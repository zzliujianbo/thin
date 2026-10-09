//! ThinAgent 终端界面（TUI）模块。
//! 职责：维护对话显示记录、把 Markdown 渲染为终端行、处理键盘输入与工具审批，
//! 并通过 bridge 与运行时后台任务（Job）通信。绘制采用“整帧生成 + 分段写出”。
const std = @import("std");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const task = @import("../core/task.zig");
const interrupt = @import("../platform/interrupt.zig");
const terminal_module = @import("terminal.zig");
const input = @import("input.zig");
const text = @import("text.zig");
const markdown = @import("markdown.zig");
const bridge_module = @import("bridge.zig");
const Io = std.Io;

/// 单条显示记录的字节上限（128 KiB）。超出部分只影响显示，不影响模型历史。
const record_limit = 128 * 1024;

/// 显示记录的种类：用户输入、助手正文、推理内容、工具事件、系统提示。
const Kind = enum { user, assistant, reasoning, tool, notice };

/// 对话区中的一条显示记录。body 保存原始 UTF-8 文本；渲染结果缓存在 cache 的 arena 中。
const Record = struct {
    /// 记录种类，决定标题与 Markdown 渲染方式。
    kind: Kind,
    /// 原始文本（UTF-8），受 record_limit 约束。
    body: std.ArrayList(u8) = .empty,
    /// 文本超过上限被截断；渲染时会附加提示。
    clipped: bool = false,
    /// 流式草稿因取消或失败而被中断。
    interrupted: bool = false,
    /// 渲染后的行被截断（行数超过上限），标题会标注 display excerpt。
    excerpt: bool = false,
    /// 渲染缓存所在的 arena；为 null 表示需要重新渲染。
    cache: ?std.heap.ArenaAllocator = null,
    /// 缓存对应的列宽，列宽变化时需要重新布局。
    columns: usize = 0,
    /// 已渲染的显示行，引用 cache arena 中的内存。
    lines: []const []const u8 = &.{},

    /// 释放渲染缓存，下次 layout 时重新渲染。
    fn invalidate(self: *Record) void {
        if (self.cache) |*cache| cache.deinit();
        self.cache = null;
        self.lines = &.{};
    }

    /// 释放记录占用的全部内存（渲染缓存与原始文本）。
    fn deinit(self: *Record, a: std.mem.Allocator) void {
        self.invalidate();
        self.body.deinit(a);
    }

    /// 追加文本。超出 record_limit 时截断，并在截断后忽略后续追加。
    fn append(self: *Record, a: std.mem.Allocator, bytes: []const u8) !void {
        if (self.clipped) return;
        var end = @min(record_limit - self.body.items.len, bytes.len);

        // 向前回退到 UTF-8 字符边界（跳过 0b10xxxxxx 续字节），避免切断多字节字符。
        while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
        try self.body.appendSlice(a, bytes[0..end]);

        // 没有全部写入时标记 clipped，之后的追加直接忽略。
        self.clipped = end < bytes.len;
        self.invalidate();
    }

    /// 按列宽渲染为显示行并缓存；缓存有效（列宽未变）时直接返回。
    fn layout(self: *Record, a: std.mem.Allocator, columns: usize) !void {
        if (self.cache != null and self.columns == columns) return;
        self.invalidate();

        // 渲染用的临时内存放在独立 arena 中，成功后整体交给 self.cache 持有。
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const temp = arena.allocator();

        // 截断时追加提示，但提示只用于显示，模型历史保持不变。
        const data = if (self.clipped) try std.fmt.allocPrint(temp, "{s}\n[display clipped; model history is unchanged]", .{self.body.items}) else self.body.items;
        const rendered = try markdown.render(temp, data, .{ .columns = columns, .max_lines = 4096, .markdown = self.kind == .assistant });
        self.lines = rendered.lines;
        self.excerpt = rendered.truncated or rendered.total_lines > rendered.lines.len;
        self.columns = columns;

        // arena 所有权转移给 Record；之后由 invalidate 统一释放。
        self.cache = arena;
    }
};

/// 当前等待用户审批的工具调用。description 由 Ui 的 allocator 持有，由 clearPermission 释放。
/// clipped 表示预览被截断；pasted 表示审批期间出现过粘贴。两者任一为真时只能拒绝。
const Permission = struct { id: u64, description: []const u8, clipped: bool, pasted: bool = false };

/// UI-owned callbacks; the application owns the runtime and configuration lifetime.
pub const Connection = struct {
    context: *anyopaque,
    current_fn: *const fn (*anyopaque) State,
    configure_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub const State = struct { runtime: ?*r.Runtime, model: []const u8, base_url: []const u8 };

    pub fn current(self: Connection) State {
        return self.current_fn(self.context);
    }

    pub fn configure(self: Connection, key: []const u8) !void {
        try self.configure_fn(self.context, key);
    }
};

/// TUI 入口：打开终端，运行事件循环直到退出，并恢复终端属性。返回进程退出码。
pub fn run(a: std.mem.Allocator, io: Io, connection: Connection, bridge: *bridge_module.Bridge, cancel: *p.Cancellation) !u8 {
    // Caller initialized the C.UTF-8 width locale before starting application I/O.
    // 打开终端并进入 TUI 模式；终端属性由 terminal 模块保存，退出时恢复。
    var terminal = try terminal_module.Terminal.open();
    // defer 逆序执行：先 ui.deinit（等待 worker 结束），再 terminal.deinit（恢复终端）。
    defer terminal.deinit();
    var ui = Ui{ .allocator = a, .io = io, .connection = connection, .bridge = bridge, .cancel = cancel, .terminal = &terminal, .editor = .{ .allocator = a }, .job = undefined };
    defer ui.deinit();

    // 事件循环出错时直接返回，资源释放交给上面的 defer。
    const result = ui.loop() catch |err| {
        // ui.deinit joins its worker before terminal.deinit restores attributes.
        return err;
    };

    // 正常退出时显式恢复终端；恢复失败必须报告给调用方，而不是静默忽略。
    if (!terminal.restore()) return error.TerminalRestoreFailed;
    return result;
}

