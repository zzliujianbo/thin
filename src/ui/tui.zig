//! ThinAgent 终端界面（TUI）模块。
//! 职责：维护对话显示记录、把 Markdown 渲染为终端行、处理键盘输入与工具审批，
//! 并通过 bridge 与运行时后台任务（Job）通信。绘制采用“整帧生成 + 分段写出”。
const std = @import("std");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const core_config = @import("../core/config.zig");
const task = @import("../core/task.zig");
const interrupt = @import("../platform/interrupt.zig");
const terminal_module = @import("terminal.zig");
const input = @import("input.zig");
const picker_module = @import("model_picker.zig");
const text = @import("text.zig");
const markdown = @import("markdown.zig");
const theme = @import("theme.zig");
const activity = @import("activity.zig");
const presentation = @import("presentation.zig");
const shared = @import("../presentation.zig");
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
    /// Every completed call owns one compact row, never a raw result block.
    command_row: bool = false,
    final_answer: bool = false,
    command_spans: std.ArrayList(presentation.CommandSpan) = .empty,
    /// Only a fully written frame commits transcript delivery. Pending survives index shifts.
    output: bool = false,
    pending_output: bool = false,
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
        self.command_spans.deinit(a);
    }

    fn setCommand(self: *Record, a: std.mem.Allocator, caption: presentation.Caption, outcome: presentation.Outcome) !void {
        std.debug.assert(self.body.items.len == 0 and self.command_spans.items.len == 0);
        const label = try presentation.commandText(a, caption, outcome);
        defer a.free(label);
        try self.command_spans.ensureUnusedCapacity(a, 1);
        const start = self.body.items.len;
        try self.append(a, label);
        self.command_row = true;
        self.command_spans.appendAssumeCapacity(.{ .start = start, .end = self.body.items.len, .outcome = outcome, .write_marks = if (caption.write_marks) |marks| marks.shifted(start + activity.icon(caption.kind).len + 1) else null });
    }

    /// 追加文本。超出 record_limit 时截断，并在截断后忽略后续追加。
    fn append(self: *Record, a: std.mem.Allocator, bytes: []const u8) !void {
        if (self.kind == .reasoning) {
            // Thinking is a bounded rolling window, not a permanent transcript.
            // Keep the newest UTF-8 suffix even after the first display limit.
            var start = bytes.len -| record_limit;
            while (start < bytes.len and bytes[start] & 0xc0 == 0x80) start += 1;
            const suffix = bytes[start..];
            var drop = self.body.items.len + suffix.len -| record_limit;
            while (drop < self.body.items.len and self.body.items[drop] & 0xc0 == 0x80) drop += 1;
            if (drop != 0) {
                std.mem.copyForwards(u8, self.body.items, self.body.items[drop..]);
                self.body.items.len -= drop;
            }
            try self.body.appendSlice(a, suffix);
            self.clipped = self.clipped or start != 0 or drop != 0;
            self.invalidate();
            return;
        }
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

        if (self.command_row) {
            const line = try presentation.commandLine(temp, self.body.items, self.command_spans.items, columns, null);
            self.lines = try temp.dupe([]const u8, &.{line});
            self.excerpt = false; // Commands indicate clipping with ... only.
            self.columns = columns;
            self.cache = arena;
            return;
        }
        // 截断时追加提示，但提示只用于显示，模型历史保持不变。
        const data = if (self.clipped and self.kind != .reasoning) try std.fmt.allocPrint(temp, "{s}\n[display clipped; model history is unchanged]", .{self.body.items}) else self.body.items;
        const rendered = try markdown.render(temp, data, .{ .columns = columns, .max_lines = 4096, .markdown = self.kind == .assistant or self.kind == .reasoning, .tone = if (self.kind == .user) .user else if (self.kind == .reasoning or self.kind == .notice) .muted else .normal });
        self.lines = rendered.lines;
        self.excerpt = self.clipped or rendered.truncated or rendered.degraded or rendered.total_lines > rendered.lines.len;
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
    /// Idle, joined-owner callbacks; no network calls. Model selection stays
    /// local; effort saves the project preference, never global defaults.
    select_model_fn: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    set_effort_fn: ?*const fn (*anyopaque, shared.ReasoningEffort) anyerror!void = null,

    pub const State = struct {
        runtime: ?*r.Runtime,
        /// Immutable app-prepared startup snapshot; no runtime dereference in draw.
        initial_context: ?r.ContextSnapshot = null,
        model: []const u8,
        /// Immutable owner snapshot, valid even without a journal submission.
        session_id: ?[32]u8 = null,
        /// Metadata-only catalog for this endpoint; never a credential catalog.
        models: []const core_config.Model = &.{},
        context_limit: u32 = 0,
        /// Immutable configured request option, not inferred from stream time.
        reasoning_effort: shared.ReasoningEffort = .unspecified,
        /// Capability metadata prepared by the owner; zero means unknown.
        effort_levels: shared.activity.EffortSet = .{},
        settings_error: ?anyerror = null,
        settings_notice: ?[]const u8 = null,
        base_url: []const u8,
        /// 应用层的启动策略快照，不读取工作线程可变的 Runtime.trusted。
        tools_trusted: bool = false,
        logging_enabled: bool = true,
        /// 由应用层以原子状态发布；UI 不读日志文件、不持有其写入器。
        log_error: ?anyerror = null,
    };

    pub fn current(self: Connection) State {
        return self.current_fn(self.context);
    }

    pub fn configure(self: Connection, key: []const u8) !void {
        try self.configure_fn(self.context, key);
    }
    pub fn selectModel(self: Connection, name: []const u8) !void {
        const callback = self.select_model_fn orelse return error.SelectionUnavailable;
        try callback(self.context, name);
    }
    pub fn setEffort(self: Connection, effort: shared.ReasoningEffort) !void {
        const callback = self.set_effort_fn orelse return error.SelectionUnavailable;
        try callback(self.context, effort);
    }
};

/// TUI 入口：打开终端，运行事件循环直到退出，并恢复终端属性。返回进程退出码。
pub fn run(a: std.mem.Allocator, io: Io, connection: Connection, bridge: *bridge_module.Bridge, cancel: *p.Cancellation) !u8 {
    // Snapshot immutable identity BEFORE the loop; never inspect writer Store.
    const session_id = connection.current().session_id;
    if (session_id) |id| for (id) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidSessionID;
    };
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

    return finishExit(&terminal, ui.ctrl_d_exit, result, session_id, interrupt.signal);
}

const ExitSignal = struct {
    read: *const fn () u8,
    fn stopped(ctx: ?*const anyopaque) bool {
        const self: *const ExitSignal = @ptrCast(@alignCast(ctx.?));
        return self.read() != 0;
    }
};

