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
const provider_picker_module = @import("provider_picker.zig");
const command_menu_module = @import("command_menu.zig");
const settings_menu_module = @import("settings_menu.zig");
const decision_picker_module = @import("decision_picker.zig");
const local_command_output = @import("local_command_output.zig");
const tool_views_module = @import("tool_views.zig");
const text = @import("text.zig");
const markdown = @import("markdown.zig");
const tail_frame = @import("tail_frame.zig");
const StreamPrefix = @import("stream_prefix.zig").Prefix;
const theme = @import("theme.zig");
const activity = @import("activity.zig");
const presentation = @import("presentation.zig");
const shared = @import("../presentation.zig");
const bridge_module = @import("bridge.zig");
const Io = std.Io;

pub const ModelProvider = picker_module.Provider;

/// 单条显示记录的字节上限（128 KiB）。超出部分只影响显示，不影响模型历史。
const record_limit = 128 * 1024;

/// 显示记录的种类：用户输入、助手正文、推理内容、工具事件、系统提示。
const Kind = enum { user, assistant, reasoning, tool, notice };

/// 对话区中的一条显示记录。body 保存原始 UTF-8 文本；渲染结果缓存在 cache 的 arena 中。
const Record = struct {
    /// 记录种类，决定标题与 Markdown 渲染方式。
    kind: Kind,
    /// Compact completion caption; explicit local output uses a separate plain record.
    command_row: bool = false,
    /// Measured wall-clock execution time of this row; null when unobserved.
    duration_ms: ?u64 = null,
    final_answer: bool = false,
    command_spans: std.ArrayList(presentation.CommandSpan) = .empty,
    /// Only a fully written frame commits transcript delivery. Pending survives index shifts.
    output: bool = false,
    pending_output: bool = false,
    /// Display-only streamed rows released above the mutable tail. Never model
    /// history or canonical output. Copies survive layout invalidation.
    flow_prefix: ?StreamPrefix = null,
    pending_flow_prefix: ?StreamPrefix = null,
    pending_flow_change: bool = false,
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
        if (self.flow_prefix) |*prefix| prefix.deinit();
        self.discardPendingFlow();
        self.body.deinit(a);
        self.command_spans.deinit(a);
    }

    fn discardPendingFlow(self: *Record) void {
        if (self.pending_flow_prefix) |*prefix| prefix.deinit();
        self.pending_flow_prefix = null;
        self.pending_flow_change = false;
    }

    fn stageFlow(self: *Record, a: std.mem.Allocator, count: usize) !bool {
        var next: ?StreamPrefix = null;
        if (count != 0) next = (try StreamPrefix.capture(a, self.lines[0..count], self.columns)) orelse return false;
        self.discardPendingFlow();
        self.pending_flow_prefix = next;
        self.pending_flow_change = true;
        return true;
    }

    fn setCommand(self: *Record, a: std.mem.Allocator, caption: presentation.Caption, outcome: presentation.Outcome, duration_ms: ?u64) !void {
        std.debug.assert(self.body.items.len == 0 and self.command_spans.items.len == 0);
        const label = try presentation.commandText(a, caption, outcome);
        defer a.free(label);
        try self.command_spans.ensureUnusedCapacity(a, 1);
        const start = self.body.items.len;
        try self.append(a, label);
        self.command_row = true;
        self.duration_ms = duration_ms;
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
            const line = try presentation.commandLine(temp, self.body.items, self.command_spans.items, columns, self.duration_ms, null);
            self.lines = try temp.dupe([]const u8, &.{line});
            self.excerpt = false; // Commands indicate clipping with ... only.
            self.columns = columns;
            self.cache = arena;
            return;
        }
        // 截断时追加提示，但提示只用于显示，模型历史保持不变。
        const data = if (self.clipped and self.kind != .reasoning) try std.fmt.allocPrint(temp, "{s}\n[display clipped; model history is unchanged]", .{self.body.items}) else self.body.items;
        const rendered = try markdown.render(temp, data, .{ .columns = columns, .max_lines = 4096, .markdown = self.kind == .assistant, .tone = if (self.kind == .user) .user else if (self.kind == .reasoning) .thinking else if (self.kind == .notice) .muted else .normal });
        self.lines = rendered.lines;
        self.excerpt = self.clipped or rendered.truncated or rendered.degraded or rendered.total_lines > rendered.lines.len;
        self.columns = columns;

        // arena 所有权转移给 Record；之后由 invalidate 统一释放。
        self.cache = arena;
    }
};

// Strict adjacent shape is a display classification only, never authorization.
// No historical call is executed, and ordinary model bash results stay compact.
fn localHistoryCall(messages: []const p.Message, index: usize) ?[]const u8 {
    if (index == 0 or index + 1 >= messages.len) return null;
    const user = messages[index - 1];
    const assistant = messages[index];
    const result = messages[index + 1];
    if (user.role != .user or user.blocks.len != 1 or user.blocks[0] != .text) return null;
    const prompt = std.mem.trimStart(u8, user.blocks[0].text, " \t\r\n");
    if (prompt.len == 0 or prompt[0] != '!') return null;
    if (assistant.role != .assistant or assistant.blocks.len != 2 or assistant.blocks[0] != .text or assistant.blocks[1] != .tool_call) return null;
    if (!std.mem.eql(u8, assistant.blocks[0].text, "Program-generated bash call for the user's explicit !command; not LLM reasoning or a model response.")) return null;
    const call = assistant.blocks[1].tool_call;
    if (!std.mem.eql(u8, call.name, "bash") or !std.mem.startsWith(u8, call.id, "local_command_") or call.id.len == "local_command_".len) return null;
    if (result.role != .tool or result.blocks.len != 1 or result.blocks[0] != .tool_result or !std.mem.eql(u8, result.blocks[0].tool_result.call_id, call.id)) return null;
    return call.id;
}

/// 当前等待用户审批的工具调用。description 由 Ui 的 allocator 持有，由 clearPermission 释放。
/// clipped 表示预览被截断；pasted 表示审批期间出现过粘贴。两者任一为真时只能拒绝。
const Permission = struct { id: u64, description: []const u8, clipped: bool, pasted: bool = false };