/// TUI 的全部状态。只在 UI 线程（run/loop）中访问；后台 Job 只通过 bridge 与之通信。
const Ui = struct {
    /// 分配显示记录、草稿与帧缓冲的内存分配器。
    allocator: std.mem.Allocator,
    io: Io,
    connection: Connection,
    /// 事件队列与审批应答通道，运行时与 UI 的唯一桥梁。
    bridge: *bridge_module.Bridge,
    /// 取消信号，与后台任务共享。
    cancel: *p.Cancellation,
    terminal: *terminal_module.Terminal,
    secret: input.SecretInput = .{},
    secret_mode: bool = false,
    /// After a secret paste, trailing bytes remain quarantined until explicit clear.
    secret_quarantine: bool = false,
    /// 输入框编辑器（UTF-8 字节缓冲）。
    editor: input.Editor,
    /// 终端输入解析器，处理转义序列与粘贴边界。
    parser: input.Parser = .{},
    /// 对话显示记录；超过 64 条或约 1 MiB 时丢弃最旧的。
    records: std.ArrayList(Record) = .empty,
    /// 正在流式接收的助手正文记录索引；null 表示没有草稿。
    draft: ?usize = null,
    /// 正在流式接收的推理记录索引。
    reasoning: ?usize = null,
    /// 是否显示推理内容，Ctrl+R 切换。
    show_reasoning: bool = false,
    /// 当前待审批的请求；null 表示没有审批。
    permission: ?Permission = null,
    /// 最近一次真正写出到屏幕上的审批 id。只有它与 permission 一致时按键才生效，
    /// 避免用户按的键落到未显示的请求上。
    displayed_permission: ?u64 = null,
    /// 审批面板的滚动偏移行数。
    permission_scroll: usize = 0,
    /// 审批期间是否出现过粘贴；出现后该审批只能拒绝。
    approval_paste_seen: bool = false,
    /// 对话区向上滚动的行数（0 表示贴底）。
    scroll: usize = 0,
    /// 已有旧记录被丢弃，标题栏会提示 older display clipped。
    dropped_display: bool = false,
    /// 后台任务是否正在运行。
    busy: bool = false,
    /// 用户请求退出；若任务仍在运行，会等它结束后再退出。
    want_exit: bool = false,
    /// 清理未确认（CleanupFailed 等），禁止再次提交，只允许退出并检查。
    poisoned: bool = false,
    /// 是否需要重绘，由事件与按键置位。
    dirty: bool = true,
    /// 运行时当前状态，用于状态栏显示。
    mode: ?r.State = null,
    /// 状态栏的提示文本。
    notice: []const u8 = "Ready",
    /// 上一次运行的终态结果，用于状态栏与用量显示。
    last_terminal: ?r.Terminal = null,
    /// 实际使用的协议；可能因 Responses 不支持而降级为 Chat。
    effective_protocol: ?p.Protocol = null,
    /// 后台任务描述与结果；只在 submit 中赋值。
    job: task.Job,
    /// 后台 worker 的 future；非 null 表示任务已启动，complete 时 await。
    future: ?Io.Future(void) = null,
    /// 当前任务的提示词副本，由 Ui 持有到任务结束。
    prompt: ?[]const u8 = null,
    /// 待写出帧所在的 arena，帧全部写完后释放。
    frame_arena: ?std.heap.ArenaAllocator = null,
    /// 待输出的完整帧；可能分多次 write，由 frame_offset 记录进度。
    frame: []const u8 = "",
    frame_offset: usize = 0,
    /// 该帧绘制时展示的审批 id；写完后才成为 displayed_permission。
    frame_permission: ?u64 = null,
    /// 最近一次读取的终端尺寸。
    size: terminal_module.Size = .{ .columns = 0, .rows = 0 },

    /// 释放 Ui 持有的全部资源。顺序很重要：先关 bridge 并取消任务，再等待 worker 结束，否则 worker 可能仍在访问 Ui 字段。
    fn deinit(self: *Ui) void {
        // 关闭 bridge 并发出取消，让后台任务尽快退出。
        self.bridge.close();
        self.cancel.cancel();
        // 必须等待 worker 结束，否则它可能仍在访问 Ui 的字段。
        if (self.future) |*future| future.await(self.io);
        if (self.prompt) |prompt| self.allocator.free(prompt);
        self.clearPermission();
        if (self.frame_arena) |*arena| arena.deinit();
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.secret.deinit();
        self.parser.secretMode(false);
        self.wipeEditor();
        self.editor.deinit();
    }

    /// 释放当前审批的描述并清空审批状态（包括已显示的审批 id）。
    fn clearPermission(self: *Ui) void {
        if (self.permission) |permission| self.allocator.free(permission.description);
        self.permission = null;
        self.displayed_permission = null;
    }

    /// 追加一条新显示记录。超出条数或字节上限时丢弃最旧的记录，返回新记录的索引。
    fn add(self: *Ui, kind: Kind, data: []const u8) !usize {
        var bytes: usize = 0;
        for (self.records.items) |record| bytes += record.body.items.len;

        // 丢弃最旧记录时同步修正 draft/reasoning 索引，避免指向错误的记录。
        while (self.records.items.len > 0 and (self.records.items.len >= 64 or bytes + @min(data.len, record_limit) > 1024 * 1024)) {
            var removed = self.records.orderedRemove(0);
            bytes -= removed.body.items.len;
            removed.deinit(self.allocator);
            if (self.draft) |i| self.draft = if (i == 0) null else i - 1;
            if (self.reasoning) |i| self.reasoning = if (i == 0) null else i - 1;
            self.dropped_display = true;
        }

        try self.records.append(self.allocator, .{ .kind = kind });
        const index = self.records.items.len - 1;
        try self.records.items[index].append(self.allocator, data);
        self.dirty = true;
        return index;
    }

    /// 将文本追加到当前流式草稿（助手正文或推理）；没有草稿时新建一条。
    fn appendDraft(self: *Ui, kind: Kind, value: []const u8) !void {
        const prior = if (kind == .reasoning) self.reasoning else self.draft;
        const index = prior orelse try self.add(kind, "");
        try self.records.items[index].append(self.allocator, value);
        if (kind == .reasoning) self.reasoning = index else self.draft = index;
    }

    /// 用运行时最终确认的内容替换流式草稿，使显示与模型历史一致（canonical）。
    fn replaceCommitted(self: *Ui, blocks: []const p.Block, clipped: bool) !void {
        // 先清空现有草稿的内容，再用 canonical 块重新填充。
        if (self.draft) |i| {
            self.records.items[i].body.clearRetainingCapacity();
            self.records.items[i].clipped = false;
            self.records.items[i].invalidate();
        }
        if (self.reasoning) |i| {
            self.records.items[i].body.clearRetainingCapacity();
            self.records.items[i].clipped = false;
            self.records.items[i].invalidate();
        }

        for (blocks) |block| switch (block) {
            .text => |v| try self.appendDraft(.assistant, v),
            .reasoning => |v| try self.appendDraft(.reasoning, v),
            else => {},
        };

        // 显示被截断时只在草稿上标记 clipped，canonical 内容本身不受影响。
        if (clipped) {
            for ([_]?usize{ self.draft, self.reasoning }) |index| if (index) |i| {
                self.records.items[i].clipped = true;
                self.records.items[i].invalidate();
            };
        }

        self.draft = null;
        self.reasoning = null;
    }

    /// 把一个 bridge 事件应用到 UI 状态：追加文本、更新状态、插入审批或工具记录等。
    fn event(self: *Ui, item: bridge_module.Item) !void {
        self.dirty = true;
        switch (item.event) {
            .state => |state| self.mode = state,
            .text => |v| {
                try self.appendDraft(.assistant, v);
                if (item.display_truncated) {
                    self.records.items[self.draft.?].clipped = true;
                    self.records.items[self.draft.?].invalidate();
                }
            },
            .reasoning => |v| {
                try self.appendDraft(.reasoning, v);
                if (item.display_truncated) {
                    self.records.items[self.reasoning.?].clipped = true;
                    self.records.items[self.reasoning.?].invalidate();
                }
            },
            .assistant_committed => |blocks| try self.replaceCommitted(blocks, item.display_truncated),
            .permission => |permission| {
                // 新审批到来时先释放旧的；粘贴标记沿用到这次请求。
                self.clearPermission();
                self.approval_paste_seen = self.approval_paste_seen or self.parser.pasted;
                self.permission = .{ .id = permission.id, .description = try self.allocator.dupe(u8, permission.description), .clipped = item.display_truncated, .pasted = self.approval_paste_seen };
                self.permission_scroll = 0;
            },
            .tool_started => |tool| {
                const title = try std.fmt.allocPrint(self.allocator, "Running {s} (#{d})", .{ tool.name, tool.id });
                defer self.allocator.free(title);
                _ = try self.add(.notice, title);
            },
            .tool_result => |tool| {
                const title = try std.fmt.allocPrint(self.allocator, "{s} #{d}: {s}\n{s}", .{ tool.name, tool.id, if (tool.result.is_error) "error" else "completed", tool.result.text });
                defer self.allocator.free(title);
                const i = try self.add(.tool, title);
                self.records.items[i].clipped = self.records.items[i].clipped or item.display_truncated;
            },
            .usage => |usage| self.effective_protocol = usage.protocol,
            .fallback => {
                // Responses 不支持时仅降级一次，之后本进程都使用 Chat。
                self.effective_protocol = .chat;
                _ = try self.add(.notice, "Responses unsupported: switched once to Chat for this process.");
            },
            .compacted => |v| {
                const message = try std.fmt.allocPrint(self.allocator, "Context compacted: estimated input {d} -> {d} tokens. Display history is separate.", .{ v.before, v.after });
                defer self.allocator.free(message);
                _ = try self.add(.notice, message);
            },
            .compaction_failed => |err| {
                _ = try self.add(.notice, @errorName(err));
            },
            // 这些事件对 UI 没有需要展示的内容。
            .finished, .tool_preview => {},
        }
    }

    /// 提交当前输入并启动后台任务。忙碀或已 poisoned 时拒绝；提交不排队。
    fn submit(self: *Ui) !void {
        const command = std.mem.trim(u8, self.editor.bytes.items, " \t\r\n");
        if (std.mem.startsWith(u8, command, "/")) {
            const auth = std.mem.eql(u8, command, "/auth");
            self.wipeEditor();
            if (!auth) {
                self.notice = "Usage: /auth (no key argument); unknown commands are not sent";
            } else if (self.busy or self.permission != null or self.poisoned) {
                self.notice = "Setup requires an idle session";
            } else if (self.connection.current().runtime != null) {
                self.notice = "Already configured; /auth does not replace this session";
            } else {
                self.secret.wipe();
                self.secret_mode = true;
                self.parser.secretMode(true);
                self.notice = "Enter API key below; Enter saves locally; Ctrl+C cancels";
            }
            return;
        }
        if (self.busy) {
            self.notice = "Busy: cancel or wait; submissions are not queued";
            return;
        }
        if (self.poisoned) {
            self.notice = "Cleanup unconfirmed: exit and inspect before continuing";
            return;
        }

        if (std.mem.trim(u8, self.editor.bytes.items, " \t\r\n").len == 0) return;

        const runtime = self.connection.current().runtime orelse {
            self.wipeEditor();
            self.notice = "Not configured: use /auth first";
            return;
        };

        // 重置 bridge 与取消标记，确保新任务不继承上一次的取消状态。
        try self.bridge.reset();
        self.cancel.* = .{};
        self.approval_paste_seen = false;

        const prompt = try self.allocator.dupe(u8, self.editor.bytes.items);

        // prompt 在任务启动前的错误路径中由 errdefer 释放；启动后由 self.prompt 接管。
        errdefer self.allocator.free(prompt);

        _ = try self.add(.user, prompt);
        self.job = .{ .runtime = runtime, .cancel = self.cancel, .prompt = prompt };

        // 在独立线程中运行任务；&self.job 在 future 结束前必须保持有效（Ui 持有）。
        const future = try Io.concurrent(self.io, task.Job.run, .{&self.job});
        self.future = future;
        self.prompt = prompt;
        self.busy = true;
        self.mode = .calling_model;
        self.last_terminal = null;
        self.notice = "Running";
        self.scroll = 0;
        self.editor.clear();
    }

    fn wipeEditor(self: *Ui) void {
        // clear 在 Debug 模式会 poison 原 items；最后再擦除，确保整个保留缓冲区为零。
        self.editor.clear();
        std.crypto.secureZero(u8, self.editor.bytes.allocatedSlice());
    }

    fn endSecret(self: *Ui) void {
        self.secret_quarantine = self.parser.secret_paste;
        self.secret.wipe();
        self.secret_mode = false;
        self.parser.secretMode(false);
    }

    fn secretKey(self: *Ui, event_: input.Event) void {
        switch (event_) {
            .text => |v| {
                self.secret.insert(v.value);
                if (self.secret.failed) self.notice = "Invalid or oversized key; Ctrl+U clears, Ctrl+C cancels";
            },
            .paste_start => self.parser.secret_paste = true,
            .backspace, .delete => self.secret.erase(),
            .clear => {
                self.secret.wipe();
                self.notice = "Key cleared; Enter saves locally; Ctrl+C cancels";
            },
            .cancel => {
                self.endSecret();
                self.notice = "Setup canceled";
            },
            .quit => {
                self.endSecret();
                self.want_exit = true;
            },
            .enter => {
                const key_bytes = self.secret.value() orelse {
                    self.notice = "Empty or invalid key; Ctrl+U clears, Ctrl+C cancels";
                    return;
                };
                self.connection.configure(key_bytes) catch {
                    self.endSecret();
                    self.notice = "Could not save configuration; use /auth to retry";
                    return;
                };
                self.endSecret();
                self.notice = "Saved locally; send a message to connect";
            },
            else => {},
        }
    }

    /// 检测到粘贴时调用：忙碀或审批中则禁止批准，只允许拒绝。
    fn blockPastedApproval(self: *Ui) void {
        if (self.busy or self.permission != null) {
            self.approval_paste_seen = true;
            self.notice = "Paste detected: deny or cancel; approvals disabled for this run";
        }
        if (self.permission) |*permission| permission.pasted = true;
    }

    /// 键盘事件回调（由 input.Parser 调用）。审批可见时优先处理审批按键；粘贴内容永远不能用于批准。
    fn key(ctx: *anyopaque, event_: input.Event) !void {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        self.dirty = true;
        if (self.secret_mode) {
            self.secretKey(event_);
            return;
        }
        if (self.secret_quarantine) {
            switch (event_) {
                .clear => {
                    self.secret_quarantine = false;
                    self.parser.secretMode(false);
                },
                .quit => self.want_exit = true,
                else => {},
            }
            return;
        }

        switch (event_) {
            .paste_start => self.blockPastedApproval(),
            .text => |v| {
                if (self.permission) |permission| {
                    if (v.pasted) {
                        self.blockPastedApproval();
                        return;
                    }
                    // 只有用户真正看到的那条审批才能被处理，防止按键落到未显示的请求上。
                    if (self.displayed_permission != permission.id) return;
                    const decision: ?r.Decision = if (std.mem.eql(u8, v.value, "y")) .allow_once else if (std.mem.eql(u8, v.value, "n")) .deny else if (std.mem.eql(u8, v.value, "t")) .trust_process else null;
                    if (decision) |d| {
                        // 预览被截断或出现过粘贴时只允许拒绝，避免用户批准彿用无法完整查看的内容。
                        if (!self.approvalFits(permission.id) and d != .deny) return;
                        if ((permission.clipped or permission.pasted) and d != .deny) {
                            self.notice = if (permission.pasted) "Paste detected: deny this request and ask again" else "Preview too large: deny and request a smaller operation";
                            return;
                        }
                        // decide 返回 false 表示请求已过期（运行时已不再等待它）。
                        if (self.bridge.decide(permission.id, d)) self.notice = "Decision sent" else self.notice = "Permission expired";
                        self.clearPermission();
                    }
                } else if (!try self.editor.insert(v.value)) self.notice = "Input limit: 64 KiB";
            },
            // 审批可见时回车无效，避免误触发送。
            .enter => if (self.permission == null) {
                try self.submit();
            },
            // 忙碀时取消任务（已产生的副作用不回滚）；空闲时只清空输入。
            .cancel => {
                if (self.busy) {
                    self.cancel.cancel();
                    self.notice = "Cancellation requested; cleaning up, not rolling back effects";
                    self.clearPermission();
                } else {
                    self.editor.clear();
                    self.notice = "Ready";
                }
            },
            // 退出：若任务仍在运行则先取消，等 loop 中 complete 完成后才真正退出。
            .quit => {
                self.want_exit = true;
                if (self.busy) self.cancel.cancel();
            },
            .toggle_reasoning => self.show_reasoning = !self.show_reasoning,
            .page_up, .up => if (self.permission != null) {
                self.permission_scroll -|= if (event_ == .up) 1 else 10;
            } else {
                self.scroll +|= if (event_ == .up) 1 else 10;
            },
            .page_down, .down => if (self.permission != null) {
                self.permission_scroll +|= if (event_ == .down) 1 else 10;
            } else {
                self.scroll -|= if (event_ == .down) 1 else 10;
            },
            .backspace => self.editor.backspace(),
            .delete => self.editor.delete(),
            .left => self.editor.left(),
            .right => self.editor.right(),
            .home => self.editor.cursor = 0,
            .end => self.editor.cursor = self.editor.bytes.items.len,
            .clear => self.editor.clear(),
            .kill_end => self.editor.bytes.items.len = self.editor.cursor,
        }
    }

    /// 收尾已结束的后台任务：等待 worker、排空剩余事件、记录终态并更新状态。
    fn complete(self: *Ui) !void {
        self.future.?.await(self.io);
        self.future = null;

        // The producer can finish after our per-tick drain limit. Once joined,
        // at most one bounded queue remains; consume it before accepting Submit.
        while (self.bridge.pop()) |value| {
            var item = value;
            defer item.deinit();
            try self.event(item);
        }
        self.busy = false;

        // 取走 bridge 中记录的终止信息，避免残留到下一次运行。
        _ = self.bridge.takeTerminal();
        self.clearPermission();
        self.allocator.free(self.prompt.?);
        self.prompt = null;
        self.last_terminal = try self.job.result();
        const result = self.last_terminal.?;

        // 清理失败或无法安全继续时进入 poisoned，禁止再次提交。
        self.poisoned = if (result.detail) |detail| detail == error.CleanupFailed or detail == error.UnsafeToContinue else false;
        self.notice = switch (result.status) {
            .success => "Completed",
            .canceled => "Canceled; prior side effects remain",
            .failed => "Failed",
        };

        // 任务结束时仍未收到 canonical 内容的草稿，标记为中断。
        if (self.draft) |i| self.records.items[i].interrupted = true;
        if (self.reasoning) |i| self.records.items[i].interrupted = true;
        self.draft = null;
        self.reasoning = null;
        self.mode = null;
        self.dirty = true;
    }

    /// 主事件循环：分批消费 bridge 事件、读取按键、分段写出帧、按节流重绘；满足退出条件时返回退出码。
    fn loop(self: *Ui) !u8 {
        var last_draw = Io.Clock.awake.now(self.io);
        var buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        while (true) {
            // 每轮最多处理 64 个事件，避免大量输出阻塞输入与绘制。
            for (0..64) |_| {
                var item = self.bridge.pop() orelse break;
                defer item.deinit();
                try self.event(item);
            }

            // acquire 与 worker 的 release 配对，确保读到任务结果。
            if (self.busy and self.job.done.load(.acquire)) try self.complete();

            // 收到信号（如 SIGINT）：转为退出请求并取消任务。
            if (interrupt.signal() != 0) {
                self.want_exit = true;
                self.cancel.cancel();
            }

            // 任务结束后才真正退出；若由信号触发，退出码为 128 + 信号编号。
            if (self.want_exit and !self.busy) return if (interrupt.signal() != 0) 128 + interrupt.signal() else 0;

            const dimensions = self.terminal.size();
            if (dimensions.columns != self.size.columns or dimensions.rows != self.size.rows) {
                self.size = dimensions;
                self.dirty = true;
            }

            // 读取终端输入交给 parser；n == 0 表示本轮无输入。
            const n = try self.terminal.read(&buffer);
            if (n > 0) {
                defer std.crypto.secureZero(u8, &buffer);
                try self.parser.feed(buffer[0..n], .{ .context = self, .emit_fn = key });
            }

            // 分段写出待输出的帧：终端可能只接受部分字节，剩余部分在下一轮继续。
            if (self.frame_offset < self.frame.len) {
                self.frame_offset += try self.terminal.write(self.frame[self.frame_offset..]);
                if (self.frame_offset == self.frame.len) {
                    // 整帧写完后才确认该审批已真正显示，按键才会生效。
                    self.displayed_permission = self.frame_permission;
                    if (self.frame_arena) |*arena| arena.deinit();
                    self.frame_arena = null;
                    self.frame = "";
                    self.frame_offset = 0;
                }
            }

            // 仅当上一帧已写完、有脉冲标记且距上次绘制超过 33ms（约 30 FPS）时才重绘。
            if (self.dirty and self.frame.len == 0 and last_draw.untilNow(self.io, .awake).toMilliseconds() >= 33) {
                try self.draw();
                last_draw = Io.Clock.awake.now(self.io);
                self.dirty = false;
            }

            // 等待终端可读（有待写帧时同时等待可写），最多 16ms，避免忙等。
            try self.terminal.wait(self.frame.len != 0, 16);
        }
    }

    /// 除正文行外，还必须完整显示审批编号；不能用被截断的标题确认当前请求。
    fn approvalFits(self: *const Ui, id: u64) bool {
        var buffer: [40]u8 = undefined;
        const identity = std.fmt.bufPrint(&buffer, "Approval #{d}", .{id}) catch return false;
        return self.size.rows >= 7 and self.size.columns > identity.len;
    }

    /// 构建一整帧输出到帧 arena（不直接写终端），帧由 loop 分段写出。
    fn draw(self: *Ui) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const cols = if (self.size.columns > 1) self.size.columns - 1 else 1; // Never trigger terminal autowrap.
        const rows = self.size.rows;
        var out: std.Io.Writer.Allocating = .init(a);
        const writer = &out.writer;

        // 隐藏光标并回到左上角，之后整帧覆盖绘制。
        try writer.writeAll("\x1b[?25l\x1b[H");

        // 终端太小时只显示提示，避免布局越界。
        // 审批标题之外至少留一行正文；尺寸不足不属于永久的 clipped 状态。
        const hides_approval_id = if (self.permission) |permission| !self.approvalFits(permission.id) else false;
        if (rows < 7 or cols < 8 or hides_approval_id) {
            for (0..rows) |row| try putLine(writer, a, row + 1, if (row == 0) "Resize terminal" else "", cols);
            self.frame_permission = null;
        } else {
            const state = self.connection.current();
            const header = try std.fmt.allocPrint(a, "thin | {s} | {s}{s}", .{ state.model, if (state.runtime == null) "not configured: /auth" else if (self.effective_protocol) |protocol| @tagName(protocol) else "configured/auto", if (self.dropped_display) " | older display clipped" else "" });
            try putLine(writer, a, 1, header, cols);

            // 布局：第 1 行标题，第 2 行审批标题或正文首行，中间为正文，倒数 3 行为状态、用量和快捷键提示，最后一行为输入行。
            const body_rows = rows - 5;
            if (self.secret_mode) {
                const destination = try std.fmt.allocPrint(a, "API key for model {s}\nBase URL: {s}\nEnter saves locally; no network request is made here", .{ state.model, state.base_url });
                const lines = try markdown.render(a, destination, .{ .columns = cols, .max_lines = 8192, .markdown = false });
                for (0..body_rows) |line| try putStyled(writer, 2 + line, if (line < lines.lines.len) lines.lines[line] else "");
                self.frame_permission = null;
            } else if (self.permission) |permission| {
                // Plain rendering: tool input must not hide behind Markdown formatting.
                const all = try markdown.render(a, permission.description, .{ .columns = cols, .max_lines = 8192, .markdown = false });
                const clipped = permission.clipped or all.truncated or all.total_lines > all.lines.len;

                // 把截断状态写回审批，供 key 处理判断是否只允许拒绝。
                self.permission.?.clipped = clipped;

                const title = if (permission.pasted)
                    try std.fmt.allocPrint(a, "Approval #{d} [paste detected; deny only]: n deny", .{permission.id})
                else if (clipped)
                    try std.fmt.allocPrint(a, "Approval #{d} [preview clipped; deny only]: n deny", .{permission.id})
                else
                    try std.fmt.allocPrint(a, "Approval #{d}: y once / n deny / t TRUST THIS PROCESS", .{permission.id});
                try putLine(writer, a, 2, title, cols);

                // 滚动位置限制在内容末尾，防止滚出空白区域。
                const start = @min(self.permission_scroll, all.lines.len -| (body_rows - 1));
                for (0..body_rows - 1) |line| try putStyled(writer, 3 + line, if (start + line < all.lines.len) all.lines[start + line] else "");
                self.frame_permission = permission.id;
            } else {
                // 把所有可见记录展开为一维行列表，再按滚动偏移取窗口。
                var lines: std.ArrayList([]const u8) = .empty;
                for (self.records.items) |*record| {
                    // 推理内容默认隐藏，Ctrl+R 切换显示。
                    if (record.kind == .reasoning and !self.show_reasoning) continue;
                    try record.layout(self.allocator, cols);
                    const heading = try std.fmt.allocPrint(a, "[{s}{s}{s}]", .{ @tagName(record.kind), if (record.interrupted) " - interrupted draft" else "", if (record.excerpt) " - display excerpt" else "" });
                    try lines.append(a, heading);
                    try lines.appendSlice(a, record.lines);
                }

                // 从底部向上回退 scroll 行，得到显示窗口的结束位置。
                const end = lines.items.len -| @min(self.scroll, lines.items.len -| body_rows);
                const start = end -| body_rows;
                for (0..body_rows) |line| try putStyled(writer, 2 + line, if (start + line < end) lines.items[start + line] else "");
                self.frame_permission = null;
            }

            // 状态栏：有运行态时加前缀 mode，有终态时附加错误信息。
            var status: []const u8 = self.notice;
            if (self.mode) |mode| status = try std.fmt.allocPrint(a, "{s} | {s}", .{ @tagName(mode), self.notice });
            if (self.last_terminal) |result| status = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ self.notice, if (result.detail != null) ": " else "", if (result.detail) |err| @errorName(err) else "", if (result.model_failure != null) " / " else "", if (result.model_failure) |failure| @tagName(failure) else "" });
            try putLine(writer, a, rows - 3, status, cols);

            const usage_line = if (self.last_terminal) |result| try std.fmt.allocPrint(a, "tokens normal in:{s} out:{s} cached:{s} | summary in:{s} out:{s} | cost:unknown", .{ try counter(a, result.usage.normal.input_tokens), try counter(a, result.usage.normal.output_tokens), try counter(a, result.usage.normal.cached_input_tokens), try counter(a, result.usage.summary.input_tokens), try counter(a, result.usage.summary.output_tokens) }) else "Usage pending | cost:unknown | Ctrl+R toggles visible reasoning";
            try putLine(writer, a, rows - 2, usage_line, cols);
            try putLine(writer, a, rows - 1, if (self.secret_quarantine) "Secret paste drained: Ctrl+U to resume | Ctrl+D exit" else if (self.secret_mode) "Enter save | Ctrl+U erase | Ctrl+C cancel | Ctrl+D exit" else if (state.runtime == null) "/auth setup (no key argument) | Ctrl+C clear | Ctrl+D exit" else "Enter send | Ctrl+J newline | Ctrl+C cancel | Ctrl+D exit | PgUp/PgDn scroll", cols);

            if (self.secret_mode or self.secret_quarantine) {
                // Only a bounded mask is copied to the frame; never format secret bytes.
                const masks: [64]u8 = @splat('*');
                const count = @min(self.secret.len, @min(masks.len, cols - 3));
                const masked = try std.fmt.allocPrint(a, "API key> {s}", .{masks[0..count]});
                try putLine(writer, a, rows, masked, cols);
                try writer.print("\x1b[{d};{d}H\x1b[?25h", .{ rows, @min(cols, count + 10) });
            } else {

                // 光标所在逻辑行的起点（以换行为界）。
                // Slash arguments can be accidental credentials: never render them, even before Enter.
                const trimmed = std.mem.trimStart(u8, self.editor.bytes.items, " \t\r\n");
                const hide_arguments = std.mem.startsWith(u8, trimmed, "/") and (std.mem.findScalar(u8, trimmed, ' ') != null or std.mem.findScalar(u8, trimmed, '\t') != null or std.mem.findScalar(u8, trimmed, '\r') != null or std.mem.findScalar(u8, trimmed, '\n') != null);
                const visible: []const u8 = if (hide_arguments) "/auth [arguments hidden; no key argument]" else self.editor.bytes.items;
                const cursor = if (hide_arguments) visible.len else self.editor.cursor;
                const begin = if (std.mem.findScalarLast(u8, visible[0..cursor], '\n')) |index| index + 1 else 0;
                const prefix = try editorDisplay(a, visible[begin..cursor]);
                var start: usize = 0;
                var width = text.width(prefix);
                // 输入过长时从左侧裁剪，保证光标所在位置可见。
                while (width > cols - 3 and start < prefix.len) {
                    const cluster = text.nextCluster(prefix, start, 0);
                    width -|= cluster.width;
                    start = cluster.end;
                }
                const tail = visible[cursor..];
                const suffix = try editorDisplay(a, tail[0..(std.mem.findScalar(u8, tail, '\n') orelse tail.len)]);
                const input_line = try std.fmt.allocPrint(a, "> {s}{s}", .{ prefix[start..], suffix });
                try putLine(writer, a, rows, input_line, cols);

                // 光标移到输入行并重新显示；+3 为 "> " 提示符占用的列加一列。
                try writer.print("\x1b[{d};{d}H\x1b[?25h", .{ rows, @min(cols, width + 3) });
            }
        }

        // frame 指向 arena 内存，arena 所有权交给 frame_arena，直到这帧写完。
        self.frame = out.written();
        self.frame_offset = 0;
        self.frame_arena = arena;
    }
};