// The private reader seam permits exact post-restore/pre-write boundary tests.
// Production always reads the process-local signal handler's atomic value.
fn finishExit(terminal: *terminal_module.Terminal, ctrl_d: bool, result: u8, id: ?[32]u8, read_signal: *const fn () u8) !u8 {
    if (!terminal.restore()) return error.TerminalRestoreFailed;
    const signal = read_signal();
    if (signal != 0) return 128 + signal;
    if (ctrl_d and result == 0) {
        if (id) |value| {
            var line: [64]u8 = undefined;
            const bytes = try std.fmt.bufPrint(&line, "Session ID: {s}\r\n", .{value});
            const guard = ExitSignal{ .read = read_signal };
            terminal.writeAfterRestoreStopped(bytes, .{ .context = &guard, .stopped_fn = ExitSignal.stopped }) catch |err| {
                if (err == error.Canceled) {
                    const caught = read_signal();
                    if (caught != 0) return 128 + caught;
                }
                return err;
            };
        }
    }
    const final_signal = read_signal();
    return if (final_signal != 0) 128 + final_signal else result;
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
    editor_pasted: bool = false,
    model_picker: ?picker_module.Picker = null,
    model_epoch: u64 = 0,
    displayed_model_epoch: ?u64 = null,
    displayed_model_generation: ?u64 = null,
    frame_model_epoch: ?u64 = null,
    frame_model_generation: ?u64 = null,
    last_input_ms: u64 = 0,
    /// 对话显示记录；超过 64 条或约 1 MiB 时丢弃最旧的。
    records: std.ArrayList(Record) = .empty,
    /// 正在流式接收的助手正文记录索引；null 表示没有草稿。
    draft: ?usize = null,
    /// 正在流式接收的推理记录索引。
    reasoning: ?usize = null,
    /// 默认在三行临时窗口显示可见推理；正文开始后丢弃，不进入滚屏/历史。
    /// 不推断或解密供应商未公开的隐藏推理。
    show_reasoning: bool = true,
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
    ctrl_d_exit: bool = false,
    /// 清理未确认（CleanupFailed 等），禁止再次提交，只允许退出并检查。
    poisoned: bool = false,
    /// 是否需要重绘，由事件与按键置位。
    dirty: bool = true,
    /// UI接收状态：用于计时/忙碌标记，不显示常驻mode文字。
    mode: ?r.State = null,
    /// 仅必要的错误、设置和隔离提示使用临时hint。
    notice: []const u8 = "Ready",
    log_warning_seen: bool = false,
    /// UI receipt clock and bounded statistics; never read worker-owned timing.
    clock_ms: u64 = 0,
    animation_tick: u64 = 0,
    display: shared.State = .{},
    model_flow: activity.Flow = .{},
    active_tool: ?struct { id: u64, caption: presentation.Caption } = null,
    /// Shared canonical FIFO; renderer adds terminal widths/icons later.
    tool_calls: shared.tools.Queue = .{},
    /// 上一次终态用于失败详情和cleanup安全检查，不显示统计栏。
    last_terminal: ?r.Terminal = null,
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
    frame_height: usize = 0,
    frame_size: terminal_module.Size = .{ .columns = 0, .rows = 0 },
    frame_fresh: bool = false,
    frame_clear_end: usize = 0,
    /// A resize may interrupt even an escape sequence in the reclaim prefix.
    resize_rescue: []const u8 = "",
    tail_height: usize = 0,
    tail_size: terminal_module.Size = .{ .columns = 0, .rows = 0 },
    abandon_tail: bool = false,
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
        self.clearActiveTool();
        self.clearToolCaptions();
        self.tool_calls.deinit(self.allocator);
        if (self.frame_arena) |*arena| arena.deinit();
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.secret.deinit();
        self.closeModelPicker();
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

    fn removeRecord(self: *Ui, index: usize) void {
        var removed = self.records.orderedRemove(index);
        removed.deinit(self.allocator);
        if (self.draft) |i| self.draft = if (i == index) null else if (i > index) i - 1 else i;
        if (self.reasoning) |i| self.reasoning = if (i == index) null else if (i > index) i - 1 else i;
    }

    fn discardReasoning(self: *Ui) void {
        self.removeRecord(self.reasoning orelse return);
    }

    fn clearActiveTool(self: *Ui) void {
        if (self.active_tool) |active| active.caption.deinit(self.allocator);
        self.active_tool = null;
    }

    fn clearToolCaptions(self: *Ui) void {
        self.tool_calls.clear(self.allocator);
    }

    fn captureToolCaptions(self: *Ui, blocks: []const p.Block) !void {
        try self.tool_calls.capture(self.allocator, blocks);
    }

    fn nextToolCaption(self: *Ui, name: []const u8) !presentation.Caption {
        const call = try self.tool_calls.take(name, self.allocator);
        defer call.deinit(self.allocator);
        return presentation.fromCall(self.allocator, call);
    }

    fn toolCompleted(self: *Ui, caption: presentation.Caption, result: r.Execution) !void {
        const completion = shared.tools.Completion.fromExecution(result);
        const outcome = completion.outcome;
        const observed = if (outcome == .success) try presentation.completed(self.allocator, caption, completion.file_stats) else presentation.Caption{ .kind = caption.kind, .label = try self.allocator.dupe(u8, caption.label) };
        defer observed.deinit(self.allocator);
        const index = try self.add(.tool, "");
        try self.records.items[index].setCommand(self.allocator, observed, outcome);
    }

    /// Only the currently running call is replaceable; every result owns a row.
    fn pendingCommand(self: *Ui, a: std.mem.Allocator, columns: usize) ![]const u8 {
        const label = try presentation.commandText(a, self.active_tool.?.caption, .pending);
        defer a.free(label);
        return presentation.commandLine(a, label, &.{.{ .start = 0, .end = label.len, .outcome = .pending }}, columns, self.clock_ms);
    }

    /// Only actionable notices/errors use a temporary hint row. Completed,
    /// mode, usage and performance have no rows; the composer owns activity.
    fn hint(self: *Ui, a: std.mem.Allocator, state: Connection.State) ![]const u8 {
        if (self.secret_quarantine) return std.fmt.allocPrint(a, "{s} | Ctrl+U resume; Ctrl+D exit", .{if (std.mem.eql(u8, self.notice, "Saved locally; send a message to connect")) self.notice else "Secret paste drained"});
        if (self.secret_mode) return "Enter save | Ctrl+U erase | Ctrl+C cancel | Ctrl+D exit";
        if (self.model_picker) |picker| return if (picker.pasted) "Pasted selection: Ctrl+U clears; Esc cancels" else "Up/Down select; Enter confirm; Esc/Ctrl+C cancel";
        var notice: []const u8 = "";
        if (self.last_terminal) |result| {
            if (result.status != .success) notice = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ self.notice, if (result.detail != null) ": " else "", if (result.detail) |err| @errorName(err) else "", if (result.model_failure != null) " / " else "", if (result.model_failure) |failure| @tagName(failure) else "" });
        }
        if (notice.len == 0 and !std.mem.eql(u8, self.notice, "Ready") and !std.mem.eql(u8, self.notice, "Running") and !std.mem.eql(u8, self.notice, "Completed")) notice = self.notice;
        if (notice.len == 0 and state.runtime == null) notice = "Not configured: /auth";
        if (state.settings_error) |err| {
            notice = try std.fmt.allocPrint(a, "{s}{s}SETTINGS FAILED: {s}", .{ notice, if (notice.len != 0) " | " else "", @errorName(err) });
        } else if (state.settings_notice) |warning| {
            notice = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ notice, if (notice.len != 0) " | " else "", warning });
        }
        if (state.log_error) |err| return std.fmt.allocPrint(a, "{s}{s}REC FAILED: {s}", .{ notice, if (notice.len != 0) " | " else "", @errorName(err) });
        if (!state.logging_enabled) return std.fmt.allocPrint(a, "{s}{s}recording off", .{ notice, if (notice.len != 0) " | " else "" });
        return notice;
    }

    /// 正文的首个非空增量替换三行思考；迟到的推理不再抢回正文区域。
    fn appendDraft(self: *Ui, kind: Kind, value: []const u8) !void {
        if (value.len == 0) return;
        if (kind == .reasoning and self.draft != null) return;
        if (kind == .assistant) self.discardReasoning();
        const prior = if (kind == .reasoning) self.reasoning else self.draft;
        const index = prior orelse try self.add(kind, "");
        try self.records.items[index].append(self.allocator, value);
        if (kind == .reasoning) self.reasoning = index else self.draft = index;
    }

    /// Canonical visible body replaces the draft. Reasoning is deliberately not
    /// retained in UI history; Runtime protocol history remains untouched.
    fn replaceCommitted(self: *Ui, blocks: []const p.Block, clipped: bool, blocks_complete: bool) !void {
        self.discardReasoning();
        if (self.draft) |i| {
            self.records.items[i].body.clearRetainingCapacity();
            self.records.items[i].clipped = false;
            self.records.items[i].invalidate();
        }
        for (blocks) |block| switch (block) {
            .text => |v| try self.appendDraft(.assistant, v),
            else => {},
        };
        if (clipped) {
            if (self.draft) |i| {
                self.records.items[i].clipped = true;
                self.records.items[i].invalidate();
            }
        }
        if (self.draft) |i| {
            if (self.records.items[i].body.items.len == 0) {
                self.removeRecord(i);
            } else {
                self.records.items[i].final_answer = shared.answer.classify(blocks, blocks_complete) == .final;
            }
        }
        self.draft = null;
    }

    /// 把一个 bridge 事件应用到 UI 状态：追加文本、更新状态、插入审批或工具记录等。
    fn event(self: *Ui, item: bridge_module.Item) !void {
        self.dirty = true;
        self.display.observe(item.event, self.clock_ms);
        switch (item.event) {
            .state => |state| self.mode = state,
            .text => |v| {
                try self.appendDraft(.assistant, v);
                if (item.display_truncated and self.draft != null) {
                    self.records.items[self.draft.?].clipped = true;
                    self.records.items[self.draft.?].invalidate();
                }
            },
            .reasoning => |v| {
                try self.appendDraft(.reasoning, v);
                if (item.display_truncated and self.reasoning != null) {
                    self.records.items[self.reasoning.?].clipped = true;
                    self.records.items[self.reasoning.?].invalidate();
                }
            },
            .assistant_committed => |blocks| {
                try self.captureToolCaptions(blocks);
                try self.replaceCommitted(blocks, item.display_truncated, item.canonical_complete);
            },
            .permission => |permission| {
                self.closeModelPicker();
                // 新审批到来时先释放旧的；粘贴标记沿用到这次请求。
                self.clearPermission();
                self.approval_paste_seen = self.approval_paste_seen or self.parser.pasted;
                self.permission = .{ .id = permission.id, .description = try self.allocator.dupe(u8, permission.description), .clipped = item.display_truncated, .pasted = self.approval_paste_seen };
                self.permission_scroll = 0;
            },
            .tool_started => |tool| {
                self.clearActiveTool();
                self.active_tool = .{ .id = tool.id, .caption = try self.nextToolCaption(tool.name) };
            },
            .tool_result => |tool| {
                // FIFO also covers prepare failures/denials without a start.
                // Raw results stay in Runtime/archives, never UI JSON.
                if (self.active_tool) |active| {
                    if (active.id == tool.id) {
                        try self.toolCompleted(active.caption, tool.result);
                        self.clearActiveTool();
                    }
                } else {
                    const caption = try self.nextToolCaption(tool.name);
                    defer caption.deinit(self.allocator);
                    try self.toolCompleted(caption, tool.result);
                }
            },
            .context_snapshot => {},
            .usage => {},
            .fallback => {
                // Responses 不支持时仅降级一次，之后本进程都使用 Chat。
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
            .finished => {},
            .tool_preview => {},
        }
    }

    fn requestQuit(self: *Ui) void {
        self.ctrl_d_exit = true;
        self.want_exit = true;
        self.parser.stop_feed = true;
        if (self.busy) self.cancel.cancel();
    }
    fn settingsIdle(self: *const Ui) bool {
        return !self.busy and self.future == null and self.permission == null and !self.poisoned and !self.want_exit and !self.secret_mode and !self.secret_quarantine and !self.parser.pasted;
    }
    fn closeModelPicker(self: *Ui) void {
        if (self.model_picker) |*picker| picker.deinit();
        self.model_picker = null;
        self.displayed_model_epoch = null;
        self.displayed_model_generation = null;
    }
    fn openModelPicker(self: *Ui) void {
        self.closeModelPicker();
        self.model_epoch +%= 1;
        self.model_picker = picker_module.Picker.init(self.allocator);
        self.notice = "Select a configured model or type a custom ID";
    }
    fn selectModel(self: *Ui, name: []const u8) !void {
        if (!self.settingsIdle()) return error.Busy;
        // Completed producers have joined and complete() drained every event.
        // A reset error occurs BEFORE configuration publication.
        try self.bridge.reset();
        const before = self.connection.current();
        var inherited = !std.mem.eql(u8, before.model, name);
        for (before.models) |profile| if (std.mem.eql(u8, profile.name, name)) {
            inherited = false;
            break;
        };
        try self.connection.selectModel(name);
        const state = self.connection.current();
        self.display = .{ .context = state.initial_context, .reasoning_effort = state.reasoning_effort };
        self.model_flow = .{};
        self.mode = null;
        self.last_terminal = null;
        self.closeModelPicker();
        self.notice = if (inherited) "Selected for this session; inherited context budget; defaults unchanged" else "Selected for this session; defaults unchanged";
        self.dirty = true;
    }
    fn cycleEffort(self: *Ui) void {
        if (!self.settingsIdle() or self.editor_pasted or self.model_picker != null) {
            self.notice = "Thinking selection requires an idle, non-pasted session";
            return;
        }
        self.bridge.reset() catch {
            self.notice = "Thinking selection requires a drained session bridge";
            return;
        };
        const state = self.connection.current();
        const next = state.effort_levels.next(state.reasoning_effort) orelse {
            self.notice = "Thinking capabilities unknown: declare model reasoning levels in configuration";
            return;
        };
        if (next == state.reasoning_effort.canonical()) {
            self.notice = "This model has no other supported thinking level";
            return;
        }
        self.connection.setEffort(next) catch {
            self.notice = "Could not save thinking option; previous option kept";
            return;
        };
        self.display.setEffort(next);
        self.notice = switch (next) {
            .off, .none => "Thinking request: off (saved for this project)",
            .minimal => "Thinking request: minimal (saved for this project)",
            .low => "Thinking request: low (saved for this project)",
            .medium => "Thinking request: medium (saved for this project)",
            .high => "Thinking request: high (saved for this project)",
            .xhigh => "Thinking request: xhigh (saved for this project)",
            .max => "Thinking request: max (saved for this project)",
            else => unreachable,
        };
        self.dirty = true;
    }
    fn modelKey(self: *Ui, event_: input.Event) !void {
        const picker = &self.model_picker.?;
        switch (event_) {
            .escape, .cancel => {
                self.closeModelPicker();
                self.notice = "Ready";
            },
            .quit => self.requestQuit(),
            .paste_start => {
                picker.pasted = true;
                picker.generation +%= 1;
            },
            .text => |value| {
                if (std.mem.indexOfScalar(u8, value.value, '\n') != null) return;
                if (!try picker.insert(value.value, value.pasted)) self.notice = "Search limit: 1024 bytes";
            },
            .clear => picker.clear(),
            .backspace => {
                picker.query.backspace();
                picker.changed();
            },
            .delete => {
                picker.query.delete();
                picker.changed();
            },
            .left => picker.query.left(),
            .right => picker.query.right(),
            .home => picker.query.cursor = 0,
            .end => picker.query.cursor = picker.query.bytes.items.len,
            .kill_end => {
                picker.query.bytes.items.len = picker.query.cursor;
                picker.changed();
            },
            .up, .down, .page_up, .page_down, .enter => {
                const state = self.connection.current();
                const choices = try picker.choices(self.allocator, state.model, state.context_limit, state.models);
                defer self.allocator.free(choices);
                if (event_ == .enter) {
                    if (picker.pasted or choices.len == 0 or self.displayed_model_epoch != self.model_epoch or self.displayed_model_generation != picker.generation) return;
                    const choice = choices[@min(picker.selected, choices.len - 1)];
                    self.selectModel(choice.name) catch {
                        self.notice = "Could not switch; selection is unchanged";
                    };
                } else picker.move(event_ == .down or event_ == .page_down, choices.len);
            },
            else => {},
        }
    }

    /// 提交当前输入并启动后台任务。忙碀或已 poisoned 时拒绝；提交不排队。
    fn submit(self: *Ui) !void {
        if (self.want_exit) return;
        const command = std.mem.trim(u8, self.editor.bytes.items, " \t\r\n");
        if (modelCommand(command)) {
            if (!self.settingsIdle() or self.editor_pasted) {
                self.wipeEditor();
                self.notice = "Model selection requires an idle, non-pasted session";
                return;
            }
            const name = std.mem.trim(u8, command["/model".len..], " \t");
            if (name.len == 0) {
                self.wipeEditor();
                self.openModelPicker();
            } else if (!picker_module.manualName(name)) {
                self.wipeEditor();
                self.notice = "Usage: /model or /model exact-id (one token)";
            } else {
                self.selectModel(name) catch {
                    self.wipeEditor();
                    self.notice = "Could not switch; selection is unchanged";
                    return;
                };
                self.wipeEditor();
            }
            return;
        }
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
        self.display.reset(self.clock_ms);
        self.clearActiveTool();
        self.clearToolCaptions();
        self.scroll = 0;
        self.editor.clear();
    }

    fn wipeEditor(self: *Ui) void {
        // clear 在 Debug 模式会 poison 原 items；最后再擦除，确保整个保留缓冲区为零。
        self.editor.clear();
        self.editor_pasted = false;
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
                self.requestQuit();
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
        if (self.want_exit) return;
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
                .quit => self.requestQuit(),
                else => {},
            }
            return;
        }

        if (self.model_picker != null and self.permission == null) return self.modelKey(event_);
        switch (event_) {
            .paste_start => {
                self.editor_pasted = true;
                self.blockPastedApproval();
            },
            .text => |v| {
                self.editor_pasted = self.editor_pasted or v.pasted;
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
            .quit => self.requestQuit(),
            .toggle_reasoning => self.show_reasoning = !self.show_reasoning,
            .cycle_effort => self.cycleEffort(),
            .escape => {},
            .page_up, .up => if (self.permission != null) {
                self.permission_scroll -|= if (event_ == .up) 1 else @max(1, @min(7, self.size.rows -| 6));
            } else {
                self.scroll +|= if (event_ == .up) 1 else 10;
            },
            .page_down, .down => if (self.permission != null) {
                self.permission_scroll +|= if (event_ == .down) 1 else @max(1, @min(7, self.size.rows -| 6));
            } else {
                self.scroll -|= if (event_ == .down) 1 else 10;
            },
            .backspace => self.editor.backspace(),
            .delete => self.editor.delete(),
            .left => self.editor.left(),
            .right => self.editor.right(),
            .home => self.editor.cursor = 0,
            .end => self.editor.cursor = self.editor.bytes.items.len,
            .clear => {
                self.editor.clear();
                self.editor_pasted = false;
            },
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
        // Shared state applies owner-produced terminal context after join.
        self.display.finish(self.last_terminal.?, self.clock_ms);
        const result = self.last_terminal.?;

        // 清理失败或无法安全继续时进入 poisoned，禁止再次提交。
        self.poisoned = if (result.detail) |detail| detail == error.CleanupFailed or detail == error.UnsafeToContinue else false;
        self.notice = switch (result.status) {
            .success => "Ready",
            .canceled => "Canceled; prior side effects remain",
            .failed => "Failed",
        };

        // 任务结束时仍未收到 canonical 内容的草稿，标记为中断。
        if (self.draft) |i| self.records.items[i].interrupted = true;
        self.discardReasoning();
        self.draft = null;
        self.clearActiveTool();
        self.clearToolCaptions();
        self.mode = null;
        self.dirty = true;
    }

    /// 主事件循环：分批消费 bridge 事件、读取按键、分段写出帧、按节流重绘；满足退出条件时返回退出码。
    fn loop(self: *Ui) !u8 {
        var last_draw = Io.Clock.awake.now(self.io);
        var buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        while (true) {
            self.clock_ms = @intCast(@max(0, Io.Clock.awake.now(self.io).toMilliseconds()));
            if (self.busy and self.animation_tick != self.clock_ms / 80) {
                self.animation_tick = self.clock_ms / 80;
                self.dirty = true;
            }
            // 每轮最多处理 64 个事件，避免大量输出阻塞输入与绘制。
            for (0..64) |_| {
                var item = self.bridge.pop() orelse break;
                defer item.deinit();
                try self.event(item);
            }

            // acquire 与 worker 的 release 配对，确保读到任务结果。
            if (self.busy and self.job.done.load(.acquire)) try self.complete();
            if (!self.log_warning_seen and self.connection.current().log_error != null) {
                self.log_warning_seen = true;
                // 记录故障有独立临时hint，不改变Runtime任务结果。
                if (self.last_terminal == null) self.notice = "Session recording failed; records may be incomplete";
                self.dirty = true;
            }

            // 收到信号（如 SIGINT）：转为退出请求并取消任务。
            if (interrupt.signal() != 0) {
                self.want_exit = true;
                self.cancel.cancel();
            }

            // 任务结束后才真正退出；若由信号触发，退出码为 128 + 信号编号。
            if (self.want_exit and !self.busy) {
                try self.drainExit();
                return if (interrupt.signal() != 0) 128 + interrupt.signal() else 0;
            }

            const dimensions = self.terminal.size();
            self.resize(dimensions);

            // 读取终端输入交给 parser；n == 0 表示本轮无输入。
            const n = try self.terminal.read(&buffer);
            if (n > 0) {
                defer std.crypto.secureZero(u8, &buffer);
                self.last_input_ms = self.clock_ms;
                try self.parser.feed(buffer[0..n], .{ .context = self, .emit_fn = key });
            } else if (self.clock_ms -| self.last_input_ms >= 150) {
                try self.parser.expireEscape(.{ .context = self, .emit_fn = key });
            }

            // 分段写出待输出的帧：终端可能只接受部分字节，剩余部分在下一轮继续。
            if (self.frame_offset < self.frame.len) {
                try self.writeFrame();
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

    fn resize(self: *Ui, dimensions: terminal_module.Size) void {
        if (dimensions.columns == self.size.columns and dimensions.rows == self.size.rows) return;
        self.size = dimensions;
        self.displayed_permission = null;
        self.displayed_model_epoch = null;
        self.displayed_model_generation = null;
        self.frame_fresh = false;
        if (self.frame.len != 0 and (self.frame_offset < self.frame_clear_end or self.resize_rescue.len != 0)) {
            // Never finish an old CUU/EL reclaim after reflow. Cancel a partial
            // escape and continue transcript/tail at a fresh bottom line instead.
            self.frame_offset = self.frame_clear_end;
            self.resize_rescue = "\x18\x1b[999B\r\n";
        }
        self.abandon_tail = self.tail_height != 0 or self.frame.len != 0;
        self.dirty = true;
    }

    fn writeFrame(self: *Ui) !void {
        if (self.resize_rescue.len != 0) {
            const n = try self.terminal.write(self.resize_rescue);
            self.resize_rescue = self.resize_rescue[n..];
            if (self.resize_rescue.len != 0) return;
        }
        self.frame_offset += try self.terminal.write(self.frame[self.frame_offset..]);
        if (self.frame_offset == self.frame.len) self.finishFrame();
    }

    fn finishFrame(self: *Ui) void {
        // Resize invalidation is sticky, even if the window returns to its old size.
        self.displayed_permission = if (self.frame_fresh) self.frame_permission else null;
        self.displayed_model_epoch = if (self.frame_fresh) self.frame_model_epoch else null;
        self.displayed_model_generation = if (self.frame_fresh) self.frame_model_generation else null;
        self.tail_height = self.frame_height;
        self.tail_size = self.frame_size;
        for (self.records.items) |*record| {
            if (record.pending_output) record.output = true;
            record.pending_output = false;
        }
        if (self.frame_arena) |*arena| arena.deinit();
        self.frame_arena = null;
        self.frame = "";
        self.frame_offset = 0;
        self.resize_rescue = "";
    }

    /// Exit gets a bounded chance to publish the final canonical reply, never an infinite drain.
    fn drainExit(self: *Ui) !void {
        const start = Io.Clock.awake.now(self.io);
        for (0..128) |_| {
            self.resize(self.terminal.size());
            if (self.frame.len == 0) {
                if (!self.dirty) return;
                try self.draw();
                self.dirty = false;
            }
            try self.writeFrame();
            if (start.untilNow(self.io, .awake).toMilliseconds() >= 200) return;
            if (self.frame.len != 0) try self.terminal.wait(true, 2);
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
        const cols = self.size.columns -| 1; // Never trigger terminal autowrap.
        var out: std.Io.Writer.Allocating = .init(a);
        const writer = &out.writer;
        self.displayed_permission = null;
        self.frame_permission = null;

        // Reclaim only our last complete live tail, never the user's earlier rows.
        try writer.writeAll("\x1b[?25l\r");
        if (self.abandon_tail or (self.tail_height != 0 and
            (self.tail_size.columns != self.size.columns or self.tail_size.rows != self.size.rows)))
        {
            try writer.writeAll("\x1b[999B\r\n");
        } else if (self.tail_height != 0) {
            if (self.tail_height > 1) try writer.print("\x1b[{d}A", .{self.tail_height - 1});
            for (0..self.tail_height) |line| {
                if (line != 0) try writer.writeAll("\r\n");
                try writer.writeAll("\x1b[0m\x1b[2K");
            }
            // No LF after the last erased row: that would scroll before CUU.
            if (self.tail_height > 1) try writer.print("\x1b[{d}A", .{self.tail_height - 1});
            try writer.writeAll("\r");
        }

        self.frame_clear_end = out.written().len;

        // Commit each finalized record once. Live Markdown/reasoning remains a
        // replaceable preview until canonical commit; model ANSI is never emitted.
        var lines: std.ArrayList([]const u8) = .empty;
        const preview = self.scroll != 0;
        var transcript_rows: usize = 0;
        var previous_kind: ?Kind = null;
        for (self.records.items, 0..) |*record, index| {
            if (record.kind == .reasoning) continue;
            const drafting = self.draft == index;
            try record.layout(self.allocator, @max(1, cols));
            const heading = if (record.interrupted) "Interrupted response — preview" else if (record.excerpt) "Display excerpt" else "";
            if (cols >= 8 and !record.output and !drafting) {
                // Leading gaps work even when the prior command was committed
                // in an earlier frame. Tool -> tool is always contiguous.
                if (previous_kind) |prior| if (prior != .tool or record.kind != .tool) {
                    try writer.writeAll("\r\n");
                    transcript_rows += 1;
                };
                if (heading.len != 0) {
                    try putToneLine(writer, a, 1, heading, cols, theme.muted);
                    try writer.writeAll("\r\n");
                    transcript_rows += 1;
                }
                for (record.lines) |line| {
                    try putStyled(writer, 1, line);
                    try writer.writeAll("\r\n");
                    transcript_rows += 1;
                }
                record.pending_output = true;
            }
            if (preview or drafting) {
                if (previous_kind) |prior| if (prior != .tool or record.kind != .tool) try lines.append(a, "");
                if (heading.len != 0) {
                    const headings = try markdown.render(a, heading, .{ .columns = @max(1, cols), .max_lines = 32, .markdown = false, .tone = .muted });
                    try lines.appendSlice(a, headings.lines);
                }
                try lines.appendSlice(a, record.lines);
            }
            previous_kind = record.kind;
        }
        if (!preview and self.active_tool != null) {
            if (previous_kind) |prior| if (prior != .tool) try lines.append(a, "");
            try lines.append(a, try self.pendingCommand(a, @max(1, cols)));
        }
        const thinking = if (self.show_reasoning and !preview and self.draft == null) self.reasoning else null;
        var thinking_lines: []const []const u8 = &.{};
        if (thinking) |index| {
            const record = &self.records.items[index];
            try record.layout(self.allocator, @max(1, cols));
            thinking_lines = record.lines[record.lines.len -| 3..];
        }
        // Transient reasoning follows the transcript without committing a gap
        // or reasoning text to scrollback. Its gap does not consume the latest3.
        const thinking_gap: usize = @intFromBool(thinking != null and thinking_lines.len != 0 and previous_kind != null);
        // A live draft already has one leading gap in lines. Keep it outside
        // the scrollable slice so a long draft cannot clip it next to the user.
        const live_gap: usize = @intFromBool(!preview and lines.items.len != 0 and lines.items[0].len == 0);
        const secret_destination = if (self.secret_mode) blk: {
            const state = self.connection.current();
            break :blk try std.fmt.allocPrint(a, "API key for model {s}\nBase URL: {s}\nEnter saves locally; no network request is made here", .{ state.model, state.base_url });
        } else "";
        const secret_lines = try markdown.render(a, secret_destination, .{ .columns = @max(1, cols), .max_lines = 8, .markdown = false });
        const state = self.connection.current();
        // App-prepared immutable value, including local /auth activation.
        // Draw never dereferences Runtime, not even a fixture/idle pointer.
        self.display.seed(state.initial_context);
        self.display.setEffort(state.reasoning_effort);
        const hint_line = try self.hint(a, state);
        // Always reserve one EMPTY row between conversation and composer.
        const footer_rows: usize = 2 + @as(usize, @intFromBool(hint_line.len != 0));
        const body_limit = self.size.rows -| footer_rows;
        const picker_rows = if (self.model_picker) |*picker| try picker.rows(a, state.model, state.context_limit, state.models, cols, body_limit) else picker_module.Rows{ .lines = &.{}, .can_confirm = false };
        self.frame_model_epoch = null;
        self.frame_model_generation = null;
        const wanted_body = if (self.permission) |permission|
            @min(body_limit, 1 + @max(1, (try markdown.render(a, permission.description, .{ .columns = @max(1, cols), .max_lines = 8192, .markdown = false })).lines.len))
        else if (self.secret_mode) secret_lines.lines.len else if (self.model_picker != null) picker_rows.lines.len else if (thinking != null) @min(thinking_gap + @min(3, thinking_lines.len), body_limit) else @min(lines.items.len, body_limit);
        // Initial blank space keeps the first conversation at the top. Each
        // immutable row consumes it; expanding drafts scroll old content upward.
        // Never shrink a tail without replacing it by committed rows: the editor
        // therefore stays on the physical bottom row, without absolute positioning.
        const available = if (self.tail_height == 0 or self.abandon_tail) self.size.rows else self.tail_height;
        const rows = @min(self.size.rows, @max(footer_rows + wanted_body, available -| transcript_rows));

        // 终端太小时只显示提示，避免布局越界。
        // 审批标题之外至少留一行正文；尺寸不足不属于永久的 clipped 状态。
        const hides_approval_id = if (self.permission) |permission| !self.approvalFits(permission.id) else false;
        if (self.size.rows < 7 or cols < 8 or hides_approval_id) {
            for (0..rows) |row| try putLine(writer, a, row + 1, if (row == 0) "Resize terminal" else "", cols);
            try writer.writeAll("\r\x1b[?25h");
            self.frame_permission = null;
        } else {
            const body_rows = rows - footer_rows;
            if (self.secret_mode) {
                for (0..body_rows) |line| try putStyled(writer, 1 + line, if (line < secret_lines.lines.len) secret_lines.lines[line] else "");
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
                try putToneLine(writer, a, 1, title, cols, theme.accent);

                // 滚动位置限制在内容末尾，防止滚出空白区域。
                const start = @min(self.permission_scroll, all.lines.len -| (body_rows - 1));
                for (0..body_rows - 1) |line| try putStyled(writer, 2 + line, if (start + line < all.lines.len) all.lines[start + line] else "");
                self.frame_permission = permission.id;
            } else if (self.model_picker) |picker| {
                for (0..body_rows) |line| try putLine(writer, a, 1 + line, if (line < picker_rows.lines.len) picker_rows.lines[line] else "", cols);
                self.frame_permission = null;
                if (picker_rows.can_confirm and picker_rows.lines.len <= body_rows) {
                    self.frame_model_epoch = self.model_epoch;
                    self.frame_model_generation = picker.generation;
                }
            } else if (thinking != null) {
                // Latest THREE content rows, without any title/prefix.
                const visible_rows = @min(3, body_rows -| thinking_gap);
                const start = thinking_lines.len -| visible_rows;
                for (0..body_rows) |line| {
                    const index = line -| thinking_gap;
                    try putStyled(writer, 1 + line, if (line >= thinking_gap and index < visible_rows and start + index < thinking_lines.len) thinking_lines[start + index] else "");
                }
                self.frame_permission = null;
            } else {
                // 有界 live draft / retained history preview，不重写终端滚屏。
                // 从底部向上回退 scroll 行，得到显示窗口的结束位置。
                const content = lines.items[live_gap..];
                const content_rows = body_rows -| live_gap;
                const end = content.len -| @min(self.scroll, content.len -| content_rows);
                const start = end -| content_rows;
                for (0..body_rows) |line| {
                    const index = line -| live_gap;
                    try putStyled(writer, 1 + line, if (line >= live_gap and start + index < end) content[start + index] else "");
                }
                self.frame_permission = null;
            }

            if (hint_line.len != 0) try putToneLine(writer, a, rows - 2, hint_line, cols, theme.muted);
            try putLine(writer, a, rows - 1, "", cols);

            if (self.secret_mode or self.secret_quarantine) {
                // Only a bounded mask is copied to the frame; never format secret bytes.
                const masks: [64]u8 = @splat('*');
                const count = @min(self.secret.len, @min(masks.len, cols - 3));
                const masked = try std.fmt.allocPrint(a, "API key> {s}", .{masks[0..count]});
                try putLine(writer, a, rows, masked, cols);
                try writer.print("\r\x1b[{d}C\x1b[?25h", .{@min(cols, count + 10) - 1});
            } else if (self.model_picker) |picker| {
                const decorated = "Search> ";
                const prefix = try editorDisplay(a, picker.query.bytes.items[0..picker.query.cursor]);
                var start: usize = 0;
                var width = text.width(prefix);
                while (width > cols -| (decorated.len + 1) and start < prefix.len) {
                    const cluster = text.nextCluster(prefix, start, 0);
                    width -|= cluster.width;
                    start = cluster.end;
                }
                const suffix = try editorDisplay(a, picker.query.bytes.items[picker.query.cursor..]);
                const end = fittingBytes(suffix, cols -| (decorated.len + width));
                const line = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ decorated, prefix[start..], suffix[0..end] });
                try putLine(writer, a, rows, line, cols);
                try writer.print("\r\x1b[{d}C\x1b[?25h", .{@min(cols, decorated.len + width + 1) - 1});
            } else {

                // 光标所在逻辑行的起点（以换行为界）。
                // Slash arguments can be accidental credentials: never render them, even before Enter.
                const trimmed = std.mem.trimStart(u8, self.editor.bytes.items, " \t\r\n");
                const safe_model = modelCommand(trimmed) and picker_module.manualName(std.mem.trim(u8, trimmed["/model".len..], " \t"));
                const hide_arguments = !safe_model and std.mem.startsWith(u8, trimmed, "/") and (std.mem.findScalar(u8, trimmed, ' ') != null or std.mem.findScalar(u8, trimmed, '\t') != null or std.mem.findScalar(u8, trimmed, '\r') != null or std.mem.findScalar(u8, trimmed, '\n') != null);
                const visible: []const u8 = if (hide_arguments) "/auth [arguments hidden; no key argument]" else self.editor.bytes.items;
                const cursor = if (hide_arguments) visible.len else self.editor.cursor;
                const begin = if (std.mem.findScalarLast(u8, visible[0..cursor], '\n')) |index| index + 1 else 0;
                const working = self.busy or self.mode != null or self.active_tool != null;
                const view = self.display.view(self.clock_ms);
                self.model_flow.advance(self.clock_ms, working, view.live_tps_tenths);
                const decoration = try presentation.prompt(a, state.model, view.context, cols, .{ .busy = working, .now_ms = self.clock_ms, .phase = self.model_flow.step(), .rate_band = view.rate_band, .reasoning_effort = view.reasoning_effort });
                const decoration_width = text.width(decoration.plain);
                const prefix = try editorDisplay(a, visible[begin..cursor]);
                var start: usize = 0;
                var width = text.width(prefix);
                // 输入过长时从左侧裁剪，保证光标所在位置可见。
                while (width > cols -| (decoration_width + 1) and start < prefix.len) {
                    const cluster = text.nextCluster(prefix, start, 0);
                    width -|= cluster.width;
                    start = cluster.end;
                }
                const tail = visible[cursor..];
                const suffix = try editorDisplay(a, tail[0..(std.mem.findScalar(u8, tail, '\n') orelse tail.len)]);
                const suffix_end = fittingBytes(suffix, cols -| (decoration_width + width));
                // Only model letters carry SGR; marker/editor are default colors.
                const input_line = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ decoration.styled, prefix[start..], suffix[0..suffix_end] });
                try putStyled(writer, rows, input_line);

                // Decoration participates in clipping AND cursor positioning;
                // editing/submitted raw bytes remain untouched.
                try writer.print("\r\x1b[{d}C\x1b[?25h", .{@min(cols, width + decoration_width + 1) - 1});
            }
        }

        // frame 指向 arena 内存，arena 所有权交给 frame_arena，直到这帧写完。
        self.frame = out.written();
        self.frame_offset = 0;
        self.frame_arena = arena;
        self.frame_height = rows;
        self.frame_size = self.size;
        self.frame_fresh = true;
        self.abandon_tail = false;
    }
};