/// UI-owned callbacks; the application owns the runtime and configuration lifetime.
pub const Connection = struct {
    pub const Setting = enum { low_price_input, decision_enabled };
    pub const DecisionChoice = enum { off, opencode_jev_free };
    decision_fn: ?*const fn (*anyopaque, DecisionChoice) anyerror!void = null,
    setting_fn: ?*const fn (*anyopaque, Setting, bool) anyerror!void = null,
    context: *anyopaque,
    current_fn: *const fn (*anyopaque) State,
    configure_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    /// Idle, joined-owner callbacks; no network calls. Model selection stays
    /// local; effort saves the project preference, never global defaults.
    select_model_fn: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    configure_provider_fn: ?*const fn (*anyopaque, core_config.providers.Id, []const u8) anyerror!void = null,
    set_effort_fn: ?*const fn (*anyopaque, shared.ReasoningEffort) anyerror!void = null,
    /// Explicit owner-side action may adopt newly discovered missing capability
    /// metadata. Redraw snapshots and existing accepted maps remain frozen.
    cycle_effort_fn: ?*const fn (*anyopaque) anyerror!shared.ReasoningEffort = null,
    /// Startup-only borrowed context, consumed before any worker exists.
    initial_history_fn: ?*const fn (*anyopaque) []const p.Message = null,
    /// Explicit metadata refresh and bounded owner polling, separate from LLM jobs.
    refresh_models_fn: ?*const fn (*anyopaque) anyerror!void = null,
    poll_models_fn: ?*const fn (*anyopaque, bool) bool = null,

    pub const State = struct {
        runtime: ?*r.Runtime,
        /// Immutable app-prepared startup snapshot; no runtime dereference in draw.
        initial_context: ?r.ContextSnapshot = null,
        model: []const u8,
        /// Immutable owner snapshot, valid even without a journal submission.
        session_id: ?[32]u8 = null,
        /// Metadata-only catalog for this endpoint; never a credential catalog.
        models: []const core_config.Model = &.{},
        /// Nonsecret logged-in aliases filter the flat model list. Null is
        /// legacy unfiltered ownership; empty never means all providers.
        model_providers: ?[]const ModelProvider = null,
        model_context_official: []const bool = &.{},
        model_disabled: []const bool = &.{},
        context_official: bool = false,
        metadata_notice: ?[]const u8 = null,
        selection_name: ?[]const u8 = null,
        provider: ?core_config.providers.Id = null,
        /// Nonsecret configured-status bits; never credential bytes.
        configured_providers: u8 = 0,
        allow_custom_models: bool = true,
        context_limit: u32 = 0,
        /// Owner snapshot: known tiered-price protection active for this model,
        /// not the global toggle; never inferred from token usage.
        low_price_input: bool = false,
        low_price_input_enabled: bool = true,
        decision_enabled: bool = false,
        decision_configured: bool = false,
        decision_jev_free: bool = false,
        global_settings_available: bool = true,
        /// Immutable configured request option, not inferred from stream time.
        reasoning_effort: shared.ReasoningEffort = .unspecified,
        /// Default preference awaiting an exact capability map; not a wire option.
        pending_default_effort: ?shared.ReasoningEffort = null,
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
    pub fn configureProvider(self: Connection, provider: core_config.providers.Id, key: []const u8) !void {
        const callback = self.configure_provider_fn orelse return error.SelectionUnavailable;
        try callback(self.context, provider, key);
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
    var ui = Ui{ .allocator = a, .io = io, .connection = connection, .bridge = bridge, .cancel = cancel, .terminal = &terminal, .editor = .{ .allocator = a }, .job = .{ .runtime = undefined, .cancel = cancel, .prompt = "" } };
    defer ui.deinit();

    var directory: [Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try Io.Dir.cwd().realPath(io, &directory);
    const banner = try @import("startup.zig").banner(a, directory[0..directory_len], Io.Clock.real.now(io).toSeconds());
    defer a.free(banner);
    _ = try ui.add(.notice, banner);
    if (connection.initial_history_fn) |history| try ui.restoreHistory(history(connection.context));

    // 事件循环出错时直接返回，资源释放交给上面的 defer。
    const result = ui.loop() catch |err| {
        // ui.deinit joins its worker before terminal.deinit restores attributes.
        return err;
    };

    if (result == 0 and interrupt.signal() == 0) ui.tidyIdleExit();
    return finishExit(&terminal, result, interrupt.signal);
}

// Terminal cleanup emits no session metadata. The application prints exactly
// one resume command only after it has saved a nonempty conversation.
fn finishExit(terminal: *terminal_module.Terminal, result: u8, read_signal: *const fn () u8) !u8 {
    if (!terminal.restore()) return error.TerminalRestoreFailed;
    const signal = read_signal();
    if (signal != 0) return 128 + signal;
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
    input_history: @import("input_history.zig").History = .{},
    /// 终端输入解析器，处理转义序列与粘贴边界。
    parser: input.Parser = .{},
    editor_pasted: bool = false,
    model_picker: ?picker_module.Picker = null,
    provider_picker: provider_picker_module.Picker = .{},
    provider_open: bool = false,
    settings_open: bool = false,
    decision_open: bool = false,
    settings_menu: settings_menu_module.Menu = .{},
    displayed_settings_generation: ?u64 = null,
    frame_settings_generation: ?u64 = null,
    provider_choices: provider_picker_module.Choices = .{},
    displayed_provider_generation: ?u64 = null,
    frame_provider_generation: ?u64 = null,
    secret_provider: ?core_config.providers.Id = null,
    /// Non-modal slash-command suggestions shown above the composer while the
    /// editor holds a bare command token. Local only; never executes by itself.
    command_menu: command_menu_module.Menu = .{},
    command_matches: command_menu_module.Matches = .{},
    displayed_command_generation: ?u64 = null,
    frame_command_generation: ?u64 = null,
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
    /// Idle-exit cleanup must never consume a tail from a submitted conversation.
    has_submitted: bool = false,
    /// 清理未确认（CleanupFailed 等），禁止再次提交，只允许退出并检查。
    poisoned: bool = false,
    /// 是否需要重绘，由事件与按键置位。
    dirty: bool = true,
    /// UI接收状态：用于计时/忙碌标记，不显示常驻mode文字。
    mode: ?r.State = null,
    /// 仅必要的错误、设置和隔离提示使用临时hint。
    notice: []const u8 = "Ready",
    /// 切换思考档位后的短暂确认：在输入框百分比位置显示新档位，2 秒后自动恢复。
    effort_flash: ?struct { level: shared.ReasoningEffort, until_ms: u64 } = null,
    log_warning_seen: bool = false,
    /// UI receipt clock and bounded statistics; never read worker-owned timing.
    clock_ms: u64 = 0,
    animation_tick: u64 = 0,
    display: shared.State = .{},
    model_flow: activity.Flow = .{},
    active_tool: ?struct { id: u64, caption: presentation.Caption, started_ms: u64, display_key: ?p.ToolDisplayKey = null } = null,
    /// Mutable display-only tool rows; never released as immutable transcript.
    tool_views: tool_views_module.Views = .{},
    /// Shared canonical FIFO remains the fallback for restored/legacy events.
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
    /// Independent bounded copies, never borrowed Record.lines. Only complete
    /// writes publish the candidate as a reusable acknowledged tail snapshot.
    frame_tail_snapshot: ?tail_frame.Snapshot = null,
    tail_snapshot: ?tail_frame.Snapshot = null,
    menu_history: ?tail_frame.MenuHistory = null,
    frame_menu_history: ?tail_frame.MenuHistory = null,
    /// Rebuild a display-only history window after resize revokes a popup's
    /// physical backing coordinates. Never replay these rows as model history.
    menu_history_recovery: bool = false,
    /// Sparse relative edits cannot survive reflow: keep a full one-pass tail
    /// in the same frame arena for CAN/bottom recovery after any resize.
    frame_full_tail: []const u8 = "",
    frame_sparse: bool = false,
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
        self.tool_views.deinit(self.allocator);
        if (self.frame_arena) |*arena| arena.deinit();
        if (self.frame_tail_snapshot) |*snapshot| snapshot.deinit();
        if (self.tail_snapshot) |*snapshot| snapshot.deinit();
        if (self.menu_history) |*history| history.deinit();
        if (self.frame_menu_history) |*history| history.deinit();
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.secret.deinit();
        self.closeModelPicker();
        self.parser.secretMode(false);
        self.wipeEditor();
        self.editor.deinit();
        self.input_history.deinit(self.allocator);
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

    /// Display-only projection of locally loaded canonical history.
    /// No Bridge/observer events, execution, approvals or live reasoning replay.
    fn restoreHistory(self: *Ui, messages: []const p.Message) !void {
        if (messages.len == 0) return;
        _ = try self.add(.notice, "Restored model context (display may be shortened); prior tools are NOT rerun");
        for (messages, 0..) |message, index| switch (message.role) {
            .user, .context => {
                for (message.blocks) |block| switch (block) {
                    .text => |value| {
                        _ = try self.add(if (message.role == .user) .user else .notice, value);
                    },
                    else => {},
                };
                if (message.role == .user and message.blocks.len == 1 and message.blocks[0] == .text) {
                    const value = message.blocks[0].text;
                    if (value.len != 0 and value.len <= @import("input_history.zig").History.max_entry_bytes and value[0] != '/') {
                        const owned = try self.input_history.prepare(self.allocator, value);
                        self.input_history.commit(self.allocator, owned);
                    }
                }
            },
            .assistant => {
                try self.captureToolCaptions(message.blocks);
                if (localHistoryCall(messages, index) == null)
                    try self.replaceCommitted(message.blocks, false, true);
            },
            .tool => for (message.blocks) |block| switch (block) {
                .tool_result => |result| {
                    const tool_name: ?[]const u8 = find_name: {
                        for (messages[0..index]) |prior| for (prior.blocks) |candidate| {
                            if (candidate == .tool_call and std.mem.eql(u8, candidate.tool_call.id, result.call_id)) break :find_name candidate.tool_call.name;
                        };
                        break :find_name null;
                    };
                    // Display is not outgoing-history validation. A saved result
                    // without its call is still readable and never executable.
                    const caption = if (tool_name) |name| try self.nextToolCaption(name) else presentation.Caption{ .kind = .other, .label = try self.allocator.dupe(u8, "Saved tool result") };
                    defer caption.deinit(self.allocator);
                    try self.toolCompleted(caption, .{ .text = result.text, .is_error = result.is_error, .canceled = result.canceled, .truncated = result.truncated });
                    if (index > 0) if (localHistoryCall(messages, index - 1)) |id| {
                        if (std.mem.eql(u8, id, result.call_id)) try self.localCommandOutput(result.text, result.truncated);
                    };
                },
                else => {},
            },
        };
        self.clearToolCaptions();
        // Restored records are content, not a never-used empty composer tail.
        self.has_submitted = true;
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

    /// Consume the canonical FIFO even when a pre-Bridge typed ready summary
    /// supplies the caption. A provisional row never supplies execution text.
    fn executionCaption(self: *Ui, name: []const u8, identity: ?p.ToolDisplayKey) !presentation.Caption {
        const call = try self.tool_calls.take(name, self.allocator);
        defer call.deinit(self.allocator);
        // Preserve reliable canonical captions, including valid optional/null
        // fields that the intentionally conservative preview extractor omits.
        if (call.detail != null) return presentation.fromCall(self.allocator, call);
        if (identity) |value| {
            if (try self.tool_views.cloneReadyCaption(self.allocator, value)) |caption| return caption;
        }
        return presentation.fromCall(self.allocator, call);
    }

    fn toolCompleted(self: *Ui, caption: presentation.Caption, result: r.Execution) !void {
        const completion = shared.tools.Completion.fromExecution(result);
        const outcome = completion.outcome;
        const observed = if (outcome == .success) try presentation.completed(self.allocator, caption, completion.file_stats) else presentation.Caption{
            .kind = caption.kind,
            .label = try self.allocator.dupe(u8, caption.label),
            .failure_reason = if (caption.kind == .read) shared.tools.readFailure(result) else null,
        };
        defer observed.deinit(self.allocator);
        const index = try self.add(.tool, "");
        try self.records.items[index].setCommand(self.allocator, observed, outcome, completion.duration_ms);
    }

    fn localCommandOutput(self: *Ui, data: []const u8, truncated: bool) !void {
        const output = try local_command_output.format(self.allocator, data);
        defer self.allocator.free(output.text);
        const index = try self.add(.tool, output.text);
        self.records.items[index].clipped = output.clipped;
        // A runtime or Bridge cap can cut the JSON envelope itself. Preserve
        // that outer provenance even when the formatter falls back to literal.
        if (truncated) _ = try self.add(.notice, "Local command result was truncated; some output is unavailable.");
    }

    /// Only the currently running call is replaceable; every result owns a row.
    fn pendingCommand(self: *Ui, a: std.mem.Allocator, columns: usize) ![]const u8 {
        const label = try presentation.commandText(a, self.active_tool.?.caption, .pending);
        defer a.free(label);
        const start = self.active_tool.?.started_ms;
        return presentation.commandLine(a, label, &.{.{ .start = 0, .end = label.len, .outcome = .pending }}, columns, self.clock_ms -| start, self.clock_ms);
    }

    fn waitingCommand(a: std.mem.Allocator, caption: presentation.Caption, columns: usize) ![]const u8 {
        const label = try presentation.commandText(a, caption, .pending);
        defer a.free(label);
        // Generation, queueing and approval are not execution: static prefix,
        // no timer, no observed line counts and no fabricated result.
        return presentation.commandLine(a, label, &.{.{ .start = 0, .end = label.len, .outcome = .pending }}, columns, null, null);
    }

    /// Only actionable notices/errors use a temporary hint row. Completed,
    /// mode, usage and performance have no rows; the composer owns activity.
    fn hint(self: *Ui, a: std.mem.Allocator, state: Connection.State) ![]const u8 {
        if (self.secret_quarantine) return std.fmt.allocPrint(a, "{s}; Esc closes", .{self.notice});
        if (self.secret_mode) return if (std.mem.eql(u8, self.notice, "Ready")) "" else self.notice;
        if (self.settings_open) return if (self.settings_menu.pasted) "Pasted selection; Esc cancels" else if (std.mem.eql(u8, self.notice, "Ready")) "" else self.notice;
        if (self.provider_open) return if (self.provider_picker.pasted) "Pasted selection; Esc cancels" else if (std.mem.eql(u8, self.notice, "Ready")) "" else self.notice;
        if (self.model_picker) |picker| {
            if (picker.pasted) return "Pasted selection; Esc cancels";
            if (!std.mem.eql(u8, self.notice, "Ready")) return self.notice;
            if (state.model_providers) |logged| if (logged.len == 0) return "No logged-in providers: /login, then /model";
            return "";
        }
        if (self.commandMenuVisible()) return "";
        var notice: []const u8 = "";
        var model_failed = false;
        if (self.last_terminal) |result| {
            if (result.status != .success and (result.status != .paused or result.model_failure == .output_limit or r.policyPause(result.detail))) {
                var formatted: std.Io.Writer.Allocating = .init(a);
                defer formatted.deinit();
                try shared.failure.write(&formatted.writer, self.notice, result.detail, result.model_failure, result.http_status);
                notice = try a.dupe(u8, formatted.written());
                model_failed = result.status == .failed and result.model_failure != null;
            }
        }
        if (notice.len == 0 and !std.mem.eql(u8, self.notice, "Ready") and !std.mem.eql(u8, self.notice, "Running") and !std.mem.eql(u8, self.notice, "Completed")) notice = self.notice;
        if (notice.len == 0 and state.runtime == null and (state.settings_notice == null or state.model.len == 0)) notice = "Not configured: /login, then /model";
        if (notice.len == 0 and state.settings_error == null) if (state.pending_default_effort) |effort| {
            notice = try std.fmt.allocPrint(a, "Default thinking: {s}; awaiting model capabilities", .{effort.name() orelse "unknown"});
        };
        if (state.settings_error) |err| {
            notice = try std.fmt.allocPrint(a, "{s}{s}SETTINGS FAILED: {s}", .{ notice, if (notice.len != 0) " | " else "", @errorName(err) });
        } else if (!model_failed) {
            if (state.settings_notice) |warning| {
                if (!std.mem.eql(u8, notice, warning)) notice = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ notice, if (notice.len != 0) " | " else "", warning });
            }
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
        var withdrawn_preview = false;
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
                withdrawn_preview = self.records.items[i].flow_prefix != null or self.records.items[i].pending_flow_prefix != null;
                self.removeRecord(i);
            } else {
                self.records.items[i].final_answer = shared.answer.classify(blocks, blocks_complete) == .final;
            }
        }
        self.draft = null;
        if (withdrawn_preview) _ = try self.add(.notice, "Stream preview withdrawn (final response has no text)");
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
                // Runtime's command marker is canonical provenance, not model prose.
                if (self.job.kind != .command)
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
                self.active_tool = .{ .id = tool.id, .caption = try self.executionCaption(tool.name, tool.display_key), .started_ms = tool.started_ms orelse self.clock_ms, .display_key = tool.display_key };
            },
            .tool_result => |tool| {
                // FIFO also covers prepare failures/denials without a start.
                // Normal model tools keep captions; explicit local commands also
                // project bounded literal streams without changing canonical data.
                if (self.active_tool) |active| {
                    if (active.id == tool.id) {
                        // Both events may arrive in one UI tick; use the worker's
                        // measured result, never queue-drain time as execution time.
                        try self.toolCompleted(active.caption, tool.result);
                        if (active.display_key) |identity| self.tool_views.remove(self.allocator, identity);
                        self.clearActiveTool();
                    }
                } else {
                    const caption = try self.executionCaption(tool.name, tool.display_key);
                    defer caption.deinit(self.allocator);
                    try self.toolCompleted(caption, tool.result);
                    if (tool.display_key) |identity| self.tool_views.remove(self.allocator, identity);
                }
                if (self.job.kind == .command) try self.localCommandOutput(tool.result.text, tool.result.truncated or item.display_truncated);
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
                _ = try self.add(.notice, if (err == error.NoCompactionCandidate)
                    "No history can be safely compacted yet; context was not changed."
                else
                    @errorName(err));
            },
            // 这些事件对 UI 没有需要展示的内容。
            .finished => {},
            // Raw arguments only feed the shared meter above. Visible rows use
            // bounded typed snapshots produced before Bridge text clipping.
            .tool_preview => {},
            .tool_view => |view| try self.tool_views.upsert(self.allocator, view),
            .tool_views => |stream| switch (stream.phase) {
                .begin => self.tool_views.begin(self.allocator, stream.generation),
                .commit => self.tool_views.commit(self.allocator, stream.generation),
                .discard => self.tool_views.discard(self.allocator, stream.generation),
            },
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
    /// Refresh the slash menu from the current editor bytes. The menu is only
    /// meaningful on an idle, non-pasted session with no modal surface open.
    fn refreshCommandMenu(self: *Ui) void {
        const active = self.settingsIdle() and self.model_picker == null and !self.provider_open and !self.settings_open and !self.editor_pasted;
        if (!active) {
            self.command_matches = .{};
            return;
        }
        const matches = command_menu_module.suggestions(self.editor.bytes.items, self.editor.cursor, self.editor_pasted);
        if (matches.len == 0) {
            self.command_matches = .{};
            return;
        }
        // Compare identities too: /m -> /lg has the same number of candidates.
        if (!std.mem.eql(command_menu_module.Command, self.command_matches.commands[0..self.command_matches.len], matches.commands[0..matches.len])) self.command_menu.changed();
        self.command_matches = matches;
    }
    fn commandMenuVisible(self: *const Ui) bool {
        return self.settingsIdle() and !self.editor_pasted and self.command_matches.len != 0 and !self.command_menu.dismissed and self.model_picker == null and !self.provider_open and !self.settings_open;
    }
    fn closeCommandMenu(self: *Ui) void {
        self.command_matches = .{};
        self.command_menu.changed();
        self.displayed_command_generation = null;
    }
    /// Tab only edits the composer, never opens a picker or starts a job. Like
    /// menu confirmation, completion may only use a fully shown current choice.
    fn completeCommandMenu(self: *Ui) !void {
        if (!self.commandMenuVisible() or self.frame.len != 0 or self.displayed_command_generation != self.command_menu.generation) return;
        const command = self.command_menu.choice(self.command_matches) orelse return;
        const value = command_menu_module.info(command).value;
        if (std.mem.eql(u8, self.editor.bytes.items, value)) return;
        // Prepare before clearing so allocation failure leaves the input intact.
        try self.editor.bytes.ensureTotalCapacity(self.editor.allocator, value.len);
        self.editor.clear();
        self.editor.bytes.appendSliceAssumeCapacity(value);
        self.editor.cursor = value.len;
        self.closeCommandMenu();
        self.refreshCommandMenu();
    }

    /// Only a fully acknowledged, current menu may choose an action. Enter
    /// submits through the usual guarded command path.
    fn acceptCommandMenu(self: *Ui) !void {
        if (!self.commandMenuVisible() or self.frame.len != 0 or self.displayed_command_generation != self.command_menu.generation) return;
        const command = self.command_menu.choice(self.command_matches) orelse return;
        const item = command_menu_module.info(command);
        self.editor.clear();
        _ = try self.editor.insert(item.value);
        self.closeCommandMenu();
        self.command_matches = command_menu_module.suggestions(self.editor.bytes.items, self.editor.cursor, false);
        self.command_menu.dismiss();
        try self.submit();
    }
    fn backToCommands(self: *Ui, selected: command_menu_module.Command) !void {
        // Prepare before closing the child menu; no stale child-frame authority
        // can confirm the newly opened parent, even if a write is in flight.
        try self.editor.bytes.ensureTotalCapacity(self.editor.allocator, 1);
        self.closeModelPicker();
        self.closeProviderPicker();
        self.closeSettingsMenu();
        self.wipeEditor();
        self.editor.bytes.appendSliceAssumeCapacity("/");
        self.editor.cursor = 1;
        self.closeCommandMenu();
        self.refreshCommandMenu();
        for (self.command_matches.commands[0..self.command_matches.len], 0..) |command, index| {
            if (command == selected) self.command_menu.selected = index;
        }
        self.notice = "Ready";
    }
    fn closeSettingsMenu(self: *Ui) void {
        self.settings_open = false;
        self.decision_open = false;
        self.settings_menu.clear();
        self.parser.stop_feed = true;
        self.displayed_settings_generation = null;
    }
    fn openSettingsMenu(self: *Ui) void {
        self.closeModelPicker();
        self.closeProviderPicker();
        self.closeCommandMenu();
        self.closeSettingsMenu();
        self.settings_menu.selected = 0;
        self.settings_open = true;
        self.parser.stop_feed = true;
        self.notice = "Ready";
    }
    fn backToSettings(self: *Ui) void {
        self.decision_open = false;
        self.settings_menu.clear();
        self.settings_menu.selected = 1;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.parser.stop_feed = true;
        self.notice = "Ready";
    }
    fn settingsKey(self: *Ui, event_: input.Event) !void {
        if (self.decision_open and (event_ == .left or event_ == .escape or event_ == .cancel)) {
            self.backToSettings();
            return;
        }
        switch (event_) {
            .escape, .cancel => self.closeSettingsMenu(),
            .quit => self.requestQuit(),
            .left => try self.backToCommands(.settings),
            .paste_start => self.settings_menu.markPaste(),
            .text => |value| if (value.pasted) {
                self.settings_menu.markPaste();
            },
            .up, .down => self.settings_menu.move(event_ == .down, 2),
            .enter => {
                if (!self.settingsIdle() or self.editor_pasted or self.frame.len != 0 or self.settings_menu.pasted or
                    self.displayed_settings_generation != self.settings_menu.generation) return;
                // Revoke before any attempt, including failed saves. Discard the
                // read batch tail; only a new complete frame can authorize again.
                self.settings_menu.generation +%= 1;
                self.displayed_settings_generation = null;
                self.parser.stop_feed = true;
                const state = self.connection.current();
                if (!state.global_settings_available) {
                    self.notice = "Global settings unavailable; changes disabled";
                    return;
                }
                if (!self.decision_open and self.settings_menu.selected != 0) {
                    self.decision_open = true;
                    self.settings_menu.clear();
                    self.settings_menu.selected = @intFromBool(state.decision_enabled and state.decision_jev_free);
                    self.frame_settings_generation = null;
                    self.notice = "Ready";
                    return;
                }
                self.bridge.reset() catch {
                    self.notice = "Settings require a drained session bridge";
                    return;
                };
                if (self.decision_open) {
                    const save = self.connection.decision_fn orelse {
                        self.notice = "Global settings unavailable; changes disabled";
                        return;
                    };
                    save(self.connection.context, if (self.settings_menu.selected == 0) .off else .opencode_jev_free) catch {
                        self.notice = "Could not save setting; previous value kept";
                        return;
                    };
                    self.backToSettings();
                } else {
                    const save = self.connection.setting_fn orelse {
                        self.notice = "Global settings unavailable; changes disabled";
                        return;
                    };
                    save(self.connection.context, .low_price_input, !state.low_price_input_enabled) catch {
                        self.notice = "Could not save setting; previous value kept";
                        return;
                    };
                }
                // Owner publishes, UI never speculates or mutates the snapshot.
                // Decision schema rewrites may explicitly invalidate context.
                const updated = self.connection.current();
                self.display.context = updated.initial_context;
                self.frame_settings_generation = null;
                self.notice = "Ready";
            },
            else => {},
        }
    }
    fn closeProviderPicker(self: *Ui) void {
        self.provider_open = false;
        self.provider_picker.clear(); // Lifetime generation survives close/reopen.
        self.displayed_provider_generation = null;
    }
    fn openProviderPicker(self: *Ui) void {
        self.closeModelPicker();
        self.closeCommandMenu();
        self.closeProviderPicker();
        const state = self.connection.current();
        self.provider_choices = provider_picker_module.choices(state.runtime == null and state.provider == null);
        self.provider_picker.selected = 0;
        for (self.provider_choices.items[0..self.provider_choices.len], 0..) |choice, index| {
            if (choice == .provider and state.provider == choice.provider) self.provider_picker.selected = index;
        }
        self.provider_open = true;
        self.notice = "Ready";
    }
    fn beginSecret(self: *Ui, provider: ?core_config.providers.Id) void {
        self.secret_provider = provider;
        self.secret.wipe();
        self.secret_mode = true;
        self.parser.secretMode(true);
        self.notice = "Ready";
    }
    fn providerKey(self: *Ui, event_: input.Event) !void {
        switch (event_) {
            .escape, .cancel => {
                self.closeProviderPicker();
                self.notice = "Ready";
            },
            .quit => self.requestQuit(),
            .paste_start => self.provider_picker.markPaste(),
            .text => |value| if (value.pasted) {
                self.provider_picker.markPaste();
            },
            .clear => self.provider_picker.clear(),
            .left => try self.backToCommands(.auth),
            .up, .down => self.provider_picker.move(event_ == .down, self.provider_choices.len),
            .enter => {
                if (!self.settingsIdle() or self.frame.len != 0 or self.provider_picker.pasted or self.provider_choices.len == 0 or
                    self.displayed_provider_generation != self.provider_picker.generation) return;
                self.bridge.reset() catch {
                    self.notice = "Setup requires a drained session bridge";
                    return;
                };
                const choice = self.provider_choices.items[@min(self.provider_picker.selected, self.provider_choices.len - 1)];
                self.closeProviderPicker();
                self.beginSecret(switch (choice) {
                    .current => null,
                    .provider => |id| id,
                });
            },
            else => {},
        }
    }

    fn openModelPicker(self: *Ui) void {
        self.closeModelPicker();
        self.model_epoch +%= 1;
        self.model_picker = picker_module.Picker.init(self.allocator);
        const state = self.connection.current();
        self.model_picker.?.allow_custom = state.allow_custom_models;
        self.model_picker.?.provider = state.provider;
        self.notice = "Ready";
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
        self.effort_flash = if (state.effort_levels.contains(state.reasoning_effort))
            .{ .level = state.reasoning_effort.canonical(), .until_ms = self.clock_ms +| 2000 }
        else
            null;
        self.model_flow = .{};
        self.mode = null;
        self.last_terminal = null;
        self.closeModelPicker();
        self.notice = if (inherited) "Model selected; inherited context budget" else "Model selected";
        self.dirty = true;
    }
    fn cycleEffort(self: *Ui) void {
        if (!self.settingsIdle() or self.editor_pasted or self.model_picker != null or self.provider_open or self.settings_open) {
            self.notice = "Thinking selection requires an idle, non-pasted session";
            return;
        }
        self.bridge.reset() catch {
            self.notice = "Thinking selection requires a drained session bridge";
            return;
        };
        const state = self.connection.current();
        const next = if (self.connection.cycle_effort_fn) |cycle|
            cycle(self.connection.context) catch |err| {
                self.notice = switch (err) {
                    error.ThinkingCapabilitiesLoading => "Thinking capabilities are loading; try Shift+Tab again shortly",
                    error.ThinkingCapabilitiesUnknown => "Thinking capabilities unknown: refresh /model or declare reasoning levels in configuration",
                    else => "Could not save thinking option; previous option kept",
                };
                return;
            }
        else blk: {
            const selected = state.effort_levels.next(state.reasoning_effort) orelse {
                self.notice = "Thinking capabilities unknown: declare model reasoning levels in configuration";
                return;
            };
            if (selected != state.reasoning_effort.canonical()) self.connection.setEffort(selected) catch {
                self.notice = "Could not save thinking option; previous option kept";
                return;
            };
            break :blk selected;
        };
        if (next == state.reasoning_effort.canonical()) {
            self.notice = "This model has no other supported thinking level";
            return;
        }
        self.display.setEffort(next);
        // 档位变更只在输入框百分比位置短暂确认，不再写常驻 hint 行。
        self.effort_flash = .{ .level = next, .until_ms = self.clock_ms +| 2000 };
        self.notice = "Ready";
        self.dirty = true;
    }
    fn expireEffortFlash(self: *Ui) void {
        if (self.effort_flash) |pending| {
            if (self.clock_ms >= pending.until_ms) {
                self.effort_flash = null;
                self.dirty = true;
            }
        }
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
            .left => try self.backToCommands(.model),
            .right => picker.query.right(),
            .home => picker.query.cursor = 0,
            .end => picker.query.cursor = picker.query.bytes.items.len,
            .kill_end => {
                picker.query.bytes.items.len = picker.query.cursor;
                picker.changed();
            },
            .up, .down, .enter => {
                const state = self.connection.current();
                const choices = try picker.choicesWithProviders(self.allocator, state.selection_name orelse state.model, state.context_limit, state.models, state.model_disabled, state.model_providers);
                defer self.allocator.free(choices);
                if (event_ == .enter) {
                    if (self.frame.len != 0 or picker.pasted or choices.len == 0 or self.displayed_model_epoch != self.model_epoch or self.displayed_model_generation != picker.generation) return;
                    const choice = choices[@min(picker.selected, choices.len - 1)];
                    if (choice.disabled) {
                        self.notice = "Protocol unknown; model cannot be selected";
                        return;
                    }
                    const name = try picker.selectionName(self.allocator, choice);
                    defer self.allocator.free(name);
                    if (!picker.modelShown(name)) return;
                    self.selectModel(name) catch {
                        self.notice = "Could not switch; selection is unchanged";
                    };
                } else picker.move(event_ == .down, choices.len);
            },
            else => {},
        }
    }

    /// 提交当前输入并启动后台任务。忙碀或已 poisoned 时拒绝；提交不排队。
    fn submit(self: *Ui) !void {
        if (self.want_exit) return;
        const command = std.mem.trim(u8, self.editor.bytes.items, " \t\r\n");
        if (std.mem.eql(u8, command, "/model --refresh")) {
            const allowed = self.settingsIdle() and !self.editor_pasted;
            self.wipeEditor();
            if (!allowed) {
                self.notice = "Metadata refresh requires an idle, non-pasted session";
                return;
            }
            const refresh = self.connection.refresh_models_fn orelse {
                self.notice = "Metadata refresh unavailable";
                return;
            };
            refresh(self.connection.context) catch |err| {
                self.notice = if (err == error.NoOfficialProvider) "No official provider configured; use /login first" else if (err == error.MetadataRefreshBusy) "Official metadata refresh already running" else "Could not start metadata refresh; previous cache kept";
                return;
            };
            self.notice = "Refreshing official model metadata...";
            return;
        }
        if (std.mem.eql(u8, command, "/help")) {
            self.wipeEditor();
            _ = try self.add(.notice, "/model  Select model\n/login  Configure provider\n/compact  Compact conversation\n/settings  Global settings (Low-price input, Decision model)\n!command  Run a local command without main-model inference");
            return;
        }
        if (std.mem.eql(u8, command, "/settings") or std.mem.startsWith(u8, command, "/settings ") or std.mem.startsWith(u8, command, "/settings\t")) {
            const no_arguments = command.len == "/settings".len;
            const allowed = self.settingsIdle() and !self.editor_pasted;
            self.wipeEditor();
            if (!allowed) self.notice = "Settings require an idle, non-pasted session" else if (!no_arguments) self.notice = "Usage: /settings (no arguments)" else self.openSettingsMenu();
            return;
        }
        if (compactCommand(command)) {
            const no_arguments = std.mem.trim(u8, command["/compact".len..], " \t").len == 0;
            const allowed = self.settingsIdle() and !self.editor_pasted;
            self.wipeEditor();
            if (!allowed) {
                self.notice = "Compaction requires an idle, non-pasted session";
            } else if (!no_arguments) {
                self.notice = "Usage: /compact (no arguments)";
            } else if (self.connection.current().runtime) |runtime| {
                if (runtime.messages().len == 0) {
                    self.notice = "No conversation to compact yet";
                    return;
                }
                try self.startCompaction(runtime);
            } else {
                self.notice = self.connection.current().settings_notice orelse "Not configured: use /login first";
            }
            return;
        }
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
            const auth = std.mem.eql(u8, command, "/login");
            const idle = self.settingsIdle() and !self.editor_pasted;
            self.wipeEditor();
            if (!auth) {
                self.notice = "Unknown command; use /help, /model, /login, /compact or /settings";
            } else if (!idle) {
                self.notice = "Setup requires an idle, non-pasted session";
            } else {
                self.bridge.reset() catch {
                    self.notice = "Setup requires a drained session bridge";
                    return;
                };
                if (self.connection.configure_provider_fn != null) self.openProviderPicker() else if (self.connection.current().runtime != null) self.notice = "Already configured; /login does not replace this session" else self.beginSecret(null);
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

        const local_command = command[0] == '!';
        if (local_command and (!self.settingsIdle() or self.editor_pasted or self.parser.pasted or self.parser.escape_len != 0 or self.parser.utf8_len != 0)) {
            self.notice = "Commands require an idle, non-pasted fresh Enter";
            return;
        }
        if (local_command and std.mem.trim(u8, command[1..], " \t\r\n").len == 0) {
            self.notice = "Usage: !command";
            return;
        }
        const state = self.connection.current();
        const runtime = state.runtime orelse {
            self.wipeEditor();
            self.notice = if (state.model.len == 0) "Not configured: /login, then /model" else state.settings_notice orelse "Not configured: use /login first";
            return;
        };

        // 重置 bridge 与取消标记，确保新任务不继承上一次的取消状态。
        try self.bridge.reset();
        self.cancel.* = .{};
        self.approval_paste_seen = false;

        const prompt = try self.allocator.dupe(u8, self.editor.bytes.items);

        // prompt 在任务启动前的错误路径中由 errdefer 释放；启动后由 self.prompt 接管。
        errdefer self.allocator.free(prompt);
        const history_entry = try self.input_history.prepare(self.allocator, prompt);
        errdefer @import("input_history.zig").History.discard(self.allocator, history_entry);

        _ = try self.add(.user, prompt);
        self.job = .{ .runtime = runtime, .cancel = self.cancel, .prompt = prompt, .kind = if (local_command) .command else .prompt };

        // 在独立线程中运行任务；&self.job 在 future 结束前必须保持有效（Ui 持有）。
        const future = try Io.concurrent(self.io, task.Job.run, .{&self.job});
        self.input_history.commit(self.allocator, history_entry);
        self.future = future;
        self.prompt = prompt;
        self.has_submitted = true;
        self.busy = true;
        self.mode = if (local_command) .executing_tool else .calling_model;
        self.last_terminal = null;
        self.notice = if (local_command) "Running command" else "Running";
        if (local_command) self.parser.stop_feed = true;
        self.display.reset(self.clock_ms);
        self.clearActiveTool();
        self.clearToolCaptions();
        self.scroll = 0;
        self.editor.clear();
    }

    /// Summary-only worker, sharing the ordinary cancellation/join/terminal path.
    /// No command text is added to model history or ordinary prompt history.
    fn startCompaction(self: *Ui, runtime: *r.Runtime) !void {
        self.bridge.reset() catch {
            self.notice = "Compaction requires a drained session bridge";
            return;
        };
        self.cancel.* = .{};
        self.approval_paste_seen = false;
        self.job = .{ .runtime = runtime, .cancel = self.cancel, .prompt = "", .kind = .compact };
        const future = try Io.concurrent(self.io, task.Job.run, .{&self.job});
        self.future = future;
        self.prompt = null;
        self.has_submitted = true;
        self.busy = true;
        self.mode = .compacting;
        self.last_terminal = null;
        self.notice = "Compacting context...";
        self.display.reset(self.clock_ms);
        self.clearActiveTool();
        self.clearToolCaptions();
        self.closeCommandMenu();
        self.scroll = 0;
    }

    fn navigateInput(self: *Ui, forward: bool) !void {
        // Nonempty user edits are never overwritten. Text inserted by history
        // itself retains index so subsequent Up/Down can keep browsing.
        if (self.editor.bytes.items.len != 0 and self.input_history.index == null) return;
        const selected = self.input_history.target(forward) orelse return;
        try self.editor.bytes.ensureTotalCapacity(self.editor.allocator, selected.text.len);
        self.editor.clear();
        self.editor.bytes.appendSliceAssumeCapacity(selected.text);
        self.editor.cursor = selected.text.len;
        self.input_history.index = selected.index;
        self.editor_pasted = false;
    }

    fn requestCancel(self: *Ui) void {
        self.cancel.cancel();
        self.notice = "Cancellation requested; cleaning up, not rolling back effects";
        self.clearPermission();
    }

    fn wipeEditor(self: *Ui) void {
        self.input_history.index = null;
        // clear 在 Debug 模式会 poison 原 items；最后再擦除，确保整个保留缓冲区为零。
        self.editor.clear();
        self.editor_pasted = false;
        std.crypto.secureZero(u8, self.editor.bytes.allocatedSlice());
    }

    fn endSecret(self: *Ui) void {
        self.secret_quarantine = self.parser.secret_paste;
        self.secret.wipe();
        self.secret_mode = false;
        self.secret_provider = null;
        self.parser.secretMode(false);
    }

    fn secretKey(self: *Ui, event_: input.Event) !void {
        switch (event_) {
            .text => |v| {
                self.secret.insert(v.value);
                if (self.secret.failed) self.notice = "Invalid or oversized key; Esc cancels";
            },
            .paste_start => self.parser.secret_paste = true,
            .backspace, .delete => self.secret.erase(),
            .clear => {
                self.secret.wipe();
                self.notice = "Ready";
            },
            .escape, .left => {
                // Navigation must not be smuggled behind a paste in the same
                // read. Mode changes wipe scratch and discard remaining bytes.
                if (self.parser.secret_batch_paste) return;
                const previous = self.secret_provider;
                self.endSecret();
                self.secret_quarantine = false;
                self.notice = "Ready";
                if (event_ == .left) {
                    if (self.connection.configure_provider_fn != null) {
                        self.openProviderPicker();
                        for (self.provider_choices.items[0..self.provider_choices.len], 0..) |choice, index| {
                            if (choice == .provider and previous == choice.provider) self.provider_picker.selected = index;
                        }
                    } else try self.backToCommands(.auth);
                }
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
                    self.notice = "Empty or invalid key; Esc cancels";
                    return;
                };
                const named = self.secret_provider != null;
                const saved = if (self.secret_provider) |id| self.connection.configureProvider(id, key_bytes) else self.connection.configure(key_bytes);
                saved catch {
                    self.endSecret();
                    self.notice = "Could not save configuration; use /login to retry";
                    return;
                };
                self.endSecret();
                // A fresh Enter authorizes the completed paste, not its read tail.
                // endSecret still wipes parser scratch and sets stop_feed.
                self.secret_quarantine = false;
                self.wipeEditor();
                self.notice = if (named) "Key saved locally; use /model to select or activate it" else "Saved locally; send a message to connect";
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
        if (event_ == .escape and self.busy) {
            self.requestCancel();
            return; // Cancel the task even while an approval is visible; never exit.
        }
        if (self.secret_mode) {
            try self.secretKey(event_);
            return;
        }
        if (self.secret_quarantine) {
            switch (event_) {
                .escape, .clear => {
                    self.secret_quarantine = false;
                    self.parser.secretMode(false);
                },
                .quit => self.requestQuit(),
                else => {},
            }
            return;
        }

        if (self.settings_open and self.permission == null) return self.settingsKey(event_);
        if (self.provider_open and self.permission == null) return self.providerKey(event_);
        if (self.model_picker != null and self.permission == null) return self.modelKey(event_);
        switch (event_) {
            .text, .paste_start, .backspace, .delete, .clear, .kill_end, .tab => self.input_history.index = null,
            else => {},
        }
        self.refreshCommandMenu();
        // Edits/cursor changes revoke old authority even if candidates stay equal.
        switch (event_) {
            .text, .paste_start, .backspace, .delete, .left, .right, .home, .end, .clear, .kill_end => self.command_menu.changed(),
            else => {},
        }
        // The slash menu is non-modal: it only captures navigation keys while it
        // is visible and the session is idle. Every other key still edits text.
        if (self.commandMenuVisible() and self.permission == null) {
            switch (event_) {
                .up, .down => {
                    self.command_menu.move(event_ == .down, self.command_matches.len);
                    return;
                },
                .escape => {
                    self.command_menu.dismiss();
                    self.dirty = true;
                    return;
                },
                .enter => {
                    const chosen = self.command_menu.choice(self.command_matches).?;
                    // A literal command (typed or completed from an ACKed choice)
                    // keeps the fast input path, not unseen candidate acceptance.
                    if (std.mem.eql(u8, self.editor.bytes.items, command_menu_module.info(chosen).value)) {
                        try self.submit();
                    } else try self.acceptCommandMenu();
                    self.refreshCommandMenu();
                    return;
                },
                .tab => return self.completeCommandMenu(),
                .page_up, .page_down, .cycle_effort, .toggle_reasoning => return,
                else => {},
            }
        }
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
            .tab => if (self.permission == null) {
                if (!try self.editor.insert("    ")) self.notice = "Input limit: 64 KiB";
                self.command_menu.changed();
            },
            // 审批可见时回车无效，避免误触发送。
            .enter => if (self.permission == null) {
                try self.submit();
            },
            // 忙碀时取消任务（已产生的副作用不回滚）；空闲时只清空输入。
            .cancel => {
                if (self.busy) {
                    self.requestCancel();
                } else {
                    self.editor.clear();
                    self.input_history.index = null;
                    self.notice = "Ready";
                }
            },
            // 退出：若任务仍在运行则先取消，等 loop 中 complete 完成后才真正退出。
            .quit => self.requestQuit(),
            .toggle_reasoning => self.show_reasoning = !self.show_reasoning,
            .cycle_effort => self.cycleEffort(),
            .escape => {},
            .up, .down => if (self.permission != null) {
                if (event_ == .up) self.permission_scroll -|= 1 else self.permission_scroll +|= 1;
            } else try self.navigateInput(event_ == .down),
            .page_up => if (self.permission != null) {
                self.permission_scroll -|= @max(1, @min(7, self.size.rows -| 6));
            } else {
                self.scroll +|= 10;
            },
            .page_down => if (self.permission != null) {
                self.permission_scroll +|= @max(1, @min(7, self.size.rows -| 6));
            } else {
                self.scroll -|= 10;
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
        // Any editor mutation re-evaluates the slash menu; a changed token clears
        // an earlier Esc dismissal so suggestions reappear while typing.
        self.refreshCommandMenu();
    }

    fn pollMetadata(self: *Ui) void {
        const poll = self.connection.poll_models_fn orelse return;
        const before = self.connection.current();
        if (!poll(self.connection.context, self.settingsIdle())) return;
        const state = self.connection.current();
        if (before.pending_default_effort != null and state.pending_default_effort == null and
            state.effort_levels.contains(state.reasoning_effort))
            self.effort_flash = .{ .level = state.reasoning_effort.canonical(), .until_ms = self.clock_ms +| 2000 };
        if (self.model_picker) |*picker| picker.changed();
        self.displayed_model_generation = null;
        if (state.metadata_notice) |notice| self.notice = notice;
        self.dirty = true;
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
        if (self.prompt) |prompt| self.allocator.free(prompt);
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
            .paused => if (result.model_failure == .output_limit or r.policyPause(result.detail)) "Paused" else "Paused at round limit; send a message to continue",
            .failed => "Failed",
        };

        // 任务结束时仍未收到 canonical 内容的草稿，标记为中断。
        if (self.draft) |i| self.records.items[i].interrupted = true;
        self.discardReasoning();
        self.draft = null;
        self.clearActiveTool();
        self.clearToolCaptions();
        self.tool_views.clear(self.allocator);
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
            // 档位确认到期后自动恢复为上下文百分比，不必等下一次按键。
            // 主循环每轮最多等待 16ms，因此到期后无需额外唤醒。
            self.expireEffortFlash();
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

            self.pollMetadata();
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
        // A full ACK proves ownership before resize, not after terminal reflow
        // or cursor clamping (even height-only). Never erase guessed old rows.
        // Conservative recovery can retain old visual previews in scrollback;
        // those are not canonical transcript or completed execution records.
        self.size = dimensions;
        if ((self.records.items.len != 0 and (self.settings_open or self.provider_open or self.model_picker != null or self.commandMenuVisible())) or
            (self.menu_history != null and self.menu_history.?.borrowed.len != 0) or
            (self.frame_menu_history != null and self.frame_menu_history.?.borrowed.len != 0))
            self.menu_history_recovery = true;
        self.displayed_permission = null;
        self.displayed_model_epoch = null;
        self.displayed_model_generation = null;
        self.displayed_command_generation = null;
        self.displayed_provider_generation = null;
        self.displayed_settings_generation = null;
        self.frame_fresh = false;
        if (self.tail_snapshot) |*snapshot| snapshot.deinit();
        self.tail_snapshot = null;
        if (self.frame.len != 0 and self.frame_sparse) {
            // Every sparse CUU/CUD after reflow is uncertain, even beyond the
            // initial reclaim prefix. Skip them ALL and replace at a fresh bottom.
            self.frame = self.frame_full_tail;
            self.frame_offset = 0;
            self.frame_clear_end = 0;
            self.frame_sparse = false;
            self.resize_rescue = "\x18" ++ terminal_module.sync_end ++ "\x1b[999B\r\n";
        } else if (self.frame.len != 0 and (self.frame_offset < self.frame_clear_end or self.resize_rescue.len != 0)) {
            // Never finish an old relative reclaim after reflow. Cancel a partial
            // escape, release a possibly interrupted sync, then recover at bottom.
            self.frame_offset = self.frame_clear_end;
            self.resize_rescue = "\x18" ++ terminal_module.sync_end ++ "\x1b[999B\r\n";
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
        if (self.model_picker) |*picker| {
            if (self.displayed_model_epoch == self.model_epoch and self.displayed_model_generation == picker.generation)
                picker.acknowledgeChoice()
            else
                picker.drawn_model_len = null;
        }
        self.displayed_command_generation = if (self.frame_fresh) self.frame_command_generation else null;
        self.displayed_provider_generation = if (self.frame_fresh) self.frame_provider_generation else null;
        self.displayed_settings_generation = if (self.frame_fresh) self.frame_settings_generation else null;
        self.tail_height = self.frame_height;
        self.tail_size = self.frame_size;
        for (self.records.items) |*record| {
            if (record.pending_output) record.output = true;
            record.pending_output = false;
            if (record.pending_flow_change and self.frame_fresh) {
                if (record.flow_prefix) |*prefix| prefix.deinit();
                record.flow_prefix = record.pending_flow_prefix;
                record.pending_flow_prefix = null;
            }
            record.discardPendingFlow();
        }
        if (self.tail_snapshot) |*snapshot| snapshot.deinit();
        self.tail_snapshot = null;
        if (self.frame_fresh) {
            self.tail_snapshot = self.frame_tail_snapshot;
        } else if (self.frame_tail_snapshot) |*snapshot| snapshot.deinit();
        self.frame_tail_snapshot = null;
        if (self.menu_history) |*history| history.deinit();
        self.menu_history = null;
        if (self.frame_fresh) {
            self.menu_history = self.frame_menu_history;
        } else if (self.frame_menu_history) |*history| history.deinit();
        self.frame_menu_history = null;
        if (self.frame_arena) |*arena| arena.deinit();
        self.frame_arena = null;
        self.frame_full_tail = "";
        self.frame_sparse = false;
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

    /// Only an acknowledged, unchanged-size owned tail can be reclaimed. Keep
    /// the startup transcript and shell history above it; never ED/CUP/scrollback-clear.
    fn idleExitBytes(self: *const Ui, writer: *Io.Writer) !bool {
        if (!self.ctrl_d_exit or self.has_submitted or self.busy or self.future != null or
            self.frame.len != 0 or self.resize_rescue.len != 0 or !self.frame_fresh or
            self.abandon_tail or self.tail_snapshot == null or self.tail_height == 0 or
            (self.menu_history != null and self.menu_history.?.borrowed.len != 0) or self.menu_history_recovery or
            self.tail_height > self.size.rows or self.tail_size.rows != self.size.rows or
            self.tail_size.columns != self.size.columns) return false;
        try writer.writeAll(terminal_module.sync_begin ++ "\x1b[?25l\r");
        if (self.tail_height > 1) try writer.print("\x1b[{d}A", .{self.tail_height - 1});
        for (0..self.tail_height) |row| {
            try writer.writeAll("\x1b[0K");
            if (row + 1 < self.tail_height) try writer.writeAll("\x1b[1B\r");
        }
        if (self.tail_height > 1) try writer.print("\x1b[{d}A", .{self.tail_height - 1});
        try writer.writeAll("\r" ++ terminal_module.sync_end);
        return true;
    }

    fn tidyIdleExit(self: *Ui) void {
        self.resize(self.terminal.size());
        var bytes: [2048]u8 = undefined;
        var writer = Io.Writer.fixed(&bytes);
        if (!(self.idleExitBytes(&writer) catch false)) return;
        const start = Io.Clock.awake.now(self.io);
        var offset: usize = 0;
        for (0..50) |_| {
            const size = self.terminal.size();
            // Do not continue relative cleanup after a resize or interruption.
            // Terminal.restore always cancels partial CSI and releases sync.
            if (size.rows != self.size.rows or size.columns != self.size.columns or interrupt.signal() != 0) return;
            offset += self.terminal.write(writer.buffered()[offset..]) catch return;
            if (offset == writer.buffered().len or start.untilNow(self.io, .awake).toMilliseconds() >= 100) return;
            self.terminal.wait(true, 2) catch return;
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
        self.refreshCommandMenu();
        self.displayed_command_generation = null;
        self.frame_command_generation = null;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        errdefer for (self.records.items) |*record| {
            record.discardPendingFlow();
            record.pending_output = false;
        };
        const cols = self.size.columns -| 1; // Never trigger terminal autowrap.
        var out: std.Io.Writer.Allocating = .init(a);
        var tail_out: std.Io.Writer.Allocating = .init(a);
        var writer: *Io.Writer = &out.writer;
        self.displayed_permission = null;
        self.frame_permission = null;

        // Reclaim only our last complete live tail, never the user's earlier rows.
        // Batch visible presentation as well as writes: large canonical commits
        // must scroll, and row-by-row correctness alone still exposes mid-frame
        // footer/body states. Unsupported terminals retain the same safe diffs.
        try writer.writeAll(terminal_module.sync_begin ++ "\x1b[?25l\r");
        if (self.abandon_tail or (self.tail_height != 0 and
            (self.tail_size.columns != self.size.columns or self.tail_size.rows != self.size.rows)))
        {
            try writer.writeAll("\x1b[999B\r\n");
        } else if (self.tail_height != 0) {
            if (self.tail_height > 1) try writer.print("\x1b[{d}A", .{self.tail_height - 1});
            // Replace each row once, without exposing a whole-tail blank pass.
            // Transcript rows plus the nonshrinking live tail cover our footprint.
            try writer.writeAll("\r");
        }

        self.frame_clear_end = out.written().len;
        const history_valid = !self.abandon_tail and self.tail_size.columns == self.size.columns and
            self.tail_size.rows == self.size.rows and self.menu_history != null;
        var above: []const []const u8 = if (history_valid) self.menu_history.?.above else &.{};
        var borrowed: []const []const u8 = if (history_valid) self.menu_history.?.borrowed else &.{};

        // Native scrollback is an appendable document, not a sliding window.
        // Streamed body prefixes may leave the mutable tail as DISPLAY previews;
        // canonical flags/history remain separate. Thinking is always transient.
        var lines: std.ArrayList([]const u8) = .empty;
        if (self.menu_history_recovery) {
            for (self.records.items) |record| {
                // New real output returns to normal append/commit semantics.
                if (!record.output and record.kind != .reasoning) {
                    self.menu_history_recovery = false;
                    break;
                }
            }
        }
        const preview = self.scroll != 0 or self.menu_history_recovery;
        const flow_allowed = !preview and self.size.rows >= 7 and cols >= 8 and
            self.permission == null and self.model_picker == null and !self.provider_open and !self.settings_open and
            !self.commandMenuVisible() and !self.secret_mode and !self.secret_quarantine;
        const mutable_rows = @max(1, self.size.rows -| 4);
        var flow_continuation = false;
        var canonical_output = false;
        var transcript_rows: usize = 0;
        var previous_kind: ?Kind = null;
        for (self.records.items, 0..) |*record, index| {
            if (record.kind == .reasoning) continue;
            const drafting = self.draft == index;
            if (record.output and !preview and !drafting) {
                previous_kind = record.kind;
                continue;
            }
            try record.layout(self.allocator, @max(1, cols));
            const heading = if (record.interrupted) "Interrupted response — preview" else if (record.excerpt) "Display excerpt" else "";
            var prefix: usize = 0;
            if (record.flow_prefix) |*shown| {
                if (shown.matches(record.lines, @max(1, cols))) {
                    prefix = shown.rows.len;
                } else if (!drafting or flow_allowed) {
                    // Do not clear/replay native history as Pi's regular renderer
                    // can do. A revised/reflowed preview is explicitly superseded.
                    try putToneLine(writer, a, 1, "Response revised — earlier stream preview above", cols, theme.muted);
                    try writer.writeAll("\r\n");
                    transcript_rows += 1;
                    _ = try record.stageFlow(self.allocator, 0);
                }
            }
            const finalized = cols >= 8 and !record.output and !drafting;
            var stop = prefix;
            if (drafting and flow_allowed) {
                const wanted = @max(prefix, record.lines.len -| mutable_rows);
                if (wanted > prefix and try record.stageFlow(self.allocator, wanted)) stop = wanted;
            }
            if (finalized) stop = record.lines.len;
            if (finalized or stop > prefix) {
                if (prefix == 0) {
                    if (previous_kind) |prior| if (prior != .tool or record.kind != .tool) {
                        try putStyled(writer, 1, "");
                        try writer.writeAll("\r\n");
                        transcript_rows += 1;
                    };
                }
                if (heading.len != 0 and (prefix == 0 or finalized)) {
                    try putToneLine(writer, a, 1, heading, cols, theme.muted);
                    try writer.writeAll("\r\n");
                    transcript_rows += 1;
                }
                for (record.lines[prefix..stop]) |line| {
                    try putStyled(writer, 1, line);
                    try writer.writeAll("\r\n");
                    transcript_rows += 1;
                }
                if (finalized) {
                    record.pending_output = true;
                    canonical_output = true;
                    _ = try record.stageFlow(self.allocator, 0);
                }
                prefix = stop;
            }
            if (preview or drafting) {
                const begin = if (preview) 0 else prefix;
                if (begin == 0) {
                    if (previous_kind) |prior| if (prior != .tool or record.kind != .tool) try lines.append(a, "");
                    if (heading.len != 0) {
                        const headings = try markdown.render(a, heading, .{ .columns = @max(1, cols), .max_lines = 32, .markdown = false, .tone = .muted });
                        try lines.appendSlice(a, headings.lines);
                    }
                }
                try lines.appendSlice(a, record.lines[begin..]);
                if (drafting and begin != 0) flow_continuation = true;
            }
            previous_kind = record.kind;
        }
        // A real transcript advance releases the borrowed prefix at its original
        // document coordinates before committing new rows. A menu-only redraw
        // instead keeps it reversible (no scrollback duplication).
        if (transcript_rows != 0 and borrowed.len != 0) {
            var rebuilt: std.Io.Writer.Allocating = .init(a);
            try rebuilt.writer.writeAll(out.written()[0..self.frame_clear_end]);
            for (borrowed) |line| {
                try rebuilt.writer.writeAll(line);
                try rebuilt.writer.writeAll("\r\n");
            }
            try rebuilt.writer.writeAll(out.written()[self.frame_clear_end..]);
            out = rebuilt;
            transcript_rows += borrowed.len;
            borrowed = &.{};
        }
        if (!preview) {
            const detached_active = if (self.active_tool) |active| if (active.display_key) |identity| self.tool_views.get(identity) == null else true else false;
            if (self.tool_views.entries.items.len != 0 or detached_active) {
                if (previous_kind) |prior| if (prior != .tool) try lines.append(a, "");
                // Bound the mutable window, keeping the executing/next-ready
                // call visible instead of burying it above 64 queued rows.
                const view_limit = @max(1, self.size.rows -| 5);
                var view_start = if (self.tool_views.ready_count != 0) 0 else self.tool_views.entries.items.len -| view_limit;
                if (self.active_tool) |active| if (active.display_key) |identity| {
                    for (self.tool_views.entries.items, 0..) |entry, i| if (identity.eql(entry.key)) {
                        view_start = i;
                        break;
                    };
                };
                const view_end = @min(self.tool_views.entries.items.len, view_start + view_limit);
                for (self.tool_views.entries.items[view_start..view_end]) |entry| {
                    const running = if (self.active_tool) |active| if (active.display_key) |identity| identity.eql(entry.key) else false else false;
                    try lines.append(a, if (running) try self.pendingCommand(a, @max(1, cols)) else try waitingCommand(a, entry.caption, @max(1, cols)));
                }
                if (detached_active) try lines.append(a, try self.pendingCommand(a, @max(1, cols)));
            }
        }
        const thinking = if (self.show_reasoning and !preview and self.draft == null and self.tool_views.entries.items.len == 0 and self.active_tool == null) self.reasoning else null;
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
        const live_gap: usize = @intFromBool(!preview and !flow_continuation and lines.items.len != 0 and lines.items[0].len == 0);
        const secret_destination = if (self.secret_mode) blk: {
            if (self.secret_provider) |id| break :blk try std.fmt.allocPrint(a, "API key for {s}\nBase URL: {s}\nSaved locally only; /model activates the saved key", .{ id.label(), id.baseUrl() });
            const state = self.connection.current();
            if (state.model.len == 0) break :blk try std.fmt.allocPrint(a, "API key for current endpoint\nBase URL: {s}\nEnter saves locally; no network request is made here", .{state.base_url});
            break :blk try std.fmt.allocPrint(a, "API key for model {s}\nBase URL: {s}\nEnter saves locally; no network request is made here", .{ state.model, state.base_url });
        } else "";
        const empty_rendered: markdown.Rendered = .{ .lines = &.{}, .total_lines = 0, .truncated = false };
        const secret_lines = if (self.secret_mode) try markdown.render(a, secret_destination, .{ .columns = @max(1, cols), .max_lines = 8, .markdown = false }) else empty_rendered;
        // One frame-local plain render serves both sizing and the deny-only latch.
        const approval_lines = if (self.permission) |permission| try markdown.render(a, permission.description, .{ .columns = @max(1, cols), .max_lines = 8192, .markdown = false }) else empty_rendered;
        const state = self.connection.current();
        // App-prepared immutable value, including local /login activation.
        // Draw never dereferences Runtime, not even a fixture/idle pointer.
        self.display.seed(state.initial_context);
        self.display.setEffort(state.reasoning_effort);
        const hint_line = try self.hint(a, state);
        // Always reserve one EMPTY row between conversation and composer.
        const footer_rows: usize = 2 + @as(usize, @intFromBool(hint_line.len != 0));
        const body_limit = self.size.rows -| footer_rows;
        const candidate_limit = body_limit -| 1; // Separate candidates from conversation even in short windows.
        const picker_rows = if (self.model_picker) |*picker| try picker.rowsWithProviders(a, state.selection_name orelse state.model, state.context_limit, state.models, cols, candidate_limit, .{ .current = state.context_official, .models = state.model_context_official }, state.model_disabled, state.model_providers) else picker_module.Rows{ .lines = &.{}, .can_confirm = false };
        if (self.model_picker) |*picker| try picker.captureChoice(a, picker_rows.selected_choice);
        const provider_rows = if (self.provider_open) try provider_picker_module.rows(a, self.provider_picker, self.provider_choices, state.configured_providers, cols, candidate_limit) else provider_picker_module.Rows{ .lines = &.{} };
        self.frame_provider_generation = null;
        const settings_rows = if (self.settings_open and self.decision_open) try decision_picker_module.rows(a, self.settings_menu, cols, candidate_limit) else if (self.settings_open) try settings_menu_module.rows(a, self.settings_menu, .{
            .low_price_input_enabled = state.low_price_input_enabled,
            .decision_enabled = state.decision_enabled,
            .decision_configured = state.decision_configured,
            .decision_jev_free = state.decision_jev_free,
            .global_settings_available = state.global_settings_available,
        }, cols, candidate_limit) else settings_menu_module.Rows{ .lines = &.{} };
        self.frame_settings_generation = null;
        const menu_visible = self.commandMenuVisible();
        const menu_rows = if (menu_visible) try command_menu_module.rows(a, self.command_matches, self.command_menu.selected, cols, candidate_limit) else command_menu_module.Rows{ .lines = &.{} };
        if (menu_visible) self.command_menu.selected = @min(self.command_menu.selected, self.command_matches.len - 1);
        // All candidate menus share one bottom-pinned popup slot. Secondary
        // pickers must not replace the top of the transcript body.
        const popup_lines = if (self.settings_open) settings_rows.lines else if (self.provider_open) provider_rows.lines else if (self.model_picker != null) picker_rows.lines else menu_rows.lines;
        const selected_line = if (self.settings_open) settings_rows.selected_line else if (self.provider_open) provider_rows.selected_line else if (self.model_picker != null) picker_rows.selected_line else menu_rows.selected_line;
        const checked_mask: u16 = if (self.provider_open) provider_rows.checked_mask else if (self.model_picker != null) picker_rows.checked_mask else 0;
        const popup_gap: usize = @intFromBool(popup_lines.len != 0);
        const content_body_limit = body_limit -| (popup_lines.len + popup_gap);
        self.frame_model_epoch = null;
        self.frame_model_generation = null;
        const wanted_body = if (self.permission != null)
            @min(body_limit, 1 + @max(1, approval_lines.lines.len))
        else if (self.secret_mode) @min(body_limit, secret_lines.lines.len) else if (thinking != null) @min(thinking_gap + @min(3, thinking_lines.len), content_body_limit) else @min(lines.items.len, content_body_limit);
        // Initial blank space keeps the first conversation at the top. Each
        // immutable row consumes it; expanding drafts scroll old content upward.
        // Never shrink a tail without replacing it by committed rows: the editor
        // therefore stays on the physical bottom row, without absolute positioning.
        const available = if (self.tail_height == 0 or self.abandon_tail) self.size.rows else self.tail_height;
        const rows = @min(self.size.rows, @max(footer_rows + popup_lines.len + popup_gap + wanted_body, available -| transcript_rows));
        // Popups and history preview grow UP into exact ACKed transcript rows,
        // without pushing duplicate content into native scrollback. Keep these
        // restoration rows when returning from preview to the normal live tail.
        // Unknown/reflowed/partially written rows never grant upward ownership.
        const borrow_count = if ((popup_lines.len != 0 or preview) and transcript_rows == 0)
            @min(rows -| self.tail_height, above.len)
        else
            0;
        if (borrow_count != 0) {
            var prefix: std.ArrayList([]const u8) = .empty;
            try prefix.appendSlice(a, above[above.len - borrow_count ..]);
            try prefix.appendSlice(a, borrowed);
            borrowed = prefix.items;
            above = above[0 .. above.len - borrow_count];
            var rebuilt: std.Io.Writer.Allocating = .init(a);
            try rebuilt.writer.writeAll(out.written()[0..self.frame_clear_end]);
            try rebuilt.writer.print("\x1b[{d}A\r", .{borrow_count});
            self.frame_clear_end = rebuilt.written().len;
            out = rebuilt;
        }
        const active_lines = lines.items;
        // Preview already contains the complete canonical history. Borrowed rows
        // remain owned restoration data, not another prefix of that history.
        if (!preview and borrowed.len != 0) {
            var combined: std.ArrayList([]const u8) = .empty;
            try combined.appendSlice(a, borrowed);
            try combined.appendSlice(a, active_lines);
            lines = combined;
        }
        var next_above: std.ArrayList([]const u8) = .empty;
        try next_above.appendSlice(a, above);
        if (transcript_rows != 0) {
            var split = std.mem.splitSequence(u8, out.written()[self.frame_clear_end..], "\r\n");
            for (0..transcript_rows) |_| try next_above.append(a, split.next() orelse return error.InvalidTailFrame);
        }
        const above_count = @min(next_above.items.len, self.size.rows -| rows);
        var next_history: ?tail_frame.MenuHistory = try tail_frame.MenuHistory.capture(self.allocator, next_above.items[next_above.items.len - above_count ..], borrowed);
        errdefer if (next_history) |*history| history.deinit();

        // Build the complete candidate tail before choosing full or sparse output.
        // Its bytes also provide recovery if resize interrupts a sparse frame.
        writer = &tail_out.writer;
        var cursor_offset: usize = 0;
        // 终端太小时只显示提示，避免布局越界。
        // 审批标题之外至少留一行正文；尺寸不足不属于永久的 clipped 状态。
        const hides_approval_id = if (self.permission) |permission| !self.approvalFits(permission.id) else false;
        if (self.size.rows < 7 or cols < 8 or hides_approval_id) {
            for (0..rows) |row| try putLine(writer, a, row + 1, if (row == 0) "Resize terminal" else "", cols);
            cursor_offset = tail_out.written().len;
            try writer.writeAll("\r");
            self.frame_permission = null;
        } else {
            const body_rows = rows - footer_rows;
            // Menu rows are pinned to the bottom of the body, directly above the
            // composer, so the transcript above keeps its own scroll window.
            const popup_span = @min(popup_lines.len, body_rows);
            const content_body_rows = body_rows -| (popup_span + popup_gap);
            if (self.secret_mode) {
                const start = body_rows -| secret_lines.lines.len;
                for (0..body_rows) |line| try putStyled(writer, 1 + line, if (line >= start and line - start < secret_lines.lines.len) secret_lines.lines[line - start] else "");
                self.frame_permission = null;
            } else if (self.permission) |permission| {
                // Plain rendering: tool input must not hide behind Markdown formatting.
                const all = approval_lines;
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
            } else if (thinking != null) {
                // Latest THREE content rows, without any title/prefix.
                const visible_rows = @min(3, content_body_rows -| thinking_gap);
                const start = thinking_lines.len -| visible_rows;
                for (0..content_body_rows) |line| {
                    const index = line -| thinking_gap;
                    try putStyled(writer, 1 + line, if (line >= thinking_gap and index < visible_rows and start + index < thinking_lines.len) thinking_lines[start + index] else "");
                }
                self.frame_permission = null;
            } else {
                // 有界 live draft / retained history preview，不重写终端滚屏。
                // 从底部向上回退 scroll 行，得到显示窗口的结束位置。
                const leading_gap = if (borrowed.len == 0) live_gap else 0;
                const content = lines.items[leading_gap..];
                const content_rows = content_body_rows -| leading_gap;
                const end = content.len -| @min(self.scroll, content.len -| content_rows);
                const start = end -| content_rows;
                for (0..content_body_rows) |line| {
                    const index = line -| leading_gap;
                    try putStyled(writer, 1 + line, if (line >= leading_gap and start + index < end) content[start + index] else "");
                }
                self.frame_permission = null;
            }

            // Explicit empty separator belongs to the tail and is repaired on
            // every frame, including short histories and narrow candidate windows.
            if (popup_gap != 0 and body_rows > popup_span)
                try putStyled(writer, 1 + content_body_rows, "");
            // Shared provider palette for root, provider and model candidates.
            for (0..popup_span) |line| {
                const tone = if (selected_line == line) theme.accent else theme.muted;
                try putCandidateLine(writer, a, 1 + content_body_rows + @min(popup_gap, body_rows -| popup_span) + line, popup_lines[line], cols, tone, checked_mask & (@as(u16, 1) << @intCast(line)) != 0);
            }
            if (popup_span == popup_lines.len) {
                if (self.settings_open and settings_rows.can_confirm) self.frame_settings_generation = self.settings_menu.generation;
                if (self.provider_open and provider_rows.can_confirm) self.frame_provider_generation = self.provider_picker.generation;
                if (self.model_picker) |picker| {
                    if (picker_rows.can_confirm) {
                        self.frame_model_epoch = self.model_epoch;
                        self.frame_model_generation = picker.generation;
                    }
                }
                if (menu_visible and menu_rows.can_confirm) self.frame_command_generation = self.command_menu.generation;
            }

            if (hint_line.len != 0) try putToneLine(writer, a, rows - 2, hint_line, cols, theme.muted);
            try putLine(writer, a, rows - 1, "", cols);

            if (self.secret_mode or self.secret_quarantine) {
                // Only a bounded mask is copied to the frame; never format secret bytes.
                const masks: [64]u8 = @splat('*');
                const count = @min(self.secret.len, @min(masks.len, cols - 3));
                try putInputLine(writer, a, rows, "API key> ", masks[0..count], cols);
                cursor_offset = tail_out.written().len;
                try writer.print("\r\x1b[{d}C", .{@min(cols, count + 10) - 1});
            } else if (self.settings_open) {
                try putInputLine(writer, a, rows, "Settings> ", "", cols);
                cursor_offset = tail_out.written().len;
                try writer.print("\r\x1b[{d}C", .{@min(cols - 1, 10)});
            } else if (self.provider_open) {
                try putInputLine(writer, a, rows, "Provider> ", "", cols);
                cursor_offset = tail_out.written().len;
                try writer.print("\r\x1b[{d}C", .{@min(cols - 1, 10)});
            } else if (self.model_picker) |picker| {
                const decorated: []const u8 = "Search> ";
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
                const value = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix[start..], suffix[0..end] });
                try putInputLine(writer, a, rows, decorated, value, cols);
                cursor_offset = tail_out.written().len;
                try writer.print("\r\x1b[{d}C", .{@min(cols, decorated.len + width + 1) - 1});
            } else {

                // 光标所在逻辑行的起点（以换行为界）。
                // Slash arguments can be accidental credentials: never render them, even before Enter.
                const trimmed = std.mem.trimStart(u8, self.editor.bytes.items, " \t\r\n");
                const is_model = modelCommand(trimmed);
                const model_args = if (is_model) std.mem.trim(u8, trimmed["/model".len..], " \t\r\n") else "";
                const safe_model = is_model and (model_args.len == 0 or picker_module.manualName(model_args));
                const hide_arguments = !safe_model and std.mem.startsWith(u8, trimmed, "/") and (std.mem.findScalar(u8, trimmed, ' ') != null or std.mem.findScalar(u8, trimmed, '\t') != null or std.mem.findScalar(u8, trimmed, '\r') != null or std.mem.findScalar(u8, trimmed, '\n') != null);
                const command_end = std.mem.findAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
                const hidden_hint: []const u8 = if (is_model)
                    "/model [arguments hidden; use one model ID]"
                else if (std.mem.eql(u8, trimmed[0..command_end], "/login"))
                    "/login [arguments hidden; no key argument]"
                else if (std.mem.eql(u8, trimmed[0..command_end], "/compact"))
                    "/compact [arguments hidden; no arguments]"
                else
                    "/ [command arguments hidden]";
                const visible: []const u8 = if (hide_arguments) hidden_hint else self.editor.bytes.items;
                const cursor = if (hide_arguments) visible.len else self.editor.cursor;
                const begin = if (std.mem.findScalarLast(u8, visible[0..cursor], '\n')) |index| index + 1 else 0;
                const working = self.busy or self.mode != null or self.active_tool != null;
                const view = self.display.view(self.clock_ms);
                self.model_flow.advance(self.clock_ms, working, view.live_tps_tenths);
                const flash = if (self.effort_flash) |pending| if (self.clock_ms < pending.until_ms) pending.level else null else null;
                const decoration = try presentation.prompt(a, state.model, view.context, cols, .{ .busy = working, .now_ms = self.clock_ms, .phase = self.model_flow.step(), .rate_band = view.rate_band, .reasoning_effort = view.reasoning_effort, .effort_flash = flash, .low_price_input = state.low_price_input });
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
                // Decoration owns bounded SGR; the marker reset keeps editor text default.
                const input_line = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ decoration.styled, prefix[start..], suffix[0..suffix_end] });
                try putStyled(writer, rows, input_line);

                // Decoration participates in clipping AND cursor positioning;
                // editing/submitted raw bytes remain untouched.
                cursor_offset = tail_out.written().len;
                try writer.print("\r\x1b[{d}C", .{@min(cols, width + decoration_width + 1) - 1});
            }
        }

        // Include release in the trusted cursor suffix so full/sparse/recovery
        // tails all close synchronization; cursor-show remains the final marker.
        try writer.writeAll(terminal_module.sync_end ++ "\x1b[?25h");
        const snapshot_allowed = self.permission == null and self.model_picker == null and !self.provider_open and !self.settings_open and !menu_visible and !self.secret_mode and !self.secret_quarantine;
        var candidate = if (snapshot_allowed) try tail_frame.Snapshot.capture(self.allocator, tail_out.written(), rows, cursor_offset) else null;
        errdefer if (candidate) |*snapshot| snapshot.deinit();
        const can_diff = !self.abandon_tail and snapshot_allowed and
            self.tail_size.columns == self.size.columns and self.tail_size.rows == self.size.rows and
            self.tail_snapshot != null and candidate != null;
        const growing = can_diff and !canonical_output and transcript_rows != 0 and
            transcript_rows + rows >= self.tail_height;
        const sparse = can_diff and transcript_rows == 0 and self.tail_height == rows;
        var growth_out: std.Io.Writer.Allocating = .init(a);
        writer = &out.writer;
        if (growing) {
            // Compare at unchanged document indices; only CRLF past the old
            // physical bottom creates new history. No sliding-window DL.
            const released = try a.alloc([]const u8, transcript_rows);
            var split = std.mem.splitSequence(u8, out.written()[self.frame_clear_end..], "\r\n");
            for (released) |*line| line.* = split.next() orelse return error.InvalidTailFrame;
            try growth_out.writer.writeAll(out.written()[0..self.frame_clear_end]);
            try candidate.?.emitGrowingDiff(&growth_out.writer, &self.tail_snapshot.?, released);
        } else if (sparse) {
            // Tail sizing pins its last row to the physical bottom. Only the
            // current live view may reuse lines; internal history browsing keeps
            // the ordinary diff, and all modal/ACK/resize gates remain above.
            if (self.scroll == 0 and self.draft == null)
                try candidate.?.emitBottomDiff(writer, &self.tail_snapshot.?)
            else
                try candidate.?.emitDiff(writer, &self.tail_snapshot.?);
        } else {
            try writer.writeAll(tail_out.written());
        }

        // frame 指向 arena 内存，arena 所有权交给 frame_arena，直到这帧写完。
        self.frame_full_tail = tail_out.written();
        self.frame_sparse = sparse or growing;
        self.frame_tail_snapshot = candidate;
        self.frame_menu_history = next_history;
        next_history = null;
        self.frame = if (growing) growth_out.written() else out.written();
        self.frame_offset = 0;
        self.frame_arena = arena;
        self.frame_height = rows;
        self.frame_size = self.size;
        self.frame_fresh = true;
        self.abandon_tail = false;
    }
};

fn compactCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "/compact") or std.mem.startsWith(u8, command, "/compact ") or std.mem.startsWith(u8, command, "/compact\t");
}

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