/// 输入行的显示副本：Tab 固定展开为四个空格，测宽、裁剪与输出共用；不修改提交字节。
fn editorDisplay(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const safe = try text.sanitize(a, bytes, 256 * 1024);
    defer a.free(safe);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (safe) |byte| {
        if (byte == '\t') try out.appendSlice(a, "    ") else try out.append(a, byte);
    }
    return out.toOwnedSlice(a);
}

/// 把可选计数格式化为十进制字符串；未知值显示为 "?"。
fn counter(a: std.mem.Allocator, value: ?u64) ![]const u8 {
    return if (value) |n| std.fmt.allocPrint(a, "{d}", .{n}) else "?";
}

/// 在指定行输出内容：先定位、清行，再输出内容，最后复位样式，避免属性残留到下一行。
fn putStyled(writer: *Io.Writer, row: usize, line: []const u8) !void {
    try writer.print("\x1b[{d};1H\x1b[0m\x1b[2K{s}\x1b[0m", .{ row, line });
}

/// 按终端列宽截断一行后输出：先清理控制字符，再按字素簇累计显示宽度，超出列宽即停止。
fn putLine(writer: *Io.Writer, a: std.mem.Allocator, row: usize, line: []const u8, columns: usize) !void {
    const safe = try text.sanitize(a, line, 65536);
    var pos: usize = 0;
    var width: usize = 0;
    // 只显示第一行；按字素簇累计宽度（而非字节），宽字符不会被截成半个。
    while (pos < safe.len and safe[pos] != '\n') {
        const cluster = text.nextCluster(safe, pos, width);
        if (width + cluster.width > columns) break;
        width += cluster.width;
        pos = cluster.end;
    }
    try putStyled(writer, row, safe[0..pos]);
}