fn modelCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "/model") or std.mem.startsWith(u8, command, "/model ") or std.mem.startsWith(u8, command, "/model\t");
}

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

fn fittingBytes(bytes: []const u8, columns: usize) usize {
    var at: usize = 0;
    var cells: usize = 0;
    while (at < bytes.len) {
        const cluster = text.nextCluster(bytes, at, cells);
        if (cells + cluster.width > columns) break;
        cells += cluster.width;
        at = cluster.end;
    }
    return at;
}

/// 顺序输出一行；row 只区别首行是否换行，不是绝对坐标。清理自身行并复位样式。
fn putStyled(writer: *Io.Writer, row: usize, line: []const u8) !void {
    if (row > 1) try writer.writeAll("\r\n");
    try writer.print("\x1b[0m\x1b[2K{s}\x1b[0m", .{line});
}

/// 按终端列宽截断一行后输出：先清理控制字符，再按字素簇累计显示宽度，超出列宽即停止。
fn putLine(writer: *Io.Writer, a: std.mem.Allocator, row: usize, line: []const u8, columns: usize) !void {
    try putToneLine(writer, a, row, line, columns, "");
}

fn putToneLine(writer: *Io.Writer, a: std.mem.Allocator, row: usize, line: []const u8, columns: usize, tone: []const u8) !void {
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
    const styled = try std.fmt.allocPrint(a, "{s}{s}", .{ tone, safe[0..pos] });
    try putStyled(writer, row, styled);
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

test "regular transcript starts at top and keeps composer at bottom without role tags" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "unique committed user");
    try ui.appendDraft(.assistant, "uncanonical draft");
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique committed user") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Streaming") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "History preview") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "[user]") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "[assistant") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.user_background) != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    try std.testing.expect(std.mem.find(u8, &screen.grid[0], "unique committed user") != null);
    try std.testing.expect(!ui.records.items[0].output);
    try std.testing.expectEqual(@as(usize, 23), ui.frame_height); // One committed user row, no trailing gap.
    ui.finishFrame();
    try std.testing.expect(ui.records.items[0].output);
    try std.testing.expect(!ui.records.items[1].output);
    try ui.replaceCommitted(&.{.{ .text = "unique canonical reply" }}, false, true);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique committed user") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "uncanonical draft") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique canonical reply") != null);
    try std.testing.expectEqual(@as(usize, 21), ui.frame_height); // Leading gap + canonical body, no title.
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.finishFrame();
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    try std.testing.expectEqual(@as(usize, 1), screen.count("unique canonical reply"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique canonical reply") == null);
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, "\x1b[?25l\r\x1b[20A"));
    for ([_][]const u8{ "1049", "1047", "\x1b[H", "\x1b[2J", ";1H" }) |forbidden|
        try std.testing.expect(std.mem.find(u8, ui.frame, forbidden) == null);
}