/// 顺序输出一行；row 只区别首行是否换行，不是绝对坐标。
/// 先写正文再擦除行尾残留：整行清屏会让批量刷新时每行都先空一瞬，造成闪屏。
/// 始终预留一列防止自动换行；空行仍从首列擦除，短行只擦除新内容之后的残留。
fn putStyled(writer: *Io.Writer, row: usize, line: []const u8) !void {
    if (row > 1) try writer.writeAll("\r\n");
    try writer.print("\x1b[0m{s}\x1b[0m\x1b[K", .{line});
}

/// 按终端列宽截断一行后输出：先清理控制字符，再按字素簇累计显示宽度，超出列宽即停止。
/// Menu input prefixes are highlighted; typed text and secret masks stay in
/// the terminal default color. Clip/sanitize before adding trusted styles.
fn putCandidateLine(writer: *Io.Writer, a: std.mem.Allocator, row: usize, value: []const u8, columns: usize, tone: []const u8, checked: bool) !void {
    // Candidate modules already bound display cells and sanitize identifiers.
    // Do not reapply the generic 512-byte caption cap after adding the prefix:
    // that could hide a previously authorized multi-byte identifier suffix.
    const buffer = try text.sanitize(a, value, 4096);
    defer a.free(buffer);
    const safe = buffer[0..fittingBytes(buffer, columns)];
    const glyph = "✓";
    const styled = if (checked and safe.len >= 2 + glyph.len and std.mem.eql(u8, safe[2..][0..glyph.len], glyph))
        try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}{s}{s}", .{ tone, safe[0..2], theme.success, glyph, tone, safe[2 + glyph.len ..], theme.reset })
    else
        try std.fmt.allocPrint(a, "{s}{s}{s}", .{ tone, safe, theme.reset });
    defer a.free(styled);
    try putStyled(writer, row, styled);
}