const FixtureConnection = struct {
    fn current(_: *anyopaque) Connection.State {
        return .{ .runtime = null, .model = "fixture", .base_url = "http://localhost/fixture" };
    }

    fn configure(_: *anyopaque, _: []const u8) !void {
        return error.FixtureNotConfigured;
    }
};

/// 测试用 Ui 构造器：使用 testing allocator，运行时与终端字段为 undefined（测试中不会访问）。
fn fixtureUi(bridge: *bridge_module.Bridge, cancel: *p.Cancellation) Ui {
    return .{ .allocator = std.testing.allocator, .io = std.testing.io, .connection = .{ .context = bridge, .current_fn = FixtureConnection.current, .configure_fn = FixtureConnection.configure }, .bridge = bridge, .cancel = cancel, .terminal = undefined, .editor = .{ .allocator = std.testing.allocator }, .job = undefined, .size = .{ .columns = 80, .rows = 24 } };
}

// 验证：任务完成时 complete 会先排空 bridge 中残留的事件，canonical 内容覆盖草稿，最终结果不丢失。
test "completed producer drains final events before bridge can reset" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();

    ui.prompt = try std.testing.allocator.dupe(u8, "fixture");
    ui.job = .{ .runtime = undefined, .cancel = &cancel, .prompt = ui.prompt.? };
    ui.busy = true;

    const Producer = struct {
        fn run(state: *Ui) void {
            const host = state.bridge.host();
            host.emit_fn(host.context, .{ .text = "old draft" }, state.cancel) catch unreachable;
            host.emit_fn(host.context, .{ .assistant_committed = &.{.{ .text = "canonical final" }} }, state.cancel) catch unreachable;
            state.job.terminal = .{ .status = .success };
            state.job.done.store(true, .release);
        }
    };

    ui.future = try Io.concurrent(std.testing.io, Producer.run, .{&ui});
    try ui.complete();

    // 收尾后草稿已清空，且最终内容不被标记为中断。
    try std.testing.expect(!ui.busy and ui.draft == null);
    try std.testing.expectEqualStrings("canonical final", ui.records.items[0].body.items);
    try std.testing.expect(!ui.records.items[0].interrupted);

    // 收尾后 bridge 必须可以安全复用。
    try bridge.reset();
}