test "growing a compact live tail keeps replaceable drafts out of scrollback" {
    for ([_]bool{ false, true }) |same_final| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        var old: std.ArrayList(u8) = .empty;
        defer old.deinit(std.testing.allocator);
        for (0..20) |_| try old.appendSlice(std.testing.allocator, "older-row\n");
        try old.appendSlice(std.testing.allocator, "last-older-row");
        _ = try ui.add(.assistant, old.items);
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try ui.draw();
        try screen.replay(ui.frame);
        ui.finishFrame();
        try std.testing.expectEqual(@as(usize, 3), ui.tail_height);
        try std.testing.expectEqual(@as(usize, 23), screen.row);

        try ui.appendDraft(.assistant, "growth-draft-marker\nsecond-draft-line");
        try ui.draw();
        try screen.replay(ui.frame);
        ui.finishFrame();
        try std.testing.expectEqual(@as(usize, 6), ui.tail_height); // Gap + two draft rows + hinted footer; no preview-title row.
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        for (screen.history[0..screen.history_len]) |line| try std.testing.expect(std.mem.find(u8, &line, "growth-draft-marker") == null);

        try ui.replaceCommitted(&.{.{ .text = if (same_final) "growth-draft-marker" else "different-final-marker" }}, false, true);
        try ui.draw();
        try screen.replay(ui.frame);
        ui.finishFrame();
        try std.testing.expectEqual(@as(usize, @intFromBool(same_final)), screen.count("growth-draft-marker"));
        try std.testing.expectEqual(@as(usize, @intFromBool(!same_final)), screen.count("different-final-marker"));
        try std.testing.expectEqual(@as(usize, 0), screen.count("second-draft-line"));
        try std.testing.expectEqual(@as(usize, 23), screen.row);
    }
}

