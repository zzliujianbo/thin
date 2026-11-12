//! ThinAgent 终端界面（TUI）模块。
//! 职责：维护对话显示记录、把 Markdown 渲染为终端行、处理键盘输入与工具审批，
//! 并通过 bridge 与运行时后台任务（Job）通信。绘制采用“整帧生成 + 分段写出”。
const std = @import("std");
const r = @import("../core/runtime.zig");
const inbox_module = @import("../core/inbox.zig");
const p = @import("../core/protocol.zig");
const core_config = @import("../core/config.zig");
const task = @import("../core/task.zig");
const interrupt = @import("../platform/interrupt.zig");
const terminal_module = @import("terminal.zig");
const input = @import("input.zig");
const composer_layout = @import("composer_layout.zig");
const picker_module = @import("model_picker.zig");
const provider_picker_module = @import("provider_picker.zig");
const corecodex = @import("../core/codex_login.zig");
const command_menu_module = @import("command_menu.zig");
const resume_picker_module = @import("resume_picker.zig");
const settings_menu_module = @import("settings_menu.zig");
const decision_picker_module = @import("decision_picker.zig");
const proxy_picker_module = @import("proxy_picker.zig");
const preference = @import("../core/settings.zig");
const settings_value_module = @import("settings_value_picker.zig");
const local_command_output = @import("local_command_output.zig");
const tool_views_module = @import("tool_views.zig");
const text = @import("text.zig");
const markdown = @import("markdown.zig");
const body_stream = @import("body_stream.zig");
const plain_tail = @import("plain_tail.zig");
const tail_frame = @import("tail_frame.zig");
const StreamPrefix = @import("stream_prefix.zig").Prefix;
const theme = @import("theme.zig");
const activity = @import("activity.zig");
const presentation = @import("presentation.zig");
const shared = @import("../presentation.zig");
const bridge_module = @import("bridge.zig");
const session_client = @import("session_client.zig");
const memory_status = @import("../core/memory_status.zig");
const background_status = @import("../core/background_status.zig");
const remote_action = @import("remote_action.zig");
const Io = std.Io;

pub const ModelProvider = picker_module.Provider;

/// Ordinary body-repaint cadence. Pending work is coalesced onto this interval,
/// measured from the previous draw's start; input and geometry never wait for it.
const draw_interval_ms: u16 = 8;

const StopIdentity = struct {
    runtime: ?*r.Runtime,
    session: ?[32]u8,
    task_epoch: u64,
    revision: u64,
    busy: bool,
    /// Remote control epoch: takeover makes an open confirmation stale.
    remote_epoch: u64 = 0,
};

/// 单条显示记录的字节上限（128 KiB）。超出部分只影响显示，不影响模型历史。
const canonical_mirror_limit = 128 * 1024;

/// Thinking is a bounded rolling display window, not a transcript: one visible
/// row over a fixed conservative retained budget (the tail clamps terminals to
/// 512 columns). The canonical provider/reasoning history is a separate owner.
const reasoning_tail_rows = 1;
const reasoning_tail_bytes = 64 * 1024;

/// 显示记录的种类：用户输入、助手正文、推理内容、工具事件、系统提示。
const Kind = enum { user, assistant, reasoning, tool, notice };

/// Conversation-only notice severity. Red/yellow never reach the footer.
const NoticeLevel = enum { plain, warning, failure };

/// 对话区中的一条显示记录。body 保存原始 UTF-8 文本；渲染结果缓存在 cache 的 arena 中。
const AgentRow = struct {
    view: @import("../core/subagent_status.zig").AgentView,
    record_id: u64,
};

const Record = struct {
    id: u64 = 0,
    stream_generation: u64 = 0,
    /// 记录种类，决定标题与 Markdown 渲染方式。
    kind: Kind,
    /// Notice-only tone; all other kinds render exactly as before.
    notice_level: NoticeLevel = .plain,
    /// One physical display row: the body is clipped to the real screen width
    /// with an ellipsis instead of wrapping. Only compact confirmations (the
    /// Memory saved result) opt in; every other notice keeps paragraph
    /// rendering so no real failure text is ever cut away.
    single_row: bool = false,
    /// Compact completion caption; explicit local output uses a separate plain record.
    command_row: bool = false,
    agent_row: bool = false,
    agent_open: bool = false,
    /// Measured wall-clock execution time of this row; null when unobserved.
    duration_ms: ?u64 = null,
    command_spans: std.ArrayList(presentation.CommandSpan) = .empty,
    /// Only a fully written frame commits transcript delivery. Pending survives index shifts.
    output: bool = false,
    pending_output: bool = false,
    /// Display-only streamed rows released above the mutable tail. Never model
    /// history or canonical output. Copies survive layout invalidation.
    flow_prefix: ?StreamPrefix = null,
    pending_flow_prefix: ?StreamPrefix = null,
    pending_flow_change: bool = false,
    /// Exact full-prefix comparison for the current layout cache; null means
    /// unknown. Reset by invalidate() and by every committed-prefix change, so a
    /// repaint of an unchanged cache never rescans all released rows.
    flow_match: ?bool = null,
    /// pending_flow_prefix rows were taken from the still-current lines cache.
    pending_flow_layout_valid: bool = false,
    /// Test-only evidence that a cached comparison skipped the exact scan.
    /// Outside test builds this is void: production ships no tracking storage.
    flow_scan_count: if (@import("builtin").is_test) usize else void = if (@import("builtin").is_test) 0 else {},
    /// Static text is complete; active assistant bodies use a bounded comparison mirror.
    body: std.ArrayList(u8) = .empty,
    /// 文本超过上限被截断；渲染时会附加提示。
    clipped: bool = false,
    /// A full comparison mirror does not mean streamed output was clipped.
    mirror_full: bool = false,
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
    /// Incremental active-answer body: sanitizer, bounded parser window, rows
    /// with parser-source provenance. Null for static/batch records.
    stream: ?*body_stream.Body = null,
    /// Rows already written AND fully ACKed into native scrollback.
    stream_written: usize = 0,
    /// Rows written by the in-flight frame; committed only on a full fresh ACK.
    pending_stream_rows: usize = 0,
    /// A real canonical revision replaced already-released stream rows.
    stream_revised: bool = false,
    /// Static records (restored history) deliberately use the batch renderer.
    batch: bool = false,
    /// Heap-owned bounded incremental thinking tail. It survives invalidate()
    /// and Record moves unchanged (the Writer sink points at the heap Tail, not
    /// at this record) and is destroyed exactly once, in deinit().
    tail: ?*plain_tail.Tail = null,
    /// Absolute source end this record's rows have actually proven visible for
    /// the CURRENT stream generation. Persists across frames: displayed content
    /// stays displayed, and a later fence for the same generation may use it.
    delivery_visible: usize = 0,
    /// At least one complete fresh frame displayed every row this record had at
    /// the time (no cropped tail, no modal replacement).
    delivery_complete: bool = false,

    /// 释放渲染缓存，下次 layout 时重新渲染。
    fn invalidate(self: *Record) void {
        if (self.cache) |*cache| cache.deinit();
        self.cache = null;
        self.lines = &.{};
        // A staged checkpoint belongs to the cache it was copied from.
        self.flow_match = null;
        self.pending_flow_layout_valid = false;
    }

    /// 释放记录占用的全部内存（渲染缓存与原始文本）。
    fn deinit(self: *Record, a: std.mem.Allocator) void {
        self.invalidate();
        if (self.stream) |stream| stream.destroy();
        self.stream = null;
        if (self.tail) |tail| tail.destroy();
        self.tail = null;
        if (self.flow_prefix) |*prefix| prefix.deinit();
        self.discardPendingFlow();
        self.body.deinit(a);
        self.command_spans.deinit(a);
    }

    fn discardPendingFlow(self: *Record) void {
        if (self.pending_flow_prefix) |*prefix| prefix.deinit();
        self.pending_flow_prefix = null;
        self.pending_flow_change = false;
        self.pending_flow_layout_valid = false;
    }

    /// Cached exact prefix comparison. Only a layout invalidation (or a new
    /// committed prefix) clears it, so ordinary repaints reuse the verdict.
    fn flowMatches(self: *Record, columns: usize) bool {
        const shown = if (self.flow_prefix) |*prefix| prefix else return false;
        // A width that is not this cache's layout cannot reuse or overwrite its
        // verdict. Callers re-layout before asking for a real comparison.
        if (columns != self.columns or self.cache == null) return false;
        if (self.flow_match) |cached| return cached;
        if (@import("builtin").is_test) self.flow_scan_count += 1;
        const matched = shown.matches(self.lines, columns);
        self.flow_match = matched;
        return matched;
    }

    fn stageFlow(self: *Record, a: std.mem.Allocator, count: usize) !bool {
        if (count > self.lines.len) return false;
        var next: ?StreamPrefix = null;
        if (count != 0) {
            // Grow from an already-released checkpoint instead of recopying the
            // whole prefix. A pending checkpoint from this same cache needs no
            // scan; a committed one needs the exact comparison after new text or
            // a new width. Bounds/OOM leave the current checkpoint untouched.
            const base: ?*StreamPrefix = blk: {
                if (self.pending_flow_prefix != null and self.pending_flow_layout_valid) {
                    if (self.pending_flow_prefix) |*prefix| break :blk prefix;
                } else if (self.flow_prefix) |*prefix| {
                    if (self.flowMatches(self.columns)) break :blk prefix;
                }
                break :blk null;
            };
            if (base) |prior| {
                if (count < prior.rowCount())
                    next = try StreamPrefix.capture(a, self.lines[0..count], self.columns) orelse return false
                else
                    next = try prior.extend(a, self.lines[prior.rowCount()..count], self.columns) orelse return false;
            } else {
                next = try StreamPrefix.capture(a, self.lines[0..count], self.columns) orelse return false;
            }
        }
        self.discardPendingFlow();
        self.pending_flow_prefix = next;
        self.pending_flow_change = true;
        self.pending_flow_layout_valid = next != null;
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

    /// Create the bounded thinking tail once, at the current terminal width.
    /// A standalone record (columns == 0) uses the documented 80-column default.
    fn attachTail(self: *Record, a: std.mem.Allocator, columns: usize) !void {
        if (self.tail != null) return;
        self.tail = try plain_tail.Tail.create(a, if (columns == 0) 80 else columns, reasoning_tail_rows, reasoning_tail_bytes);
    }

    /// Retire the current source generation and its pending coverage.
    fn resetStream(self: *Record) !void {
        self.stream_generation +%= 1;
        self.pending_output = false;
        if (self.stream) |stream| stream.destroy();
        self.stream = null;
        self.stream_written = 0;
        self.pending_stream_rows = 0;
        // A new generation owns new source; an old frame's coverage cannot be
        // reused as proof for it.
        self.delivery_visible = 0;
        self.delivery_complete = false;
    }

    fn append(self: *Record, a: std.mem.Allocator, bytes: []const u8) !void {
        if (self.kind == .assistant and !self.batch) {
            // Active body display is never gated by the 128 KiB mirror. Input
            // ownership belongs to the incremental Body; `body` is a bounded
            // preview used only for the one exact canonical comparison.
            if (self.stream == null) {
                const columns = if (self.columns != 0) self.columns else 80;
                self.stream = try body_stream.Body.create(a, columns);
            }
            self.stream.?.append(bytes) catch |err| {
                // A failed parse/limit must not lose the bytes already accepted;
                // Body retains them and reports a sticky display limit.
                self.invalidate();
                return err;
            };
            if (!self.mirror_full) {
                var end = @min(canonical_mirror_limit - self.body.items.len, bytes.len);
                while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
                try self.body.appendSlice(a, bytes[0..end]);
                self.mirror_full = end < bytes.len;
            }
            self.invalidate();
            return;
        }
        if (self.kind == .reasoning) {
            self.pending_output = false;
            self.delivery_visible = 0;
            self.delivery_complete = false;
            // Incremental only: feed the new chunk into the bounded tail. No
            // 128 KiB body is retained or rescanned, and the tail owns its own
            // sanitizer state, rows and retained source window.
            try self.attachTail(a, self.columns);
            self.tail.?.append(bytes) catch |err| {
                // Even a partial append/limit change must not leave a stale frame.
                self.invalidate();
                return err;
            };
            self.invalidate();
            return;
        }
        try self.body.appendSlice(a, bytes);
        // Publish the new generation only after the full allocation succeeds.
        self.stream_generation +%= 1;
        self.pending_output = false;
        self.delivery_visible = 0;
        self.delivery_complete = false;
        self.invalidate();
    }

    /// 按列宽渲染为显示行并缓存；缓存有效（列宽未变）时直接返回。
    fn layout(self: *Record, a: std.mem.Allocator, columns: usize) !void {
        if (self.cache != null and self.columns == columns) {
            // The cached slices borrow Body's render. A completed zero-row
            // frame can release its pin while leaving this cache intact; repin
            // through build before using the slices or their coverage as proof.
            if (self.stream == null or self.stream.?.pinned) return;
        }
        self.invalidate();

        // 渲染用的临时内存放在独立 arena 中，成功后整体交给 self.cache 持有。
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const temp = arena.allocator();

        if (self.stream) |stream| {
            if (stream.columnCount() != columns) stream.resize(columns);
            stream.build() catch |err| {
                if (err == error.OutOfMemory) return err;
            };
            const rows = stream.visibleRows();
            const limited = stream.limit != .none;
            const lines = try temp.alloc([]const u8, rows.len + @intFromBool(limited));
            for (rows, 0..) |row, i| lines[i] = row.text;
            if (limited) lines[rows.len] = try temp.dupe(u8, "[Display render limit; model history unchanged]");
            self.lines = lines;
            self.excerpt = limited;
            self.columns = columns;
            self.cache = arena;
            return;
        }

        if (self.kind == .reasoning) {
            const tail = self.tail orelse {
                // A failed create must still leave a readable (empty) record.
                self.lines = &.{};
                self.excerpt = false;
                self.columns = columns;
                self.cache = arena;
                return;
            };
            // Reflow ONLY on a real width change, and only the retained source.
            // snapshot() is a clone: a repeated redraw never re-consumes bytes.
            if (tail.columns() != columns) try tail.resize(columns);
            const snap = try tail.snapshot(temp);
            if (snap.limit == .none) {
                self.lines = snap.rows;
            } else {
                // Sticky display limit is explicit inside the three-row window;
                // never silently fall back to the unbounded old source.
                const marker = try std.fmt.allocPrint(temp, "thinking display limited: {s}; model history unchanged", .{@tagName(snap.limit)});
                const line = try presentation.singleLine(temp, marker, columns);
                const styled = try std.fmt.allocPrint(temp, "{s}{s}{s}", .{ theme.reset, theme.caution, line });
                const rows = try temp.alloc([]const u8, snap.rows.len + 1);
                @memcpy(rows[0..snap.rows.len], snap.rows);
                rows[snap.rows.len] = styled;
                self.lines = rows;
            }
            self.excerpt = false;
            self.columns = columns;
            self.cache = arena;
            return;
        }

        if (self.command_row) {
            const line = try presentation.commandLine(temp, self.body.items, self.command_spans.items, columns, self.duration_ms, null);
            self.lines = try temp.dupe([]const u8, &.{line});
            self.excerpt = false; // Commands indicate clipping with ... only.
            self.columns = columns;
            self.cache = arena;
            return;
        }
        if (self.single_row) {
            // Storage keeps the whole text; only this row is clipped. A width
            // change re-derives the line from the retained body, so a still
            // drawable record obeys the new geometry. Rows already retired into
            // native scrollback stay exactly as written.
            const tone = switch (self.notice_level) {
                .plain => theme.muted,
                .warning => theme.caution,
                .failure => theme.failure,
            };
            const line = try presentation.singleLine(temp, self.body.items, @max(1, columns));
            const styled = try std.fmt.allocPrint(temp, "{s}{s}{s}", .{ theme.reset, tone, line });
            self.lines = try temp.dupe([]const u8, &.{styled});
            self.excerpt = false;
            self.columns = columns;
            self.cache = arena;
            return;
        }
        // 截断时追加提示，但提示只用于显示，模型历史保持不变。
        const data = if (self.clipped and self.kind != .reasoning) try std.fmt.allocPrint(temp, "{s}\n[display clipped; model history is unchanged]", .{self.body.items}) else self.body.items;
        const rendered = try markdown.render(temp, data, .{ .columns = columns, .max_lines = null, .markdown = self.kind == .assistant, .tone = if (self.kind == .user) .user else if (self.kind == .reasoning) .thinking else if (self.kind == .notice) switch (self.notice_level) {
            .plain => .muted,
            .warning => .warning,
            .failure => .failure,
        } else .normal });
        self.lines = rendered.lines;
        self.excerpt = self.clipped or rendered.truncated or rendered.total_lines > rendered.lines.len;
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
const ApprovalChoice = enum { allow_once, deny };
const Permission = struct {
    id: u64,
    description: []const u8,
    clipped: bool,
    pasted: bool = false,
    choice: ApprovalChoice = .deny,
    /// Remote control epoch the approval was displayed in; 0 for local.
    epoch: u64 = 0,
};

/// UI-owned callbacks; the application owns the runtime and configuration lifetime.
pub const Connection = struct {
    pub const Setting = enum { low_price_input, decision_enabled };
    pub const DecisionChoice = decision_picker_module.Choice;
    decision_fn: ?*const fn (*anyopaque, DecisionChoice) anyerror!void = null,
    image_fn: ?*const fn (*anyopaque, DecisionChoice) anyerror!void = null,
    setting_fn: ?*const fn (*anyopaque, Setting, bool) anyerror!void = null,
    preference_fn: ?*const fn (*anyopaque, preference.Key, ?u32) anyerror!void = null,
    /// Exact proxy-model routing toggle: the owner saves the list and
    /// republishes its snapshot. Settings only; no network request here.
    proxy_fn: ?*const fn (*anyopaque, []const u8, bool) anyerror!void = null,
    /// Owner saves (host:port or [IPv6]:port) or clears (empty) the endpoint.
    /// Settings only; the main route changes with the next session.
    proxy_address_fn: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    context: *anyopaque,
    current_fn: *const fn (*anyopaque) State,
    configure_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    /// Owner callbacks; no network calls. Model selection stays local and
    /// idle-only; effort/cycle-effort are the only two operations also issued
    /// while the main task runs, and the owner queues that value for the next
    /// request boundary instead of mutating a live request's configuration.
    select_model_fn: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    configure_provider_fn: ?*const fn (*anyopaque, core_config.providers.Id, []const u8) anyerror!void = null,
    codex_login_fn: ?*const fn (*anyopaque, corecodex.Action, u64) anyerror!void = null,
    set_effort_fn: ?*const fn (*anyopaque, shared.ReasoningEffort) anyerror!void = null,
    /// Explicit owner-side action may adopt newly discovered missing capability
    /// metadata. Redraw snapshots and existing accepted maps remain frozen.
    cycle_effort_fn: ?*const fn (*anyopaque) anyerror!shared.ReasoningEffort = null,
    /// Startup-only borrowed context, consumed before any worker exists.
    initial_history_fn: ?*const fn (*anyopaque) []const p.Message = null,
    /// Explicit metadata refresh and bounded owner polling, separate from LLM jobs.
    refresh_models_fn: ?*const fn (*anyopaque) anyerror!void = null,
    poll_models_fn: ?*const fn (*anyopaque, bool) bool = null,
    /// Local foreground only: pop one delivered Memory terminal. The owner
    /// returns it exactly once; remote sessions deliver through display events.
    take_memory_completion_fn: ?*const fn (*anyopaque) ?memory_status.Terminal = null,
    peek_background_fn: ?*const fn (*anyopaque) ?background_status.Terminal = null,
    take_background_fn: ?*const fn (*anyopaque, background_status.Id) void = null,
    /// Local foreground task lifecycle. The owner marks its own shared
    /// configuration as owned between begin and the matching joined, so a
    /// request boundary never reads a selection that is still being published.
    /// A remote backend already owns its task; that path never calls these.
    task_begin_fn: ?*const fn (*anyopaque) anyerror!void = null,
    task_joined_fn: ?*const fn (*anyopaque) void = null,
    /// Optional remote session adapter (daemon --connect / --attach). When set,
    /// the TUI never dereferences a Runtime: tasks, Inbox, approvals and
    /// checkpoints stay owned by the backend and the UI only submits, ACKs and
    /// renders. Absent keeps the original local foreground ownership path.
    session_client: ?session_client.Client = null,
    /// Optional nonblocking command/completion channel. Queue admission never
    /// authorizes optimistic UI success or bypasses the existing frame ACK.
    async_actions: ?remote_action.Channel = null,

    pub const State = struct {
        runtime: ?*r.Runtime,
        /// Remote session is attachable: submitting plus model/settings UI are
        /// allowed even though `runtime` is null. Two session owners never
        /// coexist for one connection.
        available: bool = false,
        /// Owner-reported task activity of the attached remote session.
        busy: bool = false,
        /// Borrowed display-only session identity; never used as a path.
        session_label: ?[]const u8 = null,
        launcher_dir: ?[]const u8 = null,
        /// Controller epoch; a change invalidates old approvals and queue sends.
        control_epoch: u64 = 0,
        /// Immutable app-prepared startup snapshot; no runtime dereference in draw.
        initial_context: ?r.ContextSnapshot = null,
        model: []const u8,
        /// Immutable owner snapshot, valid even without a journal submission.
        session_id: ?[32]u8 = null,
        /// Metadata-only catalog for this endpoint; never a credential catalog.
        models: []const core_config.Model = &.{},
        /// Nonsecret logged-in aliases filter the flat model list. Empty means
        /// no logged-in provider, never "all providers".
        model_providers: []const ModelProvider = &.{},
        model_context_official: []const bool = &.{},
        model_disabled: []const bool = &.{},
        context_official: bool = false,
        metadata_notice: ?[]const u8 = null,
        /// Producer-classified success toast. Zero keeps actionable notices.
        metadata_notice_ttl_ms: u16 = 0,
        selection_name: ?[]const u8 = null,
        provider: ?core_config.providers.Id = null,
        /// Nonsecret configured-status bits; never credential bytes.
        configured_providers: u8 = 0,
        codex_login: corecodex.View = .{},
        allow_custom_models: bool = true,
        context_limit: u32 = 0,
        /// Owner snapshot: known tiered-price protection active for this model,
        /// not the global toggle; never inferred from token usage.
        low_price_input: bool = false,
        low_price_input_enabled: bool = true,
        image_enabled: bool = false,
        image_models: []const core_config.Model = &.{},
        image_model: ?[]const u8 = null,
        memory_auto: bool = true,
        memory: @import("../core/memory_status.zig").View = .{},
        background: background_status.View = .{},
        subagents: @import("../core/subagent_status.zig").View = .{},
        subagents_supported: bool = false,
        decision_enabled: bool = false,
        /// Owned by the session, resolved with auxiliary rather than chat limits.
        decision_models: []const core_config.Model = &.{},
        decision_model: ?[]const u8 = null,
        /// Owner-published proxy host/port availability; never inferred or guessed.
        proxy_configured: bool = false,
        /// Owner-published bare host (IPv6 without brackets); null means none.
        proxy_address: ?[]const u8 = null,
        proxy_port: u16 = 0,
        /// Exact provider/raw-ID strings routed through that proxy, in order.
        proxy_models: []const []const u8 = &.{},
        global_settings_available: bool = true,
        limits: core_config.Limits = .{},
        /// Immutable configured request option, not inferred from stream time.
        reasoning_effort: shared.ReasoningEffort = .unspecified,
        /// Default preference awaiting an exact capability map; not a wire option.
        pending_default_effort: ?shared.ReasoningEffort = null,
        /// Capability metadata prepared by the owner; zero means unknown.
        effort_levels: shared.activity.EffortSet = .{},
        settings_error: ?anyerror = null,
        settings_notice: ?[]const u8 = null,
        base_url: []const u8,
        /// 由应用层以原子状态发布；UI 不读日志文件、不持有其写入器。
        log_error: ?anyerror = null,
    };

    pub fn current(self: Connection) State {
        return self.current_fn(self.context);
    }

    /// Pop one Memory terminal from the local owner queue. Remote sessions
    /// never use this callback; they deliver the same value as an event.
    pub fn takeMemoryCompletion(self: Connection) ?memory_status.Terminal {
        const callback = self.take_memory_completion_fn orelse return null;
        return callback(self.context);
    }

    pub fn peekBackground(self: Connection) ?background_status.Terminal {
        const callback = self.peek_background_fn orelse return null;
        return callback(self.context);
    }

    pub fn takeBackground(self: Connection, id: background_status.Id) void {
        const callback = self.take_background_fn orelse return;
        callback(self.context, id);
    }

    pub fn configure(self: Connection, key: []const u8) !void {
        try self.configure_fn(self.context, key);
    }
    pub fn configureProvider(self: Connection, provider: core_config.providers.Id, key: []const u8) !void {
        const callback = self.configure_provider_fn orelse return error.SelectionUnavailable;
        try callback(self.context, provider, key);
    }
    pub fn codexLogin(self: Connection, action: corecodex.Action, generation: u64) !void {
        const callback = self.codex_login_fn orelse return error.SelectionUnavailable;
        try callback(self.context, action, generation);
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

fn validCodexCode(view: *const corecodex.View) bool {
    if (view.code_len > view.code.len) return false;
    for (view.userCode()) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

/// Configured means a local Runtime exists or a remote session is available;
/// never infer it from model text or from the absence of a Runtime alone.
fn configured(state: Connection.State) bool {
    return state.runtime != null or state.available;
}

/// These exact owner-published setup conditions are ongoing states, not
/// completed operations. Other settings notices remain transcript advisories.
fn setupHint(state: Connection.State) ?[]const u8 {
    if (configured(state)) return null;
    const notice = state.settings_notice orelse return null;
    if (std.mem.eql(u8, notice, "Not logged in; history available, use /login to activate"))
        return "Not configured: /login, then /model";
    if (std.mem.eql(u8, notice, "SystemOne is decision-only; history available, select a chat model"))
        return "SystemOne is decision-only; select /model";
    if (std.mem.eql(u8, notice, "Default model unavailable locally; select a configured model") or
        std.mem.eql(u8, notice, "Saved model unavailable locally; history available, use /model"))
        return "Model unavailable: select /model";
    return null;
}

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
    const entry = terminal.entryPosition(io, .{ .stopped_fn = entryInterrupted });
    const initial_size = terminal.size();
    const origin = if (entry) |value| if (value.row < initial_size.rows and
        value.size.rows == initial_size.rows and value.size.columns == initial_size.columns) value else null else null;
    if (connection.async_actions) |actions| try terminal.setNotification(actions.wake_fd);
    var ui = Ui{ .allocator = a, .io = io, .connection = connection, .bridge = bridge, .cancel = cancel, .terminal = &terminal, .size = initial_size, .entry_origin = origin, .natural_flow = true, .editor = .{ .allocator = a }, .job = .{ .runtime = undefined, .cancel = cancel, .prompt = "" } };
    defer ui.deinit();

    // Enter in normal flow without replaying pre-existing terminal history;
    // the composer moves down with output until it reaches the bottom.
    if (connection.initial_history_fn) |history| try ui.restoreHistory(history(connection.context));
    // Remote attach may already own a running task; adopt its epoch before the
    // first frame so a stale approval or queue send cannot cross sessions.
    if (connection.session_client) |client| ui.adoptRemoteSession(client);

    // 事件循环出错时直接返回，资源释放交给上面的 defer。
    const result = ui.loop() catch |err| {
        // ui.deinit joins its worker before terminal.deinit restores attributes.
        return err;
    };

    if (result == 0 and interrupt.signal() == 0) ui.tidyIdleExit();
    return finishExit(&terminal, result, interrupt.signal);
}

fn entryInterrupted(_: ?*const anyopaque) bool {
    return interrupt.signal() != 0;
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

/// Footer placeholder owned by an admitted-but-unaccepted control request.
/// Only this exact text may be replaced by a later failure/obsolete receipt.
const pending_session_notice = "Waiting for session...";

/// TUI 的全部状态。只在 UI 线程（run/loop）中访问；后台 Job 只通过 bridge 与之通信。
const AsyncPurpose = enum { submit, enqueue, withdraw, manage, approve, cancel, cancel_clear, open_stop, release_stop, queue_resume, configure, codex_login, model, effort, preference, setting, decision, image, proxy, proxy_address, refresh };
const AsyncPending = struct {
    ticket: u64,
    purpose: AsyncPurpose,
    original_editor: []u8,
    editor_revision: u64,
    epoch: u64,
    permission_id: ?u64,
    inherited: bool = false,
    previous_effort: shared.ReasoningEffort,
    settings_generation: u64,
    stop_instance: u64,
    record: ?Record = null,
    history_entry: ?[]u8 = null,

    fn deinit(self: *AsyncPending, a: std.mem.Allocator) void {
        if (self.record) |*record| record.deinit(a);
        if (self.history_entry) |entry| @import("input_history.zig").History.discard(a, entry);
        std.crypto.secureZero(u8, self.original_editor);
        a.free(self.original_editor);
    }
};

const FrameRecord = struct {
    record_id: u64,
    generation: u64,
    stream_rows: usize = 0,
    /// A zero-row metadata render staged in an unobscured frame.
    metadata_staged: bool = false,
    output_candidate: bool = false,
    flow_change: bool = false,
    flow_prefix: ?StreamPrefix = null,
    flow_layout_valid: bool = false,
    /// Absolute accepted source end this frame actually displayed for the
    /// record, captured from the pinned render BEFORE `Body.commit`. Zero means
    /// no source was proven visible by this frame.
    visible_source_end: usize = 0,
    /// Candidates captured before commit: coverage of the whole pinned render,
    /// and coverage of the frozen prefix rows that went to native scrollback.
    stream_full_end: usize = 0,
    stream_prefix_end: usize = 0,
    /// This record has no undisplayed row left over after this frame's layout:
    /// every row either went to native scrollback or sits inside the visible
    /// mutable tail. A cropped/overlaid tail is never "complete".
    visible_complete: bool = false,
    /// Index into the frame's mutable tail where this record's tail rows begin,
    /// and how many rows it contributed. Used only to decide `visible_complete`
    /// after the final tail crop is known.
    tail_line_start: usize = 0,
    tail_rows: usize = 0,
    /// Thinking is a rolling window: its proof is "the newest rows are on
    /// screen", not "every retained row exists".
    reasoning: bool = false,
};

/// One admitted live event's display obligation. Created only AFTER the event
/// was successfully applied, so its target is state the UI really owns; nothing
/// here is a prediction. Fences keep the admitted order and are never merged
/// while their proof is outstanding, so an unmet hole can never swallow a later
/// independently shown event.
///
/// `record_id == 0` means the event has no display record of its own (owner
/// state, usage, captions): a complete fresh frame staged after application
/// proves it. A record fence needs that record's rows actually displayed, so a
/// retained mutable window can still be acknowledged without waiting for EOF.
const DeliveryFence = struct {
    epoch: u64,
    /// Highest sequence this entry covers (its own sequence, or the last of an
    /// already-enqueued proven run).
    sequence: u64,
    /// Lowest sequence of that run; equals `sequence` for a single event.
    first: u64 = 0,
    record_id: u64 = 0,
    generation: u64 = 0,
    /// Absolute accepted source end that must be visible for this record.
    /// Zero for records without an incremental body (a whole-row obligation).
    target: usize = 0,
    reasoning: bool = false,
    permission_id: ?u64 = null,
    permission_epoch: u64 = 0,
    proven: bool = false,
    /// Its exact interval was already handed to the delivery ACK channel. The
    /// proof is retained (compactly) only to advance the contiguous watermark.
    enqueued: bool = false,
};

/// Bounded per-event fences, one per admitted live sequence and never merged:
/// an unmovable later target must not swallow earlier already-shown proof. The
/// bound is real backpressure, not a discard policy (`displayBackpressured`).
const delivery_fence_capacity = 256;

/// What an applied live payload actually advanced. `source` distinguishes a
/// payload that appended new source bytes from one that carried none (an
/// exactly empty text/reasoning delta): an empty increment owns no source
/// obligation, so it must never inherit the current body's accepted end.
const DeliveryReceipt = struct { id: u64, generation: u64, reasoning: bool = false, source: bool = true, permission_id: ?u64 = null, permission_epoch: u64 = 0 };

const Ui = struct {
    /// 分配显示记录、草稿与帧缓冲的内存分配器。
    allocator: std.mem.Allocator,
    io: Io,
    connection: Connection,
    async_pending: [8]?AsyncPending = @splat(null),
    async_stop_intent: u64 = 0,
    stop_instance: u64 = 0,
    withdrawn_draft: ?[]u8 = null,
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
    editor_revision: u64 = 0,
    input_history: @import("input_history.zig").History = .{},
    history_draft: ?input.Editor = null,
    history_draft_pasted: bool = false,
    vertical_column: ?usize = null,
    /// 终端输入解析器，处理转义序列与粘贴边界。
    parser: input.Parser = .{},
    editor_pasted: bool = false,
    model_picker: ?picker_module.Picker = null,
    provider_picker: provider_picker_module.Picker = .{},
    provider_open: bool = false,
    codex_open: bool = false,
    /// Start/cancel was admitted to the async channel but the owner has not
    /// accepted it yet. No panel is displayed until the receipt arrives.
    codex_opening: bool = false,
    codex_baseline: u64 = 0,
    codex_generation: ?u64 = null,
    codex_cancel_waiting: bool = false,
    codex_view_hash: u64 = 0,
    settings_open: bool = false,
    settings_model_picker: enum { none, decision, image } = .none,
    /// Searchable multi-select proxy child. Enter saves one exact model.
    proxy_open: bool = false,
    /// Proxy second level: Address and Models rows.
    proxy_sub_open: bool = false,
    /// Proxy address editor; the submenu stays visible above it.
    proxy_address_open: bool = false,
    settings_value_picker: ?settings_value_module.Picker = null,
    settings_return_selected: usize = 0,
    settings_menu: settings_menu_module.Menu = .{},
    displayed_settings_generation: ?u64 = null,
    frame_settings_generation: ?u64 = null,
    displayed_decision_fingerprint: ?decision_picker_module.Fingerprint = null,
    frame_decision_fingerprint: ?decision_picker_module.Fingerprint = null,
    displayed_proxy_fingerprint: ?proxy_picker_module.Fingerprint = null,
    frame_proxy_fingerprint: ?proxy_picker_module.Fingerprint = null,
    /// Settings-root editor draft captured while the proxy child owns the editor.
    proxy_restore: ?input.Editor = null,
    provider_choices: provider_picker_module.Choices = .{},
    displayed_provider_generation: ?u64 = null,
    frame_provider_generation: ?u64 = null,
    secret_provider: ?core_config.providers.Id = null,
    /// Non-modal slash-command suggestions shown above the composer while the
    /// editor holds a bare command token. Local only; never executes by itself.
    resume_picker: ?resume_picker_module.Picker = null,
    resume_pending: ?struct { epoch: u64, session_id: ?[32]u8, launcher: ?[]u8 } = null,
    resume_serial: u64 = 0,
    displayed_resume_generation: ?u64 = null,
    frame_resume_generation: ?u64 = null,
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
    /// Owned display records; viewport limits do not retire source records.
    records: std.ArrayList(Record) = .empty,
    record_index: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    next_record_id: u64 = 1,
    draw_record_visits: if (@import("builtin").is_test) usize else void = if (@import("builtin").is_test) 0 else {},
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
    /// The choice proven visible by the same complete frame ACK.
    displayed_permission_choice: ?ApprovalChoice = null,
    frame_permission_choice: ?ApprovalChoice = null,
    /// 审批面板的滚动偏移行数。
    permission_scroll: usize = 0,
    /// 审批期间是否出现过粘贴；出现后该审批只能拒绝。
    approval_paste_seen: bool = false,
    /// Static restored history uses the batch renderer, not live streaming.
    restoring: bool = false,
    /// 后台任务是否正在运行。
    busy: bool = false,
    // The UI owns the only inbox. Never reach through State.runtime to draw it:
    // display fixtures intentionally contain undefined Runtime pointers.
    inbox: r.Inbox = .{},
    attached_runtime: ?*r.Runtime = null,
    queue_owner: ?struct { runtime: *r.Runtime, session: ?[32]u8 } = null,
    task_epoch: u64 = 0,
    queue_revision: u64 = 0,
    stop_open: bool = false,
    stop_danger: bool = false,
    stop_generation: u64 = 0,
    stop_identity: ?StopIdentity = null,
    displayed_stop: ?u64 = null,
    frame_stop: ?u64 = null,
    /// Remote control epoch currently displayed; a change retires old ACK
    /// authority and any queue ownership for the replaced session.
    remote_epoch: u64 = 0,
    // Live delivery is admitted only after application, and proven only by a
    // complete fresh frame. A failed nonblocking enqueue retains the proof.
    delivery_epoch: u64 = 0,
    delivery_admitted: u64 = 0,
    delivery_proven: u64 = 0,
    delivery_acked: u64 = 0,
    delivery_fault: bool = false,
    /// The attached adapter has no ACK channel. Display stays truthful and the
    /// watermark stays pending; this is reported once instead of silently
    /// retiring live content the backend would resend.
    delivery_ack_unsupported: bool = false,
    /// The adapter has no exact-range ACK channel. Selective proof is retained
    /// but can never be handed over; this is reported instead of closing a hole
    /// with a cumulative claim.
    delivery_range_unsupported: bool = false,
    delivery_fences: std.ArrayListUnmanaged(DeliveryFence) = .empty,
    /// Post-application identity of the record the last event advanced.
    delivery_receipt: ?DeliveryReceipt = null,
    frame_delivery_epoch: u64 = 0,
    frame_delivery_sequence: u64 = 0,
    /// This frame wrote the applied session state (body tail, thinking window
    /// or the approval modal). A narrow/hidden frame proves nothing.
    frame_delivery_shown: bool = false,
    frame_delivery_reasoning: bool = false,
    terminal_delivery: ?struct { epoch: u64, sequence: u64 } = null,
    replay_refused: bool = false,
    remote_observed_busy: bool = false,
    remote_observed_sync: bool = false,
    remote_kind: session_client.TaskKind = .prompt,
    /// Consecutive idle observations used to settle a lost remote terminal.
    remote_idle_ticks: u8 = 0,
    /// A remote terminal was already handled while the owner still reported that
    /// same task busy. The result and its notice stay visible, but the view keeps
    /// the busy composer until ordered owner idle or a new task state event
    /// arrives; a repeated busy snapshot proves neither.
    remote_terminal_wait: bool = false,
    /// Epoch injected with the next display event; copied into the approval so
    /// the decision is bound to the session that displayed it.
    inject_epoch: u64 = 0,
    /// Owned backend notice text; never a dangling borrowed reply buffer.
    notice_owned: ?[]u8 = null,
    /// Owned id of a pending busy-session /close confirmation.
    stop_close: ?[]const u8 = null,

    /// An explicit quit owns exit authority; local tasks are joined first.
    ctrl_d_exit: bool = false,
    /// 清理未确认（CleanupFailed 等），禁止再次提交，只允许退出并检查。
    poisoned: bool = false,
    /// 是否需要重绘，由事件与按键置位。
    dirty: bool = true,
    /// Ordinary body repaints coalesce on this cadence, measured from the start
    /// of the previous draw. It is a scheduling parameter, not a latency budget.
    last_draw_ms: u64 = 0,
    /// Keyboard input pending an actual fresh draw. Cleared only when that draw
    /// is staged, so input preempts the ordinary cadence without ever cutting an
    /// already-started frame or a pending geometry/resize turn.
    urgent_draw: bool = false,
    /// Genuine input/content, unlike an animation pulse.
    display_changed: bool = true,
    /// Geometry is unproven: inhibit animation and staging until real input or
    /// content calls requestDraw. There is no timer and no automatic repair.
    resize_waiting: bool = false,
    /// UI接收状态：用于计时/忙碌标记，不显示常驻mode文字。
    mode: ?r.State = null,
    /// 仅必要的错误、设置和隔离提示使用临时hint。
    notice: []const u8 = "Ready",
    /// Last owner-published advisory string already turned into one display
    /// record; repeated identical snapshots are never republished.
    /// 切换思考档位后的短暂确认：在输入框百分比位置显示新档位，5 秒后自动恢复。
    effort_flash: ?struct { level: shared.ReasoningEffort, until_ms: u64 } = null,
    /// Actual-state advisory publication receipts, never draw receipts. Null
    /// means the fault is clear, so a cleared fault that recurs is reported
    /// again. Settings is separate because its owner snapshot is a string.
    settings_error_seen: ?anyerror = null,
    log_error_seen: ?anyerror = null,
    settings_notice_seen: ?u64 = null,
    /// Exact Memory terminal popped locally whose transcript publication
    /// failed. One fixed value, retried before taking any new source value.
    memory_completion_pending: ?memory_status.Terminal = null,
    /// A local foreground task was announced to the owner and its joined
    /// release is still owed. Exactly one release follows one begin.
    task_owned: bool = false,
    /// Foreground terminal detail that could not be published yet. Retried at
    /// the same idle safe point; only a proven append clears it.
    terminal_notice_pending: ?r.Terminal = null,
    /// Exact terminal alias already published in the conversation.
    terminal_alias: []const u8 = "",
    /// Notice text already published once; the footer must not repeat it.
    notice_alias_hash: ?u64 = null,
    /// Typed publication that failed for the current notice; retry its level.
    notice_alias_pending: ?struct { hash: u64, level: NoticeLevel } = null,
    /// UI receipt clock and bounded statistics; never read worker-owned timing.
    clock_ms: u64 = 0,
    animation_tick: u64 = 0,
    display: shared.State = .{},
    model_flow: activity.Flow = .{},
    active_tool: ?struct { id: u64, caption: presentation.Caption, started_ms: u64, display_key: ?p.ToolDisplayKey = null, grouped: bool = false } = null,
    /// Group id of the rows below; the owner's group scalars are never copied
    /// beyond what this display needs to order groups.
    subagent_group: u64 = 0,
    subagent_last_group: u64 = 0,
    subagent_epoch: u64 = 0,
    subagent_starting: bool = false,
    /// One display row per real subagent id, in first-seen order. These are
    /// Ui-owned value copies of the owner's borrowed AgentView entries; the
    /// owner's slice is never retained past one observation.
    subagent_rows: std.ArrayList(AgentRow) = .empty,
    applying_history: bool = false,
    /// This view published the restored-conversation transcript banner. Its
    /// byte-identical footer hint / settings notice stays suppressed even if
    /// the banner is evicted; ownership resets with the rest of the view.
    history_notice_shown: bool = false,
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
    frame_records: []FrameRecord = &.{},
    /// Independent bounded copies, never borrowed Record.lines. Only complete
    /// writes publish the candidate as a reusable acknowledged tail snapshot.
    frame_tail_snapshot: ?tail_frame.Snapshot = null,
    tail_snapshot: ?tail_frame.Snapshot = null,
    menu_history: ?tail_frame.MenuHistory = null,
    frame_menu_history: ?tail_frame.MenuHistory = null,
    frame_sparse: bool = false,
    /// Display requests, not messages. Only a complete frame consumes them.
    idle_breaks: u16 = 0,
    frame_idle_breaks: u16 = 0,
    frame_idle_prefix_end: usize = 0,
    /// A notice published after an idle Enter must not be hidden by that
    /// Enter's later (possibly already staged) compact-composer ACK.
    idle_notice_barrier: bool = false,
    compact_composer: bool = false,
    compact_hint_hash: u64 = 0,
    /// Last fully ACKed footer hint. Idle release may compact only while the
    /// currently visible hint is still that ACKed one.
    tail_hint_hash: u64 = 0,
    frame_hint_hash: u64 = 0,
    /// A normal Enter behind display-only breaks waits for their ACK, never
    /// until the next task completes. Move the editor (no allocation) so typing
    /// in the following read batch belongs to the next draft, not this submit.
    deferred_submit: ?struct { editor: input.Editor, pasted: bool } = null,
    /// 待输出的完整帧；可能分多次 write，由 frame_offset 记录进度。
    frame: []const u8 = "",
    frame_offset: usize = 0,
    /// 该帧绘制时展示的审批 id；写完后才成为 displayed_permission。
    frame_permission: ?u64 = null,
    frame_height: usize = 0,
    frame_cursor_rows_up: usize = 0,
    frame_composer_rows: usize = 1,
    /// Staged proof that the row immediately above the composer is UI-only.
    frame_exit_separator: bool = false,
    frame_size: terminal_module.Size = .{ .columns = 0, .rows = 0 },
    /// Rows borrowed from ACKed transcript rows for an overlay in this frame.
    frame_borrow_rows: usize = 0,
    /// Root-command-only expansion, staged and published with coordinate proof.
    frame_menu_extra: usize = 0,
    tail_menu_extra: usize = 0,
    frame_fresh: bool = false,
    /// Requeue a real update interrupted before ACK; never requeue a pure pulse.
    frame_changed: bool = false,
    frame_clear_end: usize = 0,
    /// A resize may interrupt even an escape sequence in the reclaim prefix.
    resize_rescue: []const u8 = "",
    tail_height: usize = 0,
    /// True only while the ACKed tail is proven to end at the physical bottom.
    /// Promoted by a fresh complete frame whose footprint fills the screen and
    /// dropped by any resize or abandoned tail. Delete-line/erase optimizations
    /// below the owned footprint require it; a floating tail uses row rewrites.
    tail_bottom: bool = false,
    /// Natural layout owns an ACKed footprint relative to the cursor, even
    /// before its end has reached the physical bottom.
    natural_flow: bool = false,
    tail_relative: bool = false,
    frame_relative: bool = false,
    tail_end_floor: usize = 0,
    frame_end_floor: usize = 0,
    /// Staged proof for `tail_bottom`; promoted only by finishFrame's ACK.
    frame_bottom: bool = false,
    /// Published only by a complete ACK, relative to the tail's bottom row.
    tail_cursor_rows_up: usize = 0,
    tail_composer_rows: usize = 1,
    /// Published with the rest of the tail geometry only after a fresh ACK.
    tail_exit_separator: bool = false,
    tail_size: terminal_module.Size = .{ .columns = 0, .rows = 0 },
    abandon_tail: bool = false,
    /// 最近一次读取的终端尺寸。
    size: terminal_module.Size = .{ .columns = 0, .rows = 0 },
    /// Valid only until the first output byte or any geometry change.
    entry_origin: ?terminal_module.Entry = null,

    /// 释放 Ui 持有的全部资源。顺序很重要：先关 bridge 并取消任务，再等待 worker 结束，否则 worker 可能仍在访问 Ui 字段。
    fn deinit(self: *Ui) void {
        // Remote sessions: release this view/control only. Never send a task
        // cancel from teardown; the backend keeps running and saves state.
        if (self.connection.session_client) |client| client.detach();
        // 关闭 bridge 并发出取消，让后台任务尽快退出。
        self.bridge.close();
        self.cancel.cancel();
        // 必须等待 worker 结束，否则它可能仍在访问 Ui 的字段。
        if (self.future) |*future| future.await(self.io);
        self.endTaskOwnership();
        self.detachInbox();
        self.inbox.deinit();
        if (self.prompt) |prompt| self.allocator.free(prompt);
        self.clearPermission();
        self.clearActiveTool();
        self.clearToolCaptions();
        self.tool_calls.deinit(self.allocator);
        self.tool_views.deinit(self.allocator);
        self.subagent_rows.deinit(self.allocator);
        self.discardFrameRecords(self.frame_records);
        self.frame_records = &.{};
        if (self.frame_arena) |*arena| arena.deinit();
        if (self.frame_tail_snapshot) |*snapshot| snapshot.deinit();
        if (self.tail_snapshot) |*snapshot| snapshot.deinit();
        if (self.menu_history) |*history| history.deinit();
        if (self.frame_menu_history) |*history| history.deinit();
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.record_index.deinit(self.allocator);
        self.delivery_fences.deinit(self.allocator);
        self.secret.deinit();
        self.closeModelPicker();
        self.closeResumePicker();
        self.clearResumePending();
        self.parser.secretMode(false);
        self.wipeEditor();
        self.editor.deinit();
        if (self.deferred_submit) |*pending| {
            std.crypto.secureZero(u8, pending.editor.bytes.items);
            pending.editor.deinit();
        }
        self.input_history.deinit(self.allocator);
        self.dropProxyRestore();
        if (self.notice_owned) |owned| self.allocator.free(owned);
        if (self.stop_close) |id| self.allocator.free(id);
        for (&self.async_pending) |*pending| if (pending.*) |*value| value.deinit(self.allocator);
        if (self.withdrawn_draft) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
    }

    // ---- Remote session adapter -------------------------------------------------
    // Local foreground ownership stays exactly as before. When Connection carries
    // a session_client, tasks/Inbox/approvals belong to the backend: the UI
    // submits, acknowledges and renders, and never dereferences a Runtime.

    fn remote(self: *const Ui) ?session_client.Client {
        return self.connection.session_client;
    }

    fn hasAsync(self: *const Ui, purpose: AsyncPurpose) bool {
        for (self.async_pending) |pending| if (pending) |value| {
            if (value.purpose == purpose) return true;
        };
        return false;
    }

    fn presentationWaiting(self: *const Ui) bool {
        // A request is not an accepted Runtime task, but it is not a settled
        // idle composer either. Keep task/history state receipt-gated.
        for (self.async_pending) |pending| if (pending != null) return true;
        return false;
    }

    fn urgentAsync(purpose: AsyncPurpose) bool {
        return switch (purpose) {
            .approve, .cancel, .cancel_clear, .open_stop, .release_stop => true,
            else => false,
        };
    }

    fn normalAsyncPending(self: *const Ui) bool {
        for (self.async_pending) |pending| if (pending) |value| {
            if (!urgentAsync(value.purpose)) return true;
        };
        return false;
    }

    fn blocksSubmit(self: *const Ui) bool {
        // Thinking/metadata probes do not switch the primary model or session.
        // Preserve a fast Enter behind them instead of dropping submit intent.
        for (self.async_pending) |pending| if (pending) |value| {
            if (!urgentAsync(value.purpose) and value.purpose != .effort and value.purpose != .refresh) return true;
        };
        return false;
    }

    fn asyncFailureLevel(self: *const Ui, purpose: AsyncPurpose) NoticeLevel {
        return switch (purpose) {
            .submit => .failure,
            .configure => if (configured(self.connection.current())) .warning else .failure,
            else => .warning,
        };
    }

    fn beginAsync(self: *Ui, action: remote_action.Action, purpose: AsyncPurpose) ?*AsyncPending {
        const channel = self.connection.async_actions orelse return null;
        if ((!urgentAsync(purpose) and (if (purpose == .submit) self.blocksSubmit() else self.normalAsyncPending())) or
            (purpose != .open_stop and purpose != .release_stop and self.hasAsync(purpose)))
        {
            self.notice = "Operation pending; input kept";
            return null;
        }
        var target: ?*?AsyncPending = null;
        for (&self.async_pending) |*slot| if (slot.* == null) {
            target = slot;
            break;
        };
        const slot = target orelse {
            self.notice = "Control queue full; input kept";
            return null;
        };
        const original = self.allocator.dupe(u8, self.editor.bytes.items) catch {
            self.notice = "Out of memory; action not sent";
            self.publishNoticeAlias(self.asyncFailureLevel(purpose));
            return null;
        };
        const epoch = if (purpose == .approve) (if (self.permission) |permission| permission.epoch else self.remote_epoch) else self.remote_epoch;
        const ticket = channel.start(epoch, action) catch |err| {
            self.allocator.free(original);
            self.notice = session_client.describe(err);
            self.publishNoticeAlias(self.asyncFailureLevel(purpose));
            return null;
        };
        slot.* = .{ .ticket = ticket, .purpose = purpose, .original_editor = original, .editor_revision = self.editor_revision, .epoch = epoch, .permission_id = if (self.permission) |permission| permission.id else null, .previous_effort = self.connection.current().reasoning_effort, .settings_generation = self.settings_menu.generation, .stop_instance = self.stop_instance };
        if (purpose == .open_stop or purpose == .release_stop) self.async_stop_intent = ticket;
        // Effort changes do not transfer input ownership; retain the rest of
        // this feed without clearing a barrier set by an earlier action.
        if (purpose != .effort) self.parser.stop_feed = true;
        self.notice = pending_session_notice;
        self.requestDraw();
        return &slot.*.?;
    }

    fn clearSubmittedEditor(self: *Ui, pending: *const AsyncPending) void {
        if (self.editor_revision == pending.editor_revision and std.mem.eql(u8, self.editor.bytes.items, pending.original_editor)) self.wipeEditor();
    }

    fn adoptWithdrawn(self: *Ui, bytes: []u8) void {
        self.editor.deinit();
        self.editor = .{ .allocator = self.allocator, .bytes = .{ .items = bytes, .capacity = bytes.len, .pointer_stability = .{} }, .cursor = bytes.len };
        self.editor_pasted = false;
        self.input_history.index = null;
        self.vertical_column = null;
        self.publishNotice("Pending message withdrawn as plain draft");
    }

    fn activateStop(self: *Ui) void {
        self.stop_instance +%= 1;
        self.stop_open = true;
        self.stop_danger = false;
        self.stop_identity = self.stopIdentity();
        self.invalidateStop();
        self.parser.stop_feed = true;
    }

    fn pumpAsync(self: *Ui) void {
        const channel = self.connection.async_actions orelse return;
        for (0..self.async_pending.len) |_| {
            var completion = channel.poll() orelse break;
            defer completion.deinit();
            var found: ?AsyncPending = null;
            for (&self.async_pending) |*slot| if (slot.*) |pending| {
                if (pending.ticket == completion.request.ticket) {
                    found = pending;
                    slot.* = null;
                    break;
                }
            };
            var pending = found orelse continue;
            defer pending.deinit(self.allocator);
            if (completion.obsolete) {
                if (pending.purpose == .manage and completion.request.action.manage == .saved_sessions) self.clearResumePending();
                // A superseded login attempt must never strand an opening panel
                // nor keep a deferred cancellation armed for a dead generation.
                if (pending.purpose == .codex_login) {
                    const start = completion.request.action.codex_login.action == .start;
                    self.codex_opening = false;
                    self.codex_open = false;
                    self.codex_generation = null;
                    self.codex_cancel_waiting = false;
                    self.codex_view_hash = 0;
                    if (start and std.mem.eql(u8, self.notice, pending_session_notice)) self.notice = "Ready";
                    self.requestDraw();
                }
                continue;
            }
            if (pending.purpose == .approve) {
                const permission = self.permission orelse continue;
                if (permission.epoch != pending.epoch or permission.id != pending.permission_id) continue;
            }
            if (completion.failure) |err| {
                if (pending.purpose == .manage and completion.request.action.manage == .saved_sessions) self.clearResumePending();
                if (pending.purpose == .codex_login) {
                    const start = completion.request.action.codex_login.action == .start;
                    self.codex_opening = false;
                    self.codex_cancel_waiting = false;
                    self.codex_view_hash = 0;
                    if (start) {
                        // A rejected start never opened a panel; no generation
                        // was bound to this request either.
                        self.codex_open = false;
                        self.codex_generation = null;
                        self.notice = "OpenAI Codex device login unavailable";
                    } else self.notice = "Could not cancel OpenAI Codex login";
                    self.requestDraw();
                    continue;
                }
                self.notice = if (err == error.PublicationUnavailable) "Operation result unavailable; verify before retrying" else switch (pending.purpose) {
                    .refresh => if (err == error.NoOfficialProvider) "No official provider configured; use /login first" else if (err == error.MetadataRefreshBusy) "Official metadata refresh already running" else "Could not start metadata refresh; previous cache kept",
                    .effort => switch (err) {
                        error.ThinkingCapabilitiesLoading => "Thinking capabilities are loading; try Shift+Tab again shortly",
                        error.ThinkingCapabilitiesUnknown => "Thinking capabilities unknown: refresh /model or declare reasoning levels in configuration",
                        else => "Could not save thinking option; previous option kept",
                    },
                    .configure => "Could not save configuration; use /login to retry",
                    .model => "Could not switch; selection is unchanged",
                    .preference, .setting, .decision, .image, .proxy, .proxy_address => "Could not save setting; previous value kept",
                    else => session_client.describe(err),
                };
                self.publishNoticeAlias(self.asyncFailureLevel(pending.purpose));
                if (pending.purpose == .configure and self.secret_mode) self.endSecret();
                self.requestDraw();
                continue;
            }
            self.completeAsync(&pending, &completion);
            self.requestDraw();
        }
    }

    /// Publish a one-shot UI outcome independently of canonical conversation.
    /// On capacity/allocation failure retain an actionable hint instead of losing it.
    fn publishNotice(self: *Ui, message: []const u8) void {
        _ = self.add(.notice, message) catch {
            if (self.notice_alias_pending == null) self.notice = "Display notice unavailable; inspect operation state";
            self.requestDraw();
            return;
        };
        if (self.notice_alias_pending == null) self.notice = "Ready";
    }

    fn completeAsync(self: *Ui, pending: *AsyncPending, completion: *remote_action.Completion) void {
        const action = completion.request.action;
        switch (pending.purpose) {
            .submit => {
                const record = if (pending.record) |*value| value else return;
                if (self.remote()) |client| self.remote_epoch = client.snapshot().control_epoch;
                self.acceptRemote(action.submit.kind, record, &pending.history_entry);
                self.clearSubmittedEditor(pending);
            },
            .enqueue => {
                self.clearSubmittedEditor(pending);
                self.publishNotice(if (action.enqueue.kind == .steering) "Steering pending" else "FollowUp pending");
            },
            .withdraw => {
                if (completion.value != .withdrawn) return;
                const bytes = completion.value.withdrawn orelse {
                    self.notice = "Message already consumed; nothing withdrawn";
                    return;
                };
                completion.value = .none;
                if (self.editor.bytes.items.len == 0) self.adoptWithdrawn(bytes) else {
                    self.withdrawn_draft = bytes;
                    self.notice = "Message withdrawn; clear draft and press Esc to restore it";
                }
            },
            .manage => {
                if (completion.value == .managed) self.acceptManage(&completion.value.managed, true);
                if (action.manage == .saved_sessions) self.clearResumePending();
            },
            .approve => {
                self.settlePermissionDelivery(action.approve.id, pending.epoch);
                if (self.permission) |permission| if (permission.epoch == pending.epoch and permission.id == action.approve.id) self.clearPermission();
                self.publishNotice(if (action.approve.decision == .deny) "Request denied" else "Allowed once");
            },
            .cancel, .cancel_clear => {
                if (self.permission) |permission| if (permission.epoch == pending.epoch and pending.permission_id == permission.id) self.clearPermission();
                if (pending.purpose == .cancel_clear and self.stop_open and self.stop_instance == pending.stop_instance) {
                    self.stop_open = false;
                    self.stop_identity = null;
                    self.stop_instance +%= 1;
                    self.invalidateStop();
                }
                if (self.last_terminal) |result| {
                    if (std.mem.eql(u8, self.notice, pending_session_notice)) self.notice = terminalNotice(result);
                } else self.publishNotice(if (pending.purpose == .cancel_clear) "Stop requested; queue cleared; draft kept" else "Cancellation requested; cleaning up, not rolling back effects");
            },
            .open_stop => if (self.async_stop_intent == pending.ticket) {
                self.activateStop();
                self.notice = "Confirm stop";
            },
            .release_stop => if (self.async_stop_intent == pending.ticket and self.last_terminal == null) {
                self.notice = "Stop dismissed";
            },
            .queue_resume => {
                self.clearSubmittedEditor(pending);
                self.publishNotice("Queue resumed");
            },
            .configure => {
                if (self.secret_mode) self.endSecret();
                self.secret_quarantine = false;
                self.display.context = self.connection.current().initial_context;
                self.publishNotice(if (action.configure.provider != null) "Key saved locally; use /model to select or activate it" else "Saved locally; send a message to connect");
            },
            .codex_login => {
                const request = action.codex_login;
                self.codex_opening = false;
                if (request.action == .start) {
                    // Only the owner's accepted RPC opens the panel; the code
                    // itself stays ephemeral and is watched by generation.
                    self.codex_open = true;
                    self.codex_generation = null;
                    self.codex_view_hash = 0;
                    self.notice = "Ready";
                    self.parser.stop_feed = true;
                    self.observeCodexLogin();
                } else {
                    // A cancel receipt closes only the panel still bound to the
                    // EXACT generation it targeted; a later attempt keeps its own.
                    if (self.codex_generation) |bound| if (bound == request.generation) {
                        self.codex_open = false;
                        self.codex_generation = null;
                        self.codex_view_hash = 0;
                    };
                    self.codex_cancel_waiting = false;
                    self.notice = "Ready";
                }
            },
            .model => {
                self.finishModelSelection(pending.inherited);
                self.clearSubmittedEditor(pending);
            },
            .effort => {
                const next = if (completion.value == .effort) completion.value.effort else self.connection.current().reasoning_effort;
                if (next == pending.previous_effort) {
                    self.notice = "This model has no other supported thinking level";
                    return;
                }
                self.display.setEffort(next);
                self.effort_flash = .{ .level = next, .until_ms = self.clock_ms +| 5000 };
                self.notice = "Ready";
            },
            .preference, .setting, .decision, .image, .proxy, .proxy_address => {
                self.display.context = self.connection.current().initial_context;
                self.frame_settings_generation = null;
                const same_menu = self.settings_open and self.settings_menu.generation == pending.settings_generation;
                if (same_menu) switch (pending.purpose) {
                    .preference => if (self.settings_value_picker != null) self.backFromSettingsValue(),
                    .decision, .image => if (self.settingsModelOpen()) self.backToSettings(),
                    .proxy_address => if (self.proxy_address_open) self.backToProxySubmenu(0),
                    else => {},
                };
                self.publishNotice(switch (pending.purpose) {
                    .proxy => "Saved proxy models; main route applies in a new session",
                    .proxy_address => if (action.proxy_address.len == 0) "Empty disables proxy; a new session applies it" else "Saved proxy address; main route applies in a new session",
                    else => "Settings saved",
                });
            },
            .refresh => self.notice = "Refreshing official model metadata...",
        }
    }

    /// True for a locally executed !command, which projects literal streams.
    fn commandKind(self: *const Ui) bool {
        if (self.remote() != null) return self.remote_kind == .command;
        return self.job.kind == .command;
    }

    fn promptKind(self: *const Ui) bool {
        if (self.remote() != null) return self.remote_kind == .prompt;
        return self.job.kind == .prompt;
    }

    /// Queue state for rendering and the open/enter stop confirmation. Remote
    /// counts come from the owner snapshot; local counts from the UI-owned Inbox.
    fn queueSnapshot(self: *Ui) inbox_module.Snapshot {
        const client = self.remote() orelse return self.inbox.snapshot();
        const snapshot = client.snapshot();
        var mirror = inbox_module.Snapshot{
            .revision = snapshot.queue_revision,
            .steering = snapshot.steering,
            .follow_up = snapshot.follow_up,
            .newest_id = snapshot.newest_id,
            .newest_bytes = snapshot.newest_bytes,
            .paused = snapshot.queue_paused,
            .confirming = self.stop_open,
            .active = snapshot.busy,
            .epoch = snapshot.control_epoch,
        };
        const shown = @min(snapshot.previews.len, @min(mirror.previews.len, session_client.max_previews));
        for (snapshot.previews[0..shown], 0..) |preview, index| {
            var entry = &mirror.previews[index];
            entry.id = preview.id;
            entry.kind = preview.kind;
            var n = @min(entry.bytes.len, preview.text.len);
            while (n < preview.text.len and n > 0 and preview.text[n] & 0xc0 == 0x80) n -= 1;
            @memcpy(entry.bytes[0..n], preview.text[0..n]);
            entry.len = n;
            mirror.preview_count += 1;
        }
        return mirror;
    }

    /// Startup attach: adopt the owner epoch and any already-running task.
    fn adoptRemoteSession(self: *Ui, client: session_client.Client) void {
        const snapshot = client.snapshot();
        self.remote_epoch = snapshot.control_epoch;
        self.remote_observed_busy = snapshot.busy;
        self.remote_kind = snapshot.task_kind;
        if (snapshot.busy) {
            self.busy = true;
            self.mode = snapshot.mode orelse .calling_model;
            self.notice = "Attached; task is running";
        } else if (snapshot.attached) {
            self.notice = "Ready";
        }
    }

    /// Apply an owned remote event directly while its payload is alive. Only
    /// the terminal uses the Bridge completion path.
    fn pumpRemote(self: *Ui) !void {
        if (self.hasAsync(.submit)) return;
        const client = self.remote() orelse return;
        var snapshot = client.snapshot();
        if (snapshot.control_epoch != self.remote_epoch) {
            try self.resetSessionView(snapshot);
            snapshot = client.snapshot();
        }
        self.retryDeliveryAck();
        if (self.terminal_delivery != null) return;
        if (self.bridgeEmpty()) {
            const delivered = pollRemote(client, self.allocator) catch |err| blk: {
                self.notice = session_client.describe(err);
                self.requestDraw();
                break :blk null;
            };
            if (delivered) |value| {
                var item = value;
                defer item.deinit();
                self.inject_epoch = item.epoch;
                self.adoptReplayHistory(&item);
                if (self.replay_refused and (item.history_replay or item.history_display_reset)) return;
                if (item.event == .finished) {
                    const host = self.bridge.host();
                    host.emit_fn(host.context, item.event, self.cancel) catch |err| {
                        self.notice = "Display queue rejected a session event; reattach to resync";
                        self.requestDraw();
                        return err;
                    };
                    if (item.delivery_sequence != 0) self.terminal_delivery = .{ .epoch = item.delivery_epoch, .sequence = item.delivery_sequence };
                } else {
                    // A receipt from an unrelated local event must never name
                    // this live event's record.
                    self.delivery_receipt = null;
                    self.applying_history = item.history_replay;
                    defer self.applying_history = false;
                    try self.applyEvent(item.event, item.display_truncated, item.canonical_complete);
                    // 0 means "single raw event"; a coalesced item keeps the full
                    // first..last interval so no interior raw sequence is lost.
                    const first = if (item.delivery_first_sequence == 0)
                        item.delivery_sequence
                    else
                        item.delivery_first_sequence;
                    self.admitDeliverySpan(item.delivery_epoch, first, item.delivery_sequence);
                }
            }
        }
        // A snapshot can already say idle while its earlier live events are
        // still queued. Do not count those pending events as idle samples.
        if (client.snapshot().busy or (!client.buffered() and self.bridgeEmpty()))
            self.adoptRemoteActivity(client.snapshot());
    }

    /// Single-sequence admission; the terminal path and fixture tests use it.
    fn admitDelivery(self: *Ui, epoch: u64, sequence: u64) void {
        self.admitDeliverySpan(epoch, sequence, sequence);
    }

    /// Admit one applied live payload covering raw sequences `first..last`.
    ///
    /// C may coalesce several contiguous raw events into one item, so the last
    /// sequence alone is NOT the coverage: acknowledging only it would strand
    /// `first..last-1` in the server ring. The payload was applied as a whole,
    /// so displaying it proves the whole interval; the fence keeps the real
    /// span and the ACK range covers every original raw event.
    fn admitDeliverySpan(self: *Ui, epoch: u64, first: u64, last: u64) void {
        const receipt = self.delivery_receipt;
        self.delivery_receipt = null;
        if (last == 0) return;
        const span_first = if (first == 0 or first > last) last else first;
        if (epoch == 0 or (self.delivery_epoch != 0 and epoch != self.delivery_epoch)) {
            self.delivery_fault = true;
            self.notice = "Delivery epoch changed; reattach to resync";
            self.requestDraw();
            return;
        }
        if (last <= self.delivery_acked) return;
        // A retransmission is never applied twice; a retained interval (single or
        // coalesced) already covers every sequence it represents.
        for (self.delivery_fences.items) |fence| {
            const start = if (fence.first == 0) fence.sequence else fence.first;
            if (last >= start and span_first <= fence.sequence) return;
        }
        self.delivery_epoch = epoch;
        self.delivery_admitted = @max(self.delivery_admitted, last);
        var fence = DeliveryFence{ .epoch = epoch, .sequence = last, .first = span_first };
        if (receipt) |value| {
            fence.permission_id = value.permission_id;
            fence.permission_epoch = value.permission_epoch;
            fence.reasoning = value.reasoning;
            if (value.id != 0) {
                if (self.record_index.get(value.id)) |index| {
                    const record = &self.records.items[index];
                    if (record.stream_generation == value.generation) {
                        fence.record_id = record.id;
                        fence.generation = record.stream_generation;
                        fence.reasoning = fence.reasoning or record.kind == .reasoning;
                        // Only a payload that appended source can own a source
                        // target. An empty increment keeps the record's explicit
                        // UX ownership but no new source to display.
                        if (value.source) {
                            if (record.stream) |stream| fence.target = stream.acceptedSourceEnd();
                        }
                    }
                }
            }
        }
        self.pushDeliveryFence(fence);
    }

    /// Fences are never coalesced while proof is outstanding: every admitted
    /// sequence owns its own target, so an unmovable later target (a held CR, an
    /// undisplayed tail) cannot swallow the proof of earlier already-shown
    /// events. Only entries whose exact interval was already handed over are
    /// merged, and only to keep the retained set bounded.
    fn pushDeliveryFence(self: *Ui, fence: DeliveryFence) void {
        self.pruneDeliveryFences();
        if (self.unenqueuedFenceCount() >= delivery_fence_capacity or
            self.delivery_fences.items.len >= delivery_fence_capacity * 2 + 2)
        {
            // The poll gate above should have stopped admission already. Keep the
            // failure truthful: never drop a fence and never ACK what it covered.
            self.delivery_fault = true;
            self.notice = "Display delivery backlog exceeded; reattach to resync";
            self.requestDraw();
            return;
        }
        self.delivery_fences.append(self.allocator, fence) catch {
            self.delivery_fault = true;
            self.notice = "Display delivery fence allocation failed; reattach to resync";
            self.requestDraw();
        };
    }

    /// Fences whose exact interval has NOT been handed to the ACK channel yet.
    /// This is the real UI delivery capacity: an already-enqueued later proof
    /// must free capacity while its retained sequence keeps the watermark honest.
    fn unenqueuedFenceCount(self: *const Ui) usize {
        var count: usize = 0;
        for (self.delivery_fences.items) |fence| {
            if (!fence.enqueued) count += 1;
        }
        return count;
    }

    /// Drop fences the contiguous ACK watermark already passed. A proven-but-
    /// later entry stays: only `delivery_acked` (proven AND handed over) may
    /// release a sequence, never a high `admitted` value.
    fn pruneDeliveryFences(self: *Ui) void {
        var drop: usize = 0;
        while (drop < self.delivery_fences.items.len and
            self.delivery_fences.items[drop].sequence <= self.delivery_acked)
        {
            drop += 1;
        }
        if (drop == 0) return;
        const keep = self.delivery_fences.items.len - drop;
        std.mem.copyForwards(DeliveryFence, self.delivery_fences.items[0..keep], self.delivery_fences.items[drop..]);
        self.delivery_fences.shrinkRetainingCapacity(keep);
    }

    /// Merge adjacent retained entries whose proof was already enqueued. No hole
    /// can be crossed (a hole is an unproven entry between them), so this bounds
    /// the retained set without inventing coverage.
    fn coalesceEnqueuedFences(self: *Ui) void {
        if (self.delivery_fences.items.len < 2) return;
        var write: usize = 1;
        for (self.delivery_fences.items[1..]) |fence| {
            const previous = &self.delivery_fences.items[write - 1];
            if (previous.enqueued and previous.proven and fence.enqueued and fence.proven) {
                previous.sequence = @max(previous.sequence, fence.sequence);
                continue;
            }
            self.delivery_fences.items[write] = fence;
            write += 1;
        }
        self.delivery_fences.shrinkRetainingCapacity(write);
    }

    /// Authoritative REMOVAL (withdrawn canonical text, reasoning retired by UX,
    /// or another explicit removal): the sequence keeps its ordering but the record is
    /// gone, so only a fresh frame of the applied state can settle it.
    fn retargetDeliveryFences(self: *Ui, record_id: u64) void {
        if (record_id == 0) return;
        for (self.delivery_fences.items) |*fence| {
            if (fence.proven or fence.enqueued or fence.record_id != record_id) continue;
            fence.record_id = 0;
            fence.generation = 0;
            fence.target = 0;
        }
    }

    /// Explicit CANONICAL REPLACEMENT: the same sequences now require the
    /// replacement's own source (or its rows, when it has no incremental body)
    /// to be displayed. Nothing here infers a replacement from an unexplained
    /// generation mismatch.
    fn retargetDeliveryFencesTo(self: *Ui, record_id: u64, generation: u64, target: usize) void {
        if (record_id == 0) return;
        for (self.delivery_fences.items) |*fence| {
            if (fence.proven or fence.enqueued or fence.record_id != record_id) continue;
            fence.generation = generation;
            fence.target = target;
        }
    }

    /// Source fence prefixes and all-row proof are renderer-owned numbers: a
    /// `max(row.end)` reconstruction could overclaim a table prefix or an
    /// atomic suffix, so there is deliberately no local fallback.
    fn bodyShownEnd(stream: *const body_stream.Body, shown: usize) usize {
        return stream.visibleSourceEndForRows(shown);
    }

    /// Proof is published, then handed over: the contiguous prefix uses the
    /// cumulative watermark, and every independently proven run past a hole uses
    /// an exact range. A failure keeps the exact proof for retry.
    fn retryDeliveryAck(self: *Ui) void {
        if (self.delivery_fault or self.delivery_epoch == 0) return;
        self.advanceContiguousDelivery();
        self.pruneDeliveryFences();
        self.enqueueDeliveryProof();
        self.advanceContiguousDelivery();
        self.pruneDeliveryFences();
    }

    /// Contiguous watermarks only: `delivery_proven` stops at the first unproven
    /// hole, `delivery_acked` additionally stops at the first proven-but-not-yet-
    /// handed-over entry. Neither is ever a max(sequence).
    fn advanceContiguousDelivery(self: *Ui) void {
        var proven = self.delivery_proven;
        var acked = self.delivery_acked;
        var ack_open = true;
        for (self.delivery_fences.items) |fence| {
            if (!fence.proven) break;
            proven = @max(proven, fence.sequence);
            if (!ack_open) continue;
            if (fence.enqueued) acked = @max(acked, fence.sequence) else ack_open = false;
        }
        self.delivery_proven = proven;
        self.delivery_acked = acked;
    }

    fn enqueueDeliveryProof(self: *Ui) void {
        const client = self.remote() orelse return;
        if (client.snapshot().control_epoch != self.remote_epoch) return;
        // Only a genuinely complete prefix may use the cumulative watermark.
        if (self.delivery_proven > self.delivery_acked) {
            if (self.delivery_ack_unsupported) return;
            client.acknowledge(self.delivery_epoch, self.delivery_proven) catch |err| {
                // Unsupported is permanent for this adapter: say so once instead
                // of implying the live stream was retired backend-side.
                if (err == error.Unsupported and !self.delivery_ack_unsupported) {
                    self.delivery_ack_unsupported = true;
                    self.notice = "Live delivery ACK unsupported; display retained";
                    self.requestDraw();
                }
                return;
            };
            self.delivery_acked = self.delivery_proven;
            self.pruneDeliveryFences();
            return;
        }
        if (self.delivery_range_unsupported) return;
        // Exact ranges of consecutive proven sequences. A hole (unproven entry)
        // ends the run, so a range can never bridge undisplayed content.
        var enqueued_any = false;
        var index: usize = 0;
        while (index < self.delivery_fences.items.len) : (index += 1) {
            const start = self.delivery_fences.items[index];
            if (!start.proven or start.enqueued) continue;
            var end = index;
            while (end + 1 < self.delivery_fences.items.len) {
                const next = self.delivery_fences.items[end + 1];
                if (!next.proven or next.enqueued) break;
                const next_first = if (next.first == 0) next.sequence else next.first;
                if (next_first != self.delivery_fences.items[end].sequence + 1) break;
                end += 1;
            }
            const first = if (start.first == 0) start.sequence else start.first;
            const last = self.delivery_fences.items[end].sequence;
            client.acknowledgeRange(self.delivery_epoch, first, last) catch |err| {
                // Keep the exact interval un-enqueued so the same range is retried.
                if (err == error.Unsupported and !self.delivery_range_unsupported) {
                    self.delivery_range_unsupported = true;
                    self.notice = "Live delivery range ACK unsupported; display retained";
                    self.requestDraw();
                }
                break;
            };
            // Marking is not structural, so the scan can continue in this pass.
            for (self.delivery_fences.items[index .. end + 1]) |*fence| fence.enqueued = true;
            index = end;
            enqueued_any = true;
        }
        if (enqueued_any) self.coalesceEnqueuedFences();
    }

    /// The UX retires a thinking window when prose starts, a tool runs, or the
    /// user hides it. That is an intentional replacement, not a lost stream.
    fn reasoningReplaced(self: *const Ui) bool {
        return !self.show_reasoning or self.draft != null or
            self.tool_views.entries.items.len != 0 or self.active_tool != null;
    }

    /// One fence against already-published display proof. Nothing here looks at
    /// `Body.finished`: an active stream's displayed prefix is provable on its
    /// own, and a cropped/hidden row simply leaves the fence unmet.
    fn deliveryFenceProven(self: *const Ui, fence: DeliveryFence, frame_valid: bool) bool {
        if (fence.epoch != self.delivery_epoch) return false;
        // Coverage can only come from a frame staged AFTER this sequence was
        // admitted. An event applied after the frame was built is never covered
        // by that earlier admission snapshot, whatever its target looks like.
        if (fence.sequence > self.frame_delivery_sequence) return false;
        if (fence.permission_id) |id| {
            const permission = self.permission orelse return false;
            return frame_valid and permission.epoch == fence.permission_epoch and permission.id == id and self.frame_permission == id;
        }
        if (fence.reasoning) {
            // An intentionally replaced thinking window (prose began, a tool ran,
            // the user hid it) is settled by that explicit UX rule; otherwise only
            // a frame that actually draws its newest rows proves it.
            if (self.reasoningReplaced()) return frame_valid and self.frame_delivery_shown;
            if (fence.record_id == 0) return false;
            const index = self.record_index.get(fence.record_id) orelse return false;
            if (self.records.items[index].stream_generation != fence.generation) return false;
            return frame_valid and self.frame_delivery_reasoning;
        }
        if (fence.record_id == 0) {
            if (!frame_valid or !self.frame_delivery_shown) return false;
            return true;
        }
        const index = self.record_index.get(fence.record_id) orelse return false;
        const record = &self.records.items[index];
        if (record.stream_generation != fence.generation) return false;
        if (fence.target != 0) return record.delivery_visible >= fence.target;
        return record.delivery_complete;
    }

    /// Mark every independently shown fence this frame's admission snapshot
    /// covers, continuing PAST unmet earlier holes, then publish exactly what can
    /// be claimed. A hole never blocks a later metadata/source proof, and later
    /// proofs never widen the contiguous watermarks over that hole.
    /// There is deliberately NO inference from a vanished/re-generated record:
    /// only an explicit canonical replacement/removal retargets a fence.
    fn promoteDeliveryFences(self: *Ui, frame_valid: bool) void {
        if (self.delivery_fault or self.delivery_epoch == 0) return;
        self.pruneDeliveryFences();
        for (self.delivery_fences.items) |*fence| {
            if (fence.proven) continue;
            if (self.deliveryFenceProven(fence.*, frame_valid)) fence.proven = true;
        }
        self.retryDeliveryAck();
    }

    fn displayBackpressured(self: *const Ui) bool {
        // Live delivery fences are the first bound: at capacity no further event
        // may be polled, so an unprovable prefix is never dropped or fabricated.
        // Only proof that has NOT been handed over counts against capacity.
        if (self.unenqueuedFenceCount() >= delivery_fence_capacity) return true;
        for (self.records.items) |record| {
            if (!record.output) if (record.stream) |stream| {
                if (stream.pendingBytes() >= 64 * 1024 or stream.windowBytes() >= 128 * 1024) return true;
            };
        }
        return false;
    }

    /// Drain at most the existing per-tick event budget. The first poll may
    /// fetch one page; subsequent polls only consume buffered items.
    fn pumpDisplay(self: *Ui) !void {
        self.retryDeliveryAck();
        if (self.terminal_notice_pending != null) return;
        for (0..64) |index| {
            // A remote terminal must settle before this batch polls the item that
            // follows it: finished(task 1) plus state/text(task 2) can share one
            // read, and the next task must not be closed as task 1's residue.
            if (self.remote() != null) {
                try self.finishReadyTask();
                if (self.terminal_notice_pending != null) break;
                if (self.terminal_delivery) |delivery| {
                    if (self.bridge.terminal != null) break;
                    self.terminal_delivery = null;
                    // A terminal event has no record of its own: its result rows
                    // are proven by the next complete frame, not by leftovers.
                    self.delivery_receipt = null;
                    self.admitDelivery(delivery.epoch, delivery.sequence);
                    self.requestDraw();
                }
            }
            if (self.displayBackpressured()) break;
            if (index == 0 or (if (self.remote()) |client| client.buffered() else false))
                try self.pumpRemote();
            if (self.bridge.pop()) |value| {
                var item = value;
                defer item.deinit();
                try self.event(item);
            } else if (self.remote()) |client| {
                // Direct remote events still consume budget.
                if (!client.buffered()) break;
            } else break;
        }
    }

    /// Take the next delta that belongs to the current control epoch. Deltas a
    /// replaced controller queued before takeover are discarded, never rendered
    /// or allowed to authorize anything in the new session view.
    fn pollRemote(client: session_client.Client, a: std.mem.Allocator) !?session_client.Item {
        for (0..8) |_| {
            const polled = try client.poll(a);
            var item = polled orelse return null;
            if (item.epoch != 0 and item.epoch != client.snapshot().control_epoch) {
                item.deinit();
                // Never turn stale-item draining into repeated blocking page
                // requests in one UI tick.
                if (!client.buffered()) return null;
                continue;
            }
            return item;
        }
        return null;
    }

    /// Poll returns only items whose epoch still matches the current controller,
    /// so a real history snapshot may reset and seed the session input history.
    /// Display replay never becomes execution: only complete, unreduced
    /// canonical user_committed text is copied. A reset leaves an ordinary
    /// editor untouched; only an unsent draft parked by Up browsing is moved
    /// back so the reset cannot lose it. Live/queued events carry neither
    /// marker, so they cannot duplicate a history entry.
    fn adoptReplayHistory(self: *Ui, item: *const session_client.Item) void {
        if (item.history_display_reset) {
            self.replay_refused = self.delivery_admitted != self.delivery_acked;
            for (self.records.items) |record| {
                if (record.kind == .reasoning) continue;
                if (record.stream) |stream| {
                    if (stream.windowBytes() != 0 or stream.decoder.carry_len != 0 or stream.decoder.held_cr or record.pending_stream_rows != 0)
                        self.replay_refused = true;
                }
            }
            if (self.replay_refused) {
                self.notice = "History reset refused; unacknowledged display retained";
                self.requestDraw();
                return;
            }
            // Replace the current view with one canonical baseline, including a
            // submit whose receipt overtook the baseline. Do not clear native
            // scrollback, the composer, pending commands, or owner barriers.
            self.discardResizedFrame();
            self.clearPermission();
            self.clearActiveTool();
            self.clearToolCaptions();
            self.tool_calls.deinit(self.allocator);
            self.tool_calls = .{};
            self.tool_views.clear(self.allocator);
            // The startup banner and local notices are not canonical history;
            // a first baseline must not erase them before the first frame.
            var kept: usize = 0;
            for (self.records.items) |*record| {
                if (record.kind == .notice) {
                    self.records.items[kept] = record.*;
                    kept += 1;
                } else record.deinit(self.allocator);
            }
            self.records.items.len = kept;
            self.record_index.clearRetainingCapacity();
            for (self.records.items, 0..) |record, index| self.record_index.putAssumeCapacityNoClobber(record.id, index);
            self.draft = null;
            self.reasoning = null;
            self.requestDraw();
        }
        if (item.history_reset) {
            if (self.input_history.index != null and self.history_draft != null) {
                self.restoreHistoryDraft();
            } else self.dropHistoryDraft();
            self.input_history.deinit(self.allocator);
        }
        if (!item.history_replay or item.display_truncated or !item.canonical_complete) return;
        const committed = switch (item.event) {
            .user_committed => |value| value.text,
            else => return,
        };
        const trimmed = std.mem.trimStart(u8, committed, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '/') return;
        const owned = self.input_history.prepare(self.allocator, committed) catch return;
        self.input_history.commit(self.allocator, owned);
    }

    fn bridgeEmpty(self: *const Ui) bool {
        std.debug.assert(std.c.pthread_mutex_lock(&self.bridge.mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.bridge.mutex) == .SUCCESS);
        return self.bridge.len == 0 and self.bridge.outstanding == 0 and self.bridge.bytes == 0 and self.bridge.active == 0;
    }

    /// Track owner-reported activity. A task that becomes idle without a
    /// delivered terminal is settled explicitly after a second observation, so
    /// a lost result never leaves the composer stuck in a busy state.
    fn remoteSynchronizing(self: *const Ui) bool {
        const client = self.remote() orelse return false;
        return self.remoteSnapshotSynchronizing(client.snapshot());
    }

    fn remoteSnapshotSynchronizing(self: *const Ui, snapshot: *const session_client.Snapshot) bool {
        return snapshot.attached and (!snapshot.available or snapshot.control_epoch != self.remote_epoch);
    }

    fn adoptRemoteActivity(self: *Ui, snapshot: *const session_client.Snapshot) void {
        const syncing = self.remoteSnapshotSynchronizing(snapshot);
        if (syncing != self.remote_observed_sync) {
            self.remote_observed_sync = syncing;
            if (!syncing and std.mem.eql(u8, self.notice, "Synchronizing session; draft kept")) self.notice = "Ready";
            self.requestDraw();
        }
        if (snapshot.busy) {
            self.remote_idle_ticks = 0;
            // The owner can stay busy across two tasks, and a handled terminal no
            // longer clears the local view when the owner still reports busy, so
            // this busy sample may be the same task rather than a next one.
            // Re-adopt only when the local view really is idle and nothing is
            // waiting for ordered evidence, or a continuous next task could never
            // become visible.
            if (!self.remote_terminal_wait and !self.busy) {
                self.busy = true;
                self.mode = snapshot.mode orelse .calling_model;
                self.remote_kind = snapshot.task_kind;
                self.notice = "Attached; task is running";
                self.approval_paste_seen = false;
                self.requestDraw();
            }
        } else if (self.busy and (self.remote_observed_busy or self.remote_idle_ticks != 0)) {
            // Consecutive idle samples must keep accumulating after the first one
            // clears `remote_observed_busy`; entering this branch at all already
            // requires a busy sample, either now or when the count started.
            self.remote_idle_ticks +|= 1;
            if (self.remote_idle_ticks >= 2 and self.bridge.terminal == null and self.bridgeEmpty()) {
                if (self.remote_terminal_wait) self.releaseRemoteTerminalWait() else self.settleRemoteIdle();
            }
        }
        self.remote_observed_busy = snapshot.busy;
    }

    /// Owner-ordered idle consumed a terminal that was already handled: the task
    /// view may end, but the delivered result and its notice stay visible. This
    /// is not the missing-terminal path.
    fn releaseRemoteTerminalWait(self: *Ui) void {
        self.remote_terminal_wait = false;
        self.busy = false;
        self.mode = null;
        self.remote_idle_ticks = 0;
        self.requestDraw();
    }

    fn settleRemoteIdle(self: *Ui) void {
        self.remote_terminal_wait = false;
        self.busy = false;
        self.mode = null;
        self.remote_idle_ticks = 0;
        if (self.draft) |index| {
            self.records.items[index].interrupted = true;
            if (self.records.items[index].stream) |stream| stream.finish() catch {
                self.notice = "Could not finalize interrupted display";
            };
        }
        self.discardReasoning();
        self.draft = null;
        self.clearActiveTool();
        self.clearToolCaptions();
        self.tool_views.clear(self.allocator);
        self.clearPermission();
        self.last_terminal = null;
        self.notice = "Remote task ended without a terminal result; reattach to verify";
        self.requestDraw();
    }

    /// A new control epoch (attach/takeover/session switch) revokes every piece
    /// of display authority that belonged to the old session.
    fn resetSessionView(self: *Ui, snapshot: *const session_client.Snapshot) !void {
        self.closeResumePicker();
        self.clearResumePending();
        // Revoke old frame and approval authority even if the bridge is busy.
        // Do not adopt the new epoch or destroy the old display until both
        // operations succeed.
        self.clearPermission();
        self.clearSubagentRows();
        self.subagent_group = 0;
        self.subagent_last_group = if (snapshot.busy) 0 else snapshot.subagents.group_id;
        self.subagent_epoch = snapshot.control_epoch;
        self.subagent_starting = false;
        self.discardResizedFrame();
        self.frame_permission = null;
        self.frame_fresh = false;
        self.displayed_stop = null;
        self.frame_stop = null;
        self.displayed_model_epoch = null;
        self.displayed_model_generation = null;
        self.frame_model_epoch = null;
        self.frame_model_generation = null;
        self.displayed_command_generation = null;
        self.frame_command_generation = null;
        self.displayed_provider_generation = null;
        self.frame_provider_generation = null;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.displayed_decision_fingerprint = null;
        self.frame_decision_fingerprint = null;
        self.displayed_proxy_fingerprint = null;
        self.frame_proxy_fingerprint = null;
        self.delivery_proven = 0;
        self.delivery_receipt = null;
        self.frame_delivery_epoch = 0;
        self.frame_delivery_sequence = 0;
        self.bridge.reset() catch |err| {
            self.notice = "UI reset failed; reattach to resync";
            self.requestDraw();
            return err;
        };
        const host = self.bridge.host();
        if (host.rebase_permission_fn) |rebase| rebase(host.context) catch |err| {
            self.notice = "UI reset failed; reattach to resync";
            self.requestDraw();
            return err;
        };
        // The owner's snapshot is the only source of epoch identity.
        self.remote_epoch = snapshot.control_epoch;
        self.delivery_epoch = 0;
        self.delivery_admitted = 0;
        self.delivery_proven = 0;
        self.delivery_acked = 0;
        self.delivery_fault = false;
        self.delivery_ack_unsupported = false;
        self.delivery_range_unsupported = false;
        self.delivery_fences.clearRetainingCapacity();
        self.delivery_receipt = null;
        self.frame_delivery_epoch = 0;
        self.frame_delivery_sequence = 0;
        self.frame_delivery_shown = false;
        self.frame_delivery_reasoning = false;
        self.terminal_delivery = null;
        self.replay_refused = false;
        self.clearPermission();
        self.stop_open = false;
        self.stop_danger = false;
        self.stop_identity = null;
        self.stop_generation +%= 1;
        self.displayed_stop = null;
        self.frame_stop = null;
        if (self.stop_close) |id| {
            self.allocator.free(id);
            self.stop_close = null;
        }
        self.detachInbox();
        self.queue_owner = null;
        self.inbox.deinit();
        self.inbox = .{};
        self.clearActiveTool();
        self.clearToolCaptions();
        self.tool_calls.deinit(self.allocator);
        self.tool_calls = .{};
        self.tool_views.clear(self.allocator);
        self.discardResizedFrame();
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.clearRetainingCapacity();
        self.record_index.clearRetainingCapacity();
        self.draft = null;
        self.reasoning = null;
        self.last_terminal = null;
        self.mode = null;
        self.display = .{};
        self.model_flow = .{};
        self.history_notice_shown = false;
        self.settings_error_seen = null;
        self.log_error_seen = null;
        self.settings_notice_seen = null;
        self.memory_completion_pending = null;
        self.terminal_notice_pending = null;
        self.terminal_alias = "";
        self.notice_alias_hash = null;
        self.notice_alias_pending = null;
        self.poisoned = false;
        self.closeSettingsMenu();
        self.closeProviderPicker();
        self.closeModelPicker();
        self.closeCommandMenu();
        self.secret_mode = false;
        self.secret_quarantine = false;
        self.secret.wipe();
        self.secret_provider = null;
        self.parser.secretMode(false);
        self.input_history.deinit(self.allocator);
        self.dropHistoryDraft();
        self.wipeEditor();
        self.discardResizedFrame();
        self.displayed_permission = null;
        self.displayed_permission_choice = null;
        self.frame_permission = null;
        self.frame_permission_choice = null;
        self.displayed_model_epoch = null;
        self.displayed_model_generation = null;
        self.displayed_command_generation = null;
        self.displayed_provider_generation = null;
        self.displayed_settings_generation = null;
        self.displayed_decision_fingerprint = null;
        self.frame_decision_fingerprint = null;
        self.displayed_proxy_fingerprint = null;
        self.frame_proxy_fingerprint = null;
        self.model_epoch +%= 1;
        self.command_menu.changed();
        self.task_epoch +%= 1;
        self.remote_kind = snapshot.task_kind;
        self.remote_observed_busy = snapshot.busy;
        self.remote_idle_ticks = 0;
        self.remote_terminal_wait = false;
        self.busy = snapshot.busy;
        if (snapshot.busy) self.mode = snapshot.mode orelse self.mode;
        self.notice = if (snapshot.busy) "Attached; task is running" else "Ready";
        self.display_changed = true;
        self.resize_waiting = false;
        self.frame_fresh = false;
        self.dirty = true;
    }

    fn adoptNotice(self: *Ui, value: []u8) void {
        if (self.notice_owned) |old| self.allocator.free(old);
        self.notice_owned = value;
        self.notice = value;
    }

    /// Session-management commands are parsed before busy/steering handling: they
    /// never enter model history, Steering, FollowUp or an inference request.
    fn runManageText(self: *Ui, command: []const u8) bool {
        const trimmed = std.mem.trim(u8, command, " \t");
        if (trimmed.len == 0 or trimmed[0] != '/') return false;
        const name_end = std.mem.findAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
        const name = trimmed[0..name_end];
        const is_resume = std.mem.eql(u8, name, "/resume");
        const is_list = std.mem.eql(u8, name, "/ls");
        const is_cd = std.mem.eql(u8, name, "/cd");
        const is_attach = std.mem.eql(u8, name, "/attach") or std.mem.eql(u8, name, "/attch");
        const is_detach = std.mem.eql(u8, name, "/detach");
        const is_exit = std.mem.eql(u8, name, "/exit");
        const is_close = std.mem.eql(u8, name, "/close");
        if (!(is_resume or is_list or is_cd or is_attach or is_detach or is_exit or is_close)) return false;
        // The editor is wiped below; parse an owned copy so arguments stay valid.
        const owned = self.allocator.dupe(u8, trimmed) catch {
            self.wipeEditor();
            self.notice = "Out of memory; command not sent";
            return true;
        };
        defer self.allocator.free(owned);
        self.wipeEditor();
        const backend = self.remote() orelse {
            self.notice = "Session commands need a daemon connection (thin --connect)";
            return true;
        };
        const name_end_owned = std.mem.findAny(u8, owned, " \t\r\n") orelse owned.len;
        const rest = std.mem.trim(u8, owned[name_end_owned..], " \t");
        if (std.mem.findScalar(u8, owned, '\n') != null or std.mem.findScalar(u8, owned, '\r') != null or std.mem.findScalar(u8, owned, 0) != null) {
            self.notice = "Session commands are single-line";
            return true;
        }
        if (is_resume) {
            if (rest.len == 0) {
                self.openResumeRequest(backend);
            } else if (rest.len == 32 and for (rest) |c| {
                if (!std.ascii.isHex(c)) break false;
            } else true) {
                self.applyManage(backend, .{ .@"resume" = rest });
            } else self.notice = "Usage: /resume [32-hex-id]";
            return true;
        }
        if (is_detach or is_exit) {
            if (rest.len != 0) {
                self.notice = if (is_detach) "Usage: /detach" else "Usage: /exit";
                return true;
            }
            self.applyManage(backend, if (is_detach) .detach else .exit);
            return true;
        }
        if (is_cd) {
            if (rest.len == 0 or rest.len > 4096) {
                self.notice = "Usage: /cd <directory>";
                return true;
            }
            // No chdir and no bash string: the backend validates the path,
            // detaches first and changes only the launcher directory.
            self.applyManage(backend, .{ .cd = rest });
            return true;
        }
        var words: [4][]const u8 = undefined;
        const count = splitWords(rest, &words);
        if (is_list) {
            var running_only = false;
            var page: usize = 0;
            var index: usize = 0;
            while (index < count) : (index += 1) {
                const word = words[index];
                if (std.mem.eql(u8, word, "--running")) {
                    running_only = true;
                    continue;
                }
                if (std.mem.eql(u8, word, "--page") and index + 1 < count) {
                    index += 1;
                    page = std.fmt.parseInt(usize, words[index], 10) catch {
                        self.notice = "Usage: /ls [--running] [--page N]";
                        return true;
                    };
                    continue;
                }
                self.notice = "Usage: /ls [--running] [--page N]";
                return true;
            }
            self.applyManage(backend, .{ .list = .{ .running_only = running_only, .page = page } });
            return true;
        }
        var force = false;
        var takeover = false;
        var id: ?[]const u8 = null;
        for (words[0..count]) |word| {
            if (is_attach and std.mem.eql(u8, word, "--takeover")) {
                takeover = true;
                continue;
            }
            if (is_close and std.mem.eql(u8, word, "--force")) {
                force = true;
                continue;
            }
            if (word.len != 0 and word[0] == '-') {
                self.notice = if (is_attach) "Usage: /attach [--takeover] <id>" else "Usage: /close [--force] <id>";
                return true;
            }
            if (id != null) {
                self.notice = if (is_attach) "Usage: /attach [--takeover] <id>" else "Usage: /close [--force] <id>";
                return true;
            }
            id = word;
        }
        const session_id = id orelse {
            self.notice = if (is_attach) "Usage: /attach [--takeover] <id>" else "Usage: /close [--force] <id>";
            return true;
        };
        if (session_id.len == 0 or session_id.len > 256) {
            self.notice = "Invalid session id";
            return true;
        }
        if (is_attach) {
            self.applyManage(backend, .{ .attach = .{ .id = session_id, .takeover = takeover } });
        } else {
            self.startClose(backend, session_id, force);
        }
        return true;
    }

    fn splitWords(text_: []const u8, out: *[4][]const u8) usize {
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, text_, " \t");
        while (it.next()) |word| {
            if (count == out.len) break;
            out[count] = word;
            count += 1;
        }
        return count;
    }

    fn clearResumePending(self: *Ui) void {
        if (self.resume_pending) |pending| {
            if (pending.launcher) |launcher| self.allocator.free(launcher);
        }
        self.resume_pending = null;
    }

    fn closeResumePicker(self: *Ui) void {
        if (self.resume_picker) |*picker| picker.deinit(self.allocator);
        self.resume_picker = null;
        self.displayed_resume_generation = null;
        self.frame_resume_generation = null;
    }

    fn resumeContextCurrent(self: *const Ui, epoch: u64, session_id: ?[32]u8, launcher: ?[]const u8) bool {
        const client = self.remote() orelse return false;
        const current = client.snapshot();
        if (current.control_epoch != epoch or !std.meta.eql(current.session_id, session_id)) return false;
        if (current.launcher_dir) |dir| return if (launcher) |old| std.mem.eql(u8, dir, old) else false;
        return launcher == null;
    }

    fn openResumeRequest(self: *Ui, client: session_client.Client) void {
        self.clearResumePending();
        const snapshot = client.snapshot();
        const launcher = if (snapshot.launcher_dir) |dir| self.allocator.dupe(u8, dir) catch {
            self.notice = "Out of memory; session list not requested";
            return;
        } else null;
        self.resume_pending = .{ .epoch = snapshot.control_epoch, .session_id = snapshot.session_id, .launcher = launcher };
        self.applyManage(client, .saved_sessions);
    }

    fn resumeKey(self: *Ui, event_: input.Event) void {
        const picker = &self.resume_picker.?;
        if (!self.resumeContextCurrent(picker.epoch, picker.session_id, picker.launcher)) {
            self.parser.stop_feed = true;
            self.closeResumePicker();
            self.notice = "Session context changed; reopen /resume";
            return;
        }
        if (event_ == .paste_start) {
            self.resume_serial +%= 1;
            picker.generation = self.resume_serial;
            return;
        }
        if (self.parser.pasted or self.parser.batch_paste) return;
        switch (event_) {
            .escape, .left, .cancel => {
                self.parser.stop_feed = true;
                self.closeResumePicker();
            },
            .quit => self.requestQuit(),
            .up, .down => {
                self.resume_serial +%= 1;
                picker.move(event_ == .down);
                picker.generation = self.resume_serial;
            },
            .enter => {
                if (self.frame.len != 0 or self.displayed_resume_generation != picker.generation or self.normalAsyncPending()) return;
                const id = picker.sessions[picker.selected].id;
                self.parser.stop_feed = true;
                self.closeResumePicker();
                if (self.remote()) |client| self.applyManage(client, .{ .@"resume" = &id });
            },
            else => {},
        }
    }

    fn applyManage(self: *Ui, client: session_client.Client, request: session_client.Manage) void {
        if (self.connection.async_actions != null) {
            if (self.beginAsync(.{ .manage = request }, .manage) == null and request == .saved_sessions) self.clearResumePending();
            return;
        }
        var outcome = client.manage(self.allocator, request) catch |err| {
            if (request == .saved_sessions) self.clearResumePending();
            self.notice = session_client.describe(err);
            self.requestDraw();
            return;
        };
        defer outcome.deinit(self.allocator);
        self.acceptManage(&outcome, request == .@"resume");
        if (request == .saved_sessions) self.clearResumePending();
    }

    fn acceptManage(self: *Ui, outcome: *session_client.Outcome, preserve_editor: bool) void {
        const leaving = outcome.exit;
        if (outcome.saved_sessions) |sessions| {
            if (self.resume_pending) |pending| {
                if (self.resumeContextCurrent(pending.epoch, pending.session_id, pending.launcher)) {
                    if (sessions.len == 0) {
                        self.notice = "No saved sessions in this launcher directory";
                    } else {
                        self.closeResumePicker();
                        self.resume_serial +%= 1;
                        self.resume_picker = .{ .sessions = sessions, .epoch = pending.epoch, .session_id = pending.session_id, .launcher = pending.launcher, .generation = self.resume_serial };
                        self.resume_pending = null;
                        outcome.saved_sessions = null;
                        self.notice = "Ready";
                    }
                }
            }
            self.clearResumePending();
        }
        if (outcome.switched) if (self.remote()) |client| {
            if (preserve_editor) {
                const parked = self.editor;
                const pasted = self.editor_pasted;
                self.editor = .{ .allocator = self.allocator };
                const result = self.resetSessionView(client.snapshot());
                self.editor.deinit();
                self.editor = parked;
                self.editor_pasted = pasted;
                result catch return;
            } else self.resetSessionView(client.snapshot()) catch return;
        };
        // Leaving the owner view ends any handled-terminal wait; the result and
        // its notice stay as the last known state instead of a busy display.
        if (self.remote()) |client| if (!client.snapshot().attached and self.remote_terminal_wait) self.releaseRemoteTerminalWait();
        if (outcome.listing) |listing| _ = self.add(.notice, listing) catch {};
        if (outcome.notice) |notice| {
            // Transfer ownership instead of copying a bounded listing twice.
            outcome.notice = null;
            self.adoptNotice(notice);
        } else if (outcome.listing != null) {
            self.notice = "Ready";
        }
        if (leaving) self.requestQuit();
        self.requestDraw();
    }

    fn attachedSession(self: *const Ui, id: []const u8) bool {
        const hex = self.connection.current().session_id orelse return false;
        if (id.len != hex.len * 2) return false;
        const alphabet = "0123456789abcdef";
        for (hex, 0..) |byte, index| {
            if (id[index * 2] != alphabet[byte >> 4] or id[index * 2 + 1] != alphabet[byte & 0x0f]) return false;
        }
        return true;
    }

    /// Busy close needs an explicit confirmation; `--force` is the typed form of
    /// the same intent. Unknown (not attached) sessions are decided by the owner.
    fn startClose(self: *Ui, client: session_client.Client, id: []const u8, force: bool) void {
        if (!force and self.busy and self.attachedSession(id)) {
            if (self.stop_close) |old| self.allocator.free(old);
            self.stop_close = self.allocator.dupe(u8, id) catch {
                self.notice = "Out of memory; close not requested";
                return;
            };
            self.stop_instance +%= 1;
            self.stop_open = true;
            self.stop_danger = false;
            self.stop_identity = self.stopIdentity();
            self.invalidateStop();
            self.parser.stop_feed = true;
            self.notice = "Session is busy; confirm close";
            return;
        }
        self.applyManage(client, .{ .close = .{ .id = id, .force = force } });
    }

    /// A user decision, explicit revocation, or terminal retires this exact request.
    fn settlePermissionDelivery(self: *Ui, id: u64, epoch: u64) void {
        for (self.delivery_fences.items) |*fence| {
            if (fence.permission_epoch == epoch and fence.permission_id == id) fence.proven = true;
        }
    }

    /// 释放当前审批的描述并清空审批状态（包括已显示的审批 id/choice）。
    fn clearPermission(self: *Ui) void {
        if (self.permission) |permission| self.allocator.free(permission.description);
        self.frame_permission = null;
        self.permission = null;
        self.displayed_permission = null;
        self.displayed_permission_choice = null;
        self.frame_permission_choice = null;
    }

    fn add(self: *Ui, kind: Kind, data: []const u8) !usize {
        return self.addRecord(kind, data, false);
    }

    fn addRecord(self: *Ui, kind: Kind, data: []const u8, is_agent_row: bool) !usize {
        // Prepare every fallible part before publishing an id.
        // A failed body allocation owns no display row.
        try self.reserveRecord();
        var prepared = Record{ .kind = kind, .batch = self.restoring, .agent_row = is_agent_row };
        errdefer prepared.deinit(self.allocator);
        if (kind == .reasoning) try prepared.attachTail(self.allocator, @max(1, self.size.columns -| 1));
        try prepared.append(self.allocator, data);

        self.records.appendAssumeCapacity(prepared);
        const index = self.records.items.len - 1;
        self.registerRecord(index) catch |err| {
            // Still unpublished: do not retarget fences or remove id zero.
            _ = self.records.pop();
            return err;
        };
        if (kind == .notice) {
            self.compact_composer = false;
            if (self.idle_breaks != 0 or self.frame_idle_breaks != 0) self.idle_notice_barrier = true;
        }
        self.requestDraw();
        return index;
    }

    /// Display-only projection of locally loaded canonical history.
    /// No Bridge/observer events, execution, approvals or live reasoning replay.
    fn restoreHistory(self: *Ui, messages: []const p.Message) !void {
        if (messages.len == 0) return;
        const prior_restoring = self.restoring;
        self.restoring = true;
        defer self.restoring = prior_restoring;
        const restore_notice = try self.add(.notice, "Restored model context (display may be shortened); prior tools are NOT rerun");
        self.records.items[restore_notice].batch = false;
        // Published: this transcript banner now owns the success notice for
        // this view. Set only after the row really exists.
        self.history_notice_shown = true;
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
                    if (value.len != 0 and value[0] != '/') {
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
    }

    fn removeRecord(self: *Ui, index: usize) void {
        // A record that is intentionally replaced never keeps an unprovable
        // identity: its fences stay ordered but wait for a fresh frame of the
        // replacement instead of fabricating stale/ABA proof.
        self.retargetDeliveryFences(self.records.items[index].id);
        self.forgetRecord(index);
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
        // Prepared background metadata is authoritative even when canonical
        // arguments happened to yield an ordinary bash or control caption.
        if (identity) |value| {
            if (try self.tool_views.cloneReadyCaption(self.allocator, value)) |caption| {
                if (caption.display != null or call.detail == null) return caption;
                caption.deinit(self.allocator);
            }
        }
        return presentation.fromCall(self.allocator, call);
    }

    fn isSubagentTool(name: []const u8) bool {
        return std.mem.eql(u8, name, "subagent") or std.mem.eql(u8, name, "get_subagent_result") or std.mem.eql(u8, name, "send_subagent_message") or std.mem.eql(u8, name, "cancel_subagent");
    }

    fn groupTools(self: *Ui) bool {
        const state = self.connection.current();
        // Individual per-agent rows are the only representation of children.
        // Without that capability the ordinary tool rows stay authoritative.
        return !self.applying_history and state.subagents_supported and (state.available or state.runtime != null);
    }

    fn subagentPhaseOutcome(agent: @import("../core/subagent_status.zig").AgentView) presentation.Outcome {
        if (agent.active()) return .pending;
        return switch (agent.phase) {
            .completed => .success,
            .failed => .failed,
            .canceled, .paused => .canceled,
            .starting, .running, .waiting => .pending,
        };
    }

    /// `#<id> · <phase> · <latest text>`; the id is the real child id, so no
    /// placeholder row can exist without one.
    fn subagentAgentLabel(a: std.mem.Allocator, agent: @import("../core/subagent_status.zig").AgentView) ![]const u8 {
        const phase = @tagName(agent.phase);
        const detail = try presentation.singleLine(a, agent.latestText(), 256);
        defer a.free(detail);
        if (detail.len == 0) return std.fmt.allocPrint(a, "#{d} · {s}", .{ agent.id, phase });
        return std.fmt.allocPrint(a, "#{d} · {s} · {s}", .{ agent.id, phase, detail });
    }

    fn subagentRowsVisible(self: *const Ui) bool {
        return self.subagent_rows.items.len != 0 or self.subagent_starting;
    }

    fn subagentRowsPending(self: *const Ui) bool {
        for (self.subagent_rows.items) |row| if (subagentPhaseOutcome(row.view) == .pending) return true;
        return false;
    }

    fn clearSubagentRows(self: *Ui) void {
        for (self.subagent_rows.items) |row| {
            if (self.record_index.get(row.record_id)) |index| {
                if (!self.records.items[index].output) self.removeRecord(index);
            }
        }
        self.subagent_rows.clearRetainingCapacity();
    }

    fn updateSubagentRow(self: *Ui, agent: @import("../core/subagent_status.zig").AgentView) !bool {
        for (self.subagent_rows.items) |*row| {
            if (row.view.id != agent.id) continue;
            if (agent.revision < row.view.revision or std.meta.eql(row.view, agent)) return false;
            const index = self.record_index.get(row.record_id) orelse return false;
            if (self.records.items[index].output) return false;
            const label = try subagentAgentLabel(self.allocator, agent);
            defer self.allocator.free(label);
            var replacement = Record{ .kind = .tool, .id = row.record_id, .stream_generation = self.records.items[index].stream_generation +% 1, .agent_row = true, .agent_open = agent.active() };
            errdefer replacement.deinit(self.allocator);
            try replacement.setCommand(self.allocator, .{ .kind = .subagent, .label = label }, subagentPhaseOutcome(agent), agent.elapsed_ms);
            self.records.items[index].deinit(self.allocator);
            self.records.items[index] = replacement;
            row.view = agent;
            return true;
        }
        try self.subagent_rows.ensureUnusedCapacity(self.allocator, 1);
        const index = try self.addRecord(.tool, "", true);
        errdefer self.removeRecord(index);
        const label = try subagentAgentLabel(self.allocator, agent);
        defer self.allocator.free(label);
        const record = &self.records.items[index];
        try record.setCommand(self.allocator, .{ .kind = .subagent, .label = label }, subagentPhaseOutcome(agent), agent.elapsed_ms);
        record.agent_open = agent.active();
        self.subagent_rows.appendAssumeCapacity(.{ .view = agent, .record_id = record.id });
        self.subagent_starting = false;
        return true;
    }

    fn finishSubagentRows(self: *Ui) !void {
        self.subagent_rows.clearRetainingCapacity();
        self.subagent_last_group = @max(self.subagent_last_group, self.subagent_group);
    }

    fn observeSubagents(self: *Ui) !void {
        const state = self.connection.current();
        const view = state.subagents;
        if (!state.subagents_supported or (!state.available and state.runtime == null)) {
            const had_row = self.subagentRowsVisible();
            self.clearSubagentRows();
            self.subagent_group = 0;
            self.subagent_starting = false;
            if (had_row) self.requestDraw();
            return;
        }
        var changed = false;
        if (self.subagent_epoch != state.control_epoch) {
            // Switching control does not settle the old root's mutable rows.
            changed = self.subagentRowsVisible();
            self.subagent_epoch = state.control_epoch;
            self.subagent_last_group = if (state.busy) 0 else view.group_id;
            self.clearSubagentRows();
            self.subagent_group = 0;
            self.subagent_starting = false;
        }
        if (view.group_id != 0 and view.group_id > self.subagent_last_group) {
            if (view.group_id > self.subagent_group) {
                // A different root owns the new ids; unsettled old rows are not
                // ours to settle, and a finished group is never replayed.
                changed = changed or self.subagentRowsVisible();
                self.clearSubagentRows();
                self.subagent_group = view.group_id;
            }
            // Borrowed for this observation only; each row keeps a value copy.
            for (view.agents) |agent| {
                if (agent.id == 0) continue;
                if (try self.updateSubagentRow(agent)) changed = true;
            }
        }
        if (!self.busy and !self.presentationWaiting() and !self.remote_terminal_wait) {
            if (self.subagent_starting and self.subagent_rows.items.len == 0) {
                self.subagent_starting = false;
                changed = true;
            }
            if (self.subagent_rows.items.len != 0 and view.group_id == self.subagent_group and view.agents.len >= view.total and !self.subagentRowsPending()) {
                try self.finishSubagentRows();
                changed = true;
            }
        }
        if (changed) self.requestDraw();
    }

    fn toolCompleted(self: *Ui, caption: presentation.Caption, result: r.Execution) !void {
        const completion = shared.tools.Completion.fromExecution(result);
        const outcome = completion.outcome;
        const replacement: ?presentation.Caption = if (completion.display) |display|
            try presentation.withBackground(self.allocator, caption, display)
        else
            null;
        defer if (replacement) |value| value.deinit(self.allocator);
        const effective = replacement orelse caption;
        const observed = if (outcome == .success) try presentation.completed(self.allocator, effective, completion.file_stats) else presentation.Caption{
            .kind = effective.kind,
            .label = try self.allocator.dupe(u8, effective.label),
            .display = effective.display,
            .failure_reason = if (effective.kind == .read) shared.tools.readFailure(result) else null,
        };
        defer observed.deinit(self.allocator);
        const index = try self.add(.tool, "");
        const handoff = if (effective.display) |display| display.action == .start and outcome == .success else false;
        try self.records.items[index].setCommand(self.allocator, observed, outcome, if (handoff) null else completion.duration_ms);
    }

    fn localCommandOutput(self: *Ui, data: []const u8, truncated: bool) !void {
        const output = try local_command_output.format(self.allocator, data);
        defer self.allocator.free(output.text);
        _ = try self.add(.tool, output.text);
        // A runtime or Bridge cap can cut the JSON envelope itself. Preserve
        // that outer provenance even when the formatter falls back to literal.
        if (truncated) _ = try self.add(.notice, "Local command result was truncated; some output is unavailable.");
    }

    /// Only the currently running call is replaceable; every result owns a row.
    fn pendingCommand(self: *Ui, a: std.mem.Allocator, columns: usize) ![]const u8 {
        const label = try presentation.commandText(a, self.active_tool.?.caption, .pending);
        defer a.free(label);
        const start = self.active_tool.?.started_ms;
        const background_start = if (self.active_tool.?.caption.display) |display| display.action == .start else false;
        return presentation.commandLine(a, label, &.{.{ .start = 0, .end = label.len, .outcome = .pending }}, columns, if (background_start) null else self.clock_ms -| start, self.clock_ms);
    }

    fn waitingCommand(self: *Ui, a: std.mem.Allocator, entry: tool_views_module.Entry, columns: usize) ![]const u8 {
        var observed: ?presentation.Caption = null;
        defer if (observed) |value| value.deinit(a);
        const caption = if (entry.write_progress != null and entry.caption.kind == .write) blk: {
            observed = try presentation.provisionalWrite(a, entry.caption, entry.write_progress.?);
            break :blk observed.?;
        } else entry.caption;
        const label = try presentation.commandText(a, caption, .pending);
        defer a.free(label);
        const generating = !entry.ready and entry.write_progress != null and entry.caption.kind == .write;
        // Generating and approval rows remain muted and static, without an
        // execution time; tool_started owns warm icon timing.
        return presentation.commandLine(a, label, &.{.{ .start = 0, .end = label.len, .outcome = .pending, .write_marks = if (caption.write_marks) |marks| marks.shifted(activity.icon(caption.kind).len + 1) else null, .generating = generating }}, columns, null, if (generating) self.clock_ms else null);
    }

    /// Only actionable notices/errors use a temporary hint row. Completed,
    /// mode, usage and performance have no rows; the composer owns activity.
    /// Exact current interaction / synchronization states stay in the neutral
    /// footer. Everything else is a one-shot result that belongs to the
    /// transcript. No model text or error-name keywords are inspected here.
    fn persistentNotice(self: *const Ui, value: []const u8) bool {
        if (self.settings_open) {
            if (self.settings_value_picker) |picker| {
                if (std.mem.eql(u8, value, settingsValueTitle(picker.key)) or
                    (picker.editing and std.mem.eql(u8, value, "Enter seconds with up to three decimal places")) or
                    (!picker.editing and std.mem.eql(u8, value, "Value staged; Enter after redraw saves"))) return true;
            }
            if (self.proxy_address_open and (std.mem.eql(u8, value, "Address") or
                std.mem.eql(u8, value, "Address pasted; review it, then Enter after redraw saves"))) return true;
        }
        const exact = [_][]const u8{
            pending_session_notice,
            "Synchronizing session; draft kept",
            "Refreshing official model metadata...",
            "Operation pending; input kept",
            "Queue belongs to another session; Ctrl-C to clear explicitly",
            "Message withdrawn; clear draft and press Esc to restore it",
            "Cancellation requested; cleaning up, not rolling back effects",
            "Stop requested; queue cleared; draft kept",
            "Confirm stop",
            "Attached; task is running",
            "Thinking capabilities are loading; try Shift+Tab again shortly",
            "Thinking capabilities unknown: refresh /model or declare reasoning levels in configuration",
        };
        for (exact) |entry| if (std.mem.eql(u8, value, entry)) return true;
        return std.mem.eql(u8, value, "Remote task ended without a terminal result; reattach to verify");
    }

    fn omitNotice(value: []const u8) bool {
        return std.mem.eql(u8, value, "Ready") or std.mem.eql(u8, value, "Running") or
            std.mem.eql(u8, value, "Completed") or std.mem.eql(u8, value, "Attached; task is running");
    }

    /// Program-owned success / explicit cancel outcomes are plain; rejected
    /// operations are warnings. These exact program messages are not probes.
    fn oneShotNoticeLevel(value: []const u8) NoticeLevel {
        if (std.mem.eql(u8, value, "Selection restored; NEW EMPTY CHAT (history not restored)")) return .plain;
        const plain_prefixes = [_][]const u8{
            "Saved",         "Key saved",         "Model selected", "Setup canceled", "Stop dismissed",
            "Queue resumed", "Message withdrawn", "Request denied", "Allowed once",
        };
        for (plain_prefixes) |prefix| if (std.mem.startsWith(u8, value, prefix)) return .plain;
        return .warning;
    }

    fn noticePublished(self: *const Ui) bool {
        return self.notice_alias_hash != null;
    }

    fn syncNoticeAlias(self: *Ui) void {
        const hash = std.hash.Wyhash.hash(0, self.notice);
        if (self.notice_alias_hash) |published| if (published != hash) {
            self.notice_alias_hash = null;
        };
        if (self.notice_alias_pending) |pending| if (pending.hash != hash) {
            self.notice_alias_pending = null;
        };
    }

    fn hint(self: *Ui, a: std.mem.Allocator, state: Connection.State) ![]const u8 {
        self.syncNoticeAlias();
        const persistent = !self.noticePublished() and !omitNotice(self.notice) and self.persistentNotice(self.notice);
        if (self.secret_quarantine) return "Esc closes";
        if (self.secret_mode) return if (persistent) self.notice else "";
        if (self.settings_open) {
            if (self.settings_value_picker) |picker| {
                const title = settingsValueTitle(picker.key);
                if (self.settings_menu.pasted) return std.fmt.allocPrint(a, "{s}; pasted selection, Esc cancels", .{title});
                if (persistent and !std.mem.eql(u8, self.notice, title)) return std.fmt.allocPrint(a, "{s}: {s}", .{ title, self.notice });
                return title;
            }
            return if (self.settings_menu.pasted) "Pasted selection; Esc cancels" else if (persistent) self.notice else "";
        }
        if (self.provider_open) return if (self.provider_picker.pasted) "Pasted selection; Esc cancels" else if (persistent) self.notice else "";
        if (self.model_picker) |picker| {
            if (picker.pasted) return "Pasted selection; Esc cancels";
            if (persistent) return self.notice;
            if (state.model_providers.len == 0) return "No logged-in providers: /login, then /model";
            return "";
        }
        if (self.commandMenuVisible()) return "";
        var notice: []const u8 = "";
        // A restored-success banner was published in this view. Its footer
        // twin stays suppressed even if the row is later evicted; only the
        // exact canonical success string is dropped.
        // Only the exact terminal alias already published in the conversation
        // is suppressed; a different actionable notice is never hidden.
        if (self.terminal_alias.len != 0 and !std.mem.eql(u8, self.terminal_alias, self.notice)) self.terminal_alias = "";
        const terminal_alias = self.terminal_alias.len != 0 and std.mem.eql(u8, self.terminal_alias, self.notice);
        const published_once = self.notice_alias_hash != null;
        const self_restored = self.history_notice_shown and std.mem.eql(u8, self.notice, session_client.restored_notice);
        if (!self_restored and !terminal_alias and !published_once and
            !omitNotice(self.notice) and self.persistentNotice(self.notice)) notice = self.notice;
        if (notice.len == 0 and !configured(state)) {
            if (setupHint(state)) |setup| {
                notice = setup;
            } else if (state.settings_notice == null or state.model.len == 0) {
                notice = "Not configured: /login, then /model";
            }
        }
        if (notice.len == 0 and self.remote() != null and !state.available) notice = "Daemon connection unavailable; /exit and reconnect";
        // Active/queued Memory has an independent persistent status. Its
        // terminal results are conversation notices and never return here.
        // The row is one braille frame plus, when waiting work exists, exactly
        // the queued count (the active job is never counted twice). The frame
        // comes from the ordinary 80 ms animation clock; nothing here schedules
        // a refresh of its own.
        if (self.permission == null and !self.stop_open and state.memory.enabled and
            (state.memory.active != null or state.memory.queued_count != 0))
        {
            const spinner = activity.spinner(self.clock_ms);
            const memory_text = if (state.memory.queued_count != 0)
                try std.fmt.allocPrint(a, "M: {s} +{d}", .{ spinner, state.memory.queued_count })
            else
                try std.fmt.allocPrint(a, "M: {s}", .{spinner});
            notice = if (notice.len == 0) memory_text else try std.fmt.allocPrint(a, "{s} | {s}", .{ notice, memory_text });
        }
        if (self.permission == null and !self.stop_open and state.background.active_count != 0) {
            const spinner = activity.spinner(self.clock_ms);
            const background_text = if (state.background.active_count > 1)
                try std.fmt.allocPrint(a, "B: {s} {d}", .{ spinner, state.background.active_count })
            else
                try std.fmt.allocPrint(a, "B: {s}", .{spinner});
            notice = if (notice.len == 0) background_text else try std.fmt.allocPrint(a, "{s} | {s}", .{ notice, background_text });
        }
        if (notice.len == 0) if (state.pending_default_effort) |effort| {
            notice = try std.fmt.allocPrint(a, "Default thinking: {s}; awaiting model capabilities", .{effort.name() orelse "unknown"});
        };
        // Persistent capability pending remains a neutral footer state; every
        // other owner notice was already migrated once into the transcript.
        if (state.settings_notice) |warning| {
            if (capabilityPendingNotice(warning)) {
                const same_capability_cause = std.mem.eql(u8, warning, "Saved thinking level not applied: model capabilities unknown") and
                    (std.mem.eql(u8, notice, "Thinking capabilities are loading; try Shift+Tab again shortly") or
                        std.mem.eql(u8, notice, "Thinking capabilities unknown: refresh /model or declare reasoning levels in configuration"));
                const restored_twin = self.history_notice_shown and std.mem.eql(u8, warning, session_client.restored_notice);
                if (!restored_twin and !same_capability_cause and !std.mem.eql(u8, notice, warning)) notice = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ notice, if (notice.len != 0) " | " else "", warning });
            }
        }
        return notice;
    }

    fn footerHint(self: *Ui, a: std.mem.Allocator, state: Connection.State) ![]const u8 {
        const base = try self.hint(a, state);
        const queue = self.queueSnapshot();
        // A paused empty Inbox has nothing to resume. The task failure is the
        // actionable issue; do not invent a second warning for S:0/F:0.
        if (queue.steering == 0 and queue.follow_up == 0) return base;
        return std.fmt.allocPrint(a, "{s}{s}S:{d} F:{d} {s}", .{
            base,                                                      if (base.len != 0) " | " else "", queue.steering, queue.follow_up,
            if (queue.paused) "paused (/queue resume)" else "pending",
        });
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
        var truncated_stream = false;
        var revised_stream = false;
        if (self.draft) |i| {
            const record = &self.records.items[i];
            // Bounded canonical text for the ONE exact comparison. The proof
            // that a complete, untruncated canonical body fits the mirror is
            // upstream (64 KiB total copy budget < 128 KiB mirror), so no
            // equivalence between deltas and canonical is ever assumed.
            var canonical: std.ArrayList(u8) = .empty;
            defer canonical.deinit(self.allocator);
            for (blocks) |block| switch (block) {
                .text => |v| try canonical.appendSlice(self.allocator, v),
                else => {},
            };
            if (record.stream != null) {
                if (canonical.items.len == 0 and !clipped and blocks_complete) {
                    // Explicitly withdrawn text is explained; a tool-only answer
                    // never had final prose to withdraw, so it stays silent.
                    withdrawn_preview = blocks.len == 0 and
                        (record.stream.?.visibleRows().len != 0 or record.stream_written != 0);
                    self.removeRecord(i);
                } else {
                    if (!clipped and blocks_complete and canonical.items.len <= canonical_mirror_limit) {
                        const same = !record.clipped and !record.mirror_full and record.body.items.len == canonical.items.len and
                            std.mem.eql(u8, record.body.items, canonical.items);
                        if (!same) {
                            record.output = false;
                            revised_stream = record.stream_written != 0;
                            record.stream_revised = revised_stream;
                            try record.resetStream();
                            record.body.clearRetainingCapacity();
                            record.clipped = false;
                            record.mirror_full = false;
                            try record.append(self.allocator, canonical.items);
                            // Explicit canonical replacement: the older sequences
                            // now require the REPLACEMENT's own source to be shown,
                            // never the retired generation's.
                            if (record.stream) |stream|
                                self.retargetDeliveryFencesTo(record.id, record.stream_generation, stream.acceptedSourceEnd());
                        }
                        record.stream.?.finish() catch {};
                        // A finished body is a new render generation: drop the
                        // cached rows so the next layout re-builds and pins it.
                        // Without a pin the renderer cannot report coverage.
                        record.invalidate();
                    } else {
                        // A clipped/partial canonical is NOT a complete body: keep
                        // the already displayed long stream, mark it explicitly.
                        record.clipped = true;
                        truncated_stream = true;
                        record.stream.?.finish() catch {};
                        record.invalidate();
                    }
                }
            } else {
                record.body.clearRetainingCapacity();
                record.clipped = false;
                record.invalidate();
                for (blocks) |block| switch (block) {
                    .text => |v| try record.append(self.allocator, v),
                    else => {},
                };
                if (clipped) {
                    record.clipped = true;
                    record.invalidate();
                }
                if (record.body.items.len == 0) {
                    withdrawn_preview = record.flow_prefix != null or record.pending_flow_prefix != null;
                    // Authoritative withdrawal: the record is gone, so its fences
                    // settle only through a fresh frame of the applied state.
                    self.removeRecord(i);
                } else {
                    // Rebuilt from canonical blocks without an incremental body:
                    // the same sequences now own the replacement's rows.
                    self.retargetDeliveryFencesTo(record.id, record.stream_generation, 0);
                }
            }
        } else {
            // No prior draft (e.g. reasoning-only preview was discarded): the
            // canonical text creates the record exactly as before.
            for (blocks) |block| switch (block) {
                .text => |v| try self.appendDraft(.assistant, v),
                else => {},
            };
            if (self.draft) |i| {
                const record = &self.records.items[i];
                if (clipped) {
                    record.clipped = true;
                    record.invalidate();
                }
                if (record.body.items.len == 0) {
                    withdrawn_preview = record.flow_prefix != null or record.pending_flow_prefix != null;
                    self.removeRecord(i);
                }
            }
        }
        self.draft = null;
        if (withdrawn_preview) _ = try self.add(.notice, "Stream preview withdrawn (final response has no text)");
        if (truncated_stream) _ = try self.add(.notice, "Final response was truncated for display; the streamed preview above is unchanged");
    }

    /// 把一个 bridge 事件应用到 UI 状态：追加文本、更新状态、插入审批或工具记录等。
    fn event(self: *Ui, item: bridge_module.Item) !void {
        return self.applyEvent(item.event, item.display_truncated, item.canonical_complete);
    }

    /// Pre-application display identity, so the receipt can name the record that
    /// this event actually advanced without predicting later state.
    const DeliveryBefore = struct {
        draft_id: u64,
        reasoning_id: u64,
        next_id: u64,
    };

    fn captureDeliveryBefore(self: *const Ui) DeliveryBefore {
        return .{
            .draft_id = if (self.draft) |index| self.records.items[index].id else 0,
            .reasoning_id = if (self.reasoning) |index| self.records.items[index].id else 0,
            .next_id = self.next_record_id,
        };
    }

    /// The newest record this event created, or null when it created none.
    fn newestDeliveryRecord(self: *const Ui, before_next_id: u64) ?usize {
        if (self.records.items.len == 0) return null;
        const index = self.records.items.len - 1;
        if (self.records.items[index].id >= before_next_id) return index;
        return null;
    }

    /// Receipt capture is payload-aware, not tag-aware: an exactly empty raw
    /// text/reasoning payload appends no source, so it cannot point at the
    /// current body's accepted end. A held CR keeps that end unmoved across the
    /// resolving LF too, so "accepted end unchanged" would be the wrong rule;
    /// only the actual payload length can say whether this event added source.
    fn captureDeliveryReceipt(self: *Ui, before: DeliveryBefore, applied: r.Event) void {
        self.delivery_receipt = null;
        var candidate: ?usize = null;
        var reasoning = false;
        var source = true;
        switch (applied) {
            .permission => |permission| {
                self.delivery_receipt = .{ .id = 0, .generation = 0, .permission_id = permission.id, .permission_epoch = self.inject_epoch };
                return;
            },
            .text => |v| {
                // No bytes were appended, so nothing new needs displaying. The
                // sequence is a metadata fence: its own fresh frame proves it,
                // never the older body's held-CR target (unreachable for it).
                if (v.len == 0) return;
                candidate = self.recordIndexOfId(before.draft_id);
            },
            .assistant_committed => candidate = self.recordIndexOfId(before.draft_id),
            .reasoning => |v| {
                // Empty thinking keeps its explicit UX ownership (the record's
                // newest rows prove it) but carries no new source.
                candidate = self.recordIndexOfId(before.reasoning_id);
                reasoning = true;
                source = v.len != 0;
            },
            .memory_completed, .background_completed => {
                // A completed background result owns its appended row, not a
                // stream source. A silent skipped result is a metadata fence.
                source = false;
                if (self.newestDeliveryRecord(before.next_id)) |index| {
                    candidate = index;
                } else {
                    self.delivery_receipt = .{ .id = 0, .generation = 0, .source = false };
                    return;
                }
            },
            .user_committed, .tool_result, .compacted, .compaction_failed, .fallback => {},
            else => return,
        }
        if (candidate == null) candidate = self.newestDeliveryRecord(before.next_id);
        const index = candidate orelse {
            // A payload the UX intentionally hid (reasoning while prose runs)
            // still owns its span; keep the replacement semantics explicit.
            if (reasoning) self.delivery_receipt = .{ .id = 0, .generation = 0, .reasoning = true };
            return;
        };
        self.delivery_receipt = .{
            .id = self.records.items[index].id,
            .generation = self.records.items[index].stream_generation,
            .reasoning = reasoning or self.records.items[index].kind == .reasoning,
            .source = source,
        };
    }

    fn recordIndexOfId(self: *const Ui, id: u64) ?usize {
        if (id == 0) return null;
        return self.record_index.get(id);
    }

    /// One typed event applied to the UI. Local workers reach this through the
    /// Bridge; owned remote display deltas reuse the same path directly.
    fn applyEvent(self: *Ui, event_: r.Event, display_truncated: bool, canonical_complete: bool) !void {
        const delivery_before = self.captureDeliveryBefore();
        defer self.captureDeliveryReceipt(delivery_before, event_);
        self.requestDraw();
        self.display.observe(event_, self.clock_ms);
        switch (event_) {
            .state => |state| {
                // An ordered owner state after a handled terminal is the next
                // task. That holds both while a busy snapshot still waits for
                // owner idle and after a terminal that already saw idle owner
                // state: the busy boolean alone could never prove either case.
                if (self.remote() != null and (self.remote_terminal_wait or self.last_terminal != null)) {
                    self.remote_terminal_wait = false;
                    self.last_terminal = null;
                    self.busy = true;
                    // Old idle samples belong to the finished task and must not
                    // settle the new one; this ordered state is its first busy
                    // evidence even when the snapshot itself still says idle.
                    self.remote_idle_ticks = 0;
                    self.remote_observed_busy = true;
                    self.remote_kind = if (self.remote()) |client| client.snapshot().task_kind else self.remote_kind;
                    self.notice = "Attached; task is running";
                    self.approval_paste_seen = false;
                }
                self.mode = state;
            },
            .user_committed => |v| {
                self.draft = null;
                self.discardReasoning();
                _ = try self.add(.user, v.text);
            },
            .permission_cleared => |id| {
                self.settlePermissionDelivery(id, self.inject_epoch);
                if (self.permission) |permission| if (permission.id == id and permission.epoch == self.inject_epoch) self.clearPermission();
            },
            .text => |v| {
                try self.appendDraft(.assistant, v);
                if (display_truncated and self.draft != null) {
                    self.records.items[self.draft.?].clipped = true;
                    self.records.items[self.draft.?].invalidate();
                }
            },
            .reasoning => |v| {
                try self.appendDraft(.reasoning, v);
                if (display_truncated and self.reasoning != null) {
                    self.records.items[self.reasoning.?].clipped = true;
                    self.records.items[self.reasoning.?].invalidate();
                }
            },
            .assistant_committed => |blocks| {
                try self.captureToolCaptions(blocks);
                // Runtime's command marker is canonical provenance, not model prose.
                if (!self.commandKind())
                    try self.replaceCommitted(blocks, display_truncated, canonical_complete);
            },
            .permission => |permission| {
                self.closeModelPicker();
                // 新审批到来时先释放旧的；粘贴标记沿用到这次请求。
                self.clearPermission();
                self.approval_paste_seen = self.approval_paste_seen or self.parser.pasted;
                self.permission = .{ .id = permission.id, .description = try self.allocator.dupe(u8, permission.description), .clipped = display_truncated, .pasted = self.approval_paste_seen, .epoch = self.inject_epoch };
                self.permission_scroll = 0;
            },
            .tool_started => |tool| {
                self.clearActiveTool();
                const grouped = self.groupTools() and isSubagentTool(tool.name);
                if (grouped and std.mem.eql(u8, tool.name, "subagent")) self.subagent_starting = true;
                self.active_tool = .{ .id = tool.id, .caption = try self.executionCaption(tool.name, tool.display_key), .started_ms = tool.started_ms orelse self.clock_ms, .display_key = tool.display_key, .grouped = grouped };
            },
            .tool_result => |tool| {
                // FIFO also covers prepare failures/denials without a start.
                // Normal model tools keep captions; explicit local commands also
                // project bounded literal streams without changing canonical data.
                if (self.active_tool) |active| {
                    if (active.id == tool.id) {
                        // Both events may arrive in one UI tick; use the worker's
                        // measured result, never queue-drain time as execution time.
                        if (!active.grouped) {
                            try self.toolCompleted(active.caption, tool.result);
                        } else if (self.subagent_starting and (tool.result.is_error or tool.result.canceled)) {
                            self.subagent_starting = false;
                            self.notice = "Subagent start failed";
                        }
                        if (active.display_key) |identity| self.tool_views.remove(self.allocator, identity);
                        self.clearActiveTool();
                    }
                } else {
                    const caption = try self.executionCaption(tool.name, tool.display_key);
                    defer caption.deinit(self.allocator);
                    if (!(self.groupTools() and isSubagentTool(tool.name))) {
                        try self.toolCompleted(caption, tool.result);
                    } else if (std.mem.eql(u8, tool.name, "subagent") and self.subagent_starting and (tool.result.is_error or tool.result.canceled)) {
                        self.subagent_starting = false;
                        self.notice = "Subagent start failed";
                    }
                    if (tool.display_key) |identity| self.tool_views.remove(self.allocator, identity);
                }
                if (self.commandKind()) try self.localCommandOutput(tool.result.text, tool.result.truncated or display_truncated);
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
            .memory_completed => |terminal| try self.acceptMemoryCompletion(terminal),
            .background_completed => |terminal| try self.appendBackgroundCompletion(terminal),
            // 这些事件对 UI 没有需要展示的内容。
            .finished => {},
            // Raw arguments only feed the shared meter above. Visible rows use
            // bounded typed snapshots produced before Bridge text clipping.
            .tool_preview => {},
            .tool_view => |view| {
                try self.tool_views.upsert(self.allocator, view);
                if (view.ready and view.subagent_progress != null) {
                    if (self.active_tool) |*active| if (active.display_key) |identity| {
                        if (identity.eql(view.key)) if (self.tool_views.get(view.key)) |entry| {
                            if (entry.ready and (entry.caption.kind == .subagent or entry.caption.kind == .subagent_id)) {
                                var replacement = entry.caption;
                                replacement.label = try self.allocator.dupe(u8, entry.caption.label);
                                active.caption.deinit(self.allocator);
                                active.caption = replacement;
                            }
                        };
                    };
                }
            },
            .tool_views => |stream| switch (stream.phase) {
                .begin => self.tool_views.begin(self.allocator, stream.generation),
                .commit => self.tool_views.commit(self.allocator, stream.generation),
                .discard => self.tool_views.discard(self.allocator, stream.generation),
            },
        }
    }

    fn requestQuit(self: *Ui) void {
        // A quit gesture or accepted session-leave action grants authority;
        // captured signals are checked separately by exitAuthorized.
        self.ctrl_d_exit = true;
        self.parser.stop_feed = true;
        // A remote frontend leaves without canceling the daemon-owned task;
        // deinit reports the detach. Explicit Ctrl-C still cancels it.
        if (self.busy and self.remote() == null) self.cancel.cancel();
    }
    fn exitAuthorized(self: *const Ui) bool {
        return self.ctrl_d_exit or interrupt.signal() != 0;
    }
    fn settingsIdle(self: *const Ui) bool {
        return !self.busy and !self.remoteSynchronizing() and self.future == null and self.permission == null and !self.poisoned and !self.exitAuthorized() and !self.secret_mode and !self.secret_quarantine and !self.parser.pasted;
    }
    /// No worker can still publish after its Future was joined. Check borrowed
    /// Bridge items as well as the queue, without reset's cancellation side effects.
    fn idleEnter(self: *Ui) bool {
        if (self.deferred_submit != null or self.presentationWaiting() or !self.settingsIdle() or self.editor_pasted or self.parser.batch_paste or
            self.parser.escape_len != 0 or self.parser.utf8_len != 0 or self.stop_open or
            self.settings_open or self.provider_open or self.model_picker != null or
            self.mode != null or self.active_tool != null or self.draft != null or
            self.size.columns < 9 or self.size.rows < 7 or
            std.mem.trim(u8, self.editor.bytes.items, " \t\r\n").len != 0) return false;
        const queue = self.inbox.snapshot();
        if (queue.steering != 0 or queue.follow_up != 0) return false;
        std.debug.assert(std.c.pthread_mutex_lock(&self.bridge.mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.bridge.mutex) == .SUCCESS);
        return self.bridge.active == 0 and self.bridge.len == 0 and self.bridge.outstanding == 0 and
            self.bridge.bytes == 0 and self.bridge.pending == null and self.bridge.terminal == null;
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
        const active = self.settingsIdle() and self.resume_picker == null and self.model_picker == null and !self.provider_open and !self.settings_open and !self.editor_pasted;
        if (!active) {
            self.command_matches = .{};
            return;
        }
        const found = command_menu_module.suggestions(self.editor.bytes.items, self.editor.cursor, self.editor_pasted);
        // Session management is only executable with a remote adapter; hide it
        // from local foreground mode instead of advertising a dead command.
        var matches = command_menu_module.Matches{};
        if (self.remote() != null) {
            matches = found;
        } else {
            for (found.commands[0..found.len]) |command| {
                if (command_menu_module.sessionOnly(command)) continue;
                matches.commands[matches.len] = command;
                matches.len += 1;
            }
        }
        if (matches.len == 0) {
            self.command_matches = .{};
            return;
        }
        // Compare identities too: /m -> /lg has the same number of candidates.
        if (!std.mem.eql(command_menu_module.Command, self.command_matches.commands[0..self.command_matches.len], matches.commands[0..matches.len])) self.command_menu.changed();
        self.command_matches = matches;
    }
    fn commandMenuVisible(self: *const Ui) bool {
        return self.settingsIdle() and !self.editor_pasted and self.command_matches.len != 0 and !self.command_menu.dismissed and self.resume_picker == null and self.model_picker == null and !self.provider_open and !self.settings_open;
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
    fn settingsModelOpen(self: *const Ui) bool {
        return self.settings_model_picker != .none;
    }
    /// Any settings child that borrows the editor as a bounded query.
    fn settingsQueryOpen(self: *const Ui) bool {
        return self.settingsModelOpen() or self.proxy_open;
    }
    fn settingsModels(self: *const Ui, state: Connection.State) []const core_config.Model {
        return if (self.settings_model_picker == .image) state.image_models else state.decision_models;
    }
    fn dropProxyRestore(self: *Ui) void {
        if (self.proxy_restore) |*draft| {
            draft.clear();
            std.crypto.secureZero(u8, draft.bytes.allocatedSlice());
            draft.deinit();
        }
        self.proxy_restore = null;
    }
    fn anyProxyOpen(self: *const Ui) bool {
        return self.proxy_open or self.proxy_sub_open or self.proxy_address_open;
    }
    /// Only these children replace the editor; a bare submenu keeps the root draft.
    fn proxyEditorBorrowed(self: *const Ui) bool {
        return self.proxy_open or self.proxy_address_open;
    }
    /// The proxy child takes ownership of the editor and keeps the Settings-root
    /// draft aside, so returning never destroys it. The submenu stays behind it.
    fn beginProxyPicker(self: *Ui) void {
        self.dropProxyRestore();
        self.proxy_restore = self.editor;
        self.editor = .{ .allocator = self.allocator };
        self.editor_pasted = false;
        self.proxy_open = true;
        self.proxy_sub_open = true;
        self.proxy_address_open = false;
        self.settings_menu.clear();
        self.settings_menu.selected = 0;
        self.displayed_proxy_fingerprint = null;
        self.frame_proxy_fingerprint = null;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.parser.stop_feed = true;
    }
    /// Prefill is committed only after its buffer exists, so a failed open can
    /// neither leak nor drop the parent draft. The current endpoint is never
    /// rewritten by the UI; the owner publishes what it saved.
    fn beginProxyAddress(self: *Ui, state: Connection.State) !void {
        var buffer: [settings_menu_module.endpoint_buffer_bytes]u8 = undefined;
        const current = endpointText(&buffer, state);
        var next: input.Editor = .{ .allocator = self.allocator };
        errdefer next.deinit();
        try next.bytes.ensureTotalCapacity(self.allocator, current.len);
        next.bytes.appendSliceAssumeCapacity(current);
        next.cursor = current.len;
        self.dropProxyRestore();
        self.dropHistoryDraft();
        self.vertical_column = null;
        self.input_history.index = null;
        self.proxy_restore = self.editor;
        self.editor = next;
        self.editor_pasted = false;
        self.proxy_open = false;
        self.proxy_sub_open = true;
        self.proxy_address_open = true;
        self.settings_menu.clear();
        self.settings_menu.selected = 0;
        self.displayed_proxy_fingerprint = null;
        self.frame_proxy_fingerprint = null;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.parser.stop_feed = true;
        self.notice = "Address";
    }
    /// Restores the Settings-root draft owned by proxy_restore exactly once.
    fn endProxyEditor(self: *Ui) void {
        self.dropHistoryDraft();
        self.vertical_column = null;
        self.input_history.index = null;
        std.crypto.secureZero(u8, self.editor.bytes.allocatedSlice());
        self.editor.clear();
        self.editor.deinit();
        self.editor = self.proxy_restore orelse .{ .allocator = self.allocator };
        self.proxy_restore = null;
        self.editor_pasted = false;
    }
    fn closeSettingsMenu(self: *Ui) void {
        if (self.settingsModelOpen()) self.wipeEditor();
        if (self.proxyEditorBorrowed()) self.endProxyEditor();
        self.dropProxyRestore();
        self.settings_open = false;
        self.settings_model_picker = .none;
        self.proxy_open = false;
        self.proxy_sub_open = false;
        self.proxy_address_open = false;
        self.displayed_decision_fingerprint = null;
        self.frame_decision_fingerprint = null;
        self.displayed_proxy_fingerprint = null;
        self.frame_proxy_fingerprint = null;
        self.settings_value_picker = null;
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
        const parent: usize = if (self.settings_model_picker == .image) 5 else if (self.anyProxyOpen()) 7 else 1;
        if (self.settingsModelOpen()) self.wipeEditor();
        if (self.proxyEditorBorrowed()) self.endProxyEditor();
        self.displayed_decision_fingerprint = null;
        self.frame_decision_fingerprint = null;
        self.displayed_proxy_fingerprint = null;
        self.frame_proxy_fingerprint = null;
        self.settings_value_picker = null;
        self.settings_model_picker = .none;
        self.proxy_open = false;
        self.proxy_sub_open = false;
        self.proxy_address_open = false;
        self.settings_menu.clear();
        self.settings_menu.selected = parent;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.parser.stop_feed = true;
        self.notice = "Ready";
    }
    fn settingsValueTitle(key_: preference.Key) []const u8 {
        return switch (key_) {
            .compaction_enabled => "Auto compaction",
            .memory_auto => "Auto memory",
            .command_timeout_ms => "Command timeout (s)",
            .request_timeout_ms => "All inference request timeout (s; including decisions)",
        };
    }
    fn openSettingsValue(self: *Ui, key_: preference.Key, state: Connection.State) void {
        const current: ?u32 = switch (key_) {
            .compaction_enabled => @intFromBool(state.limits.compaction_enabled),
            .memory_auto => @intFromBool(state.memory_auto),
            .command_timeout_ms => state.limits.command_timeout_ms,
            .request_timeout_ms => state.limits.request_timeout_ms,
        };
        self.settings_return_selected = self.settings_menu.selected;
        self.settings_value_picker = settings_value_module.Picker.init(key_, current, state.limits);
        self.settings_menu.clear();
        self.settings_menu.selected = 0;
        for (0..self.settings_value_picker.?.count()) |index| {
            const value = self.settings_value_picker.?.chosen(index) catch continue;
            if (value == current) {
                self.settings_menu.selected = index;
                break;
            }
        }
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.parser.stop_feed = true;
        self.notice = settingsValueTitle(key_);
    }
    fn backFromSettingsValue(self: *Ui) void {
        self.settings_value_picker = null;
        self.settings_menu.clear();
        self.settings_menu.selected = self.settings_return_selected;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.parser.stop_feed = true;
        self.notice = "Ready";
    }
    fn savePreference(self: *Ui, key_: preference.Key, value: ?u32) bool {
        self.bridge.reset() catch {
            self.notice = "Settings require a drained session bridge";
            return false;
        };
        const save = self.connection.preference_fn orelse {
            self.notice = "Global settings unavailable; changes disabled";
            return false;
        };
        if (self.connection.async_actions != null) {
            _ = self.beginAsync(.{ .preference = .{ .key = key_, .value = value } }, .preference);
            return false;
        }
        save(self.connection.context, key_, value) catch {
            self.notice = "Could not save setting; previous value kept";
            return false;
        };
        self.display.context = self.connection.current().initial_context;
        self.frame_settings_generation = null;
        self.publishNotice("Settings saved");
        return true;
    }
    fn settingsValueKey(self: *Ui, event_: input.Event) !void {
        const picker = &self.settings_value_picker.?;
        if (event_ == .left or event_ == .escape or event_ == .cancel) {
            if (picker.editing) {
                picker.editing = false;
                picker.clear();
                self.settings_menu.clear();
                self.displayed_settings_generation = null;
                self.frame_settings_generation = null;
                self.parser.stop_feed = true;
                self.notice = "Ready";
            } else self.backFromSettingsValue();
            return;
        }
        switch (event_) {
            .quit => self.requestQuit(),
            .paste_start => self.settings_menu.markPaste(),
            .text => |value| {
                if (value.pasted) self.settings_menu.markPaste() else if (picker.editing) {
                    self.notice = if (picker.append(value.value)) settingsValueTitle(picker.key) else "Use positive seconds with up to three decimal places";
                    self.settings_menu.generation +%= 1;
                }
            },
            .backspace, .delete, .clear, .kill_end => if (picker.editing) {
                if (event_ == .backspace or event_ == .delete) picker.backspace() else picker.clear();
                self.settings_menu.generation +%= 1;
            },
            .up, .down => if (!picker.editing) self.settings_menu.move(event_ == .down, picker.count()),
            .enter => {
                if (!self.settingsIdle() or self.editor_pasted or self.frame.len != 0 or self.settings_menu.pasted or
                    self.displayed_settings_generation != self.settings_menu.generation) return;
                self.settings_menu.generation +%= 1;
                self.displayed_settings_generation = null;
                self.parser.stop_feed = true;
                if (!self.connection.current().global_settings_available) {
                    self.notice = "Global settings unavailable; changes disabled";
                    return;
                }
                if (picker.editing) {
                    const selected = picker.submitCustom() catch {
                        self.notice = "Invalid value; previous setting kept";
                        return;
                    };
                    self.settings_menu.clear();
                    self.settings_menu.selected = selected;
                    self.frame_settings_generation = null;
                    self.notice = "Value staged; Enter after redraw saves";
                    return;
                }
                if (picker.isCustom(self.settings_menu.selected)) {
                    picker.beginCustom();
                    self.settings_menu.clear();
                    self.frame_settings_generation = null;
                    self.notice = "Enter seconds with up to three decimal places";
                    return;
                }
                const value = picker.chosen(self.settings_menu.selected) catch {
                    self.notice = "Invalid value; previous setting kept";
                    return;
                };
                if (self.savePreference(picker.key, value)) self.backFromSettingsValue();
            },
            else => {},
        }
    }
    /// The main editor is exclusively a bounded child query while Decision is
    /// open. Revoke before allocating: an insertion OOM cannot retain old ACK.
    fn decisionQueryChanged(self: *Ui) void {
        self.settings_menu.selected = 0;
        self.settings_menu.generation +%= 1;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.displayed_decision_fingerprint = null;
        self.frame_decision_fingerprint = null;
    }
    fn proxyQueryChanged(self: *Ui) void {
        self.settings_menu.selected = 0;
        self.settings_menu.generation +%= 1;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.displayed_proxy_fingerprint = null;
        self.frame_proxy_fingerprint = null;
    }
    fn settingsQueryChanged(self: *Ui) void {
        if (self.proxy_open) self.proxyQueryChanged() else self.decisionQueryChanged();
    }
    /// Any address edit revokes the acknowledgement; only a fresh complete
    /// frame can authorize a save, even inside one read or paste batch.
    fn proxyAddressChanged(self: *Ui) void {
        self.settings_menu.generation +%= 1;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
    }
    fn addressFits(self: *const Ui, columns: usize) bool {
        return text.width("Address> ") + text.width(self.editor.bytes.items) <= columns;
    }
    /// Back from a proxy child lands on the row that owned it; the Settings
    /// root and its draft are untouched.
    fn backToProxySubmenu(self: *Ui, selected: usize) void {
        if (self.proxyEditorBorrowed()) self.endProxyEditor();
        self.proxy_open = false;
        self.proxy_address_open = false;
        self.proxy_sub_open = true;
        self.displayed_proxy_fingerprint = null;
        self.frame_proxy_fingerprint = null;
        self.settings_menu.clear();
        self.settings_menu.selected = selected;
        self.displayed_settings_generation = null;
        self.frame_settings_generation = null;
        self.parser.stop_feed = true;
        self.notice = "Ready";
    }
    fn openProxyAddress(self: *Ui) void {
        self.beginProxyAddress(self.connection.current()) catch {
            self.notice = "Out of memory; address editor not opened";
        };
    }
    /// Empty input removes the proxy through the same owner callback. The UI
    /// never mutates its own endpoint: a failed save keeps the old value.
    fn saveProxyAddress(self: *Ui, state: Connection.State) void {
        if (!state.global_settings_available) {
            self.notice = "Global settings unavailable; changes disabled";
            return;
        }
        const raw = std.mem.trim(u8, self.editor.bytes.items, " \t");
        const parsed = core_config.parseProxyEndpoint(raw) catch {
            self.notice = "Invalid proxy address; use host:port, [IPv6]:port, or empty to disable";
            return;
        };
        const save = self.connection.proxy_address_fn orelse {
            self.notice = "Global settings unavailable; changes disabled";
            return;
        };
        var buffer: [settings_menu_module.endpoint_buffer_bytes]u8 = undefined;
        const value: []const u8 = if (parsed) |endpoint| blk: {
            if (endpoint.address.len == 0 or endpoint.port == 0) {
                self.notice = "Invalid proxy address; use host:port, [IPv6]:port, or empty to disable";
                return;
            }
            if (std.mem.findScalar(u8, endpoint.address, ':') != null)
                break :blk std.fmt.bufPrint(&buffer, "[{s}]:{d}", .{ endpoint.address, endpoint.port }) catch {
                    self.notice = "Invalid proxy address; use host:port, [IPv6]:port, or empty to disable";
                    return;
                };
            break :blk std.fmt.bufPrint(&buffer, "{s}:{d}", .{ endpoint.address, endpoint.port }) catch {
                self.notice = "Invalid proxy address; use host:port, [IPv6]:port, or empty to disable";
                return;
            };
        } else "";
        self.bridge.reset() catch {
            self.notice = "Settings require a drained session bridge";
            return;
        };
        if (self.connection.async_actions != null) {
            _ = self.beginAsync(.{ .proxy_address = value }, .proxy_address);
            return;
        }
        save(self.connection.context, value) catch {
            self.notice = "Could not save setting; previous value kept";
            return;
        };
        // The owner publishes; then the submenu shows the saved endpoint.
        self.display.context = self.connection.current().initial_context;
        const disabled = parsed == null;
        self.backToProxySubmenu(0);
        self.publishNotice(if (disabled) "Empty disables proxy; a new session applies it" else "Saved proxy address; main route applies in a new session");
    }
    fn proxySubKey(self: *Ui, event_: input.Event) !void {
        switch (event_) {
            .quit => self.requestQuit(),
            .escape, .cancel, .left => self.backToSettings(),
            .up, .down => self.settings_menu.move(event_ == .down, settings_menu_module.proxy_labels.len),
            .paste_start => self.settings_menu.markPaste(),
            .enter => {
                if (!self.settingsIdle() or self.frame.len != 0 or self.settings_menu.pasted or
                    self.displayed_settings_generation != self.settings_menu.generation) return;
                // Opening a child consumes the acknowledgement.
                self.settings_menu.generation +%= 1;
                self.displayed_settings_generation = null;
                self.frame_settings_generation = null;
                self.parser.stop_feed = true;
                const state = self.connection.current();
                if (!state.global_settings_available) {
                    self.notice = "Global settings unavailable; changes disabled";
                    return;
                }
                if (self.settings_menu.selected == 0) {
                    self.openProxyAddress();
                    return;
                }
                self.beginProxyPicker();
                if (!state.proxy_configured) self.notice = "Configure a proxy address first; saving is disabled";
            },
            else => {},
        }
    }
    fn proxyAddressKey(self: *Ui, event_: input.Event) !void {
        switch (event_) {
            .quit => self.requestQuit(),
            .escape, .cancel => self.backToProxySubmenu(0),
            // Left is a cursor move while text remains; at the raw origin it
            // cancels without writing, matching the Custom value editor.
            .left => {
                if (self.editor.cursor == 0) {
                    self.backToProxySubmenu(0);
                    return;
                }
                self.proxyAddressChanged();
                self.editor.left();
            },
            .right => {
                self.proxyAddressChanged();
                self.editor.right();
            },
            .home => {
                self.proxyAddressChanged();
                self.editor.cursor = 0;
            },
            .end => {
                self.proxyAddressChanged();
                self.editor.cursor = self.editor.bytes.items.len;
            },
            .paste_start => {
                self.proxyAddressChanged();
                self.notice = "Address pasted; review it, then Enter after redraw saves";
            },
            .text => |value| {
                self.proxyAddressChanged();
                if (value.value.len > core_config.max_proxy_endpoint_bytes -| self.editor.bytes.items.len) {
                    self.notice = "Address limit: 320 bytes";
                    return;
                }
                _ = try self.editor.insert(value.value);
                if (value.pasted) self.notice = "Address pasted; review it, then Enter after redraw saves";
            },
            .backspace, .delete, .clear, .kill_end => {
                self.proxyAddressChanged();
                switch (event_) {
                    .backspace => self.editor.backspace(),
                    .delete => self.editor.delete(),
                    .clear => self.wipeEditor(),
                    .kill_end => self.editor.bytes.items.len = self.editor.cursor,
                    else => unreachable,
                }
            },
            .enter => {
                if (!self.settingsIdle() or self.editor_pasted or self.parser.batch_paste or self.frame.len != 0 or
                    self.settings_menu.pasted) return;
                // Visible state authorizes the save: text that cannot be shown
                // in full is refused with a reason instead of failing silently.
                if (self.editor.bytes.items.len > core_config.max_proxy_endpoint_bytes or !self.addressFits(self.size.columns -| 1)) {
                    self.proxyAddressChanged();
                    self.parser.stop_feed = true;
                    self.notice = "Resize: the full address must be visible to save";
                    return;
                }
                if (self.displayed_settings_generation != self.settings_menu.generation) return;
                // Consume the acknowledgement before any attempt; a repeated
                // Enter in the same read batch cannot save twice.
                self.proxyAddressChanged();
                self.parser.stop_feed = true;
                self.saveProxyAddress(self.connection.current());
            },
            else => {},
        }
    }
    /// One acknowledged Enter toggles exactly one exact model. The owner saves
    /// and republishes, so failed saves leave the checkbox and configuration
    /// unchanged. Never derive a proxy address here.
    fn toggleProxy(self: *Ui, acknowledged: ?proxy_picker_module.Fingerprint, state: Connection.State) !void {
        const previous = acknowledged orelse return;
        const current = proxy_picker_module.fingerprint(state.models, state.model_providers, state.proxy_models, state.proxy_configured, state.proxy_address, state.proxy_port) orelse return;
        if (!std.mem.eql(u8, &previous, &current)) return;
        if (!state.global_settings_available) {
            self.notice = "Global settings unavailable; changes disabled";
            return;
        }
        if (!state.proxy_configured) {
            // An acknowledged Enter reports the blocker; it is never silent.
            self.notice = "Configure a proxy address first; saving is disabled";
            return;
        }
        const name = proxy_picker_module.candidate(state.models, state.model_providers, self.editor.bytes.items, self.settings_menu.selected) orelse return;
        const save = self.connection.proxy_fn orelse {
            self.notice = "Global settings unavailable; changes disabled";
            return;
        };
        self.bridge.reset() catch {
            self.notice = "Settings require a drained session bridge";
            return;
        };
        if (self.connection.async_actions != null) {
            _ = self.beginAsync(.{ .proxy = .{ .model = name, .enabled = !proxy_picker_module.isSelected(state.proxy_models, name) } }, .proxy);
            return;
        }
        save(self.connection.context, name, !proxy_picker_module.isSelected(state.proxy_models, name)) catch {
            self.notice = "Could not save setting; previous value kept";
            return;
        };
        // The owner publishes; the UI never rewrites its own selected copy.
        self.display.context = self.connection.current().initial_context;
        self.frame_settings_generation = null;
        self.publishNotice("Saved proxy models; main route applies in a new session");
    }
    fn settingsKey(self: *Ui, event_: input.Event) !void {
        if (self.normalAsyncPending() and event_ != .escape and event_ != .cancel and event_ != .left and event_ != .quit) return;
        if (self.settings_value_picker != null) return self.settingsValueKey(event_);
        if (self.proxy_address_open) return self.proxyAddressKey(event_);
        if (self.proxy_open and (event_ == .left or event_ == .escape or event_ == .cancel)) {
            self.backToProxySubmenu(1);
            return;
        }
        // The active models picker keeps the parent marker for its breadcrumb,
        // so it must not intercept its own query, navigation or Enter.
        if (self.proxy_sub_open and !self.proxy_open) return self.proxySubKey(event_);
        if (self.settingsModelOpen() and (event_ == .left or event_ == .escape or event_ == .cancel)) {
            self.backToSettings();
            return;
        }
        switch (event_) {
            .escape, .cancel => self.closeSettingsMenu(),
            .quit => self.requestQuit(),
            .left => try self.backToCommands(.settings),
            .paste_start => self.settings_menu.markPaste(),
            .text => |value| {
                if (value.pasted) {
                    self.settings_menu.markPaste();
                } else if (self.settingsQueryOpen()) {
                    self.settingsQueryChanged();
                    if (value.value.len <= 256 -| self.editor.bytes.items.len) {
                        _ = try self.editor.insert(value.value);
                    } else self.notice = "Search limit: 256 bytes";
                }
            },
            .backspace, .delete, .clear, .kill_end => if (self.settingsQueryOpen()) {
                self.settingsQueryChanged();
                switch (event_) {
                    .backspace => self.editor.backspace(),
                    .delete => self.editor.delete(),
                    .clear => self.wipeEditor(),
                    .kill_end => self.editor.bytes.items.len = self.editor.cursor,
                    else => unreachable,
                }
            },
            .right => if (self.settingsQueryOpen()) {
                self.editor.right();
            },
            .home => if (self.settingsQueryOpen()) {
                self.editor.cursor = 0;
            },
            .end => if (self.settingsQueryOpen()) {
                self.editor.cursor = self.editor.bytes.items.len;
            },
            .up, .down => {
                const state = self.connection.current();
                const total: usize = if (self.proxy_open)
                    proxy_picker_module.count(state.models, state.model_providers, self.editor.bytes.items)
                else if (self.settingsModelOpen())
                    decision_picker_module.count(self.settingsModels(state), state.model_providers, self.editor.bytes.items)
                else
                    settings_menu_module.labels.len;
                self.settings_menu.move(event_ == .down, total);
            },
            .enter => {
                if (!self.settingsIdle() or self.editor_pasted or self.frame.len != 0 or self.settings_menu.pasted or
                    self.displayed_settings_generation != self.settings_menu.generation) return;
                // Revoke before any attempt, including failed saves. Discard the
                // read batch tail; only a new complete frame can authorize again.
                self.settings_menu.generation +%= 1;
                self.displayed_settings_generation = null;
                const acknowledged = self.displayed_decision_fingerprint;
                self.displayed_decision_fingerprint = null;
                self.frame_decision_fingerprint = null;
                const acknowledged_proxy = self.displayed_proxy_fingerprint;
                self.displayed_proxy_fingerprint = null;
                self.frame_proxy_fingerprint = null;
                self.parser.stop_feed = true;
                const state = self.connection.current();
                if (self.proxy_open) return self.toggleProxy(acknowledged_proxy, state);
                if (self.settingsModelOpen()) {
                    const previous = acknowledged orelse return;
                    const current = decision_picker_module.fingerprint(self.settingsModels(state), state.model_providers) orelse return;
                    if (!std.mem.eql(u8, &previous, &current)) return;
                }
                if (!state.global_settings_available) {
                    self.notice = "Global settings unavailable; changes disabled";
                    return;
                }
                if (!self.settingsQueryOpen() and (self.settings_menu.selected == 1 or self.settings_menu.selected == 5)) {
                    self.wipeEditor();
                    self.settings_model_picker = if (self.settings_menu.selected == 5) .image else .decision;
                    self.settings_menu.clear();
                    const selected_ref = if (self.settings_model_picker == .image)
                        (if (state.image_enabled) state.image_model else null)
                    else
                        (if (state.decision_enabled) state.decision_model else null);
                    self.settings_menu.selected = decision_picker_module.indexOf(self.settingsModels(state), state.model_providers, self.editor.bytes.items, selected_ref);
                    self.frame_settings_generation = null;
                    self.notice = "Ready";
                    return;
                }
                if (!self.settingsQueryOpen() and self.settings_menu.selected == 7) {
                    self.backToProxySubmenu(0);
                    return;
                }
                if (!self.settingsQueryOpen()) {
                    if (settings_menu_module.preferenceKey(self.settings_menu.selected)) |key_| {
                        if (key_ == .compaction_enabled) {
                            _ = self.savePreference(key_, @intFromBool(!state.limits.compaction_enabled));
                        } else if (key_ == .memory_auto) {
                            _ = self.savePreference(key_, @intFromBool(!state.memory_auto));
                        } else self.openSettingsValue(key_, state);
                        return;
                    }
                }
                self.bridge.reset() catch {
                    self.notice = "Settings require a drained session bridge";
                    return;
                };
                if (self.settingsModelOpen()) {
                    const save = (if (self.settings_model_picker == .image) self.connection.image_fn else self.connection.decision_fn) orelse {
                        self.notice = "Global settings unavailable; changes disabled";
                        return;
                    };
                    const selected = decision_picker_module.choice(self.settingsModels(state), state.model_providers, self.editor.bytes.items, self.settings_menu.selected) orelse return;
                    if (self.connection.async_actions != null) {
                        _ = self.beginAsync(if (self.settings_model_picker == .image) .{ .image = selected } else .{ .decision = selected }, if (self.settings_model_picker == .image) .image else .decision);
                        return;
                    }
                    save(self.connection.context, selected) catch {
                        self.notice = "Could not save setting; previous value kept";
                        return;
                    };
                    self.backToSettings();
                } else {
                    const save = self.connection.setting_fn orelse {
                        self.notice = "Global settings unavailable; changes disabled";
                        return;
                    };
                    if (self.connection.async_actions != null) {
                        _ = self.beginAsync(.{ .setting = .{ .key = .low_price_input, .value = !state.low_price_input_enabled } }, .setting);
                        return;
                    }
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
        self.provider_choices = provider_picker_module.choices(!configured(state) and state.provider == null);
        self.provider_picker.selected = 0;
        for (self.provider_choices.items[0..self.provider_choices.len], 0..) |choice, index| {
            if (choice == .provider and state.provider == choice.provider) self.provider_picker.selected = index;
        }
        self.provider_open = true;
        self.notice = "Ready";
    }
    fn startCodexLogin(self: *Ui) void {
        const baseline = self.connection.current().codex_login.generation;
        if (self.connection.async_actions != null) {
            // Queue admission is not the owner's acceptance: keep the panel
            // closed until the typed RPC completion arrives.
            if (self.beginAsync(.{ .codex_login = .{ .action = .start, .generation = 0 } }, .codex_login) == null) return;
            self.closeProviderPicker();
            self.codex_baseline = baseline;
            self.codex_generation = null;
            self.codex_cancel_waiting = false;
            self.codex_view_hash = 0;
            self.codex_opening = true;
            self.codex_open = false;
            self.parser.stop_feed = true;
            self.requestDraw();
            return;
        }
        // Local foreground owner only: the synchronous callback is the owner.
        self.connection.codexLogin(.start, 0) catch {
            self.notice = "OpenAI Codex device login unavailable";
            return;
        };
        self.closeProviderPicker();
        self.codex_baseline = baseline;
        self.codex_generation = null;
        self.codex_cancel_waiting = false;
        self.codex_view_hash = 0;
        self.codex_opening = false;
        self.codex_open = true;
        self.notice = "Ready";
        self.parser.stop_feed = true;
        self.observeCodexLogin();
        self.requestDraw();
    }

    fn cancelCodexLogin(self: *Ui) void {
        if (self.codex_generation) |generation| {
            if (self.connection.current().codex_login.generation != generation) {
                self.notice = "OpenAI Codex login state changed; cannot cancel";
                return;
            }
            if (self.connection.async_actions != null) {
                if (self.beginAsync(.{ .codex_login = .{ .action = .cancel, .generation = generation } }, .codex_login) == null) return;
                // Keep the panel bound to this generation until the RPC is
                // accepted; the completion closes it, not queue admission.
                self.parser.stop_feed = true;
                self.requestDraw();
                return;
            }
            self.connection.codexLogin(.cancel, generation) catch {
                self.notice = "Could not cancel OpenAI Codex login";
                return;
            };
            self.codex_open = false;
            self.codex_opening = false;
            self.codex_generation = null;
            self.notice = "Ready";
        } else {
            // The owner has accepted start but has not published its generation.
            // Defer cancellation until we can target that exact generation.
            self.codex_cancel_waiting = true;
        }
        self.parser.stop_feed = true;
        self.requestDraw();
    }

    fn observeCodexLogin(self: *Ui) void {
        if (!self.codex_open) return;
        const view = self.connection.current().codex_login;
        if (self.codex_generation == null) {
            if (view.generation == self.codex_baseline or view.status == .idle) return;
            self.codex_generation = view.generation;
        }
        if (view.generation != self.codex_generation.?) return;
        if (self.codex_cancel_waiting) {
            // Consume the deferred intent exactly once. A rejected admission is
            // not retried on every poll, which would repaint the same warning.
            self.codex_cancel_waiting = false;
            self.cancelCodexLogin();
            return;
        }
        switch (view.status) {
            .idle => return,
            .succeeded => {
                self.codex_open = false;
                self.codex_generation = null;
                self.notice = "Ready";
                self.publishNotice("OpenAI Codex connected");
                self.requestDraw();
            },
            .canceled => {
                self.codex_open = false;
                self.codex_generation = null;
                self.notice = "Ready";
                self.requestDraw();
            },
            .failed => {
                self.codex_open = false;
                self.codex_generation = null;
                self.notice = switch (view.failure orelse .other) {
                    .unavailable => "OpenAI Codex login unavailable",
                    .denied => "OpenAI Codex login denied",
                    .expired => "OpenAI Codex login expired",
                    .busy => "OpenAI Codex login busy",
                    .invalid_response => "OpenAI Codex login response invalid",
                    .storage => "OpenAI Codex login could not be saved",
                    .other => "OpenAI Codex login failed",
                };
                self.requestDraw();
            },
            .pending => {
                const code = if (validCodexCode(&view)) view.userCode() else "";
                const hash = std.hash.Wyhash.hash(view.generation, code);
                if (hash != self.codex_view_hash) {
                    self.codex_view_hash = hash;
                    self.requestDraw();
                }
            },
        }
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
                if (choice == .provider and choice.provider == .openai_codex) {
                    self.startCodexLogin();
                    return;
                }
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
        if (self.connection.async_actions != null) {
            const pending = self.beginAsync(.{ .model = name }, .model) orelse return error.Busy;
            pending.inherited = inherited;
            return error.AsyncPending;
        }
        try self.connection.selectModel(name);
        self.finishModelSelection(inherited);
    }

    fn finishModelSelection(self: *Ui, inherited: bool) void {
        const state = self.connection.current();
        self.display = .{ .context = state.initial_context, .reasoning_effort = state.reasoning_effort };
        self.effort_flash = if (state.effort_levels.contains(state.reasoning_effort))
            .{ .level = state.reasoning_effort, .until_ms = self.clock_ms +| 5000 }
        else
            null;
        self.model_flow = .{};
        self.mode = null;
        self.last_terminal = null;
        self.closeModelPicker();
        self.notice = if (inherited) "Model selected; inherited context budget" else "Model selected";
        self.requestDraw();
    }
    /// Shift+Tab is allowed while the main task runs: the owner queues the
    /// selection at the next request boundary, so the UI only lifts the
    /// task-idle requirement. Every ownership guard stays exactly as strict as
    /// before: poison, secret/paste isolation, overlays, confirmation, approval
    /// and exit authority. This is not a relaxed settingsIdle().
    fn effortAdjustable(self: *const Ui) bool {
        return !self.remoteSynchronizing() and self.permission == null and !self.poisoned and
            !self.exitAuthorized() and !self.secret_mode and !self.secret_quarantine and
            !self.parser.pasted and !self.editor_pasted and !self.parser.batch_paste and
            self.model_picker == null and !self.provider_open and !self.settings_open and
            !self.stop_open and !self.codex_open and !self.codex_opening and
            !self.commandMenuVisible();
    }

    fn cycleEffort(self: *Ui) void {
        if (!self.effortAdjustable()) {
            self.notice = "Thinking selection requires an idle, non-pasted session";
            return;
        }
        // A running task keeps its bridge, draft, body, tool rows and busy
        // state: resetting them here would interrupt the request that the new
        // selection must not touch.
        if (!self.busy) self.bridge.reset() catch {
            self.notice = "Thinking selection requires a drained session bridge";
            return;
        };
        const state = self.connection.current();
        if (self.connection.async_actions != null) {
            _ = self.beginAsync(.cycle_effort, .effort);
            return;
        }
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
            if (selected != state.reasoning_effort) self.connection.setEffort(selected) catch {
                self.notice = "Could not save thinking option; previous option kept";
                return;
            };
            break :blk selected;
        };
        if (next == state.reasoning_effort) {
            self.notice = "This model has no other supported thinking level";
            return;
        }
        self.display.setEffort(next);
        // 档位变更只在输入框百分比位置短暂确认，不再写常驻 hint 行。
        self.effort_flash = .{ .level = next, .until_ms = self.clock_ms +| 5000 };
        // While the main task runs, its own notice (pending control, warning)
        // stays untouched; the flash is the only confirmation.
        if (!self.busy) self.notice = "Ready";
        self.requestDraw();
    }
    fn expireEffortFlash(self: *Ui) void {
        if (self.effort_flash) |pending| {
            if (self.clock_ms >= pending.until_ms) {
                self.effort_flash = null;
                self.requestDraw();
            }
        }
    }
    fn modelKey(self: *Ui, event_: input.Event) !void {
        if (self.normalAsyncPending() and event_ != .escape and event_ != .cancel and event_ != .quit) return;
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
                const model_state = state;
                const choices = try picker.choicesWithProviders(self.allocator, model_state.selection_name orelse model_state.model, model_state.context_limit, model_state.models, model_state.model_disabled, model_state.model_providers);
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
                    self.selectModel(name) catch |err| {
                        if (err != error.AsyncPending) self.notice = "Could not switch; selection is unchanged";
                    };
                } else picker.move(event_ == .down, choices.len);
            },
            else => {},
        }
    }

    /// 提交当前输入并启动后台任务。忙碀或已 poisoned 时拒绝；提交不排队。
    fn submit(self: *Ui) !void {
        if (self.exitAuthorized()) return;
        if (self.blocksSubmit()) {
            self.notice = "Operation pending; input kept";
            return;
        }
        const command = std.mem.trim(u8, self.editor.bytes.items, " \t\r\n");
        // Session management resolves before steering: /ls, /cd, /attach,
        // /detach, /exit and /close work while a task is busy and never enter
        // the model, Steering or FollowUp.
        if (self.runManageText(command)) return;
        if (self.terminal_notice_pending != null) return;
        if (self.busy) return self.enqueueDraft(.steering);
        // Slash commands keep their original modal/secret and stop-feed
        // boundary. Inference/local execution alone needs the display barrier.
        if (self.idle_breaks != 0 and command.len != 0 and (command[0] != '/' or compactCommand(command))) {
            if (self.deferred_submit == null) {
                self.deferred_submit = .{ .editor = self.editor, .pasted = self.editor_pasted };
                self.editor = .{ .allocator = self.allocator };
                self.editor_pasted = false;
                self.input_history.index = null;
                self.dropHistoryDraft();
                self.requestDraw();
            }
            return;
        }
        if (std.mem.eql(u8, command, "/queue resume")) {
            if (!self.settingsIdle() or self.editor_pasted or self.parser.escape_len != 0 or self.parser.utf8_len != 0) {
                self.notice = "Queue resume requires idle, fresh input";
                return;
            }
            if (!self.queueOwnerMatches()) {
                self.notice = "Queue belongs to another session; Ctrl-C to clear explicitly";
                return;
            }
            if (self.remote()) |client| {
                if (self.connection.async_actions != null) {
                    _ = self.beginAsync(.queue_resume, .queue_resume);
                    return;
                }
                client.queueResume(self.remote_epoch) catch |err| {
                    self.notice = session_client.describe(err);
                    return;
                };
                self.wipeEditor();
                self.publishNotice("Queue resumed");
                return;
            }
            self.inbox.@"resume"();
            self.wipeEditor();
            self.publishNotice("Queue resumed");
            return;
        }
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
            if (self.connection.async_actions != null) {
                _ = self.beginAsync(.refresh_models, .refresh);
                return;
            }
            refresh(self.connection.context) catch |err| {
                self.notice = if (err == error.NoOfficialProvider) "No official provider configured; use /login first" else if (err == error.MetadataRefreshBusy) "Official metadata refresh already running" else "Could not start metadata refresh; previous cache kept";
                return;
            };
            self.notice = "Refreshing official model metadata...";
            return;
        }
        if (std.mem.eql(u8, command, "/help")) {
            self.wipeEditor();
            _ = try self.add(.notice, if (self.remote() != null)
                "/model  Select model\n/login  Configure provider\n/compact  Compact conversation\n/settings  Global settings (Low-price input, Decision model)\n/ls [--running] [--page N]  List sessions\n/resume [id]  Resume saved session\n/cd <dir>  Change launcher directory\n/attach [--takeover] <id>  Attach a session\n/detach  Leave the session view\n/close [--force] <id>  Close a session\n/exit  Leave this frontend\n!command  Run a local command without main-model inference"
            else
                "/model  Select model\n/login  Configure provider\n/compact  Compact conversation\n/settings  Global settings (Low-price input, Decision model)\n!command  Run a local command without main-model inference");
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
            } else if (self.remote()) |client| {
                _ = try self.remoteStart(client, .compact, "");
            } else if (self.connection.current().runtime) |runtime| {
                if (runtime.messages().len == 0) {
                    self.notice = "No conversation to compact yet";
                    return;
                }
                self.startCompaction(runtime) catch |err| {
                    if (err != error.QueueOwnerChanged) return err;
                    self.inbox.pause();
                    self.notice = "Queue belongs to another session; Ctrl-C to confirm clearing it";
                };
            } else {
                self.rejectUnconfigured(self.connection.current(), "Not configured: use /login first");
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
                self.selectModel(name) catch |err| {
                    if (err == error.AsyncPending) return;
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
            const codex = std.mem.eql(u8, command, "/login openai-codex");
            const idle = self.settingsIdle() and !self.editor_pasted;
            self.wipeEditor();
            if (!auth and !codex) {
                self.notice = "Unknown command; use /help, /model, /login, /compact or /settings";
            } else if (!idle) {
                self.notice = "Setup requires an idle, non-pasted session";
            } else {
                self.bridge.reset() catch {
                    self.notice = "Setup requires a drained session bridge";
                    return;
                };
                if (codex) self.startCodexLogin() else if (self.connection.configure_provider_fn != null or self.connection.codex_login_fn != null) self.openProviderPicker() else if (configured(self.connection.current())) self.notice = "Already configured; /login does not replace this session" else self.beginSecret(null);
            }
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
        if (self.remote()) |client| {
            if (try self.remoteStart(client, if (local_command) .command else .prompt, self.editor.bytes.items)) self.wipeEditor();
            return;
        }
        const runtime = state.runtime orelse {
            self.wipeEditor();
            self.rejectUnconfigured(state, if (state.model.len == 0) "Not configured: /login, then /model" else "Not configured: use /login first");
            return;
        };

        self.startPrompt(runtime, self.editor.bytes.items, if (local_command) .command else .prompt) catch |err| {
            if (err != error.QueueOwnerChanged) return err;
            self.inbox.pause();
            self.notice = "Queue belongs to another session; Ctrl-C to confirm clearing it";
            self.parser.stop_feed = true;
            return;
        };
        self.wipeEditor();
    }

    /// A rejected action is distinct from the persistent owner setup state.
    fn rejectUnconfigured(self: *Ui, state: Connection.State, fallback: []const u8) void {
        const message = setupHint(state) orelse if (state.settings_notice == null) fallback else "Session unavailable; operation not run";
        // Keep this action distinct from an identical owner advisory, including
        // one already published, so every actual rejection gets its own row.
        self.notice = if (state.settings_notice) |advisory|
            if (std.mem.eql(u8, advisory, message)) "Cannot run: session unavailable" else message
        else
            message;
        self.publishNoticeAlias(.failure);
    }

    // All fallible display/history preparation precedes worker launch. Queued
    // prompts pass explicit text and never borrow or clear the current draft.
    fn startPrompt(self: *Ui, runtime: *r.Runtime, value: []const u8, kind: @TypeOf(@as(task.Job, undefined).kind)) !void {
        if (self.displayBackpressured()) return error.DisplayBackpressured;
        if (!self.queueOwnerMatches()) return error.QueueOwnerChanged;
        try self.bridge.reset();
        self.cancel.* = .{};
        self.approval_paste_seen = false;

        const local_command = kind == .command;
        const prompt = try self.allocator.dupe(u8, value);

        // prompt 在任务启动前的错误路径中由 errdefer 释放；启动后由 self.prompt 接管。
        errdefer self.allocator.free(prompt);
        const history_entry = try self.input_history.prepare(self.allocator, prompt);
        errdefer @import("input_history.zig").History.discard(self.allocator, history_entry);

        var record = Record{ .kind = .user };
        errdefer record.deinit(self.allocator);
        try record.append(self.allocator, prompt);
        try self.reserveRecord();
        self.job = .{ .runtime = runtime, .cancel = self.cancel, .prompt = prompt, .kind = kind };
        self.attachInbox(runtime);
        errdefer self.detachInbox();
        // Ownership is announced immediately before the worker exists, so a
        // failed start releases it and never leaves the owner holding a lock.
        try self.beginTaskOwnership();
        errdefer self.endTaskOwnership();
        const future = try Io.concurrent(self.io, task.Job.run, .{&self.job});
        self.records.appendAssumeCapacity(record);
        self.registerRecord(self.records.items.len - 1) catch |err| {
            var removed = self.records.pop().?;
            removed.deinit(self.allocator);
            return err;
        };
        self.task_epoch +%= 1;
        self.input_history.commit(self.allocator, history_entry);
        self.dropHistoryDraft();
        self.future = future;
        self.prompt = prompt;
        self.busy = true;
        self.compact_composer = false;
        self.mode = if (local_command) .executing_tool else .calling_model;
        self.last_terminal = null;
        self.notice = if (local_command) "Running command" else "Running";
        if (local_command) self.parser.stop_feed = true;
        self.display.reset();
        self.clearActiveTool();
        self.clearToolCaptions();
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
        if (!self.queueOwnerMatches()) return error.QueueOwnerChanged;
        self.job = .{ .runtime = runtime, .cancel = self.cancel, .prompt = "", .kind = .compact };
        self.attachInbox(runtime);
        errdefer self.detachInbox();
        try self.beginTaskOwnership();
        errdefer self.endTaskOwnership();
        const future = try Io.concurrent(self.io, task.Job.run, .{&self.job});
        self.future = future;
        self.prompt = null;
        self.task_epoch +%= 1;
        self.busy = true;
        self.compact_composer = false;
        self.mode = .compacting;
        self.last_terminal = null;
        self.notice = "Compacting context...";
        self.display.reset();
        self.clearActiveTool();
        self.clearToolCaptions();
        self.closeCommandMenu();
    }

    /// Remote task submission. The backend owns the task, its jobs and its
    /// cancellation; the UI only publishes the accepted submission locally and
    /// adopts owner-reported activity. Returns false when nothing was accepted,
    /// in which case the draft and display are unchanged.
    fn remoteStart(self: *Ui, client: session_client.Client, kind: session_client.TaskKind, value: []const u8) !bool {
        if (kind != .compact and self.displayBackpressured()) {
            self.notice = "Display is catching up; draft kept";
            return false;
        }
        if (!self.queueOwnerMatches()) {
            self.notice = "Queue belongs to another session; Ctrl-C to clear explicitly";
            return false;
        }
        const snapshot = client.snapshot();
        if (!snapshot.available or self.remoteSnapshotSynchronizing(snapshot)) {
            self.notice = if (snapshot.attached) "Synchronizing session; draft kept" else "Session unavailable; /exit and reconnect";
            return false;
        }
        self.bridge.reset() catch {
            self.notice = "Submission requires a drained session display queue";
            return false;
        };
        self.approval_paste_seen = false;
        // Prepare display and history ownership before the backend accepts the
        // request so an accepted task cannot lose its visible user row.
        var history_entry: ?[]u8 = null;
        if (kind != .compact) history_entry = try self.input_history.prepare(self.allocator, value);
        var history_committed = false;
        defer if (!history_committed) {
            if (history_entry) |entry| @import("input_history.zig").History.discard(self.allocator, entry);
        };
        var record = Record{ .kind = .user };
        var record_moved = false;
        defer if (!record_moved) record.deinit(self.allocator);
        if (kind != .compact) try record.append(self.allocator, value);
        if (kind != .compact) try self.reserveRecord();
        if (self.connection.async_actions != null) {
            if (self.beginAsync(.{ .submit = .{ .kind = kind, .text = value } }, .submit)) |pending| {
                pending.record = record;
                pending.history_entry = history_entry;
                record_moved = true;
                history_committed = true;
            }
            return false;
        }
        client.submit(self.remote_epoch, kind, value) catch |err| {
            self.notice = session_client.describe(err);
            return false;
        };
        self.acceptRemote(kind, &record, &history_entry);
        record_moved = true;
        history_committed = true;
        return true;
    }

    fn acceptRemote(self: *Ui, kind: session_client.TaskKind, record: *Record, history_entry: *?[]u8) void {
        // Called only for an accepted receipt, with all display storage prepared
        // before queue admission. Stream delivery is held until this point.
        if (kind != .compact) {
            self.records.appendAssumeCapacity(record.*);
            record.* = .{ .kind = .user };
            if (self.registerRecord(self.records.items.len - 1)) {
                // Reservation guarantees this; never drop an accepted receipt.
            } else |_| {
                std.debug.assert(false);
            }
        }
        if (history_entry.*) |entry| {
            self.input_history.commit(self.allocator, entry);
            history_entry.* = null;
        }
        self.dropHistoryDraft();
        self.task_epoch +%= 1;
        self.remote_kind = kind;
        self.remote_observed_busy = false;
        self.remote_idle_ticks = 0;
        self.remote_terminal_wait = false;
        self.busy = true;
        self.compact_composer = false;
        self.mode = switch (kind) {
            .command => .executing_tool,
            .compact => .compacting,
            .prompt => .calling_model,
        };
        self.last_terminal = null;
        self.notice = switch (kind) {
            .command => "Running command",
            .compact => "Compacting context...",
            .prompt => "Running",
        };
        if (kind == .command) self.parser.stop_feed = true;
        self.display.reset();
        self.clearActiveTool();
        self.clearToolCaptions();
    }

    /// Return the unsent draft parked by Up browsing to the editor without
    /// allocating: bytes, cursor and paste provenance are the ones the user
    /// left behind. The moved value is cleared from `history_draft` first so
    /// `wipeEditor`'s own cleanup cannot free it twice.
    fn restoreHistoryDraft(self: *Ui) void {
        const draft = self.history_draft orelse return;
        const pasted = self.history_draft_pasted;
        self.history_draft = null;
        self.wipeEditor();
        self.editor.deinit();
        self.editor = draft;
        self.editor_pasted = pasted;
        self.history_draft_pasted = false;
        self.vertical_column = null;
    }

    fn dropHistoryDraft(self: *Ui) void {
        if (self.history_draft) |*draft| {
            draft.clear();
            std.crypto.secureZero(u8, draft.bytes.allocatedSlice());
            draft.deinit();
        }
        self.history_draft = null;
        self.history_draft_pasted = false;
    }

    fn navigateInput(self: *Ui, forward: bool) !void {
        // Only the exact raw-input origin enters history. A top visual line at
        // any other column must not discard the draft or browse history.
        if (self.editor.cursor != 0) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const cols = self.size.columns -| 1;
            const prepared = try self.prepareComposer(a, self.connection.current(), cols);
            const moved = try composer_layout.moveVertical(a, self.editor.bytes.items, self.editor.cursor, cols -| text.width(prepared.decoration.plain), forward, self.vertical_column);
            self.editor.cursor = moved.cursor;
            self.vertical_column = moved.preferred_column;
            return;
        }
        self.vertical_column = null;
        const selected = self.input_history.target(forward) orelse return;
        if (selected.index == null) {
            const saved = self.history_draft;
            const pasted = self.history_draft_pasted;
            const allocator = self.editor.allocator;
            self.history_draft = null;
            self.wipeEditor();
            self.editor.deinit();
            self.editor = saved orelse .{ .allocator = allocator };
            self.editor_pasted = pasted;
            self.history_draft_pasted = false;
            return;
        }
        // Allocate a replacement before moving either owner; OOM preserves the
        // selected entry, draft, original cursor and paste provenance.
        var replacement: input.Editor = .{ .allocator = self.editor.allocator };
        errdefer replacement.deinit();
        if (!try replacement.insert(selected.text)) return error.InputLimit;
        replacement.cursor = 0; // Repeated history keys still satisfy the rule.
        if (self.input_history.index == null) {
            self.dropHistoryDraft();
            self.history_draft = self.editor;
            self.history_draft_pasted = self.editor_pasted;
        } else {
            self.editor.clear();
            std.crypto.secureZero(u8, self.editor.bytes.allocatedSlice());
            self.editor.deinit();
        }
        self.editor = replacement;
        self.editor_revision +%= 1;
        self.input_history.index = selected.index;
        self.editor_pasted = false;
    }

    fn detachInbox(self: *Ui) void {
        if (self.attached_runtime) |runtime| runtime.inbox = null;
        self.attached_runtime = null;
    }

    fn attachInbox(self: *Ui, runtime: *r.Runtime) void {
        self.queue_owner = .{ .runtime = runtime, .session = self.connection.current().session_id };
        runtime.inbox = &self.inbox;
        self.attached_runtime = runtime;
    }

    fn queueOwnerMatches(self: *Ui) bool {
        if (self.remote()) |client| {
            // The backend owns the queue; a takeover must have replaced this
            // frontend before any new send is accepted.
            return client.snapshot().control_epoch == self.remote_epoch;
        }
        const snapshot = self.inbox.snapshot();
        if (snapshot.steering + snapshot.follow_up == 0 and !snapshot.active) return true;
        const owner = self.queue_owner orelse return false;
        const state = self.connection.current();
        return state.runtime == owner.runtime and std.meta.eql(state.session_id, owner.session);
    }

    fn enqueueDraft(self: *Ui, kind: inbox_module.Kind) !void {
        const value = std.mem.trim(u8, self.editor.bytes.items, " \t\r\n");
        if (value.len == 0) return;
        if (value[0] == '/' or value[0] == '!') {
            self.notice = "Only ordinary conversation text can be queued";
            self.publishNoticeAlias(.warning);
            return;
        }
        if (self.poisoned or self.stop_open or !self.queueOwnerMatches()) {
            self.notice = "Queue unavailable for this task/session";
            return;
        }
        if (kind == .steering and !self.promptKind()) {
            self.notice = "Local commands/compaction accept Alt-Enter FollowUp only";
            return;
        }
        if (self.remote()) |client| {
            // Delivery, pause and terminal state stay owned by the backend; a
            // failed enqueue keeps the draft so the user can retry.
            if (self.connection.async_actions != null) {
                _ = self.beginAsync(.{ .enqueue = .{ .kind = kind, .text = self.editor.bytes.items } }, .enqueue);
                return;
            }
            client.enqueue(self.remote_epoch, kind, self.editor.bytes.items) catch |err| {
                self.notice = session_client.describe(err);
                return;
            };
            self.wipeEditor();
            self.parser.stop_feed = true;
            self.publishNotice(if (kind == .steering) "Steering pending" else "FollowUp pending");
            return;
        }
        if (self.attached_runtime == null) {
            self.notice = "Queue unavailable for this task/session";
            return;
        }
        _ = self.inbox.enqueue(self.allocator, kind, self.editor.bytes.items) catch {
            self.notice = "Could not queue message; draft kept (queue/input limit)";
            return;
        };
        self.wipeEditor();
        self.parser.stop_feed = true;
        self.publishNotice(if (kind == .steering) "Steering pending" else "FollowUp pending");
    }

    fn dispatchNext(self: *Ui) !void {
        // The backend dispatches its own queue; the UI never launches a remote job.
        if (self.remote() != null) return;
        if (self.terminal_notice_pending != null or self.busy or self.future != null or self.exitAuthorized() or self.poisoned or self.stop_open or
            self.secret_mode or self.secret_quarantine or self.settings_open or self.provider_open or self.model_picker != null) return;
        // finishRun's sticky pause is authoritative, including explicit resume.
        if (!self.queueOwnerMatches()) {
            self.inbox.pause();
            return;
        }
        const lease = self.inbox.claimNext() orelse return;
        const runtime = self.connection.current().runtime orelse {
            self.inbox.restore(lease);
            self.inbox.pause();
            return;
        };
        self.startPrompt(runtime, lease.text, .prompt) catch {
            self.inbox.restore(lease);
            self.inbox.pause();
            self.notice = "Queued launch failed; message kept; /queue resume retries";
            self.requestDraw();
            return;
        };
        if (self.inbox.commit(lease)) |value| {
            var entry = value;
            entry.deinit();
        }
        self.requestDraw();
    }

    fn stopIdentity(self: *Ui) StopIdentity {
        const state = self.connection.current();
        return .{ .runtime = state.runtime, .session = state.session_id, .task_epoch = self.task_epoch, .revision = self.queueSnapshot().revision, .busy = self.busy, .remote_epoch = self.remote_epoch };
    }

    fn invalidateStop(self: *Ui) void {
        self.stop_generation +%= 1;
        self.displayed_stop = null;
        self.frame_stop = null;
        self.requestDraw();
    }

    fn refreshStop(self: *Ui) void {
        const revision = self.queueSnapshot().revision;
        if (self.queue_revision != revision) {
            self.queue_revision = revision;
            self.requestDraw();
        }
        if (!self.stop_open) return;
        const identity = self.stopIdentity();
        if (self.remote() != null) {
            if (self.stop_identity) |old| {
                if (old.remote_epoch != identity.remote_epoch or !std.meta.eql(old.session, identity.session)) {
                    // The owner behind this modal was replaced. Close against the
                    // old identity (its epoch no longer matches, so no release is
                    // sent) instead of rebinding Esc to the new session.
                    self.closeStop();
                    return;
                }
            }
        }
        if (!std.meta.eql(self.stop_identity, @as(?StopIdentity, identity))) {
            self.stop_identity = identity;
            self.stop_danger = false;
            self.invalidateStop();
        }
    }

    fn closeStop(self: *Ui) void {
        // Release only the owner this modal was opened against. A takeover or
        // session switch since then owns a different barrier and must not be
        // unbound by a late close; busy/revision changes never block release.
        const was_open = self.stop_open;
        const identity = self.stop_identity;
        if (self.remote()) |client| {
            if (was_open and identity != null) {
                const current = client.snapshot();
                if (identity.?.remote_epoch == current.control_epoch and std.meta.eql(identity.?.session, current.session_id)) {
                    if (self.connection.async_actions != null) {
                        _ = self.beginAsync(.{ .confirming = false }, .release_stop);
                    } else client.setConfirming(identity.?.remote_epoch, false) catch {
                        // The modal is already gone, so stop gating on it; the
                        // owner clears the barrier on detach/EOF instead.
                        self.notice = "Stop dismissed; remote confirmation barrier not released until disconnect";
                    };
                }
            }
        } else self.inbox.pauseClaims(false);
        self.stop_open = false;
        self.stop_instance +%= 1;
        self.stop_danger = false;
        self.stop_identity = null;
        if (self.stop_close) |id| {
            self.allocator.free(id);
            self.stop_close = null;
        }
        self.invalidateStop();
        self.parser.stop_feed = true;
    }

    fn stopKey(self: *Ui, event_: input.Event) void {
        self.refreshStop();
        if (!self.stop_open) return;
        switch (event_) {
            .quit => self.requestQuit(),
            .escape => self.closeStop(),
            .left, .right, .up, .down, .tab => {
                self.stop_danger = switch (event_) {
                    .right, .down => true,
                    .left, .up => false,
                    else => !self.stop_danger,
                };
                self.invalidateStop();
                self.parser.stop_feed = true;
            },
            .enter => {
                if (self.displayed_stop != self.stop_generation or self.parser.pasted or
                    self.parser.utf8_len != 0 or self.parser.escape_len != 0)
                {
                    // A held Enter started before ACK cannot become a later
                    // dangerous authorization merely because output caught up.
                    self.stop_danger = false;
                    self.invalidateStop();
                    self.parser.stop_feed = true;
                    return;
                }
                if (!self.stop_danger) return self.closeStop();
                const identity = self.stop_identity orelse return;
                if (!std.meta.eql(identity, self.stopIdentity())) {
                    self.refreshStop();
                    return;
                }
                if (self.stop_close != null) {
                    // Explicit confirmation for closing a busy session; the
                    // backend performs cancel/join/save and releases ownership.
                    self.confirmClose();
                    return;
                }
                if (self.remote()) |client| {
                    if (self.connection.async_actions != null) {
                        _ = self.beginAsync(.{ .cancel_clear = identity.revision }, .cancel_clear);
                        self.displayed_stop = null;
                        return;
                    }
                    client.cancelClear(self.remote_epoch, identity.revision) catch |err| {
                        self.notice = session_client.describe(err);
                        self.closeStop();
                        return;
                    };
                } else if (!self.inbox.cancelClear(identity.revision, self.cancel)) {
                    self.refreshStop();
                    return;
                }
                self.clearPermission();
                // The owner clears its own barrier on a successful cancel/clear.
                self.stop_open = false;
                self.stop_identity = null;
                self.invalidateStop();
                self.parser.stop_feed = true;
                self.notice = "Stop requested; queue cleared; draft kept";
            },
            .paste_start => {
                self.stop_danger = false;
                self.invalidateStop();
                // Consume the paste through its terminator; batch_paste keeps
                // its tail quarantined without stranding Parser.pasted=true.
            },
            .cancel => {
                self.stop_danger = false;
                self.invalidateStop();
                self.parser.stop_feed = true;
            },
            else => {},
        }
    }

    fn openStop(self: *Ui) void {
        const snapshot = self.queueSnapshot();
        if (!self.busy and snapshot.steering + snapshot.follow_up == 0) return;
        if (self.remote()) |client| {
            // The owner gates new launches behind its own confirming flag and
            // adopts a fresh snapshot on success, so request the barrier before
            // the modal claims anything and authorize against the adopted queue
            // revision. A rejected request must never open a fake-safe modal.
            if (self.connection.async_actions != null) {
                _ = self.beginAsync(.{ .confirming = true }, .open_stop);
                return;
            }
            client.setConfirming(self.remote_epoch, true) catch |err| {
                self.notice = session_client.describe(err);
                self.requestDraw();
                self.parser.stop_feed = true;
                return;
            };
        } else self.inbox.pauseClaims(true);
        self.activateStop();
    }

    /// Busy /close confirmation accepted: cancel, join, save and release via
    /// the backend. Teardown of the local modal stays local.
    fn confirmClose(self: *Ui) void {
        const id = self.stop_close orelse return;
        const client = self.remote() orelse {
            self.closeStop();
            return;
        };
        self.applyManage(client, .{ .close = .{ .id = id, .force = true } });
        self.closeStop();
    }

    fn escapeQueue(self: *Ui) !void {
        self.parser.stop_feed = true;
        if (self.editor.bytes.items.len != 0) {
            self.notice = "Draft kept; clear it before withdrawing a pending message";
            return;
        }
        if (self.withdrawn_draft) |bytes| {
            self.withdrawn_draft = null;
            self.adoptWithdrawn(bytes);
            return;
        }
        const snapshot = self.queueSnapshot();
        if (snapshot.newest_id) |id| {
            if (self.remote()) |client| {
                if (self.connection.async_actions != null) {
                    _ = self.beginAsync(.{ .withdraw = id }, .withdraw);
                    return;
                }
                const withdrawn = client.withdraw(self.allocator, self.remote_epoch, id) catch |err| {
                    self.notice = session_client.describe(err);
                    return;
                };
                const draft = withdrawn orelse {
                    self.notice = "Message already consumed; nothing withdrawn";
                    return;
                };
                defer self.allocator.free(draft);
                if (!(try self.editor.insert(draft))) {
                    self.notice = "Could not withdraw into the draft; pending message kept";
                    return;
                }
                self.editor_pasted = false;
                self.input_history.index = null;
                self.publishNotice("Pending message withdrawn as plain draft");
                return;
            }
            self.editor.bytes.ensureTotalCapacity(self.editor.allocator, snapshot.newest_bytes) catch {
                self.notice = "Could not prepare editor; pending message kept";
                return;
            };
            if (self.inbox.withdraw(id)) |value| {
                var entry = value;
                defer entry.deinit();
                self.editor.bytes.appendSliceAssumeCapacity(entry.text);
                self.editor.cursor = entry.text.len;
                self.editor_pasted = false;
                self.input_history.index = null;
                self.publishNotice("Pending message withdrawn as plain draft");
            } else self.notice = "Message already consumed; nothing withdrawn";
            return;
        }
        if (self.busy) self.requestCancel();
    }

    fn requestCancel(self: *Ui) void {
        if (self.remote()) |client| {
            // Only the current task is canceled; the attached session, its
            // queue ownership and this connection stay alive.
            if (self.connection.async_actions != null) {
                _ = self.beginAsync(.cancel, .cancel);
                return;
            }
            client.cancel(self.remote_epoch) catch |err| {
                self.notice = session_client.describe(err);
                return;
            };
            self.notice = "Cancellation requested; cleaning up, not rolling back effects";
            self.clearPermission();
            self.parser.stop_feed = true;
            return;
        }
        self.inbox.pause();
        self.cancel.cancel();
        self.notice = "Cancellation requested; cleaning up, not rolling back effects";
        self.clearPermission();
    }

    fn wipeEditor(self: *Ui) void {
        self.editor_revision +%= 1;
        self.dropHistoryDraft();
        self.vertical_column = null;
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
        if (self.hasAsync(.configure) and event_ != .escape and event_ != .cancel and event_ != .quit) return;
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
                if (self.connection.async_actions != null) {
                    if (self.beginAsync(.{ .configure = .{ .provider = self.secret_provider, .key = key_bytes } }, .configure) != null) self.secret.wipe();
                    return;
                }
                const saved = if (self.secret_provider) |id| self.connection.configureProvider(id, key_bytes) else self.connection.configure(key_bytes);
                saved catch {
                    self.endSecret();
                    self.notice = "Could not save configuration; use /login to retry";
                    self.publishNoticeAlias(self.asyncFailureLevel(.configure));
                    return;
                };
                self.endSecret();
                // A fresh Enter authorizes the completed paste, not its read tail.
                // endSecret still wipes parser scratch and sets stop_feed.
                self.secret_quarantine = false;
                self.wipeEditor();
                self.display.context = self.connection.current().initial_context;
                self.publishNotice(if (named) "Key saved locally; use /model to select or activate it" else "Saved locally; send a message to connect");
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

    fn selectPermission(self: *Ui, choice: ApprovalChoice) void {
        const permission = if (self.permission) |*value| value else return;
        const selected: ApprovalChoice = if ((permission.clipped or permission.pasted) and choice == .allow_once) .deny else choice;
        if (permission.choice == selected) return;
        permission.choice = selected;
        // Selection is authority-bearing UI. Never let an ACK for the previous
        // choice authorize Enter after a rapid arrow or a partial frame.
        self.displayed_permission = null;
        self.displayed_permission_choice = null;
        self.requestDraw();
    }

    fn decidePermission(self: *Ui, decision: r.Decision, require_choice_ack: bool) void {
        const permission = self.permission orelse return;
        if (require_choice_ack and (self.displayed_permission != permission.id or self.displayed_permission_choice != permission.choice)) return;
        if (decision != .deny and ((permission.clipped or permission.pasted) or !self.approvalFits(permission.id, .allow_once))) {
            self.notice = if (permission.pasted) "Paste detected: deny this request and ask again" else "Preview unavailable: deny and request a smaller operation";
            return;
        }
        if (self.remote()) |client| {
            if (decision != .deny and !client.snapshot().available) {
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
                self.notice = "Session display is resynchronizing; approval not sent";
                return;
            }
            // The decision is bound to the epoch that displayed the request; the
            // backend rejects approvals from a replaced controller.
            if (self.connection.async_actions != null) {
                _ = self.beginAsync(.{ .approve = .{ .id = permission.id, .decision = decision } }, .approve);
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
                return;
            }
            client.approve(permission.epoch, permission.id, decision) catch |err| {
                self.notice = session_client.describe(err);
                self.clearPermission();
                self.parser.stop_feed = true;
                return;
            };
            self.settlePermissionDelivery(permission.id, permission.epoch);
            self.publishNotice(if (decision == .deny) "Request denied" else "Allowed once");
        } else if (self.bridge.decide(permission.id, decision)) {
            self.settlePermissionDelivery(permission.id, permission.epoch);
            self.publishNotice(if (decision == .deny) "Request denied" else "Allowed once");
        } else self.notice = "Permission expired";
        self.clearPermission();
        self.parser.stop_feed = true;
    }

    /// Modal approval selector. It never writes bytes into the ordinary
    /// composer: arrows choose, Enter confirms, and Escape safely denies.
    fn permissionKey(self: *Ui, event_: input.Event) void {
        switch (event_) {
            .paste_start => {
                self.blockPastedApproval();
                self.selectPermission(.deny);
            },
            .text => |value| {
                if (value.pasted) self.blockPastedApproval();
                self.selectPermission(.deny);
                self.notice = "Approval is modal: use arrows and Enter; Esc denies";
            },
            .left, .up => self.selectPermission(.allow_once),
            .right, .down => self.selectPermission(.deny),
            .tab => self.selectPermission(if (self.permission.?.choice == .deny) .allow_once else .deny),
            .enter => self.decidePermission(if (self.permission.?.choice == .allow_once) .allow_once else .deny, true),
            .escape => self.decidePermission(.deny, false),
            // Two is the compact preview's minimum visible page after its hint;
            // conservative overlap prevents skipping lines.
            .page_up => {
                self.permission_scroll -|= @max(1, @min(2, self.size.rows -| 7));
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
                self.frame_permission = null;
                self.frame_permission_choice = null;
            },
            .page_down => {
                self.permission_scroll +|= @max(1, @min(2, self.size.rows -| 7));
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
                self.frame_permission = null;
                self.frame_permission_choice = null;
            },
            .home => {
                self.permission_scroll = 0;
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
                self.frame_permission = null;
                self.frame_permission_choice = null;
            },
            .end => {
                self.permission_scroll = std.math.maxInt(usize);
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
                self.frame_permission = null;
                self.frame_permission_choice = null;
            },
            .quit => self.requestQuit(),
            else => {},
        }
    }

    /// 键盘事件回调（由 input.Parser 调用）。审批可见时优先处理审批按键；粘贴内容永远不能用于批准。
    fn key(ctx: *anyopaque, event_: input.Event) !void {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        if (self.exitAuthorized()) return;
        // Keyboard input must reach the next fresh draw without waiting for the
        // ordinary cadence; it still never interrupts an already-started frame.
        self.urgent_draw = true;
        self.requestDraw();
        if (event_ == .escape and self.hasAsync(.open_stop) and !self.stop_open) {
            _ = self.beginAsync(.{ .confirming = false }, .release_stop);
            return;
        }
        if (event_ != .up and event_ != .down) self.vertical_column = null;
        if ((event_ == .enter or event_ == .follow_up) and (self.parser.pasted or self.parser.batch_paste)) return;
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

        if (self.codex_open or self.codex_opening) {
            if (event_ == .quit) self.requestQuit() else if (event_ == .escape and !self.parser.pasted and !self.parser.batch_paste) self.cancelCodexLogin();
            return;
        }
        if (self.stop_open) {
            if (self.parser.batch_paste and event_ != .quit and event_ != .paste_start) return;
            self.stopKey(event_);
            return;
        }
        if (event_ == .escape and self.resume_pending != null and self.permission == null and !self.parser.pasted and !self.parser.batch_paste) {
            self.clearResumePending();
            self.parser.stop_feed = true;
            self.notice = "Ready";
            return;
        }
        if (self.resume_picker != null and self.permission == null and !self.stop_open) return self.resumeKey(event_);
        if (event_ == .cancel and (self.busy or self.queueSnapshot().newest_id != null)) {
            self.openStop();
            return;
        }
        if (self.permission != null) {
            self.permissionKey(event_);
            return;
        }
        if (event_ == .escape and (self.busy or self.queueSnapshot().newest_id != null)) {
            try self.escapeQueue();
            return;
        }
        if (self.settings_open and self.permission == null) return self.settingsKey(event_);
        if (self.provider_open and self.permission == null) return self.providerKey(event_);
        if (self.model_picker != null and self.permission == null) return self.modelKey(event_);
        switch (event_) {
            .text, .tab, .backspace, .delete, .clear, .kill_end => self.editor_revision +%= 1,
            else => {},
        }
        switch (event_) {
            .backspace, .delete, .clear, .kill_end => {
                self.input_history.index = null;
                self.dropHistoryDraft();
            },
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
                    self.requestDraw();
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
                if (try self.editor.insert(v.value)) {
                    self.input_history.index = null;
                    self.dropHistoryDraft();
                    self.editor_pasted = self.editor_pasted or v.pasted;
                } else self.notice = "Input limit: 64 KiB";
            },
            .tab => {
                if (try self.editor.insert("    ")) {
                    self.input_history.index = null;
                    self.dropHistoryDraft();
                } else self.notice = "Input limit: 64 KiB";
                self.command_menu.changed();
            },
            .enter => {
                if (self.idleEnter()) {
                    // Saturation bounds memory/work even with an unresponsive TTY.
                    self.idle_breaks +|= 1;
                    self.wipeEditor();
                } else try self.submit();
            },
            .follow_up => {
                if (self.busy) try self.enqueueDraft(.follow_up) else try self.submit();
            },
            // Active tasks/queues were handled above; idle modal handlers get
            // first refusal. Ordinary idle Ctrl-C must not erase the composer.
            .cancel => {},
            // 退出：若任务仍在运行则先取消，等 loop 中 complete 完成后才真正退出。
            .quit => self.requestQuit(),
            .toggle_reasoning => self.show_reasoning = !self.show_reasoning,
            .cycle_effort => self.cycleEffort(),
            .escape => {},
            .up, .down => try self.navigateInput(event_ == .down),
            // Native scrollback owns completed conversation rows; no program
            // key injection and no full-history repaint from PageUp/PageDown.
            .page_up, .page_down => {},
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
        const before = self.connection.current();
        const poll = self.connection.poll_models_fn orelse return;
        const changed = poll(self.connection.context, self.settingsIdle());
        const state = self.connection.current();
        if (!changed) return;
        if (before.pending_default_effort != null and state.pending_default_effort == null and
            state.effort_levels.contains(state.reasoning_effort))
            self.effort_flash = .{ .level = state.reasoning_effort, .until_ms = self.clock_ms +| 5000 };
        if (self.model_picker) |*picker| picker.changed();
        self.displayed_model_generation = null;
        if (state.metadata_notice) |notice| {
            const same = if (before.metadata_notice) |previous| std.mem.eql(u8, previous, notice) else false;
            if (!same) {
                // Both producer-classified success and failure are one-shot
                // transcript notices, with failure at warning severity.
                if (state.metadata_notice_ttl_ms != 0) self.publishNotice(notice) else {
                    self.notice = notice;
                    self.publishNoticeAlias(.warning);
                }
            }
        }
        self.requestDraw();
    }

    /// The only displayed wording for a delivered terminal result. Shared so a
    /// late cancel receipt or an ordered idle release can restore it verbatim.
    fn terminalNotice(result: r.Terminal) []const u8 {
        return switch (result.status) {
            .success => "Ready",
            .canceled => "Canceled; prior side effects remain",
            .paused => if (result.model_failure == .output_limit or r.policyPause(result.detail)) "Paused" else "Paused at round limit; send a message to continue",
            .failed => "Failed",
        };
    }

    /// Append a severity-typed conversation notice without touching the
    /// foreground `notice` field. Publication failure inserts no record and
    /// leaves every caller-owned receipt unchanged.
    fn appendNotice(self: *Ui, level: NoticeLevel, message: []const u8) !void {
        const index = try self.addRecord(.notice, message, false);
        self.records.items[index].notice_level = level;
    }

    /// Memory terminal wording. Skipped is deliberately silent; failed and
    /// uncertain are warnings unless cleanup safety is at stake. The saved
    /// confirmation is a compact one-row summary, never a count. A failed or
    /// uncertain result that still saved some entries keeps that fact and its
    /// original severity instead of pretending to be a success.
    fn formatMemoryTerminal(terminal: memory_status.Terminal, buffer: []u8) ?struct { level: NoticeLevel, text: []const u8 } {
        if (terminal.result == .skipped) return null;
        const label: []const u8 = switch (terminal.result) {
            .saved => "M: \u{2713}",
            .failed => "M: failed",
            .uncertain => "M: uncertain",
            .canceled => "M: canceled",
            .skipped => return null,
        };
        const level: NoticeLevel = switch (terminal.result) {
            .saved, .canceled => .plain,
            .failed, .uncertain => if (terminal.failure != null and terminal.failure.? == .cleanup) .failure else .warning,
            .skipped => unreachable,
        };
        const summary = terminal.summary.text();
        const value_text = if (terminal.result == .saved)
            if (summary.len == 0)
                label
            else
                std.fmt.bufPrint(buffer, "{s} {s}", .{ label, summary }) catch return null
        else if (terminal.saved_count != 0 and summary.len != 0)
            std.fmt.bufPrint(buffer, "{s}; saved ({d}) - {s}", .{ label, terminal.saved_count, summary }) catch return null
        else if (terminal.saved_count != 0)
            std.fmt.bufPrint(buffer, "{s}; saved ({d})", .{ label, terminal.saved_count }) catch return null
        else
            label;
        return .{ .level = level, .text = value_text };
    }

    fn appendMemoryCompletion(self: *Ui, terminal: memory_status.Terminal) !void {
        var buffer: [640]u8 = undefined;
        const formatted = formatMemoryTerminal(terminal, &buffer) orelse return;
        const index = try self.addRecord(.notice, formatted.text, false);
        self.records.items[index].notice_level = formatted.level;
        // Only the saved confirmation is guaranteed one physical row. Failure,
        // uncertainty and cancellation keep the ordinary paragraph rendering so
        // nothing real becomes invisible on a narrow screen.
        self.records.items[index].single_row = terminal.result == .saved;
    }

    /// Remote delivery is fallible on purpose: the caller keeps the source
    /// sequence unacknowledged when the row was not really appended.
    fn acceptMemoryCompletion(self: *Ui, terminal: memory_status.Terminal) !void {
        try self.appendMemoryCompletion(terminal);
    }

    /// Background terminal rows are UI-only. Keep the result and failure
    /// classification ahead of the potentially long command when clipped.
    fn appendBackgroundCompletion(self: *Ui, terminal: background_status.Terminal) !void {
        var buffer: [768]u8 = undefined;
        var detail_buffer: [96]u8 = undefined;
        const status = if (terminal.result == .canceled) "canceled" else "failed";
        const detail = if (terminal.result == .success)
            "✓"
        else if (terminal.exit_code) |code|
            if (terminal.failure) |failure|
                try std.fmt.bufPrint(&detail_buffer, "{s} ({s}, exit {d})", .{ status, @tagName(failure), code })
            else
                try std.fmt.bufPrint(&detail_buffer, "{s} (exit {d})", .{ status, code })
        else if (terminal.signal) |signal|
            if (terminal.failure) |failure|
                try std.fmt.bufPrint(&detail_buffer, "{s} ({s}, signal {d})", .{ status, @tagName(failure), signal })
            else
                try std.fmt.bufPrint(&detail_buffer, "{s} (signal {d})", .{ status, signal })
        else if (terminal.failure) |failure|
            try std.fmt.bufPrint(&detail_buffer, "{s} ({s})", .{ status, @tagName(failure) })
        else
            status;
        const command = terminal.command.slice();
        const message = if (std.mem.eql(u8, command, "[command hidden]"))
            try std.fmt.bufPrint(&buffer, "B: {s} {s} {s} · {d}ms", .{ detail, terminal.id.slice(), command, terminal.duration_ms })
        else
            try std.fmt.bufPrint(&buffer, "B: {s} {s} · {d}ms", .{ detail, command, terminal.duration_ms });
        const index = try self.addRecord(.notice, message, false);
        self.records.items[index].notice_level = if (terminal.result == .success) .plain else if (terminal.result == .canceled and terminal.failure != .cleanup) .warning else .failure;
        self.records.items[index].single_row = true;
    }

    /// Peek is non-consuming: admission must succeed before the exact source
    /// id is retired. Remote completions arrive only through the live stream.
    fn pollBackgroundCompletion(self: *Ui) void {
        if (!self.memorySafePoint() or self.remote() != null or self.connection.take_background_fn == null) return;
        var batch: usize = 0;
        while (batch < 8) : (batch += 1) {
            const terminal = self.connection.peekBackground() orelse return;
            self.appendBackgroundCompletion(terminal) catch return;
            self.connection.takeBackground(terminal.id);
            self.requestDraw();
        }
    }

    /// Local foreground ownership handoff, strictly paired. A remote backend
    /// already owns its task, so this view never announces a second one.
    fn beginTaskOwnership(self: *Ui) !void {
        if (self.task_owned or self.remote() != null) return;
        const begin = self.connection.task_begin_fn orelse return;
        try begin(self.connection.context);
        self.task_owned = true;
    }

    /// Release exactly the ownership a successful begin established. A failed
    /// begin leaves no release to send, and the caller's input stays untouched.
    fn endTaskOwnership(self: *Ui) void {
        if (!self.task_owned) return;
        self.task_owned = false;
        const joined = self.connection.task_joined_fn orelse return;
        joined(self.connection.context);
    }

    /// Memory completion is appended only at the idle point the host proxy
    /// guarantees (after a task was reaped, before the next dispatch). The
    /// body stream and its delivery order are never interrupted, and no UI
    /// FIFO of pending results is built.
    fn memorySafePoint(self: *const Ui) bool {
        return !self.busy and self.future == null and self.draft == null and self.reasoning == null;
    }

    /// Local foreground delivery is a source-queue pop, so repeated polls with
    /// no value are naturally silent. Failed UI publication keeps the exact
    /// value in fixed retry slots and stops taking more values until it lands.
    fn pollMemoryCompletion(self: *Ui) void {
        if (!self.memorySafePoint()) return;
        if (self.memory_completion_pending) |terminal| {
            self.appendMemoryCompletion(terminal) catch return;
            self.memory_completion_pending = null;
            self.requestDraw();
        }
        if (self.remote() != null) return;
        const callback = self.connection.take_memory_completion_fn orelse return;
        var batch: usize = 0;
        while (batch < 8) : (batch += 1) {
            const terminal = (callback(self.connection.context)) orelse return;
            self.appendMemoryCompletion(terminal) catch {
                self.memory_completion_pending = terminal;
                return;
            };
            self.requestDraw();
        }
    }

    /// A persistent capability warning stays in the neutral footer; every
    /// other owner-published settings notice is a one-shot conversation result.
    fn capabilityPendingNotice(value: []const u8) bool {
        return std.mem.startsWith(u8, value, "Saved thinking level not applied");
    }

    /// Publish foreground terminal details once for this delivered terminal.
    /// A failed task or an error pause stops the current main task, so it is
    /// red; an explicit user cancellation remains plain.
    fn publishTerminalNotice(self: *Ui, result: r.Terminal) bool {
        if (result.status == .success) return true;
        // Ordinary round-limit pauses already have user-facing wording; do not
        // expose their internal error name. Policy and output pauses keep detail.
        if (result.status == .paused and result.model_failure != .output_limit and !r.policyPause(result.detail))
            return self.tryAppendNotice(.failure, terminalNotice(result));
        var formatted: std.Io.Writer.Allocating = .init(self.allocator);
        defer formatted.deinit();
        const writer = &formatted.writer;
        const label = switch (result.status) {
            .paused => "Paused",
            .failed => "Failed",
            .canceled => "Canceled; prior side effects remain",
            .success => unreachable,
        };
        if (result.status == .canceled and result.detail != null and result.detail.? == error.Canceled)
            writer.writeAll(label) catch return false
        else if (result.detail != null and result.detail.? == error.DecisionUnavailable)
            shared.failure.writeDecision(writer, result.decision_failure) catch return false
        else
            shared.failure.write(writer, label, result.detail, result.model_failure, result.http_status) catch return false;
        const level: NoticeLevel = if (result.status == .canceled) .plain else .failure;
        return self.tryAppendNotice(level, formatted.written());
    }

    fn queueTerminalNotice(self: *Ui, result: r.Terminal) void {
        if (self.terminal_notice_pending) |pending| {
            if (!self.publishTerminalNotice(pending)) return;
            self.terminal_notice_pending = null;
            self.terminal_alias = terminalNotice(pending);
        }
        if (!self.publishTerminalNotice(result)) {
            self.terminal_notice_pending = result;
            return;
        }
        self.terminal_alias = terminalNotice(result);
    }

    fn retryTerminalNotice(self: *Ui) void {
        if (!self.memorySafePoint()) return;
        const pending = self.terminal_notice_pending orelse return;
        if (!self.publishTerminalNotice(pending)) return;
        self.terminal_notice_pending = null;
        self.terminal_alias = terminalNotice(pending);
    }

    /// Publish the current one-shot `notice` exactly once and remember its
    /// exact text so the footer does not repeat it. The notice field itself is
    /// preserved for existing callers and assertions.
    fn publishNoticeAlias(self: *Ui, level: NoticeLevel) void {
        self.syncNoticeAlias();
        const message = self.notice;
        if (message.len == 0 or std.mem.eql(u8, message, "Ready") or
            std.mem.eql(u8, message, "Running") or std.mem.eql(u8, message, "Completed")) return;
        const hash = std.hash.Wyhash.hash(0, message);
        const restored = std.mem.eql(u8, message, session_client.restored_notice);
        const state = self.connection.current();
        const same_settings = if (state.settings_notice) |notice| std.mem.eql(u8, notice, message) else false;
        if ((restored and self.history_notice_shown) or
            (same_settings and self.settings_notice_seen != null and self.settings_notice_seen.? == hash))
        {
            self.notice_alias_hash = hash;
            self.notice_alias_pending = null;
            return;
        }
        self.notice_alias_hash = null;
        if (self.tryAppendNotice(if (restored) .plain else level, message)) {
            self.notice_alias_pending = null;
            self.notice_alias_hash = hash;
            if (restored) self.history_notice_shown = true;
            if (same_settings and !capabilityPendingNotice(message)) self.settings_notice_seen = hash;
        } else self.notice_alias_pending = .{ .hash = hash, .level = level };
    }

    fn tryAppendNotice(self: *Ui, level: NoticeLevel, message: []const u8) bool {
        self.appendNotice(level, message) catch return false;
        return true;
    }

    /// Actual-state advisory migrations, independent of draw/poll repetition.
    /// A fault is reported once per real state value; clearing it (including a
    /// session switch) makes a later recurrence report again.
    fn observeAdvisories(self: *Ui) void {
        const state = self.connection.current();
        if (state.settings_error) |err| {
            const changed = self.settings_error_seen == null or self.settings_error_seen.? != err;
            if (changed) {
                var buffer: [96]u8 = undefined;
                const message = std.fmt.bufPrint(&buffer, "SETTINGS FAILED: {s}", .{@errorName(err)}) catch "SETTINGS FAILED";
                if (self.tryAppendNotice(.warning, message)) self.settings_error_seen = err;
            }
        } else self.settings_error_seen = null;
        if (state.log_error) |err| {
            const changed = self.log_error_seen == null or self.log_error_seen.? != err;
            if (changed) {
                var buffer: [96]u8 = undefined;
                const message = std.fmt.bufPrint(&buffer, "REC FAILED: {s}", .{@errorName(err)}) catch "REC FAILED";
                if (self.tryAppendNotice(.warning, message)) self.log_error_seen = err;
            }
        } else self.log_error_seen = null;
        // Generic one-shot feedback is migrated at a safe body boundary. It is
        // never shown in the footer first and never rewrites retired rows.
        self.syncNoticeAlias();
        const self_hash = std.hash.Wyhash.hash(0, self.notice);
        const self_restored = std.mem.eql(u8, self.notice, session_client.restored_notice);
        const same_settings = if (state.settings_notice) |notice| std.mem.eql(u8, notice, self.notice) else false;
        const settings_published = same_settings and self.settings_notice_seen != null and self.settings_notice_seen.? == self_hash;
        var self_published_now = false;
        if ((self_restored and self.history_notice_shown) or settings_published) {
            // A real earlier publication, not a snapshot, owns this exact twin.
            self.notice_alias_hash = self_hash;
            self.notice_alias_pending = null;
        } else if (self.memorySafePoint()) {
            if (self.notice_alias_pending) |pending| {
                const level: NoticeLevel = if (self_restored) .plain else pending.level;
                if (self.tryAppendNotice(level, self.notice)) {
                    self.notice_alias_hash = pending.hash;
                    self.notice_alias_pending = null;
                    self_published_now = true;
                    if (self_restored) self.history_notice_shown = true;
                }
            } else {
                const terminal_twin = self.terminal_alias.len != 0 and std.mem.eql(u8, self.terminal_alias, self.notice);
                if (!self.noticePublished() and !terminal_twin and !omitNotice(self.notice) and !self.persistentNotice(self.notice)) {
                    const level: NoticeLevel = if (self_restored) .plain else oneShotNoticeLevel(self.notice);
                    if (self.tryAppendNotice(level, self.notice)) {
                        self.notice_alias_hash = self_hash;
                        self_published_now = true;
                        if (self_restored) self.history_notice_shown = true;
                    }
                }
            }
        }
        if (state.settings_notice) |notice| {
            const restored = std.mem.eql(u8, notice, session_client.restored_notice);
            if (setupHint(state) != null or capabilityPendingNotice(notice) or (restored and self.history_notice_shown)) {
                self.settings_notice_seen = null;
            } else {
                const hash = std.hash.Wyhash.hash(0, notice);
                if (same_settings and self_published_now) {
                    self.settings_notice_seen = hash;
                } else if ((self.settings_notice_seen == null or self.settings_notice_seen.? != hash) and
                    self.tryAppendNotice(if (restored or std.mem.eql(u8, notice, "Selection restored; NEW EMPTY CHAT (history not restored)")) .plain else .warning, notice))
                {
                    self.settings_notice_seen = hash;
                    if (restored) self.history_notice_shown = true;
                }
            }
        } else self.settings_notice_seen = null;
    }

    /// 判断是否有任务可以收尾。远端终态由本线程经 Bridge 交付，本地 busy 只是
    /// 视图：两个任务之间它可能已经为 false，所以不能把真实 terminal 留在
    /// Bridge 里等一个永远不会再出现的 busy 周期。本地任务仍需 busy 且
    /// job.done 才 join，保持 acquire/release 配对。
    fn finishReadyTask(self: *Ui) !void {
        if (self.terminal_notice_pending != null) return;
        if (self.remote() != null) {
            // The terminal event is produced and consumed on this thread; no
            // cross-thread race is involved.
            if (self.bridge.terminal != null) try self.complete();
        } else if (self.busy and self.job.done.load(.acquire)) {
            try self.complete();
        }
    }

    /// 收尾已结束的后台任务：等待 worker、排空剩余事件、记录终态并更新状态。
    fn complete(self: *Ui) !void {
        const is_remote = self.remote() != null;
        if (self.future) |*future| {
            future.await(self.io);
            self.future = null;
        }
        // The worker is really joined here, and no next task or FollowUp can be
        // dispatched before this release: the owner may hand its shared
        // configuration back at a safe boundary.
        self.endTaskOwnership();
        self.detachInbox();

        // The producer can finish after our per-tick drain limit. Once joined,
        // at most one bounded queue remains; consume it before accepting Submit.
        while (true) {
            if (self.displayBackpressured()) break;
            var item = self.bridge.pop() orelse break;
            defer item.deinit();
            try self.event(item);
        }
        if (!self.bridgeEmpty()) return;
        self.busy = false;
        self.remote_idle_ticks = 0;

        // 取走 bridge 中记录的终止信息，避免残留到下一次运行。
        const bridge_terminal = self.bridge.takeTerminal();
        if (bridge_terminal != null or !is_remote) {
            if (self.permission) |permission| self.settlePermissionDelivery(permission.id, permission.epoch);
        }
        self.clearPermission();
        if (self.prompt) |prompt| self.allocator.free(prompt);
        self.prompt = null;
        // Remote terminal events are injected through the display Bridge; the
        // local path keeps its joined Job result. No terminal means no result.
        self.last_terminal = if (is_remote)
            (bridge_terminal orelse {
                self.settleRemoteIdle();
                return;
            })
        else
            try self.job.result();
        // Shared state applies owner-produced terminal context after join.
        self.display.finish(self.last_terminal.?);
        const result = self.last_terminal.?;

        // 清理失败或无法安全继续时进入 poisoned，禁止再次提交。
        if (result.status != .success and !is_remote) self.inbox.pause();
        self.poisoned = if (result.detail) |detail| detail == error.CleanupFailed or detail == error.UnsafeToContinue else false;
        self.notice = terminalNotice(result);
        // Foreground terminal detail is delivered once into the conversation;
        // the neutral footer never keeps failed/paused/canceled history.
        self.queueTerminalNotice(result);

        // A truncated or canceled stream still has to drain its final window.
        if (self.draft) |i| {
            self.records.items[i].interrupted = true;
            if (self.records.items[i].stream) |stream| stream.finish() catch {
                self.notice = "Could not finalize interrupted display";
            };
        }
        self.discardReasoning();
        self.draft = null;
        self.clearActiveTool();
        self.clearToolCaptions();
        self.tool_views.clear(self.allocator);
        self.mode = null;
        // The owner can still report this task busy after delivering its
        // terminal. Keep the composer busy instead of painting an idle prompt
        // that the next stale snapshot would immediately re-busy; ordered owner
        // idle releases it, and an ordered state event adopts the next task.
        const owner_busy = if (self.remote()) |client| client.snapshot().busy else false;
        self.remote_terminal_wait = owner_busy;
        if (owner_busy) {
            self.busy = true;
            self.remote_observed_busy = true;
            self.remote_idle_ticks = 0;
        }
        self.requestDraw();
    }

    fn flushDeferredSubmit(self: *Ui) !void {
        if (self.idle_breaks != 0 or self.frame.len != 0 or self.exitAuthorized() or self.busy) return;
        const pending = self.deferred_submit orelse return;
        const draft = self.editor;
        const pasted = self.editor_pasted;
        self.deferred_submit = null;
        self.editor = pending.editor;
        self.editor_pasted = pending.pasted;
        defer {
            self.wipeEditor();
            self.editor.deinit();
            self.editor = draft;
            self.editor_pasted = pasted;
        }
        try self.submit();
        self.requestDraw();
    }

    fn requestDraw(self: *Ui) void {
        self.display_changed = true;
        self.resize_waiting = false;
        self.dirty = true;
    }

    /// Display progress of already-accepted content. It needs another frame but
    /// is not new input: it must not resurrect a screen whose geometry just
    /// changed, and it must not keep a resize-hold open.
    fn requestProgressDraw(self: *Ui) void {
        self.dirty = true;
    }

    fn registerRecord(self: *Ui, index: usize) !void {
        try self.record_index.ensureUnusedCapacity(self.allocator, 1);
        const id = self.next_record_id;
        self.next_record_id += 1;
        self.records.items[index].id = id;
        self.record_index.putAssumeCapacityNoClobber(id, index);
    }

    fn forgetRecord(self: *Ui, index: usize) void {
        _ = self.record_index.remove(self.records.items[index].id);
        for (self.records.items[index + 1 ..], index..) |record, shifted| {
            self.record_index.getPtr(record.id).?.* = shifted;
        }
    }

    /// Reserve every capacity a future record publication needs, so accepting an
    /// event can never fail after the receipt has already been consumed.
    fn reserveRecord(self: *Ui) !void {
        // Reserve for the caller's own publication plus one nesting level, so an
        // intervening display record can never consume a pending reservation.
        try self.records.ensureUnusedCapacity(self.allocator, 2);
        try self.record_index.ensureUnusedCapacity(self.allocator, 2);
    }

    fn drawReady(self: *const Ui) bool {
        return self.dirty and !self.resize_waiting and self.frame.len == 0 and self.resize_rescue.len == 0;
    }

    /// Pi-style ordinary display cadence: at most one fresh body frame per
    /// interval, counted from the previous draw's start so the draw's own cost is
    /// already used. Urgent input bypasses it; an unproven geometry waits for
    /// real input/content and never enters here by timer.
    fn drawDue(self: *const Ui) bool {
        if (!self.drawReady()) return false;
        if (self.urgent_draw) return true;
        return self.clock_ms -| self.last_draw_ms >= draw_interval_ms;
    }

    /// Remaining wait for a throttled dirty frame: the rest of the interval, not
    /// a fresh full interval after work that already happened.
    fn cadenceWaitMs(self: *const Ui) u16 {
        const elapsed = self.clock_ms -| self.last_draw_ms;
        const remaining = draw_interval_ms -| elapsed;
        return @intCast(@max(1, @min(remaining, draw_interval_ms)));
    }

    fn idleBreaksDrawable(self: *const Ui) bool {
        return self.idle_breaks != 0 and self.size.columns >= 9 and self.size.rows >= 7 and
            self.permission == null and !self.stop_open and !self.settings_open and !self.provider_open and
            self.model_picker == null and !self.secret_mode and !self.secret_quarantine and
            !self.busy and !self.presentationWaiting() and !self.remoteSynchronizing() and self.mode == null and self.active_tool == null;
    }

    /// Active or queued Memory keeps its own neutral animated footer row even
    /// while the main task is idle. Read-only owner snapshot; it neither polls
    /// nor schedules anything, so the ordinary tick owns the cadence.
    fn memoryAnimating(self: *const Ui) bool {
        if (self.permission != null or self.stop_open or self.secret_mode or self.secret_quarantine or
            self.settings_open or self.provider_open or self.model_picker != null or self.commandMenuVisible()) return false;
        const memory = self.connection.current().memory;
        return memory.enabled and (memory.active != null or memory.queued_count != 0);
    }

    fn backgroundAnimating(self: *const Ui) bool {
        if (self.permission != null or self.stop_open or self.secret_mode or self.secret_quarantine or
            self.settings_open or self.provider_open or self.model_picker != null or self.commandMenuVisible()) return false;
        return self.connection.current().background.active_count != 0;
    }

    fn animate(self: *Ui) void {
        const tick = self.clock_ms / 80;
        if (self.resize_waiting or self.animation_tick == tick) return;
        // Memory progress is a background owner: it rotates on the same 80 ms
        // tick and dirty-draw path as a running task, but it needs neither a
        // busy main task nor a second refresh source.
        if (!self.busy and !self.presentationWaiting() and !self.remoteSynchronizing() and !self.memoryAnimating() and !self.backgroundAnimating()) return;
        self.animation_tick = tick;
        // An approval owns a full, non-sparse preview. Repainting that unchanged
        // preview for a composer pulse sends its title/body again every 80 ms.
        // Keep polling/cancellation alive, but redraw only for actual events,
        // input until the approval is cleared. Never clear dirty here.
        // A static pending preview needs no spinner-only repaint. Real events,
        // input and tool timing retain their normal independent draw requests.
        const queue = self.queueSnapshot();
        if (self.permission == null and (queue.preview_count == 0 or self.active_tool != null or self.memoryAnimating() or self.backgroundAnimating())) self.dirty = true;
    }

    /// 主事件循环：有界消费、处理按键，然后绘制最新状态；仅动画自身限频。
    /// 已开始的帧仍完整写完并 ACK，不丢弃部分帧或清除原生 scrollback。
    fn loop(self: *Ui) !u8 {
        var buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        while (true) {
            self.clock_ms = @intCast(@max(0, Io.Clock.awake.now(self.io).toMilliseconds()));
            self.animate();
            // 档位确认到期后自动恢复为上下文百分比，不必等下一次按键。
            // 主循环每轮最多等待 16ms，因此到期后无需额外唤醒。
            self.expireEffortFlash();
            self.pumpAsync();
            // Both local and remote output share the bounded event budget;
            // buffered remote deltas must not wait one terminal tick apiece.
            try self.pumpDisplay();
            self.pollMemoryCompletion();
            self.pollBackgroundCompletion();

            // acquire 与 worker 的 release 配对，确保读到任务结果。
            try self.finishReadyTask();
            self.observeAdvisories();
            self.retryTerminalNotice();

            // 收到信号（如 SIGINT）：转为退出请求并取消任务。A remote task is
            // owned by the backend, so a frontend signal only detaches.
            if (interrupt.signal() != 0) {
                if (self.remote() == null) self.cancel.cancel();
            }

            // 任务结束后才真正退出；远程前端最后一次 ACK 后即可离开。
            if (self.exitAuthorized() and (!self.busy or self.remote() != null)) {
                try self.drainExit();
                return if (interrupt.signal() != 0) 128 + interrupt.signal() else 0;
            }

            self.refreshStop();
            self.pollMetadata();
            try self.observeSubagents();
            self.observeCodexLogin();
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

            // Join/drain happens above; current input/exit always wins over
            // dispatch. No await or host emission while holding Inbox locks.
            try self.flushDeferredSubmit();
            if (!self.exitAuthorized() and self.idle_breaks == 0 and self.deferred_submit == null) try self.dispatchNext();
            self.refreshStop();

            // 分段写出待输出的帧：终端可能只接受部分字节，剩余部分在下一轮继续。
            if (!self.initialExitWithoutFrame() and (self.resize_rescue.len != 0 or self.frame_offset < self.frame.len)) {
                try self.writeFrame();
            }

            // Draw latest state on the ordinary cadence, but preserve the
            // input/geometry turn before its first write. Already-buffered keys
            // must not gain authority from a frame they could not have seen;
            // urgent input waits only for a frame that has already started.
            // Cadence starts when the draw can actually run, not at the loop's
            // earlier clock sample before pumping/input/output work.
            self.clock_ms = @intCast(@max(0, Io.Clock.awake.now(self.io).toMilliseconds()));
            const staged = !self.initialExitWithoutFrame() and self.drawDue();
            if (staged) {
                try self.draw();
                self.dirty = false;
                self.urgent_draw = false;
            }

            // A fresh frame immediately returns through that safety turn. An
            // existing blocked/partial write still waits for output readiness,
            // rather than spinning just because a frame remains outstanding.
            const local_buffered = blk: {
                std.debug.assert(std.c.pthread_mutex_lock(&self.bridge.mutex) == .SUCCESS);
                defer std.debug.assert(std.c.pthread_mutex_unlock(&self.bridge.mutex) == .SUCCESS);
                // Active producers/borrowed storage are ownership, not queued
                // display work; an approval waiter must not make us spin.
                break :blk self.bridge.len != 0 or self.bridge.terminal != null;
            };
            const buffered = local_buffered or (!self.hasAsync(.submit) and
                (if (self.remote()) |client| client.buffered() else false));
            // Wake at the coalescing deadline rather than a full tick after work
            // that already happened; buffered events are consumed immediately and
            // never spin merely because a throttled dirty frame exists.
            var wait_ms: u16 = if (staged or buffered) 0 else 16;
            if (!staged and !buffered and self.frame.len == 0 and self.resize_rescue.len == 0 and
                self.drawReady() and !self.urgent_draw)
                wait_ms = self.cadenceWaitMs();
            try self.terminal.wait(self.frame.len != 0 or self.resize_rescue.len != 0, wait_ms);
        }
    }

    fn resize(self: *Ui, dimensions: terminal_module.Size) void {
        // Same geometry proves nothing new; a repeated size report is not a draw
        // request and must not restart any recovery state.
        if (dimensions.columns == self.size.columns and dimensions.rows == self.size.rows) return;
        // Real content staged in this turn keeps its obligation to be drawn even
        // though the frame carrying it is about to be discarded.
        const changed = self.display_changed or (self.frame.len != 0 and self.frame_changed);
        // A full ACK proves ownership before resize, not after terminal reflow
        // or cursor clamping (even height-only). Never erase guessed old rows:
        // pre-resize pixels belong to terminal-managed screen/scrollback from
        // now on, so they are neither canonical transcript nor completed
        // execution records, and this client no longer owns their coordinates.
        self.size = dimensions;
        self.entry_origin = null;
        self.vertical_column = null;
        self.tail_cursor_rows_up = 0;
        self.tail_composer_rows = 1;
        self.tail_exit_separator = false;
        // Reflow may have moved our rows: nothing is proven about the bottom or
        // about the rows we owned before this geometry change.
        self.tail_bottom = false;
        self.frame_bottom = false;
        self.tail_relative = false;
        self.frame_relative = false;
        self.tail_end_floor = 0;
        self.frame_end_floor = 0;
        self.tail_menu_extra = 0;
        self.frame_menu_extra = 0;
        self.displayed_permission = null;
        self.displayed_permission_choice = null;
        self.frame_permission_choice = null;
        self.displayed_model_epoch = null;
        self.displayed_model_generation = null;
        self.displayed_resume_generation = null;
        self.frame_resume_generation = null;
        self.displayed_command_generation = null;
        self.displayed_provider_generation = null;
        self.displayed_settings_generation = null;
        self.displayed_decision_fingerprint = null;
        self.frame_decision_fingerprint = null;
        self.displayed_stop = null;
        self.frame_stop = null;
        if (self.stop_open) self.stop_generation +%= 1;
        self.frame_fresh = false;
        if (self.tail_snapshot) |*snapshot| snapshot.deinit();
        self.tail_snapshot = null;
        self.abandon_tail = self.abandon_tail or self.tail_height != 0 or self.frame_offset != 0;
        self.discardResizedFrame();
        // Pending genuine input/content is ordinary work and draws once at the
        // new geometry; it is never dropped just because a resize shared its
        // turn. Otherwise only an animation pulse or repeated resize is pending:
        // stay inhibited until real input/content arrives. No timer, no repair
        // frame, no replay, and no CUD999/clear/fill is scheduled here.
        self.display_changed = changed or self.idleBreaksDrawable();
        self.resize_waiting = !self.display_changed;
        self.dirty = self.display_changed;
    }

    fn discardFrameRecords(self: *Ui, records: []FrameRecord) void {
        for (records) |*entry| {
            if (self.record_index.get(entry.record_id)) |index| {
                const record = &self.records.items[index];
                if (record.stream_generation == entry.generation) {
                    record.pending_output = false;
                    record.pending_stream_rows = 0;
                    record.discardPendingFlow();
                    if (record.stream) |stream| {
                        stream.abort();
                        record.invalidate();
                    }
                }
            }
            if (entry.flow_prefix) |*prefix| prefix.deinit();
            entry.flow_prefix = null;
        }
    }

    fn discardResizedFrame(self: *Ui) void {
        if (self.frame_idle_prefix_end != 0) {
            const sent = std.mem.count(u8, self.frame[0..@min(self.frame_offset, self.frame_idle_prefix_end)], "\n");
            self.idle_breaks -= @intCast(@min(sent, self.frame_idle_breaks));
        }
        // Controls only: release an interrupted sync/escape and restore cursor
        // visibility, but never move, erase, scroll or replay old-width content.
        if (self.frame_offset != 0 or self.resize_rescue.len != 0)
            self.resize_rescue = "\x18\x1b[0m" ++ terminal_module.sync_end ++ "\x1b[?25h";
        self.discardFrameRecords(self.frame_records);
        self.frame_records = &.{};
        if (self.frame_tail_snapshot) |*snapshot| snapshot.deinit();
        self.frame_tail_snapshot = null;
        if (self.frame_menu_history) |*history| history.deinit();
        self.frame_menu_history = null;
        if (self.frame_arena) |*arena| arena.deinit();
        self.frame_arena = null;
        self.frame = "";
        self.frame_offset = 0;
        self.frame_clear_end = 0;
        self.frame_sparse = false;
        self.frame_changed = false;
        self.frame_idle_breaks = 0;
        self.frame_idle_prefix_end = 0;
        if (self.idle_breaks == 0) self.idle_notice_barrier = false;
        self.frame_bottom = false;
        self.frame_relative = false;
        self.frame_end_floor = 0;
        self.frame_menu_extra = 0;
        self.frame_exit_separator = false;
        self.frame_delivery_shown = false;
        self.frame_delivery_reasoning = false;
    }

    fn writeFrame(self: *Ui) !void {
        // Rendering/input handling can take time after the loop's first size
        // sample. Revalidate before writing any owned interface payload.
        self.resize(self.terminal.size());
        if (self.resize_rescue.len != 0) {
            const n = try self.terminal.write(self.resize_rescue);
            self.resize_rescue = self.resize_rescue[n..];
            if (self.resize_rescue.len != 0) return;
        }
        if (self.frame.len == 0) return;
        const written = try self.terminal.write(self.frame[self.frame_offset..]);
        if (written != 0) self.entry_origin = null;
        self.frame_offset += written;
        if (written != 0 and self.frame_offset != self.frame.len and self.natural_flow) {
            self.tail_bottom = false;
            self.tail_relative = false;
            self.tail_end_floor = 0;
            self.tail_menu_extra = 0;
            // Keep staged proof for this same frame's eventual full ACK;
            // resize() invalidates it separately, including resize ABA.
        }
        if (self.frame_offset == self.frame.len) self.finishFrame();
    }

    fn finishFrame(self: *Ui) void {
        if (self.frame.len == 0 or self.frame_offset != self.frame.len) return;
        self.entry_origin = null;
        // Resize invalidation is sticky, even if the window returns to its old size.
        self.displayed_stop = if (self.frame_fresh) self.frame_stop else null;
        self.displayed_permission = if (self.frame_fresh) self.frame_permission else null;
        self.displayed_permission_choice = if (self.frame_fresh) self.frame_permission_choice else null;
        self.displayed_model_epoch = if (self.frame_fresh) self.frame_model_epoch else null;
        self.displayed_model_generation = if (self.frame_fresh) self.frame_model_generation else null;
        if (self.model_picker) |*picker| {
            if (self.displayed_model_epoch == self.model_epoch and self.displayed_model_generation == picker.generation)
                picker.acknowledgeChoice()
            else
                picker.drawn_model_len = null;
        }
        self.displayed_resume_generation = if (self.frame_fresh) self.frame_resume_generation else null;
        self.displayed_command_generation = if (self.frame_fresh) self.frame_command_generation else null;
        self.displayed_provider_generation = if (self.frame_fresh) self.frame_provider_generation else null;
        self.displayed_settings_generation = if (self.frame_fresh) self.frame_settings_generation else null;
        self.displayed_decision_fingerprint = if (self.frame_fresh and self.displayed_settings_generation != null) self.frame_decision_fingerprint else null;
        self.displayed_proxy_fingerprint = if (self.frame_fresh and self.displayed_settings_generation != null) self.frame_proxy_fingerprint else null;
        self.tail_height = self.frame_height;
        if (self.frame_fresh) self.tail_hint_hash = self.frame_hint_hash;
        // Only a fresh, complete frame that fills the screen proves that its last
        // row is the physical bottom. Fractional/partial state never promotes.
        self.tail_bottom = self.frame_fresh and self.frame_bottom;
        self.tail_relative = self.frame_fresh and self.frame_relative;
        self.tail_end_floor = if (self.tail_relative) self.frame_end_floor else 0;
        self.tail_menu_extra = if (self.frame_fresh and self.tail_relative) self.frame_menu_extra else 0;
        self.tail_cursor_rows_up = if (self.frame_fresh) self.frame_cursor_rows_up else 0;
        self.tail_composer_rows = if (self.frame_fresh) self.frame_composer_rows else 1;
        self.tail_exit_separator = self.frame_fresh and self.frame_exit_separator;
        self.tail_size = self.frame_size;
        var delivery_frame_valid = self.frame_fresh and self.frame_offset == self.frame.len;
        for (self.frame_records) |*entry| {
            defer if (entry.flow_prefix) |*prefix| prefix.deinit();
            const index = self.record_index.get(entry.record_id) orelse {
                delivery_frame_valid = false;
                continue;
            };
            const record = &self.records.items[index];
            if (record.stream_generation != entry.generation) {
                delivery_frame_valid = false;
                continue;
            }
            record.pending_output = false;
            record.pending_stream_rows = 0;
            if (!self.frame_fresh) {
                if (record.stream) |stream| {
                    stream.abort();
                    record.invalidate();
                }
                continue;
            }
            var committed = true;
            if (record.stream) |stream| {
                if (entry.stream_rows != 0 or entry.metadata_staged) {
                    const before_base = stream.base;
                    if (stream.commit(entry.stream_rows)) |done| {
                        const progressed = done != 0 or stream.base > before_base;
                        if (entry.metadata_staged and entry.stream_rows == 0 and stream.base > before_base)
                            record.delivery_visible = @max(record.delivery_visible, stream.base);
                        record.stream_written += done;
                        if (done != entry.stream_rows) {
                            committed = false;
                            self.notice = "Display commit incomplete; output retained";
                            self.requestDraw();
                        }
                        record.invalidate();
                        if (progressed and (stream.pendingBytes() != 0 or stream.hasMetadataProgress())) self.requestProgressDraw();
                    } else |_| {
                        committed = false;
                        stream.abort();
                        record.invalidate();
                        self.notice = "Display commit failed; output retained";
                        self.requestDraw();
                    }
                } else stream.releasePin();
                if (entry.output_candidate and !stream.isDrained()) {
                    committed = false;
                    // Waiting for more provider bytes is not progress; an append,
                    // EOF or another independent state change requests its own draw.
                }
            }
            if (!committed) delivery_frame_valid = false;
            // Persist what this complete fresh frame actually displayed BEFORE
            // any later commit/frame can change the render. Prior proof stays.
            if (self.frame_fresh) {
                record.delivery_visible = @max(record.delivery_visible, entry.visible_source_end);
                record.delivery_complete = record.delivery_complete or entry.visible_complete;
            }
            if (committed and entry.output_candidate) {
                record.output = true;
                // A metadata-only EOF is visible only after its fresh frame has
                // committed the pinned metadata and drained the body.
                record.delivery_complete = true;
            }
            if (committed and entry.flow_change) {
                if (record.flow_prefix) |*prefix| prefix.deinit();
                record.flow_prefix = entry.flow_prefix;
                entry.flow_prefix = null;
                record.flow_match = if (entry.flow_layout_valid and record.cache != null) true else null;
            }
        }
        self.frame_records = &.{};
        if (!self.delivery_fault and self.frame_delivery_epoch == self.delivery_epoch and
            self.frame_delivery_sequence != 0)
        {
            self.promoteDeliveryFences(delivery_frame_valid);
            self.retryDeliveryAck();
        }
        self.frame_delivery_shown = false;
        self.frame_delivery_reasoning = false;
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
        self.idle_breaks -= self.frame_idle_breaks;
        if (self.frame_idle_breaks != 0) {
            self.compact_composer = self.frame_fresh and self.frame_height == 1 and !self.idle_notice_barrier;
            self.compact_hint_hash = self.frame_hint_hash;
            if (self.idle_breaks == 0) self.idle_notice_barrier = false;
            // Edits/menu state may have arrived after this frame was staged.
            self.requestDraw();
        }
        self.frame_idle_breaks = 0;
        self.frame_idle_prefix_end = 0;
        // Retain accepted line requests while a tiny window/modal cannot
        // advance them, without turning that retained work into a redraw loop.
        if (self.idleBreaksDrawable()) self.requestDraw();
        self.frame_changed = false;
        self.frame_sparse = false;
        self.frame = "";
        self.frame_offset = 0;
        self.resize_rescue = "";
    }

    /// An unseen initial frame owns no pixels. Pending output still drains.
    fn initialExitWithoutFrame(self: *const Ui) bool {
        return self.ctrl_d_exit and self.tail_height == 0 and self.tail_snapshot == null and
            self.menu_history == null and self.tail_size.rows == 0 and !self.abandon_tail and
            self.frame_offset == 0 and self.resize_rescue.len == 0 and
            self.records.items.len == 0 and self.draft == null and self.reasoning == null and
            self.mode == null and self.active_tool == null and self.permission == null and
            self.delivery_admitted == self.delivery_acked and self.delivery_fences.items.len == 0 and
            !self.busy and self.future == null;
    }

    /// Exit gets a bounded chance to publish the final canonical reply, never an infinite drain.
    fn drainExit(self: *Ui) !void {
        if (self.initialExitWithoutFrame()) return;
        // Exit is a real end of input: finish retained bodies so their last
        // acknowledged rows can be published instead of waiting for more tokens.
        for (self.records.items) |*record| {
            if (record.stream) |stream| stream.finish() catch {};
        }
        const start = Io.Clock.awake.now(self.io);
        for (0..128) |_| {
            self.resize(self.terminal.size());
            if (self.resize_rescue.len != 0) {
                try self.writeFrame();
                if (self.resize_rescue.len != 0) {
                    if (start.untilNow(self.io, .awake).toMilliseconds() >= 200) return;
                    try self.terminal.wait(true, 2);
                    continue;
                }
            }
            if (self.frame.len == 0) {
                if (!self.drawReady()) return;
                try self.draw();
                self.dirty = false;
            }
            try self.writeFrame();
            if (start.untilNow(self.io, .awake).toMilliseconds() >= 200) return;
            if (self.frame.len != 0) try self.terminal.wait(true, 2);
        }
    }

    /// Reclaim only exact ACK-owned blank edges, without replaying transcript
    /// rows or moving anything into native scrollback.
    fn idleExitBytes(self: *const Ui, writer: *Io.Writer) !bool {
        if (self.busy or self.future != null or self.frame.len != 0 or self.resize_rescue.len != 0 or
            !self.frame_fresh or self.abandon_tail or !(self.tail_bottom or self.tail_relative) or self.tail_snapshot == null or
            self.menu_history == null or self.tail_height == 0 or self.tail_height > self.size.rows or
            self.tail_size.rows != self.size.rows or self.tail_size.columns != self.size.columns or
            self.tail_cursor_rows_up >= self.tail_height or self.tail_composer_rows == 0 or
            self.tail_composer_rows > self.tail_height or self.editor.bytes.items.len != 0 or
            self.deferred_submit != null or self.idle_breaks != 0 or self.permission != null or
            self.stop_open or self.codex_open or self.model_picker != null or self.provider_open or
            self.settings_open or self.secret_mode or self.secret_quarantine or self.draft != null or
            self.reasoning != null or self.mode != null or self.active_tool != null) return false;
        for (self.records.items) |record| {
            if (record.kind != .reasoning and !record.output) return false;
        }
        const history = self.menu_history.?;
        const rows = self.tail_snapshot.?.rows;
        if (history.borrowed.len != 0 or rows.len != self.tail_height or
            history.above.len > self.size.rows - self.tail_height) return false;
        const blank = "\x1b[0m\x1b[K";
        var above_blank: usize = 0;
        // Natural flow never pads above: a cropped leading blank may be a
        // canonical paragraph separator straddling scrollback and the viewport.
        if (!self.natural_flow and !self.tail_relative) {
            while (above_blank < history.above.len and std.mem.eql(u8, history.above[above_blank], blank)) : (above_blank += 1) {}
        }
        var content_end = rows.len - self.tail_composer_rows;
        if (self.tail_exit_separator) {
            // The ACK identifies this one row as UI footprint; its bytes must
            // still be an exact painted blank, never an arbitrary ANSI line.
            if (content_end == 0) return false;
            const separator = rows[content_end - 1];
            if (!std.mem.eql(u8, separator, blank) and !std.mem.eql(u8, separator, "\x1b[0m\x1b[0m\x1b[K")) return false;
            content_end -= 1;
        }
        var leading: usize = 0;
        while (leading < content_end and std.mem.eql(u8, rows[leading], blank)) : (leading += 1) {}
        var end = content_end;
        while (end > leading and std.mem.eql(u8, rows[end - 1], blank)) : (end -= 1) {}
        const retained = end - leading;
        const trailing = rows.len - end;
        const above_remaining = history.above.len - above_blank;
        const top_distance = self.tail_height - 1 - self.tail_cursor_rows_up;
        const up = top_distance + history.above.len;
        const final_position = self.size.rows - self.tail_height - history.above.len + above_remaining + retained;

        // Stage the entire bounded plan before touching the caller's writer.
        var bytes: [256]u8 = undefined;
        var plan = Io.Writer.fixed(&bytes);
        plan.writeAll(terminal_module.sync_begin ++ "\x1b[?25l\r") catch return false;
        if (up != 0) plan.print("\x1b[{d}A", .{up}) catch return false;
        if (above_blank != 0) plan.print("\x1b[{d}M", .{above_blank}) catch return false;
        if (above_remaining != 0) plan.print("\x1b[{d}B", .{above_remaining}) catch return false;
        if (leading != 0) plan.print("\x1b[{d}M", .{leading}) catch return false;
        if (retained != 0) plan.print("\x1b[{d}B", .{retained}) catch return false;
        if (trailing != 0) plan.print("\x1b[{d}M", .{trailing}) catch return false;
        if (self.tail_relative or final_position != 0) plan.writeAll("\x1b[1A") catch return false;
        plan.writeAll("\r" ++ terminal_module.sync_end) catch return false;
        if (writer.buffer.len - writer.end < plan.buffered().len) return false;
        try writer.writeAll(plan.buffered());
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
    fn approvalFits(self: *const Ui, id: u64, choice: ApprovalChoice) bool {
        var buffer: [40]u8 = undefined;
        const identity = std.fmt.bufPrint(&buffer, "Approval #{d}", .{id}) catch return false;
        const cols = self.size.columns -| 1;
        const authority_width: usize = if (choice == .allow_once) "> Allow once".len else 0;
        return self.size.rows >= 7 and cols >= @max(text.width(identity), authority_width);
    }

    /// 构建一整帧输出到帧 arena（不直接写终端），帧由 loop 分段写出。
    const PreparedComposer = struct { decoration: presentation.Prompt, layout: composer_layout.Layout };

    fn prepareComposer(self: *Ui, a: std.mem.Allocator, state: Connection.State, cols: usize) !PreparedComposer {
        // Mask only genuinely sensitive or invalid slash arguments. Trailing
        // whitespace alone never hides anything, and product-supported ordinary
        // arguments (/attach, /cd, /close, /ls) stay visible and editable.
        const trimmed = std.mem.trimStart(u8, self.editor.bytes.items, " \t\r\n");
        const is_model = modelCommand(trimmed);
        const command_end = std.mem.findAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
        const name = trimmed[0..command_end];
        const hide_arguments = std.mem.startsWith(u8, trimmed, "/") and sensitiveArguments(name, trimmed[command_end..]);
        const hidden_hint: []const u8 = if (is_model)
            "/model [arguments hidden; use one model ID]"
        else if (std.mem.eql(u8, name, "/login"))
            "/login [arguments hidden; no key argument]"
        else if (std.mem.eql(u8, name, "/compact"))
            "/compact [arguments hidden; no arguments]"
        else
            "/ [command arguments hidden]";
        const visible = if (hide_arguments) hidden_hint else self.editor.bytes.items;
        const cursor = if (hide_arguments) visible.len else self.editor.cursor;
        const prefix = try editorDisplay(a, visible[0..cursor]);
        const suffix = try editorDisplay(a, visible[cursor..]);
        const display_bytes = try std.mem.concat(a, u8, &.{ prefix, suffix });
        const working = self.busy or self.presentationWaiting() or self.remoteSynchronizing() or self.mode != null or self.active_tool != null;
        const view = self.display.view(self.clock_ms);
        self.model_flow.advance(self.clock_ms, working, view.live_tps_tenths);
        const flash = if (self.effort_flash) |pending| if (self.clock_ms < pending.until_ms) pending.level else null else null;
        const decoration = try presentation.prompt(a, state.model, view.context, cols, .{ .busy = working, .now_ms = self.clock_ms, .phase = self.model_flow.step(), .rate_band = view.rate_band, .reasoning_effort = view.reasoning_effort, .effort_flash = flash, .low_price_input = state.low_price_input });
        // Modal authorization/secret layouts stay fixed. Idle LF debt first
        // obtains a single-row composer ACK even if a newer long draft arrived.
        const limit: usize = if (self.permission != null or self.stop_open or self.idle_breaks != 0) 1 else @min(composer_layout.max_rows, @max(1, self.size.rows -| 5));
        return .{ .decoration = decoration, .layout = try composer_layout.layout(a, display_bytes, prefix.len, cols -| text.width(decoration.plain), limit) };
    }

    /// Restore borrowed ACKed rows at their original owned coordinates, ahead
    /// of any rows this frame appends, and count them as transcript so the tail
    /// advances past them. The rows stay owned restoration data, never replayed
    /// history, and leave `borrowed` empty.
    fn releaseBorrowedPrefix(
        a: std.mem.Allocator,
        out: *std.Io.Writer.Allocating,
        clear_end: usize,
        borrowed: *[]const []const u8,
        transcript_rows: *usize,
    ) !void {
        if (borrowed.*.len == 0) return;
        var rebuilt: std.Io.Writer.Allocating = .init(a);
        try rebuilt.writer.writeAll(out.written()[0..clear_end]);
        for (borrowed.*) |line| {
            try rebuilt.writer.writeAll(line);
            try rebuilt.writer.writeAll("\r\n");
        }
        try rebuilt.writer.writeAll(out.written()[clear_end..]);
        out.* = rebuilt;
        transcript_rows.* += borrowed.*.len;
        borrowed.* = &.{};
    }

    const TailBodyLayout = struct {
        body_rows: usize,
        content_body_rows: usize,
        secret_lines: markdown.Rendered,
        show_thinking: bool,
        thinking_lines: []const []const u8,
        thinking_gap: usize,
        borrowed_count: usize,
        live_gap: usize,
        lines: []const []const u8,
    };

    fn drawTailBody(self: *Ui, writer: *Io.Writer, layout: TailBodyLayout) !usize {
        const body_rows = layout.body_rows;
        const content_body_rows = layout.content_body_rows;
        if (self.secret_mode) {
            const start = body_rows -| layout.secret_lines.lines.len;
            for (0..body_rows) |line| try putStyled(writer, 1 + line, if (line >= start and line - start < layout.secret_lines.lines.len) layout.secret_lines.lines[line - start] else "");
            self.frame_permission = null;
        } else if (layout.show_thinking) {
            // Latest reasoning row, without any title/prefix. This
            // window never borrows rows, so any borrowed ACKed prefix was
            // already restored above the tail before it resumes.
            const visible_rows = @min(reasoning_tail_rows, content_body_rows -| layout.thinking_gap);
            const start = layout.thinking_lines.len -| visible_rows;
            for (0..content_body_rows) |line| {
                const index = line -| layout.thinking_gap;
                try putStyled(writer, 1 + line, if (line >= layout.thinking_gap and index < visible_rows and start + index < layout.thinking_lines.len) layout.thinking_lines[start + index] else "");
            }
            self.frame_permission = null;
            self.frame_delivery_shown = true;
        } else {
            // Bounded live draft: only its last rows that fit are written,
            // and new rows grow naturally below the owned footprint. This
            // is not a regenerated history window.
            const leading_gap = if (layout.borrowed_count == 0) layout.live_gap else 0;
            const content = layout.lines[leading_gap..];
            const content_rows = content_body_rows -| leading_gap;
            const start = content.len -| content_rows;
            for (0..content_body_rows) |line| {
                const index = line -| leading_gap;
                try putStyled(writer, 1 + line, if (line >= leading_gap and start + index < content.len) content[start + index] else "");
            }
            self.frame_permission = null;
            self.frame_delivery_shown = true;
            return leading_gap + start;
        }
        return std.math.maxInt(usize);
    }

    const ComposerCursor = struct { offset: usize, rows_up: usize, rows: usize };

    fn drawComposer(self: *Ui, tail_out: *Io.Writer.Allocating, a: std.mem.Allocator, cols: usize, rows: usize, composer_rows: usize, prepared: ?PreparedComposer, modal: bool) !ComposerCursor {
        const writer = &tail_out.writer;
        var cursor_offset: usize = 0;
        var cursor_rows_up: usize = 0;
        var rendered_composer_rows: usize = 1;
        if (!modal and (self.secret_mode or self.secret_quarantine)) {
            // Only a bounded mask is copied to the frame; never format secret bytes.
            const masks: [64]u8 = @splat('*');
            const count = @min(self.secret.len, @min(masks.len, cols - 3));
            try putInputLine(writer, a, rows, "API key> ", masks[0..count], cols);
            cursor_offset = tail_out.written().len;
            try writer.print("\r\x1b[{d}C", .{@min(cols, count + 10) - 1});
        } else if (!modal and self.proxy_address_open) {
            // The endpoint editor owns the composer line while the submenu
            // stays visible; nothing is saved before a fresh full frame.
            const value = try editorDisplay(a, self.editor.bytes.items);
            try putInputLine(writer, a, rows, "Address> ", value, cols);
            cursor_offset = tail_out.written().len;
            const typed = try editorDisplay(a, self.editor.bytes.items[0..self.editor.cursor]);
            const column = @min(cols -| 1, text.width("Address> ") + text.width(typed));
            try writer.print("\r\x1b[{d}C", .{column -| 1});
        } else if (!modal and self.settings_open and !self.settingsQueryOpen()) {
            try putInputLine(writer, a, rows, "Settings> ", "", cols);
            cursor_offset = tail_out.written().len;
            try writer.print("\r\x1b[{d}C", .{@min(cols - 1, 10)});
        } else if (!modal and self.provider_open) {
            try putInputLine(writer, a, rows, "Provider> ", "", cols);
            cursor_offset = tail_out.written().len;
            try writer.print("\r\x1b[{d}C", .{@min(cols - 1, 10)});
        } else if (!modal and (self.settingsQueryOpen() or self.model_picker != null)) {
            const query = if (self.settingsQueryOpen()) &self.editor else &self.model_picker.?.query;
            const decorated: []const u8 = "Search> ";
            const prefix = try editorDisplay(a, query.bytes.items[0..query.cursor]);
            var start: usize = 0;
            var width = text.width(prefix);
            while (width > cols -| (decorated.len + 1) and start < prefix.len) {
                const cluster = text.nextCluster(prefix, start, 0);
                width -|= cluster.width;
                start = cluster.end;
            }
            const suffix = try editorDisplay(a, query.bytes.items[query.cursor..]);
            const end = fittingBytes(suffix, cols -| (decorated.len + width));
            const value = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix[start..], suffix[0..end] });
            try putInputLine(writer, a, rows, decorated, value, cols);
            cursor_offset = tail_out.written().len;
            try writer.print("\r\x1b[{d}C", .{@min(cols, decorated.len + width + 1) - 1});
        } else {
            const composer = prepared.?;
            const decoration_width = text.width(composer.decoration.plain);
            const indent = try a.alloc(u8, decoration_width);
            @memset(indent, ' ');
            for (composer.layout.lines, 0..) |line, index| {
                const input_line = try std.fmt.allocPrint(a, "{s}{s}", .{ if (index == 0) composer.decoration.styled else indent, line });
                try putStyled(writer, rows - composer_rows + 1 + index, input_line);
            }
            rendered_composer_rows = composer_rows;
            cursor_rows_up = composer_rows - 1 - composer.layout.cursor_row;
            cursor_offset = tail_out.written().len;
            try writer.writeAll("\r");
            if (cursor_rows_up != 0) try writer.print("\x1b[{d}A", .{cursor_rows_up});
            const cursor_column = @min(cols - 1, decoration_width + composer.layout.cursor_column);
            if (cursor_column != 0) try writer.print("\x1b[{d}C", .{cursor_column});
        }
        return .{ .offset = cursor_offset, .rows_up = cursor_rows_up, .rows = rendered_composer_rows };
    }

    fn draw(self: *Ui) !void {
        // Cadence is measured from the start of this draw, so its own work is
        // already counted before the next ordinary frame may be staged.
        self.last_draw_ms = self.clock_ms;
        self.refreshStop();
        self.displayed_stop = null;
        self.frame_stop = null;
        self.refreshCommandMenu();
        self.displayed_command_generation = null;
        self.frame_command_generation = null;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var frame_records: std.ArrayList(FrameRecord) = .empty;
        errdefer self.discardFrameRecords(frame_records.items);
        const cols = self.size.columns -| 1; // Never trigger terminal autowrap.
        const state = self.connection.current();
        self.display.seed(state.initial_context);
        self.display.setEffort(state.reasoning_effort);
        const normal_composer = !self.secret_mode and !self.secret_quarantine and !self.settings_open and !self.provider_open and self.model_picker == null;
        const empty_rendered: markdown.Rendered = .{ .lines = &.{}, .total_lines = 0, .truncated = false };
        const approval_lines = if (self.permission) |permission| try markdown.render(a, permission.description, .{ .columns = @max(1, cols), .max_lines = null, .markdown = false }) else empty_rendered;
        if (self.permission) |*permission| {
            permission.clipped = permission.clipped or approval_lines.truncated or approval_lines.total_lines > approval_lines.lines.len;
            if (permission.clipped or permission.pasted) permission.choice = .deny;
        }
        const queue_snapshot = self.queueSnapshot();
        const confirmation_visible = !self.secret_mode and !self.secret_quarantine and !self.codex_open and !self.codex_opening;
        const modal_text: ?[]const u8 = if (!confirmation_visible) null else if (self.stop_open) blk: {
            const closing = self.stop_close != null;
            const title = if (closing)
                try std.fmt.allocPrint(a, "Close busy session | Steering {d} FollowUp {d}", .{ queue_snapshot.steering, queue_snapshot.follow_up })
            else
                try std.fmt.allocPrint(a, "{s} | Steering {d} FollowUp {d}", .{ if (self.busy) "Task running" else "Task ended", queue_snapshot.steering, queue_snapshot.follow_up });
            const safe = if (closing) (if (self.stop_danger) "Cancel" else "> Cancel") else (if (self.stop_danger) "Continue" else "> Continue");
            const danger = if (closing) (if (self.stop_danger) "> Close session" else "Close session") else (if (self.stop_danger) "> Stop and clear" else "Stop and clear");
            break :blk try std.fmt.allocPrint(a, "{s}: [{s} / {s}]", .{ title, safe, danger });
        } else if (self.permission) |permission|
            try std.fmt.allocPrint(a, "Approval #{d}: [{s}] {s}", .{ permission.id, if (permission.clipped or permission.pasted) "> Deny" else if (permission.choice == .allow_once) "> Allow once / Deny" else "Allow once / > Deny", if (permission.pasted) "(paste detected; deny only)" else if (permission.clipped) "(preview clipped; deny only)" else "" })
        else
            null;
        var modal_fits = false;
        const prepared: ?PreparedComposer = if (modal_text) |value| blk: {
            const layout = try composer_layout.layout(a, value, value.len, cols, 3);
            modal_fits = layout.total_rows <= 3 and layout.total_rows <= self.size.rows -| 4;
            if (modal_fits) break :blk .{ .decoration = .{ .plain = "", .styled = "" }, .layout = layout };
            const fallback = "Resize to confirm";
            break :blk .{ .decoration = .{ .plain = "", .styled = "" }, .layout = try composer_layout.layout(a, fallback, fallback.len, cols, 1) };
        } else if (normal_composer) try self.prepareComposer(a, state, cols) else null;
        const composer_rows: usize = if (prepared) |value| value.layout.lines.len else 1;
        var out: std.Io.Writer.Allocating = .init(a);
        var tail_out: std.Io.Writer.Allocating = .init(a);
        var writer: *Io.Writer = &out.writer;
        self.displayed_permission = null;
        self.displayed_permission_choice = null;
        self.frame_permission = null;
        self.frame_permission_choice = null;
        // This frame's delivery proof starts empty; only a written row can
        // promote it, and only `finishFrame` may publish it.
        self.frame_delivery_shown = false;
        self.frame_delivery_reasoning = false;

        const pending_transcript = for (self.records.items) |record| {
            if (record.kind != .reasoning and !record.output) break true;
        } else false;
        const release_idle = self.idleBreaksDrawable() and !pending_transcript and !self.abandon_tail and
            self.tail_snapshot != null and (self.tail_bottom or self.tail_relative) and self.tail_height != 0 and self.tail_composer_rows == 1 and self.tail_cursor_rows_up == 0 and
            self.tail_size.columns == self.size.columns and self.tail_size.rows == self.size.rows;
        const break_count: u16 = if (release_idle) @min(256, self.idle_breaks) else 0;

        // Reclaim only our last complete live tail, never the user's earlier rows.
        // Batch visible presentation as well as writes: large canonical commits
        // must scroll, and row-by-row correctness alone still exposes mid-frame
        // footer/body states. Unsupported terminals retain the same safe diffs.
        try writer.writeAll(terminal_module.sync_begin ++ "\x1b[?25l\r");
        var idle_prompt: []const u8 = "";
        if (release_idle) {
            // Repair the old composer before releasing it: Ctrl-U/backspace and
            // Enter may share a read batch after a nonempty draft was ACKed.
            // Only the prompt, never that now-deleted draft, becomes history.
            const view = self.display.view(self.clock_ms);
            const flash = if (self.effort_flash) |pending| if (self.clock_ms < pending.until_ms) pending.level else null else null;
            const decoration = try presentation.prompt(a, state.model, view.context, cols, .{ .now_ms = self.clock_ms, .phase = self.model_flow.step(), .rate_band = view.rate_band, .reasoning_effort = view.reasoning_effort, .effort_flash = flash, .low_price_input = state.low_price_input });
            idle_prompt = try std.fmt.allocPrint(a, "{s}{s}\x1b[K", .{ decoration.styled, theme.reset });
            try writer.writeAll(idle_prompt);
            // Entry is the ACKed composer's bottom row, not the tail's top.
            // Each LF advances exactly one native row; the final composer uses
            // today's draft, including text received after the empty Enter.
            for (0..break_count) |i| {
                if (i != 0) try writer.writeAll(idle_prompt);
                try writer.writeAll("\r\n");
            }
        } else if (self.abandon_tail or (self.tail_height != 0 and
            (!(self.tail_bottom or self.tail_relative) or self.tail_size.columns != self.size.columns or self.tail_size.rows != self.size.rows)))
        {
            // Unknown geometry owns no old coordinates. The fresh frame below
            // establishes a new anchor without reclaiming the old tail.
        } else if (self.tail_height != 0) {
            const top_distance = (self.tail_height - 1) -| self.tail_cursor_rows_up;
            if (top_distance != 0) try writer.print("\x1b[{d}A", .{top_distance});
            // Replace each owned row once, without exposing a whole-tail blank
            // pass. Transcript rows plus the new tail cover the old footprint;
            // rows the frame no longer needs are contracted after it.
            try writer.writeAll("\r");
        }

        self.frame_clear_end = out.written().len;
        const history_valid = !self.abandon_tail and (self.tail_bottom or self.tail_relative) and self.tail_size.columns == self.size.columns and
            self.tail_size.rows == self.size.rows and self.menu_history != null;
        var above: []const []const u8 = if (history_valid) self.menu_history.?.above else &.{};
        var borrowed: []const []const u8 = if (history_valid and !release_idle) self.menu_history.?.borrowed else &.{};

        // Native scrollback is an appendable document, not a sliding window.
        // Completed records are released once and never regrouped, re-laid out
        // or replayed here; only the still-mutable tail joins `lines`.
        var lines: std.ArrayList([]const u8) = .empty;
        const flow_allowed = self.size.rows >= 7 and cols >= 8 and
            self.permission == null and self.resume_picker == null and self.model_picker == null and !self.provider_open and !self.settings_open and
            !self.commandMenuVisible() and !self.stop_open and !self.secret_mode and !self.secret_quarantine;
        const mutable_rows = @max(1, self.size.rows -| (3 + composer_rows));
        var flow_continuation = false;
        var canonical_output = false;
        var transcript_rows: usize = 0;
        var previous_kind: ?Kind = null;
        var hold_from: ?usize = null;
        for (self.records.items, 0..) |record, index| {
            if (record.agent_row and record.agent_open and !record.output) {
                hold_from = index;
                break;
            }
        }
        for (self.records.items, 0..) |*record, index| {
            if (@import("builtin").is_test) self.draw_record_visits += 1;
            if (record.kind == .reasoning) continue;
            const drafting = self.draft == index;
            const held = if (hold_from) |first| index >= first else false;
            if (record.output and !drafting) {
                previous_kind = record.kind;
                continue;
            }
            // Only the current draft can receive later text chunks. A static
            // or committed body needs EOF before its final rows can drain.
            if (!drafting) if (record.stream) |stream| {
                if (!stream.finished) {
                    record.invalidate();
                    try stream.finish();
                }
            };
            try frame_records.append(a, .{ .record_id = record.id, .generation = record.stream_generation });
            const frame_record = &frame_records.items[frame_records.items.len - 1];
            try record.layout(self.allocator, @max(1, cols));
            const heading = if (record.interrupted) "Interrupted response — preview" else if (record.excerpt) "Display excerpt" else "";
            // Body records keep no full-prefix copy: rows below the ACKed
            // written cursor were retired by the Body and no longer exist, so
            // this frame writes only uncommitted rows. Batched/static records
            // keep the existing shared-prefix path.
            const stream_record = record.stream != null;
            var prefix: usize = 0;
            if (!stream_record and record.flow_prefix != null) {
                if (record.flowMatches(@max(1, cols))) {
                    prefix = record.flow_prefix.?.rowCount();
                } else if (!held and self.permission == null and (!drafting or flow_allowed)) {
                    // Do not clear/replay native history as Pi's regular renderer
                    // can do. A revised/reflowed preview is explicitly superseded.
                    try putToneLine(writer, a, 1, "Response revised — earlier stream preview above", cols, theme.muted);
                    try writer.writeAll("\r\n");
                    transcript_rows += 1;
                    _ = try record.stageFlow(self.allocator, 0);
                }
            }
            // An approval is a reversible overlay, not a transcript advance.
            // Defer unseen canonical rows until it closes; otherwise opening a
            // full-height preview can scroll away the context it must restore.
            const finalized = cols >= 8 and !record.output and !drafting and !held and self.permission == null;
            if (held) prefix = 0;
            var stop = prefix;
            if (stream_record) {
                stop = if (finalized) record.stream.?.releaseLimit(record.stream.?.visibleRows().len) else if (drafting and flow_allowed and !held) record.stream.?.releaseLimit(record.lines.len -| mutable_rows) else 0;
                record.pending_stream_rows = stop;
            } else {
                if (drafting and flow_allowed and !held) {
                    const wanted = @max(prefix, record.lines.len -| mutable_rows);
                    if (wanted > prefix and try record.stageFlow(self.allocator, wanted)) stop = wanted;
                }
                if (finalized) stop = record.lines.len;
            }
            var gap_wanted = if (stream_record) record.stream_written == 0 else prefix == 0;
            if (stream_record and record.stream_revised and (finalized or stop > prefix)) {
                // A real revision superseded released preview rows. Explain it
                // once, then re-open the transcript with exactly one gap.
                try putToneLine(writer, a, 1, "Response revised — earlier stream preview above", cols, theme.muted);
                try writer.writeAll("\r\n");
                transcript_rows += 1;
                record.stream_revised = false;
                gap_wanted = true;
            }
            if (finalized or stop > prefix) {
                if (gap_wanted) {
                    if (previous_kind) |prior| if (prior != .tool or record.kind != .tool) {
                        try putStyled(writer, 1, "");
                        try writer.writeAll("\r\n");
                        transcript_rows += 1;
                    };
                }
                if (heading.len != 0 and (gap_wanted or finalized)) {
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
                    if (!stream_record) _ = try record.stageFlow(self.allocator, 0);
                }
                prefix = stop;
            }
            frame_record.tail_line_start = lines.items.len;
            if (stream_record and record.lines.len == 0 and flow_allowed and record.stream.?.hasMetadataProgress())
                frame_record.metadata_staged = true;
            if (drafting or held or (finalized and stream_record and record.stream.?.limit != .none)) {
                const begin = prefix;
                if (begin == 0 and !(stream_record and record.stream_written != 0)) {
                    if (previous_kind) |prior| if (prior != .tool or record.kind != .tool) try lines.append(a, "");
                    if (heading.len != 0) {
                        const headings = try markdown.render(a, heading, .{ .columns = @max(1, cols), .max_lines = 32, .markdown = false, .tone = .muted });
                        try lines.appendSlice(a, headings.lines);
                    }
                }
                // The record's own rows start here; the leading gap/heading above
                // are layout decoration and never stand in for source rows.
                frame_record.tail_line_start = lines.items.len;
                try lines.appendSlice(a, record.lines[begin..]);
                // A finalized limited stream's tail is only a diagnostic, not
                // proof that its retained source was completely delivered.
                frame_record.tail_rows = if (drafting or held) lines.items.len - frame_record.tail_line_start else 0;
                if (begin != 0 or (stream_record and record.stream_written != 0)) flow_continuation = true;
            }
            // Display proof candidates, captured while this frame's render is
            // still pinned. Which of them survives is decided by the tail crop
            // below (a modal/crop never counts as visible).
            if (stream_record) {
                const stream = record.stream.?;
                frame_record.stream_full_end = stream.visibleSourceEnd();
                frame_record.stream_prefix_end = bodyShownEnd(stream, stop);
                frame_record.visible_source_end = if (finalized) frame_record.stream_prefix_end else 0;
                frame_record.visible_complete = finalized and stream.limit == .none and
                    stop == stream.visibleRows().len and stream.pendingBytes() == 0 and
                    frame_record.stream_prefix_end == stream.acceptedSourceEnd();
            } else {
                frame_record.visible_complete = finalized;
            }
            frame_record.stream_rows = record.pending_stream_rows;
            frame_record.output_candidate = record.pending_output;
            frame_record.flow_change = record.pending_flow_change;
            frame_record.flow_prefix = record.pending_flow_prefix;
            frame_record.flow_layout_valid = record.pending_flow_layout_valid;
            record.pending_flow_prefix = null;
            record.pending_flow_change = false;
            record.pending_flow_layout_valid = false;
            previous_kind = record.kind;
        }
        // A real transcript advance releases the borrowed prefix at its original
        // document coordinates before committing new rows. A menu-only redraw
        // instead keeps it reversible (no scrollback duplication).
        if (transcript_rows != 0) try releaseBorrowedPrefix(a, &out, self.frame_clear_end, &borrowed, &transcript_rows);
        {
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
                    if (self.groupTools() and (entry.caption.kind == .subagent or entry.caption.kind == .subagent_id)) continue;
                    const running = if (self.active_tool) |active| if (active.display_key) |identity| identity.eql(entry.key) else false else false;
                    try lines.append(a, if (running) try self.pendingCommand(a, @max(1, cols)) else try self.waitingCommand(a, entry, @max(1, cols)));
                }
                if (detached_active and !(self.active_tool.?.grouped)) try lines.append(a, try self.pendingCommand(a, @max(1, cols)));
            }
        }
        const thinking = if (self.show_reasoning and self.draft == null and self.tool_views.entries.items.len == 0 and self.active_tool == null) self.reasoning else null;
        var thinking_lines: []const []const u8 = &.{};
        if (thinking) |index| {
            const record = &self.records.items[index];
            if (!record.output) {
                // The thinking window is a real display obligation while it is
                // active: it is replaced by UX rules, never ignored silently.
                try record.layout(self.allocator, @max(1, cols));
                try frame_records.append(a, .{
                    .record_id = record.id,
                    .generation = record.stream_generation,
                    .reasoning = true,
                });
                thinking_lines = record.lines[record.lines.len -| reasoning_tail_rows..];
            }
        }
        // Transient reasoning follows the transcript without committing a gap
        // or reasoning text to scrollback. Its gap does not consume the latest row.
        const thinking_gap: usize = @intFromBool(thinking != null and thinking_lines.len != 0 and previous_kind != null);
        // A live draft already has one leading gap in lines. Keep it outside
        // the scrollable slice so a long draft cannot clip it next to the user.
        const live_gap: usize = @intFromBool(!flow_continuation and lines.items.len != 0 and lines.items[0].len == 0);
        const secret_destination = if (self.secret_mode) blk: {
            if (self.secret_provider) |id| break :blk try std.fmt.allocPrint(a, "API key for {s}\nBase URL: {s}\nSaved locally only; /model activates the saved key", .{ id.label(), id.baseUrl() });
            const secret_state = self.connection.current();
            if (secret_state.model.len == 0) break :blk try std.fmt.allocPrint(a, "API key for current endpoint\nBase URL: {s}\nEnter saves locally; no network request is made here", .{secret_state.base_url});
            break :blk try std.fmt.allocPrint(a, "API key for model {s}\nBase URL: {s}\nEnter saves locally; no network request is made here", .{ secret_state.model, secret_state.base_url });
        } else "";
        const secret_lines = if (self.secret_mode) try markdown.render(a, secret_destination, .{ .columns = @max(1, cols), .max_lines = 8, .markdown = false }) else empty_rendered;
        // The question already contains queue counts. Keep unrelated persistent
        // notices, but do not repeat the stop confirmation or queue summary.
        const modal_hint = if (modal_text != null) try self.hint(a, state) else "";
        const hint_line = if (modal_text == null) try self.footerHint(a, state) else if (std.mem.eql(u8, modal_hint, "Confirm stop")) "" else modal_hint;
        // Normal output keeps its empty gap; acknowledged shell-like idle
        // lines instead keep a single-row composer without extra redraw scroll.
        const hint_hash = std.hash.Wyhash.hash(0, hint_line);
        // Idle release keeps the one-row composer only while the hint it would
        // hide is exactly the one already ACKed. A newly published diagnostic
        // therefore keeps its own row instead of being dismissed by this Enter.
        const compact = (release_idle and !self.idle_notice_barrier and self.tail_hint_hash == hint_hash) or
            ((self.compact_composer and self.compact_hint_hash == hint_hash) and
                !self.busy and self.permission == null and !self.stop_open and !self.settings_open and
                !self.provider_open and !self.codex_open and self.resume_picker == null and self.model_picker == null and !self.commandMenuVisible() and
                !self.secret_mode and !self.secret_quarantine and thinking == null and composer_rows == 1);
        // The separator row is footprint, so it exists only while there is
        // something above it to separate: mutable body, an approval/secret
        // panel, pending reasoning, a candidate/menu popup, or canonical rows
        // released above this tail. Initial entry has none of these and writes
        // the composer alone at the terminal's existing row.
        const popup_requested = self.codex_open or self.stop_open or self.settings_open or self.provider_open or
            self.resume_picker != null or self.model_picker != null or (!release_idle and self.commandMenuVisible()) or
            (self.permission == null and queue_snapshot.preview_count != 0);
        const above_content = for (above) |line| {
            if (!std.mem.eql(u8, line, "\x1b[0m\x1b[K")) break true;
        } else false;
        // Restoring known blank borrowed rows does not create body content.
        const borrowed_content = for (borrowed) |line| {
            if (!std.mem.eql(u8, line, "\x1b[0m\x1b[K")) break true;
        } else false;
        const body_present = lines.items.len != 0 or borrowed_content or transcript_rows != 0 or above_content or
            self.permission != null or self.secret_mode or thinking != null or popup_requested;
        const separator: usize = @intFromBool(!compact and body_present and modal_text == null);
        const exit_separator = separator != 0 and hint_line.len == 0;
        const footer_rows: usize = if (compact) 1 else composer_rows + separator + @as(usize, @intFromBool(hint_line.len != 0));
        const body_limit = self.size.rows -| footer_rows;
        const candidate_limit = body_limit -| 1; // Separate candidates from conversation even in short windows.
        const model_state = state;
        const resume_rows = if (self.resume_picker) |*picker| try resume_picker_module.rows(a, picker, cols, candidate_limit) else resume_picker_module.Rows{};
        const picker_rows = if (self.model_picker) |*picker| try picker.rowsWithProviders(a, model_state.selection_name orelse model_state.model, model_state.context_limit, model_state.models, cols, candidate_limit, .{ .current = model_state.context_official, .models = model_state.model_context_official }, model_state.model_disabled, model_state.model_providers) else picker_module.Rows{ .lines = &.{}, .can_confirm = false };
        if (self.model_picker) |*picker| try picker.captureChoice(a, picker_rows.selected_choice);
        const provider_rows = if (self.provider_open) try provider_picker_module.rows(a, self.provider_picker, self.provider_choices, state.configured_providers, cols, candidate_limit) else provider_picker_module.Rows{ .lines = &.{} };
        self.frame_provider_generation = null;
        const settings_snapshot: settings_menu_module.Snapshot = .{
            .low_price_input_enabled = state.low_price_input_enabled,
            .decision_enabled = state.decision_enabled,
            .decision_model = state.decision_model,
            .image_enabled = state.image_enabled,
            .image_model = state.image_model,
            .memory_auto = state.memory_auto,
            .proxy_configured = state.proxy_configured,
            .proxy_address = state.proxy_address,
            .proxy_port = state.proxy_port,
            .proxy_model_count = state.proxy_models.len,
            .global_settings_available = state.global_settings_available,
            .limits = state.limits,
        };
        var settings_rows = if (self.settings_open and self.settings_value_picker != null) try settings_value_module.rows(a, self.settings_menu, self.settings_value_picker.?, cols, candidate_limit) else if (self.settings_open and self.proxy_open) try proxy_picker_module.rows(a, self.settings_menu, state.models, state.model_providers, state.proxy_models, state.proxy_configured, state.proxy_address, state.proxy_port, self.editor.bytes.items, cols, candidate_limit) else if (self.settings_open and self.proxy_sub_open) try settings_menu_module.proxyRows(a, self.settings_menu, settings_snapshot, cols, candidate_limit) else if (self.settings_open and self.settingsModelOpen()) try decision_picker_module.rows(a, self.settings_menu, self.settingsModels(state), state.model_providers, self.editor.bytes.items, cols, candidate_limit) else if (self.settings_open) try settings_menu_module.rows(a, self.settings_menu, settings_snapshot, cols, candidate_limit) else settings_menu_module.Rows{ .lines = &.{} };
        if (self.settings_value_picker) |picker| {
            settings_rows.can_confirm = settings_rows.can_confirm and text.width(settingsValueTitle(picker.key)) <= cols;
        }
        self.frame_settings_generation = null;
        self.frame_decision_fingerprint = null;
        self.frame_proxy_fingerprint = null;
        const menu_visible = !release_idle and self.commandMenuVisible();
        const menu_rows = if (menu_visible) try command_menu_module.rows(a, self.command_matches, self.command_menu.selected, cols, candidate_limit) else command_menu_module.Rows{ .lines = &.{} };
        if (menu_visible) self.command_menu.selected = @min(self.command_menu.selected, self.command_matches.len - 1);
        // All candidate menus share one bottom-pinned popup slot. Secondary
        // pickers must not replace the top of the transcript body.
        var queue_lines: std.ArrayList([]const u8) = .empty;
        if (self.permission == null and queue_snapshot.preview_count != 0) {
            const shown = @min(@min(@as(usize, 3), candidate_limit), queue_snapshot.preview_count);
            for (queue_snapshot.previews[queue_snapshot.preview_count - shown .. queue_snapshot.preview_count]) |entry| {
                var preview_bytes = entry.bytes;
                for (preview_bytes[0..entry.len]) |*byte_| {
                    if (byte_.* == '\n' or byte_.* == '\r' or byte_.* == '\t') byte_.* = ' ';
                }
                try queue_lines.append(a, try std.fmt.allocPrint(a, "{s} pending #{d}: {s}", .{
                    if (entry.kind == .steering) "Steering" else "FollowUp", entry.id, preview_bytes[0..entry.len],
                }));
            }
        }
        // A genuine hint occupies one of the three rows immediately above the
        // question; never let it push the plain preview farther away.
        const preview_limit = @as(usize, 3) - @intFromBool(hint_line.len != 0);
        const preview_count = if (modal_text != null and self.permission != null and !self.stop_open) @min(@min(preview_limit, candidate_limit), approval_lines.lines.len) else 0;
        const preview_start = @min(self.permission_scroll, approval_lines.lines.len -| preview_count);
        const preview = approval_lines.lines[preview_start .. preview_start + preview_count];
        const codex_view = state.codex_login;
        const codex_code = if (self.codex_generation != null and codex_view.generation == self.codex_generation.? and codex_view.status == .pending and validCodexCode(&codex_view)) codex_view.userCode() else "";
        const codex_popup = [_][]const u8{ corecodex.verification_url, if (codex_code.len != 0) codex_code else "Waiting for device code...", "Esc cancels" };
        const popup_lines: []const []const u8 = if (self.codex_open) &codex_popup else if (modal_text != null and self.stop_open) queue_lines.items else if (modal_text != null and self.permission != null) preview else if (self.settings_open) settings_rows.lines else if (self.provider_open) provider_rows.lines else if (self.model_picker != null) picker_rows.lines else if (self.resume_picker != null) resume_rows.lines else if (menu_visible) menu_rows.lines else queue_lines.items;
        const selected_line = if (self.codex_open or self.stop_open or self.permission != null) @as(?usize, null) else if (self.settings_open) settings_rows.selected_line else if (self.provider_open) provider_rows.selected_line else if (self.model_picker != null) picker_rows.selected_line else if (self.resume_picker != null) resume_rows.selected_line else menu_rows.selected_line;
        const checked_mask: u16 = if (self.stop_open) 0 else if (self.provider_open) provider_rows.checked_mask else if (self.model_picker != null) picker_rows.checked_mask else 0;
        const popup_gap: usize = @intFromBool(popup_lines.len != 0 and modal_text == null);
        const content_body_limit = body_limit -| (popup_lines.len + popup_gap);
        self.frame_model_epoch = null;
        self.frame_model_generation = null;
        self.frame_resume_generation = null;
        // Reasoning resumes into its own downward window. A closed popup,
        // approval or secret prompt may have borrowed ACKed rows above this
        // tail; put them back at their original coordinates before the window
        // can paint over them. They join the tail as an ordinary transcript
        // prefix, so this frame defers (thinking_deferred) and the window
        // appears on the next complete ACK.
        const reasoning_resumes = thinking != null and popup_lines.len == 0 and
            self.permission == null and !self.secret_mode and !self.secret_quarantine;
        if (reasoning_resumes or modal_text != null) try releaseBorrowedPrefix(a, &out, self.frame_clear_end, &borrowed, &transcript_rows);
        // Transient reasoning owns a downward-growing window inside the tail. It
        // never borrows ACKed rows, so the committed user row above it is never
        // painted over. A pending canonical row in the same frame would also
        // grow the tail; defer the window to the next fresh frame instead of
        // committing reasoning rows. The initial tail==0 screen and an abandoned
        // tail keep their baseline geometry.
        const thinking_overlay = thinking != null and transcript_rows == 0 and history_valid and
            self.tail_height != 0 and !self.abandon_tail and !release_idle;
        const thinking_deferred = thinking != null and !thinking_overlay and
            self.tail_height != 0 and !self.abandon_tail;
        const show_thinking = thinking != null and !thinking_deferred;
        self.frame_delivery_reasoning = show_thinking;
        const overlay_visible = self.codex_open or self.stop_open or self.permission != null or popup_lines.len != 0 or menu_visible or
            self.resume_picker != null or self.model_picker != null or self.provider_open or self.settings_open;
        const wanted_body = if (self.secret_mode) @min(body_limit, secret_lines.lines.len) else if (show_thinking) @min(thinking_gap + @min(reasoning_tail_rows, thinking_lines.len), content_body_limit) else @min((if (overlay_visible) @as(usize, 0) else borrowed.len) + lines.items.len, content_body_limit);
        const wanted_rows = @min(self.size.rows, footer_rows + popup_lines.len + popup_gap + wanted_body);
        // Reuse the ACKed footprint when content contracts. This keeps the
        // composer at its acknowledged row without inventing a full-screen
        // tail or evicting already committed transcript rows.
        const anchored = !release_idle and !self.abandon_tail and (self.tail_bottom or self.tail_relative) and
            self.tail_size.columns == self.size.columns and self.tail_size.rows == self.size.rows;
        const old_normal = self.tail_height -| if (self.natural_flow and anchored) self.tail_menu_extra else 0;
        const rows = @min(self.size.rows, @max(wanted_rows, if (anchored) old_normal -| transcript_rows else 0));
        // Only a popup or approval grows UP into exact ACKed transcript rows,
        // without pushing duplicate content into native scrollback. Keep those
        // restoration rows when returning to the normal live tail. Reasoning
        // never borrows: its window grows downward instead.
        // Unknown/reflowed/partially written rows never grant upward ownership.
        // Menus may borrow ACKed rows for reversible overlays. Inline
        // confirmations instead grow forward and leave the conversation visible.
        const borrow_count = if (overlay_visible and modal_text == null and transcript_rows == 0)
            @min(rows -| self.tail_height, above.len)
        else
            0;
        self.frame_borrow_rows = borrow_count;
        // Borrowed restoration rows and real content are never menu budget.
        // Keep the prior ordinary footprint even while its canonical prefix
        // advances, and account for newly borrowed rows separately.
        const root_menu = menu_visible and !self.codex_open and !self.stop_open and self.permission == null and !self.secret_mode and !self.secret_quarantine;
        // Project the ordinary footer, not the expanded menu footer. The menu
        // can suppress a previously ACKed hint, so its hint hash cannot decide
        // whether the compact composer will remain compact after dismissal.
        const normal_compact = root_menu and self.compact_composer and
            !self.busy and self.permission == null and !self.stop_open and !self.settings_open and
            !self.provider_open and !self.codex_open and self.model_picker == null and
            !self.secret_mode and !self.secret_quarantine and thinking == null and composer_rows == 1;
        const normal_popup = self.codex_open or self.stop_open or self.settings_open or self.provider_open or
            self.resume_picker != null or self.model_picker != null or (self.permission == null and queue_snapshot.preview_count != 0);
        const normal_body_present = lines.items.len != 0 or borrowed_content or transcript_rows != 0 or above_content or
            self.permission != null or self.secret_mode or thinking != null or normal_popup;
        const normal_footer = if (!root_menu) footer_rows else if (normal_compact) @as(usize, 1) else composer_rows + @as(usize, @intFromBool(normal_body_present)) + @as(usize, @intFromBool(hint_line.len != 0));
        const normal_content = normal_footer + @min(self.size.rows -| normal_footer, borrowed.len + lines.items.len);
        const normal_baseline = @max(normal_content, @max(normal_footer, (old_normal -| transcript_rows) +| borrow_count));
        self.frame_menu_extra = if (self.natural_flow and root_menu) rows -| normal_baseline else 0;
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
        if (borrowed.len != 0) {
            var combined: std.ArrayList([]const u8) = .empty;
            try combined.appendSlice(a, borrowed);
            try combined.appendSlice(a, active_lines);
            lines = combined;
        }
        // Record tail indices were captured before any borrowed rows were
        // prepended to the mutable tail; keep the coordinate shift explicit.
        const tail_row_shift: usize = if (borrowed.len != 0) borrowed.len else 0;
        const needs_anchor = !release_idle and !anchored;
        const origin = if (needs_anchor and self.frame_offset == 0 and self.tail_height == 0 and !self.abandon_tail) blk: {
            const value = self.entry_origin orelse break :blk null;
            if (value.row >= self.size.rows or value.size.rows != self.size.rows or value.size.columns != self.size.columns) break :blk null;
            break :blk value;
        } else null;
        const height = transcript_rows + rows;
        const visible_height = @min(self.size.rows, height);
        const scroll = if (origin) |value| visible_height -| (self.size.rows - 1 - value.row) else 0;
        const pad = if (origin) |value| (self.size.rows - visible_height) -| (value.row + 1 - scroll) else 0;
        var next_above: std.ArrayList([]const u8) = .empty;
        // Only explicitly blanked entry padding (or the conservative fallback's
        // blank viewport) can be borrowed, and only after a complete ACK.
        if (needs_anchor and !self.natural_flow) {
            const blank_count = @min(200, if (origin != null) pad else self.size.rows -| visible_height);
            for (0..blank_count) |_| try next_above.append(a, "\x1b[0m\x1b[K");
        } else try next_above.appendSlice(a, above);
        if (release_idle) {
            const old_rows = self.tail_snapshot.?.rows;
            try next_above.appendSlice(a, old_rows[0 .. old_rows.len - 1]);
            for (0..break_count) |_| try next_above.append(a, idle_prompt);
        }
        if (transcript_rows != 0) {
            var split = std.mem.splitSequence(u8, out.written()[self.frame_clear_end..], "\r\n");
            for (0..transcript_rows) |_| try next_above.append(a, split.next() orelse return error.InvalidTailFrame);
        }
        const above_count = @min(@min(next_above.items.len, self.size.rows -| rows), 200 -| borrowed.len);
        var next_history: ?tail_frame.MenuHistory = try tail_frame.MenuHistory.capture(self.allocator, next_above.items[next_above.items.len - above_count ..], borrowed);
        errdefer if (next_history) |*history| history.deinit();

        // Without same-geometry ownership, natural flow starts on the next
        // native row. Legacy layout establishes a bottom anchor instead.
        if (needs_anchor and self.natural_flow) {
            const prefix_len = (terminal_module.sync_begin ++ "\x1b[?25l\r").len;
            var rebuilt: std.Io.Writer.Allocating = .init(a);
            try rebuilt.writer.writeAll(out.written()[0..prefix_len]);
            try rebuilt.writer.writeAll("\r\n");
            try rebuilt.writer.writeAll(out.written()[prefix_len..]);
            out = rebuilt;
            self.frame_clear_end += 2;
        } else if (needs_anchor) {
            const reserve = @min(self.size.rows -| 1, (transcript_rows + rows) -| 1);
            const prefix_len = (terminal_module.sync_begin ++ "\x1b[?25l\r").len;
            var rebuilt: std.Io.Writer.Allocating = .init(a);
            try rebuilt.writer.writeAll(out.written()[0..prefix_len]);
            try rebuilt.writer.print("\x1b[{d}B", .{self.size.rows});
            if (origin != null) {
                for (0..scroll) |_| try rebuilt.writer.writeAll("\r\n");
                if (reserve != 0) try rebuilt.writer.print("\x1b[{d}A", .{reserve});
                if (pad != 0) try rebuilt.writer.print("\x1b[{d}A", .{pad});
                for (0..pad) |_| try rebuilt.writer.writeAll("\x1b[0m\x1b[K\r\n");
            } else {
                for (0..self.size.rows) |_| try rebuilt.writer.writeAll("\r\n");
                if (reserve != 0) try rebuilt.writer.print("\x1b[{d}A", .{reserve});
            }
            try rebuilt.writer.writeAll("\r");
            const inserted = rebuilt.written().len - prefix_len;
            try rebuilt.writer.writeAll(out.written()[prefix_len..]);
            out = rebuilt;
            self.frame_clear_end += inserted;
        }

        // Build the complete candidate tail before choosing full or sparse output.
        // Its bytes also provide recovery if resize interrupts a sparse frame.
        // Rows this frame returns belong to the previous ACKed footprint only:
        // a smaller floating footprint is contracted after the tail, at the same
        // width and geometry. Differential frames never leave rows behind.
        const reclaimable = anchored;
        const vacated = if (reclaimable) (self.tail_height + borrow_count) -| (transcript_rows + rows) else 0;
        writer = &tail_out.writer;
        var cursor_offset: usize = 0;
        var cursor_rows_up: usize = 0;
        var rendered_composer_rows: usize = 1;
        // First mutable-tail row index this frame really painted. Anything before
        // it was cropped (or replaced by a modal) and is never claimed visible.
        var visible_from: usize = std.math.maxInt(usize);
        // 终端太小时只显示提示，避免布局越界。
        // 审批标题之外至少留一行正文；尺寸不足不属于永久的 clipped 状态。
        const hides_approval_id = if (self.permission) |permission| !self.approvalFits(permission.id, permission.choice) else false;
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
            visible_from = try self.drawTailBody(writer, .{
                .body_rows = body_rows,
                .content_body_rows = content_body_rows,
                .secret_lines = secret_lines,
                .show_thinking = show_thinking,
                .thinking_lines = thinking_lines,
                .thinking_gap = thinking_gap,
                .borrowed_count = borrowed.len,
                .live_gap = live_gap,
                .lines = lines.items,
            });

            // Explicit empty separator belongs to the tail and is repaired on
            // every frame, including short histories and narrow candidate windows.
            if (popup_gap != 0 and body_rows > popup_span)
                try putStyled(writer, 1 + content_body_rows, "");
            // Shared provider palette for root, provider and model candidates.
            for (0..popup_span) |line| {
                const tone = if (selected_line == line) theme.accent else theme.muted;
                if (self.permission != null and !self.stop_open) {
                    try putStyled(writer, 1 + content_body_rows + line, popup_lines[line]);
                } else {
                    try putCandidateLine(writer, a, 1 + content_body_rows + @min(popup_gap, body_rows -| popup_span) + line, popup_lines[line], cols, tone, checked_mask & (@as(u16, 1) << @intCast(line)) != 0);
                }
            }
            if (popup_span == popup_lines.len) {
                if (!self.stop_open and self.settings_open and settings_rows.can_confirm and
                    (!self.proxy_address_open or self.addressFits(cols)))
                {
                    self.frame_settings_generation = self.settings_menu.generation;
                    if (self.settingsModelOpen()) self.frame_decision_fingerprint = decision_picker_module.fingerprint(self.settingsModels(state), state.model_providers);
                    if (self.proxy_open) self.frame_proxy_fingerprint = proxy_picker_module.fingerprint(state.models, state.model_providers, state.proxy_models, state.proxy_configured, state.proxy_address, state.proxy_port);
                }
                if (!self.stop_open and self.provider_open and provider_rows.can_confirm) self.frame_provider_generation = self.provider_picker.generation;
                if (self.model_picker) |picker| {
                    if (!self.stop_open and picker_rows.can_confirm) {
                        self.frame_model_epoch = self.model_epoch;
                        self.frame_model_generation = picker.generation;
                    }
                }
                if (!self.stop_open and !self.codex_open and self.permission == null and !self.secret_mode and !self.secret_quarantine and !self.settings_open and !self.provider_open and self.model_picker == null) {
                    if (self.resume_picker) |picker| if (resume_rows.can_confirm) {
                        self.frame_resume_generation = picker.generation;
                    };
                }
                if (!self.stop_open and menu_visible and menu_rows.can_confirm) self.frame_command_generation = self.command_menu.generation;
            }

            // Keep the existing separator above the hint, never between the
            // hint and the first composer row. With no hint it remains the gap.
            if (!compact and separator != 0) try putLine(writer, a, rows - composer_rows - @intFromBool(hint_line.len != 0), "", cols);
            if (!compact and hint_line.len != 0) try putToneLine(writer, a, rows - composer_rows, hint_line, cols, theme.muted);

            const cursor = try self.drawComposer(&tail_out, a, cols, rows, composer_rows, prepared, modal_text != null);
            cursor_offset = cursor.offset;
            cursor_rows_up = cursor.rows_up;
            rendered_composer_rows = cursor.rows;
            if (modal_fits and self.stop_open) self.frame_stop = self.stop_generation;
            if (modal_fits and !self.stop_open and self.permission != null and popup_span == preview.len and (approval_lines.lines.len == 0 or preview.len != 0)) {
                self.frame_permission = self.permission.?.id;
                self.frame_permission_choice = self.permission.?.choice;
                self.frame_delivery_shown = true;
            }
        }

        // Resolve the per-record delivery proof now that the real crop is known.
        // A record's mutable rows only count when the layout actually wrote all
        // of them; otherwise only its frozen prefix (native scrollback) is proof.
        resolveDeliveryCoverage(frame_records.items, tail_row_shift, visible_from, self.frame_delivery_reasoning);

        // Contract from the LAST WRITTEN row BEFORE any cursor suffix. A
        // multiline composer suffix already moved the cursor up to its first
        // line; cleaning from there would erase the composer's own lower rows.
        // Save the suffix, truncate the rows, clean the owned vacated footprint,
        // then replay the cursor suffix (and keep it in Snapshot.cursor_suffix).
        if (vacated != 0) {
            const saved_suffix = try a.dupe(u8, tail_out.written()[cursor_offset..]);
            tail_out.shrinkRetainingCapacity(cursor_offset);
            try tail_frame.emitVacatedRows(&tail_out.writer, vacated);
            try tail_out.writer.writeAll(saved_suffix);
        }
        // Include release in the trusted cursor suffix so full/sparse/recovery
        // tails all close synchronization; cursor-show remains the final marker.
        try writer.writeAll(terminal_module.sync_end ++ "\x1b[?25h");
        const snapshot_allowed = self.permission == null and self.resume_picker == null and self.model_picker == null and !self.provider_open and !self.settings_open and !menu_visible and !self.secret_mode and !self.secret_quarantine;
        var candidate = if (snapshot_allowed) try tail_frame.Snapshot.capture(self.allocator, tail_out.written(), rows, cursor_offset) else null;
        errdefer if (candidate) |*snapshot| snapshot.deinit();
        const can_diff = anchored and snapshot_allowed and
            self.tail_size.columns == self.size.columns and self.tail_size.rows == self.size.rows and
            self.tail_snapshot != null and candidate != null;
        const growing = can_diff and !canonical_output and transcript_rows != 0 and
            transcript_rows + rows >= self.tail_height;
        const sparse = can_diff and transcript_rows == 0 and self.tail_height == rows;
        var growth_out: std.Io.Writer.Allocating = .init(a);
        writer = &out.writer;
        if (growing) {
            // Compare at unchanged document indices from the ACKed tail origin.
            // CRLF past the old bottom appends natively (scrolling only once the
            // physical bottom is actually reached). No sliding-window DL.
            const released = try a.alloc([]const u8, transcript_rows);
            var split = std.mem.splitSequence(u8, out.written()[self.frame_clear_end..], "\r\n");
            for (released) |*line| line.* = split.next() orelse return error.InvalidTailFrame;
            try growth_out.writer.writeAll(out.written()[0..self.frame_clear_end]);
            try candidate.?.emitGrowingDiff(&growth_out.writer, &self.tail_snapshot.?, released);
        } else if (sparse) {
            // Delete-line repair shifts only cursor..bottom, so it needs the
            // ACKed tail to be proven at the physical bottom. A floating tail
            // keeps the plain relative row diff; modal/ACK/resize gates stay above.
            if (self.tail_bottom and self.draft == null)
                try candidate.?.emitBottomDiff(writer, &self.tail_snapshot.?)
            else
                try candidate.?.emitDiff(writer, &self.tail_snapshot.?);
        } else {
            try writer.writeAll(tail_out.written());
        }

        // frame 指向 arena 内存，arena 所有权交给 frame_arena，直到这帧写完。
        self.frame_idle_breaks = break_count;
        self.frame_idle_prefix_end = if (release_idle) self.frame_clear_end else 0;
        self.frame_hint_hash = hint_hash;
        self.frame_sparse = sparse or growing;
        self.frame_tail_snapshot = candidate;
        self.frame_menu_history = next_history;
        next_history = null;
        self.frame = if (growing) growth_out.written() else out.written();
        self.frame_offset = 0;
        self.frame_records = frame_records.items;
        self.frame_delivery_epoch = self.delivery_epoch;
        self.frame_delivery_sequence = self.delivery_admitted;
        self.frame_arena = arena;
        self.frame_height = rows;
        self.frame_cursor_rows_up = cursor_rows_up;
        self.frame_composer_rows = rendered_composer_rows;
        self.frame_exit_separator = exit_separator and self.size.rows >= 7 and cols >= 8 and !hides_approval_id;
        self.frame_size = self.size;
        if (self.natural_flow) {
            const last_row = self.size.rows -| 1;
            const floor = if (needs_anchor)
                @min(last_row, (if (origin) |value| @as(usize, value.row) else 0) +| height)
            else if (release_idle)
                @min(last_row, self.tail_end_floor +| @as(usize, break_count) +| (rows -| 1))
            else blk: {
                const previous = self.tail_height +| borrow_count;
                const endpoint = if (height >= previous)
                    self.tail_end_floor +| (height - previous)
                else
                    self.tail_end_floor -| (previous - height);
                break :blk @min(last_row, endpoint);
            };
            self.frame_end_floor = floor;
            self.frame_relative = true;
            self.frame_bottom = floor == last_row and self.terminal.exactPhysicalRows(self.size.rows);
        } else {
            self.frame_end_floor = 0;
            self.frame_relative = false;
            self.frame_bottom = true;
        }
        self.frame_fresh = true;
        self.frame_changed = self.display_changed;
        self.display_changed = false;
        self.resize_waiting = false;
        self.abandon_tail = false;
    }
};

/// Resolve every staged record's display proof once the frame's real tail crop
/// is known. `shift` moves the record coordinates into the final mutable tail
/// (borrowed ACKed rows are prepended); `visible_from` is the first tail row the
/// layout actually painted. Rows above it were cropped or replaced by a modal,
/// and frozen prefix rows are always in native scrollback by construction.
fn resolveDeliveryCoverage(entries: []FrameRecord, shift: usize, visible_from: usize, reasoning_shown: bool) void {
    for (entries) |*entry| {
        if (entry.reasoning) {
            // A rolling thinking window is complete for ACK purposes as soon as
            // its newest rows are the ones on screen.
            entry.visible_complete = reasoning_shown;
            entry.visible_source_end = 0;
            continue;
        }
        if (entry.metadata_staged and entry.tail_line_start + shift < visible_from)
            entry.metadata_staged = false;
        if (entry.visible_complete) continue;
        if (entry.tail_rows != 0 and entry.tail_line_start + shift >= visible_from) {
            entry.visible_complete = true;
            entry.visible_source_end = entry.stream_full_end;
        } else if (entry.stream_full_end != 0) {
            entry.visible_source_end = entry.stream_prefix_end;
        }
    }
}

fn compactCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "/compact") or std.mem.startsWith(u8, command, "/compact ") or std.mem.startsWith(u8, command, "/compact\t");
}

fn modelCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "/model") or std.mem.startsWith(u8, command, "/model ") or std.mem.startsWith(u8, command, "/model\t");
}

/// True when the slash arguments must stay masked. Only non-empty arguments of
/// no-argument or unknown commands, /login credentials and malformed values are
/// sensitive; ordinary supported argument shapes stay visible and editable.
fn sensitiveArguments(name: []const u8, rest: []const u8) bool {
    const args = std.mem.trim(u8, rest, " \t\r\n");
    if (args.len == 0) return false; // Trailing whitespace alone is never sensitive.
    if (std.mem.findAny(u8, args, "\r\n") != null) return true; // Commands are single-line.
    if (std.mem.eql(u8, name, "/cd")) return args.len > 4096;
    if (std.mem.eql(u8, name, "/model")) return !picker_module.manualName(args);
    if (std.mem.eql(u8, name, "/ls")) return !listArgumentsValid(args);
    if (std.mem.eql(u8, name, "/attach") or std.mem.eql(u8, name, "/attch") or std.mem.eql(u8, name, "/close"))
        return !sessionArgumentsValid(name, args);
    if (std.mem.eql(u8, name, "/queue")) return !std.mem.eql(u8, args, "resume");
    // /login, /compact, /help, /detach, /exit and unknown commands take no
    // arguments; non-empty text cannot be told apart from an accidental paste.
    return true;
}

fn decimalWord(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

/// Tokenizes into the same bounded shape the management parser accepts.
fn splitQuiet(value: []const u8, out: *[4][]const u8) usize {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, value, " \t");
    while (it.next()) |word| {
        if (count == out.len) return out.len + 1;
        out[count] = word;
        count += 1;
    }
    return count;
}

fn listArgumentsValid(args: []const u8) bool {
    var words: [4][]const u8 = undefined;
    const count = splitQuiet(args, &words);
    if (count > words.len) return false;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const word = words[index];
        if (std.mem.eql(u8, word, "--running")) continue;
        if (std.mem.eql(u8, word, "--page") and index + 1 < count and decimalWord(words[index + 1])) {
            index += 1;
            continue;
        }
        if (decimalWord(word)) continue;
        return false;
    }
    return true;
}

fn sessionArgumentsValid(name: []const u8, args: []const u8) bool {
    var words: [4][]const u8 = undefined;
    const count = splitQuiet(args, &words);
    if (count == 0 or count > words.len) return false;
    const flag = if (std.mem.eql(u8, name, "/close")) "--force" else "--takeover";
    var id: ?[]const u8 = null;
    for (words[0..count]) |word| {
        if (std.mem.eql(u8, word, flag)) continue;
        if (word.len != 0 and word[0] == '-') return false;
        if (id != null) return false;
        id = word;
    }
    return (id orelse return false).len <= 256;
}

/// 输入行的显示副本：Tab 固定展开为四个空格，测宽、裁剪与输出共用；不修改提交字节。
/// Prefill text for the proxy address editor; empty means no endpoint exists.
fn endpointText(buffer: []u8, state: Connection.State) []const u8 {
    const address = state.proxy_address orelse return "";
    if (state.proxy_port == 0) return address;
    if (std.mem.findScalar(u8, address, ':') != null)
        return std.fmt.bufPrint(buffer, "[{s}]:{d}", .{ address, state.proxy_port }) catch address;
    return std.fmt.bufPrint(buffer, "{s}:{d}", .{ address, state.proxy_port }) catch address;
}

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

// 测试用 Ui 构造器：使用 testing allocator，运行时与终端字段为 undefined（测试中不会访问）。

// Ordinary one-shot successes live in the display transcript, not the footer.
// Keep the wording assertions on that record so an actionable footer can
// still own errors, approvals and pending queue state at the same time.

// Prior shell output with the cursor left on the physical bottom row, so the
// floating composer starts where a real terminal prompt stopped. No text
// reflow or native-viewport position is inferred from this fixture.

// Absolute row whose cells start with `prefix`; popup rows are only guaranteed
// to be adjacent and above the composer, not to sit at a fixed screen row.

// Check actual retained rows, including user output pushed into scrollback.

// Shared plain renderer reference: the exact Writer settings the bounded tail
// uses, so a live tail can be compared byte-for-byte at a given width.

// Compare physical glyph bytes while allowing equivalent SGR boundaries at a
// streaming checkpoint. Frame bytes themselves are checked separately below.

// Test fixture: commit real canonical rows through complete frames so the
// ACKed above rows are physically on the replay screen and the live tail is
// reduced to a compact footer. Returns each marker exactly once on screen.

// 验证：任务完成时 complete 会先排空 bridge 中残留的事件，canonical 内容覆盖草稿，最终结果不丢失。

// 验证：即使字节未超过 bridge 预算，超高的审批预览也会被截断，并且只能拒绝。

// 验证：审批必须与屏幕上真正显示的请求一致，且粘贴内容不能批准。

// 验证：粘贴内容中嵌入的结束标记不能伪造一次“允许”。

// 验证：canonical 推理内容保留显式的显示截断标记。

// ---- Remote adapter focused tests -------------------------------------------
// A fake backend proves UI-side ownership rules without sockets, daemon code or
// a real Runtime: the client owns tasks/queues/approvals, and the UI only
// submits, acknowledges and renders.