// 验证：即使字节未超过 bridge 预算，超高的审批预览也会被截断，并且只能拒绝。
test "permission line clipping is deny-only even when bytes fit bridge budget" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();

    // 10000 个换行，使预览行数超出上限。
    const lines: [10000]u8 = @splat('\n');
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = &lines } }, &cancel);
    var item = bridge.pop().?;
    try std.testing.expect(!item.display_truncated);
    try ui.event(item);
    item.deinit();

    try ui.draw();
    try std.testing.expect(ui.permission.?.clipped);
    try std.testing.expect(std.mem.find(u8, ui.frame, "deny only") != null);
    ui.displayed_permission = 1;
    try Ui.key(&ui, .{ .text = .{ .value = "y", .pasted = false } });
    try Ui.key(&ui, .{ .text = .{ .value = "t", .pasted = false } });
    try std.testing.expect(bridge.answer == null);
    try Ui.key(&ui, .{ .text = .{ .value = "n", .pasted = false } });
    try std.testing.expectEqual(@as(?r.Decision, .deny), bridge.answer);
}

// 验证：审批必须与屏幕上真正显示的请求一致，且粘贴内容不能批准。
test "permissions require a matching displayed frame and never accept paste" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 2, .tool_name = "bash", .description = "fixed fixture" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try Ui.key(&ui, .{ .text = .{ .value = "y", .pasted = false } });
    try std.testing.expect(bridge.answer == null);
    ui.displayed_permission = 1;
    try Ui.key(&ui, .{ .text = .{ .value = "y", .pasted = false } });
    try std.testing.expect(bridge.answer == null);

    ui.displayed_permission = 2;
    try Ui.key(&ui, .{ .text = .{ .value = "y", .pasted = true } });
    try std.testing.expect(bridge.answer == null);
    try Ui.key(&ui, .{ .text = .{ .value = "y", .pasted = false } });
    try std.testing.expect(bridge.answer == null); // Pasting makes this request deny-only.
    try Ui.key(&ui, .{ .text = .{ .value = "n", .pasted = false } });
    try std.testing.expectEqual(@as(?r.Decision, .deny), bridge.answer);
}