/// Check actual retained rows, including user output pushed into scrollback.
fn expectTranscriptGap(screen: *const @import("../tests/regular_screen.zig").Screen, before: []const u8, after: []const u8) !void {
    var first: ?usize = null;
    var second: ?usize = null;
    for (0..screen.history_len + screen.grid.len) |i| {
        const line = if (i < screen.history_len) &screen.history[i] else &screen.grid[i - screen.history_len];
        if (first == null and std.mem.indexOf(u8, line, before) != null) first = i;
        if (second == null and std.mem.indexOf(u8, line, after) != null) second = i;
    }
    try std.testing.expect(first != null and second != null);
    try std.testing.expectEqual(first.? + 2, second.?);
    const gap = first.? + 1;
    const line = if (gap < screen.history_len) &screen.history[gap] else &screen.grid[gap - screen.history_len];
    for (line) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
}

test "user thinking short long and canonical replies keep one gap without preview titles" {
    for ([_]usize{ 80, 20 }) |columns| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.size.columns = columns;
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        _ = try ui.add(.user, "user-row-one\nuser-row-end");
        try ui.appendDraft(.reasoning, "old-think\nthink-first\nthink-second\nthink-last");
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "think-first");
        for ([_][]const u8{ "think-first", "think-second", "think-last" }) |marker| try std.testing.expect(screen.visible(marker));
        try std.testing.expect(!screen.visible("old-think"));
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        ui.finishFrame();
        try ui.appendDraft(.reasoning, "\nthink-new\nthink-new-last");
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "think-last");
        ui.finishFrame();
        try ui.appendDraft(.assistant, "live-start\nlive-end");
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "live-start");
        try std.testing.expectEqual(@as(usize, 0), screen.count("think-"));
        try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Streaming") == null);
        try std.testing.expect(std.mem.indexOf(u8, ui.frame, "History preview") == null);
        ui.finishFrame();
        // Clipping the start of a long live draft cannot consume its leading gap.
        for (0..60) |i| {
            const delta = try std.fmt.allocPrint(std.testing.allocator, "\nlive-line-{d}", .{i});
            defer std.testing.allocator.free(delta);
            try ui.appendDraft(.assistant, delta);
        }
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "live-line-");
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        ui.finishFrame();
        try ui.replaceCommitted(&.{.{ .text = "formal-final" }}, false, true);
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "formal-final");
        try std.testing.expectEqual(@as(usize, 1), screen.count("formal-final"));
        try std.testing.expectEqual(@as(usize, 0), screen.count("live-line-"));
        try std.testing.expectEqual(@as(usize, 1), screen.count("user-row-end"));
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        ui.finishFrame();
    }
}