fn putInputLine(writer: *Io.Writer, a: std.mem.Allocator, row: usize, prefix: []const u8, value: []const u8, columns: usize) !void {
    const label = try presentation.singleLine(a, prefix, columns);
    defer a.free(label);
    const content = try presentation.singleLine(a, value, columns -| text.width(label));
    defer a.free(content);
    const styled = try std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ theme.accent, label, theme.reset, content });
    defer a.free(styled);
    try putStyled(writer, row, styled);
}

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
    return .{ .allocator = std.testing.allocator, .io = std.testing.io, .connection = .{ .context = bridge, .current_fn = FixtureConnection.current, .configure_fn = FixtureConnection.configure }, .bridge = bridge, .cancel = cancel, .terminal = undefined, .editor = .{ .allocator = std.testing.allocator }, .job = .{ .runtime = undefined, .cancel = cancel, .prompt = "" }, .size = .{ .columns = 80, .rows = 24 } };
}

test "local command bridge clipping preserves outer truncation provenance" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.job.kind = .command;
    const stdout = try a.alloc(u8, bridge_module.item_budget + 4096);
    defer a.free(stdout);
    @memset(stdout, 'x');
    const result = try std.fmt.allocPrint(a, "{{\"stdout\":\"{s}\",\"stderr\":\"UNAVAILABLE_BRIDGE_TAIL\",\"exit_code\":7}}", .{stdout});
    defer a.free(result);
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 1, .name = "bash", .result = .{ .text = result, .is_error = true, .truncated = false } } }, &cancel);
    var item = bridge.pop() orelse return error.MissingToolUiEvent;
    defer item.deinit();
    try std.testing.expect(item.display_truncated);
    try std.testing.expect(!item.event.tool_result.result.truncated);
    try std.testing.expect(item.event.tool_result.result.text.len < result.len);
    try ui.event(item);
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    try std.testing.expect(ui.records.items[0].command_row);
    try std.testing.expectEqualStrings(item.event.tool_result.result.text, ui.records.items[1].body.items);
    try std.testing.expect(!ui.records.items[1].clipped); // Below the formatter's independent cap.
    try std.testing.expectEqual(Kind.notice, ui.records.items[2].kind);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[2].body.items, "result was truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[1].body.items, "UNAVAILABLE_BRIDGE_TAIL") == null);
    try std.testing.expect(std.mem.endsWith(u8, result, "\"exit_code\":7}"));
    try ui.draw();
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Local command result was truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "exit: 7") == null);
}

test "local command outer truncation remains visible with incomplete JSON" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.localCommandOutput("{\"stdout\":\"partial", true);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("{\"stdout\":\"partial", ui.records.items[0].body.items);
    try std.testing.expectEqual(Kind.notice, ui.records.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[1].body.items, "result was truncated") != null);
    try std.testing.expect(ui.future == null);
}

test "local command live streams are visible literal and normal tools stay captions" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.job.kind = .command;
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .assistant_committed = &.{
        .{ .text = "Program-generated bash call for the user's explicit !command; not LLM reasoning or a model response." },
        .{ .tool_call = .{ .id = "local_command_1", .name = "bash", .arguments = "{\"command\":\"exit 7\"}" } },
    } }, &cancel);
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 1, .name = "bash", .result = .{ .text = "{\"stdout\":\"**literal**\\n\\u001b[2J\",\"stderr\":\"visible-error\",\"exit_code\":7}", .is_error = true } } }, &cancel);
    while (bridge.pop()) |value| {
        var item = value;
        defer item.deinit();
        try ui.event(item);
    }
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expect(ui.records.items[0].command_row);
    try std.testing.expect(!ui.records.items[1].command_row and ui.records.items[1].kind == .tool);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    for ([_][]const u8{ "stdout:", "stderr:", "**literal**", "visible-error", "exit: 7" }) |label| try std.testing.expectEqual(@as(usize, 1), screen.count(label));
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Program-generated") == null);
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "\x1b[2J") == null);
    try ui.records.items[1].layout(std.testing.allocator, 5);
    for (ui.records.items[1].lines) |line| {
        var offset: usize = 0;
        var columns: usize = 0;
        while (offset < line.len) {
            const cluster = text.nextStyledCluster(line, offset, columns);
            columns += cluster.width;
            offset = cluster.end;
        }
        try std.testing.expect(columns <= 5);
    }
    ui.job.kind = .prompt;
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 2, .name = "bash", .result = .{ .text = "normal-hidden-output" } } }, &cancel);
    while (bridge.pop()) |value| {
        var item = value;
        defer item.deinit();
        try ui.event(item);
    }
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    try std.testing.expect(ui.records.items[2].command_row);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[2].body.items, "normal-hidden-output") == null);
}

test "local command restore is adjacent display only with paired result" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const messages = [_]p.Message{
        .{ .role = .user, .blocks = &.{.{ .text = "  !exit 7" }} },
        .{ .role = .assistant, .blocks = &.{
            .{ .text = "Program-generated bash call for the user's explicit !command; not LLM reasoning or a model response." },
            .{ .tool_call = .{ .id = "local_command_1", .name = "bash", .arguments = "{\"command\":\"must-not-execute\"}" } },
        } },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "local_command_1", .text = "{\"stdout\":\"restored-stream\",\"stderr\":\"restored-error\",\"exit_code\":7}", .is_error = true } }} },
    };
    try std.testing.expect(localHistoryCall(&messages, 1) != null);
    try ui.restoreHistory(&messages);
    try std.testing.expect(bridge.pop() == null);
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqual(@as(usize, 4), ui.records.items.len);
    try std.testing.expect(ui.records.items[2].command_row);
    try std.testing.expect(!ui.records.items[3].command_row);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    for ([_][]const u8{ "stdout:", "stderr:", "restored-stream", "restored-error", "exit: 7" }) |label| try std.testing.expectEqual(@as(usize, 1), screen.count(label));
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Program-generated") == null);
    var ordinary = messages;
    ordinary[0] = .{ .role = .user, .blocks = &.{.{ .text = "model command" }} };
    try std.testing.expect(localHistoryCall(&ordinary, 1) == null);
    ordinary = messages;
    ordinary[2] = .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "other", .text = "hidden" } }} };
    try std.testing.expect(localHistoryCall(&ordinary, 1) == null);
}

test "command elapsed time uses source timestamps freezes results and resets per call" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    const drain = struct {
        fn apply(target: *Ui) !void {
            while (target.bridge.pop()) |value| {
                var item = value;
                defer item.deinit();
                try target.event(item);
            }
        }
    }.apply;
    ui.clock_ms = 5000; // UI may consume both events long after execution.
    try host.emit_fn(host.context, .{ .tool_started = .{ .id = 1, .name = "bash", .started_ms = 1000 } }, &cancel);
    try drain(&ui);
    const running = try ui.pendingCommand(std.testing.allocator, 79);
    defer std.testing.allocator.free(running);
    try std.testing.expect(std.mem.endsWith(u8, running, "4.00s" ++ theme.reset));
    ui.clock_ms = 5500;
    const later = try ui.pendingCommand(std.testing.allocator, 79);
    defer std.testing.allocator.free(later);
    try std.testing.expect(std.mem.endsWith(u8, later, "4.50s" ++ theme.reset));
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 1, .name = "bash", .result = .{ .text = "done", .duration_ms = 420 } } }, &cancel);
    try drain(&ui);
    try std.testing.expectEqual(@as(?u64, 420), ui.records.items[0].duration_ms);
    try ui.records.items[0].layout(std.testing.allocator, 79);
    try std.testing.expect(std.mem.endsWith(u8, ui.records.items[0].lines[0], "420ms" ++ theme.reset));
    ui.clock_ms = 8000;
    try ui.records.items[0].layout(std.testing.allocator, 60); // Resize cannot restart a completed timer.
    try std.testing.expect(std.mem.endsWith(u8, ui.records.items[0].lines[0], "420ms" ++ theme.reset));
    // Start/result drained in the same UI tick retain the measured duration.
    try host.emit_fn(host.context, .{ .tool_started = .{ .id = 2, .name = "bash", .started_ms = 6100 } }, &cancel);
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 2, .name = "bash", .result = .{ .text = "failed", .is_error = true, .duration_ms = 230 } } }, &cancel);
    try drain(&ui);
    try std.testing.expectEqual(@as(?u64, 230), ui.records.items[1].duration_ms);
    try std.testing.expectEqual(presentation.Outcome.failed, ui.records.items[1].command_spans.items[0].outcome);
    // A denied/preparation-failed call did not execute: do not invent 0ms.
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 3, .name = "bash", .result = .{ .text = "not executed", .is_error = true } } }, &cancel);
    try drain(&ui);
    try std.testing.expect(ui.records.items[2].duration_ms == null);
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
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[20A"));
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

test "user thinking streaming prefixes and revised replies keep explicit gaps" {
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
        // Growing native history preserves the original start and its gap,
        // instead of clipping the stream into a moving last-screen window.
        for (0..60) |i| {
            const delta = try std.fmt.allocPrint(std.testing.allocator, "\nlive-line-{d}", .{i});
            defer std.testing.allocator.free(delta);
            try ui.appendDraft(.assistant, delta);
        }
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "live-start");
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        ui.finishFrame();
        try ui.replaceCommitted(&.{.{ .text = "formal-final" }}, false, true);
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "Response revised", "formal-final");
        try std.testing.expectEqual(@as(usize, 1), screen.count("formal-final"));
        try std.testing.expect(screen.count("live-line-") > 0);
        try std.testing.expectEqual(@as(usize, 1), screen.count("user-row-end"));
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        ui.finishFrame();
    }
}