// 验证：粘贴内容中嵌入的结束标记不能伪造一次“允许”。
test "paste terminator injection cannot authorize the visible permission" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "fixed fixture" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    ui.displayed_permission = 1;

    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~\x1b[201~", sink);
    try ui.parser.feed("yt\x1b[201~", sink); // Malicious paste body after an embedded terminator.
    try std.testing.expect(bridge.answer == null);
    try std.testing.expect(ui.approval_paste_seen);
    try ui.parser.feed("n", sink);
    try std.testing.expectEqual(@as(?r.Decision, .deny), bridge.answer);
}

// 验证：canonical 推理内容保留显式的显示截断标记。
test "canonical reasoning retains an explicit display clipping marker" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();

    try ui.appendDraft(.reasoning, "old reasoning");
    try ui.replaceCommitted(&.{.{ .reasoning = "bounded canonical reasoning" }}, true);
    try std.testing.expect(ui.records.items[0].clipped);
    try std.testing.expectEqualStrings("bounded canonical reasoning", ui.records.items[0].body.items);
}

test "six-row approval cannot authorize and recovers after a complete visible frame" {
    try text.initLocale();
    for ([_]usize{ 7, 24 }) |restored_rows| {
        for ([_][]const u8{ "y", "t" }) |key_bytes| {
            var cancel = p.Cancellation{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            ui.size = .{ .columns = 80, .rows = 6 };
            const host = bridge.host();
            try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "VISIBLE OPERATION" } }, &cancel);
            var item = bridge.pop().?;
            try ui.event(item);
            item.deinit();
            const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };

            try ui.draw();
            try std.testing.expect(std.mem.find(u8, ui.frame, "Resize terminal") != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "VISIBLE OPERATION") == null);
            try std.testing.expect(ui.frame_permission == null);
            ui.displayed_permission = ui.frame_permission; // 模拟整帧写完，不使用真实终端。
            try ui.parser.feed("yt", sink);
            try std.testing.expect(bridge.answer == null);
            try std.testing.expect(!ui.permission.?.clipped);
            ui.frame_arena.?.deinit();
            ui.frame_arena = null;
            ui.frame = "";

            ui.size.rows = restored_rows;
            try ui.draw();
            try std.testing.expect(std.mem.find(u8, ui.frame, "VISIBLE OPERATION") != null);
            try std.testing.expectEqual(@as(?u64, 1), ui.frame_permission);
            try ui.parser.feed(key_bytes, sink); // 构建帧不等于整帧已显示。
            try std.testing.expect(bridge.answer == null);
            ui.displayed_permission = ui.frame_permission;
            try ui.parser.feed(key_bytes, sink);
            try std.testing.expectEqual(@as(?r.Decision, if (key_bytes[0] == 'y') .allow_once else .trust_process), bridge.answer);
        }
    }
}