test "thinking scrolls in three rows and body replaces it without retaining reasoning" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.appendDraft(.reasoning, "think-one\nthink-two\nthink-three\nthink-four");
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("think-one"));
    for ([_][]const u8{ "think-two", "think-three", "think-four" }) |marker| try std.testing.expect(screen.visible(marker));
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.finishFrame();
    try std.testing.expect(!ui.records.items[0].output);
    try ui.appendDraft(.reasoning, "\nthink-five\nthink-six");
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("think-two") and !screen.visible("think-three"));
    for ([_][]const u8{ "think-four", "think-five", "think-six" }) |marker| try std.testing.expect(screen.visible(marker));
    for (screen.history[0..screen.history_len]) |line| try std.testing.expect(std.mem.find(u8, &line, "think-") == null);
    ui.finishFrame();

    try ui.appendDraft(.assistant, "partial-answer\x1b[2J");
    try ui.appendDraft(.reasoning, "late-reasoning");
    try std.testing.expect(ui.reasoning == null);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("Thinking"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("think-"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("late-reasoning"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
    ui.finishFrame();
    const draft = ui.draft.?;
    try std.testing.expect(!ui.records.items[draft].output);
    // Cancellation keeps only the unfinished visible answer, explicitly marked.
    ui.records.items[draft].interrupted = true;
    ui.draft = null;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("Interrupted response"));
    ui.finishFrame();
    ui.scroll = 1;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "History preview") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "think-") == null);
    ui.finishFrame();
}

test "rolling thinking keeps latest bounded UTF8 suffix and can be hidden" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const large = try std.testing.allocator.alloc(u8, 3 * (record_limit / 3 + 10));
    defer std.testing.allocator.free(large);
    for (0..large.len / 3) |i| @memcpy(large[i * 3 ..][0..3], "你");
    try ui.appendDraft(.reasoning, large);
    try ui.appendDraft(.reasoning, "\nnewest-thinking");
    const record = &ui.records.items[ui.reasoning.?];
    try std.testing.expect(record.body.items.len <= record_limit);
    try std.testing.expect(record.clipped);
    try std.testing.expect(std.unicode.utf8ValidateSlice(record.body.items));
    try std.testing.expect(std.mem.endsWith(u8, record.body.items, "newest-thinking"));
    ui.show_reasoning = false;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "newest-thinking") == null);
    ui.finishFrame();
    ui.show_reasoning = true;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "newest-thinking") != null);
    ui.finishFrame();
    ui.discardReasoning(); // Same cancellation cleanup as complete.
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "newest-thinking") == null);
    ui.finishFrame();
}

test "tool animation is transient and raw tool JSON never enters displayed records" {
    for ([_][]const u8{ "memory", "bash", "read_file", "write_file" }) |name| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.mode = .executing_tool;
        const host = bridge.host();
        const arguments = if (std.mem.eql(u8, name, "bash")) "{\"command\":\"date\"}" else if (std.mem.eql(u8, name, "memory")) "{\"action\":\"read\",\"topic\":\"core\"}" else "{\"path\":\"src/example.zig\"}";
        try ui.captureToolCaptions(&.{.{ .tool_call = .{ .id = "fixture-call", .name = name, .arguments = arguments } }});
        try host.emit_fn(host.context, .{ .tool_started = .{ .id = 7, .name = name } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, activity.spinner(0)) != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, if (std.mem.eql(u8, name, "bash")) "date" else if (std.mem.eql(u8, name, "memory")) "read core" else "src/example.zig") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, theme.command_pulse[0] ++ "⠋" ++ theme.muted) != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "#7") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "Running memory") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "Running bash") == null);
        ui.finishFrame();
        ui.clock_ms = 120;
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, activity.spinner(120)) != null);
        ui.finishFrame();
        try host.emit_fn(host.context, .{ .tool_preview = .{ .index = 0, .arguments = "{\"hidden-tool-argument\":1}" } }, &cancel);
        item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try host.emit_fn(host.context, .{ .tool_result = .{ .id = 7, .name = name, .result = .{ .text = "{\"hidden-tool-output\":1}" } } }, &cancel);
        item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try std.testing.expect(ui.active_tool == null);
        try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
        try ui.replaceCommitted(&.{.{ .text = "{\"requested-answer\":1}" }}, false, true);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "hidden-tool-") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "requested-answer") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "completed") == null);
        ui.finishFrame();
    }
}

test "first pending tool follows user gap then tools stay contiguous" {
    for ([_][]const u8{ "bash", "read_file", "write_file", "memory" }) |name| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        _ = try ui.add(.user, "tool-user-end");
        try ui.draw();
        try screen.replay(ui.frame);
        ui.finishFrame();
        const args = if (std.mem.eql(u8, name, "bash")) "{\"command\":\"target-one\"}" else if (std.mem.eql(u8, name, "memory")) "{\"action\":\"read\",\"topic\":\"target-one\"}" else "{\"path\":\"target-one\"}";
        try ui.captureToolCaptions(&.{.{ .tool_call = .{ .id = "gap-one", .name = name, .arguments = args } }});
        ui.active_tool = .{ .id = 1, .caption = try ui.nextToolCaption(name) };
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "tool-user-end", "target-one");
        ui.finishFrame();
        try ui.toolCompleted(ui.active_tool.?.caption, .{ .text = "{}" });
        ui.clearActiveTool();
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "tool-user-end", "target-one");
        ui.finishFrame();
        const second: presentation.Caption = .{ .kind = .read, .label = "target-two" };
        ui.active_tool = .{ .id = 2, .caption = .{ .kind = .read, .label = try std.testing.allocator.dupe(u8, second.label) } };
        try ui.draw();
        try screen.replay(ui.frame);
        var first_row: ?usize = null;
        var second_row: ?usize = null;
        for (screen.grid, 0..) |line, row| {
            if (std.mem.indexOf(u8, &line, "target-one") != null) first_row = row;
            if (std.mem.indexOf(u8, &line, "target-two") != null) second_row = row;
        }
        try std.testing.expect(first_row != null and second_row != null);
        try std.testing.expectEqual(first_row.? + 1, second_row.?);
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        ui.finishFrame();
    }
}

test "same batch bash calls own contiguous pending and result rows with FIFO labels" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .assistant_committed = &.{
        .{ .tool_call = .{ .id = "one", .name = "bash", .arguments = "{\"command\":\"date\"}" } },
        .{ .tool_call = .{ .id = "two", .name = "bash", .arguments = "{\"command\":\"pwd\"}" } },
    } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    // A preparation failure without started consumes only its own caption.
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 1, .name = "bash", .result = .{ .text = "hidden-error-json", .is_error = true } } }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try host.emit_fn(host.context, .{ .tool_started = .{ .id = 2, .name = "bash" } }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expectEqualStrings("pwd", ui.active_tool.?.caption.label);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    var failed_row: ?usize = null;
    var pending_row: ?usize = null;
    for (screen.grid, 0..) |line, row| {
        if (std.mem.find(u8, &line, "date [error]") != null) failed_row = row;
        if (std.mem.find(u8, &line, "pwd") != null) pending_row = row;
    }
    try std.testing.expect(failed_row != null and pending_row != null);
    try std.testing.expectEqual(failed_row.? + 1, pending_row.?);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.finishFrame();
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 2, .name = "bash", .result = .{ .text = "hidden-output-json" } } }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("> date [error]", ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("> pwd", ui.records.items[1].body.items);
    try ui.draw();
    try std.testing.expect(ui.records.items[0].output);
    try std.testing.expect(!ui.records.items[0].pending_output);
    try std.testing.expect(ui.records.items[1].pending_output);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items[0].lines.len);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items[1].lines.len);
    try std.testing.expect(std.mem.find(u8, ui.frame, " date [error]") == null); // The previous result is not rewritten.
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.reset ++ ">" ++ theme.muted ++ " pwd") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "hidden-") == null);
    try screen.replay(ui.frame);
    failed_row = null;
    pending_row = null;
    for (screen.grid, 0..) |line, row| {
        if (std.mem.find(u8, &line, "date [error]") != null) failed_row = row;
        if (std.mem.find(u8, &line, "> pwd") != null) pending_row = row;
    }
    try std.testing.expect(failed_row != null and pending_row != null);
    try std.testing.expectEqual(failed_row.? + 1, pending_row.?);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.finishFrame();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, " date [error]") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, " pwd") == null);
}

test "incomplete canonical block tails cannot publish a false final heading" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var blocks: [bridge_module.block_limit + 1]p.Block = @splat(.{ .text = "" });
    blocks[0] = .{ .text = "intermediate-body" };
    blocks[bridge_module.block_limit] = .{ .tool_call = .{ .id = "tail-tool", .name = "bash", .arguments = "{\"command\":\"pwd\"}" } };
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .assistant_committed = &blocks }, &cancel);
    var item = bridge.pop().?;
    defer item.deinit();
    try std.testing.expect(item.display_truncated and !item.canonical_complete);
    try ui.event(item);
    try std.testing.expect(!ui.records.items[0].final_answer);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Final answer") == null);
    ui.finishFrame();
}

test "tool only reasoning only and empty canonical bodies remove a previously visible draft" {
    for ([_]p.Block{
        .{ .tool_call = .{ .id = "id", .name = "bash", .arguments = "{}" } },
        .{ .reasoning = "not-visible-canonical" },
        .{ .text = "" },
    }) |block| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        _ = try ui.add(.user, "retained-user");
        try ui.appendDraft(.assistant, "provisional-body");
        try ui.draw();
        ui.finishFrame();
        try ui.replaceCommitted(&.{block}, false, true);
        try std.testing.expect(ui.draft == null and ui.records.items.len == 1);
        try std.testing.expectEqual(Kind.user, ui.records.items[0].kind);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "Final answer") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "provisional-body") == null);
        ui.finishFrame();
    }
}