test "empty composer arrows browse history while slash arrows only select commands" {
    const a = std.testing.allocator;
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    for ([_][]const u8{ "first\n中文", "second" }) |message|
        ui.input_history.commit(a, try ui.input_history.prepare(a, message));
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[B", sink);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try ui.parser.feed("\x1b[A", sink);
    try std.testing.expectEqualStrings("second", ui.editor.bytes.items);
    try ui.parser.feed("\x1b[A\x1b[A", sink);
    try std.testing.expectEqualStrings("first\n中文", ui.editor.bytes.items);
    try ui.parser.feed("\x1b[B\x1b[B", sink);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try ui.parser.feed("manual\x1b[A\x1b[B", sink);
    try std.testing.expectEqualStrings("manual", ui.editor.bytes.items);
    try ui.parser.feed("\x15\x1b[A-edited\x1b[A\x1b[B", sink);
    try std.testing.expectEqualStrings("second-edited", ui.editor.bytes.items);
    try std.testing.expect(ui.input_history.index == null);
    try ui.parser.feed("\x15/\x1b[B", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    try std.testing.expectEqual(command_menu_module.Command.auth, ui.command_menu.choice(ui.command_matches).?);
    try std.testing.expectEqual(@as(usize, 0), ui.scroll);
    try std.testing.expect(!ui.busy and ui.future == null); // Browsing is never submission.
    ui.wipeEditor();
    ui.beginSecret(null);
    try ui.parser.feed("fake-secret-never-history", sink);
    ui.endSecret();
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("second", ui.input_history.target(false).?.text);
}

test "standalone Escape cancels active task without exit but arrows and pasted escapes cannot" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("draft-next\x1b[200~\x1b[A\x1b[201~\x1b[", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!cancel.isRequested());
    try ui.parser.feed("A", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!cancel.isRequested());
    try ui.parser.feed("\x1b", sink);
    try std.testing.expect(!cancel.isRequested());
    try ui.parser.expireEscape(sink);
    try std.testing.expect(cancel.isRequested() and !ui.want_exit and !ui.ctrl_d_exit);
    try std.testing.expectEqualStrings("draft-next", ui.editor.bytes.items);
    try std.testing.expect(std.mem.startsWith(u8, ui.notice, "Cancellation requested"));
}

test "idle exit reclaims only acknowledged blank tail and preserves startup and shell history" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.notice, "thin fixture-version\n/fixture\nfixture UTC");
    ui.ctrl_d_exit = true;
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay("shell-kept\r\n");
    try ui.draw();
    var buf: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    try std.testing.expect(!try ui.idleExitBytes(&writer));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    try std.testing.expect(try ui.idleExitBytes(&writer));
    try screen.replay(writer.buffered());
    try screen.replay("\r\nshell-next");
    try std.testing.expectEqual(@as(usize, 0), screen.count("Session ID:"));
    try std.testing.expect(screen.row <= 6);
    for ([_][]const u8{ "shell-kept", "thin fixture-version", "/fixture", "fixture UTC", "shell-next" }) |marker|
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));

    const Denied = struct {
        fn check(state: *Ui) !void {
            var bytes: [2048]u8 = undefined;
            var out = Io.Writer.fixed(&bytes);
            try std.testing.expect(!try state.idleExitBytes(&out));
            try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
        }
    };
    ui.has_submitted = true;
    try Denied.check(&ui);
    ui.has_submitted = false;
    ui.frame_fresh = false;
    try Denied.check(&ui);
    ui.frame_fresh = true;
    ui.abandon_tail = true;
    try Denied.check(&ui);
    ui.abandon_tail = false;
    const old_size = ui.size;
    ui.resize(.{ .columns = 40, .rows = 12 });
    ui.resize(old_size);
    try Denied.check(&ui); // ABA cannot resurrect cleanup ownership.
}

test "resume startup projects saved text and tool outcomes without replaying reasoning or commands" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.restoreHistory(&.{
        .{ .role = .context, .blocks = &.{.{ .text = "[Earlier context summary — lossy background data]" }} },
        .{ .role = .user, .blocks = &.{.{ .text = "remember this" }} },
        .{ .role = .assistant, .blocks = &.{ .{ .reasoning = "hidden old thought" }, .{ .tool_call = .{ .id = "old-call", .name = "read_file", .arguments = "{\"path\":\"old.txt\"}" } } } },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "old-call", .text = "raw output must not render", .is_error = true, .canceled = true } }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "## Earlier answer" }} },
        .{ .role = .user, .blocks = &.{.{ .text = "/login" }} },
    });
    try std.testing.expect(ui.has_submitted and !ui.busy and ui.future == null and !ui.secret_mode);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("remember this", ui.input_history.entries.items[0]);
    var tools: usize = 0;
    for (ui.records.items) |record| {
        try std.testing.expect(record.kind != .reasoning);
        try std.testing.expect(std.mem.indexOf(u8, record.body.items, "hidden old thought") == null);
        try std.testing.expect(std.mem.indexOf(u8, record.body.items, "raw output must not render") == null);
        if (record.kind == .tool) {
            tools += 1;
            try std.testing.expect(record.command_row and record.duration_ms == null);
            try std.testing.expectEqual(presentation.Outcome.canceled, record.command_spans.items[0].outcome);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), tools);
}

test "thinking keeps Markdown syntax literal while assistant answers still render it" {
    const a = std.testing.allocator;
    var thinking_record: Record = .{ .kind = .reasoning };
    defer thinking_record.deinit(a);
    try thinking_record.append(a, "# **plan**\n- `step`\n| a | b |");
    try thinking_record.layout(a, 80);
    const thinking_lines = thinking_record.lines;
    try std.testing.expectEqual(@as(usize, 3), thinking_lines.len);
    for (thinking_lines, [_][]const u8{ "# **plan**", "- `step`", "| a | b |" }) |line, literal| {
        try std.testing.expect(std.mem.find(u8, line, literal) != null);
        try std.testing.expect(std.mem.startsWith(u8, line, theme.reset ++ theme.thinking));
        for ([_][]const u8{ theme.heading, theme.inline_code, theme.code, theme.link, theme.strong, theme.muted, theme.success, theme.failure, theme.caution }) |style|
            try std.testing.expect(std.mem.find(u8, line, style) == null);
    }
    var answer: Record = .{ .kind = .assistant };
    defer answer.deinit(a);
    try answer.append(a, "# plan");
    try answer.layout(a, 80);
    const answer_lines = answer.lines;
    try std.testing.expectEqual(@as(usize, 1), answer_lines.len);
    try std.testing.expect(std.mem.find(u8, answer_lines[0], "plan") != null);
    try std.testing.expect(std.mem.find(u8, answer_lines[0], "# plan") == null);
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

fn emitToolUi(ui: *Ui, event_: r.Event) !void {
    const host = ui.bridge.host();
    try host.emit_fn(host.context, event_, ui.cancel);
    var item = ui.bridge.pop() orelse return error.MissingToolUiEvent;
    defer item.deinit();
    try ui.event(item);
}

fn replayToolFrame(ui: *Ui, screen: *@import("../tests/regular_screen.zig").Screen) !void {
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
}

test "typed tool row updates in place before execution and uses ready metadata after Bridge clipping" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const screen = try a.create(@import("../tests/regular_screen.zig").Screen);
    defer a.destroy(screen);
    screen.* = .{};
    ui.mode = .calling_model;
    ui.clock_ms = 5000;
    try ui.appendDraft(.reasoning, "transient-reasoning");
    const key: p.ToolDisplayKey = .{ .generation = 9, .index = 3 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 9, .phase = .begin } });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = key, .name = "write_file" } });
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.reset ++ "w" ++ theme.muted ++ " write_file") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "transient-reasoning") == null);
    try std.testing.expect(ui.active_tool == null);
    const in_flight = try a.dupe(u8, ui.frame);
    defer a.free(in_flight);
    try emitToolUi(&ui, .{ .tool_view = .{ .key = key, .name = "write_file", .fields = .{ .path = .{ .text = "src/preview.zig" } } } });
    // Updating captions cannot mutate/release a partially written frame.
    try std.testing.expectEqualStrings(in_flight, ui.frame);
    try screen.replay(ui.frame);
    ui.finishFrame();
    for (0..3) |_| {
        try replayToolFrame(&ui, screen);
        try std.testing.expectEqual(@as(usize, 1), screen.count("src/preview.zig"));
        try std.testing.expectEqual(@as(usize, 0), screen.count("write_file"));
        try std.testing.expect(ui.active_tool == null);
    }
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len); // reasoning only
    const filler = try a.alloc(u8, 70 * 1024);
    defer a.free(filler);
    @memset(filler, 'x');
    const arguments = try std.fmt.allocPrint(a, "{{\"content\":\"PRIVATE_PAYLOAD{s}\",\"path\":\"src/preview.zig\"}}", .{filler});
    defer a.free(arguments);
    const blocks = [_]p.Block{.{ .tool_call = .{ .id = "canonical-write", .name = "write_file", .arguments = arguments } }};
    try emitToolUi(&ui, .{ .assistant_committed = &blocks });
    // The canonical display copy is clipped before path. A typed ready snapshot
    // must remain available without repairing that partial JSON.
    try emitToolUi(&ui, .{ .tool_view = .{ .key = key, .name = "write_file", .fields = .{ .path = .{ .text = "src/preview.zig" } }, .ready = true } });
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 9, .phase = .commit } });
    try replayToolFrame(&ui, screen);
    try std.testing.expect(ui.active_tool == null and ui.records.items.len == 0);
    try std.testing.expectEqual(@as(usize, 1), screen.count("src/preview.zig"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("PRIVATE_PAYLOAD"));
    try emitToolUi(&ui, .{ .tool_started = .{ .id = 77, .name = "write_file", .started_ms = 5000, .display_key = key } });
    ui.clock_ms = 5400;
    try std.testing.expectEqualStrings("src/preview.zig", ui.active_tool.?.caption.label);
    try std.testing.expectEqual(@as(u64, 5000), ui.active_tool.?.started_ms);
    try replayToolFrame(&ui, screen);
    try std.testing.expectEqual(@as(usize, 1), screen.count("src/preview.zig"));
    try emitToolUi(&ui, .{ .tool_result = .{ .id = 77, .name = "write_file", .display_key = key, .result = .{ .text = "not display JSON", .duration_ms = 41, .file_stats = .{ .changes = .{ .added = 3, .removed = 2 } } } } });
    try replayToolFrame(&ui, screen);
    try std.testing.expect(ui.active_tool == null and ui.tool_views.entries.items.len == 0);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(@as(?u64, 41), ui.records.items[0].duration_ms);
    try std.testing.expectEqual(@as(usize, 1), screen.count("src/preview.zig"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("+3"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("file unavailable"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("receiving arguments"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("Preparing write"));
}

test "same-name typed rows keep canonical order and denied calls do not consume another view" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const screen = try a.create(@import("../tests/regular_screen.zig").Screen);
    defer a.destroy(screen);
    screen.* = .{};
    ui.mode = .calling_model;
    const first: p.ToolDisplayKey = .{ .generation = 21, .index = 7 };
    const second: p.ToolDisplayKey = .{ .generation = 21, .index = 2 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 21, .phase = .begin } });
    // Arrival/index order is not the final canonical execution order.
    try emitToolUi(&ui, .{ .tool_view = .{ .key = second, .name = "bash", .fields = .{ .command = .{ .text = "echo SECOND" } } } });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = first, .name = "bash", .fields = .{ .command = .{ .text = "echo FIRST" } } } });
    const blocks = [_]p.Block{
        .{ .tool_call = .{ .id = "first", .name = "bash", .arguments = "{\"command\":\"echo FIRST\"}" } },
        .{ .tool_call = .{ .id = "second", .name = "bash", .arguments = "{\"command\":\"echo SECOND\"}" } },
    };
    try emitToolUi(&ui, .{ .assistant_committed = &blocks });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = first, .name = "bash", .fields = .{ .command = .{ .text = "echo FIRST" } }, .ready = true } });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = second, .name = "bash", .fields = .{ .command = .{ .text = "echo SECOND" } }, .ready = true } });
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 21, .phase = .commit } });
    try std.testing.expect(ui.tool_views.entries.items[0].key.eql(first));
    try replayToolFrame(&ui, screen);
    try std.testing.expect(ui.active_tool == null);
    try emitToolUi(&ui, .{ .tool_result = .{ .id = 80, .name = "bash", .display_key = first, .result = .{ .text = "Denied, not executed", .is_error = true } } });
    try std.testing.expect(ui.active_tool == null);
    try std.testing.expectEqual(@as(usize, 1), ui.tool_views.entries.items.len);
    try emitToolUi(&ui, .{ .tool_started = .{ .id = 81, .name = "bash", .display_key = second } });
    try std.testing.expectEqualStrings("echo SECOND", ui.active_tool.?.caption.label);
    try replayToolFrame(&ui, screen);
    try std.testing.expectEqual(@as(usize, 1), screen.count("echo FIRST"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("echo SECOND"));
    try emitToolUi(&ui, .{ .tool_result = .{ .id = 81, .name = "bash", .display_key = second, .result = .{ .text = "done", .duration_ms = 7 } } });
    try replayToolFrame(&ui, screen);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expect(ui.tool_views.entries.items.len == 0);
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "echo FIRST") != null);
    try std.testing.expect(std.mem.find(u8, ui.records.items[1].body.items, "echo SECOND") != null);
    const next: p.ToolDisplayKey = .{ .generation = 22, .index = 7 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 22, .phase = .begin } });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = next, .name = "read_file", .fields = .{ .path = .{ .text = "canceled-preview.txt" } } } });
    try replayToolFrame(&ui, screen);
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 21, .phase = .discard } });
    try std.testing.expectEqual(@as(usize, 1), ui.tool_views.entries.items.len);
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 22, .phase = .discard } });
    try replayToolFrame(&ui, screen);
    try std.testing.expect(ui.tool_views.entries.items.len == 0 and ui.records.items.len == 2);
    try std.testing.expectEqual(@as(usize, 0), screen.count("canceled-preview.txt"));
}

test "canonical caption keeps valid detail omitted by conservative preview extraction" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const identity: p.ToolDisplayKey = .{ .generation = 30, .index = 0 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 30, .phase = .begin } });
    try emitToolUi(&ui, .{ .assistant_committed = &.{.{ .tool_call = .{ .id = "memory-list", .name = "memory", .arguments = "{\"action\":\"list\",\"topic\":null}" } }} });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = identity, .name = "memory", .ready = true } });
    try emitToolUi(&ui, .{ .tool_started = .{ .id = 1, .name = "memory", .display_key = identity } });
    try std.testing.expectEqualStrings("list core/index", ui.active_tool.?.caption.label);
    try std.testing.expectEqual(ui.tool_calls.items.items.len, ui.tool_calls.cursor);
}

test "bounded tool window keeps the first actual execution visible in a full batch" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size.rows = 10;
    ui.mode = .calling_model;
    const screen = try a.create(@import("../tests/regular_screen.zig").Screen);
    defer a.destroy(screen);
    screen.* = .{};
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 31, .phase = .begin } });
    for (0..64) |i| try emitToolUi(&ui, .{ .tool_view = .{
        .key = .{ .generation = 31, .index = i },
        .name = "bash",
        .fields = .{ .command = .{ .text = if (i == 0) "FIRST_ACTIVE_TOOL" else "queued" } },
        .ready = true,
    } });
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 31, .phase = .commit } });
    try emitToolUi(&ui, .{ .tool_started = .{ .id = 1, .name = "bash", .display_key = .{ .generation = 31, .index = 0 } } });
    try replayToolFrame(&ui, screen);
    try std.testing.expect(screen.visible("FIRST_ACTIVE_TOOL"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("FIRST_ACTIVE_TOOL"));
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}

test "raw write deltas alone never display JSON or invent execution" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.mode = .calling_model;
    const host = bridge.host();
    const previews = [_]r.Event{
        .{ .tool_preview = .{ .index = 2, .arguments = "", .write_file = true, .argument_bytes = 0 } },
        .{ .tool_preview = .{ .index = 2, .arguments = "RAW_WRITE_BYTES", .write_file = true, .argument_bytes = 4096 } },
    };
    for (previews) |event_| {
        try host.emit_fn(host.context, event_, &cancel);
        var item = bridge.pop().?;
        defer item.deinit();
        try ui.event(item);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try std.testing.expect(ui.active_tool == null);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "Preparing write") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "receiving arguments") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "received") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "RAW_WRITE_BYTES") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "+3") == null);
        ui.finishFrame();
    }
    const events = [_]r.Event{
        .{ .assistant_committed = &.{.{ .tool_call = .{ .id = "write-2", .name = "write_file", .arguments = "{\"path\":\"preview.txt\"}" } }} },
        .{ .tool_started = .{ .id = 7, .name = "write_file" } },
        .{ .tool_result = .{ .id = 7, .name = "write_file", .result = .{ .text = "written", .file_stats = .{ .changes = .{ .added = 3, .removed = 2 } } } } },
    };
    for (events, 0..) |event_, index| {
        try host.emit_fn(host.context, event_, &cancel);
        var item = bridge.pop().?;
        defer item.deinit();
        try ui.event(item);
        if (index < 2) try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "Preparing write") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "receiving arguments") == null);
        if (index == 0) {
            try std.testing.expect(ui.active_tool == null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "preview.txt") == null);
        } else if (index == 1) {
            try std.testing.expect(ui.active_tool != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, theme.command_pulse[0] ++ "⠋" ++ theme.muted ++ " preview.txt") != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "+3") == null);
        } else {
            try std.testing.expect(ui.active_tool == null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "preview.txt") != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "+3") != null);
        }
        ui.finishFrame();
    }
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "+3") != null);
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "-2") != null);
    ui.last_terminal = .{ .status = .paused, .detail = error.RoundLimit };
    ui.notice = "Paused at round limit; send a message to continue";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const notice = try ui.hint(arena.allocator(), ui.connection.current());
    try std.testing.expect(std.mem.find(u8, notice, "send a message to continue") != null);
    try std.testing.expect(std.mem.find(u8, notice, "RoundLimit") == null);
    try std.testing.expect(std.mem.find(u8, notice, "Failed") == null);
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
        ui.active_tool = .{ .id = 1, .caption = try ui.nextToolCaption(name), .started_ms = 0 };
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
        ui.active_tool = .{ .id = 2, .caption = .{ .kind = .read, .label = try std.testing.allocator.dupe(u8, second.label) }, .started_ms = 0 };
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
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.reset ++ theme.success ++ ">" ++ theme.muted ++ " pwd") != null);
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
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ theme.reset ++ "fixture" ++ theme.reset ++ " " ++ theme.failure ++ "50.0%" ++ theme.reset ++ ") > ") != null);
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

test "committed large Markdown caches stay untouched on resize until history preview opens" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var source: Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for ([_][]const u8{ "once-history-marker", "second-history-marker" }) |marker| {
        source.clearRetainingCapacity();
        try source.writer.print("{s}\n\n", .{marker});
        for (0..64) |_| try source.writer.writeAll("**wide paragraph** with enough words to wrap at the smaller preview width.\n\n");
        _ = try ui.add(.assistant, source.written());
    }
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    ui.finishFrame();
    const old_columns = ui.records.items[0].columns;
    const caches = .{ ui.records.items[0].cache.?.state, ui.records.items[1].cache.?.state };
    const line_ptrs = .{ ui.records.items[0].lines.ptr, ui.records.items[1].lines.ptr };
    ui.resize(.{ .columns = 41, .rows = 24 });
    try ui.draw();
    inline for (0..2) |i| {
        const record = &ui.records.items[i];
        try std.testing.expect(record.output and !record.pending_output);
        try std.testing.expectEqual(old_columns, record.columns);
        try std.testing.expectEqualDeep(caches[i], record.cache.?.state);
        try std.testing.expectEqual(line_ptrs[i], record.lines.ptr);
    }
    try std.testing.expect(std.mem.find(u8, ui.frame, "history-marker") == null);
    try screen.replay(ui.frame);
    ui.finishFrame();
    ui.scroll = 1;
    try ui.draw();
    for (ui.records.items) |*record| {
        try std.testing.expectEqual(@as(usize, 40), record.columns);
        try std.testing.expect(record.output and !record.pending_output);
        for (record.lines) |line| {
            var at: usize = 0;
            var width: usize = 0;
            while (at < line.len) {
                const cluster = text.nextStyledCluster(line, at, width);
                width += cluster.width;
                at = cluster.end;
            }
            try std.testing.expect(width <= 40);
        }
    }
    try screen.replay(ui.frame);
    ui.finishFrame();
    ui.scroll = 0;
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    // Screen is only a fixed-grid transcript counter, not a resize/reflow oracle.
    try std.testing.expectEqual(@as(usize, 1), screen.count("once-history-marker"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("second-history-marker"));
}

fn expectSynchronizedFrame(bytes: []const u8) !void {
    const begin = "\x1b[?2026h";
    const end = "\x1b[?2026l";
    try std.testing.expect(std.mem.startsWith(u8, bytes, begin));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, begin));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, end));
    // Cursor-show remains the final ACK marker, after the display is released.
    try std.testing.expect(std.mem.endsWith(u8, bytes, end ++ "\x1b[?25h"));
}

test "growing and bulk committed frames synchronize before scrolling and release before cursor ACK" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var source: Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..20) |_| try source.writer.writeAll("older-row\n");
    try source.writer.writeAll("last-older-row");
    _ = try ui.add(.assistant, source.written());
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 3), ui.tail_height);

    try ui.appendDraft(.assistant, "growth-draft-marker\nsecond-draft-line");
    try ui.draw();
    try std.testing.expect(!ui.frame_sparse);
    try expectSynchronizedFrame(ui.frame);
    // This expansion scrolls three rows. Supporting terminals must not publish
    // the intermediate state where draft rows have overwritten the old footer.
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 6), ui.tail_height);

    source.clearRetainingCapacity();
    for (0..64) |i| try source.writer.print("committed-{d}\n\n", .{i});
    try ui.replaceCommitted(&.{.{ .text = source.written() }}, false, true);
    try ui.draw();
    try expectSynchronizedFrame(ui.frame);
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 1), screen.count("committed-63"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("growth-draft-marker"));
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.finishFrame();

    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try expectSynchronizedFrame(ui.frame);
    try std.testing.expect(std.mem.find(u8, ui.frame, "committed-") == null);
    try screen.replay(ui.frame);
    ui.finishFrame();
}

test "bulk frames repaint before erasing stale line suffixes" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // Cover shrinking/empty rows as well as an almost-full-width replacement.
    const almost_full: [79]u8 = @splat('x');
    for ([_][]const u8{ "new", "", &almost_full, "\x1b[1mbold\x1b[0m" }) |line| {
        out.clearRetainingCapacity();
        try putStyled(&out.writer, 1, line);
        const bytes = out.written();
        const erase = std.mem.find(u8, bytes, "\x1b[K") orelse return error.MissingSuffixErase;
        try std.testing.expectEqual(@as(usize, 4 + line.len + 4), erase);
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay("previous long content\r");
        try screen.replay(bytes[0..erase]); // 正文先于擦除出现，行尾旧内容不提前消失。
        const replaced = screen.grid[0];
        const column = screen.col;
        try screen.replay(bytes[erase..]);
        try std.testing.expectEqualSlices(u8, replaced[0..column], screen.grid[0][0..column]);
        for (screen.grid[0][column..]) |cell| try std.testing.expectEqual(@as(u8, ' '), cell);
    }

    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    for (0..32) |i| {
        var buffer: [128]u8 = undefined;
        const chunk = try std.fmt.bufPrint(&buffer, "bulk-{d} **changing body** with several words to fill the viewport.\n\n", .{i});
        try ui.appendDraft(.assistant, chunk);
        ui.clock_ms = @intCast(i * 33);
        try ui.draw();
        // Inspect the candidate before finishFrame releases it, including growth.
        try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2K") == null);
        try screen.replay(ui.frame);
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        ui.finishFrame();
    }
    try std.testing.expect(screen.visible("bulk-31"));
}