test "approval identity must fit in full before narrow windows can authorize" {
    try text.initLocale();
    for ([_]u64{ 1, std.math.maxInt(u64) }) |id| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        var buffer: [40]u8 = undefined;
        const identity = try std.fmt.bufPrint(&buffer, "Approval #{d}", .{id});
        ui.size = .{ .columns = identity.len, .rows = 7 };
        const host = bridge.host();
        try host.emit_fn(host.context, .{ .permission = .{ .id = id, .tool_name = "bash", .description = "OPERATION" } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.draw();
        try std.testing.expect(ui.frame_permission == null);
        try std.testing.expect(!ui.permission.?.clipped);
        // 即使还残留较宽窗口的旧帧确认，也不得在编号放不下时批准。
        ui.displayed_permission = id;
        try ui.parser.feed("yt", sink);
        try std.testing.expect(bridge.answer == null);
        ui.displayed_permission = null;
        ui.frame_arena.?.deinit();
        ui.frame_arena = null;
        ui.frame = "";

        ui.size.columns += 1; // 末列保留给避免 autowrap；现在编号恰好完整显示。
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, identity) != null);
        try std.testing.expectEqual(@as(?u64, id), ui.frame_permission);
        try ui.parser.feed("y", sink);
        try std.testing.expect(bridge.answer == null);
        ui.displayed_permission = ui.frame_permission;
        try ui.parser.feed("y", sink);
        try std.testing.expectEqual(@as(?r.Decision, .allow_once), bridge.answer);
    }
}