test "file captions are contiguous but separated from final prose and percent context changes by value" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const cap = try presentation.caption(std.testing.allocator, "write_file", "{\"path\":\"src/main.zig\",\"content\":\"do-not-show-body\"}");
    defer cap.deinit(std.testing.allocator);
    try ui.toolCompleted(cap, .{ .text = "raw-json-must-stay-hidden", .file_stats = .{ .changes = .{ .modified = 1, .added = 2, .removed = 3 } } });
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .context_snapshot = .{ .tokens = 16384, .limit = 32768 } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.replaceCommitted(&.{.{ .text = "final-body-marker" }}, false, true);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "w" ++ theme.muted ++ " src/main.zig  ~1 " ++ theme.diff_added ++ "+2" ++ theme.muted ++ " " ++ theme.diff_removed ++ "-3" ++ theme.muted ++ " lines") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "raw-json-must-stay-hidden") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "do-not-show-body") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "(fixture 50.0%) > ") != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("Final answer") and screen.visible("final-body-marker"));
    for (screen.grid[1]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.finishFrame();
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 0), screen.count("=> Final answer"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("final-body-marker"));
    ui.finishFrame();
}

test "sequential tool records from different frames have no gaps then final prose has one gap" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    for ([_][]const u8{ "one.txt", "two.txt", "three.txt" }, 0..) |path, i| {
        const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
        defer std.testing.allocator.free(args);
        const caption = try presentation.caption(std.testing.allocator, "read_file", args);
        defer caption.deinit(std.testing.allocator);
        try ui.toolCompleted(caption, .{ .text = "hidden-result", .file_stats = .{ .read = 1 } });
        try ui.draw();
        try screen.replay(ui.frame);
        try std.testing.expect(std.mem.find(u8, &screen.grid[i], path) != null);
        ui.finishFrame();
    }
    try ui.replaceCommitted(&.{.{ .text = "answer-without-heading" }}, false, true);
    try ui.draw();
    try screen.replay(ui.frame);
    for (screen.grid[3]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
    try std.testing.expect(std.mem.find(u8, &screen.grid[4], "answer-without-heading") != null);
    try std.testing.expectEqual(@as(usize, 0), screen.count("Final answer"));
    ui.finishFrame();
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 1), screen.count("answer-without-heading"));
    for ([_][]const u8{ "one.txt", "two.txt", "three.txt" }) |path| try std.testing.expectEqual(@as(usize, 1), screen.count(path));
    ui.finishFrame();
}

test "configured effort colors idle prefix before reasoning but never the busy marker" {
    const Owner = struct {
        effort: shared.ReasoningEffort,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var state = FixtureConnection.current(raw);
            state.reasoning_effort = self.effort;
            return state;
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var owner: Owner = .{ .effort = .high };
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = .{ .context = &owner, .current_fn = Owner.current, .configure_fn = FixtureConnection.configure };
    _ = try ui.editor.insert("input-default");
    // Idle startup, without any delta or mutable Runtime reads.
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.high)) ++ "fixture" ++ theme.reset ++ " " ++ (comptime theme.effortColor(.high)) ++ "?%" ++ theme.reset ++ ") > input-default") != null);
    ui.finishFrame();
    ui.mode = .calling_model;
    ui.display.reset(0);
    ui.display.observe(.{ .state = .calling_model }, 0);
    for ([_]u64{ 1100, 3100, 9100 }) |now| {
        ui.clock_ms = now;
        try ui.draw();
        const marker = try std.fmt.allocPrint(std.testing.allocator, "{s}) {s} input-default", .{ theme.reset, activity.spinner(now) });
        defer std.testing.allocator.free(marker);
        try std.testing.expect(std.mem.find(u8, ui.frame, marker) != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, theme.effortColor(.high)) == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, theme.model_flow[ui.model_flow.step()]) != null);
        ui.finishFrame();
    }
    ui.display.observe(.{ .reasoning = "late thought" }, 9100);
    ui.display.finish(.{ .status = .success }, 9200);
    ui.mode = null;
    owner.effort = .low;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.low)) ++ "fixture" ++ theme.reset ++ " " ++ (comptime theme.effortColor(.low)) ++ "?%" ++ theme.reset ++ ") > input-default") != null);
    ui.finishFrame();
    owner.effort = .unspecified;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(fixture ?%) > input-default") != null);
    ui.finishFrame();
}

test "model only default color prompt has no headers cache or status and preserves cursor" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.editor.insert("hello\t你");
    ui.display.normal_usage = .{ .input_tokens = 100, .cached_input_tokens = 90 };
    try ui.appendDraft(.reasoning, "unprefixed-thought");
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Thinking") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "thin |") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "tools trusted") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, ".thin/sessions") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "(fixture ?%) > hello    你") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "90.0%") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "(fixture)") == null);
    const decoration = "(fixture ?%) > ";
    const position = try std.fmt.allocPrint(std.testing.allocator, "\r\x1b[{d}C\x1b[?25h", .{text.width(decoration) + text.width("hello    你")});
    defer std.testing.allocator.free(position);
    try std.testing.expect(std.mem.endsWith(u8, ui.frame, position));
    try std.testing.expectEqualStrings("hello\t你", ui.editor.bytes.items);
    ui.finishFrame();
}

test "single composer hides statistics and completion and uses flow and exact braille spinner" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.mode = .calling_model;
    ui.display.meter.reset(0);
    ui.display.meter.beginCall(0);
    ui.display.meter.observe(100, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    ui.model_flow.advance(0, true, null);
    ui.clock_ms = 600;
    try ui.appendDraft(.assistant, "visible-body");
    _ = try ui.editor.insert("typed-default-color");
    try ui.draw();
    for ([_][]const u8{ "TPS:", "TTFT:", "tokens in:", "summary in:", "cost:", "loading", "Completed", "calling_model" }) |removed| try std.testing.expect(std.mem.find(u8, ui.frame, removed) == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.reset ++ ") " ++ "⠧ typed-default-color") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.model_flow[ui.model_flow.step()]) != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("visible-body"));
    for (screen.grid[22]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
    try std.testing.expect(std.mem.find(u8, &screen.grid[23], "(fixture ?%) ~ typed-default-color") != null);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.finishFrame();
    ui.clock_ms = 680;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "⠇ typed-default-color") != null);
    ui.finishFrame();
    ui.mode = null;
    ui.draft = null;
    ui.notice = "Completed"; // Even old application success notices cannot add a row.
    ui.last_terminal = .{ .status = .success, .usage = .{ .normal_calls = 1, .normal = .{ .input_tokens = 10562, .output_tokens = 873, .cached_input_tokens = 9600 } } };
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(fixture ?%) > typed-default-color") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Completed") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "tokens in:") == null);
    ui.finishFrame();
}

test "flow model prefix clips long editor suffix without wrap or changing raw cursor bytes" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const raw: [200]u8 = @splat('x');
    _ = try ui.editor.insert(&raw);
    ui.editor.cursor = 1;
    ui.mode = .calling_model;
    ui.clock_ms = 80;
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[23], "(fixture ?%) ~ x"));
    try std.testing.expect(std.mem.endsWith(u8, ui.frame, "\r\x1b[16C\x1b[?25h"));
    for (screen.grid[22]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
    try std.testing.expectEqualStrings(&raw, ui.editor.bytes.items);
    ui.finishFrame();
    ui.editor.cursor = raw.len;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    try std.testing.expect(std.mem.endsWith(u8, ui.frame, "\r\x1b[78C\x1b[?25h"));
    try std.testing.expectEqualStrings(&raw, ui.editor.bytes.items);
    ui.finishFrame();
}

test "resize abandons unknown rows and old completed approval cannot authorize" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.permission = .{ .id = 42, .description = try std.testing.allocator.dupe(u8, "safe preview"), .clipped = false };
    try ui.draw();
    ui.finishFrame();
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
    try ui.draw();
    try std.testing.expect(ui.displayed_permission == null);
    ui.frame_offset = 1; // Even a partially written reclaim escape is unsafe after reflow.
    ui.resize(.{ .columns = 70, .rows = 20 });
    try std.testing.expectEqual(ui.frame_clear_end, ui.frame_offset);
    try std.testing.expectEqualStrings("\x18\x1b[999B\r\n", ui.resize_rescue);
    ui.resize(.{ .columns = 80, .rows = 24 });
    ui.finishFrame();
    try std.testing.expect(ui.displayed_permission == null);
    try ui.draw();
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, "\x1b[?25l\r\x1b[999B\r\n"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[6A") == null);
    try std.testing.expectEqual(@as(usize, 24), ui.frame_height);
    try std.testing.expect(ui.displayed_permission == null);
    ui.finishFrame();
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
}

test "exit drains final canonical transcript on owned PTY without erasing earlier output" {
    const abi = @import("../platform/terminal_abi.zig");
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.openpty(&master, &slave, null, null, null));
    defer _ = std.c.close(master);
    defer _ = std.c.close(slave);
    _ = std.c.fcntl(master, 4, std.c.fcntl(master, 3) | 0x800);
    _ = std.c.write(slave, "prior-shell-output\r\n", 20);
    var terminal = try terminal_module.Terminal.fromFd(slave, false);
    defer terminal.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.terminal = &terminal;
    try ui.draw(); // A pending frame when Ctrl+D arrives.
    _ = try ui.add(.assistant, "final-exit-reply");
    ui.want_exit = true;
    try ui.drainExit();
    try std.testing.expect(ui.frame.len == 0 and !ui.dirty);
    try std.testing.expect(ui.records.items[0].output);
    try std.testing.expect(terminal.restore());
    var buffer: [16384]u8 = undefined;
    var used: usize = 0;
    while (used < buffer.len) {
        const n = std.c.read(master, buffer[used..].ptr, buffer.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    const output = buffer[0..used];
    try std.testing.expect(std.mem.find(u8, output, "prior-shell-output") != null);
    try std.testing.expect(std.mem.find(u8, output, "final-exit-reply") != null);
    for ([_][]const u8{ "1049", "1047", "\x1b[H", "\x1b[2J" }) |forbidden|
        try std.testing.expect(std.mem.find(u8, output, forbidden) == null);
}

test "application log failure and opt-out remain visible without poisoning runtime" {
    const ConnectionFixture = struct {
        runtime: r.Runtime = undefined, // 仅借用地址供 ready 状态判断，本测试不调用它。
        failed: bool,

        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{
                .runtime = &self.runtime,
                .model = "fixture",
                .base_url = "http://unused.invalid",
                .logging_enabled = self.failed,
                .log_error = if (self.failed) error.NoSpaceLeft else null,
            };
        }
    };
    for ([_]bool{ false, true }) |failed| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var connection = ConnectionFixture{ .failed = failed };
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection.context = &connection;
        ui.connection.current_fn = ConnectionFixture.current;
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, if (failed) "REC FAILED: NoSpaceLeft" else "recording off") != null);
        try std.testing.expect(!ui.poisoned);
        try std.testing.expect(!cancel.isRequested());
    }
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
test "canonical reasoning is discarded even when clipped and body remains canonical" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();

    try ui.appendDraft(.reasoning, "old reasoning");
    try ui.replaceCommitted(&.{ .{ .reasoning = "bounded canonical reasoning" }, .{ .text = "canonical body" } }, true, true);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(Kind.assistant, ui.records.items[0].kind);
    try std.testing.expect(ui.records.items[0].clipped);
    try std.testing.expectEqualStrings("canonical body", ui.records.items[0].body.items);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "reasoning") == null);
    ui.finishFrame();
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
        const expected = try std.fmt.allocPrint(std.testing.allocator, "\r\n\x1b[0m\x1b[2K{s}\x1b[0m\r\x1b[{d}C\x1b[?25h", .{ case.line, case.column - 1 });
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