test "stable large table body is not erased or reprinted for a footer animation tick" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true; // No worker: simulate only the renderer-owned pulse.
    _ = try ui.add(.user, "owned request");
    var source: Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("| Key | Description |\n| --- | --- |\n");
    for (0..64) |i| try source.writer.print("| row-{d} | bounded table cell |\n", .{i});
    try ui.appendDraft(.assistant, source.written());
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    ui.finishFrame();
    const before = screen.grid;
    ui.clock_ms = 80;
    try ui.draw();
    // Only the animated composer changed. A completed body must not disappear
    // in a separate blank pass or be rewritten solely for a footer pulse.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ui.frame, "\x1b[K"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "row-") == null);
    try screen.replay(ui.frame);
    for (0..23) |row| try std.testing.expectEqualSlices(u8, &before[row], &screen.grid[row]);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.finishFrame();
}

test "one-pass transcript separators erase acknowledged approval preview before committing records" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "first request");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "GHOST-preview-1\nGHOST-preview-2\nGHOST-preview-3\nGHOST-preview-4\nGHOST-preview-5\nGHOST-preview-6" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(screen.visible("Approval #1"));
    try std.testing.expect(ui.tail_snapshot == null);
    // The actual loop can answer and receive results before its next draw slot.
    ui.clearPermission();
    _ = try ui.add(.tool, "completed-tool-result");
    _ = try ui.add(.user, "next-user-record");
    _ = try ui.add(.assistant, "short-canonical-record");
    try ui.draw();
    try std.testing.expect(!ui.frame_sparse and ui.frame_tail_snapshot != null);
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), screen.count("Approval #1"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("GHOST-preview"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("completed-tool-result"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("next-user-record"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("short-canonical-record"));
    try std.testing.expectEqual(@as(usize, 23), screen.row);
}

fn seedShiftDraft(ui: *Ui) !void {
    try ui.appendDraft(.assistant, "```\n");
    for (0..35) |row_index| {
        var buffer: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "stream-row-{d:0>3} abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n", .{row_index});
        try ui.appendDraft(.assistant, line);
    }
}

fn nativeLine(screen: *const @import("../tests/regular_screen.zig").Screen, index: usize) []const u8 {
    return if (index < screen.history_len) &screen.history[index] else &screen.grid[index - screen.history_len];
}

test "stream prefix publishes only after ACK and matching canonical text is not duplicated" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    try std.testing.expect(ui.records.items[index].flow_prefix == null);
    try std.testing.expect(ui.records.items[index].pending_flow_prefix != null);
    try std.testing.expect(!ui.records.items[index].output and !ui.records.items[index].pending_output);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    // Invalidating the render cache cannot invalidate the in-flight checkpoint.
    try ui.appendDraft(.assistant, "```");
    ui.finishFrame();
    try std.testing.expect(ui.records.items[index].flow_prefix != null);
    const body = try std.testing.allocator.dupe(u8, ui.records.items[index].body.items);
    defer std.testing.allocator.free(body);
    try ui.replaceCommitted(&.{.{ .text = body }}, false, true);
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(ui.records.items[index].output);
    try std.testing.expect(ui.records.items[index].flow_prefix == null);
    try std.testing.expectEqual(@as(usize, 35), screen.count("stream-row-"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("Response revised"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-000"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-034"));
}

test "withdrawn streamed text is explained without clearing native scrollback" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    ui.finishFrame();
    try ui.replaceCommitted(&.{}, false, true);
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(screen.count("stream-row-") > 0);
    try std.testing.expectEqual(@as(usize, 1), screen.count("Stream preview withdrawn"));
}

test "native history viewport stays stable during streaming and revisions are explicit" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "stream-goal");
    try seedShiftDraft(&ui);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    // A native viewport is an absolute slice of scrollback+screen, NOT Ui.scroll.
    // Pin an observer eight rows above the current bottom; send no wheel input.
    try std.testing.expect(screen.history_len >= 8);
    const view_top = screen.history_len - 8;
    var pinned: [24][80]u8 = undefined;
    for (&pinned, 0..) |*line, index| @memcpy(line, nativeLine(&screen, view_top + index));
    const history = screen.history_len;
    for (35..43) |row_index| {
        var buffer: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "stream-row-{d:0>3} abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n", .{row_index});
        try ui.appendDraft(.assistant, line);
        try ui.draw();
        try std.testing.expect(ui.frame_sparse);
        try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1M") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "\n") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "stream-row-020") == null);
        try screen.replay(ui.frame);
        try std.testing.expect(screen.history_len > history);
        for (&pinned, 0..) |*line_, index| try std.testing.expectEqualSlices(u8, line_, nativeLine(&screen, view_top + index));
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        try std.testing.expect(screen.visible(line[0..14]));
        ui.finishFrame();
    }
    try ui.replaceCommitted(&.{.{ .text = "final-canonical-only" }}, false, true);
    try ui.draw();
    try std.testing.expect(!ui.frame_sparse);
    try screen.replay(ui.frame);
    ui.finishFrame();
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    // Already-visible previews remain identifiable, not silently erased or
    // presented as the corrected canonical answer.
    try std.testing.expect(screen.count("stream-row-") > 0);
    try std.testing.expectEqual(@as(usize, 1), screen.count("Response revised"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("final-canonical-only"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-goal"));
}

test "tail snapshots publish only on full ACK and own bytes after record invalidation" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.appendDraft(.assistant, "stable-body-A");
    try ui.draw();
    try std.testing.expect(ui.tail_snapshot == null and ui.frame_tail_snapshot != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "stable-body-A") != null);
    // appendDraft invalidates/frees Record.lines; the acknowledged copy stays valid.
    try ui.appendDraft(.assistant, "-extended");
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "stable-body-A") != null);
    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "extended") == null);
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "extended") != null);
    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.frame, "\x1b[K"));
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("stable-body-A-extended"));
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.finishFrame();
}

test "resize at every sparse frame byte drops stale relative edits and cannot republish ownership" {
    for ([_]bool{ false, true }) |shifted| {
        var length: usize = 1;
        var offset: usize = 0;
        while (offset < length) : (offset += 1) {
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            // Keep this byte-split fixture ASCII: Screen models CSI cancellation,
            // not a terminal's replacement-character policy for truncated UTF-8.
            if (shifted) try seedShiftDraft(&ui) else try ui.appendDraft(.assistant, "owned body");
            try ui.draw();
            ui.finishFrame();
            try ui.appendDraft(.assistant, if (shifted) "stream-row-035 abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n" else " extended");
            try ui.draw();
            try std.testing.expect(ui.frame_sparse);
            const old_prefix = if (ui.draft) |index| if (ui.records.items[index].flow_prefix) |prefix| prefix.rows.len else 0 else 0;
            if (shifted) {
                try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1M") == null);
                try std.testing.expect(std.mem.find(u8, ui.frame, "\n") != null);
            }
            for (ui.frame) |byte| try std.testing.expect(byte < 128);
            length = ui.frame.len;
            const full = ui.frame_full_tail;
            var captured: Io.Writer.Allocating = .init(std.testing.allocator);
            defer captured.deinit();
            try captured.writer.writeAll(ui.frame[0..offset]);
            ui.frame_offset = offset;
            ui.resize(.{ .columns = 40, .rows = 12 });
            try std.testing.expect(!ui.frame_sparse and !ui.frame_fresh);
            try std.testing.expect(ui.tail_snapshot == null);
            try std.testing.expectEqual(@as(usize, 0), ui.frame_offset);
            try std.testing.expectEqualStrings(full, ui.frame);
            try std.testing.expectEqualStrings("\x18" ++ terminal_module.sync_end ++ "\x1b[999B\r\n", ui.resize_rescue);
            try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[23A") == null);
            try captured.writer.writeAll(ui.resize_rescue);
            try captured.writer.writeAll(ui.frame);
            var screen: @import("../tests/regular_screen.zig").Screen = .{};
            // Syntax/escape cancellation only, not a physical resize/reflow oracle.
            try screen.replay(captured.written());
            try std.testing.expect(std.mem.endsWith(u8, captured.written(), terminal_module.sync_end ++ "\x1b[?25h"));
            // Even returning to old dimensions does not revive the old ACK/cache.
            ui.resize(.{ .columns = 80, .rows = 24 });
            ui.finishFrame(); // Simulate completion of the full recovery, not sparse ACK.
            try std.testing.expect(ui.tail_snapshot == null);
            try std.testing.expect(ui.displayed_permission == null and ui.displayed_model_epoch == null);
            if (ui.draft) |index| {
                const record = &ui.records.items[index];
                try std.testing.expectEqual(old_prefix, if (record.flow_prefix) |prefix| prefix.rows.len else 0);
                try std.testing.expect(record.pending_flow_prefix == null);
            }
            try std.testing.expect(ui.abandon_tail);
        }
    }
}

fn discardFixtureFrame(ui: *Ui) void {
    // Test-only discard of an unsent preview, NOT an acknowledgement. Legacy
    // tests freed only frame_arena; candidates now own a separate arena too.
    if (ui.frame_arena) |*arena| arena.deinit();
    if (ui.frame_tail_snapshot) |*snapshot| snapshot.deinit();
    if (ui.frame_menu_history) |*history| history.deinit();
    ui.frame_menu_history = null;
    ui.frame_arena = null;
    ui.frame_tail_snapshot = null;
    ui.frame_full_tail = "";
    ui.frame_sparse = false;
    ui.frame_offset = 0;
    ui.frame = "";
    for (ui.records.items) |*record| record.discardPendingFlow();
}

fn tailAllocationDraw(ui: *Ui) !void {
    // draw writes only to std.Io.Writer.Allocating, never terminal I/O. Its
    // drain translates allocator OOM to WriteFailed; the fault-test helper
    // requires the original allocation error. Do not alter production errors.
    ui.draw() catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}

fn tailAllocationScenario(a: std.mem.Allocator, native: bool) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.allocator = a;
    ui.editor.allocator = a;
    defer ui.deinit();
    if (native) try seedShiftDraft(&ui) else try ui.appendDraft(.assistant, "| K | V |\n| --- | --- |\n| old | body |\n");
    try tailAllocationDraw(&ui);
    ui.finishFrame();
    const old_ack = ui.tail_snapshot.?.full;
    const prefix_count = if (ui.records.items[ui.draft.?].flow_prefix) |prefix| prefix.rows.len else 0;
    try ui.appendDraft(.assistant, if (native) "stream-row-035 more body\n" else "| new | cell |\n");
    tailAllocationDraw(&ui) catch |err| {
        // A failed candidate cannot replace/free the last acknowledged bytes.
        try std.testing.expectEqualStrings(old_ack, ui.tail_snapshot.?.full);
        const record = &ui.records.items[ui.draft.?];
        try std.testing.expectEqual(prefix_count, if (record.flow_prefix) |prefix| prefix.rows.len else 0);
        try std.testing.expect(record.pending_flow_prefix == null and !record.pending_flow_change);
        try std.testing.expect(ui.frame.len == 0 and ui.frame_tail_snapshot == null);
        return err;
    };
    ui.resize(.{ .columns = 40, .rows = 12 });
    ui.finishFrame();
    try tailAllocationDraw(&ui);
    ui.finishFrame();
}

test "tail snapshot construction and resize release all allocations under OOM" {
    try text.initLocale();
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    for ([_]bool{ false, true }) |native| try std.testing.checkAllAllocationFailures(backing.allocator(), tailAllocationScenario, .{native});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "composer displays startup zero and latest actual usage or unknown without billing accumulation" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.display.seed(.{ .tokens = 0, .limit = 1000000 });
    const green_prompt = "(" ++ theme.reset ++ "fixture" ++ theme.reset ++ " " ++ theme.success;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, green_prompt ++ "0.0%" ++ theme.reset ++ ") > ") != null);
    ui.finishFrame();
    const Case = struct { purpose: p.Purpose, usage: p.Usage, prefix: []const u8 };
    const host = bridge.host();
    for ([_]Case{
        .{ .purpose = .normal, .usage = .{ .input_tokens = 12000, .output_tokens = 1000, .cached_input_tokens = 10000, .reasoning_tokens = 300 }, .prefix = green_prompt ++ "1.3%" ++ theme.reset ++ ") > " },
        .{ .purpose = .summary, .usage = .{ .total_tokens = 1000 }, .prefix = green_prompt ++ "0.1%" ++ theme.reset ++ ") > " },
        .{ .purpose = .normal, .usage = .{ .input_tokens = 12 }, .prefix = "(fixture ?%) > " },
        .{ .purpose = .normal, .usage = .{ .total_tokens = 0 }, .prefix = green_prompt ++ "0.0%" ++ theme.reset ++ ") > " },
    }) |case| {
        try host.emit_fn(host.context, .{ .usage = .{ .purpose = case.purpose, .protocol = .chat, .value = case.usage } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, case.prefix) != null);
        ui.finishFrame();
    }
}

test "output limit paused hint retains cause and budget advice instead of round-limit notice" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.last_terminal = .{ .status = .paused, .detail = error.OutputLimitReached, .model_failure = .output_limit };
    ui.notice = "Paused";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line = try ui.hint(arena.allocator(), ui.connection.current());
    try std.testing.expect(std.mem.find(u8, line, "OutputLimitReached / output_limit") != null);
    try std.testing.expect(std.mem.find(u8, line, "limits.max_output_tokens") != null);
    try std.testing.expect(std.mem.find(u8, line, "lower reasoning effort") != null);
    try std.testing.expect(std.mem.find(u8, line, "round limit") == null);
}

test "input and decision policy pauses explain their cause rather than round limit" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]anyerror{ error.InputBudgetExceeded, error.UnknownInputPriceThreshold, error.InputBudgetSummaryFailed, error.DecisionUnavailable }) |detail| {
        try std.testing.expect(r.policyPause(detail));
        ui.last_terminal = .{ .status = .paused, .detail = detail };
        ui.notice = "Paused";
        const line = try ui.hint(arena.allocator(), ui.connection.current());
        try std.testing.expect(std.mem.find(u8, line, @errorName(detail)) != null);
        try std.testing.expect(std.mem.find(u8, line, "round limit") == null);
        try std.testing.expect(std.mem.find(u8, line, "HTTP") == null);
    }
}

test "read command errors include a safe reason after error and never display raw results" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const caption = try presentation.caption(std.testing.allocator, "read_file", "{\"path\":\"README.md\"}");
    defer caption.deinit(std.testing.allocator);
    try ui.toolCompleted(caption, .{ .text = "FileNotFound", .is_error = true, .duration_ms = 3 });
    try std.testing.expectEqualStrings("r README.md [error] FileNotFound: file not found", ui.records.items[0].body.items);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "[error] FileNotFound: file not found") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "3ms") != null);
    ui.finishFrame();
    try ui.toolCompleted(caption, .{ .text = "{\"private-result\":\"secret\"}\n\x1b[2J", .is_error = true });
    try std.testing.expect(std.mem.find(u8, ui.records.items[1].body.items, "[error] Read failed: details unavailable") != null);
    try std.testing.expect(std.mem.find(u8, ui.records.items[1].body.items, "secret") == null);
    try ui.toolCompleted(caption, .{ .text = "FileNotFound", .is_error = true, .canceled = true });
    try std.testing.expectEqualStrings("r README.md [canceled]", ui.records.items[2].body.items);
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
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.high)) ++ "fixture" ++ theme.reset ++ " " ++ theme.reset ++ "?%" ++ theme.reset ++ ") > input-default") != null);
    ui.finishFrame();
    ui.mode = .calling_model;
    ui.display.reset(0);
    ui.display.observe(.{ .state = .calling_model }, 0);
    for ([_]u64{ 1100, 3100, 9100 }) |now| {
        ui.clock_ms = now;
        try ui.draw();
        const marker = try std.fmt.allocPrint(std.testing.allocator, "{s}) {s}{s}{s} input-default", .{ theme.reset, theme.command_pulse[shared.activity.commandStep(now)], activity.spinner(now), theme.reset });
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
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.low)) ++ "fixture" ++ theme.reset ++ " " ++ theme.reset ++ "?%" ++ theme.reset ++ ") > input-default") != null);
    ui.finishFrame();
    owner.effort = .unspecified;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(fixture ?%) > input-default") != null);
    ui.finishFrame();
}

test "composer frame keeps context occupancy colors static while model and spinner animate" {
    for ([_]bool{ false, true }) |busy| {
        for ([_]u64{ 0, 25, 50 }) |tokens| {
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            ui.display.observe(.{ .context_snapshot = .{ .tokens = tokens, .limit = 100 } }, 0);
            if (busy) ui.mode = .calling_model;
            ui.clock_ms = 80;
            _ = try ui.editor.insert("default-input");
            try ui.draw();
            const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{d}.0%{s}) {s}{s}{s} default-input", .{ if (tokens == 0) theme.success else if (tokens == 25) "\x1b[38;5;220m" else theme.failure, tokens, theme.reset, if (busy) theme.command_pulse[0] else "", if (busy) activity.spinner(80) else ">", if (busy) theme.reset else "" });
            defer std.testing.allocator.free(expected);
            try std.testing.expect(std.mem.find(u8, ui.frame, expected) != null);
            ui.finishFrame();
        }
    }
}

test "pending restored history stays visible with an unmatched tool result and unavailable service" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{ .settings_notice = "Saved service unavailable; use /login or /model" };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    try ui.restoreHistory(&.{
        .{ .role = .user, .blocks = &.{.{ .text = "retained question" }} },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "absent-call", .text = "retained result" } }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "retained answer" }} },
    });
    const count = ui.records.items.len;
    try std.testing.expect(count >= 4);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(fixture.settings_notice.?, try ui.hint(arena.allocator(), ui.connection.current()));
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("new question\r", sink);
    try std.testing.expectEqualStrings(fixture.settings_notice.?, ui.notice);
    try std.testing.expectEqual(count, ui.records.items.len);
    try std.testing.expect(ui.future == null and !ui.busy and ui.has_submitted);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "retained answer") != null);
}

test "composer reflects owner low price policy without reading runtime configuration" {
    try text.initLocale();
    for ([_]bool{ false, true }) |enabled| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture = SelectionFixture{ .low_price_input = enabled };
        defer fixture.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("typed", sink);
        try ui.draw();
        const prefix = if (enabled) theme.success ++ "L3.1%" ++ theme.reset else theme.success ++ "3.1%" ++ theme.reset;
        try std.testing.expect(std.mem.find(u8, ui.frame, prefix) != null);
        try std.testing.expectEqual(enabled, std.mem.find(u8, ui.frame, "L3.1%") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "L ") == null);
        try std.testing.expectEqualStrings("typed", ui.editor.bytes.items);
        try std.testing.expectEqual(@as(usize, 5), ui.editor.cursor);
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay(ui.frame);
        try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], ") > typed") != null);
    }
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
    const position = try std.fmt.allocPrint(std.testing.allocator, "\r\x1b[{d}C" ++ terminal_module.sync_end ++ "\x1b[?25h", .{text.width(decoration) + text.width("hello    你")});
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
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.reset ++ ") " ++ theme.command_pulse[5] ++ "⠧" ++ theme.reset ++ " typed-default-color") != null);
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
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.command_pulse[5] ++ "⠇" ++ theme.reset ++ " typed-default-color") != null);
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
    try std.testing.expect(std.mem.endsWith(u8, ui.frame, "\r\x1b[16C" ++ terminal_module.sync_end ++ "\x1b[?25h"));
    for (screen.grid[22]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
    try std.testing.expectEqualStrings(&raw, ui.editor.bytes.items);
    ui.finishFrame();
    ui.editor.cursor = raw.len;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    try std.testing.expect(std.mem.endsWith(u8, ui.frame, "\r\x1b[78C" ++ terminal_module.sync_end ++ "\x1b[?25h"));
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
    try std.testing.expectEqualStrings("\x18" ++ terminal_module.sync_end ++ "\x1b[999B\r\n", ui.resize_rescue);
    ui.resize(.{ .columns = 80, .rows = 24 });
    ui.finishFrame();
    try std.testing.expect(ui.displayed_permission == null);
    try ui.draw();
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[999B\r\n"));
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
            discardFixtureFrame(&ui);

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
        discardFixtureFrame(&ui);

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
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
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
        const expected = try std.fmt.allocPrint(std.testing.allocator, "\r\n\x1b[0m{s}\x1b[0m\x1b[K\r\x1b[{d}C" ++ terminal_module.sync_end ++ "\x1b[?25h", .{ case.line, case.column - 1 });
        defer std.testing.allocator.free(expected);
        try std.testing.expect(std.mem.endsWith(u8, ui.frame, expected));
        try std.testing.expectEqualStrings(raw, ui.editor.bytes.items);
        discardFixtureFrame(&ui);
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
    low_price_input: bool = false,
    settings_notice: ?[]const u8 = null,
    effort: shared.ReasoningEffort = .none,
    levels: shared.activity.EffortSet = .{ .mask = 0x3f },
    selections: usize = 0,
    cycles: usize = 0,
    provider_saves: usize = 0,
    saved_provider: ?core_config.providers.Id = null,
    provider_hint: ?core_config.providers.Id = null,
    configured_providers: u8 = 0,
    profiles_override: ?[]const core_config.Model = null,
    model_providers: ?[]const ModelProvider = null,
    disabled_models: []const bool = &.{},
    refreshes: usize = 0,
    metadata_changed: bool = false,
    pending_default: ?shared.ReasoningEffort = null,
    metadata_effort: ?shared.ReasoningEffort = null,
    key_matched: bool = false,
    fail: bool = false,
    const profiles = [_]core_config.Model{.{ .name = "fixture-next", .context_tokens = 65536 }};
    fn refreshMetadata(ctx: *anyopaque) !void {
        const self: *SelectionFixture = @ptrCast(@alignCast(ctx));
        self.refreshes += 1;
    }
    fn pollMetadata(ctx: *anyopaque, idle: bool) bool {
        const self: *SelectionFixture = @ptrCast(@alignCast(ctx));
        if (!idle or !self.metadata_changed) return false;
        self.metadata_changed = false;
        if (self.metadata_effort) |level| {
            self.effort = level;
            self.levels = .{ .mask = 0x7f };
            self.pending_default = null;
        }
        return true;
    }
    fn connection(self: *@This()) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .select_model_fn = select, .set_effort_fn = setEffort };
    }
    fn current(raw: *anyopaque) Connection.State {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return .{ .runtime = null, .model = self.name, .models = self.profiles_override orelse &profiles, .model_providers = self.model_providers, .model_disabled = self.disabled_models, .provider = self.provider_hint, .configured_providers = self.configured_providers, .context_limit = self.limit, .low_price_input = self.low_price_input, .settings_notice = self.settings_notice, .initial_context = .{ .tokens = 1000, .limit = self.limit }, .base_url = "http://localhost/unused", .reasoning_effort = self.effort, .effort_levels = self.levels, .pending_default_effort = self.pending_default };
    }
    fn configure(_: *anyopaque, _: []const u8) !void {
        return error.TestSelectionOnly;
    }
    fn configureProvider(raw: *anyopaque, id: core_config.providers.Id, key: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail) return error.TestSelectionFailure;
        self.key_matched = std.mem.eql(u8, key, "fake-ui-key");
        self.saved_provider = id;
        self.configured_providers |= @as(u8, 1) << @intCast(@backingInt(id));
        self.provider_saves += 1;
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