test "editor tabs expand before clipping and cursor placement but submit unchanged" {
    try text.initLocale();
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat } };
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{ .configured = true };
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "", false);
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    ui.size = .{ .columns = 12, .rows = 7 };
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    const raw = "A\t\tB\t\tC";
    try ui.parser.feed("\x1b[200~" ++ raw ++ "\x1b[201~", sink);

    const cases = [_]struct { cursor: usize, line: []const u8, column: usize }{
        .{ .cursor = raw.len, .line = ">        C", .column = 11 },
        .{ .cursor = 3, .line = ">         B", .column = 11 },
        .{ .cursor = 1, .line = "> A        ", .column = 4 },
    };
    for (cases) |case| {
        ui.editor.cursor = case.cursor;
        try ui.draw();
        try std.testing.expect(std.mem.findScalar(u8, ui.frame, '\t') == null);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "\x1b[7;1H\x1b[0m\x1b[2K{s}\x1b[0m\x1b[7;{d}H\x1b[?25h", .{ case.line, case.column });
        defer std.testing.allocator.free(expected);
        try std.testing.expect(std.mem.endsWith(u8, ui.frame, expected));
        try std.testing.expectEqualStrings(raw, ui.editor.bytes.items);
        ui.frame_arena.?.deinit();
        ui.frame_arena = null;
        ui.frame = "";
    }

    try ui.parser.feed("\r", sink);
    try std.testing.expectEqualStrings(raw, ui.prompt.?);
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqualStrings(raw, runtime.messages()[0].blocks[0].text);
    try std.testing.expectEqualStrings(raw, ui.records.items[0].body.items);
}

const AuthFixture = struct {
    runtime: ?*r.Runtime = null,
    configured: bool = false,
    fail: bool = false,
    saves: usize = 0,
    calls: usize = 0,

    fn connection(self: *AuthFixture) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure };
    }

    fn current(ctx: *anyopaque) Connection.State {
        const self: *AuthFixture = @ptrCast(@alignCast(ctx));
        return .{ .runtime = if (self.configured) self.runtime else null, .model = "fixture-model", .base_url = "http://localhost/fixture" };
    }

    fn configure(ctx: *anyopaque, key_bytes: []const u8) !void {
        const self: *AuthFixture = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqualStrings("sk-fixture-secret", key_bytes);
        self.saves += 1;
        if (self.fail) return error.FixtureSaveFailed;
        self.configured = true;
    }

    fn call(ctx: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *AuthFixture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "fixture done" }} }, .finish = .stop } };
    }

    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return error.UnexpectedTool;
    }

    fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        return error.UnexpectedTool;
    }
};

test "unconfigured text and slash commands never create jobs records or expose arguments" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("hello\r", sink);
    try std.testing.expectEqualStrings("Not configured: use /auth first", ui.notice);
    try ui.parser.feed("/auth sk-accidental-secret", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "sk-accidental-secret") == null);
    ui.frame_arena.?.deinit();
    ui.frame_arena = null;
    ui.frame = "";
    try ui.parser.feed("\r", sink);
    for (ui.editor.bytes.allocatedSlice()) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("/unknown\r", sink);
    try std.testing.expect(ui.future == null and !ui.busy and ui.prompt == null);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try ui.parser.feed("/auth\rdiscard-command-batch-tail", sink);
    try std.testing.expect(ui.secret_mode and ui.secret.len == 0);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
}

test "secret prompt masks keys shows destination and erases cancel error and paste tails" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{ .fail = true };
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/auth\r", sink);
    try ui.parser.feed("sk-fixture-secret", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "sk-fixture-secret") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "API key") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "http://localhost/fixture") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fixture-model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "*****") != null);
    try ui.parser.feed("\rsecret-error-tail", sink);
    try std.testing.expect(!ui.secret_mode and !fixture.configured);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    for (ui.secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("/auth\r", sink);
    try ui.parser.feed("erase\x7f\x1b[3~", sink);
    try std.testing.expectEqualStrings("era", ui.secret.value().?);
    try ui.parser.feed("\x15", sink);
    try std.testing.expectEqual(@as(usize, 0), ui.secret.len);
    try ui.parser.feed("\x1b[200~pasted\nkey\x1b[201~", sink);
    try std.testing.expect(ui.secret.failed);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.secret_mode);
    try ui.parser.feed("\x03trailing-key", sink);
    try ui.parser.feed("more-tail\x1b[201~\r", sink);
    try std.testing.expect(!ui.secret_mode and ui.secret_quarantine);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    for (ui.secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("\x15", sink);
    try std.testing.expect(!ui.secret_quarantine);
    try ui.parser.feed("/auth\r", sink);
    try ui.parser.feed("key\x04exit-tail", sink);
    try std.testing.expect(ui.want_exit and !ui.secret_mode and ui.secret.len == 0);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
}

test "configure enables same-process submit without sending secrets or commands" {
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat } };
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{};
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "", false);
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("not-yet\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), runtime.messages().len);
    try ui.parser.feed("/auth\r", sink);
    try ui.parser.feed("\x1b[200~sk-fixture-secret\x1b[201~", sink);
    try ui.parser.feed("\rsecret-tail", sink);
    try std.testing.expectEqualStrings("Saved locally; send a message to connect", ui.notice);
    try std.testing.expectEqual(@as(usize, 1), fixture.saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    for (ui.secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("\x15", sink); // Explicitly release post-paste quarantine.
    try ui.parser.feed("/auth\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try std.testing.expectEqual(@as(usize, 1), fixture.saves);
    try ui.parser.feed("hello\r", sink);
    try std.testing.expect(ui.busy);
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqualStrings("hello", runtime.messages()[0].blocks[0].text);
    try std.testing.expectEqualStrings("hello", ui.records.items[0].body.items);
    for (ui.records.items) |record| try std.testing.expect(std.mem.find(u8, record.body.items, "sk-fixture-secret") == null);
}