const SelectionFixture = struct {
    name: []const u8 = "fixture-old",
    owned: ?[]u8 = null,
    limit: u32 = 32768,
    effort: shared.ReasoningEffort = .none,
    levels: shared.activity.EffortSet = .{ .mask = 0x3f },
    selections: usize = 0,
    cycles: usize = 0,
    fail: bool = false,
    const profiles = [_]core_config.Model{.{ .name = "fixture-next", .context_tokens = 65536 }};
    fn connection(self: *@This()) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .select_model_fn = select, .set_effort_fn = setEffort };
    }
    fn current(raw: *anyopaque) Connection.State {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return .{ .runtime = null, .model = self.name, .models = &profiles, .context_limit = self.limit, .initial_context = .{ .tokens = 1000, .limit = self.limit }, .base_url = "http://localhost/unused", .reasoning_effort = self.effort, .effort_levels = self.levels };
    }
    fn configure(_: *anyopaque, _: []const u8) !void {
        return error.TestSelectionOnly;
    }
    fn select(raw: *anyopaque, name: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail) return error.TestSelectionFailure;
        const copy = try std.testing.allocator.dupe(u8, name);
        if (self.owned) |old| std.testing.allocator.free(old);
        self.owned = copy;
        self.name = copy;
        self.selections += 1;
        if (std.mem.eql(u8, copy, "fixture-next")) self.limit = 65536;
    }
    fn setEffort(raw: *anyopaque, effort: shared.ReasoningEffort) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail) return error.TestSelectionFailure;
        self.effort = effort;
        self.cycles += 1;
    }
    fn deinit(self: *@This()) void {
        if (self.owned) |name| std.testing.allocator.free(name);
    }
};

test "effort shortcut follows declared levels and unknown or singleton sets never publish" {
    var fixture: SelectionFixture = .{ .effort = .off, .levels = .{} };
    defer fixture.deinit();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 0), fixture.cycles);
    try std.testing.expectEqual(shared.ReasoningEffort.off, fixture.effort);
    try std.testing.expect(std.mem.find(u8, ui.notice, "capabilities unknown") != null);
    fixture.levels = .{ .mask = 1 };
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 0), fixture.cycles);
    fixture.levels = .{ .mask = 0x55 }; // off / low / high / max, not a six-level cycle.
    for ([_]shared.ReasoningEffort{ .low, .high, .max, .off }) |expected| {
        ui.cycleEffort();
        try std.testing.expectEqual(expected, fixture.effort);
    }
    try std.testing.expectEqual(@as(usize, 4), fixture.cycles);
    // The preset deliberately leaves effort unspecified. Its FIRST shortcut
    // must choose the first supported value, not claim capabilities unknown.
    fixture.effort = .unspecified;
    ui.cycleEffort();
    try std.testing.expectEqual(shared.ReasoningEffort.off, fixture.effort);
    try std.testing.expectEqual(@as(usize, 5), fixture.cycles);
}

test "model picker confirms acknowledged epoch and revision preserving transcript and context" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.size = .{ .columns = 80, .rows = 24 };
    _ = try ui.add(.user, "retained user");
    _ = try ui.add(.assistant, "retained answer");
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/model\r\x1b[B\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Select model") != null);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqualStrings("fixture-next", fixture.name);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqual(@as(u32, 65536), ui.display.context.?.limit);
    try std.testing.expect(ui.model_picker == null);
    // An old in-flight menu may finish after close/reopen with revision 1.
    // Epoch acknowledgement prevents that frame authorizing the new menu.
    ui.openModelPicker();
    try ui.draw();
    try ui.modelKey(.cancel);
    ui.openModelPicker();
    ui.finishFrame();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try ui.draw();
    ui.resize(.{ .columns = 40, .rows = 12 });
    ui.finishFrame();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try ui.draw();
    ui.finishFrame();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), fixture.selections);
}

test "selection guards paste secret busy joined future poison and rollback" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~/model pasted-id\x1b[201~\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.parser.feed("/model fixture-next\r", sink);
    try std.testing.expectEqualStrings("fixture-next", fixture.name);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(shared.ReasoningEffort.minimal, fixture.effort);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.minimal)) ++ "fixture-next" ++ theme.reset ++ " " ++ (comptime theme.effortColor(.minimal)) ++ "1.5%" ++ theme.reset ++ ") > ") != null);
    ui.finishFrame();
    ui.busy = true;
    try ui.parser.feed("\x1b[Z/model busy-id\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    ui.busy = false;
    ui.future = ui.io.async(struct {
        fn noop() void {}
    }.noop, .{});
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    ui.future.?.await(ui.io);
    ui.future = null;
    ui.poisoned = true;
    try std.testing.expectError(error.Busy, ui.selectModel("poisoned"));
    ui.poisoned = false;
    fixture.fail = true;
    try std.testing.expectError(error.TestSelectionFailure, ui.selectModel("rejected"));
    try std.testing.expectEqualStrings("fixture-next", fixture.name);
    fixture.fail = false;
    ui.secret_quarantine = true;
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    ui.secret_quarantine = false;
    ui.secret_mode = true;
    ui.parser.secretMode(true);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    ui.secret_mode = false;
    ui.parser.secretMode(false);
    ui.openModelPicker();
    try ui.modelKey(.paste_start);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try ui.modelKey(.clear);
    try std.testing.expect(!ui.model_picker.?.pasted);
    try ui.modelKey(.escape);
    try std.testing.expect(ui.model_picker == null);
}

test "effort shortcut waits for queued and borrowed bridge items" {
    for ([_]bool{ false, true }) |borrowed| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture = SelectionFixture{};
        defer fixture.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        const host = bridge.host();
        try host.emit_fn(host.context, .{ .context_snapshot = .{ .tokens = 12, .limit = 32768 } }, &cancel);
        var held = if (borrowed) bridge.pop() else null;
        defer if (held) |*item| item.deinit();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("\x1b[Z", sink);
        try std.testing.expectEqual(@as(usize, 0), fixture.cycles);
        try std.testing.expectEqual(shared.ReasoningEffort.none, fixture.effort);
        if (held) |*item| {
            item.deinit();
            held = null;
        } else {
            var item = bridge.pop().?;
            item.deinit();
        }
        try ui.parser.feed("\x1b[Z", sink);
        try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
        try std.testing.expectEqual(shared.ReasoningEffort.minimal, fixture.effort);
    }
}

test "shutdown signals after restoration and before announcement suppress identity" {
    const c = std.c;
    const abi = @import("../platform/terminal_abi.zig");
    const Reader = struct {
        var terminal: *terminal_module.Terminal = undefined;
        var calls: usize = 0;
        var later: bool = false;
        fn read() u8 {
            std.debug.assert(terminal.restored and !terminal.active);
            calls += 1;
            return if (later and calls == 1) 0 else if (later) 2 else 15;
        }
    };
    for ([_]bool{ false, true }) |later| {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), abi.openpty(&master, &slave, null, null, null));
        defer _ = c.close(master);
        defer _ = c.close(slave);
        const flags = c.fcntl(slave, 3);
        try std.testing.expect(c.fcntl(master, 4, c.fcntl(master, 3) | 0x800) >= 0);
        var terminal = try terminal_module.Terminal.fromFd(slave, false);
        defer terminal.deinit();
        Reader.terminal = &terminal;
        Reader.calls = 0;
        Reader.later = later;
        try std.testing.expectEqual(@as(u8, if (later) 130 else 143), try finishExit(&terminal, true, 0, @as([32]u8, @splat('a')), Reader.read));
        try std.testing.expectEqual(flags, c.fcntl(slave, 3));
        var bytes: [4096]u8 = undefined;
        const n = c.read(master, &bytes, bytes.len);
        try std.testing.expect(n > 0);
        try std.testing.expect(std.mem.indexOf(u8, bytes[0..@intCast(n)], "Session ID:") == null);
    }
}

test "CtrlD discards the remainder and all subsequent input before submission" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const previous_notice = ui.notice;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x04hello\r", sink);
    try std.testing.expect(ui.want_exit and ui.ctrl_d_exit);
    try std.testing.expectEqualStrings(previous_notice, ui.notice);
    try ui.parser.feed("another\r", sink);
    try std.testing.expectEqualStrings(previous_notice, ui.notice);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try std.testing.expect(ui.future == null and !ui.busy and ui.records.items.len == 0);
}

test "CtrlD exit reason survives secret quarantine picker and busy cancellation" {
    for (0..5) |mode_| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        switch (mode_) {
            1 => {
                ui.secret_mode = true;
                ui.parser.secretMode(true);
                ui.secret.insert("fake-exit-secret");
            },
            2 => ui.secret_quarantine = true,
            3 => ui.openModelPicker(),
            4 => ui.busy = true,
            else => {},
        }
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("\x04", sink);
        try std.testing.expect(ui.want_exit and ui.ctrl_d_exit);
        if (mode_ == 4) try std.testing.expect(cancel.requested.load(.acquire));
        if (mode_ == 1) {
            try std.testing.expect(!ui.secret_mode and ui.secret.len == 0);
            for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
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
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Saved locally; send a message to connect") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Ctrl+U resume") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "sk-fixture-secret") == null);
    ui.finishFrame();
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