test "unselected startup prompts login and model with no placeholder ID or budget" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .name = "", .model_providers = &.{}, .low_price_input = true, .settings_notice = "Saved thinking level not applied" };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "/login, then /model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "deepseek-flash") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "?%") == null);
    ui.finishFrame();
    ui.openModelPicker();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "No logged-in providers") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fixture-next") == null);
    ui.finishFrame();
    try ui.modelKey(.enter);
    try std.testing.expect(ui.model_picker != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
}

test "model selection and late default completion flash the actual logical level" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .effort = .medium };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.clock_ms = 123;
    try ui.selectModel("fixture-next");
    try std.testing.expectEqual(shared.ReasoningEffort.medium, ui.effort_flash.?.level);
    try std.testing.expectEqual(@as(u64, 2123), ui.effort_flash.?.until_ms);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("fixture-next medium"));
    ui.finishFrame();
    fixture.effort = .unspecified;
    fixture.levels = .{};
    fixture.pending_default = .high;
    try ui.selectModel("fixture-late");
    try std.testing.expect(ui.effort_flash == null);
    fixture.metadata_effort = .high;
    fixture.metadata_changed = true;
    ui.connection.poll_models_fn = SelectionFixture.pollMetadata;
    ui.pollMetadata();
    try std.testing.expectEqual(shared.ReasoningEffort.high, ui.effort_flash.?.level);
    try ui.draw();
    try std.testing.expectEqual(shared.ReasoningEffort.high, ui.display.reasoning_effort);
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("fixture-late high"));
}

test "pending default thinking is explicit and never claims an effective wire option" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .effort = .unspecified };
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var state = fixture.connection().current();
    state.runtime = @ptrFromInt(@alignOf(r.Runtime)); // Hint reads no Runtime memory.
    state.pending_default_effort = .medium;
    const hint_line = try ui.hint(std.testing.allocator, state);
    defer std.testing.allocator.free(hint_line);
    try std.testing.expect(std.mem.find(u8, hint_line, "Default thinking: medium") != null);
    try std.testing.expect(std.mem.find(u8, hint_line, "awaiting model capabilities") != null);
    try std.testing.expectEqual(shared.ReasoningEffort.unspecified, state.reasoning_effort);
}

test "flat logged model list directly shows models and requires exact ACK" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const profiles = [_]core_config.Model{
        .{ .name = "opencode-go/go-id", .context_tokens = 1000000 },
        .{ .name = "proxy/org/model", .context_tokens = 65536 },
        .{ .name = "not-logged/hidden-id", .context_tokens = 65536 },
    };
    const providers = [_]ModelProvider{ .{ .name = "opencode-go" }, .{ .name = "proxy", .allow_custom = true } };
    var fixture: SelectionFixture = .{ .name = "opencode-go/go-id", .profiles_override = &profiles, .model_providers = &providers };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openModelPicker();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Search> ") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Provider> ") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "go-id") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "proxy/org/model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "hidden-id") == null);
    ui.finishFrame();
    try ui.modelKey(.left);
    try std.testing.expect(ui.model_picker == null and ui.commandMenuVisible());
    ui.openModelPicker();
    try ui.modelKey(.down);
    try ui.draw();
    try ui.modelKey(.enter); // A partial frame must not authorize the new row.
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    ui.finishFrame();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try std.testing.expectEqualStrings("proxy/org/model", fixture.name);
}

test "flat model confirmation rejects credential list replacement after ACK" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const profiles = [_]core_config.Model{
        .{ .name = "first/model", .context_tokens = 65536 },
        .{ .name = "replacement/model", .context_tokens = 65536 },
    };
    var fixture: SelectionFixture = .{ .name = "first/model", .profiles_override = &profiles, .model_providers = &.{.{ .name = "first" }} };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openModelPicker();
    try ui.draw();
    ui.finishFrame();
    fixture.model_providers = &.{.{ .name = "replacement" }};
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    ui.finishFrame();
    try ui.modelKey(.enter);
    try std.testing.expectEqualStrings("replacement/model", fixture.name);
}

test "model picker rejects disabled unknown protocol even after frame acknowledgement" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .disabled_models = &.{true} };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.size = .{ .columns = 100, .rows = 24 };
    ui.openModelPicker();
    try ui.modelKey(.down);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Protocol unknown") != null);
    ui.finishFrame();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try std.testing.expect(ui.model_picker != null);
    // Disabling a row after its acknowledged frame is also checked at Enter.
    fixture.disabled_models = &.{};
    try ui.draw();
    ui.finishFrame();
    fixture.disabled_models = &.{true};
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
}

test "metadata refresh command excludes paste and revokes picker confirmation after catalog changes" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.refresh_models_fn = SelectionFixture.refreshMetadata;
    ui.connection.poll_models_fn = SelectionFixture.pollMetadata;
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/model --refresh\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.refreshes);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try ui.parser.feed("\x1b[200~/model --refresh\x1b[201~\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.refreshes);
    ui.openModelPicker();
    try ui.draw();
    ui.finishFrame();
    fixture.metadata_changed = true;
    ui.pollMetadata();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    ui.finishFrame();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
}

test "green checked candidates preserve full multibyte IDs and configured label spacing" {
    const a = std.testing.allocator;
    try text.initLocale();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const name = try a.alloc(u8, 510);
    defer a.free(name);
    for (0..170) |i| @memcpy(name[i * 3 ..][0..3], "模");
    const value = try std.fmt.allocPrint(a, "> ✓ {s}", .{name});
    defer a.free(value);
    try putCandidateLine(&out.writer, a, 1, value, 400, theme.accent, true);
    try std.testing.expect(std.mem.find(u8, out.written(), name) != null);
    try std.testing.expect(std.mem.find(u8, out.written(), theme.success ++ "✓" ++ theme.accent) != null);
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .provider_hint = .deepseek, .configured_providers = 1 };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openProviderPicker();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.success ++ "✓" ++ theme.accent ++ " DeepSeek") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "configured locally") == null);
}

test "settings callbacks owner publication ACK paste batch and cursor" {
    try text.initLocale();
    const Fixture = struct {
        state: Connection.State = .{ .runtime = null, .model = "fixture", .base_url = "", .decision_configured = true },
        calls: usize = 0,
        fail: bool = false,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.state;
        }
        fn configure(_: *anyopaque, _: []const u8) !void {}
        fn choose(raw: *anyopaque, choice: Connection.DecisionChoice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.fail) return error.SaveFailed;
            self.state.decision_enabled = choice != .off;
            self.state.decision_jev_free = choice == .opencode_jev_free;
            self.state.decision_configured = choice != .off;
            self.state.initial_context = .{ .tokens = 42, .limit = 100 };
        }
        fn save(raw: *anyopaque, setting: Connection.Setting, enabled: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.fail) return error.SaveFailed;
            switch (setting) {
                .low_price_input => self.state.low_price_input_enabled = enabled,
                .decision_enabled => self.state.decision_enabled = enabled,
            }
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = .{ .context = &fixture, .current_fn = Fixture.current, .configure_fn = Fixture.configure, .setting_fn = Fixture.save, .decision_fn = Fixture.choose };
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/settings\r\r", sink);
    try std.testing.expect(ui.settings_open);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    try ui.parser.feed("\r", sink); // No complete ACK.
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 10), screen.col);
    ui.finishFrame();
    try ui.parser.feed("\r\r\x1b[B", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!fixture.state.low_price_input_enabled and ui.settings_menu.selected == 0);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open and !fixture.state.decision_enabled);
    const before_choice = fixture.calls;
    try ui.parser.feed("\x1b[B\r", sink); // Stale navigation cannot confirm.
    try std.testing.expectEqual(before_choice, fixture.calls);
    try ui.draw();
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink); // Partial child output cannot confirm.
    try std.testing.expectEqual(before_choice, fixture.calls);
    ui.finishFrame();
    fixture.state.decision_configured = false; // Preset may be saved with no declaration/key.
    try ui.parser.feed("\r\r\x1b[A", sink);
    try std.testing.expect(fixture.state.decision_enabled and fixture.state.decision_jev_free);
    try std.testing.expect(!ui.decision_open and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(@as(u32, 42), ui.display.context.?.tokens);
    fixture.fail = true;
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink); // Open selected Jev, not toggle.
    try std.testing.expect(ui.decision_open);
    try ui.parser.feed("\x1b[A", sink); // Off.
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(fixture.state.decision_enabled);
    try std.testing.expectEqualStrings("Could not save setting; previous value kept", ui.notice);
    const calls = fixture.calls;
    try ui.parser.feed("\r", sink); // Failed save revoked authority.
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.parser.feed("\x1b[D\r", sink); // Left discards read tail, retains Decision.
    try std.testing.expect(!ui.decision_open and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open);
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.decision_open and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(calls, fixture.calls);
    fixture.state.global_settings_available = false;
    try ui.parser.feed("\x1b[A", sink);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    fixture.state.global_settings_available = true;
    try ui.draw();
    ui.finishFrame();
    const original = ui.size;
    ui.resize(.{ .columns = 8, .rows = original.rows });
    ui.resize(original); // Resize ABA cannot restore authority.
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    ui.resize(.{ .columns = 12, .rows = original.rows });
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    ui.resize(original);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\x1b[200~pasted\x1b[201~\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.parser.feed("\x1b[D", sink);
    try std.testing.expect(!ui.settings_open);
    try std.testing.expectEqual(command_menu_module.Command.settings, ui.command_menu.choice(ui.command_matches).?);
}

test "decision child requires full fresh unclipped ACK and never saves pasted batch tails" {
    try text.initLocale();
    const Fixture = struct {
        state: Connection.State = .{ .runtime = null, .model = "", .base_url = "" },
        calls: usize = 0,
        fn current(raw: *anyopaque) Connection.State {
            return @as(*@This(), @ptrCast(@alignCast(raw))).state;
        }
        fn configure(_: *anyopaque, _: []const u8) !void {}
        fn choose(raw: *anyopaque, choice: Connection.DecisionChoice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.state.decision_enabled = choice != .off;
            self.state.decision_jev_free = choice == .opencode_jev_free;
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = .{ .context = &fixture, .current_fn = Fixture.current, .configure_fn = Fixture.configure, .decision_fn = Fixture.choose };
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r\r", sink);
    try std.testing.expect(ui.decision_open);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    try ui.parser.feed("\r", sink);
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    ui.finishFrame();
    const size = ui.size;
    ui.resize(.{ .columns = 8, .rows = size.rows });
    ui.resize(size);
    try ui.parser.feed("\r", sink); // Resize ABA.
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    ui.resize(.{ .columns = 17, .rows = size.rows });
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink); // Jev identifier clipped by one cell.
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    ui.resize(size);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\x1b[200~\r\x1b[D\x1b[201~\r", sink);
    try std.testing.expect(ui.decision_open);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(!ui.decision_open and ui.settings_menu.selected == 1);
    try ui.parser.feed("\r", sink); // Old child ACK cannot open parent.
    try std.testing.expect(!ui.decision_open);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r\r", sink); // Off works without a declaration.
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!fixture.state.decision_enabled and !ui.decision_open);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    try std.testing.expect(ui.displayed_settings_generation == null and ui.frame_settings_generation == null);
}

test "menus stay above composer share colors and Left returns to acknowledged parent" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    _ = try ui.add(.assistant, "menu-prior-answer");
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try ui.parser.feed("\x1b[B\r", sink); // Move to login, but no fresh ACK yet.
    try std.testing.expect(!ui.provider_open and !ui.secret_mode);
    try std.testing.expectEqual(command_menu_module.Command.auth, ui.command_menu.choice(ui.command_matches).?);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "> /login") != null);
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[18], "  /model"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[19], "> /login"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[20], "  /compact"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("menu-prior-answer"));
    try ui.parser.feed("\r", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ ">   Current endpoint") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.muted ++ "    DeepSeek") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "Provider> " ++ theme.reset) != null);
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[18], ">   Current endpoint"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[21], "    OpenCode Go"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[23], "Provider> "));
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(!ui.provider_open and !ui.secret_mode);
    try std.testing.expectEqual(command_menu_module.Command.auth, ui.command_menu.choice(ui.command_matches).?);
    try ui.parser.feed("\x1b[A", sink); // Return from login to model.
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.success ++ "✓" ++ theme.accent ++ " fixture-old") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.muted ++ "    fixture-next") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "Search> " ++ theme.reset) != null);
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[20], "> ~ fixture-old"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[21], "    fixture-next"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[23], "Search> "));
    try ui.parser.feed("\t\x1b[5~\x1b[6~", sink);
    try std.testing.expectEqual(@as(usize, 0), ui.model_picker.?.selected);
    try std.testing.expectEqualStrings("", ui.model_picker.?.query.bytes.items);
    try ui.parser.feed("\x1b[D", sink);
    try std.testing.expect(ui.model_picker == null and ui.commandMenuVisible());
    try std.testing.expectEqual(command_menu_module.Command.model, ui.command_menu.choice(ui.command_matches).?);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
}

test "model popup shows at most ten bottom rows and keeps the selected item visible" {
    try text.initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var profiles: [12]core_config.Model = undefined;
    for (&profiles, 0..) |*profile, index| profile.* = .{
        .name = try std.fmt.allocPrint(arena.allocator(), "menu-{d:0>2}", .{index}),
        .context_tokens = 32768,
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .profiles_override = &profiles };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openModelPicker();
    try ui.modelKey(.up);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ ">   menu-11") != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    ui.finishFrame();
    var count: usize = 0;
    for (screen.grid) |line| if (std.mem.find(u8, &line, "menu-") != null) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 10), count);
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[12], "    menu-02"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[21], ">   menu-11"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[23], "Search> "));
}

test "secret Escape cancels and Left returns to provider without leaking paste tails" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .provider_hint = .deepseek };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/login\r\x1b[B", sink);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("fake-ui-key", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "API key> " ++ theme.reset) != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fake-ui-key") == null);
    ui.finishFrame();
    try ui.parser.feed("\x1b[Ddiscard-tail", sink);
    try std.testing.expect(ui.provider_open and !ui.secret_mode and ui.secret.len == 0);
    try std.testing.expectEqual(core_config.providers.Id.opencode_zen, ui.provider_choices.items[ui.provider_picker.selected].provider);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode); // Newly reopened parent needs ACK.
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("\x1b[200~fake-ui-key\x1b[201~\x1b[Ddiscard", sink);
    try std.testing.expect(ui.secret_mode and !ui.provider_open);
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!ui.secret_mode and !ui.secret_quarantine and ui.secret.len == 0);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
    for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "authentication failure hint preserves HTTP status and separates thinking notice" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = ui.connection.current();
    state.settings_notice = "Saved thinking level not applied: model capabilities unknown";
    ui.notice = "Failed";
    for ([_]u16{ 401, 403 }) |code| {
        ui.last_terminal = .{ .status = .failed, .detail = error.ModelRequestFailed, .model_failure = .authentication, .http_status = code };
        const hint = try ui.hint(arena.allocator(), state);
        try std.testing.expect(std.mem.startsWith(u8, hint, if (code == 401) "Failed [HTTP 401]" else "Failed [HTTP 403]"));
        try std.testing.expect(std.mem.find(u8, hint, "authentication") != null);
        try std.testing.expect(std.mem.find(u8, hint, "thinking") == null);
    }
    // Keep real persistence failures; hide only unrelated informational warnings.
    state.settings_error = error.TestSettingsFailure;
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "SETTINGS FAILED") != null);
    state.settings_error = null;
    ui.last_terminal = null;
    ui.notice = "Ready";
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "Saved thinking level") != null);
}

test "provider auth Go fresh Enter after pasted key restores ordinary drawn composer" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/login\r", sink);
    try std.testing.expect(ui.provider_open and !ui.secret_mode);
    try ui.parser.feed("\x1b[B\x1b[B\x1b[B\r", sink);
    try std.testing.expect(!ui.secret_mode); // No unseen selection authority.
    try ui.draw();
    for ([_][]const u8{ "DeepSeek", "OpenCode Zen", ">   OpenCode Go", "Provider> " }) |label| try std.testing.expect(std.mem.find(u8, ui.frame, label) != null);
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.secret_mode and !ui.provider_open);
    try std.testing.expectEqual(core_config.providers.Id.opencode_go, ui.secret_provider.?);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.parser.feed("\x1b[200~fake-ui-key\x1b[201~\r", sink);
    try std.testing.expect(ui.secret_mode and ui.secret.failed and fixture.provider_saves == 0);
    try ui.parser.feed("\x15", sink);
    try ui.parser.feed("\x1b[200~fake-ui-key\x1b[201~", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[23], "API key> ***********"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "API key for OpenCode Go") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "https://opencode.ai/zen/go/v1") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fake-ui-key") == null);
    ui.finishFrame();
    try ui.parser.feed("\rsame-read-secret-tail", sink);
    try std.testing.expect(!ui.secret_mode and !ui.secret_quarantine and !ui.parser.secret and ui.secret_provider == null and ui.secret.len == 0);
    try std.testing.expect(ui.parser.stop_feed and !ui.parser.secret_paste and !ui.parser.secret_batch_paste);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (ui.parser.escape) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (ui.parser.utf8) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try ui.draw();
    for ([_][]const u8{ "API key", "***", "fake-ui-key", "same-read-secret-tail" }) |hidden| {
        try std.testing.expect(std.mem.find(u8, ui.frame, hidden) == null);
    }
    try screen.replay(ui.frame);
    for ([_][]const u8{ "API key", "***", "fake-ui-key", "same-read-secret-tail" }) |hidden| try std.testing.expectEqual(@as(usize, 0), screen.count(hidden));
    ui.finishFrame();
    try ui.parser.feed("nexttext", sink);
    try std.testing.expectEqualStrings("nexttext", ui.editor.bytes.items);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(std.mem.find(u8, &screen.grid[23], "nexttext") != null);
    try std.testing.expectEqual(@as(usize, 0), screen.count("same-read-secret-tail"));
    ui.finishFrame();
    try std.testing.expect(fixture.key_matched and fixture.provider_saves == 1);
    try std.testing.expectEqual(core_config.providers.Id.opencode_go, fixture.saved_provider.?);
    try std.testing.expect(std.mem.find(u8, ui.notice, "saved locally") != null);
}

test "provider auth denies partial stale resize reopen and pasted choices" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/login\r", sink);
    try ui.draw();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try ui.parser.feed("\x1b[B", sink);
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try ui.draw();
    ui.finishFrame();
    ui.resize(.{ .columns = 81, .rows = 24 });
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!ui.provider_open);
    try ui.parser.feed("/login\r\r", sink);
    try std.testing.expect(ui.provider_open and !ui.secret_mode);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\x1b[200~fake-ui-key\x1b[201~\r", sink);
    try std.testing.expect(ui.provider_picker.pasted and !ui.secret_mode);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "fake-ui-key") == null);
    ui.finishFrame();
    try ui.parser.feed("\x15\r", sink);
    try std.testing.expect(!ui.secret_mode); // Clear requires a fresh frame too.
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.secret_mode);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
}

test "provider auth requires a visible full label and save failure wipes the key" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .provider_hint = .opencode_go, .configured_providers = 4, .fail = true };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/login\r", sink);
    try std.testing.expectEqual(@as(usize, 3), ui.provider_choices.len);
    ui.size = .{ .columns = 12, .rows = 9 };
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "DeepSeek") != null);
    ui.finishFrame();
    try ui.parser.feed("\rfake-ui-key\r", sink);
    // Entering secret mode deliberately discards the rest of that read.
    try std.testing.expect(ui.secret_mode and ui.secret.len == 0);
    try ui.parser.feed("fake-ui-key\r", sink);
    try std.testing.expect(!ui.secret_mode and ui.secret.len == 0 and ui.secret_provider == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Could not save") != null);
}

test "first DeepSeek login initializes default and Shift Tab preserves budgets and atomic saves" {
    const Session = @import("../app/session.zig").Session;
    const metadata = @import("../app/model_metadata.zig");
    const Fetch = struct {
        fn official(a: std.mem.Allocator, _: Io, id: core_config.providers.Id, key: ?[]const u8) !metadata.Listing {
            try std.testing.expectEqual(core_config.providers.Id.deepseek, id);
            try std.testing.expectEqualStrings("fake-fresh-login", key.?);
            return metadata.parseListing(a,
                \\{"data":[{"id":"deepseek-flash","context_window":131072,"effort":{"supported_levels":["low","high","max"],"default_level":"high"}}]}
            , id);
        }
        fn public(_: std.mem.Allocator, _: Io) !metadata.Listing {
            return .{ .dev_done = true };
        }
    };
    try text.initLocale();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, true, .{ .logging = false, .auto_refresh_models = true });
    defer session.deinit();
    session.metadata_fetch = Fetch.official;
    session.metadata_dev_fetch = Fetch.public;
    try std.testing.expect(session.app == null);
    try session.connection().configure("fake-fresh-login");
    const before = session.app.?.config.value.model;
    try std.testing.expect(before.reasoning == null);
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(a, io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = session.connection();
    try ui.draw();
    ui.finishFrame();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expect(std.mem.find(u8, ui.notice, "are loading") != null);
    try std.testing.expect(session.app.?.config.value.model.reasoning == null);
    try std.testing.expect(session.metadata_job == null); // Shortcut itself never fetches.
    try std.testing.expect(session.connection().poll_models_fn.?(session.connection().context, true));
    const job = session.metadata_job.?;
    if (job.future) |*future| future.await(io);
    job.future = null;
    if (job.dev_future) |*future| future.await(io);
    job.dev_future = null;
    try std.testing.expect(session.connection().poll_models_fn.?(session.connection().context, true));
    // A fresh empty conversation initializes its original medium preference,
    // clamped to this model's high, without cycling or changing request budgets.
    try std.testing.expectEqual(@as(u8, 0x55), session.connection().current().effort_levels.mask);
    try std.testing.expectEqual(shared.ReasoningEffort.high, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(shared.ReasoningEffort.medium, shared.ReasoningEffort.fromName(session.global_config.?.value.registry.?.reasoning_effort orelse "medium"));
    const saved_settings = try tmp.dir.readFileAlloc(io, ".thin/config.json", a, .limited(65536));
    defer a.free(saved_settings);
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/config.json", .data = "{}" });
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Could not save") != null);
    try std.testing.expect(session.app.?.config.value.model.reasoning != null);
    try std.testing.expectEqual(shared.ReasoningEffort.high, session.connection().current().reasoning_effort);
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/config.json", .data = saved_settings });
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expectEqual(shared.ReasoningEffort.max, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(before.context_tokens, session.app.?.config.value.model.context_tokens);
    try std.testing.expectEqual(before.output_tokens, session.app.?.config.value.model.output_tokens);
    try std.testing.expectEqual(before.input_price_threshold, session.app.?.config.value.model.input_price_threshold);
    try std.testing.expectEqual(before.protocol, session.app.?.config.value.model.protocol);
    // The adopted map must be owned, not borrowed from movable cache storage.
    session.metadata_cache = .{};
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(shared.ReasoningEffort.off, session.connection().current().reasoning_effort);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(shared.ReasoningEffort.low, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(shared.ReasoningEffort.low, shared.ReasoningEffort.fromName(session.global_config.?.value.registry.?.reasoning_effort));
    const wire = r.withReasoning(session.app.?.config.value, .{ .scope = .{ .connection = "https://api.deepseek.com", .model = "deepseek-flash", .protocol = .chat }, .system = "", .tools = &.{}, .messages = &.{}, .max_output_tokens = 128 });
    try std.testing.expectEqualStrings("low", wire.reasoning_effort.?);
    try std.testing.expect(wire.thinking.?);
    var disk = try session.store.loadExisting();
    defer core_config.release(&disk);
    try std.testing.expect(disk.value.registry.?.find("deepseek").?.patchFor("deepseek-flash").?.reasoning == null);
    try std.testing.expect(!session.app.?.journal.started);
}

test "effort confirmation expires after two seconds and repeated switches restart it" {
    var fixture: SelectionFixture = .{ .effort = .low, .levels = .{ .mask = 0x55 } };
    defer fixture.deinit();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(screen.visible("fixture-old 3.1%"));
    try std.testing.expect(ui.effort_flash == null);

    ui.clock_ms = 1000;
    ui.cycleEffort(); // low -> high, expires at 3000.
    const context = ui.display.context;
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(screen.visible("fixture-old high"));
    try std.testing.expectEqualDeep(context, ui.display.context);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    try std.testing.expectEqual(text.width("(fixture-old high) > "), screen.col);

    ui.clock_ms = 2500;
    ui.cycleEffort(); // high -> max, now expires at 4500 instead.
    ui.dirty = false;
    ui.clock_ms = 3000;
    ui.expireEffortFlash();
    try std.testing.expect(!ui.dirty);
    fixture.fail = true;
    ui.cycleEffort(); // Failed save neither changes the level nor extends time.
    try std.testing.expectEqual(@as(u64, 4500), ui.effort_flash.?.until_ms);
    try std.testing.expectEqual(shared.ReasoningEffort.max, ui.effort_flash.?.level);
    ui.clock_ms = 4499;
    ui.dirty = false;
    ui.expireEffortFlash();
    try std.testing.expect(!ui.dirty);
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(screen.visible("fixture-old max"));

    ui.display.context = .{ .tokens = 2000, .limit = fixture.limit };
    ui.clock_ms = 4500;
    ui.expireEffortFlash(); // Idle expiry schedules a redraw without a keypress.
    try std.testing.expect(ui.dirty and ui.effort_flash == null);
    try ui.draw();
    try screen.replay(ui.frame);
    ui.finishFrame();
    try std.testing.expect(screen.visible("fixture-old 6.1%"));
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    ui.cycleEffort();
    try std.testing.expect(ui.effort_flash == null);
    fixture.fail = false;
    ui.cycleEffort();
    try ui.selectModel("fixture-next");
    try std.testing.expectEqual(fixture.effort.canonical(), ui.effort_flash.?.level);
    try std.testing.expectEqual(@as(u64, 6500), ui.effort_flash.?.until_ms);
}

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
    // An external connection may still supply an unspecified current value.
    // Its first shortcut chooses a supported level, not capabilities unknown.
    fixture.effort = .unspecified;
    ui.cycleEffort();
    try std.testing.expectEqual(shared.ReasoningEffort.off, fixture.effort);
    try std.testing.expectEqual(@as(usize, 5), fixture.cycles);
}

test "slash menu shows model login compact with arguments and descriptions but no shortcut hints" {
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
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };

    // Typing `/` opens the menu without executing anything.
    try ui.parser.feed("/", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Commands") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Configure provider") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/model [exact-id|--refresh]  Select model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/compact") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Compact conversation") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Type to filter; Tab complete") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Up/Down select; Enter run") == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    ui.finishFrame();

    // Case-insensitive filtering keeps only the matching entry.
    try ui.parser.feed("LO", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "/login") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/model") == null);
    ui.finishFrame();

    // Esc dismisses until the token changes again.
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!ui.commandMenuVisible());
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Commands") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Configure provider") == null);
    // The independent setup hint remains; it is not a menu item.
    try std.testing.expect(std.mem.find(u8, ui.frame, "Not configured: /login") != null);
    ui.finishFrame();
    try ui.parser.feed("G", sink);
    try std.testing.expect(ui.commandMenuVisible());
    try ui.draw();
    ui.finishFrame();

    // Enter runs the highlighted `/login`, which here means entering key entry.
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.secret_mode);
    try std.testing.expect(!ui.commandMenuVisible());
}

test "slash menu enter selects the highlighted model entry" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    // The first entry is `/model`, which opens the model picker rather than
    // switching directly, so the fixture records no selection yet.
    try std.testing.expectEqual(command_menu_module.Command.model, ui.command_menu.choice(ui.command_matches).?);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.model_picker == null);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.model_picker != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
}

test "slash menu Tab completes only an ACKed choice without executing while ordinary Tab indents" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    try ui.draw();
    // A partial frame cannot authorize even a text-only completion.
    ui.frame_offset = ui.frame.len / 2;
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    ui.finishFrame();
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/model", ui.editor.bytes.items);
    try std.testing.expectEqual(ui.editor.bytes.items.len, ui.editor.cursor);
    try std.testing.expect(ui.model_picker == null and ui.commandMenuVisible());
    try std.testing.expect(!ui.busy and !ui.secret_mode and !ui.provider_open);
    try std.testing.expect(ui.displayed_command_generation == null);
    try ui.draw();
    try std.testing.expect(ui.commandMenuVisible());
    ui.finishFrame();
    try ui.parser.feed("\t", sink); // Already complete: no spaces, cycling or action.
    try std.testing.expectEqualStrings("/model", ui.editor.bytes.items);
    try std.testing.expect(ui.model_picker == null and !ui.busy);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.model_picker != null);
    try ui.modelKey(.escape);
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("    ", ui.editor.bytes.items);
}

test "slash menu Tab canonicalizes filtered commands without opening surfaces or jobs" {
    for ([_]struct { prefix: []const u8, full: []const u8 }{
        .{ .prefix = "/mo", .full = "/model" },
        .{ .prefix = "/LG", .full = "/login" },
        .{ .prefix = "/cpt", .full = "/compact" },
        .{ .prefix = "/stg", .full = "/settings" },
    }) |case| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed(case.prefix, sink);
        try ui.parser.feed("\t", sink); // No visible ACK yet.
        try std.testing.expectEqualStrings(case.prefix, ui.editor.bytes.items);
        try ui.draw();
        ui.finishFrame();
        try ui.parser.feed("\t", sink);
        try std.testing.expectEqualStrings(case.full, ui.editor.bytes.items);
        try std.testing.expectEqual(case.full.len, ui.editor.cursor);
        try std.testing.expect(!ui.busy and !ui.secret_mode and !ui.provider_open and ui.model_picker == null);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    }
}

test "slash menu Tab honors highlighted selection only after a new ACK" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\x1b[B\t", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/login", ui.editor.bytes.items);
    try std.testing.expect(!ui.secret_mode and !ui.provider_open and ui.model_picker == null and !ui.busy);
}

test "slash menu pasted Tab remains literal and never completes" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~/mo\t\x1b[201~", sink);
    try std.testing.expectEqualStrings("/mo\t", ui.editor.bytes.items);
    try std.testing.expect(!ui.commandMenuVisible() and !ui.busy and ui.model_picker == null);
}

test "slash menu rejects stale navigation generations and resize ABA" {
    for ([_]bool{ false, true }) |resize_case| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("/", sink);
        try ui.draw();
        if (resize_case) {
            const original = ui.size;
            ui.resize(.{ .columns = original.columns - 1, .rows = original.rows });
            ui.resize(original);
        } else {
            // Same token/choice after clear must not inherit the earlier frame.
            try ui.parser.feed("\x15/", sink);
        }
        ui.finishFrame();
        try ui.parser.feed("\t", sink);
        try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
        try ui.parser.feed("\r", sink);
        try std.testing.expect(ui.model_picker == null and !ui.secret_mode);
        try ui.draw();
        ui.finishFrame();
        try ui.parser.feed("lg\t\r", sink);
        try std.testing.expect(!ui.secret_mode); // Changed token/selection is not yet shown.
        try ui.draw();
        ui.finishFrame();
        try ui.parser.feed("\r", sink);
        try std.testing.expect(ui.secret_mode);
    }
}

test "popup close restores every visible transcript row for root provider and model menus" {
    try text.initLocale();
    for ([_]usize{ 2, 60 }) |history_length| {
        for ([_]terminal_module.Size{
            .{ .columns = 80, .rows = 24 }, .{ .columns = 16, .rows = 24 },
            .{ .columns = 16, .rows = 12 }, .{ .columns = 16, .rows = 7 },
            .{ .columns = 9, .rows = 7 },
        }) |dimensions| {
            for ([_][]const u8{ "/", "/login\r", "/model\r" }) |command| {
                var cancel = p.Cancellation{};
                var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
                defer bridge.deinit();
                var fixture = SelectionFixture{};
                defer fixture.deinit();
                var ui = fixtureUi(&bridge, &cancel);
                defer ui.deinit();
                ui.connection = fixture.connection();
                ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
                ui.size = dimensions;
                var history: std.ArrayList(u8) = .empty;
                defer history.deinit(std.testing.allocator);
                for (0..history_length) |i| {
                    const line = try std.fmt.allocPrint(std.testing.allocator, "{s}row-{d:0>3}", .{ if (i == 0) "" else "\n", i });
                    defer std.testing.allocator.free(line);
                    try history.appendSlice(std.testing.allocator, line);
                }
                _ = try ui.add(.assistant, history.items);
                var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = dimensions.columns, .rows = dimensions.rows };
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                const before = screen.grid;
                const history_before = screen.history_len;
                const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
                try ui.parser.feed(command, sink);
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                // Locate the actual first candidate, not merely missing labels.
                var first: ?usize = null;
                for (screen.grid, 0..) |line, i| {
                    if (std.mem.startsWith(u8, &line, "> ")) {
                        first = i;
                        break;
                    }
                }
                try std.testing.expect(first != null and first.? > 0);
                try std.testing.expectEqualStrings("", std.mem.trim(u8, &screen.grid[first.? - 1], " "));
                // Popup borrowing is reversible and must not scroll long history.
                try std.testing.expectEqual(history_before, screen.history_len);
                try ui.parser.feed("\x1b", sink);
                try ui.parser.expireEscape(sink);
                try ui.parser.feed("\x15", sink);
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                for (before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                    try std.testing.expectEqualStrings(&old, &restored);
                try std.testing.expectEqual(history_before, screen.history_len);
                // A second ordinary frame must retain the repaired history too.
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                for (before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                    try std.testing.expectEqualStrings(&old, &restored);
                if (history_length == 60) {
                    // History preview is rebuilt from canonical records. Popup
                    // restoration rows must not precede that complete history.
                    const browsing_before = screen.grid;
                    for (0..8) |_| try ui.parser.feed("\x1b[5~", sink);
                    try ui.draw();
                    try screen.replay(ui.frame);
                    ui.finishFrame();
                    const first_preview_row = dimensions.rows - ui.tail_height;
                    try std.testing.expectEqualStrings("row-000", std.mem.trim(u8, &screen.grid[first_preview_row], " "));
                    try std.testing.expectEqual(history_before, screen.history_len);
                    for (0..8) |_| try ui.parser.feed("\x1b[6~", sink);
                    try ui.draw();
                    try screen.replay(ui.frame);
                    ui.finishFrame();
                    try std.testing.expectEqual(@as(usize, 0), ui.scroll);
                    for (browsing_before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                        try std.testing.expectEqualStrings(&old, &restored);
                    try std.testing.expectEqual(history_before, screen.history_len);
                }
                _ = try ui.add(.assistant, "new-row");
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                // Releasing a repaired prefix for subsequent output must not
                // duplicate or lose ANY earlier line, including native history.
                for (0..history_length) |i| {
                    var marker: [16]u8 = undefined;
                    const value = try std.fmt.bufPrint(&marker, "row-{d:0>3}", .{i});
                    try std.testing.expectEqual(@as(usize, 1), screen.count(value));
                }
                try std.testing.expectEqual(@as(usize, 1), screen.count("new-row"));
                const before_resize = screen.grid;
                try ui.parser.feed(command, sink);
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                // A width ABA revokes all physical coordinates even though the
                // final grid width is unchanged. Reconstruct from retained
                // canonical display records, never reclaim the stale backing.
                ui.resize(.{ .columns = dimensions.columns - 1, .rows = dimensions.rows });
                ui.resize(dimensions);
                try std.testing.expect(ui.menu_history_recovery);
                try ui.draw();
                try std.testing.expect(std.mem.find(u8, ui.frame[0..ui.frame_clear_end], "\x1b[999B") != null);
                try screen.replay(ui.frame);
                ui.finishFrame();
                try ui.parser.feed("\x1b", sink);
                try ui.parser.expireEscape(sink);
                try ui.parser.feed("\x15", sink);
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                for (before_resize[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                    try std.testing.expectEqualStrings(&old, &restored);
                try ui.parser.feed(command, sink);
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                const resized: terminal_module.Size = if (dimensions.rows == 12)
                    .{ .columns = 80, .rows = 24 }
                else
                    .{ .columns = 16, .rows = 12 };
                ui.resize(resized);
                // This bounded no-reflow grid models the changed geometry;
                // every transcript marker fits both widths. No physical reflow
                // behavior or native viewport position is inferred here.
                screen.columns = resized.columns;
                screen.rows = resized.rows;
                screen.row = @min(screen.row, resized.rows - 1);
                screen.col = @min(screen.col, resized.columns - 1);
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                try ui.parser.feed("\x1b", sink);
                try ui.parser.expireEscape(sink);
                try ui.parser.feed("\x15", sink);
                try ui.draw();
                try screen.replay(ui.frame);
                ui.finishFrame();
                const body_rows = resized.rows - 3;
                const start = (history_length + 2) -| body_rows;
                for (0..body_rows) |row| {
                    const index = start + row;
                    var marker: [16]u8 = undefined;
                    const expected = if (index < history_length)
                        try std.fmt.bufPrint(&marker, "row-{d:0>3}", .{index})
                    else if (index == history_length + 1) "new-row" else "";
                    try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, &screen.grid[row], " "));
                }
            }
        }
    }
}

test "slash menu grows a short tail and cannot authorize a clipped panel" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    ui.tail_height = 2;
    try ui.parser.feed("/", sink);
    try ui.draw();
    try std.testing.expect(ui.frame_height >= 4);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/login") != null);
    ui.finishFrame();
    ui.resize(.{ .columns = 7, .rows = 6 });
    try ui.draw();
    ui.finishFrame();
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.model_picker == null and !ui.secret_mode);
}

test "slash menu never opens for pasted arguments unknown tokens or busy sessions" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~/login\x1b[201~", sink);
    try std.testing.expect(!ui.commandMenuVisible());
    try ui.parser.feed("\x15/Z", sink);
    try std.testing.expect(!ui.commandMenuVisible());
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("/", sink);
    try std.testing.expect(ui.commandMenuVisible());
    ui.busy = true;
    ui.refreshCommandMenu();
    try std.testing.expect(!ui.commandMenuVisible());
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
    try std.testing.expect(std.mem.find(u8, ui.frame, "Search> ") != null);
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
    // 切换档位后，输入框百分比位置短暂显示新档位名。
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.minimal)) ++ "fixture-next" ++ theme.reset ++ " " ++ (comptime theme.effortColor(.minimal)) ++ "minimal" ++ theme.reset ++ ") > ") != null);
    ui.finishFrame();
    // 2 秒后自动恢复为上下文百分比。
    ui.clock_ms = 2001;
    ui.expireEffortFlash();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.minimal)) ++ "fixture-next" ++ theme.reset ++ " " ++ theme.success ++ "1.5%" ++ theme.reset ++ ") > ") != null);
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

test "shutdown restores terminal and handles signals without announcing identity" {
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
        try std.testing.expectEqual(@as(u8, if (later) 130 else 143), try finishExit(&terminal, 0, Reader.read));
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
    normal_calls: usize = 0,
    summary_calls: usize = 0,

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

    fn call(ctx: *anyopaque, _: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *AuthFixture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (request.purpose == .summary) self.summary_calls += 1 else self.normal_calls += 1;
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "fixture done" }} }, .finish = .stop } };
    }

    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return error.UnexpectedTool;
    }

    fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        return error.UnexpectedTool;
    }
};

test "compact slash menu requires acknowledged choice then joins a summary-only job" {
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
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
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/compact\r", sink);
    try std.testing.expectEqualStrings("No conversation to compact yet", ui.notice);
    try std.testing.expect(ui.future == null and !ui.busy);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    const old: [8192]u8 = @splat('a');
    const a = runtime.arena.allocator();
    try runtime.history.append(a, try p.textMessage(a, .user, &old));
    try runtime.history.append(a, try p.textMessage(a, .assistant, "old answer"));
    try runtime.history.append(a, try p.textMessage(a, .user, "latest goal"));
    try runtime.history.append(a, try p.textMessage(a, .assistant, "latest answer"));
    runtime.protected_index = 2;
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .context_snapshot = .{ .tokens = 1, .limit = 100 } }, &cancel);
    try ui.parser.feed("/compact\r", sink);
    try std.testing.expectEqualStrings("Compaction requires a drained session bridge", ui.notice);
    try std.testing.expect(ui.future == null);
    var pending = bridge.pop().?;
    pending.deinit();
    try ui.parser.feed("/compact unexpected\r", sink);
    try std.testing.expectEqualStrings("Usage: /compact (no arguments)", ui.notice);
    try std.testing.expect(ui.future == null);
    try ui.parser.feed("/co", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "/compact  Compact conversation") != null);
    try ui.parser.feed("\r", sink); // Built but not ACKed: no action.
    try std.testing.expect(ui.future == null);
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink); // Partial output still has no authority.
    try std.testing.expect(ui.future == null);
    ui.finishFrame();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.busy and ui.future != null and ui.prompt == null);
    try std.testing.expectEqual(.compact, ui.job.kind);
    try ui.complete();
    try std.testing.expect(!ui.busy and ui.future == null);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expectEqual(@as(usize, 1), fixture.summary_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.normal_calls);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    for (runtime.messages()) |message| for (message.blocks) |block| {
        if (block == .text) try std.testing.expect(!std.mem.eql(u8, block.text, "/compact"));
    };
    try std.testing.expectEqual(p.Role.context, runtime.messages()[0].role);
    try std.testing.expect(!ui.last_terminal.?.context_snapshot.?.known);
}

test "bang commands use local job with zero main calls and reject unsafe submissions" {
    var config = core_config.Config{ .provider = .{ .base_url = "http://localhost/unused" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{ .configured = true };
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "", false);
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    for (0..6) |case| {
        ui.wipeEditor();
        _ = try ui.editor.insert(if (case == 0) " ! \t" else "!echo fixture");
        ui.busy = case == 1;
        ui.poisoned = case == 2;
        ui.editor_pasted = case == 3;
        ui.parser.escape_len = if (case == 4) 2 else 0;
        ui.want_exit = case == 5;
        try ui.submit();
        try std.testing.expect(ui.future == null and ui.prompt == null);
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
        ui.busy = false;
        ui.poisoned = false;
        ui.want_exit = false;
        ui.parser.escape_len = 0;
    }
    ui.wipeEditor();
    try ui.parser.feed("\x1b[200~!echo pasted\x1b[201~\r", sink);
    try std.testing.expect(ui.future == null);
    try ui.parser.feed("\r", sink); // Sticky paste remains untrusted.
    try std.testing.expect(ui.future == null);
    ui.wipeEditor();
    try ui.parser.feed("  !echo fixture  ", sink);
    try ui.parser.feed("\r!echo batch-tail\r", sink);
    try std.testing.expect(ui.busy and ui.future != null);
    try std.testing.expectEqual(.command, ui.job.kind);
    try std.testing.expectEqualStrings("  !echo fixture  ", ui.job.prompt);
    try std.testing.expectEqual(.executing_tool, ui.mode);
    try std.testing.expectEqualStrings("Running command", ui.notice);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try ui.complete();
    try std.testing.expect(ui.future == null and !ui.busy);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    fixture.runtime = null;
    fixture.configured = false;
    try ui.parser.feed("!echo unavailable\r", sink);
    try std.testing.expect(ui.future == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "compact command rejects busy pasted poisoned and unconfigured states without a job" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    for (0..3) |case| {
        _ = try ui.editor.insert("/compact");
        ui.busy = case == 0;
        ui.editor_pasted = case == 1;
        ui.poisoned = case == 2;
        try ui.submit();
        try std.testing.expect(ui.future == null);
        try std.testing.expectEqualStrings("Compaction requires an idle, non-pasted session", ui.notice);
        ui.busy = false;
        ui.poisoned = false;
    }
    try ui.parser.feed("/compact\r", .{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
}

test "unconfigured text and slash commands never create jobs records or expose arguments" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("hello\r", sink);
    try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
    try ui.parser.feed("/login sk-accidental-secret", sink);
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
    try ui.parser.feed("/login\rdiscard-command-batch-tail", sink);
    try std.testing.expect(ui.secret_mode and ui.secret.len == 0);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
}

test "slash composer frames keep model prefixes and hide credentials with command specific hints" {
    try text.initLocale();
    const cases = [_]struct { raw: []const u8, shown: []const u8, hidden: ?[]const u8 = null }{
        .{ .raw = "/model", .shown = "/model" },
        .{ .raw = "/model ", .shown = "/model " },
        .{ .raw = "/model\t", .shown = "/model    " },
        .{ .raw = "/model \t  ", .shown = "/model       " },
        .{ .raw = "/model provider/model-pre", .shown = "/model provider/model-pre" },
        .{ .raw = "/model malformed extra", .shown = "/model [arguments hidden; use one model ID]", .hidden = "malformed" },
        .{ .raw = "/login fakecredential", .shown = "/login [arguments hidden; no key argument]", .hidden = "fakecredential" },
        .{ .raw = "/compact fakecredential", .shown = "/compact [arguments hidden; no arguments]", .hidden = "fakecredential" },
        .{ .raw = "/unknown fakecredential", .shown = "/ [command arguments hidden]", .hidden = "fakecredential" },
    };
    for (cases) |case| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture = SelectionFixture{};
        defer fixture.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
        // Insert literal bytes: a physical Tab is a completion key, not an argument.
        _ = try ui.editor.insert(case.raw);
        try ui.draw();
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay(ui.frame);
        try std.testing.expect(std.mem.find(u8, &screen.grid[23], case.shown) != null);
        if (case.hidden) |hidden| {
            try std.testing.expect(std.mem.find(u8, ui.frame, hidden) == null);
            try std.testing.expectEqual(@as(usize, 0), screen.count(hidden));
        }
        if (!std.mem.startsWith(u8, case.raw, "/login")) {
            try std.testing.expect(std.mem.find(u8, &screen.grid[23], "/login") == null);
        }
        try std.testing.expectEqualStrings(case.raw, ui.editor.bytes.items);
        ui.finishFrame();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("\r", sink);
        try std.testing.expect(!ui.secret_mode and !ui.provider_open);
        try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
    }
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
    try ui.parser.feed("/login\r", sink);
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
    try ui.parser.feed("/login\r", sink);
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
    try ui.parser.feed("/login\r", sink);
    try ui.parser.feed("key\x04exit-tail", sink);
    try std.testing.expect(ui.want_exit and !ui.secret_mode and ui.secret.len == 0);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
}

test "configure enables same-process submit without sending secrets or commands" {
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
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
    try ui.parser.feed("/login\r", sink);
    try ui.parser.feed("\x1b[200~sk-fixture-secret\x1b[201~", sink);
    try ui.parser.feed("\rsecret-tail", sink);
    try std.testing.expectEqualStrings("Saved locally; send a message to connect", ui.notice);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Saved locally; send a message to connect") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Esc closes") == null);
    try std.testing.expect(!ui.secret_mode and !ui.secret_quarantine);
    try std.testing.expect(std.mem.find(u8, ui.frame, "sk-fixture-secret") == null);
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 1), fixture.saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    for (ui.secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("/login\r", sink);
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
