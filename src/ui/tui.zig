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
const record_limit = 128 * 1024;

/// Thinking is a bounded rolling display window, not a transcript: three visible
/// rows over a fixed conservative retained budget (the tail clamps terminals to
/// 512 columns). The canonical provider/reasoning history is a separate owner.
const reasoning_tail_rows = 3;
const reasoning_tail_bytes = 64 * 1024;

/// 显示记录的种类：用户输入、助手正文、推理内容、工具事件、系统提示。
const Kind = enum { user, assistant, reasoning, tool, notice };

/// 对话区中的一条显示记录。body 保存原始 UTF-8 文本；渲染结果缓存在 cache 的 arena 中。
const Record = struct {
    id: u64 = 0,
    stream_generation: u64 = 0,
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
    /// Exact full-prefix comparison for the current layout cache; null means
    /// unknown. Reset by invalidate() and by every committed-prefix change, so a
    /// repaint of an unchanged cache never rescans all released rows.
    flow_match: ?bool = null,
    /// pending_flow_prefix rows were taken from the still-current lines cache.
    pending_flow_layout_valid: bool = false,
    /// Test-only evidence that a cached comparison skipped the exact scan.
    /// Outside test builds this is void: production ships no tracking storage.
    flow_scan_count: if (@import("builtin").is_test) usize else void = if (@import("builtin").is_test) 0 else {},
    /// 原始文本（UTF-8），受 record_limit 约束。
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
    stream_columns: usize = 0,
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

    /// 追加文本。超出 record_limit 时截断，并在截断后忽略后续追加。
    fn resetStream(self: *Record) !void {
        self.stream_generation +%= 1;
        self.pending_output = false;
        if (self.stream) |stream| stream.destroy();
        self.stream = null;
        self.stream_written = 0;
        self.pending_stream_rows = 0;
        self.stream_columns = 0;
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
                self.stream_columns = columns;
            }
            self.stream.?.append(bytes) catch |err| {
                // A failed parse/limit must not lose the bytes already accepted;
                // Body retains them and reports a sticky display limit.
                self.invalidate();
                return err;
            };
            if (!self.mirror_full) {
                var end = @min(record_limit - self.body.items.len, bytes.len);
                while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
                try self.body.appendSlice(a, bytes[0..end]);
                self.mirror_full = end < bytes.len;
            }
            self.invalidate();
            return;
        }
        // Static content changes invalidate an older frame's output candidate;
        // incremental reasoning and assistant streams retain their owner generation.
        if (self.kind != .reasoning) self.stream_generation +%= 1;
        self.pending_output = false;
        self.delivery_visible = 0;
        self.delivery_complete = false;
        if (self.kind == .reasoning) {
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
    /// Idle, joined-owner callbacks; no network calls. Model selection stays
    /// local; effort saves the project preference, never global defaults.
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
    if (connection.async_actions) |actions| try terminal.setNotification(actions.wake_fd);
    var ui = Ui{ .allocator = a, .io = io, .connection = connection, .bridge = bridge, .cancel = cancel, .terminal = &terminal, .editor = .{ .allocator = a }, .job = .{ .runtime = undefined, .cancel = cancel, .prompt = "" } };
    defer ui.deinit();

    // Initial entry anchors the composer at the physical bottom without an
    // alternate screen or replaying pre-existing terminal history.
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
const DeliveryReceipt = struct { id: u64, generation: u64, reasoning: bool = false, source: bool = true };

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
    decision_open: bool = false,
    image_open: bool = false,
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
    /// 已有旧记录被丢弃，标题栏会提示 older display clipped。
    dropped_display: bool = false,
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

    /// 用户请求退出；若任务仍在运行，会等它结束后再退出。
    want_exit: bool = false,
    ctrl_d_exit: bool = false,
    /// Idle-exit cleanup must never consume a tail from a submitted conversation.
    has_submitted: bool = false,
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
    frame_size: terminal_module.Size = .{ .columns = 0, .rows = 0 },
    /// Rows borrowed from ACKed transcript rows for an overlay in this frame.
    frame_borrow_rows: usize = 0,
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
    /// Staged proof for `tail_bottom`; promoted only by finishFrame's ACK.
    frame_bottom: bool = false,
    /// Published only by a complete ACK, relative to the tail's bottom row.
    tail_cursor_rows_up: usize = 0,
    tail_composer_rows: usize = 1,
    tail_size: terminal_module.Size = .{ .columns = 0, .rows = 0 },
    abandon_tail: bool = false,
    /// 最近一次读取的终端尺寸。
    size: terminal_module.Size = .{ .columns = 0, .rows = 0 },

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
        self.detachInbox();
        self.inbox.deinit();
        if (self.prompt) |prompt| self.allocator.free(prompt);
        self.clearPermission();
        self.clearActiveTool();
        self.clearToolCaptions();
        self.tool_calls.deinit(self.allocator);
        self.tool_views.deinit(self.allocator);
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
            return null;
        };
        const epoch = if (purpose == .approve) (if (self.permission) |permission| permission.epoch else self.remote_epoch) else self.remote_epoch;
        const ticket = channel.start(epoch, action) catch |err| {
            self.allocator.free(original);
            self.notice = session_client.describe(err);
            return null;
        };
        slot.* = .{ .ticket = ticket, .purpose = purpose, .original_editor = original, .editor_revision = self.editor_revision, .epoch = epoch, .permission_id = if (self.permission) |permission| permission.id else null, .previous_effort = self.connection.current().reasoning_effort, .settings_generation = self.settings_menu.generation, .stop_instance = self.stop_instance };
        if (purpose == .open_stop or purpose == .release_stop) self.async_stop_intent = ticket;
        self.parser.stop_feed = true;
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
            self.notice = "Display notice unavailable; inspect operation state";
            self.requestDraw();
            return;
        };
        self.notice = "Ready";
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
            },
            .approve => {
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
                self.effort_flash = .{ .level = next, .until_ms = self.clock_ms +| 2000 };
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
            self.remote_epoch = snapshot.control_epoch;
            self.resetSessionView(snapshot);
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

    fn hasUnmetFence(self: *const Ui, record_id: u64) bool {
        for (self.delivery_fences.items) |fence| {
            if (!fence.proven and fence.record_id == record_id) return true;
        }
        return false;
    }

    /// Authoritative REMOVAL (withdrawn canonical text, reasoning retired by UX,
    /// or a guarded eviction): the sequence keeps its ordering but the record is
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

    // A tool_result may add caption, local output and truncation notice (3).
    // assistant_committed can add a new body and withdrawal/truncation notice
    // (at most 2). Each mirror is capped at record_limit (128 KiB), including
    // formatted command output; reserve three full mirrors, not just wire bytes.
    const event_record_reserve = 3;
    const event_byte_reserve = event_record_reserve * record_limit;

    fn displayBackpressured(self: *const Ui) bool {
        // Live delivery fences are the first bound: at capacity no further event
        // may be polled, so an unprovable prefix is never dropped or fabricated.
        // Only proof that has NOT been handed over counts against capacity.
        if (self.unenqueuedFenceCount() >= delivery_fence_capacity) return true;
        var count: usize = self.records.items.len;
        var bytes: usize = 0;
        for (self.records.items) |record| {
            bytes += record.body.items.len;
        }
        for (self.records.items) |record| {
            if (!record.output) if (record.stream) |stream| {
                if (stream.pendingBytes() >= 64 * 1024 or stream.windowBytes() >= 128 * 1024) return true;
            };
        }
        for (self.async_pending) |pending| if (pending) |value| {
            if (value.record) |record| {
                count += 1;
                bytes += record.body.items.len;
            }
        };
        return count + event_record_reserve > 64 or bytes + event_byte_reserve > 1024 * 1024;
    }

    fn reclaimDisplayCapacity(self: *Ui) void {
        while (self.displayBackpressured() and self.canEvictOldest()) {
            self.removeRecord(0);
            self.dropped_display = true;
        }
    }

    /// Drain at most the existing per-tick event budget. The first poll may
    /// fetch one page; subsequent polls only consume buffered items.
    fn pumpDisplay(self: *Ui) !void {
        self.retryDeliveryAck();
        for (0..64) |index| {
            // A remote terminal must settle before this batch polls the item that
            // follows it: finished(task 1) plus state/text(task 2) can share one
            // read, and the next task must not be closed as task 1's residue.
            if (self.remote() != null) {
                try self.finishReadyTask();
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
            self.reclaimDisplayCapacity();
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
                    if (stream.windowBytes() != 0 or stream.carry_len != 0 or stream.held_cr or record.pending_stream_rows != 0)
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
        return client.snapshot().attached and !client.snapshot().available;
    }

    fn adoptRemoteActivity(self: *Ui, snapshot: *const session_client.Snapshot) void {
        const syncing = snapshot.attached and !snapshot.available;
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
    fn resetSessionView(self: *Ui, snapshot: *const session_client.Snapshot) void {
        // The owner's snapshot is the only source of epoch identity; nothing is
        // read from a local Runtime for an attached remote session.
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
        self.dropped_display = false;
        self.last_terminal = null;
        self.mode = null;
        self.display = .{};
        self.model_flow = .{};
        self.has_submitted = false;
        self.poisoned = false;
        self.want_exit = false;
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
        self.bridge.reset() catch {};
        // A new epoch may restart approval ids; rebase only while nothing is
        // pending so a stale decision cannot approve the first new request.
        const host = self.bridge.host();
        if (host.rebase_permission_fn) |rebase| rebase(host.context) catch {};
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
        const is_list = std.mem.eql(u8, name, "/ls");
        const is_cd = std.mem.eql(u8, name, "/cd");
        const is_attach = std.mem.eql(u8, name, "/attach") or std.mem.eql(u8, name, "/attch");
        const is_detach = std.mem.eql(u8, name, "/detach");
        const is_exit = std.mem.eql(u8, name, "/exit");
        const is_close = std.mem.eql(u8, name, "/close");
        if (!(is_list or is_cd or is_attach or is_detach or is_exit or is_close)) return false;
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

    fn applyManage(self: *Ui, client: session_client.Client, request: session_client.Manage) void {
        if (self.connection.async_actions != null) {
            _ = self.beginAsync(.{ .manage = request }, .manage);
            return;
        }
        var outcome = client.manage(self.allocator, request) catch |err| {
            self.notice = session_client.describe(err);
            self.requestDraw();
            return;
        };
        defer outcome.deinit(self.allocator);
        self.acceptManage(&outcome, false);
    }

    fn acceptManage(self: *Ui, outcome: *session_client.Outcome, preserve_editor: bool) void {
        const leaving = outcome.exit;
        if (outcome.switched) if (self.remote()) |client| {
            if (preserve_editor) {
                const parked = self.editor;
                const pasted = self.editor_pasted;
                self.editor = .{ .allocator = self.allocator };
                self.resetSessionView(client.snapshot());
                self.editor.deinit();
                self.editor = parked;
                self.editor_pasted = pasted;
            } else self.resetSessionView(client.snapshot());
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

    /// 释放当前审批的描述并清空审批状态（包括已显示的审批 id/choice）。
    fn clearPermission(self: *Ui) void {
        if (self.permission) |permission| self.allocator.free(permission.description);
        self.permission = null;
        self.displayed_permission = null;
        self.displayed_permission_choice = null;
        self.frame_permission_choice = null;
    }

    fn add(self: *Ui, kind: Kind, data: []const u8) !usize {
        var bytes: usize = 0;
        for (self.records.items) |record| bytes += record.body.items.len;
        const growth = if (self.restoring and (kind == .assistant or (kind == .tool and data.len == 0)))
            record_limit
        else
            @min(data.len, record_limit);
        if (self.restoring) {
            // Completed restored rows consume their actual bytes. Only an
            // assistant being constructed from blocks (or a tool caption
            // appended immediately after add) needs a full mirror reservation.
            while (true) {
                const active_reserve: usize = if (self.draft) |i| blk: {
                    const active = self.records.items[i];
                    break :blk if (active.batch and active.kind == .assistant) record_limit -| active.body.items.len else 0;
                } else 0;
                if (self.records.items.len < 64 and bytes + active_reserve + growth <= 1024 * 1024) break;
                var oldest: ?usize = null;
                for (self.records.items, 0..) |record, index| {
                    if (!record.batch or self.draft == index or self.reasoning == index or
                        record.pending_output or record.pending_stream_rows != 0 or record.pending_flow_change) continue;
                    var frame_owned = false;
                    for (self.frame_records) |entry| if (entry.record_id == record.id) {
                        frame_owned = true;
                        break;
                    };
                    if (!frame_owned) {
                        oldest = index;
                        break;
                    }
                }
                const index = oldest orelse return error.DisplayCapacity;
                bytes -= self.records.items[index].body.items.len;
                self.removeRecord(index);
                self.dropped_display = true;
            }
        }

        // 丢弃最旧记录时同步修正 draft/reasoning 索引，避免指向错误的记录。
        // An unprinted active body is never evicted: that would silently drop
        // content the terminal has not received yet.
        while (!self.restoring and self.records.items.len > 0 and (self.records.items.len >= 64 or bytes + growth > 1024 * 1024)) {
            if (!self.canEvictOldest()) break;
            self.forgetRecord(0);
            var removed = self.records.orderedRemove(0);
            bytes -= removed.body.items.len;
            removed.deinit(self.allocator);
            if (self.draft) |i| self.draft = if (i == 0) null else i - 1;
            if (self.reasoning) |i| self.reasoning = if (i == 0) null else i - 1;
            self.dropped_display = true;
        }

        if (self.records.items.len >= 64 or bytes + growth > 1024 * 1024)
            return error.DisplayCapacity;
        try self.reserveRecord();
        var record = Record{ .kind = kind, .batch = self.restoring };
        // Actual current terminal width, not a default, before the first append.
        if (kind == .reasoning) try record.attachTail(self.allocator, @max(1, self.size.columns -| 1));
        self.records.appendAssumeCapacity(record);
        const index = self.records.items.len - 1;
        try self.registerRecord(index);
        try self.records.items[index].append(self.allocator, data);
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
    fn hint(self: *Ui, a: std.mem.Allocator, state: Connection.State) ![]const u8 {
        if (self.secret_quarantine) return std.fmt.allocPrint(a, "{s}; Esc closes", .{self.notice});
        if (self.secret_mode) return if (std.mem.eql(u8, self.notice, "Ready")) "" else self.notice;
        if (self.settings_open) {
            if (self.settings_value_picker) |picker| {
                const title = settingsValueTitle(picker.key);
                if (self.settings_menu.pasted) return std.fmt.allocPrint(a, "{s}; pasted selection, Esc cancels", .{title});
                if (std.mem.eql(u8, self.notice, "Ready") or std.mem.eql(u8, self.notice, title)) return title;
                return std.fmt.allocPrint(a, "{s}: {s}", .{ title, self.notice });
            }
            return if (self.settings_menu.pasted) "Pasted selection; Esc cancels" else if (std.mem.eql(u8, self.notice, "Ready")) "" else self.notice;
        }
        if (self.provider_open) return if (self.provider_picker.pasted) "Pasted selection; Esc cancels" else if (std.mem.eql(u8, self.notice, "Ready")) "" else self.notice;
        if (self.model_picker) |picker| {
            if (picker.pasted) return "Pasted selection; Esc cancels";
            if (!std.mem.eql(u8, self.notice, "Ready")) return self.notice;
            if (state.model_providers.len == 0) return "No logged-in providers: /login, then /model";
            return "";
        }
        if (self.commandMenuVisible()) return "";
        var notice: []const u8 = "";
        var terminal_issue = false;
        // Ordinary one-shot successes are transcript notices. Only an
        // unresolved actionable terminal result owns the persistent hint.
        if (self.last_terminal) |result| {
            if (result.status != .success and (result.status != .paused or result.model_failure == .output_limit or r.policyPause(result.detail))) {
                var formatted: std.Io.Writer.Allocating = .init(a);
                defer formatted.deinit();
                const label = switch (result.status) {
                    .paused => "Paused",
                    .failed => "Failed",
                    .canceled => "Canceled; prior side effects remain",
                    .success => unreachable,
                };
                if (result.status == .canceled and result.detail != null and result.detail.? == error.Canceled)
                    try formatted.writer.writeAll(label)
                else if (result.detail != null and result.detail.? == error.DecisionUnavailable)
                    try shared.failure.writeDecision(&formatted.writer, result.decision_failure)
                else
                    try shared.failure.write(&formatted.writer, label, result.detail, result.model_failure, result.http_status);
                notice = try a.dupe(u8, formatted.written());
                terminal_issue = true;
            }
        }
        if (notice.len == 0 and !std.mem.eql(u8, self.notice, "Ready") and !std.mem.eql(u8, self.notice, "Running") and !std.mem.eql(u8, self.notice, "Completed")) notice = self.notice;
        if (notice.len == 0 and !configured(state) and (state.settings_notice == null or state.model.len == 0)) notice = "Not configured: /login, then /model";
        if (notice.len == 0 and self.remote() != null and !state.available) notice = "Daemon connection unavailable; /exit and reconnect";
        if (self.permission == null and !self.stop_open and !terminal_issue and notice.len == 0 and state.memory.enabled and state.settings_error == null and state.log_error == null) {
            if (state.memory.active) |active| {
                notice = if (state.memory.queued_count != 0)
                    try std.fmt.allocPrint(a, "Memory: {s} (queued: {d})", .{ @tagName(active.phase), state.memory.queued_count })
                else
                    try std.fmt.allocPrint(a, "Memory: {s}", .{@tagName(active.phase)});
            } else if (state.memory.queued_count != 0) {
                notice = try std.fmt.allocPrint(a, "Memory: queued ({d})", .{state.memory.queued_count});
            } else if (state.memory.last_terminal) |terminal| {
                notice = try std.fmt.allocPrint(a, "Memory: {s}", .{switch (terminal.result) {
                    .saved => "saved",
                    .skipped => "no new durable entries",
                    .failed => "failed",
                    .uncertain => "request outcome uncertain",
                    .canceled => "canceled",
                }});
            }
        }
        if (notice.len == 0 and state.settings_error == null) if (state.pending_default_effort) |effort| {
            notice = try std.fmt.allocPrint(a, "Default thinking: {s}; awaiting model capabilities", .{effort.name() orelse "unknown"});
        };
        if (state.settings_error) |err| {
            notice = try std.fmt.allocPrint(a, "{s}{s}SETTINGS FAILED: {s}", .{ notice, if (notice.len != 0) " | " else "", @errorName(err) });
        } else if (!terminal_issue) {
            if (state.settings_notice) |warning| {
                const same_capability_cause = std.mem.eql(u8, warning, "Saved thinking level not applied: model capabilities unknown") and
                    (std.mem.eql(u8, notice, "Thinking capabilities are loading; try Shift+Tab again shortly") or
                        std.mem.eql(u8, notice, "Thinking capabilities unknown: refresh /model or declare reasoning levels in configuration"));
                if (!same_capability_cause and !std.mem.eql(u8, notice, warning)) notice = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ notice, if (notice.len != 0) " | " else "", warning });
            }
        }
        if (state.log_error) |err| return std.fmt.allocPrint(a, "{s}{s}REC FAILED: {s}", .{ notice, if (notice.len != 0) " | " else "", @errorName(err) });
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
                    record.final_answer = shared.answer.classify(blocks, blocks_complete) == .final;
                    if (!clipped and blocks_complete and canonical.items.len <= record_limit) {
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
                    record.final_answer = shared.answer.classify(blocks, blocks_complete) == .final;
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
                } else record.final_answer = shared.answer.classify(blocks, blocks_complete) == .final;
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
                if (self.permission) |permission| if (permission.id == id) self.clearPermission();
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
        // ctrl_d_exit is the provenance bit for an actual parsed quit gesture;
        // want_exit alone is never authority to terminate the process.
        self.ctrl_d_exit = true;
        self.want_exit = true;
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
        const active = self.settingsIdle() and self.model_picker == null and !self.provider_open and !self.settings_open and !self.editor_pasted;
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
    fn settingsModelOpen(self: *const Ui) bool {
        return self.decision_open or self.image_open;
    }
    /// Any settings child that borrows the editor as a bounded query.
    fn settingsQueryOpen(self: *const Ui) bool {
        return self.settingsModelOpen() or self.proxy_open;
    }
    fn settingsModels(self: *const Ui, state: Connection.State) []const core_config.Model {
        return if (self.image_open) state.image_models else state.decision_models;
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
        self.decision_open = false;
        self.image_open = false;
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
        const parent: usize = if (self.image_open) 6 else if (self.anyProxyOpen()) 8 else 1;
        if (self.settingsModelOpen()) self.wipeEditor();
        if (self.proxyEditorBorrowed()) self.endProxyEditor();
        self.displayed_decision_fingerprint = null;
        self.frame_decision_fingerprint = null;
        self.displayed_proxy_fingerprint = null;
        self.frame_proxy_fingerprint = null;
        self.settings_value_picker = null;
        self.decision_open = false;
        self.image_open = false;
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
            .task_timeout_ms => "Task timeout (s)",
        };
    }
    fn openSettingsValue(self: *Ui, key_: preference.Key, state: Connection.State) void {
        const current: ?u32 = switch (key_) {
            .compaction_enabled => @intFromBool(state.limits.compaction_enabled),
            .memory_auto => @intFromBool(state.memory_auto),
            .command_timeout_ms => state.limits.command_timeout_ms,
            .request_timeout_ms => state.limits.request_timeout_ms,
            .task_timeout_ms => state.limits.task_timeout_ms,
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
                if (!self.settingsQueryOpen() and (self.settings_menu.selected == 1 or self.settings_menu.selected == 6)) {
                    self.wipeEditor();
                    self.image_open = self.settings_menu.selected == 6;
                    self.decision_open = !self.image_open;
                    self.settings_menu.clear();
                    const selected_ref = if (self.image_open)
                        (if (state.image_enabled) state.image_model else null)
                    else
                        (if (state.decision_enabled) state.decision_model else null);
                    self.settings_menu.selected = decision_picker_module.indexOf(self.settingsModels(state), state.model_providers, self.editor.bytes.items, selected_ref);
                    self.frame_settings_generation = null;
                    self.notice = "Ready";
                    return;
                }
                if (!self.settingsQueryOpen() and self.settings_menu.selected == 8) {
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
                    const save = (if (self.image_open) self.connection.image_fn else self.connection.decision_fn) orelse {
                        self.notice = "Global settings unavailable; changes disabled";
                        return;
                    };
                    const selected = decision_picker_module.choice(self.settingsModels(state), state.model_providers, self.editor.bytes.items, self.settings_menu.selected) orelse return;
                    if (self.connection.async_actions != null) {
                        _ = self.beginAsync(if (self.image_open) .{ .image = selected } else .{ .decision = selected }, if (self.image_open) .image else .decision);
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
            .{ .level = state.reasoning_effort, .until_ms = self.clock_ms +| 2000 }
        else
            null;
        self.model_flow = .{};
        self.mode = null;
        self.last_terminal = null;
        self.closeModelPicker();
        self.notice = if (inherited) "Model selected; inherited context budget" else "Model selected";
        self.requestDraw();
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
        self.effort_flash = .{ .level = next, .until_ms = self.clock_ms +| 2000 };
        self.notice = "Ready";
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
                "/model  Select model\n/login  Configure provider\n/compact  Compact conversation\n/settings  Global settings (Low-price input, Decision model)\n/ls [--running] [--page N]  List sessions\n/cd <dir>  Change launcher directory\n/attach [--takeover] <id>  Attach a session\n/detach  Leave the session view\n/close [--force] <id>  Close a session\n/exit  Leave this frontend\n!command  Run a local command without main-model inference"
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
            self.notice = if (state.model.len == 0) "Not configured: /login, then /model" else state.settings_notice orelse "Not configured: use /login first";
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

    // All fallible display/history preparation precedes worker launch. Queued
    // prompts pass explicit text and never borrow or clear the current draft.
    fn startPrompt(self: *Ui, runtime: *r.Runtime, value: []const u8, kind: @TypeOf(@as(task.Job, undefined).kind)) !void {
        self.reclaimDisplayCapacity();
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
        const future = try Io.concurrent(self.io, task.Job.run, .{&self.job});
        var bytes: usize = record.body.items.len;
        for (self.records.items) |old| bytes += old.body.items.len;
        while (self.records.items.len != 0 and (self.records.items.len >= 64 or bytes > 1024 * 1024)) {
            if (!self.canEvictOldest()) break;
            self.forgetRecord(0);
            var removed = self.records.orderedRemove(0);
            bytes -= removed.body.items.len;
            removed.deinit(self.allocator);
            if (self.draft) |i| self.draft = if (i == 0) null else i - 1;
            if (self.reasoning) |i| self.reasoning = if (i == 0) null else i - 1;
            self.dropped_display = true;
        }
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
        self.has_submitted = true;
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
        const future = try Io.concurrent(self.io, task.Job.run, .{&self.job});
        self.future = future;
        self.prompt = null;
        self.task_epoch +%= 1;
        self.has_submitted = true;
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
        self.reclaimDisplayCapacity();
        if (kind != .compact and self.displayBackpressured()) {
            self.notice = "Display is catching up; draft kept";
            return false;
        }
        if (!self.queueOwnerMatches()) {
            self.notice = "Queue belongs to another session; Ctrl-C to clear explicitly";
            return false;
        }
        if (!client.snapshot().available) {
            self.notice = if (client.snapshot().attached) "Synchronizing session; draft kept" else "Session unavailable; /exit and reconnect";
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
        var bytes: usize = record.body.items.len;
        for (self.records.items) |old| bytes += old.body.items.len;
        while (self.records.items.len != 0 and (self.records.items.len >= 64 or bytes > 1024 * 1024)) {
            if (!self.canEvictOldest()) break;
            self.forgetRecord(0);
            var removed = self.records.orderedRemove(0);
            bytes -= removed.body.items.len;
            removed.deinit(self.allocator);
            if (self.draft) |i| self.draft = if (i == 0) null else i - 1;
            if (self.reasoning) |i| self.reasoning = if (i == 0) null else i - 1;
            self.dropped_display = true;
        }
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
        self.has_submitted = true;
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
        if (self.busy or self.future != null or self.exitAuthorized() or self.poisoned or self.stop_open or
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
                    return;
                };
                self.endSecret();
                // A fresh Enter authorizes the completed paste, not its read tail.
                // endSecret still wipes parser scratch and sets stop_feed.
                self.secret_quarantine = false;
                self.wipeEditor();
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
            self.publishNotice(if (decision == .deny) "Request denied" else "Allowed once");
        } else if (self.bridge.decide(permission.id, decision)) self.publishNotice(if (decision == .deny) "Request denied" else "Allowed once") else self.notice = "Permission expired";
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
            .page_up => {
                self.permission_scroll -|= @max(1, @min(7, self.size.rows -| 7));
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
            },
            .page_down => {
                self.permission_scroll +|= @max(1, @min(7, self.size.rows -| 7));
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
            },
            .home => {
                self.permission_scroll = 0;
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
            },
            .end => {
                self.permission_scroll = std.math.maxInt(usize);
                self.displayed_permission = null;
                self.displayed_permission_choice = null;
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
            self.effort_flash = .{ .level = state.reasoning_effort, .until_ms = self.clock_ms +| 2000 };
        if (self.model_picker) |*picker| picker.changed();
        self.displayed_model_generation = null;
        if (state.metadata_notice) |notice| {
            const same = if (before.metadata_notice) |previous| std.mem.eql(u8, previous, notice) else false;
            if (!same) {
                // Producer-classified success is a one-shot transcript notice;
                // an unclassified failure stays actionable in the hint.
                if (state.metadata_notice_ttl_ms != 0) self.publishNotice(notice) else self.notice = notice;
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

    /// 判断是否有任务可以收尾。远端终态由本线程经 Bridge 交付，本地 busy 只是
    /// 视图：两个任务之间它可能已经为 false，所以不能把真实 terminal 留在
    /// Bridge 里等一个永远不会再出现的 busy 周期。本地任务仍需 busy 且
    /// job.done 才 join，保持 acquire/release 配对。
    fn finishReadyTask(self: *Ui) !void {
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
        self.detachInbox();

        // The producer can finish after our per-tick drain limit. Once joined,
        // at most one bounded queue remains; consume it before accepting Submit.
        while (true) {
            self.reclaimDisplayCapacity();
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

    /// Never evict unacknowledged, active, or frame-owned display records.
    fn canEvictOldest(self: *const Ui) bool {
        if (self.records.items.len == 0) return false;
        const record = &self.records.items[0];
        return record.output and self.draft != 0 and self.reasoning != 0 and
            !record.pending_output and record.pending_stream_rows == 0 and !record.pending_flow_change and
            // An unmet display fence owns its record: evicting it would erase
            // the only evidence that could prove the event was shown.
            !self.hasUnmetFence(record.id);
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

    fn animate(self: *Ui) void {
        const tick = self.clock_ms / 80;
        if ((!self.busy and !self.presentationWaiting() and !self.remoteSynchronizing()) or self.resize_waiting or self.animation_tick == tick) return;
        self.animation_tick = tick;
        // An approval owns a full, non-sparse preview. Repainting that unchanged
        // preview for a composer pulse sends its title/body again every 80 ms.
        // Keep polling/cancellation alive, but redraw only for actual events,
        // input until the approval is cleared. Never clear dirty here.
        // A static pending preview needs no spinner-only repaint. Real events,
        // input and tool timing retain their normal independent draw requests.
        const queue = self.queueSnapshot();
        if (self.permission == null and (queue.preview_count == 0 or self.active_tool != null)) self.dirty = true;
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

            // acquire 与 worker 的 release 配对，确保读到任务结果。
            try self.finishReadyTask();
            if (!self.log_warning_seen and self.connection.current().log_error != null) {
                self.log_warning_seen = true;
                // 记录故障有独立临时hint，不改变Runtime任务结果。
                if (self.last_terminal == null) self.notice = "Session recording failed; records may be incomplete";
                self.requestDraw();
            }

            // 收到信号（如 SIGINT）：转为退出请求并取消任务。A remote task is
            // owned by the backend, so a frontend signal only detaches.
            if (interrupt.signal() != 0) {
                self.want_exit = true;
                if (self.remote() == null) self.cancel.cancel();
            }

            // 任务结束后才真正退出；远程前端最后一次 ACK 后即可离开。
            if (self.exitAuthorized() and (!self.busy or self.remote() != null)) {
                try self.drainExit();
                return if (interrupt.signal() != 0) 128 + interrupt.signal() else 0;
            }

            self.refreshStop();
            self.pollMetadata();
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
            if (self.resize_rescue.len != 0 or self.frame_offset < self.frame.len) {
                try self.writeFrame();
            }

            // Draw latest state on the ordinary cadence, but preserve the
            // input/geometry turn before its first write. Already-buffered keys
            // must not gain authority from a frame they could not have seen;
            // urgent input waits only for a frame that has already started.
            // Cadence starts when the draw can actually run, not at the loop's
            // earlier clock sample before pumping/input/output work.
            self.clock_ms = @intCast(@max(0, Io.Clock.awake.now(self.io).toMilliseconds()));
            const staged = self.drawDue();
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
        self.vertical_column = null;
        self.tail_cursor_rows_up = 0;
        self.tail_composer_rows = 1;
        // Reflow may have moved our rows: nothing is proven about the bottom or
        // about the rows we owned before this geometry change.
        self.tail_bottom = false;
        self.frame_bottom = false;
        self.displayed_permission = null;
        self.displayed_permission_choice = null;
        self.frame_permission_choice = null;
        self.displayed_model_epoch = null;
        self.displayed_model_generation = null;
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
        self.frame_bottom = false;
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
        self.frame_offset += try self.terminal.write(self.frame[self.frame_offset..]);
        if (self.frame_offset == self.frame.len) self.finishFrame();
    }

    fn finishFrame(self: *Ui) void {
        if (self.frame.len == 0 or self.frame_offset != self.frame.len) return;
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
        self.tail_cursor_rows_up = if (self.frame_fresh) self.frame_cursor_rows_up else 0;
        self.tail_composer_rows = if (self.frame_fresh) self.frame_composer_rows else 1;
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
                        if (progressed and (stream.pendingBytes() != 0 or stream.hasMetadataProgress() or stream.hasPendingPresentation())) self.requestProgressDraw();
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
            if (committed and entry.output_candidate) record.output = true;
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
            self.compact_composer = self.frame_fresh and self.frame_height == 1;
            self.compact_hint_hash = self.frame_hint_hash;
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

    /// Exit gets a bounded chance to publish the final canonical reply, never an infinite drain.
    fn drainExit(self: *Ui) !void {
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

    /// Only an acknowledged, unchanged-size owned tail can be reclaimed. Keep
    /// the startup transcript and shell history above it; never ED/CUP/scrollback-clear.
    fn idleExitBytes(self: *const Ui, writer: *Io.Writer) !bool {
        if (!self.ctrl_d_exit or self.has_submitted or self.busy or self.future != null or
            self.frame.len != 0 or self.resize_rescue.len != 0 or !self.frame_fresh or
            self.abandon_tail or self.tail_snapshot == null or self.tail_height == 0 or
            (self.menu_history != null and self.menu_history.?.borrowed.len != 0) or
            self.tail_height > self.size.rows or self.tail_size.rows != self.size.rows or
            self.tail_size.columns != self.size.columns) return false;
        try writer.writeAll(terminal_module.sync_begin ++ "\x1b[?25l\r");
        const top_distance = (self.tail_height - 1) -| self.tail_cursor_rows_up;
        if (top_distance != 0) try writer.print("\x1b[{d}A", .{top_distance});
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
        const prepared: ?PreparedComposer = if (normal_composer) try self.prepareComposer(a, state, cols) else null;
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
            self.tail_snapshot != null and self.tail_bottom and self.tail_height != 0 and self.tail_composer_rows == 1 and self.tail_cursor_rows_up == 0 and
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
            (!self.tail_bottom or self.tail_size.columns != self.size.columns or self.tail_size.rows != self.size.rows)))
        {
            // Unknown geometry owns no old coordinates. The fresh frame below
            // establishes a new bottom anchor without reclaiming the old tail.
        } else if (self.tail_height != 0) {
            const top_distance = (self.tail_height - 1) -| self.tail_cursor_rows_up;
            if (top_distance != 0) try writer.print("\x1b[{d}A", .{top_distance});
            // Replace each owned row once, without exposing a whole-tail blank
            // pass. Transcript rows plus the new tail cover the old footprint;
            // rows the frame no longer needs are contracted after it.
            try writer.writeAll("\r");
        }

        self.frame_clear_end = out.written().len;
        const history_valid = !self.abandon_tail and self.tail_bottom and self.tail_size.columns == self.size.columns and
            self.tail_size.rows == self.size.rows and self.menu_history != null;
        var above: []const []const u8 = if (history_valid) self.menu_history.?.above else &.{};
        var borrowed: []const []const u8 = if (history_valid and !release_idle) self.menu_history.?.borrowed else &.{};

        // Native scrollback is an appendable document, not a sliding window.
        // Completed records are released once and never regrouped, re-laid out
        // or replayed here; only the still-mutable tail joins `lines`.
        var lines: std.ArrayList([]const u8) = .empty;
        const flow_allowed = self.size.rows >= 7 and cols >= 8 and
            self.permission == null and self.model_picker == null and !self.provider_open and !self.settings_open and
            !self.commandMenuVisible() and !self.stop_open and !self.secret_mode and !self.secret_quarantine;
        const mutable_rows = @max(1, self.size.rows -| (3 + composer_rows));
        var flow_continuation = false;
        var canonical_output = false;
        var transcript_rows: usize = 0;
        var previous_kind: ?Kind = null;
        for (self.records.items, 0..) |*record, index| {
            if (@import("builtin").is_test) self.draw_record_visits += 1;
            if (record.kind == .reasoning) continue;
            const drafting = self.draft == index;
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
                } else if (self.permission == null and (!drafting or flow_allowed)) {
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
            const finalized = cols >= 8 and !record.output and !drafting and self.permission == null;
            var stop = prefix;
            if (stream_record) {
                stop = if (finalized) record.lines.len else if (drafting and flow_allowed) record.stream.?.releaseLimit(record.lines.len -| mutable_rows) else 0;
                record.pending_stream_rows = stop;
            } else {
                if (drafting and flow_allowed) {
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
            if (drafting) {
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
                frame_record.tail_rows = lines.items.len - frame_record.tail_line_start;
                if (begin != 0 or (stream_record and record.stream_written != 0)) flow_continuation = true;
            }
            // Display proof candidates, captured while this frame's render is
            // still pinned. Which of them survives is decided by the tail crop
            // below (a modal/crop never counts as visible).
            if (stream_record) {
                const stream = record.stream.?;
                frame_record.stream_full_end = stream.visibleSourceEnd();
                frame_record.stream_prefix_end = bodyShownEnd(stream, stop);
                frame_record.visible_source_end = if (finalized) frame_record.stream_full_end else 0;
                frame_record.visible_complete = finalized;
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
                    const running = if (self.active_tool) |active| if (active.display_key) |identity| identity.eql(entry.key) else false else false;
                    try lines.append(a, if (running) try self.pendingCommand(a, @max(1, cols)) else try self.waitingCommand(a, entry, @max(1, cols)));
                }
                if (detached_active) try lines.append(a, try self.pendingCommand(a, @max(1, cols)));
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
                thinking_lines = record.lines[record.lines.len -| 3..];
            }
        }
        // Transient reasoning follows the transcript without committing a gap
        // or reasoning text to scrollback. Its gap does not consume the latest3.
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
        const empty_rendered: markdown.Rendered = .{ .lines = &.{}, .total_lines = 0, .truncated = false };
        const secret_lines = if (self.secret_mode) try markdown.render(a, secret_destination, .{ .columns = @max(1, cols), .max_lines = 8, .markdown = false }) else empty_rendered;
        // One frame-local plain render serves both sizing and the deny-only latch.
        const approval_lines = if (self.permission) |permission| try markdown.render(a, permission.description, .{ .columns = @max(1, cols), .max_lines = 8192, .markdown = false }) else empty_rendered;
        // State is an app-prepared immutable value; never dereference Runtime.
        const queue_snapshot = self.queueSnapshot();
        const hint_line = try self.footerHint(a, state);
        // Normal output keeps its empty gap; acknowledged shell-like idle
        // lines instead keep a single-row composer without extra redraw scroll.
        const hint_hash = std.hash.Wyhash.hash(0, hint_line);
        // Idle release keeps the one-row composer only while the hint it would
        // hide is exactly the one already ACKed. A newly published diagnostic
        // therefore keeps its own row instead of being dismissed by this Enter.
        const compact = (release_idle and self.tail_hint_hash == hint_hash) or
            ((self.compact_composer and self.compact_hint_hash == hint_hash) and
                !self.busy and self.permission == null and !self.stop_open and !self.settings_open and
                !self.provider_open and !self.codex_open and self.model_picker == null and !self.commandMenuVisible() and
                !self.secret_mode and !self.secret_quarantine and thinking == null and composer_rows == 1);
        // The separator row is footprint, so it exists only while there is
        // something above it to separate: mutable body, an approval/secret
        // panel, pending reasoning, a candidate/menu popup, or canonical rows
        // released above this tail. Initial entry has none of these and writes
        // the composer alone at the terminal's existing row.
        const popup_requested = self.codex_open or self.stop_open or self.settings_open or self.provider_open or
            self.model_picker != null or (!release_idle and self.commandMenuVisible()) or
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
        const separator: usize = @intFromBool(!compact and body_present);
        const footer_rows: usize = if (compact) 1 else composer_rows + separator + @as(usize, @intFromBool(hint_line.len != 0));
        const body_limit = self.size.rows -| footer_rows;
        const candidate_limit = body_limit -| 1; // Separate candidates from conversation even in short windows.
        const model_state = state;
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
        // A pending busy /close confirmation reuses the same bottom-pinned, fully
        // ACKed two-choice popup as the queue stop confirmation.
        const stop_title = if (self.stop_close != null)
            try std.fmt.allocPrint(a, "Close busy session | Steering {d} FollowUp {d}", .{ queue_snapshot.steering, queue_snapshot.follow_up })
        else
            try std.fmt.allocPrint(a, "{s} | Steering {d} FollowUp {d}", .{ if (self.busy) "Task running" else "Task ended", queue_snapshot.steering, queue_snapshot.follow_up });
        const stop_choices = [_][]const u8{
            stop_title,
            if (self.stop_danger) "  Cancel" else "> Cancel",
            if (self.stop_danger) "> Close session" else "  Close session",
        };
        const stop_choices_queue = [_][]const u8{ stop_title, if (self.stop_danger) "  Continue" else "> Continue", if (self.stop_danger) "> Stop and clear" else "  Stop and clear" };
        const stop_popup: []const []const u8 = if (self.stop_close != null) &stop_choices else &stop_choices_queue;
        const narrow = [_][]const u8{"Resize to confirm (Esc continues)"};
        const stop_fits = self.stop_open and candidate_limit >= stop_popup.len and
            cols >= text.width(stop_title) and cols >= text.width(stop_popup[1]) and cols >= text.width(stop_popup[2]);
        const codex_view = state.codex_login;
        const codex_code = if (self.codex_generation != null and codex_view.generation == self.codex_generation.? and codex_view.status == .pending and validCodexCode(&codex_view)) codex_view.userCode() else "";
        const codex_popup = [_][]const u8{ corecodex.verification_url, if (codex_code.len != 0) codex_code else "Waiting for device code...", "Esc cancels" };
        const popup_lines: []const []const u8 = if (self.codex_open) &codex_popup else if (self.stop_open) (if (stop_fits) stop_popup else &narrow) else if (self.settings_open) settings_rows.lines else if (self.provider_open) provider_rows.lines else if (self.model_picker != null) picker_rows.lines else if (menu_visible) menu_rows.lines else queue_lines.items;
        const selected_line = if (self.codex_open) @as(?usize, null) else if (self.stop_open) @as(?usize, if (self.stop_danger) 2 else 1) else if (self.settings_open) settings_rows.selected_line else if (self.provider_open) provider_rows.selected_line else if (self.model_picker != null) picker_rows.selected_line else menu_rows.selected_line;
        const checked_mask: u16 = if (self.stop_open) 0 else if (self.provider_open) provider_rows.checked_mask else if (self.model_picker != null) picker_rows.checked_mask else 0;
        const popup_gap: usize = @intFromBool(popup_lines.len != 0);
        const content_body_limit = body_limit -| (popup_lines.len + popup_gap);
        self.frame_model_epoch = null;
        self.frame_model_generation = null;
        // Reasoning resumes into its own downward window. A closed popup,
        // approval or secret prompt may have borrowed ACKed rows above this
        // tail; put them back at their original coordinates before the window
        // can paint over them. They join the tail as an ordinary transcript
        // prefix, so this frame defers (thinking_deferred) and the window
        // appears on the next complete ACK.
        const reasoning_resumes = thinking != null and popup_lines.len == 0 and
            self.permission == null and !self.secret_mode and !self.secret_quarantine;
        if (reasoning_resumes) try releaseBorrowedPrefix(a, &out, self.frame_clear_end, &borrowed, &transcript_rows);
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
        const overlay_visible = self.codex_open or self.permission != null or popup_lines.len != 0 or menu_visible or
            self.model_picker != null or self.provider_open or self.settings_open;
        const wanted_body = if (self.stop_open) 0 else if (self.permission != null)
            @min(body_limit, 2 + @max(1, approval_lines.lines.len))
        else if (self.secret_mode) @min(body_limit, secret_lines.lines.len) else if (show_thinking) @min(thinking_gap + @min(3, thinking_lines.len), content_body_limit) else @min((if (overlay_visible) @as(usize, 0) else borrowed.len) + lines.items.len, content_body_limit);
        const wanted_rows = @min(self.size.rows, footer_rows + popup_lines.len + popup_gap + wanted_body);
        // Reuse the ACKed footprint when content contracts. This keeps the
        // composer's last row at the physical bottom without inventing a
        // full-screen tail or evicting already committed transcript rows.
        const anchored = !release_idle and !self.abandon_tail and self.tail_bottom and
            self.tail_size.columns == self.size.columns and self.tail_size.rows == self.size.rows;
        const rows = @min(self.size.rows, @max(wanted_rows, if (anchored) self.tail_height -| transcript_rows else 0));
        // Only a popup or approval grows UP into exact ACKed transcript rows,
        // without pushing duplicate content into native scrollback. Keep those
        // restoration rows when returning to the normal live tail. Reasoning
        // never borrows: its window grows downward instead.
        // Unknown/reflowed/partially written rows never grant upward ownership.
        // Any overlay (permission, candidate menus, pickers) may need rows above
        // the live tail. They are borrowed from ACKed transcript rows so closing
        // the overlay restores them instead of leaving the rows overwritten.
        const borrow_count = if (overlay_visible and transcript_rows == 0)
            @min(rows -| self.tail_height, above.len)
        else
            0;
        self.frame_borrow_rows = borrow_count;
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
        var next_above: std.ArrayList([]const u8) = .empty;
        // The one-time native-space establishment below creates a completely
        // blank viewport. Only rows above this frame's actual transcript/tail
        // can be borrowed later, and they become authoritative only on ACK.
        if (needs_anchor) {
            const blank_count = @min(200, self.size.rows -| @min(self.size.rows, transcript_rows + rows));
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

        // Establish a bottom anchor only when no complete same-geometry frame
        // proves one. Move to the bottom without clearing or replaying history,
        // create one fully owned blank viewport by native scrolling, then start
        // the actual transcript/tail at its bottom-relative origin. Resize alone
        // never calls draw; the next real frame performs this bounded establishment.
        if (needs_anchor) {
            const reserve = @min(self.size.rows -| 1, (transcript_rows + rows) -| 1);
            const prefix_len = (terminal_module.sync_begin ++ "\x1b[?25l\r").len;
            var rebuilt: std.Io.Writer.Allocating = .init(a);
            try rebuilt.writer.writeAll(out.written()[0..prefix_len]);
            try rebuilt.writer.print("\x1b[{d}B\r\n", .{self.size.rows});
            for (0..self.size.rows -| 1) |_| try rebuilt.writer.writeAll("\r\n");
            if (reserve != 0) try rebuilt.writer.print("\x1b[{d}A", .{reserve});
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
            if (self.stop_open) {
                for (0..content_body_rows) |line| try putStyled(writer, 1 + line, "");
                self.frame_permission = null;
            } else if (self.secret_mode) {
                const start = body_rows -| secret_lines.lines.len;
                for (0..body_rows) |line| try putStyled(writer, 1 + line, if (line >= start and line - start < secret_lines.lines.len) secret_lines.lines[line - start] else "");
                self.frame_permission = null;
            } else if (self.permission) |permission| {
                // Plain rendering: tool input must not hide behind Markdown formatting.
                const all = approval_lines;
                const clipped = permission.clipped or all.truncated or all.total_lines > all.lines.len;

                // 把截断状态写回审批，供 key 处理判断是否只允许拒绝。
                self.permission.?.clipped = clipped;

                if (clipped or permission.pasted) self.permission.?.choice = .deny;
                const title = if (permission.pasted)
                    try std.fmt.allocPrint(a, "Approval #{d} [paste detected; deny only]", .{permission.id})
                else if (clipped)
                    try std.fmt.allocPrint(a, "Approval #{d} [preview clipped; deny only]", .{permission.id})
                else
                    try std.fmt.allocPrint(a, "Approval #{d} — choose with arrows, Enter confirms, Esc cancels", .{permission.id});
                try putToneLine(writer, a, 1, title, cols, theme.accent);

                // Reserve the last body row for the modal choices. PageUp/PageDown
                // scroll only the plain command preview; selection never shares the composer.
                const preview_rows = body_rows - 2;
                const start = @min(self.permission_scroll, all.lines.len -| preview_rows);
                for (0..preview_rows) |line| try putStyled(writer, 2 + line, if (start + line < all.lines.len) all.lines[start + line] else "");
                const choices = if (clipped or permission.pasted)
                    "                         > Deny"
                else if (self.permission.?.choice == .allow_once)
                    "> Allow once                Deny"
                else
                    "  Allow once              > Deny";
                try putToneLine(writer, a, body_rows, choices, cols, theme.accent);
                self.frame_permission = permission.id;
                self.frame_permission_choice = self.permission.?.choice;
                // The approval modal itself is a real display of the applied
                // event, even though it hides the conversation tail.
                self.frame_delivery_shown = true;
            } else if (show_thinking) {
                // Latest THREE content rows, without any title/prefix. This
                // window never borrows rows, so any borrowed ACKed prefix was
                // already restored above the tail before it resumes.
                const visible_rows = @min(3, content_body_rows -| thinking_gap);
                const start = thinking_lines.len -| visible_rows;
                for (0..content_body_rows) |line| {
                    const index = line -| thinking_gap;
                    try putStyled(writer, 1 + line, if (line >= thinking_gap and index < visible_rows and start + index < thinking_lines.len) thinking_lines[start + index] else "");
                }
                self.frame_permission = null;
                self.frame_delivery_shown = true;
            } else {
                // Bounded live draft: only its last rows that fit are written,
                // and new rows grow naturally below the owned footprint. This
                // is not a regenerated history window.
                const leading_gap = if (borrowed.len == 0) live_gap else 0;
                const content = lines.items[leading_gap..];
                const content_rows = content_body_rows -| leading_gap;
                const start = content.len -| content_rows;
                for (0..content_body_rows) |line| {
                    const index = line -| leading_gap;
                    try putStyled(writer, 1 + line, if (line >= leading_gap and start + index < content.len) content[start + index] else "");
                }
                self.frame_permission = null;
                self.frame_delivery_shown = true;
                visible_from = leading_gap + start;
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
                if (stop_fits) self.frame_stop = self.stop_generation;
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
                if (!self.stop_open and menu_visible and menu_rows.can_confirm) self.frame_command_generation = self.command_menu.generation;
            }

            // Keep the existing separator above the hint, never between the
            // hint and the first composer row. With no hint it remains the gap.
            if (!compact and separator != 0) try putLine(writer, a, rows - composer_rows - @intFromBool(hint_line.len != 0), "", cols);
            if (!compact and hint_line.len != 0) try putToneLine(writer, a, rows - composer_rows, hint_line, cols, theme.muted);

            if (self.secret_mode or self.secret_quarantine) {
                // Only a bounded mask is copied to the frame; never format secret bytes.
                const masks: [64]u8 = @splat('*');
                const count = @min(self.secret.len, @min(masks.len, cols - 3));
                try putInputLine(writer, a, rows, "API key> ", masks[0..count], cols);
                cursor_offset = tail_out.written().len;
                try writer.print("\r\x1b[{d}C", .{@min(cols, count + 10) - 1});
            } else if (self.proxy_address_open) {
                // The endpoint editor owns the composer line while the submenu
                // stays visible; nothing is saved before a fresh full frame.
                const value = try editorDisplay(a, self.editor.bytes.items);
                try putInputLine(writer, a, rows, "Address> ", value, cols);
                cursor_offset = tail_out.written().len;
                const typed = try editorDisplay(a, self.editor.bytes.items[0..self.editor.cursor]);
                const column = @min(cols -| 1, text.width("Address> ") + text.width(typed));
                try writer.print("\r\x1b[{d}C", .{column -| 1});
            } else if (self.settings_open and !self.settingsQueryOpen()) {
                try putInputLine(writer, a, rows, "Settings> ", "", cols);
                cursor_offset = tail_out.written().len;
                try writer.print("\r\x1b[{d}C", .{@min(cols - 1, 10)});
            } else if (self.provider_open) {
                try putInputLine(writer, a, rows, "Provider> ", "", cols);
                cursor_offset = tail_out.written().len;
                try writer.print("\r\x1b[{d}C", .{@min(cols - 1, 10)});
            } else if (self.settingsQueryOpen() or self.model_picker != null) {
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
        const snapshot_allowed = self.permission == null and self.model_picker == null and !self.provider_open and !self.settings_open and !menu_visible and !self.secret_mode and !self.secret_quarantine;
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
        self.frame_size = self.size;
        self.frame_bottom = true;
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

fn testAcknowledgeFullFrame(ui: *Ui) void {
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
}

/// Ordinary one-shot successes live in the display transcript, not the footer.
/// Keep the wording assertions on that record so an actionable footer can
/// still own errors, approvals and pending queue state at the same time.
fn publishedNotice(ui: *const Ui, needle: []const u8) bool {
    var index = ui.records.items.len;
    while (index > 0) {
        index -= 1;
        const record = ui.records.items[index];
        if (record.kind != .notice) continue;
        if (std.mem.find(u8, record.body.items, needle) != null) return true;
    }
    return false;
}

/// Prior shell output with the cursor left on the physical bottom row, so the
/// floating composer starts where a real terminal prompt stopped. No text
/// reflow or native-viewport position is inferred from this fixture.
fn seedPriorBottom(screen: *@import("../tests/regular_screen.zig").Screen) !void {
    for (0..screen.rows - 1) |_| try screen.replay("\r\n");
    try std.testing.expectEqual(screen.rows - 1, screen.row);
}

/// Absolute row whose cells start with `prefix`; popup rows are only guaranteed
/// to be adjacent and above the composer, not to sit at a fixed screen row.
fn rowStartingWith(screen: *const @import("../tests/regular_screen.zig").Screen, prefix: []const u8) !usize {
    for (screen.grid, 0..) |line, row| if (std.mem.startsWith(u8, &line, prefix)) return row;
    return error.MissingRowPrefix;
}

test "stable pending pulses preserve native history and tail" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try seedPriorBottom(&screen);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    ui.busy = true;
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "hold pending");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const history = screen.history_len;
    const height = ui.tail_height;
    ui.dirty = false;
    for (1..25) |i| {
        ui.clock_ms = @intCast(i * 80);
        ui.animate();
        try std.testing.expect(!ui.dirty);
        // Even if independent work requires a redraw, identical pending
        // snapshots must use owned rows and cannot advance native history.
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(history, screen.history_len);
        try std.testing.expectEqual(height, ui.tail_height);
        try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    }
}

test "memory footer stays adjacent to wrapped composer after ACK" {
    const Fixture = struct {
        fn current(_: *anyopaque) Connection.State {
            return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "", .memory = .{ .enabled = true, .active = .{ .id = 1, .phase = .extracting } } };
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.current_fn = Fixture.current;
    ui.size = .{ .columns = 30, .rows = 12 };
    _ = try ui.add(.assistant, "body");
    _ = try ui.editor.insert("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL");
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 30, .rows = 12 };
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(ui.frame_composer_rows > 1);
    const status_row = screen.rows - ui.frame_composer_rows - 1;
    try std.testing.expectEqualStrings("Memory: extracting", std.mem.trimEnd(u8, screen.grid[status_row][0..30], " "));
    try std.testing.expectEqualStrings("", std.mem.trimEnd(u8, screen.grid[status_row - 1][0..30], " "));
    try std.testing.expectEqual(@as(usize, 1), screen.count("Memory:"));
    testAcknowledgeFullFrame(&ui);
    const history = screen.history_len;
    const records = ui.records.items.len;
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(history, screen.history_len);
    try std.testing.expectEqual(records, ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 1), screen.count("Memory:"));
}

fn expectLongWarningAdjacent(screen: *const @import("../tests/regular_screen.zig").Screen, composer_rows: usize, columns: usize) !void {
    const warning = "Could not save thinking option; previous option kept | Saved thinking level not applied: model capabilities unknown";
    const status_row = screen.rows - composer_rows - 1;
    const clipped = warning[0..@min(warning.len, columns - 1)];
    try std.testing.expectEqualStrings(clipped, std.mem.trimEnd(u8, screen.grid[status_row][0..columns], " "));
    try std.testing.expectEqual(@as(usize, 1), screen.count("Could not save thinking option"));
    const composer_row = try rowStartingWith(screen, "(fixture-old) ");
    try std.testing.expectEqual(status_row + 1, composer_row);
    try std.testing.expectEqual(@as(usize, 1), screen.count("(fixture-old) "));
}

test "long combined warning stays adjacent across acknowledged command menu cycles and wrapped input" {
    for ([_]usize{ 80, 120 }) |columns| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture = SelectionFixture{ .settings_notice = "Saved thinking level not applied: model capabilities unknown" };
        defer fixture.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        ui.size.columns = columns;
        ui.notice = "Could not save thinking option; previous option kept";
        var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = columns };
        try seedPriorBottom(&screen);
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.draw();
        try screen.replay(ui.frame);
        try expectLongWarningAdjacent(&screen, ui.frame_composer_rows, columns);
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        var open_history: usize = 0;
        var closed_history: usize = 0;
        var open_height: usize = 0;
        var closed_height: usize = 0;
        for (0..2) |cycle| {
            try ui.parser.feed("/", sink);
            try ui.draw();
            try screen.replay(ui.frame);
            try std.testing.expect(ui.commandMenuVisible());
            try std.testing.expectEqual(@as(usize, 0), screen.count("Could not save thinking option"));
            try std.testing.expectEqual(@as(usize, 0), screen.count("Saved thinking level not applied"));
            try std.testing.expectEqual(screen.rows - ui.frame_composer_rows, try rowStartingWith(&screen, "(fixture-old) "));
            try std.testing.expectEqual(@as(usize, 1), screen.count("(fixture-old) "));
            try std.testing.expectEqual(screen.rows - 1, screen.row + ui.frame_cursor_rows_up);
            testAcknowledgeFullFrame(&ui);
            if (cycle == 0) {
                open_history = screen.history_len;
                open_height = ui.tail_height;
            } else {
                try std.testing.expectEqual(open_history, screen.history_len);
                try std.testing.expectEqual(open_height, ui.tail_height);
            }
            try ui.parser.feed("\x7f", sink);
            try ui.draw();
            try screen.replay(ui.frame);
            try expectLongWarningAdjacent(&screen, ui.frame_composer_rows, columns);
            try std.testing.expectEqual(screen.rows - 1, screen.row + ui.frame_cursor_rows_up);
            testAcknowledgeFullFrame(&ui);
            if (cycle == 0) {
                closed_history = screen.history_len;
                closed_height = ui.tail_height;
            } else {
                try std.testing.expectEqual(closed_history, screen.history_len);
                try std.testing.expectEqual(closed_height, ui.tail_height);
            }
        }
        const draft = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        try ui.parser.feed(draft, sink);
        try ui.draw();
        try std.testing.expect(ui.frame_composer_rows >= 2);
        try screen.replay(ui.frame);
        try expectLongWarningAdjacent(&screen, ui.frame_composer_rows, columns);
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        const wrapped_history = screen.history_len;
        const wrapped_height = ui.tail_height;
        try ui.draw();
        try screen.replay(ui.frame);
        try expectLongWarningAdjacent(&screen, ui.frame_composer_rows, columns);
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(wrapped_history, screen.history_len);
        try std.testing.expectEqual(wrapped_height, ui.tail_height);
    }
}

test "bottom composer stays anchored across draft and menu frames" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.draw();
    try std.testing.expect(ui.menu_history == null and !ui.tail_bottom);
    try std.testing.expectEqual(screen.rows - ui.frame_height, ui.frame_menu_history.?.above.len);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - ui.tail_height, ui.menu_history.?.above.len);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    const history_before_menu = screen.history_len;
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    try std.testing.expectEqual(history_before_menu, screen.history_len);
    try Ui.key(&ui, .escape);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    try ui.parser.feed("a long draft that wraps across the composer and stays fixed on the bottom row of the terminal", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
}

test "idle Enter releases exactly one native row and redraw keeps the live draft" {
    for ([_]usize{ 80, 16 }) |columns| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.size.columns = columns;
        var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = columns };
        try seedPriorBottom(&screen);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        const history_start = screen.history_len;
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        // A read batch can contain several blank lines and then a new draft.
        try ui.parser.feed(" \t\r\r\rtyped", sink);
        try std.testing.expectEqual(@as(u16, 3), ui.idle_breaks);
        try std.testing.expectEqualStrings("typed", ui.editor.bytes.items);
        try ui.draw();
        try std.testing.expectEqual(@as(u16, 3), ui.frame_idle_breaks);
        try std.testing.expectEqual(@as(usize, 1), ui.frame_height);
        try screen.replay(ui.frame);
        try std.testing.expectEqual(history_start + 3, screen.history_len);
        try std.testing.expectEqual(@as(usize, 4), screen.count("?%>"));
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
        try std.testing.expect(ui.future == null and !ui.busy and !ui.has_submitted and ui.prompt == null);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
        try std.testing.expect(ui.menu_history != null and ui.menu_history.?.above.len != 0);
        var expected_history = history_start + 3;
        for (0..3) |_| {
            const old_height = ui.tail_height;
            try ui.draw();
            // The narrow fixture now soft-wraps "typed". Its footer expansion
            // may grow native rows once, but cannot release another idle LF.
            try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
            expected_history += ui.frame_height -| old_height;
            try screen.replay(ui.frame);
            testAcknowledgeFullFrame(&ui);
            try std.testing.expectEqual(expected_history, screen.history_len);
            try std.testing.expectEqual(@as(usize, 4), screen.count("?%>"));
        }
        try std.testing.expectEqualStrings("typed", ui.editor.bytes.items);
        // A subsequent ordinary nonempty Enter still follows submit, not the
        // display-only path (this intentionally unconfigured fixture has no API).
        try Ui.key(&ui, .enter);
        try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
        try std.testing.expectEqualStrings("", ui.editor.bytes.items);
        try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    }
}

test "idle Enter bounded stages retain more than one frame of line requests" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try seedPriorBottom(&screen);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const old_history = screen.history_len;
    for (0..300) |_| try Ui.key(&ui, .enter);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 256), ui.frame_idle_breaks);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u16, 44), ui.idle_breaks);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 44), ui.frame_idle_breaks);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    try std.testing.expectEqual(old_history + 300, screen.history_len);
    try std.testing.expectEqual(@as(usize, 301), screen.count("?%>"));
}

test "idle Enter rejects paste queue permission and undrained bridge provenance" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~ \r\x1b[201~\r", sink);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    ui.wipeEditor();
    bridge.outstanding = 1;
    try std.testing.expect(!ui.idleEnter());
    bridge.outstanding = 0;
    bridge.active = 1;
    try std.testing.expect(!ui.idleEnter());
    bridge.active = 0;
    bridge.pending = 1;
    try std.testing.expect(!ui.idleEnter());
    bridge.pending = null;
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .text = "not yet drained" }, &cancel);
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    var item = bridge.pop().?;
    try std.testing.expect(!ui.idleEnter());
    item.deinit();
    ui.parser.batch_paste = false;
    ui.parser.pasted = false;
    ui.editor_pasted = false;
    try std.testing.expect(ui.idleEnter());
    ui.busy = true;
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    ui.busy = false;
    ui.stop_open = true;
    try std.testing.expect(!ui.idleEnter());
    ui.stop_open = false;
    ui.future = @as(Io.Future(void), undefined);
    try std.testing.expect(!ui.idleEnter());
    ui.future = null;
    ui.settings_open = true;
    try std.testing.expect(!ui.idleEnter());
    ui.settings_open = false;
    ui.size.columns = 8;
    try std.testing.expect(!ui.idleEnter());
    ui.size.columns = 80;
    ui.size.rows = 6;
    try std.testing.expect(!ui.idleEnter());
    ui.size.rows = 24;
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "pending");
    try std.testing.expect(!ui.idleEnter());
}

test "idle Enter precedes rapid nonempty submit and preserves following draft" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\r\rquestion\rnext draft", sink);
    try std.testing.expect(ui.deferred_submit != null);
    try std.testing.expectEqualStrings("question", ui.deferred_submit.?.editor.bytes.items);
    try std.testing.expectEqualStrings("next draft", ui.editor.bytes.items);
    try std.testing.expect(ui.future == null and !ui.has_submitted);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 2), ui.frame_idle_breaks);
    try ui.flushDeferredSubmit();
    try std.testing.expect(ui.deferred_submit != null and !ui.has_submitted);
    testAcknowledgeFullFrame(&ui);
    try ui.flushDeferredSubmit();
    try std.testing.expect(ui.deferred_submit == null and !ui.has_submitted);
    try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
    try std.testing.expectEqualStrings("next draft", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}

test "idle Enter does not release an acknowledged draft erased in the same read batch" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("deleted-draft", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), screen.count("deleted-draft"));
    try ui.parser.feed("\x15\r", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), screen.count("deleted-draft"));
    try std.testing.expectEqual(@as(usize, 2), screen.count("?%>"));
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .escape);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), screen.count("deleted-draft"));
}

test "rendered unacknowledged body window applies admission pressure" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.assistant, "");
    ui.draft = index;
    const bytes = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try ui.records.items[index].append(std.testing.allocator, bytes);
    const body = ui.records.items[index].stream.?;
    try body.build();
    // Parsing is sliced: the first window is bounded and the remainder is still
    // queued, which is exactly the admission-pressure signal.
    try std.testing.expect(body.pendingBytes() != 0);
    try std.testing.expect(body.stats.max_window_bytes <= 4 * 1024 + 64 * 1024 + 2048);
    try std.testing.expectEqual(@as(usize, 128 * 1024), body.windowBytes());
    try std.testing.expect(ui.displayBackpressured());
    body.abort();
}

test "large history restore retains bounded visible suffix" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var messages: [100]p.Message = undefined;
    for (&messages) |*message| message.* = .{ .role = .user, .blocks = &.{.{ .text = "restored" }} };
    try ui.restoreHistory(&messages);
    try std.testing.expectEqual(@as(usize, 64), ui.records.items.len);
    try std.testing.expect(ui.dropped_display);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[0].body.items, "display may be shortened") != null);
}

test "restore mixed long multi-block assistants stays within byte budget" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const chunk = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'x');
    const blocks = [_]p.Block{ .{ .text = chunk }, .{ .text = chunk } };
    var messages: [24]p.Message = undefined;
    for (&messages, 0..) |*message, i| {
        message.* = if (i % 2 == 0)
            .{ .role = .assistant, .blocks = &blocks }
        else
            .{ .role = .user, .blocks = &.{.{ .text = "short" }} };
    }
    try ui.restoreHistory(&messages);
    var bytes: usize = 0;
    for (ui.records.items) |record| bytes += record.body.items.len;
    try std.testing.expect(bytes <= 1024 * 1024);
    try std.testing.expect(ui.records.items.len <= 64);
    try std.testing.expect(ui.dropped_display);
    try std.testing.expectEqualStrings("short", ui.records.items[ui.records.items.len - 1].body.items);
}

test "normal admission never evicts unprinted records" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    for (0..64) |_| _ = try ui.add(.user, "pending");
    try std.testing.expectError(error.DisplayCapacity, ui.add(.user, "overflow"));
    try std.testing.expectEqual(@as(usize, 64), ui.records.items.len);
    try std.testing.expect(!ui.dropped_display);
}

test "real frame ignores a record removed before ack" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const first = try ui.add(.user, "old pending");
    try ui.draw();
    const id = ui.records.items[first].id;
    ui.removeRecord(first);
    const second = try ui.add(.user, "new pending");
    try std.testing.expect(ui.records.items[second].id != id);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(!ui.records.items[second].output);
}

test "frame descriptor keeps its checkpoint across stream append" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 80, .rows = 7 };
    const index = try ui.add(.assistant, "one\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix\n\nseven\n\n");
    ui.draft = index;
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 1), ui.frame_records.len);
    const checkpoint = ui.frame_records[0].stream_rows;
    try std.testing.expect(checkpoint != 0);
    const generation = ui.frame_records[0].generation;
    try ui.records.items[index].append(std.testing.allocator, "later\n");
    try std.testing.expectEqual(checkpoint, ui.frame_records[0].stream_rows);
    try std.testing.expectEqual(generation, ui.records.items[index].stream_generation);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(checkpoint, ui.records.items[index].stream_written);
    try std.testing.expect(!ui.records.items[index].output);
}

test "frame descriptors ignore removed and replaced records" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.assistant, "first");
    const id = ui.records.items[index].id;
    var entries = [_]FrameRecord{.{ .record_id = id, .generation = ui.records.items[index].stream_generation, .output_candidate = true }};
    try ui.records.items[index].resetStream();
    ui.frame_records = &entries;
    ui.frame = "x";
    ui.frame_fresh = true;
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(!ui.records.items[index].output);
    ui.removeRecord(index);
    try std.testing.expect(ui.record_index.get(id) == null);
    entries[0] = .{ .record_id = id, .generation = 0, .output_candidate = true };
    ui.frame_records = &entries;
    ui.frame = "x";
    testAcknowledgeFullFrame(&ui);
}

test "resize ABA discards frame checkpoint and fresh draw can commit" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 80, .rows = 24 };
    const index = try ui.add(.user, "resize pending");
    try ui.draw();
    ui.resize(.{ .columns = 70, .rows = 24 });
    ui.resize(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(!ui.records.items[index].output);
    try std.testing.expectEqual(@as(usize, 0), ui.frame_records.len);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].output);
}

test "frame abort keeps unacknowledged record" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.assistant, "first");
    var entries = [_]FrameRecord{.{ .record_id = ui.records.items[index].id, .generation = ui.records.items[index].stream_generation, .output_candidate = true }};
    ui.frame_records = &entries;
    ui.discardResizedFrame();
    try std.testing.expect(!ui.records.items[index].output);
    try std.testing.expect(ui.records.items[index].stream != null);
}

test "eviction requires acknowledged inactive record without frame state" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.user, "pending");
    try std.testing.expect(!ui.canEvictOldest());
    ui.records.items[index].output = true;
    try std.testing.expect(ui.canEvictOldest());
    ui.records.items[index].pending_output = true;
    try std.testing.expect(!ui.canEvictOldest());
    ui.records.items[index].pending_output = false;
    ui.draft = index;
    try std.testing.expect(!ui.canEvictOldest());
    ui.draft = null;
    ui.records.items[index].pending_flow_change = true;
    try std.testing.expect(!ui.canEvictOldest());
}

test "idle Enter waits for pending transcript output before releasing prompt rows" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    var record = Record{ .kind = .user };
    try record.append(std.testing.allocator, "pending-output");
    try ui.record_index.ensureUnusedCapacity(std.testing.allocator, 1);
    try ui.records.append(std.testing.allocator, record);
    try ui.registerRecord(ui.records.items.len - 1);
    try Ui.key(&ui, .enter);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
    try std.testing.expect(ui.records.items[0].pending_output);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 1), ui.frame_idle_breaks);
    testAcknowledgeFullFrame(&ui);
}

test "idle Enter display barrier also precedes a rapid compact command" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r/compact\r", .{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expect(ui.deferred_submit != null);
    try std.testing.expectEqualStrings("/compact", ui.deferred_submit.?.editor.bytes.items);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 1), ui.frame_idle_breaks);
    try ui.flushDeferredSubmit();
    try std.testing.expect(ui.deferred_submit != null);
    testAcknowledgeFullFrame(&ui);
    try ui.flushDeferredSubmit();
    try std.testing.expect(ui.deferred_submit == null and ui.future == null);
    try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
}

test "idle Enter acknowledged prompts survive a command popup without duplication" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    for (0..3) |_| try Ui.key(&ui, .enter);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const old_history = screen.history_len;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.menu_history.?.borrowed.len != 0);
    try Ui.key(&ui, .escape);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(old_history, screen.history_len);
    try std.testing.expectEqual(@as(usize, 4), screen.count("?%>"));
    // Releasing this restored bottom-anchored tail keeps every prompt once.
    try Ui.key(&ui, .enter);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(old_history + 1, screen.history_len);
    try std.testing.expectEqual(@as(usize, 5), screen.count("?%>"));
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .escape);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 5), screen.count("?%>"));
}

test "idle Enter keeps a newly published diagnostic visible across redraws" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .enter);
    ui.notice = "new-safety-diagnostic";
    for (0..3) |_| {
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(screen.visible("new-safety-diagnostic"));
    }
    try std.testing.expect(!ui.compact_composer);
}

test "idle Enter resize at every frame byte never replays or drops CRLF" {
    var frame_length: usize = 1;
    var offset: usize = 0;
    while (offset < frame_length) : (offset += 1) {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try Ui.key(&ui, .enter);
        try Ui.key(&ui, .enter);
        try ui.draw();
        frame_length = ui.frame.len;
        const prefix_end = ui.frame_idle_prefix_end;
        const sent = std.mem.count(u8, ui.frame[0..@min(offset, prefix_end)], "\n");
        ui.frame_offset = offset;
        ui.resize(.{ .columns = 40, .rows = 24 });
        const remaining: u16 = @intCast(2 - sent);
        try std.testing.expectEqual(remaining, ui.idle_breaks);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.resize_rescue, "\n"));
        const rescue = ui.resize_rescue;
        ui.resize(.{ .columns = 16, .rows = 24 });
        try std.testing.expectEqualStrings(rescue, ui.resize_rescue);
        try std.testing.expect(ui.frame.len == 0 and ui.frame_offset == 0 and !ui.frame_fresh);
        ui.finishFrame(); // Discarded old frames cannot consume pending requests.
        try std.testing.expectEqual(remaining, ui.idle_breaks);
        try std.testing.expect(ui.tail_snapshot == null);
        ui.resize_rescue = ""; // Simulate the controls-only cleanup being written.
        try ui.draw();
        try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui); // Establish a fresh-width composer first.
        try ui.draw();
        try std.testing.expectEqual(remaining, ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    }
}

fn idleEnterAllocationScenario(a: std.mem.Allocator) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .enter);
    _ = try ui.editor.insert("draft survives OOM");
    ui.allocator = a;
    ui.draw() catch |err| {
        try std.testing.expectEqual(@as(u16, 1), ui.idle_breaks);
        try std.testing.expectEqualStrings("draft survives OOM", ui.editor.bytes.items);
        try std.testing.expect(ui.frame.len == 0 and ui.frame_idle_breaks == 0);
        return if (err == error.WriteFailed) error.OutOfMemory else err;
    };
    testAcknowledgeFullFrame(&ui);
}

test "idle Enter captured before resize waits until a supported composer is acknowledged" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .enter);
    ui.resize(.{ .columns = 1, .rows = 24 });
    for (0..2) |_| {
        try ui.draw();
        try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(u16, 1), ui.idle_breaks);
    }
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 1), ui.frame_idle_breaks);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
}

test "idle Enter waits quietly after partial frame shrinks below supported size" {
    for ([_]terminal_module.Size{ .{ .columns = 8, .rows = 24 }, .{ .columns = 80, .rows = 6 }, .{ .columns = 8, .rows = 6 } }) |small| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        try ui.draw();
        ui.dirty = false;
        testAcknowledgeFullFrame(&ui);
        try Ui.key(&ui, .enter);
        try Ui.key(&ui, .enter);
        try ui.draw();
        ui.dirty = false;
        ui.frame_offset = 1; // No accepted LF has reached the terminal yet.
        ui.resize(small);
        ui.resize_rescue = ""; // Simulate controls-only cleanup being written.
        try std.testing.expect(ui.drawReady());
        try ui.draw();
        ui.dirty = false;
        try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui);
        for (0..4) |_| {
            ui.clock_ms += 80;
            ui.animate();
            try std.testing.expect(!ui.drawReady());
            try std.testing.expectEqual(@as(u16, 2), ui.idle_breaks);
        }
        ui.resize(.{ .columns = 80, .rows = 24 });
        try std.testing.expect(ui.drawReady());
        try ui.draw();
        ui.dirty = false;
        try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui); // The new supported composer is now fully ACKed.
        try std.testing.expect(ui.drawReady());
        try ui.draw();
        ui.dirty = false;
        try std.testing.expectEqual(@as(u16, 2), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
        try ui.draw();
        ui.dirty = false;
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(!ui.drawReady());
    }
}

test "idle Enter staging OOM keeps request draft and acknowledged ownership" {
    // Optional arena resize/remap can change allocation counts after an injected
    // failure. As in tailAllocationScenario, deny backing growth deterministically
    // while still exercising every required fresh allocation and leak check.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), idleEnterAllocationScenario, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
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
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Command exited with status 7") == null);
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
    for ([_][]const u8{ "**literal**", "visible-error", "Command exited with status 7" }) |label| try std.testing.expectEqual(@as(usize, 1), screen.count(label));
    for ([_][]const u8{ "stdout:", "stderr:", "exit:", "output encoding:" }) |label| try std.testing.expectEqual(@as(usize, 0), screen.count(label));
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
    for ([_][]const u8{ "restored-stream", "restored-error", "Command exited with status 7" }) |label| try std.testing.expectEqual(@as(usize, 1), screen.count(label));
    for ([_][]const u8{ "stdout:", "stderr:", "exit:", "output encoding:" }) |label| try std.testing.expectEqual(@as(usize, 0), screen.count(label));
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

test "regular transcript writes committed rows above a natural composer tail without role tags" {
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
    // One released user row above the gap+draft body and the hinted composer.
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expect(std.mem.find(u8, &screen.grid[screen.rows - 1 - ui.frame_height], "unique committed user") != null);
    try std.testing.expect(!ui.records.items[0].output);
    try std.testing.expectEqual(@as(usize, 5), ui.frame_height); // One committed user row, no full-screen padding.
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[0].output);
    try std.testing.expect(!ui.records.items[1].output);
    try ui.replaceCommitted(&.{.{ .text = "unique canonical reply" }}, false, true);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique committed user") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "uncanonical draft") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique canonical reply") != null);
    try std.testing.expectEqual(@as(usize, 3), ui.frame_height); // Leading gap + canonical body, no title.
    try screen.replay(ui.frame);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expectEqual(@as(usize, 1), screen.count("unique canonical reply"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique canonical reply") == null);
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[2A"));
    for ([_][]const u8{ "1049", "1047", "\x1b[H", "\x1b[2J", ";1H" }) |forbidden|
        try std.testing.expect(std.mem.find(u8, ui.frame, forbidden) == null);
}

test "static assistant EOF drains once without phantom transcript rows" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.assistant, "static-row-one\nstatic-row-two");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].output);
    try std.testing.expect(ui.records.items[index].stream.?.isDrained());
    const before = screen.grid;
    const history_before = screen.history_len;
    const above_before = ui.menu_history.?.above.len;
    try ui.draw();
    try std.testing.expectEqual(above_before, ui.frame_menu_history.?.above.len);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(history_before, screen.history_len);
    for (before[0 .. ui.size.rows - 2], screen.grid[0 .. ui.size.rows - 2]) |old, actual|
        try std.testing.expectEqualStrings(&old, &actual);
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    try ui.draw();
    // Opening a menu may borrow owned rows, but cannot append new transcript.
    const menu_history = ui.frame_menu_history.?;
    try std.testing.expectEqual(above_before, menu_history.above.len + menu_history.borrowed.len);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(history_before, screen.history_len);
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
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(usize, 3), ui.tail_height);
        try std.testing.expectEqual(@as(usize, 23), screen.row);

        try ui.appendDraft(.assistant, "growth-draft-marker\nsecond-draft-line");
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(usize, 6), ui.tail_height); // Gap + two draft rows + hinted footer; no preview-title row.
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        const draft_row = screen.row;
        for (screen.history[0..screen.history_len]) |line| try std.testing.expect(std.mem.find(u8, &line, "growth-draft-marker") == null);

        try ui.replaceCommitted(&.{.{ .text = if (same_final) "growth-draft-marker" else "different-final-marker" }}, false, true);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(usize, @intFromBool(same_final)), screen.count("growth-draft-marker"));
        try std.testing.expectEqual(@as(usize, @intFromBool(!same_final)), screen.count("different-final-marker"));
        try std.testing.expectEqual(@as(usize, 0), screen.count("second-draft-line"));
        // The released rows plus reused tail preserve the physical bottom.
        try std.testing.expectEqual(draft_row, screen.row);
        try std.testing.expectEqual(@as(usize, 4), ui.tail_height);
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
        // Two released user rows and the live reasoning stay above the footer.
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        try ui.appendDraft(.reasoning, "\nthink-new\nthink-new-last");
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "think-last");
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        try ui.appendDraft(.assistant, "live-start\nlive-end");
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "live-start");
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        try std.testing.expectEqual(@as(usize, 0), screen.count("think-"));
        try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Streaming") == null);
        try std.testing.expect(std.mem.indexOf(u8, ui.frame, "History preview") == null);
        testAcknowledgeFullFrame(&ui);
        // Growing native history preserves the original start and its gap,
        // instead of clipping the stream into a moving last-screen window.
        for (0..60) |i| {
            const delta = try std.fmt.allocPrint(std.testing.allocator, "\nlive-line-{d}", .{i});
            defer std.testing.allocator.free(delta);
            try ui.appendDraft(.assistant, delta);
        }
        const prior_tail = ui.tail_height;
        try ui.draw();
        // draw stages a new tail; tail_height remains the prior complete ACK.
        try std.testing.expectEqual(prior_tail, ui.tail_height);
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "live-start");
        try std.testing.expect(screen.count("live-line-") > 0);
        try std.testing.expectEqual(@as(usize, 1), screen.count("user-row-end"));
        // The draft grew past the window, so its tail ends on the physical bottom
        // without necessarily owning every physical row.
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        // The staged footprint is the remaining draft rows after the pending
        // released prefix, plus any fresh leading gap and the fixture footer,
        // clamped to the physical window. A short bottom-anchored tail is valid.
        const draft_record = &ui.records.items[ui.draft.?];
        const released = draft_record.pending_stream_rows;
        try std.testing.expect(released != 0);
        const remaining = draft_record.lines.len -| released;
        const leading_gap: usize = @intFromBool(released == 0);
        const fixture_footer_rows: usize = 3; // notice, separator, composer
        const staged = @min(ui.size.rows, remaining + leading_gap + fixture_footer_rows);
        try std.testing.expectEqual(staged, ui.frame_height);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(staged, ui.tail_height);
        // First row owned by the ACKed tail: the revision frame starts here.
        try ui.replaceCommitted(&.{.{ .text = "formal-final" }}, false, true);
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "Response revised", "formal-final");
        try std.testing.expectEqual(@as(usize, 1), screen.count("formal-final"));
        try std.testing.expect(screen.count("live-line-") > 0);
        try std.testing.expectEqual(@as(usize, 1), screen.count("user-row-end"));
        // The revision and its footer remain anchored at the physical bottom.
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
    }
}

test "composer history arrows require exact origin while slash arrows only select commands" {
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
    try ui.parser.feed("\x15\x1b[A\x1b[F-edited\x1b[A\x1b[B", sink);
    try std.testing.expectEqualStrings("second-edited", ui.editor.bytes.items);
    try std.testing.expect(ui.input_history.index == null);
    try ui.parser.feed("\x15/\x1b[B", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    try std.testing.expectEqual(command_menu_module.Command.auth, ui.command_menu.choice(ui.command_matches).?);
    try std.testing.expect(!ui.busy and ui.future == null); // Browsing is never submission.
    ui.wipeEditor();
    ui.beginSecret(null);
    try ui.parser.feed("fake-secret-never-history", sink);
    ui.endSecret();
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("second", ui.input_history.target(false).?.text);
}

test "composer arrows move visual rows and only exact origin browses history with draft restoration" {
    const a = std.testing.allocator;
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 30, .rows = 12 };
    for ([_][]const u8{ "older", "newer" }) |message|
        ui.input_history.commit(a, try ui.input_history.prepare(a, message));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const prepared = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 29);
    const width = 29 - text.width(prepared.decoration.plain);
    const draft = try a.alloc(u8, width * 3 + 3);
    defer a.free(draft);
    @memset(draft, 'x');
    _ = try ui.editor.insert(draft);
    ui.editor_pasted = true;
    ui.editor.cursor = width * 2 + 2;
    try Ui.key(&ui, .up);
    try std.testing.expectEqual(width + 2, ui.editor.cursor);
    try Ui.key(&ui, .up);
    try std.testing.expectEqual(@as(usize, 2), ui.editor.cursor);
    try Ui.key(&ui, .up); // Top row, nonzero column: never browse history.
    try std.testing.expectEqual(@as(usize, 2), ui.editor.cursor);
    try std.testing.expect(ui.input_history.index == null);
    try Ui.key(&ui, .down);
    try std.testing.expectEqual(width + 2, ui.editor.cursor);
    try std.testing.expectEqualStrings(draft, ui.editor.bytes.items);
    try Ui.key(&ui, .home);
    try Ui.key(&ui, .up);
    try std.testing.expectEqualStrings("newer", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.cursor);
    try Ui.key(&ui, .up);
    try std.testing.expectEqualStrings("older", ui.editor.bytes.items);
    try Ui.key(&ui, .down);
    try std.testing.expectEqualStrings("newer", ui.editor.bytes.items);
    try Ui.key(&ui, .down);
    try std.testing.expectEqualStrings(draft, ui.editor.bytes.items);
    try std.testing.expect(ui.editor_pasted and ui.history_draft == null and ui.input_history.index == null);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.cursor);
    try std.testing.expect(!ui.busy and ui.future == null);
}

fn composerHistoryAllocationScenario(a: std.mem.Allocator) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.allocator = a;
    ui.editor.allocator = a;
    defer ui.deinit();
    ui.input_history.commit(a, try ui.input_history.prepare(a, "submitted"));
    _ = try ui.editor.insert("unsent draft");
    ui.editor.cursor = 0;
    ui.editor_pasted = true;
    ui.navigateInput(false) catch |err| {
        try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
        try std.testing.expectEqual(@as(usize, 0), ui.editor.cursor);
        try std.testing.expect(ui.editor_pasted and ui.history_draft == null and ui.input_history.index == null);
        return err;
    };
    try std.testing.expectEqualStrings("submitted", ui.editor.bytes.items);
    try ui.navigateInput(true);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    try std.testing.expect(ui.editor_pasted);
}

test "composer history replacement allocation failure preserves original draft ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, composerHistoryAllocationScenario, .{});
}

fn composerHistoryEditAllocationScenario(a: std.mem.Allocator) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.allocator = a;
    ui.editor.allocator = a;
    defer ui.deinit();
    ui.input_history.commit(a, try ui.input_history.prepare(a, "submitted"));
    _ = try ui.editor.insert("pasted draft");
    ui.editor.cursor = 0;
    ui.editor_pasted = true;
    try ui.navigateInput(false);
    Ui.key(&ui, .{ .text = .{ .value = "x", .pasted = false } }) catch |err| {
        try std.testing.expectEqualStrings("submitted", ui.editor.bytes.items);
        try std.testing.expect(ui.input_history.index != null);
        try std.testing.expect(ui.history_draft != null and ui.history_draft_pasted);
        return err;
    };
    try std.testing.expectEqualStrings("xsubmitted", ui.editor.bytes.items);
    try std.testing.expect(ui.input_history.index == null and ui.history_draft == null);
}

test "editing recalled history commits draft ownership only after insertion succeeds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, composerHistoryEditAllocationScenario, .{});

    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const full = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(full);
    @memset(full, 'h');
    ui.input_history.commit(std.testing.allocator, try ui.input_history.prepare(std.testing.allocator, full));
    _ = try ui.editor.insert("draft");
    ui.editor.cursor = 0;
    ui.editor_pasted = true;
    try ui.navigateInput(false);
    try Ui.key(&ui, .{ .text = .{ .value = "x", .pasted = false } });
    try std.testing.expectEqual(@as(usize, 65536), ui.editor.bytes.items.len);
    try std.testing.expect(ui.input_history.index != null and ui.history_draft != null);
    try ui.navigateInput(true);
    try std.testing.expectEqualStrings("draft", ui.editor.bytes.items);
    try std.testing.expect(ui.editor_pasted);
}

test "Escape protects draft then cancels active task only from empty input" {
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
    try std.testing.expect(!cancel.isRequested() and !ui.want_exit and !ui.ctrl_d_exit);
    try std.testing.expectEqualStrings("draft-next", ui.editor.bytes.items);
    ui.wipeEditor();
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(cancel.isRequested());
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
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expectEqual(@as(usize, 3), ui.tail_height);
    try std.testing.expect(try ui.idleExitBytes(&writer));
    try screen.replay(writer.buffered());
    try screen.replay("\r\nshell-next");
    try std.testing.expectEqual(@as(usize, 0), screen.count("Session ID:"));
    try std.testing.expectEqual(screen.rows - ui.tail_height + 1, screen.row);
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
    // Three reasoning rows above the separator, the fixture notice and the composer.
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expectEqual(@as(usize, 6), ui.frame_height);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(!ui.records.items[0].output);
    try ui.appendDraft(.reasoning, "\nthink-five\nthink-six");
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("think-two") and !screen.visible("think-three"));
    for ([_][]const u8{ "think-four", "think-five", "think-six" }) |marker| try std.testing.expect(screen.visible(marker));
    for (screen.history[0..screen.history_len]) |line| try std.testing.expect(std.mem.find(u8, &line, "think-") == null);
    testAcknowledgeFullFrame(&ui);

    try ui.appendDraft(.assistant, "partial-answer\x1b[2J");
    try ui.appendDraft(.reasoning, "late-reasoning");
    try std.testing.expect(ui.reasoning == null);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("Thinking"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("think-"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("late-reasoning"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
    testAcknowledgeFullFrame(&ui);
    const draft = ui.draft.?;
    try std.testing.expect(!ui.records.items[draft].output);
    // Cancellation keeps only the unfinished visible answer, explicitly marked.
    ui.records.items[draft].interrupted = true;
    ui.draft = null;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("Interrupted response"));
    testAcknowledgeFullFrame(&ui);
    // PageUp is terminal-native history: it must not regroup completed records
    // or repaint reasoning into this frame.
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[5~", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "History preview") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "think-") == null);
    testAcknowledgeFullFrame(&ui);
}

test "reasoning grows from a small acknowledged tail and hides reversibly" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const small_tail = ui.tail_height;
    try std.testing.expect(small_tail != 0 and small_tail < 6);
    try ui.appendDraft(.reasoning, "think-a\nthink-b\nthink-c");
    try ui.draw();
    try screen.replay(ui.frame);
    for ([_][]const u8{ "think-a", "think-b", "think-c" }) |marker| try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
    try std.testing.expect(ui.frame_height > small_tail); // Growth, not a hidden reasoning row.
    testAcknowledgeFullFrame(&ui);
    // There was no ACKed row above the small tail to borrow, so every new row
    // grew naturally and no reasoning row entered native history.
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
    for (screen.history[0..screen.history_len]) |line| try std.testing.expect(std.mem.find(u8, &line, "think-") == null);
    ui.show_reasoning = false;
    try ui.draw();
    try screen.replay(ui.frame);
    for ([_][]const u8{ "think-a", "think-b", "think-c" }) |marker| try std.testing.expect(!screen.visible(marker));
    testAcknowledgeFullFrame(&ui);
    ui.show_reasoning = true;
    try ui.draw();
    try screen.replay(ui.frame);
    for ([_][]const u8{ "think-a", "think-b", "think-c" }) |marker| try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
    testAcknowledgeFullFrame(&ui);
}

test "rolling thinking keeps a bounded incremental tail and can be hidden" {
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
    const tail = record.tail.?;
    // The record never retains the stream body; the tail owns a bounded window.
    try std.testing.expectEqual(@as(usize, 0), record.body.items.len);
    try std.testing.expectEqual(reasoning_tail_rows, tail.keepRows());
    try std.testing.expectEqual(plain_tail.Limit.none, tail.limitState());
    try std.testing.expect(tail.retainedBytes() <= reasoning_tail_bytes);
    try std.testing.expect(tail.ownedBytes() <= tail.ownedBound());
    try std.testing.expect(tail.retainedSource().len <= reasoning_tail_bytes);
    try std.testing.expect(tail.retainedBytes() < large.len);
    try std.testing.expect(std.mem.endsWith(u8, tail.retainedSource(), "newest-thinking"));
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("newest-thinking"));
    testAcknowledgeFullFrame(&ui);
    // A redraw/layout never re-consumes or extends the retained source. Sparse
    // diffs may omit unchanged glyphs, so assert the replayed screen instead of
    // raw frame bytes.
    const source_len = tail.retainedSource().len;
    const retained = tail.retainedBytes();
    record.invalidate();
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("newest-thinking"));
    try std.testing.expectEqual(source_len, tail.retainedSource().len);
    try std.testing.expectEqual(retained, tail.retainedBytes());
    testAcknowledgeFullFrame(&ui);
    ui.show_reasoning = false;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("newest-thinking"));
    testAcknowledgeFullFrame(&ui);
    ui.show_reasoning = true;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("newest-thinking"));
    testAcknowledgeFullFrame(&ui);
    // The bounded/source invariants above were proven on the live owner while
    // it still existed. Cancellation deinitializes that tail, so the proof after
    // the discard must be about ownership, never about dereferencing `tail`.
    ui.discardReasoning(); // Same cancellation cleanup as complete.
    try std.testing.expect(ui.reasoning == null);
    // The fixture holds no other Record, so removal left no reasoning owner and
    // no draft: every retained reasoning byte was released with its tail.
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expect(ui.draft == null);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("newest-thinking"));
    testAcknowledgeFullFrame(&ui);
}

/// Shared plain renderer reference: the exact Writer settings the bounded tail
/// uses, so a live tail can be compared byte-for-byte at a given width.
fn plainWidthRows(a: std.mem.Allocator, columns: usize, body: []const u8, out: *std.ArrayList([]u8)) !void {
    const writer_module = @import("markdown_writer.zig");
    const display_text = @import("../util/display_text.zig");
    const clean = try display_text.sanitize(a, body, 1 << 20);
    defer a.free(clean);
    var w: writer_module.Writer = .{ .a = a, .columns = std.math.clamp(columns, 1, 512), .ansi = true, .base = .thinking };
    defer w.deinit();
    try w.emit(clean);
    try w.finish();
    for (w.lines.items) |row| try out.append(a, try a.dupe(u8, row));
}

fn expectTailMatchesPlain(tail: *plain_tail.Tail, columns: usize, body: []const u8) !void {
    const a = std.testing.allocator;
    var want: std.ArrayList([]u8) = .empty;
    defer {
        for (want.items) |row| a.free(row);
        want.deinit(a);
    }
    try plainWidthRows(a, columns, body, &want);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    const count = @min(tail.keepRows(), want.items.len);
    try std.testing.expectEqual(count, snap.rows.len);
    const expected = want.items[want.items.len - count ..];
    for (expected, snap.rows) |e, got| try std.testing.expectEqualStrings(e, got);
}

test "live reasoning tail is created at the drawing width before its first layout" {
    try text.initLocale();
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    // draw() never uses the raw terminal width: it reserves one column so the
    // terminal cannot autowrap.
    const draw_columns = @max(1, ui.size.columns -| 1);
    try std.testing.expect(draw_columns != ui.size.columns);
    // One long payload without a newline: at a stale width its first draw would
    // have to reflow rows that were already admitted at the wrong width and
    // could discard them, so the width must be right before any layout.
    var payload: [400]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));
    try ui.appendDraft(.reasoning, &payload);
    const record = &ui.records.items[ui.reasoning.?];
    const tail = record.tail.?;
    try std.testing.expectEqual(draw_columns, tail.columns());
    try expectTailMatchesPlain(tail, draw_columns, &payload);
    const retained = tail.retainedBytes();
    const source_len = tail.retainedSource().len;
    try ui.draw();
    // The first draw agrees instead of resizing the already-admitted rows.
    try std.testing.expectEqual(draw_columns, tail.columns());
    try std.testing.expectEqual(retained, tail.retainedBytes());
    try std.testing.expectEqual(source_len, tail.retainedSource().len);
    try std.testing.expectEqual(draw_columns, record.columns);
    try expectTailMatchesPlain(tail, draw_columns, &payload);
    testAcknowledgeFullFrame(&ui);
}

test "reasoning tail splits UTF8 chunks, wraps, and never resurrects old rows" {
    try text.initLocale();
    const a = std.testing.allocator;
    var record: Record = .{ .kind = .reasoning };
    defer record.deinit(a);
    const body = "forgotten-old-row\none\ntwo\nthree-has-wrap ab中文👍🏽cd";
    const emoji = std.mem.indexOf(u8, body, "👍🏽").?;
    // Split inside the four-byte emoji so the incremental carry must finish it.
    try record.append(a, body[0 .. emoji + 2]);
    try record.append(a, body[emoji + 2 ..]);
    try record.layout(a, 6);
    const tail = record.tail.?;
    try std.testing.expectEqual(@as(usize, 6), tail.columns());
    try std.testing.expect(record.lines.len <= reasoning_tail_rows);
    try std.testing.expect(record.lines.len >= 2); // narrow width wrapped
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(a);
    for (record.lines) |line| try joined.appendSlice(a, line);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "👍🏽") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "\u{fffd}") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "forgotten-old-row") == null);
    // Reflow only the retained window: the forgotten row cannot come back.
    try record.layout(a, 20);
    try std.testing.expectEqual(@as(usize, 20), tail.columns());
    var reflowed: std.ArrayList(u8) = .empty;
    defer reflowed.deinit(a);
    for (record.lines) |line| try reflowed.appendSlice(a, line);
    try std.testing.expect(std.mem.indexOf(u8, reflowed.items, "forgotten") == null);
    try std.testing.expect(std.mem.indexOf(u8, tail.retainedSource(), "forgotten") == null);
    try std.testing.expect(std.mem.indexOf(u8, reflowed.items, "👍🏽") != null);
}

test "thinking display limit marker is explicit and bounded" {
    try text.initLocale();
    const a = std.testing.allocator;
    var record: Record = .{ .kind = .reasoning };
    defer record.deinit(a);
    try record.append(a, "ok\na");
    for (0..5000) |_| try record.append(a, "\u{0301}");
    try record.layout(a, 80);
    const tail = record.tail.?;
    try std.testing.expectEqual(plain_tail.Limit.cluster, tail.limitState());
    try std.testing.expect(tail.retainedBytes() <= reasoning_tail_bytes);
    try std.testing.expect(record.lines.len <= reasoning_tail_rows + 1);
    const shown = record.lines[record.lines.len -| reasoning_tail_rows..];
    try std.testing.expect(std.mem.find(u8, shown[shown.len - 1], "thinking display limited: cluster; model history unchanged") != null);
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
    testAcknowledgeFullFrame(ui);
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
    testAcknowledgeFullFrame(&ui);
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
    screen.* = .{ .rows = 10 };
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
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
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
        testAcknowledgeFullFrame(&ui);
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
            try std.testing.expect(std.mem.find(u8, ui.frame, theme.tool_icon_pulse[0] ++ "w" ++ theme.muted ++ " preview.txt") != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "+3") == null);
        } else {
            try std.testing.expect(ui.active_tool == null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "preview.txt") != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "+3") != null);
        }
        testAcknowledgeFullFrame(&ui);
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
        const icon = if (std.mem.eql(u8, name, "bash")) ">" else if (std.mem.eql(u8, name, "memory")) "m" else if (std.mem.eql(u8, name, "read_file")) "r" else "w";
        const tool_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}", .{ theme.toolIconColor(0), icon, theme.muted });
        defer std.testing.allocator.free(tool_prefix);
        try std.testing.expect(std.mem.find(u8, ui.frame, tool_prefix) != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "#7") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "Running memory") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "Running bash") == null);
        testAcknowledgeFullFrame(&ui);
        ui.clock_ms = 120;
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, activity.spinner(120)) != null);
        testAcknowledgeFullFrame(&ui);
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
        testAcknowledgeFullFrame(&ui);
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
        testAcknowledgeFullFrame(&ui);
        const args = if (std.mem.eql(u8, name, "bash")) "{\"command\":\"target-one\"}" else if (std.mem.eql(u8, name, "memory")) "{\"action\":\"read\",\"topic\":\"target-one\"}" else "{\"path\":\"target-one\"}";
        try ui.captureToolCaptions(&.{.{ .tool_call = .{ .id = "gap-one", .name = name, .arguments = args } }});
        ui.active_tool = .{ .id = 1, .caption = try ui.nextToolCaption(name), .started_ms = 0 };
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "tool-user-end", "target-one");
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        try ui.toolCompleted(ui.active_tool.?.caption, .{ .text = "{}" });
        ui.clearActiveTool();
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "tool-user-end", "target-one");
        testAcknowledgeFullFrame(&ui);
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
        // Two released tool rows above the one-row tool body and hinted footer.
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
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
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
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
    // Both captions are contiguous at rows 0 and 1, so the second one is the
    // last body row; the separator, hint and composer follow it unchanged and
    // the cursor lands exactly three rows below the pending caption.
    try std.testing.expectEqual(pending_row.? + 3, screen.row);
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
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
        testAcknowledgeFullFrame(&ui);
        try ui.replaceCommitted(&.{block}, false, true);
        try std.testing.expect(ui.draft == null and ui.records.items.len == 1);
        try std.testing.expectEqual(Kind.user, ui.records.items[0].kind);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "Final answer") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "provisional-body") == null);
        testAcknowledgeFullFrame(&ui);
    }
}

test "file captions are contiguous but separated from final prose and percent context changes by value" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const call = try shared.tools.Call.init(std.testing.allocator, "write_file", "{\"path\":\"src/main.zig\",\"content\":\"do-not-show-body\"}");
    defer call.deinit(std.testing.allocator);
    const cap = try presentation.fromCall(std.testing.allocator, call);
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
    // Keep exact palette assertions independent of the already-established
    // bold prefix and its reset before editor text.
    const color_frame = try std.mem.replaceOwned(u8, std.testing.allocator, ui.frame, "\x1b[1m", "");
    defer std.testing.allocator.free(color_frame);
    try std.testing.expect(std.mem.find(u8, color_frame, "(" ++ theme.reset ++ "fixture" ++ theme.reset ++ ") " ++ theme.failure ++ "50.0%" ++ theme.reset ++ ">" ++ theme.reset ++ " ") != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("Final answer") and screen.visible("final-body-marker"));
    try expectTranscriptGap(&screen, "src/main.zig", "final-body-marker");
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 0), screen.count("=> Final answer"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("final-body-marker"));
    testAcknowledgeFullFrame(&ui);
}

test "committed large Markdown caches stay untouched across resize and PageUp" {
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
    testAcknowledgeFullFrame(&ui);
    // Active bodies are incremental: acknowledged source is gone, so there is
    // no committed cache to preserve. What matters is that nothing is replayed.
    try std.testing.expectEqual(@as(usize, 0), ui.records.items[0].stream.?.windowBytes() -| ui.records.items[0].stream.?.pendingBytes());
    ui.resize(.{ .columns = 41, .rows = 24 });
    try ui.draw();
    inline for (0..2) |i| {
        const record = &ui.records.items[i];
        try std.testing.expect(record.output or record.stream != null);
    }
    try std.testing.expect(std.mem.find(u8, ui.frame, "history-marker") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    // No program history preview path exists: committed records are never
    // re-laid out or replayed for a PageUp or a resize.
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    for (0..2) |_| try ui.parser.feed("\x1b[5~", sink);
    try ui.draw();
    inline for (0..2) |i| {
        try std.testing.expect(ui.records.items[i].stream != null);
    }
    try std.testing.expect(std.mem.find(u8, ui.frame, "history-marker") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 3), ui.tail_height);

    try ui.appendDraft(.assistant, "growth-draft-marker\nsecond-draft-line");
    try ui.draw();
    try std.testing.expect(!ui.frame_sparse);
    try expectSynchronizedFrame(ui.frame);
    // This expansion scrolls three rows. Supporting terminals must not publish
    // the intermediate state where draft rows have overwritten the old footer.
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);

    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try expectSynchronizedFrame(ui.frame);
    try std.testing.expect(std.mem.find(u8, ui.frame, "committed-") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
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
    try seedPriorBottom(&screen);
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
        testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "GHOST-preview-1\nGHOST-preview-2\nGHOST-preview-3\nGHOST-preview-4\nGHOST-preview-5\nGHOST-preview-6" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), screen.count("Approval #1"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("GHOST-preview"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("completed-tool-result"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("next-user-record"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("short-canonical-record"));
    try std.testing.expectEqual(screen.rows - 1, screen.row);
}

test "long approval Escape restores acknowledged conversation without blank screen or replay" {
    try text.initLocale();
    for (0..4) |scenario| {
        const pending_canonical = scenario & 1 != 0;
        const cancel_during_frame = scenario & 2 != 0;
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        _ = try ui.add(.user, "owned request before long approval");
        var body: Io.Writer.Allocating = .init(std.testing.allocator);
        defer body.deinit();
        for (0..18) |i| try body.writer.print("PRIOR-RESPONSE-{d:0>2}  \n", .{i});
        _ = try ui.add(.assistant, body.written());
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(screen.visible("PRIOR-RESPONSE-17"));
        const history_before = screen.history_len;
        const pending_index = ui.records.items.len;
        if (pending_canonical) {
            _ = try ui.add(.user, "new short request");
            _ = try ui.add(.assistant, "PENDING-CANONICAL-RESPONSE");
        }
        body.clearRetainingCapacity();
        for (0..64) |i| try body.writer.print("CANCEL-GHOST-PREVIEW-{d}: synthetic 中文\n", .{i});
        ui.busy = true;
        ui.mode = .awaiting_permission;
        const host = bridge.host();
        try host.emit_fn(host.context, .{ .permission = .{ .id = 14, .tool_name = "bash", .description = body.written() } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        // Force old-style repeated full preview draws independently of the
        // animation fix: closing the preview must still restore its exact rows.
        for (0..8) |tick| {
            try ui.draw();
            if (cancel_during_frame and tick == 7) {
                const split = std.mem.indexOf(u8, ui.frame, "\r\n").? + 2;
                try screen.replay(ui.frame[0..split]);
                ui.requestCancel(); // Cancel while the last preview is in flight.
                try screen.replay(ui.frame[split..]);
            } else try screen.replay(ui.frame);
            testAcknowledgeFullFrame(&ui);
        }
        try std.testing.expect(screen.visible("Approval #14"));
        const record_count = ui.records.items.len;
        if (pending_canonical) try std.testing.expect(!ui.records.items[pending_index].output);
        if (!cancel_during_frame) ui.requestCancel(); // Empty-draft/no-queue Esc.
        try std.testing.expect(cancel.isRequested());
        try std.testing.expect(ui.permission == null);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        if (!screen.visible("PRIOR-RESPONSE-17")) std.debug.print("APPROVAL_CANCEL pending_canonical={any} history_delta={d} retained_prior={d} prior_visible=false\n", .{ pending_canonical, screen.history_len -| history_before, screen.count("PRIOR-RESPONSE-") });
        try std.testing.expect(screen.visible("PRIOR-RESPONSE-17"));
        try std.testing.expectEqual(@as(usize, 18), screen.count("PRIOR-RESPONSE-"));
        try std.testing.expectEqual(@as(usize, 0), screen.count("Approval #14"));
        try std.testing.expectEqual(@as(usize, 0), screen.count("CANCEL-GHOST-PREVIEW"));
        try std.testing.expectEqual(record_count, ui.records.items.len);
        if (pending_canonical) {
            try std.testing.expect(ui.records.items[pending_index].output);
            try std.testing.expect(screen.visible("PENDING-CANONICAL-RESPONSE"));
            try std.testing.expectEqual(@as(usize, 1), screen.count("PENDING-CANONICAL-RESPONSE"));
        } else try std.testing.expectEqual(history_before, screen.history_len);
    }
}

test "approval restoration borrows only acknowledged same-width rows" {
    try text.initLocale();
    for (0..4) |scenario| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        _ = try ui.add(.assistant, "owned-0\nowned-1\nowned-2\nowned-3\nowned-4\nowned-5");
        try ui.draw();
        if (scenario == 1) ui.frame_fresh = false;
        testAcknowledgeFullFrame(&ui);
        if (scenario == 2) {
            ui.resize(.{ .columns = 79, .rows = 24 });
            ui.resize(.{ .columns = 80, .rows = 24 });
        }
        if (scenario == 3) ui.size.columns = 70;
        var description: Io.Writer.Allocating = .init(std.testing.allocator);
        defer description.deinit();
        for (0..32) |i| try description.writer.print("owned synthetic approval line {d}\n", .{i});
        const host = bridge.host();
        try host.emit_fn(host.context, .{ .permission = .{ .id = 14, .tool_name = "bash", .description = description.written() } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try ui.draw();
        const borrowed = ui.frame_menu_history.?.borrowed.len;
        if (scenario == 0) try std.testing.expect(borrowed != 0) else try std.testing.expectEqual(@as(usize, 0), borrowed);
        try std.testing.expect(ui.displayed_permission == null);
        testAcknowledgeFullFrame(&ui);
    }
}

test "approval waiting pulse never adds repeated prompts to native scrollback" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    ui.clock_ms = 80;
    ui.dirty = false;
    ui.animate();
    try std.testing.expect(ui.dirty); // Ordinary execution still animates.
    ui.mode = .awaiting_permission;
    _ = try ui.add(.user, "owned request before approval");
    _ = try ui.add(.assistant, "owned assistant before approval");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    var source: Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..125) |i| try source.writer.print("synthetic-step-{d}: Chinese 中文注释 only; abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz\n", .{i});
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 14, .tool_name = "bash", .description = source.written() } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const history_before = screen.history_len;
    try std.testing.expect(screen.visible("Approval #14"));
    ui.dirty = false;
    for (2..66) |tick| {
        ui.clock_ms = tick * 80;
        ui.animate();
        try std.testing.expect(!ui.dirty); // No key/event: no repeated preview.
        // Explicit redraws (input/events) must still preserve tail ownership.
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(history_before, screen.history_len);
        try std.testing.expectEqual(@as(usize, 1), screen.count("Approval #14"));
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        try std.testing.expectEqual(@as(?u64, 14), ui.displayed_permission);
    }
    ui.dirty = true;
    ui.clock_ms += 80;
    ui.animate();
    try std.testing.expect(ui.dirty); // Do not swallow a real event's repaint.
    ui.clearPermission();
    ui.dirty = false;
    ui.clock_ms += 80;
    ui.animate();
    try std.testing.expect(ui.dirty); // Animation resumes once approval ends.
    try std.testing.expect(!cancel.isRequested());
}

test "ordinary redraws coalesce from the previous draw start while input stays urgent" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    // Nothing pending: no idle redraw and no cadence wake-up is requested.
    ui.dirty = false;
    try std.testing.expect(!ui.drawReady() and !ui.drawDue());

    // Keyboard input is urgent but still waits for an already-started frame.
    ui.clock_ms = 1000;
    ui.urgent_draw = true;
    ui.dirty = true;
    try std.testing.expect(ui.drawDue());
    ui.frame = "partial";
    try std.testing.expect(!ui.drawDue());
    ui.frame = "";
    try ui.draw();
    try std.testing.expectEqual(@as(u64, 1000), ui.last_draw_ms);
    // Only staging that fresh draw consumes the urgent bit; draw() itself keeps
    // it so a caller cannot lose input without writing a frame.
    try std.testing.expect(ui.urgent_draw);
    ui.urgent_draw = false;
    testAcknowledgeFullFrame(&ui);
    ui.dirty = false;

    // Ordinary work waits only for the rest of the interval, never a new one.
    ui.clock_ms = 1005;
    ui.dirty = true;
    try std.testing.expect(!ui.drawDue());
    try std.testing.expectEqual(@as(u16, 3), ui.cadenceWaitMs());
    ui.clock_ms = 1007;
    try std.testing.expect(!ui.drawDue());
    try std.testing.expectEqual(@as(u16, 1), ui.cadenceWaitMs());
    ui.clock_ms = 1008;
    try std.testing.expect(ui.drawDue());

    // Unproven geometry keeps its own inhibited state and never enters the
    // cadence by timer, even when input is urgent.
    ui.resize_waiting = true;
    ui.urgent_draw = true;
    try std.testing.expect(!ui.drawReady() and !ui.drawDue());
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

test "stream rows publish only after ACK and matching canonical text is not duplicated" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    // The active body keeps no full styled prefix copy; only unwritten rows.
    try std.testing.expect(ui.records.items[index].flow_prefix == null);
    try std.testing.expect(ui.records.items[index].pending_stream_rows != 0);
    try std.testing.expect(!ui.records.items[index].output and !ui.records.items[index].pending_output);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    // Content arriving mid-frame cannot invalidate the delivery in flight.
    try ui.appendDraft(.assistant, "```");
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].stream_written != 0);
    const body = try std.testing.allocator.dupe(u8, ui.records.items[index].body.items);
    defer std.testing.allocator.free(body);
    try ui.replaceCommitted(&.{.{ .text = body }}, false, true);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].output);
    try std.testing.expect(ui.records.items[index].flow_prefix == null);
    try std.testing.expectEqual(@as(usize, 35), screen.count("stream-row-"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("Response revised"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-000"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-034"));
}

test "ACKed stream rows are not rewritten by ordinary repaints" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const written = ui.records.items[index].stream_written;
    try std.testing.expect(written != 0);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(written, ui.records.items[index].stream_written);
    try std.testing.expectEqual(@as(usize, 0), screen.count("Response revised"));
    try std.testing.expect(screen.count("stream-row-000") <= 1);
}

test "width changes re-render only the retained window without duplicate rows" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const written = ui.records.items[index].stream_written;
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    // A width ABA discards the in-flight frame authority and re-analyzes only
    // the retained window; frozen rows are never replayed.
    ui.resize(.{ .columns = 40, .rows = 12 });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].stream_written >= written);
    try std.testing.expect(screen.count("stream-row-000") <= 1);
}

test "new stream text releases each row exactly once" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const old_written = ui.records.items[index].stream_written;
    try ui.appendDraft(.assistant, "stream-row-035 abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].stream_written > old_written);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-035"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-000"));
}

test "late ACK commits pinned rows and does not lose mid-frame content" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    const staged = ui.records.items[index].pending_stream_rows;
    try std.testing.expect(staged != 0);
    // Content arrives after staging but before the frame is acknowledged.
    try ui.appendDraft(.assistant, "stream-row-035 abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(staged, ui.records.items[index].stream_written);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-035"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-000"));
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
    testAcknowledgeFullFrame(&ui);
    try ui.replaceCommitted(&.{}, false, true);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.count("stream-row-") > 0);
    try std.testing.expectEqual(@as(usize, 1), screen.count("Stream preview withdrawn"));
}

test "clipped empty canonical preserves an unacknowledged streamed body" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.appendDraft(.assistant, "BODY-NOT-YET-ACKED");
    const id = ui.records.items[ui.draft.?].id;
    const thought = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(thought);
    @memset(thought, 'r');
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .assistant_committed = &.{ .{ .reasoning = thought }, .{ .text = "BODY-NOT-YET-ACKED" } } }, &cancel);
    var item = bridge.pop().?;
    defer item.deinit();
    try std.testing.expect(item.display_truncated and item.canonical_complete);
    try std.testing.expectEqual(@as(usize, 0), item.event.assistant_committed[1].text.len);
    try ui.event(item);
    const index = ui.record_index.get(id).?;
    try std.testing.expectEqualStrings("BODY-NOT-YET-ACKED", ui.records.items[index].body.items);
    try std.testing.expect(ui.records.items[index].clipped);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), screen.count("BODY-NOT-YET-ACKED"));
}

test "complete empty canonical withdraws an unacknowledged streamed body" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.appendDraft(.assistant, "withdraw-me");
    const id = ui.records.items[ui.draft.?].id;
    try ui.replaceCommitted(&.{}, false, true);
    try std.testing.expect(ui.record_index.get(id) == null);
}

test "clipped canonical never replaces a complete displayed stream" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const preview = try std.testing.allocator.dupe(u8, ui.records.items[index].body.items);
    defer std.testing.allocator.free(preview);
    // display_truncated canonical is not a complete body: the long preview and
    // its rows must survive, with an explicit notice instead of a rewrite.
    try ui.replaceCommitted(&.{.{ .text = "cropped final" }}, true, true);
    try std.testing.expect(ui.records.items[index].clipped);
    try std.testing.expectEqualStrings(preview, ui.records.items[index].body.items);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-034"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("cropped final"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("truncated for display"));
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
    testAcknowledgeFullFrame(&ui);
    // A native viewport is an absolute slice of scrollback+screen, NOT Ui.scroll.
    // Pin an observer eight rows above the current bottom; send no wheel input.
    try std.testing.expect(screen.history_len >= 8);
    const view_top = screen.history_len - 8;
    var pinned: [24]@TypeOf(screen.grid[0]) = undefined;
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
        testAcknowledgeFullFrame(&ui);
    }
    try ui.replaceCommitted(&.{.{ .text = "final-canonical-only" }}, false, true);
    try ui.draw();
    try std.testing.expect(!ui.frame_sparse);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "stable-body-A") != null);
    // appendDraft invalidates/frees Record.lines; the acknowledged copy stays valid.
    try ui.appendDraft(.assistant, "-extended");
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "stable-body-A") != null);
    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "extended") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "extended") != null);
    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.frame, "\x1b[K"));
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("stable-body-A-extended"));
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
}

test "resize defers idle and busy screens during live geometry changes but input may resume early" {
    for ([_]bool{ false, true }) |busy| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.busy = busy;
        _ = try ui.add(.assistant, "stable resize body");
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        for ([_]terminal_module.Size{ .{ .columns = 40, .rows = 24 }, .{ .columns = 40, .rows = 12 }, .{ .columns = 80, .rows = 24 } }) |size| {
            ui.resize(size);
            try std.testing.expect(ui.resize_waiting and !ui.dirty and !ui.drawReady());
            try std.testing.expect(ui.frame.len == 0 and ui.resize_rescue.len == 0);
            try std.testing.expect(ui.tail_snapshot == null and !ui.frame_fresh);
            // Arbitrarily advanced time with only resize reports and animation
            // pulses never produces a frame: no timer, no automatic repair.
            for (0..20) |_| {
                ui.clock_ms += 20;
                ui.resize(size);
                ui.animate();
                try std.testing.expect(!ui.drawReady() and !ui.dirty);
                try std.testing.expect(ui.frame.len == 0 and ui.resize_rescue.len == 0);
            }
        }
        try Ui.key(&ui, .{ .text = .{ .value = "x", .pasted = false } });
        try std.testing.expect(ui.drawReady() and !ui.resize_waiting);
        try std.testing.expectEqualStrings("x", ui.editor.bytes.items);
        try ui.draw();
        try std.testing.expect(ui.frame_fresh and !ui.display_changed);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(ui.tail_snapshot != null);
    }
}

test "resize alone never draws and the next real input draws once at the new size" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 80, .rows = 24 };
    try Ui.key(&ui, .{ .text = .{ .value = "visible draft", .pasted = false } });
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const size: terminal_module.Size = .{ .columns = 60, .rows = 12 };
    ui.resize(size);
    // The new dimensions are current, and every old authority/bottom proof is gone.
    try std.testing.expectEqual(size.columns, ui.size.columns);
    try std.testing.expectEqual(size.rows, ui.size.rows);
    try std.testing.expect(ui.resize_waiting and !ui.dirty and !ui.drawReady());
    try std.testing.expect(ui.tail_snapshot == null and !ui.tail_bottom and ui.abandon_tail);
    // No autonomous payload, however far the clock advances.
    for (0..20) |_| {
        ui.clock_ms += 80;
        ui.resize(size);
        ui.animate();
        try std.testing.expect(!ui.drawReady() and !ui.dirty);
        try std.testing.expect(ui.frame.len == 0 and ui.resize_rescue.len == 0);
    }
    // The next real input establishes one fresh bottom-anchored frame at the
    // new width without replaying history.
    try Ui.key(&ui, .{ .text = .{ .value = "!", .pasted = false } });
    try std.testing.expect(ui.drawReady() and !ui.resize_waiting);
    try ui.draw();
    try std.testing.expectEqual(size.columns, ui.frame_size.columns);
    try std.testing.expectEqual(size.rows, ui.frame_size.rows);
    try std.testing.expect(std.mem.find(u8, ui.frame, "visible draft!") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[999B") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[0J") == null);
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r"));
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.tail_snapshot != null);
    try std.testing.expectEqualStrings("visible draft!", ui.editor.bytes.items);
}

test "resize revokes approval across ABA and only a complete new frame acknowledges" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.permission = .{ .id = 42, .description = try std.testing.allocator.dupe(u8, "settled resize approval"), .clipped = false };
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.clock_ms = 1000;
    ui.resize(.{ .columns = 60, .rows = 12 });
    ui.clock_ms = 1100;
    const restored: terminal_module.Size = .{ .columns = 80, .rows = 24 };
    ui.resize(restored);
    ui.resize(restored); // A repeated report of the restored size is not an ACK.
    try std.testing.expect(!ui.drawReady() and ui.displayed_permission == null);
    // ABA plus arbitrarily advanced time still cannot revive the authority or
    // produce an autonomous frame.
    ui.clock_ms = 1250;
    ui.resize(restored);
    ui.clock_ms = 4000;
    ui.resize(restored);
    ui.animate();
    try std.testing.expect(!ui.drawReady() and !ui.dirty);
    try std.testing.expect(ui.frame.len == 0 and ui.resize_rescue.len == 0);
    // Only genuine input/content resumes drawing, and the approval still needs a
    // complete fresh frame at the current geometry before Enter may confirm it.
    ui.requestDraw();
    try std.testing.expect(ui.drawReady() and ui.displayed_permission == null);
    try ui.draw();
    try std.testing.expect(ui.frame_permission == 42 and ui.displayed_permission == null);
    // A partial frame interrupted by another resize may publish nothing, but the
    // genuine content it carried keeps its draw obligation: only the old ACK dies.
    ui.frame_offset = 1;
    ui.resize(.{ .columns = 70, .rows = 20 });
    ui.finishFrame();
    try std.testing.expect(ui.displayed_permission == null and !ui.resize_waiting and ui.dirty);
    // Interrupted-write controls must drain first and never acknowledge anything.
    try std.testing.expect(ui.resize_rescue.len != 0 and !ui.drawReady());
    ui.resize_rescue = ""; // Controls-only cleanup cannot publish an ACK.
    // The surviving obligation is ordinary work: no new input, timer or resize is
    // needed to become drawable, and only a complete current-geometry frame ACKs.
    ui.clock_ms += 5000;
    ui.resize(ui.size);
    ui.animate();
    try std.testing.expect(ui.dirty and ui.drawReady() and ui.displayed_permission == null);
    try ui.draw();
    try std.testing.expect(ui.frame_permission == 42 and ui.displayed_permission == null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
}

test "resize requeues unfinished content but discards animation frames without payload replay" {
    for ([_]bool{ false, true }) |changed| {
        for ([_]usize{ 0, 1 }) |sent| {
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            ui.busy = true;
            try ui.draw();
            testAcknowledgeFullFrame(&ui);
            ui.clock_ms = 160;
            ui.animate();
            if (changed) {
                const host = bridge.host();
                try host.emit_fn(host.context, .{ .text = "new resize content" }, &cancel);
                var item = bridge.pop().?;
                defer item.deinit();
                try ui.event(item);
            }
            try ui.draw();
            try std.testing.expectEqual(changed, ui.frame_changed);
            ui.frame_offset = sent;
            ui.resize(.{ .columns = 40, .rows = 12 });
            try std.testing.expect(ui.frame.len == 0 and ui.frame_arena == null);
            try std.testing.expect(ui.frame_tail_snapshot == null and ui.tail_snapshot == null);
            try std.testing.expectEqual(!changed, ui.resize_waiting);
            try std.testing.expectEqualStrings(if (sent == 0) "" else "\x18\x1b[0m" ++ terminal_module.sync_end ++ "\x1b[?25h", ui.resize_rescue);
            try std.testing.expect(std.mem.indexOfAny(u8, ui.resize_rescue, "\r\n") == null);
            ui.finishFrame();
            try std.testing.expect(!ui.frame_fresh and ui.tail_snapshot == null);
            ui.resize_rescue = ""; // Controls-only flush is not a display ACK.
            if (!changed) {
                // A pure animation pulse is not resurrected by an advanced clock.
                for (0..20) |_| {
                    ui.clock_ms += 80;
                    ui.resize(.{ .columns = 40, .rows = 12 });
                    ui.animate();
                    try std.testing.expect(!ui.drawReady());
                }
            }
            try std.testing.expectEqual(changed, ui.drawReady());
            if (changed) {
                try ui.draw();
                try std.testing.expect(std.mem.indexOf(u8, ui.frame, "new resize content") != null);
                // A real update establishes a bounded new bottom anchor.
                try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[999B") == null);
                try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[12B"));
                testAcknowledgeFullFrame(&ui);
            }
        }
    }
}

test "resize preserves real input updates not yet staged" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .{ .text = .{ .value = "pending draft", .pasted = false } });
    ui.resize(.{ .columns = 40, .rows = 24 });
    try std.testing.expect(ui.drawReady() and !ui.resize_waiting);
    try std.testing.expectEqualStrings("pending draft", ui.editor.bytes.items);
}

test "resize invalidates acknowledged approval until fresh input and frame" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.permission = .{ .id = 42, .description = try std.testing.allocator.dupe(u8, "safe resize approval"), .clipped = false };
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
    ui.resize(.{ .columns = 70, .rows = 20 });
    try std.testing.expect(ui.resize_waiting and ui.displayed_permission == null and !ui.dirty);
    try Ui.key(&ui, .enter);
    try std.testing.expect(ui.permission != null and ui.displayed_permission == null and ui.drawReady());
    try ui.draw();
    try std.testing.expect(ui.displayed_permission == null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
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
            testAcknowledgeFullFrame(&ui);
            try ui.appendDraft(.assistant, if (shifted) "stream-row-035 abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n" else " extended");
            try ui.draw();
            try std.testing.expect(ui.frame_sparse);
            const old_prefix = if (ui.draft) |index| if (ui.records.items[index].flow_prefix) |prefix| prefix.rowCount() else 0 else 0;
            if (shifted) {
                try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1M") == null);
                try std.testing.expect(std.mem.find(u8, ui.frame, "\n") != null);
            }
            for (ui.frame) |byte| try std.testing.expect(byte < 128);
            length = ui.frame.len;
            var captured: Io.Writer.Allocating = .init(std.testing.allocator);
            defer captured.deinit();
            try captured.writer.writeAll(ui.frame[0..offset]);
            ui.frame_offset = offset;
            ui.resize(.{ .columns = 40, .rows = 12 });
            try std.testing.expect(!ui.frame_sparse and !ui.frame_fresh);
            try std.testing.expect(ui.tail_snapshot == null);
            try std.testing.expectEqual(@as(usize, 0), ui.frame_offset);
            try std.testing.expect(ui.frame.len == 0 and ui.frame_arena == null);
            try std.testing.expectEqualStrings(if (offset == 0) "" else "\x18\x1b[0m" ++ terminal_module.sync_end ++ "\x1b[?25h", ui.resize_rescue);
            try std.testing.expect(std.mem.indexOfAny(u8, ui.resize_rescue, "\r\n") == null);
            try captured.writer.writeAll(ui.resize_rescue);
            var screen: @import("../tests/regular_screen.zig").Screen = .{};
            // Syntax/escape cancellation only, not a physical resize/reflow oracle.
            try screen.replay(captured.written());
            if (offset != 0) try std.testing.expect(std.mem.endsWith(u8, captured.written(), terminal_module.sync_end ++ "\x1b[?25h"));
            // Even returning to old dimensions does not revive the old ACK/cache.
            ui.resize(.{ .columns = 80, .rows = 24 });
            ui.finishFrame(); // No old-width payload survives to acknowledge.
            try std.testing.expect(ui.tail_snapshot == null);
            try std.testing.expect(ui.displayed_permission == null and ui.displayed_model_epoch == null);
            if (ui.draft) |index| {
                const record = &ui.records.items[index];
                try std.testing.expectEqual(old_prefix, if (record.flow_prefix) |prefix| prefix.rowCount() else 0);
                try std.testing.expect(record.pending_flow_prefix == null);
            }
            try std.testing.expect(ui.abandon_tail);
        }
    }
}

fn discardFixtureFrame(ui: *Ui) void {
    // Test-only discard of an unsent preview, NOT an acknowledgement. Legacy
    // tests freed only frame_arena; candidates now own a separate arena too.
    ui.discardFrameRecords(ui.frame_records);
    ui.frame_records = &.{};
    if (ui.frame_arena) |*arena| arena.deinit();
    if (ui.frame_tail_snapshot) |*snapshot| snapshot.deinit();
    if (ui.frame_menu_history) |*history| history.deinit();
    ui.frame_menu_history = null;
    ui.frame_arena = null;
    ui.frame_tail_snapshot = null;
    ui.frame_sparse = false;
    ui.frame_offset = 0;
    ui.frame = "";
    for (ui.records.items) |*record| record.discardPendingFlow();
}

/// Test fixture: commit real canonical rows through complete frames so the
/// ACKed above rows are physically on the replay screen and the live tail is
/// reduced to a compact footer. Returns each marker exactly once on screen.
fn seedCompactAckedTail(ui: *Ui, screen: *@import("../tests/regular_screen.zig").Screen) !void {
    _ = try ui.add(.user, "canon-a");
    _ = try ui.add(.user, "canon-b1\ncanon-b2\ncanon-b3\ncanon-b4\ncanon-b5\ncanon-b6");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(ui);
    _ = try ui.add(.user, "canon-c1\ncanon-c2\ncanon-c3\ncanon-c4\ncanon-c5\ncanon-c6\ncanon-c7\ncanon-c8\ncanon-c9\ncanon-c10\ncanon-c11\ncanon-c12\ncanon-c13");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(ui);
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
    testAcknowledgeFullFrame(&ui);
    const old_ack = ui.tail_snapshot.?.full;
    const prefix_count = if (ui.records.items[ui.draft.?].flow_prefix) |prefix| prefix.rowCount() else 0;
    try ui.appendDraft(.assistant, if (native) "stream-row-035 more body\n" else "| new | cell |\n");
    tailAllocationDraw(&ui) catch |err| {
        // A failed candidate cannot replace/free the last acknowledged bytes.
        try std.testing.expectEqualStrings(old_ack, ui.tail_snapshot.?.full);
        const record = &ui.records.items[ui.draft.?];
        try std.testing.expectEqual(prefix_count, if (record.flow_prefix) |prefix| prefix.rowCount() else 0);
        try std.testing.expect(record.pending_flow_prefix == null and !record.pending_flow_change);
        try std.testing.expect(ui.frame.len == 0 and ui.frame_tail_snapshot == null);
        return err;
    };
    ui.resize(.{ .columns = 40, .rows = 12 });
    ui.finishFrame();
    try tailAllocationDraw(&ui);
    testAcknowledgeFullFrame(&ui);
}

test "tail snapshot construction and resize release all allocations under OOM" {
    try text.initLocale();
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    for ([_]bool{ false, true }) |native| try std.testing.checkAllAllocationFailures(backing.allocator(), tailAllocationScenario, .{native});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

fn reasoningTailAllocationScenario(a: std.mem.Allocator) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.allocator = a;
    ui.editor.allocator = a;
    defer ui.deinit();
    try ui.appendDraft(.reasoning, "alpha 中文\nbeta\n");
    tailAllocationDraw(&ui) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    testAcknowledgeFullFrame(&ui);
    try ui.appendDraft(.reasoning, "gamma-delta");
    ui.resize(.{ .columns = 20, .rows = 12 });
    tailAllocationDraw(&ui) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    testAcknowledgeFullFrame(&ui);
    ui.discardReasoning();
    tailAllocationDraw(&ui) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    testAcknowledgeFullFrame(&ui);
}

test "reasoning tail allocation failures release every owned tail and record" {
    try text.initLocale();
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), reasoningTailAllocationScenario, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "composer displays startup zero and latest actual usage or unknown without billing accumulation" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.display.seed(.{ .tokens = 0, .limit = 1000000 });
    const green_prompt = "(" ++ theme.reset ++ "\x1b[1mfixture" ++ theme.reset ++ "\x1b[1m) " ++ theme.success;
    const prompt_end = theme.reset ++ "\x1b[1m>" ++ theme.reset ++ " ";
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, green_prompt ++ "0.0%" ++ prompt_end) != null);
    testAcknowledgeFullFrame(&ui);
    const Case = struct { purpose: p.Purpose, usage: p.Usage, prefix: []const u8 };
    const host = bridge.host();
    for ([_]Case{
        .{ .purpose = .normal, .usage = .{ .input_tokens = 12000, .output_tokens = 1000, .cached_input_tokens = 10000, .reasoning_tokens = 300 }, .prefix = green_prompt ++ "1.3%" ++ prompt_end },
        .{ .purpose = .summary, .usage = .{ .total_tokens = 1000 }, .prefix = green_prompt ++ "0.1%" ++ prompt_end },
        .{ .purpose = .normal, .usage = .{ .input_tokens = 12 }, .prefix = "\x1b[1m(fixture) ?%>" ++ theme.reset ++ " " },
        .{ .purpose = .normal, .usage = .{ .total_tokens = 0 }, .prefix = green_prompt ++ "0.0%" ++ prompt_end },
    }) |case| {
        try host.emit_fn(host.context, .{ .usage = .{ .purpose = case.purpose, .protocol = .chat, .value = case.usage } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, case.prefix) != null);
        testAcknowledgeFullFrame(&ui);
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
    try std.testing.expect(std.mem.find(u8, line, "limits.max_output_tokens") == null);
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
        try std.testing.expect(std.mem.find(u8, line, if (detail == error.DecisionUnavailable) "decision review failed" else @errorName(detail)) != null);
        try std.testing.expect(std.mem.find(u8, line, "round limit") == null);
        try std.testing.expect(std.mem.find(u8, line, "HTTP") == null);
    }
}

test "decision pause wins over stale Ready thinking warnings and empty queue pause" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = ui.connection.current();
    state.settings_notice = "Saved thinking level not applied: model capabilities unknown";
    state.pending_default_effort = .medium;
    ui.notice = "Ready";
    ui.last_terminal = .{ .status = .paused, .detail = error.DecisionUnavailable };
    ui.inbox.pause();
    const expected = "Paused: decision review failed; operation not executed";
    try std.testing.expectEqualStrings(expected, try ui.footerHint(arena.allocator(), state));
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, expected) != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "S:0 F:0") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/queue resume") == null);
    testAcknowledgeFullFrame(&ui);
    // Real queued input remains visible, but never ahead of the failure.
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "retained queued input");
    const queued = try ui.footerHint(arena.allocator(), state);
    try std.testing.expect(std.mem.startsWith(u8, queued, expected));
    try std.testing.expect(std.mem.find(u8, queued, "S:0 F:1 paused (/queue resume)") != null);
    try std.testing.expect(std.mem.find(u8, queued, "Saved thinking") == null);
    // Real storage failures are not hidden by the new priority policy.
    state.settings_error = error.TestSettingsFailure;
    state.log_error = error.TestLogFailure;
    const storage = try ui.footerHint(arena.allocator(), state);
    try std.testing.expect(std.mem.find(u8, storage, "SETTINGS FAILED") != null);
    try std.testing.expect(std.mem.find(u8, storage, "REC FAILED") != null);
    state.settings_error = null;
    state.log_error = null;
    // Cancellation must retain the meaningful side-effect warning even when a
    // later redraw/menu has reset the transient notice to Ready.
    ui.last_terminal = .{ .status = .canceled, .detail = error.Canceled };
    try std.testing.expectEqualStrings("Canceled; prior side effects remain", try ui.hint(arena.allocator(), state));
    ui.last_terminal = null;
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "Saved thinking") != null);
}

test "capability action hint deduplicates only the matching saved warning" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = ui.connection.current();
    state.settings_notice = "Saved thinking level not applied: model capabilities unknown";
    for ([_][]const u8{
        "Thinking capabilities are loading; try Shift+Tab again shortly",
        "Thinking capabilities unknown: refresh /model or declare reasoning levels in configuration",
    }) |notice| {
        ui.notice = notice;
        try std.testing.expectEqualStrings(notice, try ui.hint(arena.allocator(), state));
        state.settings_error = error.TestSettingsFailure;
        const failure = try ui.hint(arena.allocator(), state);
        try std.testing.expect(std.mem.find(u8, failure, notice) != null);
        try std.testing.expect(std.mem.find(u8, failure, "SETTINGS FAILED: TestSettingsFailure") != null);
        state.settings_error = null;
    }
    ui.notice = "Could not save thinking option; previous option kept";
    const unrelated = try ui.hint(arena.allocator(), state);
    try std.testing.expect(std.mem.find(u8, unrelated, ui.notice) != null);
    try std.testing.expect(std.mem.find(u8, unrelated, state.settings_notice.?) != null);
}

test "read command errors include a safe reason after error and never display raw results" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const call = try shared.tools.Call.init(std.testing.allocator, "read_file", "{\"path\":\"README.md\"}");
    defer call.deinit(std.testing.allocator);
    const caption = try presentation.fromCall(std.testing.allocator, call);
    defer caption.deinit(std.testing.allocator);
    try ui.toolCompleted(caption, .{ .text = "FileNotFound", .is_error = true, .duration_ms = 3 });
    try std.testing.expectEqualStrings("r README.md [error] FileNotFound: file not found", ui.records.items[0].body.items);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "[error] FileNotFound: file not found") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "3ms") != null);
    testAcknowledgeFullFrame(&ui);
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
    for ([_][]const u8{ "one.txt", "two.txt", "three.txt" }) |path| {
        const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
        defer std.testing.allocator.free(args);
        const call = try shared.tools.Call.init(std.testing.allocator, "read_file", args);
        defer call.deinit(std.testing.allocator);
        const caption = try presentation.fromCall(std.testing.allocator, call);
        defer caption.deinit(std.testing.allocator);
        try ui.toolCompleted(caption, .{ .text = "hidden-result", .file_stats = .{ .read = 1 } });
        try ui.draw();
        try screen.replay(ui.frame);
        try std.testing.expectEqual(@as(usize, 1), screen.count(path));
        try std.testing.expect(screen.visible(path));
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
    }
    try ui.replaceCommitted(&.{.{ .text = "answer-without-heading" }}, false, true);
    try ui.draw();
    try screen.replay(ui.frame);
    const first = for (screen.grid, 0..) |line, row| {
        if (std.mem.find(u8, &line, "one.txt") != null) break row;
    } else return error.MissingRowPrefix;
    try std.testing.expect(std.mem.find(u8, &screen.grid[first + 1], "two.txt") != null);
    try std.testing.expect(std.mem.find(u8, &screen.grid[first + 2], "three.txt") != null);
    try expectTranscriptGap(&screen, "three.txt", "answer-without-heading");
    try std.testing.expectEqual(@as(usize, 0), screen.count("Final answer"));
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 1), screen.count("answer-without-heading"));
    for ([_][]const u8{ "one.txt", "two.txt", "three.txt" }) |path| try std.testing.expectEqual(@as(usize, 1), screen.count(path));
    testAcknowledgeFullFrame(&ui);
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
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.high)) ++ "fixture" ++ theme.reset ++ "\x1b[1m) " ++ theme.reset ++ "\x1b[1m?%" ++ theme.reset ++ "\x1b[1m>" ++ theme.reset ++ " input-default") != null);
    testAcknowledgeFullFrame(&ui);
    ui.mode = .calling_model;
    ui.display.reset();
    ui.display.observe(.{ .state = .calling_model }, 0);
    for ([_]u64{ 1100, 3100, 9100 }) |now| {
        ui.clock_ms = now;
        try ui.draw();
        const marker = try std.fmt.allocPrint(std.testing.allocator, "{s}\x1b[1m{s}{s}{s} input-default", .{ theme.reset, theme.command_pulse[shared.activity.commandStep(now)], activity.spinner(now), theme.reset });
        defer std.testing.allocator.free(marker);
        try std.testing.expect(std.mem.find(u8, ui.frame, marker) != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, theme.effortColor(.high)) == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, theme.model_flow[ui.model_flow.step()]) != null);
        testAcknowledgeFullFrame(&ui);
    }
    ui.display.observe(.{ .reasoning = "late thought" }, 9100);
    ui.display.finish(.{ .status = .success });
    ui.mode = null;
    owner.effort = .low;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.low)) ++ "fixture" ++ theme.reset ++ "\x1b[1m) " ++ theme.reset ++ "\x1b[1m?%" ++ theme.reset ++ "\x1b[1m>" ++ theme.reset ++ " input-default") != null);
    testAcknowledgeFullFrame(&ui);
    owner.effort = .unspecified;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1m(fixture) ?%>" ++ theme.reset ++ " input-default") != null);
    testAcknowledgeFullFrame(&ui);
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
            const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{d}.0%{s}\x1b[1m{s}{s}{s} default-input", .{ if (tokens == 0) theme.success else if (tokens == 25) "\x1b[38;5;220m" else theme.failure, tokens, theme.reset, if (busy) theme.command_pulse[0] else "", if (busy) activity.spinner(80) else ">", theme.reset });
            defer std.testing.allocator.free(expected);
            try std.testing.expect(std.mem.find(u8, ui.frame, expected) != null);
            testAcknowledgeFullFrame(&ui);
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
        try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], if (enabled) ") L3.1%> typed" else ") 3.1%> typed") != null);
    }
}

test "model only default color prompt has no headers cache or status and preserves cursor" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.editor.insert("hello\t你");
    try ui.appendDraft(.reasoning, "unprefixed-thought");
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Thinking") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "thin |") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "tools trusted") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, ".thin/sessions") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1m(fixture) ?%>" ++ theme.reset ++ " hello    你") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "90.0%") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "(fixture)") == null);
    const decoration = "(fixture) ?%> ";
    const position = try std.fmt.allocPrint(std.testing.allocator, "\r\x1b[{d}C" ++ terminal_module.sync_end ++ "\x1b[?25h", .{text.width(decoration) + text.width("hello    你")});
    defer std.testing.allocator.free(position);
    try std.testing.expect(std.mem.endsWith(u8, ui.frame, position));
    try std.testing.expectEqualStrings("hello\t你", ui.editor.bytes.items);
    testAcknowledgeFullFrame(&ui);
}

test "single composer hides statistics and completion and uses flow and exact braille spinner" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.mode = .calling_model;
    ui.display.meter.reset();
    ui.display.meter.beginCall();
    ui.display.meter.observe(100, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    ui.model_flow.advance(0, true, null);
    ui.clock_ms = 600;
    try ui.appendDraft(.assistant, "visible-body");
    _ = try ui.editor.insert("typed-default-color");
    try ui.draw();
    for ([_][]const u8{ "TPS:", "TTFT:", "tokens in:", "summary in:", "cost:", "loading", "Completed", "calling_model" }) |removed| try std.testing.expect(std.mem.find(u8, ui.frame, removed) == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.reset ++ "\x1b[1m" ++ theme.command_pulse[5] ++ "⠧" ++ theme.reset ++ " typed-default-color") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.model_flow[ui.model_flow.step()]) != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("visible-body"));
    // The status is immediately above the composer, with a separator before it.
    const warning = "Not configured: /login, then /model";
    try std.testing.expectEqualStrings(warning, std.mem.trimEnd(u8, &screen.grid[screen.rows - 2], " "));
    var warning_count: usize = 0;
    for (screen.grid[0..screen.rows]) |row| warning_count += std.mem.count(u8, &row, warning);
    try std.testing.expectEqual(@as(usize, 1), warning_count);
    for (screen.grid[screen.rows - 3]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
    try std.testing.expect(std.mem.find(u8, &screen.grid[screen.rows - 1], "(fixture) ?%~ typed-default-color") != null);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    ui.clock_ms = 680;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.command_pulse[5] ++ "⠇" ++ theme.reset ++ " typed-default-color") != null);
    testAcknowledgeFullFrame(&ui);
    ui.mode = null;
    ui.draft = null;
    ui.notice = "Completed"; // Even old application success notices cannot add a row.
    ui.last_terminal = .{ .status = .success, .usage = .{ .normal_calls = 1, .normal = .{ .input_tokens = 10562, .output_tokens = 873, .cached_input_tokens = 9600 } } };
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1m(fixture) ?%>" ++ theme.reset ++ " typed-default-color") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Completed") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "tokens in:") == null);
    testAcknowledgeFullFrame(&ui);
}

test "flow model prefix wraps long editor suffix without changing raw cursor bytes" {
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
    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    const first_composer = try ui.prepareComposer(first_arena.allocator(), ui.connection.current(), ui.size.columns -| 1);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    // The cursor is on the first wrapped composer row, not the frame's last row.
    try std.testing.expectEqual(screen.rows - 1 - ui.frame_cursor_rows_up, screen.row);
    const first_row = screen.row - first_composer.layout.cursor_row;
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[first_row], "(fixture) ?%~ x"));
    try std.testing.expectEqual(text.width(first_composer.decoration.plain) + first_composer.layout.cursor_column, screen.col);
    // With no body above it, the composer is preceded only by the fixture's real
    // notice: no reserved blank row and no second composer.
    if (first_row > 0) {
        try std.testing.expect(std.mem.find(u8, &screen.grid[first_row - 1], "Not configured") != null);
        try std.testing.expect(std.mem.find(u8, &screen.grid[first_row - 1], "?%>") == null);
    }
    try std.testing.expectEqualStrings(&raw, ui.editor.bytes.items);
    testAcknowledgeFullFrame(&ui);
    ui.editor.cursor = raw.len;
    var last_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer last_arena.deinit();
    const last_composer = try ui.prepareComposer(last_arena.allocator(), ui.connection.current(), ui.size.columns -| 1);
    try ui.draw();
    try screen.replay(ui.frame);
    // The composer is the frame's last block: its final row is the frame row.
    try std.testing.expectEqual(screen.rows - 1 - (last_composer.layout.lines.len - 1 - last_composer.layout.cursor_row), screen.row);
    try std.testing.expectEqual(text.width(last_composer.decoration.plain) + last_composer.layout.cursor_column, screen.col);
    try std.testing.expectEqualStrings(&raw, ui.editor.bytes.items);
    testAcknowledgeFullFrame(&ui);
}

test "resize abandons unknown rows and old completed approval cannot authorize" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.permission = .{ .id = 42, .description = try std.testing.allocator.dupe(u8, "safe preview"), .clipped = false };
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
    try ui.draw();
    try std.testing.expect(ui.displayed_permission == null);
    ui.frame_offset = 1; // Even a partially written reclaim escape is unsafe after reflow.
    ui.resize(.{ .columns = 70, .rows = 20 });
    try std.testing.expect(ui.frame.len == 0 and ui.frame_offset == 0);
    try std.testing.expectEqualStrings("\x18\x1b[0m" ++ terminal_module.sync_end ++ "\x1b[?25h", ui.resize_rescue);
    ui.resize(.{ .columns = 80, .rows = 24 });
    ui.finishFrame();
    try std.testing.expect(ui.displayed_permission == null);
    // ABA down to the repeated size report cannot schedule an autonomous frame.
    ui.clock_ms += 5000;
    ui.resize(.{ .columns = 80, .rows = 24 });
    ui.animate();
    try std.testing.expect(!ui.drawReady() and ui.frame.len == 0);
    ui.requestDraw(); // Genuine update, not a timer or a geometry repair.
    try ui.draw();
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[24B"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[999B") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[6A") == null);
    // Fixed safety layout, not a reclaimed full screen: the authorizable
    // approval needs title + preview + choices (3) plus separator + hint +
    // composer (3), i.e. six rows.
    try std.testing.expectEqual(@as(usize, 6), ui.frame_height);
    try std.testing.expect(ui.displayed_permission == null);
    testAcknowledgeFullFrame(&ui);
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

test "application log failure remains visible without poisoning runtime" {
    const ConnectionFixture = struct {
        runtime: r.Runtime = undefined, // 仅借用地址供 ready 状态判断，本测试不调用它。
        failed: bool,

        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{
                .runtime = &self.runtime,
                .model = "fixture",
                .base_url = "http://unused.invalid",
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
        if (failed) try std.testing.expect(std.mem.find(u8, ui.frame, "REC FAILED: NoSpaceLeft") != null) else try std.testing.expect(std.mem.find(u8, ui.frame, "REC FAILED") == null);
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
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .left); // Clipped previews cannot select Allow once.
    try std.testing.expectEqual(ApprovalChoice.deny, ui.permission.?.choice);
    try Ui.key(&ui, .{ .text = .{ .value = "y", .pasted = false } });
    try std.testing.expect(bridge.answer == null);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try Ui.key(&ui, .enter);
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
    try Ui.key(&ui, .enter);
    try std.testing.expect(bridge.answer == null);
    ui.displayed_permission = 1;
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .enter);
    try std.testing.expect(bridge.answer == null);

    ui.displayed_permission = 2;
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .{ .text = .{ .value = "y", .pasted = true } });
    try std.testing.expect(bridge.answer == null);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    ui.displayed_permission = 2;
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(?r.Decision, .deny), bridge.answer);
}

test "approval popup offers only one-shot allow or deny and text grants no authority" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    for ([_]u64{ 1, 2 }) |id| {
        try host.emit_fn(host.context, .{ .permission = .{ .id = id, .tool_name = "bash", .description = "explicit approval required" } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "Allow once") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "> Deny") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "TRUST") == null);
        ui.displayed_permission = ui.frame_permission;
        ui.displayed_permission_choice = ui.frame_permission_choice;
        try Ui.key(&ui, .{ .text = .{ .value = "t", .pasted = false } });
        try std.testing.expect(bridge.answer == null);
        try std.testing.expectEqual(id, ui.permission.?.id);
        try std.testing.expectEqualStrings("", ui.editor.bytes.items);
        if (id == 1) try Ui.key(&ui, .left);
        ui.displayed_permission = id;
        ui.displayed_permission_choice = ui.permission.?.choice;
        try Ui.key(&ui, .enter);
        try std.testing.expectEqual(@as(?r.Decision, if (id == 1) .allow_once else .deny), bridge.answer);
        try std.testing.expect(ui.permission == null);
        try std.testing.expectEqual(if (id == 1) r.Decision.allow_once else .deny, try host.authorize_fn(host.context, .{ .id = id, .tool_name = "bash", .description = "explicit approval required" }, &cancel));
        discardFixtureFrame(&ui);
    }
}

test "approval allow requires the complete selected authority row" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 12, .rows = 7 }; // drawable cols = 11
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "op" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try Ui.key(&ui, .left);
    try std.testing.expectEqual(ApprovalChoice.allow_once, ui.permission.?.choice);
    try std.testing.expect(!ui.approvalFits(1, .allow_once));
    try ui.draw();
    try std.testing.expect(ui.frame_permission == null);
    ui.displayed_permission = null;
    ui.displayed_permission_choice = null;
    try Ui.key(&ui, .enter);
    try std.testing.expect(bridge.answer == null);
    discardFixtureFrame(&ui);

    ui.size.columns = 13; // drawable cols = 12, exactly "> Allow once".
    try ui.draw();
    try std.testing.expectEqual(@as(?u64, 1), ui.frame_permission);
    try std.testing.expectEqual(@as(?ApprovalChoice, .allow_once), ui.frame_permission_choice);
    ui.displayed_permission = ui.frame_permission;
    ui.displayed_permission_choice = ui.frame_permission_choice;
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(?r.Decision, .allow_once), bridge.answer);
}

test "approval popup Escape denies without steering or an armed text byte" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 33, .tool_name = "bash", .description = "dangerous operation" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.draw();
    ui.displayed_permission = ui.frame_permission;
    ui.displayed_permission_choice = ui.frame_permission_choice;
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(?r.Decision, .deny), bridge.answer);
    try std.testing.expect(ui.permission == null);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
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
    ui.displayed_permission_choice = .deny;

    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~\x1b[201~", sink);
    try ui.parser.feed("yt\x1b[201~", sink); // Malicious paste body after an embedded terminator.
    try std.testing.expect(bridge.answer == null);
    try std.testing.expect(ui.approval_paste_seen);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    ui.displayed_permission = 1;
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .enter);
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
    testAcknowledgeFullFrame(&ui);
}

test "six-row approval cannot authorize and recovers after a complete visible frame" {
    try text.initLocale();
    for ([_]usize{ 7, 24 }) |restored_rows| {
        for ([_]r.Decision{ .allow_once, .deny }) |decision| {
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
            ui.displayed_permission_choice = ui.frame_permission_choice;
            try ui.parser.feed("yt", sink);
            try std.testing.expect(bridge.answer == null);
            try std.testing.expect(!ui.permission.?.clipped);
            discardFixtureFrame(&ui);

            ui.size.rows = restored_rows;
            try ui.draw();
            try std.testing.expect(std.mem.find(u8, ui.frame, "VISIBLE OPERATION") != null);
            try std.testing.expectEqual(@as(?u64, 1), ui.frame_permission);
            try Ui.key(&ui, .enter); // 构建帧不等于整帧已显示。
            try std.testing.expect(bridge.answer == null);
            if (decision == .allow_once) try Ui.key(&ui, .left);
            ui.displayed_permission = ui.frame_permission;
            ui.displayed_permission_choice = ui.permission.?.choice;
            try Ui.key(&ui, .enter);
            try std.testing.expectEqual(@as(?r.Decision, decision), bridge.answer);
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
        ui.displayed_permission_choice = .allow_once;
        try ui.parser.feed("yt", sink);
        try std.testing.expect(bridge.answer == null);
        ui.displayed_permission = null;
        discardFixtureFrame(&ui);

        // The drawable width must contain both the identity and the selected
        // authority-bearing row; the last physical column remains unused.
        ui.size.columns = @max(identity.len, "> Allow once".len) + 1;
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, identity) != null);
        try std.testing.expectEqual(@as(?u64, id), ui.frame_permission);
        try Ui.key(&ui, .left);
        try Ui.key(&ui, .enter);
        try std.testing.expect(bridge.answer == null);
        ui.displayed_permission = ui.frame_permission;
        ui.displayed_permission_choice = .allow_once;
        try Ui.key(&ui, .enter);
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
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    ui.size = .{ .columns = 12, .rows = 7 };
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    const raw = "A\t\tB\t\tC";
    try ui.parser.feed("\x1b[200~" ++ raw ++ "\x1b[201~", sink);

    const cases = [_]usize{ raw.len, 3, 1 };
    for (cases) |cursor| {
        ui.editor.cursor = cursor;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const prepared = try ui.prepareComposer(arena.allocator(), ui.connection.current(), ui.size.columns -| 1);
        try ui.draw();
        try std.testing.expect(std.mem.findScalar(u8, ui.frame, '\t') == null);
        var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 12, .rows = 7 };
        try screen.replay(ui.frame);
        // The configured fixture has no notice, so the composer is the whole tail.
        try std.testing.expectEqual(prepared.layout.lines.len, ui.frame_height);
        try std.testing.expectEqual(screen.rows - prepared.layout.lines.len + prepared.layout.cursor_row, screen.row);
        try std.testing.expectEqual(text.width(prepared.decoration.plain) + prepared.layout.cursor_column, screen.col);
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
    effort: shared.ReasoningEffort = .off,
    levels: shared.activity.EffortSet = .{ .mask = 0x3f },
    selections: usize = 0,
    cycles: usize = 0,
    provider_saves: usize = 0,
    saved_provider: ?core_config.providers.Id = null,
    provider_hint: ?core_config.providers.Id = null,
    configured_providers: u8 = 0,
    profiles_override: ?[]const core_config.Model = null,
    model_providers: []const ModelProvider = &.{.{ .name = "fixture", .allow_custom = true }},
    disabled_models: []const bool = &.{},
    refreshes: usize = 0,
    metadata_changed: bool = false,
    pending_default: ?shared.ReasoningEffort = null,
    metadata_effort: ?shared.ReasoningEffort = null,
    key_matched: bool = false,
    fail: bool = false,
    proxy_configured: bool = false,
    proxy_list: [8][]const u8 = @splat(""),
    proxy_len: usize = 0,
    proxy_saves: usize = 0,
    proxy_fail: bool = false,
    proxy_last: ?[]const u8 = null,
    proxy_last_enabled: bool = false,
    /// Owner-published endpoint; members and endpoint are independent.
    proxy_address: ?[]const u8 = null,
    proxy_port: u16 = 0,
    proxy_address_buf: [253]u8 = undefined,
    proxy_endpoint: [core_config.max_proxy_endpoint_bytes]u8 = undefined,
    proxy_endpoint_len: usize = 0,
    proxy_address_saves: usize = 0,
    proxy_address_fail: bool = false,
    const profiles = [_]core_config.Model{.{ .name = "fixture/fixture-next", .context_tokens = 65536 }};
    /// Owner-side proxy list mutation: the UI never edits its own copy.
    fn proxyToggle(raw: *anyopaque, name: []const u8, enabled: bool) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.proxy_saves += 1;
        self.proxy_last = name;
        self.proxy_last_enabled = enabled;
        if (self.proxy_fail) return error.TestSelectionFailure;
        var index: usize = 0;
        while (index < self.proxy_len) : (index += 1) {
            if (std.mem.eql(u8, self.proxy_list[index], name)) break;
        }
        if (enabled) {
            if (index == self.proxy_len and self.proxy_len < self.proxy_list.len) {
                self.proxy_list[self.proxy_len] = name;
                self.proxy_len += 1;
            }
        } else if (index < self.proxy_len) {
            std.mem.copyForwards([]const u8, self.proxy_list[index..self.proxy_len], self.proxy_list[index + 1 .. self.proxy_len]);
            self.proxy_len -= 1;
        }
    }
    /// Owner-side endpoint mutation: parse, own the host bytes, publish. A
    /// failed save leaves the previous endpoint and members untouched. An empty
    /// value removes the whole proxy like the backend: the member list is
    /// dropped too, and no state survives for the next session.
    fn proxyEndpoint(raw: *anyopaque, value: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.proxy_address_saves += 1;
        if (value.len > self.proxy_endpoint.len) return error.TestSelectionFailure;
        @memcpy(self.proxy_endpoint[0..value.len], value);
        self.proxy_endpoint_len = value.len;
        if (self.proxy_address_fail) return error.TestSelectionFailure;
        self.proxy_address = null;
        self.proxy_port = 0;
        self.proxy_configured = false;
        if (value.len == 0) {
            for (self.proxy_list[0..self.proxy_len]) |*entry| entry.* = "";
            self.proxy_len = 0;
            return;
        }
        const parsed = (try core_config.parseProxyEndpoint(value)).?;
        if (parsed.address.len > self.proxy_address_buf.len) return error.TestSelectionFailure;
        @memcpy(self.proxy_address_buf[0..parsed.address.len], parsed.address);
        self.proxy_address = self.proxy_address_buf[0..parsed.address.len];
        self.proxy_port = parsed.port;
        self.proxy_configured = true;
    }
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
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .select_model_fn = select, .set_effort_fn = setEffort, .proxy_fn = proxyToggle, .proxy_address_fn = proxyEndpoint };
    }
    fn current(raw: *anyopaque) Connection.State {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return .{ .runtime = null, .model = self.name, .selection_name = if (std.mem.eql(u8, self.name, "fixture-old")) "fixture/fixture-old" else if (std.mem.eql(u8, self.name, "fixture-next")) "fixture/fixture-next" else self.name, .models = self.profiles_override orelse &profiles, .model_providers = self.model_providers, .model_disabled = self.disabled_models, .provider = self.provider_hint, .configured_providers = self.configured_providers, .context_limit = self.limit, .low_price_input = self.low_price_input, .settings_notice = self.settings_notice, .initial_context = .{ .tokens = 1000, .limit = self.limit }, .base_url = "http://localhost/unused", .reasoning_effort = self.effort, .effort_levels = self.levels, .pending_default_effort = self.pending_default, .proxy_configured = self.proxy_configured, .proxy_address = self.proxy_address, .proxy_port = self.proxy_port, .proxy_models = self.proxy_list[0..self.proxy_len] };
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
        const local = if (std.mem.startsWith(u8, name, "fixture/")) name["fixture/".len..] else name;
        const copy = try std.testing.allocator.dupe(u8, local);
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
    const owner_default: Connection.State = .{ .runtime = null, .model = "fixture/hidden", .base_url = "" };
    try std.testing.expect(@TypeOf(owner_default.model_providers) == []const ModelProvider);
    try std.testing.expectEqual(@as(usize, 0), owner_default.model_providers.len);
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
    testAcknowledgeFullFrame(&ui);
    ui.openModelPicker();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "No logged-in providers") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fixture-next") == null);
    testAcknowledgeFullFrame(&ui);
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
    try std.testing.expect(screen.visible("fixture-next) medium"));
    testAcknowledgeFullFrame(&ui);
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
    try std.testing.expect(screen.visible("fixture-late) high"));
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
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.left);
    try std.testing.expect(ui.model_picker == null and ui.commandMenuVisible());
    ui.openModelPicker();
    try ui.modelKey(.down);
    try ui.draw();
    try ui.modelKey(.enter); // A partial frame must not authorize the new row.
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    fixture.model_providers = &.{.{ .name = "replacement" }};
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try std.testing.expect(ui.model_picker != null);
    // Disabling a row after its acknowledged frame is also checked at Enter.
    fixture.disabled_models = &.{};
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    fixture.metadata_changed = true;
    ui.pollMetadata();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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

const ImageModelFixture = struct {
    const profiles = [_]core_config.Model{
        .{ .name = "login/deepseek-flash", .protocol = .chat, .context_tokens = 16384 },
        .{ .name = "unlogged/deepseek-flash", .protocol = .chat, .context_tokens = 16384 },
    };
    state: Connection.State = .{ .runtime = null, .model = "primary", .base_url = "", .image_models = &profiles, .decision_models = &DecisionModelFixture.profiles, .model_providers = &DecisionModelFixture.logged, .decision_enabled = true, .decision_model = "login/family/judge" },
    calls: usize = 0,
    decision_calls: usize = 0,
    fail: bool = false,
    fn current(raw: *anyopaque) Connection.State {
        return @as(*@This(), @ptrCast(@alignCast(raw))).state;
    }
    fn configure(_: *anyopaque, _: []const u8) !void {}
    fn image(raw: *anyopaque, choice: Connection.DecisionChoice) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail) return error.SaveFailed;
        self.state.image_enabled = choice != .off;
        self.state.image_model = switch (choice) {
            .off => null,
            .model => "login/deepseek-flash",
        };
        if (choice == .model) try std.testing.expectEqualStrings("login/deepseek-flash", choice.model);
    }
    fn decision(raw: *anyopaque, _: Connection.DecisionChoice) !void {
        @as(*@This(), @ptrCast(@alignCast(raw))).decision_calls += 1;
    }
    fn connection(self: *@This()) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .image_fn = image, .decision_fn = decision };
    }
};

test "Image settings default Off isolated callbacks search Back and explicit Off" {
    try text.initLocale();
    var fixture: ImageModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    try std.testing.expect(!fixture.state.image_enabled);
    try std.testing.expect((Connection.State{ .runtime = null, .model = "", .base_url = "" }).image_models.len == 0);
    ui.openSettingsMenu();
    ui.settings_menu.selected = 6;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expect(ui.image_open and !ui.decision_open and ui.settings_menu.selected == 0);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "login/deepseek-flash") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "unlogged/deepseek-flash") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "family/judge") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("no-match", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "No matching models") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try Ui.key(&ui, .clear);
    try ui.parser.feed("FLASH login", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(fixture.state.image_enabled and !ui.image_open and ui.settings_menu.selected == 6);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try std.testing.expectEqualStrings("login/family/judge", fixture.state.decision_model.?);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.image_open and ui.settings_menu.selected == 1);
    try ui.parser.feed("\x1b[A", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!fixture.state.image_enabled and ui.settings_menu.selected == 6);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\rquery\x1b[D\r", sink); // Root open discards the entire tail.
    try std.testing.expect(ui.image_open and ui.editor.bytes.items.len == 0);
    try ui.parser.feed("query\x1b[D\r", sink);
    try std.testing.expect(!ui.image_open and ui.settings_menu.selected == 6 and ui.editor.bytes.items.len == 0);
    ui.settings_menu.selected = 1;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open and !ui.image_open);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.decision_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqualStrings("primary", fixture.state.model);
}

test "Image settings fresh ACK pending partial resize changed candidates paste failed saves" {
    try text.initLocale();
    var fixture: ImageModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 6;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    try ui.parser.feed("\r", sink);
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    var replaced = ImageModelFixture.profiles;
    replaced[0].name = "login/replaced";
    fixture.state.image_models = &replaced;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    fixture.state.image_models = &ImageModelFixture.profiles;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const size = ui.size;
    ui.resize(.{ .columns = 8, .rows = size.rows });
    ui.resize(size);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.fail = true;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(ui.image_open and !fixture.state.image_enabled);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    fixture.fail = false;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~flash\x1b[201~\r", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    ui.closeSettingsMenu();
    try std.testing.expect(!ui.image_open and !ui.decision_open and ui.editor.bytes.items.len == 0);
    try std.testing.expect(ui.displayed_decision_fingerprint == null and ui.frame_decision_fingerprint == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.decision_calls);
}

const DecisionModelFixture = struct {
    const profiles = [_]core_config.Model{
        .{ .name = "login/family/judge", .protocol = .chat, .context_tokens = 16384 },
        .{ .name = "second/family/judge", .protocol = .chat, .context_tokens = 16384 },
        .{ .name = "unlogged/private-model", .protocol = .chat, .context_tokens = 16384 },
    };
    const logged = [_]ModelProvider{.{ .name = "login" }};
    const other = [_]ModelProvider{.{ .name = "second" }};
    state: Connection.State = .{ .runtime = null, .model = "primary", .selection_name = "main/primary", .base_url = "", .decision_models = &profiles, .model_providers = &logged },
    calls: usize = 0,
    main_calls: usize = 0,
    fail: bool = false,
    saved: [1089]u8 = undefined,
    saved_len: usize = 0,
    fn current(raw: *anyopaque) Connection.State {
        return @as(*@This(), @ptrCast(@alignCast(raw))).state;
    }
    fn configure(_: *anyopaque, _: []const u8) !void {}
    fn mainSelect(raw: *anyopaque, _: []const u8) !void {
        @as(*@This(), @ptrCast(@alignCast(raw))).main_calls += 1;
        return error.UnexpectedMainSelection;
    }
    fn choose(raw: *anyopaque, choice: Connection.DecisionChoice) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail) return error.SaveFailed;
        const name = switch (choice) {
            .model => |value| value,
            else => return error.UnexpectedBackend,
        };
        @memcpy(self.saved[0..name.len], name);
        self.saved_len = name.len;
        self.state.decision_model = self.saved[0..name.len];
        self.state.decision_enabled = true;
    }
    fn connection(self: *@This()) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .select_model_fn = mainSelect, .decision_fn = choose };
    }
};

test "Decision direct list isolates selection and consumes failed save ACK and input batch" {
    try text.initLocale();
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("\x1b[B", sink);
    try std.testing.expect(ui.settings_open and ui.decision_open and ui.model_picker == null);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "login/family/judge") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "unlogged/private-model") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "second/family/judge") == null);
    try ui.parser.feed("\r", sink);
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    // Same-index rename, protocol-only replacement, and logout all revoke ACK.
    var replacement = DecisionModelFixture.profiles;
    for (0..3) |scenario| {
        if (scenario != 0) try ui.draw();
        replacement = DecisionModelFixture.profiles;
        switch (scenario) {
            0 => {
                replacement[0].name = "login/replaced/Judge";
                fixture.state.decision_models = &replacement;
            },
            1 => {
                replacement[0].protocol = .responses;
                fixture.state.decision_models = &replacement;
            },
            2 => fixture.state.model_providers = &.{},
            else => unreachable,
        }
        if (scenario != 0) testAcknowledgeFullFrame(&ui); // Publish only the frame's old identity.
        try ui.parser.feed("\r\r", sink);
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
        fixture.state.decision_models = &DecisionModelFixture.profiles;
        fixture.state.model_providers = &DecisionModelFixture.logged;
        try ui.parser.feed("\r", sink); // Owner ABA cannot restore consumed ACK.
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    }
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // The same raw ID on a different newly visible alias cannot inherit ACK.
    fixture.state.model_providers = &DecisionModelFixture.other;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    fixture.state.model_providers = &DecisionModelFixture.logged;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const size = ui.size;
    ui.resize(.{ .columns = 8, .rows = size.rows });
    ui.resize(size);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.fail = true;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(ui.decision_open and !fixture.state.decision_enabled);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    fixture.fail = false;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r\x1b[A", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqualStrings("login/family/judge", fixture.saved[0..fixture.saved_len]);
    try std.testing.expectEqual(@as(usize, 0), fixture.main_calls);
    try std.testing.expectEqualStrings("primary", fixture.state.model);
    try std.testing.expect(ui.settings_open and !ui.decision_open and ui.model_picker == null);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open and ui.settings_menu.selected == 1);
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(ui.settings_open and !ui.decision_open and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "Decision list offers Off without providers and never invents search identities or accepts paste" {
    try text.initLocale();
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    fixture.state.decision_model = "login/ghost-current";
    fixture.state.model_providers = &.{};
    ui.openSettingsMenu();
    ui.decision_open = true;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "login/family/judge") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "ghost-current") == null);
    try std.testing.expect(ui.frame_settings_generation != null); // Off remains available.
    testAcknowledgeFullFrame(&ui);
    fixture.state.model_providers = &DecisionModelFixture.logged;
    try ui.parser.feed("\r", sink); // Availability changed since ACK, even for Off.
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("arbitrary-raw-id", sink);
    ui.settings_menu.selected = 1;
    try ui.draw();
    try std.testing.expect(ui.model_picker == null);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .escape);
    try std.testing.expect(ui.settings_open and !ui.decision_open and ui.settings_menu.selected == 1);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~login/family/judge\x1b[201~\r", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.main_calls);
}

test "Decision search edits revoke query ACK including pending frames and clear on return" {
    try text.initLocale();
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.decision_open = true;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("LOGIN FAMILY/JUDGE\r", sink);
    try std.testing.expectEqualStrings("LOGIN FAMILY/JUDGE", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), ui.settings_menu.selected);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Search> ") != null);
    // An edit while the old query frame is in flight must revoke its ACK too.
    try ui.parser.feed("x", sink);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "No matching models") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[A\x1b[B\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("\x7f", sink);
    try std.testing.expectEqualStrings("LOGIN FAMILY/JUDGE", ui.editor.bytes.items);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // Query changes and changes back cannot resurrect the old identity proof.
    try ui.parser.feed("x\x7f\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!ui.decision_open and ui.editor.bytes.items.len == 0);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "login/family/judge") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open and ui.editor.bytes.items.len == 0);
    try ui.parser.feed("oFf\x15missing", sink);
    try std.testing.expectEqualStrings("missing", ui.editor.bytes.items);
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.decision_open and ui.editor.bytes.items.len == 0);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    const large: [257]u8 = @splat('x');
    try Ui.key(&ui, .{ .text = .{ .value = &large, .pasted = false } });
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try Ui.key(&ui, .{ .text = .{ .value = large[0..256], .pasted = false } });
    try std.testing.expectEqual(@as(usize, 256), ui.editor.bytes.items.len);
    try Ui.key(&ui, .clear);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try Ui.key(&ui, .{ .text = .{ .value = "login", .pasted = false } });
    ui.closeSettingsMenu();
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try std.testing.expectEqualStrings("Command timeout (s)", Ui.settingsValueTitle(.command_timeout_ms));
    try std.testing.expectEqualStrings("Task timeout (s)", Ui.settingsValueTitle(.task_timeout_ms));
    try std.testing.expect(std.mem.find(u8, Ui.settingsValueTitle(.request_timeout_ms), "(s;") != null);
}

test "Decision search clips UTF8 controls and tiny windows without granting authority" {
    try text.initLocale();
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.decision_open = true;
    try ui.settingsKey(.{ .text = .{ .value = "中文中文中文中文中文\x1b[2J", .pasted = false } });
    for ([_]terminal_module.Size{ .{ .columns = 0, .rows = 0 }, .{ .columns = 8, .rows = 6 }, .{ .columns = 18, .rows = 8 }, .{ .columns = 40, .rows = 12 } }) |size| {
        ui.resize(size);
        try ui.draw();
        try std.testing.expect(std.unicode.utf8ValidateSlice(ui.frame));
        try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
        testAcknowledgeFullFrame(&ui);
        try ui.settingsKey(.enter);
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    }
    try ui.settingsKey(.home);
    try ui.settingsKey(.delete);
    try std.testing.expect(std.mem.startsWith(u8, ui.editor.bytes.items, "文中文"));
    try ui.settingsKey(.end);
    try ui.settingsKey(.kill_end);
    try ui.settingsKey(.cancel);
    try std.testing.expect(ui.settings_open and !ui.decision_open and ui.editor.bytes.items.len == 0);
}

test "Decision search OOM preserves bytes but revokes every old ACK" {
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.decision_open = true;
    ui.displayed_settings_generation = ui.settings_menu.generation;
    ui.frame_settings_generation = ui.settings_menu.generation;
    ui.displayed_decision_fingerprint = decision_picker_module.fingerprint(fixture.state.decision_models, fixture.state.model_providers);
    ui.frame_decision_fingerprint = ui.displayed_decision_fingerprint;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ui.editor.allocator = failing.allocator();
    defer ui.editor.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, ui.settingsKey(.{ .text = .{ .value = "judge", .pasted = false } }));
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try std.testing.expect(ui.displayed_settings_generation == null and ui.frame_settings_generation == null);
    try std.testing.expect(ui.displayed_decision_fingerprint == null and ui.frame_decision_fingerprint == null);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "settings TUI custom seconds stages equivalent milliseconds" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 3;
    ui.openSettingsValue(.command_timeout_ms, fixture.state);
    ui.settings_menu.selected = try customPreferenceOption(ui.settings_value_picker.?);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(std.mem.find(u8, ui.notice, "seconds") != null);
    try ui.settingsKey(.{ .text = .{ .value = "123.456", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(u32, 123456), fixture.state.limits.command_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

const PreferenceFixture = struct {
    state: Connection.State = .{ .runtime = null, .model = "unchanged-primary", .base_url = "" },
    calls: usize = 0,
    fail: bool = false,
    fn current(raw: *anyopaque) Connection.State {
        return @as(*@This(), @ptrCast(@alignCast(raw))).state;
    }
    fn configure(_: *anyopaque, _: []const u8) !void {}
    fn save(raw: *anyopaque, key_: preference.Key, value: ?u32) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail) return error.SaveFailed;
        switch (key_) {
            .compaction_enabled => self.state.limits.compaction_enabled = value.? == 1,
            .memory_auto => self.state.memory_auto = value.? == 1,
            .command_timeout_ms => self.state.limits.command_timeout_ms = value.?,
            .request_timeout_ms => self.state.limits.request_timeout_ms = value.?,
            .task_timeout_ms => self.state.limits.task_timeout_ms = value.?,
        }
    }
    fn connection(self: *@This()) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .preference_fn = save };
    }
};
fn preferenceOption(picker: settings_value_module.Picker, value: ?u32) !usize {
    for (0..picker.count()) |index| {
        if (picker.isCustom(index)) continue;
        const candidate = picker.chosen(index) catch continue;
        if (candidate == value) return index;
    }
    return error.MissingPreferenceOption;
}
fn customPreferenceOption(picker: settings_value_module.Picker) !usize {
    for (0..picker.count()) |index| if (picker.isCustom(index)) return index;
    return error.MissingCustomOption;
}

test "Auto memory root toggles only after fresh ACK without overlays and preserves failed save" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 7;
    try ui.draw();
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!fixture.state.memory_auto);
    try std.testing.expect(ui.settings_value_picker == null and !ui.settingsModelOpen());
    try std.testing.expect(ui.settings_open and ui.settings_menu.selected == 7);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.fail = true;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expect(!fixture.state.memory_auto);
    try std.testing.expect(ui.settings_value_picker == null and !ui.settingsModelOpen());
    fixture.fail = false;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(fixture.state.memory_auto);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}

test "settings numeric child consumes ACK before failed save and preserves parent" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 2;
    try ui.draw();
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!fixture.state.limits.compaction_enabled);
    ui.settings_menu.selected = 3;
    ui.openSettingsValue(.command_timeout_ms, fixture.state);
    ui.settings_menu.selected = try preferenceOption(ui.settings_value_picker.?, 60000);
    try ui.draw();
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    const size = ui.size;
    ui.resize(.{ .columns = 8, .rows = size.rows });
    ui.resize(size);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.fail = true;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(u32, 300000), fixture.state.limits.command_timeout_ms);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    fixture.fail = false;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r\x1b[B", sink);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqual(@as(u32, 60000), fixture.state.limits.command_timeout_ms);
    try std.testing.expect(ui.settings_value_picker == null and ui.settings_menu.selected == 3 and ui.settings_open);
    try std.testing.expectEqualStrings("unchanged-primary", fixture.state.model);
}

test "settings custom task timeout stages before a second fresh ACK and preserves parent" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    fixture.state.limits.task_timeout_ms = 1024;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 5;
    ui.openSettingsValue(.task_timeout_ms, fixture.state);
    ui.settings_menu.selected = try customPreferenceOption(ui.settings_value_picker.?);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expect(ui.settings_value_picker.?.editing);
    try ui.parser.feed("\x158.192\r", sink);
    try std.testing.expect(ui.settings_value_picker.?.editing);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expect(!ui.settings_value_picker.?.editing);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(u32, 1024), fixture.state.limits.task_timeout_ms);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(u32, 8192), fixture.state.limits.task_timeout_ms);
    try std.testing.expect(ui.settings_value_picker == null and ui.settings_menu.selected == 5);
    ui.openSettingsValue(.task_timeout_ms, fixture.state);
    ui.settings_menu.selected = try preferenceOption(ui.settings_value_picker.?, 300000);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(u32, 300000), fixture.state.limits.task_timeout_ms);
    try std.testing.expect(ui.settings_value_picker == null and ui.settings_menu.selected == 5);
}

test "settings shared request timeout rejects pasted numbers and preserves parent" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 4;
    ui.openSettingsValue(.request_timeout_ms, fixture.state);
    ui.settings_menu.selected = try customPreferenceOption(ui.settings_value_picker.?);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("\x1b[200~1000\r\x1b[201~\r", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expect(ui.settings_value_picker.?.editing);
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(!ui.settings_value_picker.?.editing);
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(ui.settings_value_picker == null and !ui.decision_open and ui.settings_menu.selected == 4);
    ui.openSettingsValue(.request_timeout_ms, fixture.state);
    ui.settings_menu.selected = try preferenceOption(ui.settings_value_picker.?, 60000);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(u32, 60000), fixture.state.limits.request_timeout_ms);
    try std.testing.expect(!ui.decision_open and !fixture.state.decision_enabled and ui.settings_menu.selected == 4);
}

test "settings callbacks owner publication ACK paste batch and cursor" {
    try text.initLocale();
    const Fixture = struct {
        state: Connection.State = .{ .runtime = null, .model = "fixture", .base_url = "", .decision_models = &DecisionModelFixture.profiles, .model_providers = &DecisionModelFixture.logged },
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
            self.state.decision_model = switch (choice) {
                .off => null,
                .model => |name| name,
            };
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r\x1b[B", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!fixture.state.low_price_input_enabled and ui.settings_menu.selected == 0);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open and !fixture.state.decision_enabled);
    const before_choice = fixture.calls;
    try ui.parser.feed("\x1b[B\r", sink); // Stale navigation cannot confirm.
    try std.testing.expectEqual(before_choice, fixture.calls);
    try ui.draw();
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink); // Partial child output cannot confirm.
    try std.testing.expectEqual(before_choice, fixture.calls);
    testAcknowledgeFullFrame(&ui);
    // Save the direct identity without changing chat.
    try ui.parser.feed("\r\r\x1b[A", sink);
    try std.testing.expect(fixture.state.decision_enabled);
    try std.testing.expectEqualStrings("login/family/judge", fixture.state.decision_model.?);
    try std.testing.expect(!ui.decision_open and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(@as(u32, 42), ui.display.context.?.tokens);
    fixture.fail = true;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink); // Open the selected model, not toggle.
    try std.testing.expect(ui.decision_open);
    try ui.parser.feed("\x1b[A", sink); // Off.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open);
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.decision_open and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(calls, fixture.calls);
    fixture.state.global_settings_available = false;
    try ui.parser.feed("\x1b[A", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    fixture.state.global_settings_available = true;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const original = ui.size;
    ui.resize(.{ .columns = 8, .rows = original.rows });
    ui.resize(original); // Resize ABA cannot restore authority.
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    ui.resize(.{ .columns = 12, .rows = original.rows });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    ui.resize(original);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~pasted\x1b[201~\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.parser.feed("\x1b[D", sink);
    try std.testing.expect(!ui.settings_open);
    try std.testing.expectEqual(command_menu_module.Command.settings, ui.command_menu.choice(ui.command_matches).?);
}

test "decision child requires full fresh unclipped ACK and never saves pasted batch tails" {
    try text.initLocale();
    const Fixture = struct {
        state: Connection.State = .{ .runtime = null, .model = "", .base_url = "", .decision_models = &DecisionModelFixture.profiles, .model_providers = &DecisionModelFixture.logged },
        calls: usize = 0,
        fn current(raw: *anyopaque) Connection.State {
            return @as(*@This(), @ptrCast(@alignCast(raw))).state;
        }
        fn configure(_: *anyopaque, _: []const u8) !void {}
        fn choose(raw: *anyopaque, choice: Connection.DecisionChoice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.state.decision_enabled = choice != .off;
            self.state.decision_model = switch (choice) {
                .off => null,
                .model => |name| name,
            };
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expect(ui.decision_open);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    try ui.parser.feed("\r", sink);
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    const size = ui.size;
    ui.resize(.{ .columns = 8, .rows = size.rows });
    ui.resize(size);
    try ui.parser.feed("\r", sink); // Resize ABA.
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    ui.resize(.{ .columns = 17, .rows = size.rows });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink); // Complete provider/raw ID does not fit.
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    ui.resize(size);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~\r\x1b[D\x1b[201~\r", sink);
    try std.testing.expect(ui.decision_open);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(!ui.decision_open and ui.settings_menu.selected == 1);
    try ui.parser.feed("\r", sink); // Old child ACK cannot open parent.
    try std.testing.expect(!ui.decision_open);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.decision_open);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[B\r", sink); // Move to login, but no fresh ACK yet.
    try std.testing.expect(!ui.provider_open and !ui.secret_mode);
    try std.testing.expectEqual(command_menu_module.Command.auth, ui.command_menu.choice(ui.command_matches).?);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "> /login") != null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const model_row = try rowStartingWith(&screen, "  /model");
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[model_row + 1], "> /login"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[model_row + 2], "  /compact"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("menu-prior-answer"));
    try ui.parser.feed("\r", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ ">   Current endpoint") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.muted ++ "    DeepSeek") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "Provider> " ++ theme.reset) != null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const endpoint_row = try rowStartingWith(&screen, ">   Current endpoint");
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[endpoint_row + 3], "    OpenCode Go"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[screen.row], "Provider> "));
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(!ui.provider_open and !ui.secret_mode);
    try std.testing.expectEqual(command_menu_module.Command.auth, ui.command_menu.choice(ui.command_matches).?);
    try ui.parser.feed("\x1b[A", sink); // Return from login to model.
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.success ++ "✓" ++ theme.accent ++ " fixture/fixture-old") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.muted ++ "    fixture/fixture-next") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "Search> " ++ theme.reset) != null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const selected_model_row = try rowStartingWith(&screen, "> ~ fixture/fixture-old");
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[selected_model_row + 1], "    fixture/fixture-next"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[screen.row], "Search> "));
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
        .name = try std.fmt.allocPrint(arena.allocator(), "fixture/menu-{d:0>2}", .{index}),
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
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ ">   fixture/menu-11") != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    var count: usize = 0;
    for (screen.grid) |line| if (std.mem.find(u8, &line, "menu-") != null) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 10), count);
    // Ten bottom-pinned rows end with the selection; the composer stays below.
    const selected_row = try rowStartingWith(&screen, ">   fixture/menu-11");
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[selected_row - 9], "    fixture/menu-02"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[screen.row], "Search> "));
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("fake-ui-key", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "API key> " ++ theme.reset) != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fake-ui-key") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[Ddiscard-tail", sink);
    try std.testing.expect(ui.provider_open and !ui.secret_mode and ui.secret.len == 0);
    try std.testing.expectEqual(core_config.providers.Id.opencode_zen, ui.provider_choices.items[ui.provider_picker.selected].provider);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode); // Newly reopened parent needs ACK.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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

test "metadata success publishes one transcript notice from an owner transition" {
    const Fixture = struct {
        notice: ?[]const u8 = null,
        next: ?[]const u8 = "Official model list refreshed",
        ttl: u16 = 3000,
        runtime: r.Runtime = undefined,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .runtime = &self.runtime, .model = "fixture", .base_url = "", .metadata_notice = self.notice, .metadata_notice_ttl_ms = self.ttl };
        }
        fn poll(raw: *anyopaque, _: bool) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.notice = self.next;
            return true;
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = Fixture.current;
    ui.connection.poll_models_fn = Fixture.poll;
    _ = try ui.editor.insert("kept draft");
    ui.notice = "Refreshing official model metadata...";
    ui.clock_ms = 100;
    ui.pollMetadata();
    // Ordinary success is a one-shot display record; the footer returns to the
    // actionable default instead of owning a timer.
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(Kind.notice, ui.records.items[0].kind);
    try std.testing.expectEqualStrings(fixture.next.?, ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("", try ui.hint(std.testing.allocator, ui.connection.current()));
    // Repeated identical snapshots, even far in the future, never duplicate the
    // record, hide the draft or stage a timer-driven frame.
    ui.pollMetadata();
    ui.clock_ms = 999_999;
    ui.pollMetadata();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqualStrings("kept draft", ui.editor.bytes.items);

    // A later owner transition publishes exactly one more record.
    fixture.notice = null;
    ui.clock_ms = 4000;
    ui.pollMetadata();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqual(Kind.notice, ui.records.items[1].kind);
    // An unclassified failure remains actionable in the footer and adds no record.
    fixture.next = "Official metadata refresh failed; cached/default values kept";
    fixture.ttl = 0;
    ui.pollMetadata();
    try std.testing.expectEqualStrings(fixture.next.?, ui.notice);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
}

test "memory notice owner poll dirties UI without replacing foreground notice" {
    const Fixture = struct {
        view: @import("../core/memory_status.zig").View = .{},
        changed: bool = false,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .runtime = null, .model = "fixture", .base_url = "", .memory = self.view };
        }
        fn poll(raw: *anyopaque, _: bool) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const changed = self.changed;
            self.changed = false;
            return changed;
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = Fixture.current;
    ui.connection.poll_models_fn = Fixture.poll;
    ui.notice = "Foreground error";
    inline for (.{ true, false }) |enabled| {
        fixture.view = .{ .enabled = enabled, .active = if (enabled) .{ .id = 1, .phase = .extracting } else null };
        fixture.changed = true;
        ui.dirty = false;
        ui.pollMetadata();
        try std.testing.expect(ui.dirty);
        try std.testing.expectEqualStrings("Foreground error", ui.notice);
        ui.dirty = false;
        ui.pollMetadata();
        try std.testing.expect(!ui.dirty); // Identical snapshot is not a transition.
    }
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}

test "memory notice is advisory and never replaces errors queue or settings" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime: r.Runtime = undefined;
    var state = ui.connection.current();
    state.runtime = &runtime;
    state.memory = .{ .enabled = true, .active = .{ .id = 1, .phase = .extracting } };
    state.pending_default_effort = .medium;
    try std.testing.expectEqualStrings("Memory: extracting", try ui.hint(arena.allocator(), state));
    ui.notice = "Approval required";
    try std.testing.expectEqualStrings("Approval required", try ui.hint(arena.allocator(), state));
    ui.notice = "Ready";
    state.settings_error = error.TestSettingsFailure;
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "Memory:") == null);
    state.settings_error = null;
    state.settings_notice = "Settings warning";
    try std.testing.expectEqualStrings("Memory: extracting | Settings warning", try ui.hint(arena.allocator(), state));
    state.settings_notice = null;
    state.log_error = error.TestLogFailure;
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "REC FAILED") != null);
    state.log_error = null;
    ui.permission = .{ .id = 17, .description = try std.testing.allocator.dupe(u8, "owned approval"), .clipped = false };
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "Memory:") == null);
    std.testing.allocator.free(ui.permission.?.description);
    ui.permission = null;
    ui.stop_open = true;
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "Memory:") == null);
    ui.stop_open = false;
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "queued input");
    try std.testing.expectEqualStrings("Memory: extracting", try ui.hint(arena.allocator(), state));
    ui.openSettingsMenu();
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));
}

test "wrapped composer cursor is ACK owned across sparse redraws" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 30, .rows = 12 };
    const raw = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL";
    _ = try ui.editor.insert(raw);
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 30, .rows = 12 };
    try ui.draw();
    try std.testing.expect(ui.frame_composer_rows > 1 and ui.frame_composer_rows <= composer_layout.max_rows);
    try std.testing.expectEqualStrings(raw, ui.editor.bytes.items);
    try screen.replay(ui.frame);
    // The composer occupies the tail; the notice sits directly above it and no
    // blank screen rows are written below the last composer row.
    try std.testing.expectEqual(ui.frame_composer_rows + 1, ui.frame_height);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    const rows = ui.tail_composer_rows;
    ui.editor.cursor = 0;
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 0), ui.tail_cursor_rows_up);
    try std.testing.expect(ui.frame_cursor_rows_up > 0);
    try screen.replay(ui.frame);
    const up = ui.frame_cursor_rows_up;
    try std.testing.expectEqual(screen.rows - 1 - up, screen.row);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(up, ui.tail_cursor_rows_up);
    try std.testing.expectEqual(rows, ui.tail_composer_rows);
    ui.editor.cursor = ui.editor.bytes.items.len;
    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try screen.replay(ui.frame);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expectEqual(@as(usize, 1), screen.count("(fixture)"));
    try std.testing.expectEqualStrings(raw, ui.editor.bytes.items);
    testAcknowledgeFullFrame(&ui);
}

test "closing approval reuses its footprint without erasing a multiline composer" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 30, .rows = 16 };
    _ = try ui.editor.insert("AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH");
    ui.editor.cursor = 0;
    ui.permission = .{ .id = 7, .description = try std.testing.allocator.dupe(u8, "approval one\napproval two\napproval three"), .clipped = false };
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 30, .rows = 16 };
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const before = ui.tail_height;
    try std.testing.expect(before > 4);
    ui.clearPermission();
    try ui.draw();
    const after = ui.frame_height;
    try std.testing.expectEqual(before, after); // Reused owned rows keep the footer anchored.
    try std.testing.expect(ui.frame_composer_rows > 1);
    try std.testing.expect(ui.frame_cursor_rows_up > 0); // cursor on the first composer line
    const suffix = ui.frame_tail_snapshot.?.cursor_suffix;
    try std.testing.expect(std.mem.indexOfScalar(u8, suffix, '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, suffix, "\x1b[M") == null);
    try screen.replay(ui.frame);
    // Every prepared composer row survives; cleaning from the already-moved-up
    // cursor row would have erased the lower two. The HHHH marker wraps across
    // two rows, so compare each actual visible suffix and the whole raw text.
    var composer_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer composer_arena.deinit();
    const prepared = try ui.prepareComposer(composer_arena.allocator(), ui.connection.current(), ui.size.columns -| 1);
    try std.testing.expectEqual(ui.frame_composer_rows, prepared.layout.lines.len);
    const decoration_width = text.width(prepared.decoration.plain);
    const first_row = screen.row - prepared.layout.cursor_row;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (prepared.layout.lines, 0..) |line, index| {
        const visible = std.mem.trimEnd(u8, screen.grid[first_row + index][decoration_width..], " ");
        try std.testing.expectEqualStrings(line, visible);
        try joined.appendSlice(std.testing.allocator, visible);
    }
    try std.testing.expectEqualStrings(ui.editor.bytes.items, joined.items);
    try std.testing.expectEqual(screen.rows - 1 - ui.frame_cursor_rows_up, screen.row);
    testAcknowledgeFullFrame(&ui);
}

test "wrapped composer idle LF debt first obtains a single row fresh ACK" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 30, .rows = 12 };
    _ = try ui.editor.insert("abcdefghijklmnopqrstuvwxyz0123456789");
    ui.editor.cursor = 0;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.tail_composer_rows > 1 and ui.tail_cursor_rows_up > 0);
    ui.editor.clear();
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(u16, 1), ui.idle_breaks);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
    try std.testing.expectEqual(@as(usize, 1), ui.frame_composer_rows);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 1), ui.frame_idle_breaks);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}

test "uncertain memory view remains in footer without records" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var runtime: r.Runtime = undefined;
    var state = ui.connection.current();
    state.runtime = &runtime;
    state.memory = .{ .enabled = true, .last_terminal = .{ .id = 1, .result = .uncertain } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ui.clock_ms = 100;
    try std.testing.expectEqualStrings("Memory: request outcome uncertain", try ui.hint(arena.allocator(), state));
    ui.notice = "Foreground error";
    try std.testing.expectEqualStrings("Foreground error", try ui.hint(arena.allocator(), state));
    ui.notice = "Ready";
    ui.clock_ms = 999_999;
    try std.testing.expectEqualStrings("Memory: request outcome uncertain", try ui.hint(arena.allocator(), state));
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expect(ui.future == null and !ui.has_submitted);
    try std.testing.expect(ui.inbox.snapshot().newest_id == null);
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
    testAcknowledgeFullFrame(&ui);
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
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[screen.row], "API key> ***********"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "API key for OpenCode Go") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "https://opencode.ai/zen/go/v1") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fake-ui-key") == null);
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("nexttext", sink);
    try std.testing.expectEqualStrings("nexttext", ui.editor.bytes.items);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], "nexttext") != null);
    try std.testing.expectEqual(@as(usize, 0), screen.count("same-read-secret-tail"));
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(fixture.key_matched and fixture.provider_saves == 1);
    try std.testing.expectEqual(core_config.providers.Id.opencode_go, fixture.saved_provider.?);
    try std.testing.expect(publishedNotice(&ui, "saved locally"));
    try std.testing.expectEqualStrings("Ready", ui.notice);
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resize(.{ .columns = 81, .rows = 24 });
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!ui.provider_open);
    try ui.parser.feed("/login\r\r", sink);
    try std.testing.expect(ui.provider_open and !ui.secret_mode);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~fake-ui-key\x1b[201~\r", sink);
    try std.testing.expect(ui.provider_picker.pasted and !ui.secret_mode);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "fake-ui-key") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x15\r", sink);
    try std.testing.expect(!ui.secret_mode); // Clear requires a fresh frame too.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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
    try std.testing.expectEqual(core_config.providers.Id.all.len, ui.provider_choices.len);
    ui.size = .{ .columns = 12, .rows = 9 };
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "DeepSeek") != null);
    testAcknowledgeFullFrame(&ui);
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
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .auto_refresh_models = true });
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
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Could not save") != null);
    try std.testing.expect(session.app.?.config.value.model.reasoning != null);
    try std.testing.expectEqual(shared.ReasoningEffort.high, session.connection().current().reasoning_effort);
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/config.json", .data = saved_settings });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(shared.ReasoningEffort.off, session.connection().current().reasoning_effort);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(shared.ReasoningEffort.low, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(shared.ReasoningEffort.low, shared.ReasoningEffort.fromName(session.global_config.?.value.registry.?.reasoning_effort));
    const wire = r.withReasoning(session.app.?.config.value, .{ .scope = .{ .connection = "https://api.deepseek.com", .model = "deepseek-flash", .protocol = .chat }, .system = "", .tools = &.{}, .messages = &.{} });
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
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("fixture-old) 3.1%"));
    try std.testing.expect(ui.effort_flash == null);

    ui.clock_ms = 1000;
    ui.cycleEffort(); // low -> high, expires at 3000.
    const context = ui.display.context;
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("fixture-old) high"));
    try std.testing.expectEqualDeep(context, ui.display.context);
    // The composer and its real notice occupy a short bottom tail.
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expectEqual(@as(usize, 2), ui.frame_height);
    try std.testing.expectEqual(text.width("(fixture-old) high> "), screen.col);

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
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("fixture-old) max"));

    ui.display.context = .{ .tokens = 2000, .limit = fixture.limit };
    ui.clock_ms = 4500;
    ui.expireEffortFlash(); // Idle expiry schedules a redraw without a keypress.
    try std.testing.expect(ui.dirty and ui.effort_flash == null);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("fixture-old) 6.1%"));
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    ui.cycleEffort();
    try std.testing.expect(ui.effort_flash == null);
    fixture.fail = false;
    ui.cycleEffort();
    try ui.selectModel("fixture-next");
    try std.testing.expectEqual(fixture.effort, ui.effort_flash.?.level);
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
    testAcknowledgeFullFrame(&ui);

    // Case-insensitive filtering keeps only the matching entry.
    try ui.parser.feed("LO", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "/login") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/model") == null);
    testAcknowledgeFullFrame(&ui);

    // Esc dismisses until the token changes again.
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!ui.commandMenuVisible());
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Commands") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Configure provider") == null);
    // The independent setup hint remains; it is not a menu item.
    try std.testing.expect(std.mem.find(u8, ui.frame, "Not configured: /login") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("G", sink);
    try std.testing.expect(ui.commandMenuVisible());
    try ui.draw();
    testAcknowledgeFullFrame(&ui);

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
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/model", ui.editor.bytes.items);
    try std.testing.expectEqual(ui.editor.bytes.items.len, ui.editor.cursor);
    try std.testing.expect(ui.model_picker == null and ui.commandMenuVisible());
    try std.testing.expect(!ui.busy and !ui.secret_mode and !ui.provider_open);
    try std.testing.expect(ui.displayed_command_generation == null);
    try ui.draw();
    try std.testing.expect(ui.commandMenuVisible());
    testAcknowledgeFullFrame(&ui);
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
        testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[B\t", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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
        testAcknowledgeFullFrame(&ui);
        try ui.parser.feed("\t", sink);
        try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
        try ui.parser.feed("\r", sink);
        try std.testing.expect(ui.model_picker == null and !ui.secret_mode);
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try ui.parser.feed("lg\t\r", sink);
        try std.testing.expect(!ui.secret_mode); // Changed token/selection is not yet shown.
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
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
                const initial_height = ui.frame_height;
                const initial_above = ui.frame_menu_history.?.above.len;
                const initial_borrowed = ui.frame_menu_history.?.borrowed.len;
                try screen.replay(ui.frame);
                const initial_tail_start = (screen.row + ui.frame_cursor_rows_up + 1) -| initial_height;
                testAcknowledgeFullFrame(&ui);
                const before = screen.grid;
                const history_before = screen.history_len;
                const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
                try ui.parser.feed(command, sink);
                try ui.draw();
                const menu_height = ui.frame_height;
                const menu_borrow_count = ui.frame_borrow_rows;
                const menu_above = ui.frame_menu_history.?.above.len;
                const menu_borrowed = ui.frame_menu_history.?.borrowed.len;
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
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
                const close_height = ui.frame_height;
                const close_above = ui.frame_menu_history.?.above.len;
                const close_borrowed = ui.frame_menu_history.?.borrowed.len;
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
                for (before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2], 0..) |old, restored, row| {
                    if (!std.mem.eql(u8, &old, &restored)) {
                        std.debug.print("popup restore history={d} size={d}x{d} command={s} row={d}\ninitial height={d} tail_start={d} above={d} borrowed={d}; menu height={d} borrow_count={d} above={d} borrowed={d}; close height={d} above={d} borrowed={d}\n", .{
                            history_length,    dimensions.columns, dimensions.rows, std.mem.trimEnd(u8, command, "\r"), row,
                            initial_height,    initial_tail_start, initial_above,   initial_borrowed,                   menu_height,
                            menu_borrow_count, menu_above,         menu_borrowed,   close_height,                       close_above,
                            close_borrowed,
                        });
                    }
                    try std.testing.expectEqualStrings(&old, &restored);
                }
                try std.testing.expectEqual(history_before, screen.history_len);
                // A second ordinary frame must retain the repaired history too.
                try ui.draw();
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                for (before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                    try std.testing.expectEqualStrings(&old, &restored);
                if (history_length == 60) {
                    // Completed history belongs to native scrollback: PageUp is
                    // not a program preview and never regroups canonical records.
                    const browsing_before = screen.grid;
                    for (0..8) |_| try ui.parser.feed("\x1b[5~", sink);
                    try ui.draw();
                    try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                    try screen.replay(ui.frame);
                    testAcknowledgeFullFrame(&ui);
                    try std.testing.expectEqual(history_before, screen.history_len);
                    for (browsing_before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                        try std.testing.expectEqualStrings(&old, &restored);
                    for (0..8) |_| try ui.parser.feed("\x1b[6~", sink);
                    try ui.draw();
                    try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                    try screen.replay(ui.frame);
                    testAcknowledgeFullFrame(&ui);
                    for (browsing_before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                        try std.testing.expectEqualStrings(&old, &restored);
                    try std.testing.expectEqual(history_before, screen.history_len);
                }
                _ = try ui.add(.assistant, "new-row");
                try ui.draw();
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                // Releasing a repaired prefix for subsequent output must not
                // duplicate or lose ANY earlier line, including native history.
                for (0..history_length) |i| {
                    var marker: [16]u8 = undefined;
                    const value = try std.fmt.bufPrint(&marker, "row-{d:0>3}", .{i});
                    try std.testing.expectEqual(@as(usize, 1), screen.count(value));
                }
                try std.testing.expectEqual(@as(usize, 1), screen.count("new-row"));
                try ui.parser.feed(command, sink);
                try ui.draw();
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                // A width ABA revokes every physical coordinate. The next fresh
                // frame establishes a bottom anchor without reclaiming stale rows
                // or regenerating completed record text.
                ui.resize(.{ .columns = dimensions.columns - 1, .rows = dimensions.rows });
                ui.resize(dimensions);
                try std.testing.expect(ui.tail_snapshot == null and ui.abandon_tail and !ui.tail_bottom);
                // ABA back to the original size grants no autonomous repaint.
                ui.clock_ms += 5000;
                ui.resize(dimensions);
                ui.animate();
                try std.testing.expect(!ui.drawReady() and ui.frame.len == 0);
                ui.requestDraw(); // Genuine input, not a geometry repair.
                try ui.draw();
                try std.testing.expect(std.mem.find(u8, ui.frame[0..ui.frame_clear_end], "\x1b[999B") == null);
                try std.testing.expect(std.mem.find(u8, ui.frame[0..ui.frame_clear_end], "\x1b[2J") == null);
                try std.testing.expect(std.mem.find(u8, ui.frame[0..ui.frame_clear_end], "\x1b[0J") == null);
                try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r"));
                try std.testing.expect(std.mem.find(u8, ui.frame[0..ui.frame_clear_end], "\x1b[2J") == null);
                try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                try ui.parser.feed("\x1b", sink);
                try ui.parser.expireEscape(sink);
                try ui.parser.feed("\x15", sink);
                try ui.draw();
                try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                // Closing revokes the popup rows. Rows that lived only inside the
                // revoked overlay are not regenerated, but nothing is duplicated.
                for (0..history_length) |i| {
                    var marker: [16]u8 = undefined;
                    const value = try std.fmt.bufPrint(&marker, "row-{d:0>3}", .{i});
                    try std.testing.expect(screen.count(value) <= 1);
                }
                try std.testing.expect(screen.count("new-row") <= 1);
                // Pre-ABA overlay pixels are terminal-managed now and may survive
                // outside our ownership. Only the freshly ACKed tail is ours to
                // claim: locate it from the real cursor and tail geometry instead
                // of scanning the whole grid, and require no candidate inside it.
                const tail_bottom = screen.row + ui.tail_cursor_rows_up;
                try std.testing.expect(ui.tail_height != 0 and tail_bottom == screen.rows - 1);
                try std.testing.expect(tail_bottom + 1 >= ui.tail_height);
                const tail_top = tail_bottom + 1 - ui.tail_height;
                try std.testing.expect(tail_top <= screen.row);
                // An empty composer is not a menu candidate. Below 12 columns
                // presentation.prompt suppresses the model label, so the live
                // composer legitimately renders a plain "> " prompt. Derive
                // that prompt here rather than skipping composer-shaped rows:
                // the exemption below is exactly one cursor row, and every
                // other owned "> ..." row must still be rejected.
                const state_after = ui.connection.current();
                const narrow_prompt = try presentation.prompt(std.testing.allocator, state_after.model, null, dimensions.columns - 1, .{});
                defer narrow_prompt.deinit(std.testing.allocator);
                const plain_prompt = dimensions.columns < 12;
                if (plain_prompt) {
                    try std.testing.expectEqualStrings("> ", narrow_prompt.plain);
                } else {
                    // Wide layouts keep the model label, so the exemption is
                    // unreachable and a "> "-shaped row would still fail.
                    try std.testing.expect(!std.mem.startsWith(u8, narrow_prompt.plain, "> "));
                }
                try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
                for (tail_top..tail_bottom + 1) |owned| {
                    if (!std.mem.startsWith(u8, &screen.grid[owned], "> ")) continue;
                    // Sole permitted case: the actual cursor row holding the
                    // empty plain-"> " composer, text trimmed to ">", with the
                    // cursor resting exactly after the two-glyph prompt.
                    try std.testing.expect(plain_prompt);
                    try std.testing.expectEqual(screen.row, owned);
                    try std.testing.expectEqualStrings(">", std.mem.trim(u8, &screen.grid[owned], " "));
                    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
                    try std.testing.expectEqual(@as(usize, 2), screen.col);
                }
                try ui.parser.feed(command, sink);
                try ui.draw();
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
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
                testAcknowledgeFullFrame(&ui);
                try std.testing.expect(ui.tail_bottom and ui.tail_height != 0);
                try std.testing.expectEqual(resized.rows - 1, screen.row + ui.tail_cursor_rows_up);
                try std.testing.expectEqual(resized, ui.tail_size);
                const resized_menu_height = ui.tail_height;
                try ui.parser.feed("\x1b", sink);
                try ui.parser.expireEscape(sink);
                try ui.parser.feed("\x15", sink);
                try ui.draw();
                try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                // After the geometry change only the owned tail is painted at the
                // new width; completed rows are neither reflowed nor replayed and
                // never duplicated.
                for (0..history_length) |i| {
                    var marker: [16]u8 = undefined;
                    const value = try std.fmt.bufPrint(&marker, "row-{d:0>3}", .{i});
                    try std.testing.expect(screen.count(value) <= 1);
                }
                try std.testing.expect(screen.count("new-row") <= 1);
                // The ACKed overlay footprint remains owned after an empty close;
                // only its current composer row and legitimate footer hint may contain text.
                try std.testing.expectEqual(resized_menu_height, ui.tail_height);
                try std.testing.expect(ui.tail_snapshot != null);
                try std.testing.expectEqual(resized, ui.tail_size);
                const resized_bottom = screen.row + ui.tail_cursor_rows_up;
                try std.testing.expectEqual(resized.rows - 1, resized_bottom);
                try std.testing.expect(resized_bottom + 1 >= ui.tail_height);
                const resized_top = resized_bottom + 1 - ui.tail_height;
                try std.testing.expect(screen.row >= resized_top and screen.row <= resized_bottom);
                try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const expected_hint = try ui.footerHint(arena.allocator(), ui.connection.current());
                try std.testing.expect(expected_hint.len != 0);
                try std.testing.expect(std.mem.indexOfScalar(u8, expected_hint, '\n') == null);
                try std.testing.expectEqual(@as(usize, 1), ui.tail_composer_rows);
                const cols = @max(1, resized.columns - 1);
                const expected_hint_prefix = expected_hint[0..text.fitBytes(expected_hint, cols)];
                for (resized_top..resized_bottom + 1) |owned| {
                    if (owned == screen.row) continue;
                    if (expected_hint.len != 0 and owned == resized_bottom - 1) {
                        try std.testing.expectEqualStrings(std.mem.trim(u8, expected_hint_prefix, " "), std.mem.trim(u8, &screen.grid[owned], " "));
                    } else {
                        try std.testing.expectEqualStrings("", std.mem.trim(u8, &screen.grid[owned], " "));
                    }
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
    testAcknowledgeFullFrame(&ui);
    ui.resize(.{ .columns = 7, .rows = 6 });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.model_picker == null and !ui.secret_mode);
}

test "reasoning window grows below the committed user row and never borrows it" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 80, .rows = 24 };
    // A small bottom-anchored tail: the committed user row is directly above it.
    _ = try ui.add(.user, "stream-task");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const tail_before = ui.tail_height;
    try std.testing.expect(tail_before != 0 and tail_before < 6);
    try std.testing.expectEqual(screen.rows - ui.tail_height, ui.menu_history.?.above.len);
    try std.testing.expect(std.mem.indexOf(u8, ui.menu_history.?.above[ui.menu_history.?.above.len - 1], "stream-task") != null);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-task"));
    const history_before = screen.history_len;
    try ui.appendDraft(.reasoning, "think-one\nthink-two\nthink-three\nthink-four");
    try ui.draw();
    try screen.replay(ui.frame);
    // The window is one leading gap plus its last three rows, grown downward
    // under the committed user row instead of borrowed upward over it.
    try std.testing.expectEqual(tail_before + 1 + 3, ui.frame_height);
    try std.testing.expect(!screen.visible("think-one"));
    for ([_][]const u8{ "think-two", "think-three", "think-four" }) |marker|
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-task"));
    try expectTranscriptGap(&screen, "stream-task", "think-two");
    try std.testing.expect(screen.visible("stream-task"));
    try std.testing.expectEqual(history_before + 4, screen.history_len);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
    const window_rows = ui.tail_height;
    // A later reasoning update repaints only those same three rows.
    try ui.appendDraft(.reasoning, "\nthink-five\nthink-six");
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(window_rows, ui.frame_height);
    try std.testing.expect(!screen.visible("think-two"));
    for ([_][]const u8{ "think-four", "think-five", "think-six" }) |marker|
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-task"));
    try expectTranscriptGap(&screen, "stream-task", "think-four");
    try std.testing.expectEqual(history_before + 4, screen.history_len);
    testAcknowledgeFullFrame(&ui);
    // The canonical answer replaces the window; the user row is not replayed.
    try ui.appendDraft(.assistant, "final-answer");
    try std.testing.expect(ui.reasoning == null);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 0), screen.count("think-"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-task"));
    try std.testing.expect(screen.visible("final-answer"));
    testAcknowledgeFullFrame(&ui);
}

test "busy stop modal during reasoning restores the borrowed user row and window" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 80, .rows = 24 };
    _ = try ui.add(.user, "stream-task");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const tail_before = ui.tail_height;
    try std.testing.expect(tail_before != 0 and tail_before < 6);
    // Reasoning starts, then the busy stop confirmation borrows the one ACKed
    // row above the small tail while the window itself stays deferred behind it.
    try ui.appendDraft(.reasoning, "think-one\nthink-two\nthink-three\nthink-four");
    ui.busy = true;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x03", sink);
    try std.testing.expect(ui.stop_open);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.menu_history.?.borrowed.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, ui.menu_history.?.borrowed[ui.menu_history.?.borrowed.len - 1], "stream-task") != null);
    try std.testing.expectEqual(@as(usize, 0), screen.count("stream-task"));
    const modal_history = screen.history_len;
    // Closing the modal must not keep ignoring that borrowed prefix: the user
    // row returns to its original row before the window resumes.
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.stop_open);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-task"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "think-") == null);
    try std.testing.expectEqual(modal_history, screen.history_len);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
    try std.testing.expect(ui.tail_height >= tail_before);
    const restored_height = ui.tail_height;
    // The next frame updates the same three-row window below that row.
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(tail_before + 1 + 3, ui.frame_height);
    try std.testing.expect(!screen.visible("think-one"));
    for ([_][]const u8{ "stream-task", "think-two", "think-three", "think-four" }) |marker|
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
    try expectTranscriptGap(&screen, "stream-task", "think-two");
    try std.testing.expect(screen.visible("stream-task"));
    try std.testing.expectEqual(modal_history + (ui.frame_height -| restored_height), screen.history_len);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
}

test "resized reasoning frame revokes the old ACK without autonomous recovery" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 80, .rows = 24 };
    // Height-only shrink: the top `overflow` rows leave the viewport into native
    // history, the remaining rows move up, rows beyond the new logical height are
    // cleared, and the cursor drops by the same amount. Not a reflow model.
    const Shrink = struct {
        fn apply(target: *@import("../tests/regular_screen.zig").Screen, new_rows: usize) !void {
            const old_rows = target.rows;
            if (new_rows == 0 or new_rows >= old_rows or old_rows > target.grid.len) return;
            const overflow = old_rows - new_rows;
            if (target.history_len + overflow > target.history.len) return error.ScrollbackLimit;
            for (0..overflow) |i| target.history[target.history_len + i] = target.grid[i];
            target.history_len += overflow;
            for (0..new_rows) |row_index| target.grid[row_index] = target.grid[row_index + overflow];
            for (new_rows..target.grid.len) |row_index| target.grid[row_index] = @splat(' ');
            target.row -|= overflow;
            target.wrap = false;
            target.rows = new_rows;
        }
    };
    const markers = [_][]const u8{ "canon-c10", "canon-c11", "canon-c12", "canon-c13", "think-B" };
    // Tail footprint is content-derived: the three visible reasoning rows, their
    // leading gap, and the owned notice/separator/composer footer.
    const thinking_rows = 3;
    const thinking_gap = 1;
    const footer_rows = 3;
    const reasoning_footprint = thinking_rows + thinking_gap + footer_rows;
    try seedCompactAckedTail(&ui, &screen);
    try ui.appendDraft(.reasoning, "think-A\nthink-B\nthink-C");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    for (markers) |marker| try std.testing.expect(screen.count(marker) <= 1);
    // Partial geometry (same width, unknown height) grants no upward ownership.
    ui.tail_size = .{ .columns = ui.size.columns, .rows = ui.size.rows + 1 };
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "think-") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    for (markers) |marker| try std.testing.expect(screen.count(marker) <= 1);
    const records_before = ui.records.items.len;
    // Height-only resize invalidates every old ACKed geometry.
    ui.resize(.{ .columns = 80, .rows = 18 });
    try Shrink.apply(&screen, 18);
    // Resize is not content: no timer and no animation pulse may stage a frame.
    ui.clock_ms += 5000;
    ui.resize(.{ .columns = 80, .rows = 18 });
    ui.animate();
    try std.testing.expect(!ui.drawReady() and !ui.dirty and ui.frame.len == 0);
    try std.testing.expect(ui.tail_snapshot == null and !ui.tail_bottom and ui.abandon_tail);
    try std.testing.expectEqual(@as(usize, 18), ui.size.rows);
    // The next genuine update establishes a bounded bottom anchor without
    // clearing the screen or reclaiming old coordinates.
    ui.requestDraw();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[999B") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[0J") == null);
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[18B"));
    // The bounded reasoning window carries its visible rows only; completed
    // canonical rows are neither reflowed nor replayed at the new width.
    try std.testing.expectEqual(reasoning_footprint, ui.frame_height);
    try std.testing.expect(std.mem.find(u8, ui.frame, "canon-c") == null);
    try screen.replay(ui.frame);
    // Old visible previews may remain after an interrupted geometry; they are
    // discarded display state, not a duplicate canonical record. No zero-ghost
    // or unique-viewport requirement survives the resize any more.
    try std.testing.expectEqual(records_before, ui.records.items.len);
    for (ui.records.items) |record| {
        if (record.kind == .reasoning) continue;
        try std.testing.expect(record.output);
    }
    // Freeze what that single frame produced; stability means no further
    // appends or duplicate rows, not that history matches the pre-resize state.
    var recovered: [markers.len]usize = undefined;
    for (markers, 0..) |marker, index| recovered[index] = screen.count(marker);
    const recovered_history = screen.history_len;
    testAcknowledgeFullFrame(&ui);
    // The fresh tail borrowed no unknown or old-width row.
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
    // The next stable frame keeps the same content-derived footprint without
    // replaying canonical rows.
    try ui.draw();
    try std.testing.expectEqual(reasoning_footprint, ui.frame_height);
    try screen.replay(ui.frame);
    for (markers, 0..) |marker, index| {
        try std.testing.expectEqual(recovered[index], screen.count(marker));
    }
    try std.testing.expectEqual(recovered_history, screen.history_len);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
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
    testAcknowledgeFullFrame(&ui);
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
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try ui.draw();
    ui.resize(.{ .columns = 40, .rows = 12 });
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
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
    try std.testing.expectEqualStrings("/model pasted-id", ui.editor.bytes.items);
    try ui.parser.feed("\x15/model fixture-next\r", sink);
    try std.testing.expectEqualStrings("fixture-next", fixture.name);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(shared.ReasoningEffort.minimal, fixture.effort);
    // 切换档位后，输入框百分比位置短暂显示新档位名。
    try ui.draw();
    var effort_screen: @import("../tests/regular_screen.zig").Screen = .{};
    try effort_screen.replay(ui.frame);
    try std.testing.expect(effort_screen.visible("(fixture-next) minimal> "));
    testAcknowledgeFullFrame(&ui);
    // 2 秒后自动恢复为上下文百分比。
    ui.clock_ms = 2001;
    ui.expireEffortFlash();
    try ui.draw();
    try effort_screen.replay(ui.frame);
    try std.testing.expect(effort_screen.visible("(fixture-next) 1.5%> "));
    testAcknowledgeFullFrame(&ui);
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
        try std.testing.expectEqual(shared.ReasoningEffort.off, fixture.effort);
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

test "exit requires parsed quit or captured signal provenance" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.want_exit = true;
    try std.testing.expect(!ui.exitAuthorized());
    try std.testing.expect(ui.settingsIdle());
    ui.requestQuit();
    try std.testing.expect(ui.exitAuthorized());
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
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
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
    testAcknowledgeFullFrame(&ui);
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
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
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
        ui.ctrl_d_exit = case == 5;
        try ui.submit();
        try std.testing.expect(ui.future == null and ui.prompt == null);
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
        ui.busy = false;
        ui.poisoned = false;
        ui.want_exit = false;
        ui.ctrl_d_exit = false;
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
        try std.testing.expectEqualStrings(if (case == 0) "Only ordinary conversation text can be queued" else "Compaction requires an idle, non-pasted session", ui.notice);
        if (case == 0) try std.testing.expectEqualStrings("/compact", ui.editor.bytes.items);
        ui.wipeEditor();
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
        try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], case.shown) != null);
        if (case.hidden) |hidden| {
            try std.testing.expect(std.mem.find(u8, ui.frame, hidden) == null);
            try std.testing.expectEqual(@as(usize, 0), screen.count(hidden));
        }
        if (!std.mem.startsWith(u8, case.raw, "/login")) {
            try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], "/login") == null);
        }
        try std.testing.expectEqualStrings(case.raw, ui.editor.bytes.items);
        testAcknowledgeFullFrame(&ui);
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("\r", sink);
        try std.testing.expect(!ui.secret_mode and !ui.provider_open);
        try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
    }
}

test "slash composer keeps supported management arguments visible without submitting" {
    try text.initLocale();
    const cases = [_]struct { raw: []const u8, shown: []const u8, hidden: ?[]const u8 = null }{
        .{ .raw = "/attach 0123456789abcdef0123456789abcdef", .shown = "/attach 0123456789abcdef0123456789abcdef" },
        .{ .raw = "/attach --takeover 0123456789abcdef0123456789abcdef", .shown = "/attach --takeover 0123456789abcdef0123456789abcdef" },
        .{ .raw = "/attch 0123456789abcdef0123456789abcdef", .shown = "/attch 0123456789abcdef0123456789abcdef" },
        .{ .raw = "/close 0123456789abcdef0123456789abcdef --force", .shown = "/close 0123456789abcdef0123456789abcdef --force" },
        .{ .raw = "/cd /srv/work dir", .shown = "/cd /srv/work dir" },
        .{ .raw = "/ls --running --page 2", .shown = "/ls --running --page 2" },
        .{ .raw = "/ls 2", .shown = "/ls 2" },
        .{ .raw = "/ls ", .shown = "/ls " },
        .{ .raw = "/detach   ", .shown = "/detach   " },
        .{ .raw = "/login ", .shown = "/login " },
        .{ .raw = "/compact\t", .shown = "/compact    " },
        .{ .raw = "/attach bad!id extra", .shown = "/ [command arguments hidden]", .hidden = "bad!id" },
        .{ .raw = "/ls --page", .shown = "/ [command arguments hidden]", .hidden = "--page" },
        .{ .raw = "/login fakecredential", .shown = "/login [arguments hidden; no key argument]", .hidden = "fakecredential" },
        .{ .raw = "/unknown fakecredential", .shown = "/ [command arguments hidden]", .hidden = "fakecredential" },
        .{ .raw = "/model one two", .shown = "/model [arguments hidden; use one model ID]", .hidden = "one two" },
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
        _ = try ui.editor.insert(case.raw);
        try ui.draw();
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay(ui.frame);
        try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], case.shown) != null);
        if (case.hidden) |hidden| {
            try std.testing.expect(std.mem.find(u8, ui.frame, hidden) == null);
            try std.testing.expectEqual(@as(usize, 0), screen.count(hidden));
        }
        // Drawing only: no command may run from a composer frame.
        try std.testing.expectEqualStrings(case.raw, ui.editor.bytes.items);
        try std.testing.expect(!ui.secret_mode and !ui.provider_open and ui.future == null and !ui.busy);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
        discardFixtureFrame(&ui);
    }
}

test "settings proxy submenu toggles one acknowledged row and keeps parent draft" {
    try text.initLocale();
    const models = [_]core_config.Model{
        .{ .name = "fixture/one", .context_tokens = 32768 },
        // Native protocol and unknown capacity remain selectable.
        .{ .name = "fixture/two", .protocol = .systemone, .context_tokens = 0 },
        .{ .name = "unlogged/three", .context_tokens = 32768 },
    };
    var fixture: SelectionFixture = .{ .profiles_override = &models, .proxy_configured = true, .proxy_address = "10.0.0.1", .proxy_port = 8080 };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 8;
    // Settings-root draft: the child must never destroy it.
    _ = try ui.editor.insert("draft");
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Proxy") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Proxy models") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "10.0.0.1:8080") != null);
    testAcknowledgeFullFrame(&ui);
    // Root Enter opens the second level; Address stays selected by default.
    try ui.parser.feed("\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expect(ui.proxy_sub_open and !ui.proxy_open and !ui.proxy_address_open);
    try std.testing.expect(!ui.decision_open and !ui.image_open);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "> Address") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "10.0.0.1:8080") != null);
    testAcknowledgeFullFrame(&ui);
    // Down reaches Models, which opens the existing acknowledged picker.
    try ui.parser.feed("\x1b[B", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expect(ui.proxy_open and ui.proxy_sub_open and !ui.proxy_address_open);
    try std.testing.expect(!ui.decision_open and !ui.image_open);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "[ ] fixture/one") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "unlogged/three") == null);
    testAcknowledgeFullFrame(&ui);
    // One ACKed Enter saves exactly one model; the same batch cannot flip twice.
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/one", fixture.proxy_last.?);
    try std.testing.expect(fixture.proxy_last_enabled);
    try std.testing.expect(publishedNotice(&ui, "Saved proxy models"));
    try std.testing.expect(publishedNotice(&ui, "new session"));
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "[x] fixture/one") != null);
    testAcknowledgeFullFrame(&ui);
    // A second model can be toggled without leaving the submenu.
    try ui.parser.feed("\x1b[B", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/two", fixture.proxy_last.?);
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_len);
    // Owner save failure keeps the checkbox and the query, and still consumes ACK.
    fixture.proxy_fail = true;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 3), fixture.proxy_saves);
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_len);
    try std.testing.expect(std.mem.find(u8, ui.notice, "previous value kept") != null);
    try std.testing.expect(ui.proxy_open);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 3), fixture.proxy_saves);
    fixture.proxy_fail = false;
    // Search keeps the exact case and inner slashes of the saved name.
    try ui.settingsKey(.{ .text = .{ .value = "TWO", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 4), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/two", fixture.proxy_last.?);
    try std.testing.expect(!fixture.proxy_last_enabled);
    // Esc from the picker lands on the Models row and restores the parent draft.
    try ui.settingsKey(.escape);
    try std.testing.expect(!ui.proxy_open and ui.proxy_sub_open and ui.settings_open);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    try std.testing.expectEqualStrings("draft", ui.editor.bytes.items);
    // Esc from the second level returns to the root Proxy row, draft intact.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.escape);
    try std.testing.expect(!ui.proxy_sub_open and !ui.proxy_address_open and ui.settings_open);
    try std.testing.expectEqual(@as(usize, 8), ui.settings_menu.selected);
    try std.testing.expectEqualStrings("draft", ui.editor.bytes.items);
}

test "proxy picker owns its query while the parent submenu stays marked" {
    try text.initLocale();
    const models = [_]core_config.Model{
        .{ .name = "fixture/one", .context_tokens = 32768 },
        .{ .name = "fixture/two", .context_tokens = 32768 },
    };
    var fixture: SelectionFixture = .{ .profiles_override = &models, .proxy_configured = true, .proxy_address = "10.0.0.1", .proxy_port = 8080 };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 8;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try ui.settingsKey(.down);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // Models opens the picker while the parent marker stays set.
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_open and ui.proxy_sub_open and !ui.proxy_address_open);
    // The query reaches the picker editor and filters its rows.
    try ui.settingsKey(.{ .text = .{ .value = "two", .pasted = false } });
    try std.testing.expectEqualStrings("two", ui.editor.bytes.items);
    try std.testing.expect(ui.proxy_open and ui.proxy_sub_open);
    try std.testing.expectEqual(@as(usize, 1), proxy_picker_module.count(SelectionFixture.current(&fixture).models, SelectionFixture.current(&fixture).model_providers, ui.editor.bytes.items));
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "[ ] fixture/two") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fixture/one") == null);
    testAcknowledgeFullFrame(&ui);
    // A complete ACKed Enter toggles the filtered row instead of Address.
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/two", fixture.proxy_last.?);
    try std.testing.expect(fixture.proxy_last_enabled);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(ui.proxy_open and !ui.proxy_address_open);
    try std.testing.expectEqualStrings("two", ui.editor.bytes.items);
    try std.testing.expect(publishedNotice(&ui, "Saved proxy models"));
    // Esc still returns to the parent Models row, keeping the submenu.
    try ui.settingsKey(.escape);
    try std.testing.expect(!ui.proxy_open and ui.proxy_sub_open and !ui.proxy_address_open and ui.settings_open);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
}

test "settings proxy submenu reports a missing endpoint instead of stalling" {
    try text.initLocale();
    const models = [_]core_config.Model{.{ .name = "fixture/one", .context_tokens = 32768 }};
    var fixture: SelectionFixture = .{ .profiles_override = &models };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 8;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_sub_open and !ui.proxy_open);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Not configured") != null);
    testAcknowledgeFullFrame(&ui);
    // Models opens without an endpoint and states the blocker up front.
    try ui.parser.feed("\x1b[B", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_open);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Configure a proxy address first") != null);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "not configured") != null);
    testAcknowledgeFullFrame(&ui);
    // An acknowledged Enter still refuses to guess an endpoint or save a model.
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Configure a proxy address first") != null);
    try std.testing.expect(ui.proxy_open);
    // Address opens with an empty prefill and an invalid value never lands.
    try ui.settingsKey(.escape);
    try ui.settingsKey(.up);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open and ui.proxy_sub_open and !ui.proxy_open);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Address> ") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.{ .text = .{ .value = "fixture", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Invalid proxy address") != null);
    try std.testing.expect(ui.proxy_address_open and !fixture.proxy_configured);
    try std.testing.expect(ui.input_history.entries.items.len == 0);
    // The owner guard also refuses directly once settings became unavailable.
    const saves = fixture.proxy_address_saves;
    ui.saveProxyAddress(.{ .runtime = null, .model = "", .base_url = "", .global_settings_available = false });
    try std.testing.expectEqual(saves, fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Global settings unavailable") != null);
    try std.testing.expect(ui.proxy_address_open);
}

test "proxy address enables model toggles and empty removes proxy configuration" {
    try text.initLocale();
    const models = [_]core_config.Model{.{ .name = "fixture/one", .context_tokens = 32768 }};
    var fixture: SelectionFixture = .{ .profiles_override = &models };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 8;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // Root 8 -> second level -> Address, prefilled empty when nothing is set.
    try ui.settingsKey(.enter);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open and ui.editor.bytes.items.len == 0);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("127.0.0.1:8888", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings("127.0.0.1:8888", fixture.proxy_endpoint[0..fixture.proxy_endpoint_len]);
    try std.testing.expectEqualStrings("127.0.0.1", fixture.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 8888), fixture.proxy_port);
    try std.testing.expect(fixture.proxy_configured);
    // A saved address returns to the second level, never to the editor.
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open and !ui.proxy_open);
    try std.testing.expectEqual(@as(usize, 0), ui.settings_menu.selected);
    try std.testing.expect(publishedNotice(&ui, "Saved proxy address"));
    try std.testing.expect(publishedNotice(&ui, "new session"));
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "127.0.0.1:8888") != null);
    testAcknowledgeFullFrame(&ui);
    // Models now accepts one acknowledged toggle.
    try ui.settingsKey(.down);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/one", fixture.proxy_last.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_len);
    // Changing the address keeps the existing members.
    try ui.settingsKey(.escape);
    try ui.settingsKey(.up);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqualStrings("127.0.0.1:8888", ui.editor.bytes.items);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.clear);
    try ui.settingsKey(.{ .text = .{ .value = "10.0.0.1:3128", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings("10.0.0.1", fixture.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 3128), fixture.proxy_port);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_len);
    // Empty input removes the whole proxy through the same callback, dropping
    // the member list as the backend does; nothing survives the disable.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open);
    try std.testing.expectEqualStrings("10.0.0.1:3128", ui.editor.bytes.items);
    try ui.settingsKey(.clear);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 3), fixture.proxy_address_saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_endpoint_len);
    try std.testing.expect(fixture.proxy_address == null and fixture.proxy_port == 0);
    try std.testing.expect(!fixture.proxy_configured);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_len);
    try std.testing.expectEqual(@as(usize, 0), SelectionFixture.current(&fixture).proxy_models.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try std.testing.expect(publishedNotice(&ui, "Empty disables proxy"));
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open);
}

test "proxy address saves only when the endpoint fits the reserved columns" {
    try text.initLocale();
    const models = [_]core_config.Model{.{ .name = "fixture/one", .context_tokens = 32768 }};
    var fixture: SelectionFixture = .{ .profiles_override = &models };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 8;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open);
    // 63+1+2 host plus ":8888" is 71 bytes; with the 9-byte prompt it needs
    // exactly the 80 reserved columns of an 81-column terminal.
    const endpoint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aa:8888";
    try std.testing.expectEqual(@as(usize, 71), endpoint.len);
    try ui.parser.feed(endpoint, input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // At 80 columns the row keeps one spare column, so the text is not fully
    // visible: the save is refused with a reason instead of silently failing.
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Resize") != null);
    try std.testing.expect(ui.proxy_address_open);
    // One wider column authorizes the same text after a fresh complete frame.
    ui.resize(.{ .columns = 81, .rows = 24 });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings(endpoint, fixture.proxy_endpoint[0..fixture.proxy_endpoint_len]);
    try std.testing.expectEqual(@as(usize, 66), fixture.proxy_address.?.len);
    try std.testing.expectEqual(@as(u16, 8888), fixture.proxy_port);
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open);
}

test "proxy address refuses invalid, canceled, pasted and unacknowledged saves" {
    try text.initLocale();
    const models = [_]core_config.Model{.{ .name = "fixture/one", .context_tokens = 32768 }};
    var fixture: SelectionFixture = .{ .profiles_override = &models, .proxy_configured = true, .proxy_address = "10.0.0.1", .proxy_port = 8080 };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 8;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open);
    try std.testing.expectEqualStrings("10.0.0.1:8080", ui.editor.bytes.items);
    // An invalid endpoint is refused explicitly and never lands.
    try ui.settingsKey(.clear);
    try ui.settingsKey(.{ .text = .{ .value = "10.0.0.1:0", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Invalid proxy address") != null);
    try std.testing.expectEqualStrings("10.0.0.1", fixture.proxy_address.?);
    try std.testing.expect(ui.proxy_address_open);
    // Esc cancels without writing and the saved endpoint is still shown.
    try ui.settingsKey(.escape);
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "10.0.0.1:8080") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqualStrings("10.0.0.1:8080", ui.editor.bytes.items);
    // Text and Enter in one read batch cannot save: the edit revoked the ACK.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("9\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(ui.proxy_address_open);
    // Pasting only edits the buffer; the same batch Enter is refused too.
    try ui.settingsKey(.clear);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~10.0.0.9:3128\x1b[201~\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqualStrings("10.0.0.9:3128", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "pasted") != null);
    try std.testing.expect(ui.proxy_address_open);
    // An owner save failure keeps the previous endpoint and consumes the ACK.
    // The paste batch taints Enter for the rest of its read, so the attempt
    // arrives as a fresh read of its own after a complete frame.
    fixture.proxy_address_fail = true;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings("10.0.0.1", fixture.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 8080), fixture.proxy_port);
    try std.testing.expect(std.mem.find(u8, ui.notice, "previous value kept") != null);
    try std.testing.expect(ui.proxy_address_open);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_address_saves);
    fixture.proxy_address_fail = false;
    // A fresh complete frame after the same edit does save it, and the retry
    // is again a new read rather than a byte of the previous one.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings("10.0.0.9", fixture.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 3128), fixture.proxy_port);
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open);
}
test "remote history replay seeds input history without touching the editor" {
    try text.initLocale();
    const a = std.testing.allocator;
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 5 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try typeDraft(&ui, "my draft");
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 1, .text = "first" } });
    fake.item.?.history_replay = true;
    fake.item.?.history_reset = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("first", ui.input_history.entries.items[0]);
    try std.testing.expectEqualStrings("my draft", ui.editor.bytes.items);
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 2, .text = "second" } });
    fake.item.?.history_replay = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("second", ui.input_history.entries.items[1]);
    // Live and queued events carry no replay marker and never duplicate history.
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 3, .text = "live" } });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    // Truncated, incomplete, blank and slash-replayed text is skipped.
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 4, .text = "truncated" } });
    fake.item.?.history_replay = true;
    fake.item.?.display_truncated = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 5, .text = "incomplete" } });
    fake.item.?.history_replay = true;
    fake.item.?.canonical_complete = false;
    try ui.pumpRemote();
    try drainBridge(&ui);
    for ([_][]const u8{ "   ", "  /secret command" }) |skipped| {
        fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 6, .text = skipped } });
        fake.item.?.history_replay = true;
        try ui.pumpRemote();
        try drainBridge(&ui);
    }
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    // Up/Down browse the replayed prompts and restore the unsent draft.
    ui.editor.cursor = 0;
    try Ui.key(&ui, .up);
    try std.testing.expectEqualStrings("second", ui.editor.bytes.items);
    try Ui.key(&ui, .down);
    try std.testing.expectEqualStrings("my draft", ui.editor.bytes.items);
    // A stale epoch item is discarded by the poll epoch check before any reset.
    fake.snapshot.control_epoch = 6;
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 7, .text = "stale" } });
    fake.item.?.history_replay = true;
    fake.item.?.history_reset = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
}

test "remote history reset while browsing returns the unsent draft to the editor" {
    try text.initLocale();
    const a = std.testing.allocator;
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 5 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for ([_][]const u8{ "old-one", "old-two" }) |message|
        ui.input_history.commit(a, try ui.input_history.prepare(a, message));
    try typeDraft(&ui, "unsent draft");
    ui.editor_pasted = true;
    // Browsing only starts at the exact raw origin, so the parked draft carries
    // cursor 0 and its pasted provenance; Up then shows the newest prompt.
    ui.editor.cursor = 0;
    try Ui.key(&ui, .up);
    try std.testing.expectEqualStrings("old-two", ui.editor.bytes.items);
    try std.testing.expect(ui.input_history.index != null and ui.history_draft != null and ui.history_draft_pasted);
    const parked = ui.history_draft.?.bytes.items.ptr;
    const parked_cursor = ui.history_draft.?.cursor;
    // A same-epoch replay reset replaces the list instead of dropping the form.
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 9, .text = "replayed" } });
    fake.item.?.history_replay = true;
    fake.item.?.history_reset = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("replayed", ui.input_history.entries.items[0]);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    try std.testing.expectEqual(parked_cursor, ui.editor.cursor);
    try std.testing.expectEqual(parked, ui.editor.bytes.items.ptr); // moved owner, no copy
    try std.testing.expect(ui.editor_pasted);
    try std.testing.expect(ui.input_history.index == null and ui.history_draft == null and !ui.history_draft_pasted);
    // Down from the restored origin is not browsing: nothing is lost.
    try Ui.key(&ui, .down);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    try std.testing.expectEqual(parked, ui.editor.bytes.items.ptr);
    try std.testing.expect(ui.editor_pasted and ui.history_draft == null and ui.input_history.index == null);
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

fn pasteTailEscapeRegression(parts: []const []const u8, reset_before_timeout: bool) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const id = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "pending followup");
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    for (parts) |part| try ui.parser.feed(part, sink);
    try std.testing.expect(!ui.parser.pasted and ui.parser.escape_len == 1);
    if (reset_before_timeout) try ui.parser.feed("", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expectEqual(@as(?u64, id), ui.inbox.snapshot().newest_id);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ui.parser.escape_len);
    // A rejected Escape is consumed, not left to revive on a later read/timer.
    try ui.parser.feed("", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expectEqual(@as(?u64, id), ui.inbox.snapshot().newest_id);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(ui.inbox.snapshot().newest_id == null);
    try std.testing.expectEqualStrings("pending followup", ui.editor.bytes.items);
    try std.testing.expect(!cancel.isRequested());
}

test "regression paste-tail Escape timeout cannot withdraw queued FollowUp" {
    try pasteTailEscapeRegression(&.{"\x1b[200~\x1b[201~\x1b"}, false);
}

test "regression split paste terminator Escape cannot revive after feed resets taint" {
    try pasteTailEscapeRegression(&.{ "\x1b[200~\x1b[20", "1~\x1b" }, true);
}

test "regression delayed paste-tail Escape retains provenance across fresh empty reads" {
    try pasteTailEscapeRegression(&.{"\x1b[200~\x1b[201~\x1b"}, true);
}

test "regression idle Custom Ctrl-C cancels child before parent via parser" {
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 3;
    ui.openSettingsValue(.command_timeout_ms, fixture.state);
    ui.settings_menu.selected = try customPreferenceOption(ui.settings_value_picker.?);
    ui.settings_value_picker.?.beginCustom();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("123.456", sink);
    try std.testing.expect(ui.settings_value_picker.?.editing);
    try std.testing.expectEqualStrings("123.456", ui.settings_value_picker.?.input[0..ui.settings_value_picker.?.input_len]);
    try ui.parser.feed("\x03", sink);
    try std.testing.expect(!ui.settings_value_picker.?.editing);
    try std.testing.expect(ui.settings_open and !ui.stop_open);
    try std.testing.expectEqual(@as(usize, 0), ui.settings_value_picker.?.input_len);
    try ui.parser.feed("\x03", sink);
    try std.testing.expect(ui.settings_value_picker == null and ui.settings_open);
    try std.testing.expectEqual(@as(usize, 3), ui.settings_menu.selected);
    try ui.parser.feed("\x03", sink);
    try std.testing.expect(!ui.settings_open and !ui.stop_open and !cancel.isRequested());
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "regression idle selectors Ctrl-C reaches child modal via parser" {
    for (0..4) |kind| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        switch (kind) {
            0, 1 => {
                ui.openSettingsMenu();
                ui.decision_open = kind == 0;
                ui.image_open = kind == 1;
            },
            2 => ui.openModelPicker(),
            3 => ui.openProviderPicker(),
            else => unreachable,
        }
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        if (kind < 3) try ui.parser.feed("query", sink);
        try ui.parser.feed("\x03", sink);
        try std.testing.expect(!ui.settingsModelOpen() and ui.model_picker == null and !ui.provider_open);
        if (kind < 2) {
            try std.testing.expect(ui.settings_open);
            try std.testing.expectEqual(@as(usize, if (kind == 0) 1 else 6), ui.settings_menu.selected);
            try std.testing.expectEqualStrings("", ui.editor.bytes.items);
        }
        try std.testing.expect(!ui.stop_open and !cancel.isRequested());
    }
}

test "regression Ctrl-C still confirms busy or pending queue and keeps idle composer" {
    for (0..3) |kind| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.busy = kind == 0;
        if (kind == 1) {
            _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "pending");
            ui.openSettingsMenu(); // Queue confirmation outranks the idle modal.
        }
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        if (kind != 1) try ui.parser.feed("keep draft", sink);
        try ui.parser.feed("\x03", sink);
        try std.testing.expectEqual(kind != 2, ui.stop_open);
        try std.testing.expect(!ui.stop_danger and !cancel.isRequested());
        if (kind != 1) try std.testing.expectEqualStrings("keep draft", ui.editor.bytes.items);
        if (kind == 1) try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
    }
}

test "stop clear requires fresh complete ACK and independent dangerous Enter with draft kept" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true; // Undefined fixture Runtime must never be dereferenced.
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "queued steer");
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "queued followup");
    try std.testing.expect(try ui.editor.insert("keep my draft"));
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x03\x1b[C\r", sink);
    try std.testing.expect(ui.stop_open and !ui.stop_danger and !cancel.isRequested());
    try std.testing.expect(ui.inbox.snapshot().confirming);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "> Continue") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[C\r", sink);
    try std.testing.expect(ui.stop_danger and !cancel.isRequested());
    try ui.parser.feed("\r", sink); // No frame yet: no authorization.
    try std.testing.expect(!cancel.isRequested() and !ui.stop_danger);
    try ui.parser.feed("\x1b[C", sink); // Reselect after a pre-ACK/held Enter.
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "> Stop and clear") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\x03", sink);
    try std.testing.expect(cancel.isRequested() and !ui.stop_open);
    try std.testing.expect(ui.inbox.snapshot().newest_id == null);
    try std.testing.expect(ui.inbox.snapshot().paused);
    try std.testing.expectEqualStrings("keep my draft", ui.editor.bytes.items);
}

test "stop modal rejects queue revision resize paste and repeated CtrlC authority" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x03", sink);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "raced message");
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!cancel.isRequested() and !ui.stop_danger);
    try ui.parser.feed("\x1b[C", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resize(.{ .columns = 18, .rows = 7 });
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!cancel.isRequested());
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.displayed_stop == null);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!cancel.isRequested());
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.parser.feed("\x03\r", sink);
    try std.testing.expect(!ui.stop_danger and !cancel.isRequested());
    try ui.parser.feed("\x1b[C", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~\r\x1b[201~\r", sink);
    try std.testing.expect(!cancel.isRequested());
    // The discarded paste tail cannot confirm; fresh Esc solely dismisses.
    ui.parser.pasted = false;
    ui.parser.batch_paste = false;
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.stop_open and !ui.inbox.snapshot().confirming);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
}

test "Escape withdraws exact newest plain text once and preserves existing draft" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "first");
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "newest 中文");
    try Ui.key(&ui, .escape);
    try std.testing.expectEqualStrings("newest 中文", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().steering);
    try Ui.key(&ui, .escape);
    try std.testing.expectEqualStrings("newest 中文", ui.editor.bytes.items);
    try std.testing.expect(!cancel.isRequested());
    ui.wipeEditor();
    try Ui.key(&ui, .escape);
    try std.testing.expectEqualStrings("first", ui.editor.bytes.items);
    try std.testing.expect(!cancel.isRequested());
    ui.wipeEditor();
    try Ui.key(&ui, .cancel); // No real worker, but busy confirmation still safe.
    try Ui.key(&ui, .escape);
    try std.testing.expect(!cancel.isRequested() and !ui.stop_open);
    ui.busy = false;
    try std.testing.expect(try ui.editor.insert("idle draft"));
    try Ui.key(&ui, .cancel);
    try std.testing.expectEqualStrings("idle draft", ui.editor.bytes.items);
}

test "user committed is owned display only and permission cleared matches exact id" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try bridge.host().emit_fn(&bridge, .{ .user_committed = .{ .id = 9, .text = "injected actual text" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expectEqualStrings("injected actual text", ui.records.items[0].body.items);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try bridge.host().emit_fn(&bridge, .{ .permission = .{ .id = 10, .tool_name = "bash", .description = "approval" } }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try bridge.host().emit_fn(&bridge, .{ .permission_cleared = 9 }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expect(ui.permission != null);
    try bridge.host().emit_fn(&bridge, .{ .permission_cleared = 10 }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expect(ui.permission == null);
}

test "ordinary submission preserves draft and pending queue after owner change" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var old_runtime: r.Runtime = undefined;
    var new_runtime: r.Runtime = undefined;
    var fixture = AuthFixture{ .configured = true, .runtime = &new_runtime };
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    ui.queue_owner = .{ .runtime = &old_runtime, .session = null };
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "old session pending");
    try std.testing.expect(try ui.editor.insert("new draft"));
    try Ui.key(&ui, .enter);
    try std.testing.expectEqualStrings("new draft", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
    try std.testing.expect(ui.inbox.snapshot().paused);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try std.testing.expect(!ui.busy and ui.future == null and !ui.want_exit);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Ctrl-C") != null);
    ui.inbox.pauseClaims(true);
    try std.testing.expect(ui.inbox.cancelClear(ui.inbox.snapshot().revision, &cancel));
    try std.testing.expect(ui.queueOwnerMatches());
}

test "queued launch waits for joined success preserves draft and restores OOM without duplicate history" {
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{ .configured = true };
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    try std.testing.expect(try ui.editor.insert("first prompt"));
    try ui.submit();
    try std.testing.expect(runtime.inbox == &ui.inbox);
    try std.testing.expect(try ui.editor.insert("followup prompt"));
    try Ui.key(&ui, .follow_up);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
    try std.testing.expect(try ui.editor.insert("unfinished draft"));
    try ui.dispatchNext();
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try ui.complete();
    try std.testing.expect(runtime.inbox == null and ui.attached_runtime == null);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ui.allocator = failing.allocator();
    try ui.dispatchNext();
    ui.allocator = std.testing.allocator;
    try std.testing.expect(!ui.busy and ui.future == null);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
    try std.testing.expect(ui.inbox.snapshot().paused);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("unfinished draft", ui.editor.bytes.items);
    // A normal submission must not silently resume the queue. Explicit resume
    // is tested here at the Inbox seam, without sending /queue to the model.
    ui.inbox.@"resume"();
    try ui.dispatchNext();
    try std.testing.expectEqualStrings("unfinished draft", ui.editor.bytes.items);
    try std.testing.expectEqualStrings("followup prompt", ui.prompt.?);
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), ui.inbox.snapshot().follow_up);
    try std.testing.expect(runtime.inbox == null);
}

test "configure enables same-process submit without sending secrets or commands" {
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{};
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
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
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expect(publishedNotice(&ui, "Saved locally; send a message to connect"));
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Saved locally; send a message to connect") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Esc closes") == null);
    try std.testing.expect(!ui.secret_mode and !ui.secret_quarantine);
    try std.testing.expect(std.mem.find(u8, ui.frame, "sk-fixture-secret") == null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), fixture.saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(Kind.notice, ui.records.items[0].kind);
    for (ui.secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("/login\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try std.testing.expectEqual(@as(usize, 1), fixture.saves);
    try ui.parser.feed("hello\r", sink);
    try std.testing.expect(ui.busy);
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqualStrings("hello", runtime.messages()[0].blocks[0].text);
    try std.testing.expectEqualStrings("hello", ui.records.items[1].body.items);
    for (ui.records.items) |record| try std.testing.expect(std.mem.find(u8, record.body.items, "sk-fixture-secret") == null);
}

// ---- Remote adapter focused tests -------------------------------------------
// A fake backend proves UI-side ownership rules without sockets, daemon code or
// a real Runtime: the client owns tasks/queues/approvals, and the UI only
// submits, acknowledges and renders.

const FakeRemote = struct {
    snapshot: session_client.Snapshot = .{ .available = true, .attached = true, .control_epoch = 1 },
    /// Owner-published device-login view; display-only, never credentials.
    codex: corecodex.View = .{},
    item: ?session_client.Item = null,
    buffered_items: []session_client.Item = &.{},
    buffered_index: usize = 0,
    empty_polls: usize = 0,
    submits: usize = 0,
    last_submit_epoch: u64 = 0,
    last_submit_kind: session_client.TaskKind = .prompt,
    text: [64]u8 = @splat(0),
    text_len: usize = 0,
    cancels: usize = 0,
    cancel_clears: usize = 0,
    last_cancel_clear_revision: u64 = 0,
    confirmings: usize = 0,
    last_confirming_epoch: u64 = 0,
    last_confirming_active: bool = false,
    last_confirming_revision: u64 = 0,
    detaches: usize = 0,
    approvals: usize = 0,
    last_approve_epoch: u64 = 0,
    last_approve_id: u64 = 0,
    enqueues: usize = 0,
    last_enqueue_epoch: u64 = 0,
    last_enqueue_kind: session_client.QueueKind = .steering,
    resumes: usize = 0,
    manages: usize = 0,
    last_manage: ?std.meta.Tag(session_client.Manage) = null,
    manage_switched: bool = false,
    manage_exit: bool = false,
    submit_failure: ?anyerror = null,
    ack_failure: bool = false,
    ack_count: usize = 0,
    ack_epoch: u64 = 0,
    ack_sequence: u64 = 0,
    /// Exact intervals handed to the selective range channel, in order.
    ack_ranges: [64]struct { first: u64, last: u64 } = @splat(.{ .first = 0, .last = 0 }),
    ack_range_count: usize = 0,
    ack_range_failure: bool = false,
    ack_range_epoch: u64 = 0,

    fn acknowledgeFn(ctx: *anyopaque, epoch: u64, sequence: u64) anyerror!void {
        const self = from(ctx);
        if (self.ack_failure) return error.QueueFull;
        self.ack_count += 1;
        self.ack_epoch = epoch;
        self.ack_sequence = sequence;
    }

    fn acknowledgeRangeFn(ctx: *anyopaque, epoch: u64, first: u64, last: u64) anyerror!void {
        const self = from(ctx);
        // Prefix acks (first == 0) are legacy acknowledge semantics.
        if (first == 0) return acknowledgeFn(ctx, epoch, last);
        if (self.ack_range_failure) return error.QueueFull;
        if (first == 0 or first > last) return error.InvalidSequence;
        self.ack_range_epoch = epoch;
        if (self.ack_range_count < self.ack_ranges.len) {
            self.ack_ranges[self.ack_range_count] = .{ .first = first, .last = last };
            self.ack_range_count += 1;
        }
    }

    fn client(self: *FakeRemote) session_client.Client {
        return .{ .context = self, .vtable = &vtable };
    }

    fn record(self: *FakeRemote, value: []const u8) void {
        self.text_len = @min(value.len, self.text.len);
        @memcpy(self.text[0..self.text_len], value[0..self.text_len]);
    }

    fn from(ctx: *anyopaque) *FakeRemote {
        return @ptrCast(@alignCast(ctx));
    }

    fn snapshotFn(ctx: *anyopaque) *const session_client.Snapshot {
        return &from(ctx).snapshot;
    }
    fn submitFn(ctx: *anyopaque, epoch: u64, kind: session_client.TaskKind, value: []const u8) anyerror!void {
        const self = from(ctx);
        self.submits += 1;
        self.last_submit_epoch = epoch;
        self.last_submit_kind = kind;
        self.record(value);
        if (self.submit_failure) |err| return err;
    }
    fn pollFn(ctx: *anyopaque, _: std.mem.Allocator) anyerror!?session_client.Item {
        const self = from(ctx);
        if (self.item) |value| {
            self.item = null;
            return value;
        }
        if (self.buffered_index < self.buffered_items.len) {
            const value = self.buffered_items[self.buffered_index];
            self.buffered_index += 1;
            return value;
        }
        self.empty_polls += 1;
        return null;
    }
    fn bufferedFn(ctx: *anyopaque) bool {
        const self = from(ctx);
        return self.item != null or self.buffered_index < self.buffered_items.len;
    }
    fn cancelFn(ctx: *anyopaque, _: u64) anyerror!void {
        from(ctx).cancels += 1;
    }
    fn cancelClearFn(ctx: *anyopaque, _: u64, revision: u64) anyerror!void {
        const self = from(ctx);
        self.cancel_clears += 1;
        self.last_cancel_clear_revision = revision;
    }
    fn setConfirmingFn(ctx: *anyopaque, epoch: u64, active: bool) anyerror!void {
        const self = from(ctx);
        self.confirmings += 1;
        self.last_confirming_epoch = epoch;
        self.last_confirming_active = active;
        // The owner adopts a complete fresh snapshot on every barrier change;
        // only the queue revision matters here, so the UI must rebuild its stop
        // identity from the adopted value instead of a pre-RPC sample.
        self.snapshot.queue_revision +%= 1;
        self.last_confirming_revision = self.snapshot.queue_revision;
    }
    fn approveFn(ctx: *anyopaque, epoch: u64, id: u64, _: r.Decision) anyerror!void {
        const self = from(ctx);
        self.approvals += 1;
        self.last_approve_epoch = epoch;
        self.last_approve_id = id;
    }
    fn enqueueFn(ctx: *anyopaque, epoch: u64, kind: session_client.QueueKind, value: []const u8) anyerror!void {
        const self = from(ctx);
        self.enqueues += 1;
        self.last_enqueue_epoch = epoch;
        self.last_enqueue_kind = kind;
        self.record(value);
    }
    fn withdrawFn(_: *anyopaque, _: std.mem.Allocator, _: u64, _: u64) anyerror!?[]u8 {
        return null;
    }
    fn queueResumeFn(ctx: *anyopaque, _: u64) anyerror!void {
        from(ctx).resumes += 1;
    }
    fn manageFn(ctx: *anyopaque, _: std.mem.Allocator, request: session_client.Manage) anyerror!session_client.Outcome {
        const self = from(ctx);
        self.manages += 1;
        self.last_manage = std.meta.activeTag(request);
        if (self.manage_switched) self.snapshot.control_epoch +%= 1;
        return .{ .switched = self.manage_switched, .exit = self.manage_exit };
    }
    fn detachFn(ctx: *anyopaque) void {
        from(ctx).detaches += 1;
    }

    const vtable = session_client.VTable{
        .snapshot_fn = snapshotFn,
        .submit_fn = submitFn,
        .poll_fn = pollFn,
        .buffered_fn = bufferedFn,
        .acknowledge_fn = acknowledgeFn,
        .acknowledge_range_fn = acknowledgeRangeFn,
        .cancel_fn = cancelFn,
        .cancel_clear_fn = cancelClearFn,
        .set_confirming_fn = setConfirmingFn,
        .approve_fn = approveFn,
        .enqueue_fn = enqueueFn,
        .withdraw_fn = withdrawFn,
        .queue_resume_fn = queueResumeFn,
        .manage_fn = manageFn,
        .detach_fn = detachFn,
    };

    fn current(ctx: *anyopaque) Connection.State {
        const self = from(ctx);
        return .{
            .runtime = null,
            .available = self.snapshot.available,
            .busy = self.snapshot.busy,
            .session_id = self.snapshot.session_id,
            .control_epoch = self.snapshot.control_epoch,
            .model = "fixture",
            .codex_login = self.codex,
            .base_url = "",
        };
    }
    fn configure(_: *anyopaque, _: []const u8) !void {
        return error.FixtureNotConfigured;
    }
};

fn remoteUi(fake: *FakeRemote, bridge: *bridge_module.Bridge, cancel: *p.Cancellation) Ui {
    var ui = Ui{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .connection = .{ .context = fake, .current_fn = FakeRemote.current, .configure_fn = FakeRemote.configure, .session_client = fake.client() },
        .bridge = bridge,
        .cancel = cancel,
        .terminal = undefined,
        .editor = .{ .allocator = std.testing.allocator },
        .job = .{ .runtime = undefined, .cancel = cancel, .prompt = "" },
        .size = .{ .columns = 80, .rows = 24 },
    };
    ui.adoptRemoteSession(fake.client());
    return ui;
}

fn drainBridge(ui: *Ui) !void {
    while (ui.bridge.pop()) |value| {
        var item = value;
        defer item.deinit();
        try ui.event(item);
    }
}

fn typeDraft(ui: *Ui, value: []const u8) !void {
    _ = try ui.editor.insert(value);
}

test "remote delivery requires a complete fresh frame and retries failed admission" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.finishFrame(); // Partial frame must not be proof.
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    ui.frame_offset = ui.frame.len;
    ui.frame_fresh = false;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    fake.ack_failure = true;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    fake.ack_failure = false;
    ui.retryDeliveryAck();
    try std.testing.expectEqual(@as(u64, 9), fake.ack_epoch);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
}

test "remote delivery retains source across batches and unsafe history reset" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for (1..3) |sequence| {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "pending text" });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = @intCast(sequence);
        try ui.pumpRemote();
    }
    const index = ui.draft.?;
    const before = ui.records.items[index].stream.?.windowBytes();
    try std.testing.expect(before != 0);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // Visibility contract: a complete fresh frame proves the mutable window it
    // actually displayed, so live delivery is acknowledged without EOF. The
    // Body still owns its source for future syntax.
    try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, before), ui.records.items[index].stream.?.windowBytes());
    // Accepted-but-undisplayed bytes stay unprovable: a later event that has no
    // frame yet keeps history display reset unsafe and the source retained.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = " late" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 3;
    try ui.pumpRemote();
    var baseline = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    defer baseline.deinit();
    baseline.history_display_reset = true;
    ui.adoptReplayHistory(&baseline);
    try std.testing.expect(ui.replay_refused);
    try std.testing.expect(ui.records.items[ui.draft.?].stream.?.windowBytes() != 0);
}

test "delivery coverage resolution never claims a cropped or replaced row" {
    const frozen = FrameRecord{ .record_id = 1, .generation = 1, .visible_complete = true, .stream_full_end = 60, .visible_source_end = 60 };
    const shown_tail = FrameRecord{ .record_id = 2, .generation = 1, .tail_line_start = 3, .tail_rows = 2, .stream_full_end = 90, .stream_prefix_end = 40 };
    const cropped_tail = FrameRecord{ .record_id = 3, .generation = 1, .tail_line_start = 0, .tail_rows = 2, .stream_full_end = 70, .stream_prefix_end = 30 };
    const replaced = FrameRecord{ .record_id = 4, .generation = 1, .stream_full_end = 50, .stream_prefix_end = 20 };
    const thinking = FrameRecord{ .record_id = 5, .generation = 1, .reasoning = true };
    var entries = [_]FrameRecord{ frozen, shown_tail, cropped_tail, replaced, thinking };
    resolveDeliveryCoverage(&entries, 0, 1, true);
    // Rows already released into native scrollback are displayed by definition.
    try std.testing.expect(entries[0].visible_complete);
    try std.testing.expectEqual(@as(usize, 60), entries[0].visible_source_end);
    // The whole mutable tail below the visible origin was written.
    try std.testing.expect(entries[1].visible_complete);
    try std.testing.expectEqual(@as(usize, 90), entries[1].visible_source_end);
    // A crop above the record's own rows leaves only the frozen prefix proven.
    try std.testing.expect(!entries[2].visible_complete);
    try std.testing.expectEqual(@as(usize, 30), entries[2].visible_source_end);
    // A modal replaced the body: no tail row of it was painted.
    try std.testing.expect(!entries[3].visible_complete);
    try std.testing.expectEqual(@as(usize, 20), entries[3].visible_source_end);
    try std.testing.expect(entries[4].visible_complete);
    // A deferred thinking window proves nothing until its newest rows are shown.
    var deferred = [_]FrameRecord{thinking};
    resolveDeliveryCoverage(&deferred, 0, 1, false);
    try std.testing.expect(!deferred[0].visible_complete);
    // Borrowed ACKed rows shift the tail; the record still counts as complete.
    var shifted = [_]FrameRecord{shown_tail};
    resolveDeliveryCoverage(&shifted, 2, 4, false);
    try std.testing.expect(shifted[0].visible_complete);
    var unshifted = [_]FrameRecord{shown_tail};
    resolveDeliveryCoverage(&unshifted, 0, 4, false);
    try std.testing.expect(!unshifted[0].visible_complete);
    try std.testing.expectEqual(@as(usize, 40), unshifted[0].visible_source_end);
}

test "approval modal withholds body fences until the body is shown again" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "hidden while approving" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "run a command"), .clipped = false, .pasted = false, .epoch = 9 };
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    // Closing the modal restores the body; only that fresh frame proves it.
    ui.clearPermission();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
}

test "modal release repins cached body for fresh delivery proof without reparsing" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "shown" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = " hidden while approving" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    const index = ui.draft.?;
    const body = ui.records.items[index].stream.?;
    ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "run a command"), .clipped = false, .pasted = false, .epoch = 9 };
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    try std.testing.expect(!body.pinned);
    try std.testing.expect(ui.records.items[index].cache != null);
    const renders = body.stats.renders;
    const parsed_bytes = body.stats.window_bytes;
    ui.clearPermission();
    try ui.draw();
    try std.testing.expect(body.pinned);
    try std.testing.expectEqual(renders, body.stats.renders);
    try std.testing.expectEqual(parsed_bytes, body.stats.window_bytes);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}

test "an append during a pinned frame cannot extend its ACK snapshot" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "one" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw(); // Staged with admission snapshot 1 and a pinned render.
    try std.testing.expect(ui.frame.len != 0);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "two" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    try std.testing.expectEqual(@as(u64, 2), ui.delivery_admitted);
    // The next complete frame renders and proves the appended bytes.
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}

test "a held CR blocks only its own fence while earlier rows progress" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .user_committed = .{ .id = 1, .text = "hello" } });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "abc\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The committed user row is fully shown even though the body still holds a
    // pending CR byte that no row can represent yet.
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\ndef" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 3;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 3), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 3), fake.ack_sequence);
}

test "metadata is selectively acknowledged while a data fence stays unmet" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "abc\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The applied owner state is displayed, so it is acknowledged selectively...
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expectEqual(@as(usize, 1), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].last);
    // ...while the cumulative watermarks stop at the unprovable text event.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
    try std.testing.expect(ui.delivery_fences.items[0].record_id != 0);
}

test "metadata past a held CR hole is selectively acknowledged until the LF arrives" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // The seed ends in a CR: no row can represent that byte yet.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    // A modal frame never showed the body, so it cannot claim that source.
    ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "run a command"), .clipped = false, .pasted = false, .epoch = 9 };
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    ui.clearPermission();
    // >1024 ordered metadata deltas behind that hole.
    var sequence: u64 = 2;
    var chunk: usize = 0;
    while (sequence <= 1100) : (sequence += 1) {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = sequence;
        try ui.pumpRemote();
        chunk += 1;
        if (chunk == 1) {
            // Metadata must never inherit the body's unchanged CR target.
            for (ui.delivery_fences.items[1..]) |fence| {
                try std.testing.expectEqual(@as(u64, 0), fence.record_id);
                try std.testing.expectEqual(@as(usize, 0), fence.target);
            }
        }
        if (chunk == 200) {
            chunk = 0;
            try ui.draw();
            ui.frame_offset = ui.frame.len;
            ui.finishFrame();
        }
    }
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The ring never needs to hold metadata that the UI already displayed.
    try std.testing.expect(fake.ack_range_count != 0);
    for (fake.ack_ranges[0..fake.ack_range_count]) |range| {
        try std.testing.expect(range.first >= 2);
        try std.testing.expect(range.last <= 1100);
    }
    // The held-CR hole stays retained and is never claimed by a watermark.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expect(ui.delivery_fences.items.len >= 2);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
    try std.testing.expect(ui.delivery_fences.items[0].record_id != 0);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    // The LF resolves the byte; only now may the prefix cover everything.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1101;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1101), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1101), ui.delivery_acked);
    try std.testing.expectEqual(@as(u64, 1101), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 0), ui.delivery_fences.items.len);
}

test "a failed selective range keeps its exact interval for retry" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    var sequence: u64 = 2;
    while (sequence <= 4) : (sequence += 1) {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = sequence;
        try ui.pumpRemote();
    }
    fake.ack_range_failure = true;
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    for (ui.delivery_fences.items) |fence| try std.testing.expect(!fence.enqueued);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    // Retrying re-sends exactly the same proven interval, never a wider claim.
    fake.ack_range_failure = false;
    ui.retryDeliveryAck();
    try std.testing.expectEqual(@as(usize, 1), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 4), fake.ack_ranges[0].last);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
}

test "sparse event sequences are acknowledged as exact ranges, never bridged" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    for ([_]u64{ 2, 5, 9 }) |sequence| {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = sequence;
        try ui.pumpRemote();
    }
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 3), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].last);
    try std.testing.expectEqual(@as(u64, 5), fake.ack_ranges[1].first);
    try std.testing.expectEqual(@as(u64, 5), fake.ack_ranges[1].last);
    try std.testing.expectEqual(@as(u64, 9), fake.ack_ranges[2].first);
    try std.testing.expectEqual(@as(u64, 9), fake.ack_ranges[2].last);
    // A high later sequence never advances the contiguous cursors over the hole.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
}

test "a stalled selective ACK keeps cancel input live" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    fake.ack_range_failure = true;
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try Ui.key(&ui, .cancel);
    try std.testing.expect(ui.stop_open);
}

test "a missing range channel never closes a hole with a cumulative claim" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var vtable = FakeRemote.vtable;
    vtable.acknowledge_range_fn = null;
    var ui = remoteUi(&fake, &bridge, &cancel);
    ui.connection.session_client = .{ .context = &fake, .vtable = &vtable };
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expect(ui.delivery_range_unsupported);
    try std.testing.expect(std.mem.find(u8, ui.notice, "range ACK unsupported") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
}

test "a coalesced raw span is acknowledged as its full interval, not its last sequence" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Primary body ends in a held CR: seq1 cannot be shown yet.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    // One coalesced reasoning payload standing for raw events 2..1024, which the
    // existing UX hides because prose already started.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = "hidden reasoning tail" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 2;
    fake.item.?.delivery_sequence = 1024;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(usize, 2), ui.delivery_fences.items.len);
    try std.testing.expectEqual(@as(u64, 2), ui.delivery_fences.items[1].first);
    try std.testing.expectEqual(@as(u64, 1024), ui.delivery_fences.items[1].sequence);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The whole coalesced interval is claimed; the singleton 1024 would strand
    // raw sequences 2..1023 in the server ring.
    try std.testing.expectEqual(@as(usize, 1), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 1024), fake.ack_ranges[0].last);
    // The CR hole still owns the contiguous cursors.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
    // The later LF releases the hole and the whole prefix together.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 1025;
    fake.item.?.delivery_sequence = 1025;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1025), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1025), ui.delivery_acked);
    try std.testing.expectEqual(@as(u64, 1025), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 0), ui.delivery_fences.items.len);
}

test "an exactly empty payload inherits no held-CR source target" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Primary body ends in a held CR: seq1 owns a source target no frame can
    // display yet.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    const draft_id = ui.records.items[ui.draft.?].id;
    const held = ui.records.items[ui.draft.?].stream.?.acceptedSourceEnd();
    try std.testing.expect(held != 0);
    // One coalesced EMPTY text payload standing for raw events 2..1024. It
    // appends no source, so it must NOT be pointed at the draft's held-CR end:
    // that target can never be shown and would strand the whole interval in the
    // server ring until the finite fence queue blocks the resolving LF.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 2;
    fake.item.?.delivery_sequence = 1024;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(usize, 2), ui.delivery_fences.items.len);
    const empty = ui.delivery_fences.items[1];
    try std.testing.expectEqual(@as(u64, 2), empty.first);
    try std.testing.expectEqual(@as(u64, 1024), empty.sequence);
    // Metadata fence: no record, no source, no reasoning ownership.
    try std.testing.expectEqual(@as(u64, 0), empty.record_id);
    try std.testing.expectEqual(@as(u64, 0), empty.generation);
    try std.testing.expectEqual(@as(usize, 0), empty.target);
    try std.testing.expect(!empty.reasoning);
    // The empty span added nothing to the body it did not own.
    try std.testing.expectEqual(draft_id, ui.records.items[ui.draft.?].id);
    try std.testing.expectEqual(held, ui.records.items[ui.draft.?].stream.?.acceptedSourceEnd());
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // Its OWN fresh frame proves the whole coalesced interval exactly, while the
    // CR hole still holds the contiguous cursors: no prefix release.
    try std.testing.expectEqual(@as(usize, 1), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 1024), fake.ack_ranges[0].last);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
    // A NON-EMPTY LF after that held CR does not move the accepted end at all
    // (the held CR byte becomes the real newline), yet it renders a newline and
    // keeps a real source obligation. "Accepted end unchanged" is therefore not
    // a rule for metadata fences; only the exact empty payload is.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 1025;
    fake.item.?.delivery_sequence = 1025;
    try ui.pumpRemote();
    const lf = ui.delivery_fences.items[ui.delivery_fences.items.len - 1];
    try std.testing.expectEqual(@as(u64, 1025), lf.sequence);
    try std.testing.expectEqual(draft_id, lf.record_id);
    try std.testing.expect(lf.target != 0);
    try std.testing.expect(!lf.reasoning);
    try std.testing.expectEqual(held, ui.records.items[ui.draft.?].stream.?.acceptedSourceEnd());
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The resolving newline is displayed, so hole and interval settle together.
    try std.testing.expectEqual(@as(u64, 1025), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1025), ui.delivery_acked);
    try std.testing.expectEqual(@as(u64, 1025), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 0), ui.delivery_fences.items.len);
}

test "an exactly empty reasoning payload keeps UX ownership without a new source" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Thinking only: no prose has started, so the thinking window is the frame.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = "think\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    const reasoning_index = ui.reasoning.?;
    const reasoning_id = ui.records.items[reasoning_index].id;
    // Thinking rows are owned by the bounded plain Tail, never by an active
    // assistant Body: the fixture must read the real owner, not a null stream.
    try std.testing.expect(ui.records.items[reasoning_index].stream == null);
    const reasoning_tail_ptr = ui.records.items[reasoning_index].tail;
    try std.testing.expect(reasoning_tail_ptr != null);
    const reasoning_tail = reasoning_tail_ptr.?;
    const held = reasoning_tail.writer.pos;
    const held_source_base = reasoning_tail.source_base;
    const held_source_len = reasoning_tail.source.items.len;
    const held_carry_len = reasoning_tail.carry_len;
    const held_cr = reasoning_tail.held_cr;
    // An empty coalesced reasoning span: it keeps the explicit thinking UX
    // ownership but requires no new source bytes.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = "" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 2;
    fake.item.?.delivery_sequence = 3;
    try ui.pumpRemote();
    const empty = ui.delivery_fences.items[ui.delivery_fences.items.len - 1];
    try std.testing.expectEqual(@as(u64, 2), empty.first);
    try std.testing.expectEqual(@as(u64, 3), empty.sequence);
    try std.testing.expect(empty.reasoning);
    try std.testing.expectEqual(reasoning_id, empty.record_id);
    try std.testing.expectEqual(@as(usize, 0), empty.target);
    try std.testing.expect(ui.records.items[reasoning_index].stream == null);
    try std.testing.expect(ui.records.items[reasoning_index].tail == reasoning_tail);
    try std.testing.expectEqual(held, reasoning_tail.writer.pos);
    try std.testing.expectEqual(held_source_base, reasoning_tail.source_base);
    try std.testing.expectEqual(held_source_len, reasoning_tail.source.items.len);
    try std.testing.expectEqual(held_carry_len, reasoning_tail.carry_len);
    try std.testing.expectEqual(held_cr, reasoning_tail.held_cr);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // A fresh frame that draws the newest thinking rows proves both sequences;
    // nothing waits for source bytes that were never appended.
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 3), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 0), ui.delivery_fences.items.len);
}

test "incremental reasoning fences retain their owner and frame admission boundary" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for ([_][]const u8{ "first", " second" }, 1..) |chunk, seq| {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = chunk });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = @intCast(seq);
        try ui.pumpRemote();
    }
    const index = ui.reasoning.?;
    const generation = ui.records.items[index].stream_generation;
    try std.testing.expectEqual(generation, ui.delivery_fences.items[0].generation);
    try std.testing.expectEqual(generation, ui.delivery_fences.items[1].generation);
    try ui.draw();
    // A partial frame is not an ACK; a later admission cannot inherit this frame.
    ui.frame_offset = ui.frame.len - 1;
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = " third" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 3;
    try ui.pumpRemote();
    try std.testing.expectEqual(generation, ui.records.items[index].stream_generation);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 3), fake.ack_sequence);
}

test "reasoning stale geometry and reset ABA never acknowledge old fences" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for ([_][]const u8{ "first", " second" }, 1..) |chunk, seq| {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = chunk });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = @intCast(seq);
        try ui.pumpRemote();
    }
    const index = ui.reasoning.?;
    const generation = ui.records.items[index].stream_generation;
    try std.testing.expectEqual(generation, ui.delivery_fences.items[0].generation);
    try std.testing.expectEqual(generation, ui.delivery_fences.items[1].generation);
    try ui.draw();
    // A resize discards the frame even when geometry subsequently returns.
    ui.resize(.{ .columns = 79, .rows = 24 });
    ui.resize(.{ .columns = 80, .rows = 24 });
    try std.testing.expectEqual(@as(usize, 0), ui.frame.len);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try ui.draw();
    try ui.records.items[index].resetStream();
    try std.testing.expect(ui.records.items[index].stream_generation != generation);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expectEqual(generation, ui.delivery_fences.items[0].generation);
}

test "empty heading EOF metadata requires a complete fresh unobscured frame" {
    for (0..4) |scenario| {
        var fake = FakeRemote{};
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "# " });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = 1;
        try ui.pumpRemote();
        const index = ui.draft.?;
        const body = ui.records.items[index].stream.?;
        try body.finish(); // Known EOF, while retaining the draft's flow ownership.
        if (scenario == 2) ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "approval"), .clipped = false, .pasted = false, .epoch = 9 };
        try ui.draw();
        try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].lines.len);
        try std.testing.expectEqual(@as(usize, 1), ui.frame_records.len);
        try std.testing.expectEqual(scenario != 2, ui.frame_records[0].metadata_staged);
        try std.testing.expectEqual(@as(usize, 0), ui.frame_records[0].stream_rows);
        try std.testing.expect(body.hasMetadataProgress());
        try std.testing.expect(!body.isDrained());
        try std.testing.expectEqual(@as(usize, 0), body.base);
        try std.testing.expectEqual(@as(usize, 2), body.windowBytes());
        try std.testing.expectEqualStrings("# ", body.source.items);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
        try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
        try std.testing.expect(ui.frame.len > 1);
        if (scenario == 0) {
            ui.frame_offset = ui.frame.len - 1;
            ui.finishFrame();
            try std.testing.expect(body.hasMetadataProgress());
            try std.testing.expect(!body.isDrained());
            try std.testing.expectEqual(@as(usize, 0), body.base);
            try std.testing.expectEqual(@as(usize, 2), body.windowBytes());
            try std.testing.expectEqualStrings("# ", body.source.items);
            try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
            try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
        } else if (scenario == 1) {
            ui.frame_fresh = false;
        } else if (scenario == 3) {
            ui.resize(.{ .columns = 79, .rows = 24 });
            ui.resize(.{ .columns = 80, .rows = 24 });
            try std.testing.expectEqual(@as(usize, 0), ui.frame.len);
        }
        if (scenario != 3) {
            ui.frame_offset = ui.frame.len;
            ui.finishFrame();
        }
        if (scenario != 0) {
            try std.testing.expect(!body.hasMetadataProgress());
            try std.testing.expectEqual(@as(usize, 0), body.base);
            try std.testing.expect(!body.isDrained());
            try std.testing.expectEqual(@as(usize, 2), body.windowBytes());
            try std.testing.expectEqualStrings("# ", body.source.items);
            try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
            try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
            if (scenario == 2) ui.clearPermission();
            if (scenario == 3) ui.requestDraw();
            try ui.draw();
            try std.testing.expect(body.hasMetadataProgress());
            try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].lines.len);
            try std.testing.expect(ui.frame_records[0].metadata_staged);
            ui.frame_offset = ui.frame.len;
            ui.finishFrame();
        }
        try std.testing.expect(!body.hasMetadataProgress());
        try std.testing.expect(body.isDrained());
        try std.testing.expectEqual(@as(usize, 2), body.base);
        try std.testing.expectEqual(@as(usize, 0), body.windowBytes());
        try std.testing.expectEqualStrings("", body.source.items);
        try std.testing.expectEqual(@as(usize, 2), ui.records.items[index].delivery_visible);
        try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
        try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    }
}

test "literal reference definition requires a complete fresh unobscured frame" {
    for (0..3) |scenario| {
        var fake = FakeRemote{};
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        const definition = "[r]: https://example.org/one\n\n";
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = definition });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = 1;
        try ui.pumpRemote();
        const index = ui.draft.?;
        const body = ui.records.items[index].stream.?;
        if (scenario == 2) ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "approval"), .clipped = false, .pasted = false, .epoch = 9 };
        try ui.draw();
        if (scenario != 2) try std.testing.expect(std.mem.indexOf(u8, ui.frame, "[r]: https://example.org/one") != null);
        try std.testing.expectEqual(@as(usize, 0), body.base);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
        if (scenario == 0) {
            try std.testing.expect(ui.frame.len > 1);
            ui.frame_offset = ui.frame.len - 1;
            ui.finishFrame();
            try std.testing.expectEqual(@as(usize, 0), body.base);
            try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
        } else if (scenario == 1) ui.frame_fresh = false;
        ui.frame_offset = ui.frame.len;
        ui.finishFrame();
        if (scenario != 0) {
            try std.testing.expectEqual(@as(usize, 0), body.base);
            try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
            try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
            if (scenario == 2) ui.clearPermission();
            try ui.draw();
            ui.frame_offset = ui.frame.len;
            ui.finishFrame();
        }
        try std.testing.expect(ui.records.items[index].delivery_visible != 0);
        try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "later [two][r]\n" });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = 2;
        try ui.pumpRemote();
        try ui.draw();
        try std.testing.expect(std.mem.indexOf(u8, ui.frame, "[two][r]") != null);
        ui.frame_offset = ui.frame.len;
        ui.finishFrame();
        try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
    }
}

test "reference-looking syntax remains literal rather than resolving a link" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    const candidate = "[ref]: https://example.org/url\n";
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = candidate });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "[ref]: https://example.org/url") != null);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "  \"title\"\n\n[link][ref]\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "[link][ref]") != null);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}

test "an unexplained generation replacement is never acknowledged, even later" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "abcdef" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    const index = ui.draft.?;
    // Nobody asked for this replacement: an ABA/generation mismatch is not
    // authority to ACK, neither through the stale frame nor any later one.
    try ui.records.items[index].resetStream();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    for (0..3) |_| {
        try ui.draw();
        ui.frame_offset = ui.frame.len;
        ui.finishFrame();
    }
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    // The fence kept its own generation; no inference rewrote it.
    try std.testing.expect(ui.delivery_fences.items[0].generation != ui.records.items[index].stream_generation);
    // Only an explicit canonical replacement retargets the same sequences to the
    // replacement's own display obligation, and only a fresh frame proves it.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .assistant_committed = &.{.{ .text = "abcdef" }} });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}

test "256 CR-terminated events prove every earlier sequence while the last CR waits" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var sequence: u64 = 1;
    while (sequence <= delivery_fence_capacity) : (sequence += 1) {
        const chunk = [2]u8{ 'a' + @as(u8, @intCast(sequence % 26)), '\r' };
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = &chunk });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = sequence;
        try ui.pumpRemote();
    }
    // Every event keeps its own ordered fence: the last target cannot swallow
    // the earlier ones, so the queue is exactly the bound.
    try std.testing.expectEqual(@as(usize, delivery_fence_capacity), ui.delivery_fences.items.len);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // All shown prefixes are proven; only the pending CR byte (no row can
    // represent it yet) keeps the newest sequence outstanding.
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity - 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity - 1), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 1), ui.delivery_fences.items.len);
    // The resolving chunk settles the last sequence too.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = delivery_fence_capacity + 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity + 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity + 1), fake.ack_sequence);
}

test "a full delivery fence queue blocks polling without losing the event" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.delivery_epoch = 9;
    var sequence: u64 = 1;
    while (sequence <= delivery_fence_capacity) : (sequence += 1)
        ui.pushDeliveryFence(.{ .epoch = 9, .sequence = sequence });
    try std.testing.expectEqual(@as(usize, delivery_fence_capacity), ui.delivery_fences.items.len);
    try std.testing.expect(ui.displayBackpressured());
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "must not be consumed" });
    defer if (fake.item) |*item| item.deinit();
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = delivery_fence_capacity + 1;
    try ui.pumpDisplay();
    try std.testing.expect(fake.item != null);
    try std.testing.expectEqual(@as(usize, 0), bridge.len);
    try std.testing.expect(!ui.delivery_fault);
    try std.testing.expectEqual(@as(usize, delivery_fence_capacity), ui.delivery_fences.items.len);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
}

test "an event applied after the frame was built is never covered by it" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "abcdef" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    // Stage a frame, THEN apply an event whose target is already covered by the
    // pinned rows. The earlier admission snapshot cannot prove it.
    try ui.draw();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .assistant_committed = &.{.{ .text = "abcdef" }} });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    // A frame staged after that admission does cover it.
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}

test "canonical replacement waits for its own rendered source" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "aaaa" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .assistant_committed = &.{.{ .text = "bbbbbbbb" }} });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    // The stale frame shows the retired generation, so it proves neither.
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    // Both sequences now own the replacement's source; the fresh frame proves it.
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}

test "successive frames prove progressively more of one active body" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    // Comfortably more than the renderer's default 4 KiB work window.
    for (0..900) |_| try body.appendSlice(std.testing.allocator, "abcdef\n");
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = body.items });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The first window is displayed but the accepted tail is not; no ACK yet.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    for (0..8) |_| {
        if (ui.delivery_proven == 1) break;
        try ui.draw();
        ui.frame_offset = ui.frame.len;
        ui.finishFrame();
    }
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    // Retained source is not EOF: the answer is still streaming in display terms.
    try std.testing.expect(ui.records.items[ui.draft.?].stream.?.windowBytes() != 0);
}

test "an unsupported ACK enqueue never retires live delivery" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var vtable = FakeRemote.vtable;
    vtable.acknowledge_fn = null;
    vtable.acknowledge_range_fn = null;
    var ui = remoteUi(&fake, &bridge, &cancel);
    ui.connection.session_client = .{ .context = &fake, .vtable = &vtable };
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "cannot ack" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expect(!ui.delivery_fault);
    // The lack of an ACK channel is reported, never treated as an ACK.
    try std.testing.expect(ui.delivery_ack_unsupported);
    try std.testing.expect(std.mem.find(u8, ui.notice, "ACK unsupported") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
}

test "an unmet delivery fence protects its record from eviction" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "old output");
    ui.records.items[0].output = true;
    _ = try ui.add(.user, "live tail");
    ui.draft = 1;
    ui.reasoning = 1;
    try std.testing.expect(ui.canEvictOldest());
    const id = ui.records.items[0].id;
    ui.pushDeliveryFence(.{ .epoch = 9, .sequence = 1, .record_id = id });
    try std.testing.expect(!ui.canEvictOldest());
    ui.delivery_fences.items[0].proven = true;
    try std.testing.expect(ui.canEvictOldest());
}

test "remote delivery rejects resized and stale record frames" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.admitDelivery(9, 1);
    try ui.draw();
    ui.discardResizedFrame();
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try ui.draw();
    var stale = [_]FrameRecord{.{ .record_id = 999999, .generation = 1 }};
    ui.frame_records = &stale;
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
}

test "remote delivery revokes pending proof on epoch takeover" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.admitDelivery(9, 1);
    try ui.draw();
    fake.snapshot.control_epoch = 2;
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    ui.resetSessionView(&fake.snapshot);
    ui.retryDeliveryAck();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
}

test "display admission leaves remote event queued while cancel input remains live" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for (0..62) |_| _ = try ui.add(.user, "pending");
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "not consumed" });
    defer if (fake.item) |*item| item.deinit();
    try ui.pumpDisplay();
    try std.testing.expect(fake.item != null);
    try std.testing.expectEqual(@as(usize, 0), bridge.len);
    try Ui.key(&ui, .cancel);
    try std.testing.expect(ui.stop_open);
}

test "synchronizing remote view never paints an idle prompt or invents a running task" {
    var fake = FakeRemote{ .snapshot = .{ .available = false, .attached = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ui.adoptRemoteActivity(&fake.snapshot);
    try std.testing.expect(!ui.busy and ui.remoteSynchronizing());
    try std.testing.expect(!ui.settingsIdle());
    const before = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 79);
    try std.testing.expect(!std.mem.endsWith(u8, before.decoration.plain, "> "));
    try typeDraft(&ui, "kept");
    try std.testing.expect(!try ui.remoteStart(fake.client(), .prompt, ui.editor.bytes.items));
    try std.testing.expectEqualStrings("kept", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try std.testing.expectEqualStrings("Synchronizing session; draft kept", ui.notice);
    ui.dirty = false;
    fake.snapshot.available = true;
    ui.adoptRemoteActivity(&fake.snapshot);
    try std.testing.expect(ui.dirty and !ui.busy and !ui.remoteSynchronizing());
    try std.testing.expectEqualStrings("Ready", ui.notice);
    const after = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 79);
    try std.testing.expect(std.mem.endsWith(u8, after.decoration.plain, "> "));
}

test "remote display drains a bounded batch without polling empty pages or settling queued output" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 4 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var items: [72]session_client.Item = undefined;
    var initialized: usize = 0;
    defer for (items[fake.buffered_index..initialized]) |*item| item.deinit();
    for (0..70) |index| {
        items[index] = try session_client.ownEvent(std.testing.allocator, 4, .{ .text = "x" });
        initialized += 1;
    }
    const body: [70]u8 = @splat('x');
    const blocks = [_]p.Block{.{ .text = &body }};
    items[70] = try session_client.ownEvent(std.testing.allocator, 4, .{ .assistant_committed = &blocks });
    initialized += 1;
    items[71] = try session_client.ownEvent(std.testing.allocator, 4, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    initialized += 1;
    fake.buffered_items = &items;
    // The owner has already finished, but queued live events still own display.
    fake.snapshot.busy = false;
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 64), fake.buffered_index);
    try std.testing.expectEqual(@as(usize, 64), ui.records.items[ui.draft.?].body.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.empty_polls);
    try std.testing.expect(ui.busy and ui.last_terminal == null);
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 72), fake.buffered_index);
    try std.testing.expectEqual(@as(usize, 0), fake.empty_polls);
    try ui.complete();
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqualStrings(&body, ui.records.items[ui.records.items.len - 1].body.items);
    // One empty tick makes just one adapter poll, not 64 synchronous RPCs.
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 1), fake.empty_polls);
}

test "remote deinit detaches and never cancels or clears the daemon task" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 4 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(u64, 4), ui.remote_epoch);
    ui.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.detaches);
    try std.testing.expectEqual(@as(usize, 0), fake.cancels);
    try std.testing.expectEqual(@as(usize, 0), fake.cancel_clears);
}

test "remote submit is sent once and a rejected submit keeps the draft and starts nothing" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try typeDraft(&ui, "hello");
    fake.submit_failure = error.Transport;
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 1), fake.submits);
    try std.testing.expect(!ui.busy and ui.future == null);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqualStrings("hello", ui.editor.bytes.items);
    try std.testing.expectEqualStrings("Connection lost; the task was not canceled", ui.notice);

    fake.submit_failure = null;
    try ui.submit();
    // Exactly one accepted request: no implicit retry of the rejected one.
    try std.testing.expectEqual(@as(usize, 2), fake.submits);
    try std.testing.expectEqual(@as(u64, 1), fake.last_submit_epoch);
    try std.testing.expectEqual(session_client.TaskKind.prompt, fake.last_submit_kind);
    try std.testing.expectEqualStrings("hello", fake.text[0..fake.text_len]);
    try std.testing.expect(ui.busy and ui.remote_kind == .prompt);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqualStrings("hello", ui.records.items[0].body.items);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
}

test "remote approval binds the epoch that displayed it and bypasses the local bridge" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .permission = .{ .id = 11, .tool_name = "bash", .description = "rm -rf build" } });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(ui.permission != null);
    try std.testing.expectEqual(@as(u64, 6), ui.permission.?.epoch);
    // Approvals are backend-owned: the local Bridge must not hold a pending id.
    try std.testing.expect(ui.bridge.pending == null);
    ui.decidePermission(.deny, false);
    try std.testing.expectEqual(@as(usize, 1), fake.approvals);
    try std.testing.expectEqual(@as(u64, 6), fake.last_approve_epoch);
    try std.testing.expectEqual(@as(u64, 11), fake.last_approve_id);
    try std.testing.expect(ui.permission == null);
}

const FakeAsync = struct {
    requests: [8]?*remote_action.Owned = @splat(null),
    next: usize = 0,
    completed: ?remote_action.Completion = null,

    fn channel(self: *FakeAsync) remote_action.Channel {
        return .{ .context = self, .start_fn = start, .poll_fn = poll, .wake_fd = -1 };
    }
    fn start(raw: *anyopaque, epoch: u64, action: remote_action.Action) !u64 {
        const self: *FakeAsync = @ptrCast(@alignCast(raw));
        if (self.next == self.requests.len) return error.QueueFull;
        const ticket: u64 = @intCast(self.next + 1);
        self.requests[self.next] = try remote_action.Owned.create(std.testing.allocator, ticket, 1, epoch, action);
        self.next += 1;
        return ticket;
    }
    fn poll(raw: *anyopaque) ?remote_action.Completion {
        const self: *FakeAsync = @ptrCast(@alignCast(raw));
        const value = self.completed;
        self.completed = null;
        return value;
    }
    fn complete(self: *FakeAsync, value: remote_action.Value, failure: ?anyerror, obsolete: bool) void {
        std.debug.assert(self.completed == null);
        for (&self.requests) |*slot| if (slot.*) |request| {
            self.completed = .{ .request = request, .value = value, .failure = failure, .obsolete = obsolete };
            slot.* = null;
            return;
        };
        unreachable;
    }
    fn deinit(self: *FakeAsync) void {
        for (self.requests) |slot| if (slot) |request| request.deinit();
        if (self.completed) |*value| value.deinit();
    }
};

test "multiple reserved async records survive intervening display records" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    for (0..4) |slot| {
        try ui.reserveRecord();
        const ticket = try FakeAsync.start(&actions, 6, .{ .submit = .{ .kind = .prompt, .text = "reserved" } });
        var record = Record{ .kind = .user };
        try record.append(std.testing.allocator, "reserved");
        ui.async_pending[slot] = .{
            .ticket = ticket,
            .purpose = .submit,
            .original_editor = try std.testing.allocator.dupe(u8, ""),
            .editor_revision = 0,
            .epoch = 6,
            .permission_id = null,
            .previous_effort = ui.connection.current().reasoning_effort,
            .settings_generation = 0,
            .stop_instance = 0,
            .record = record,
        };
        _ = try ui.add(.notice, "intervening event");
    }
    for (0..4) |_| {
        actions.complete(.none, null, false);
        ui.pumpAsync();
    }
    try std.testing.expectEqual(@as(usize, 8), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 8), ui.record_index.count());
    for (ui.records.items, 0..) |record, index| try std.testing.expectEqual(index, ui.record_index.get(record.id).?);
}

test "async submit queues behind an effort probe without dropping Enter" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try std.testing.expect(ui.beginAsync(.cycle_effort, .effort) != null);
    try typeDraft(&ui, "after probe");
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 2), actions.next);
    try std.testing.expectEqualStrings("after probe", actions.requests[1].?.action.submit.text);
    actions.complete(.none, error.ThinkingCapabilitiesUnknown, false);
    ui.pumpAsync();
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expect(ui.busy);
    try std.testing.expectEqualStrings("after probe", ui.records.items[0].body.items);
}

test "late cancel acknowledgements do not overwrite the terminal result" {
    for ([_]bool{ false, true }) |clear| {
        var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
        var actions: FakeAsync = .{};
        defer actions.deinit();
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        ui.connection.async_actions = actions.channel();
        try std.testing.expect(ui.beginAsync(if (clear) .{ .cancel_clear = 1 } else .cancel, if (clear) .cancel_clear else .cancel) != null);
        ui.last_terminal = .{ .status = .canceled, .detail = error.Canceled };
        ui.busy = false;
        ui.notice = "Canceled; prior side effects remain";
        actions.complete(.none, null, false);
        ui.pumpAsync();
        try std.testing.expectEqualStrings("Canceled; prior side effects remain", ui.notice);
    }
}

test "async metadata errors retain the actionable synchronous notice" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try std.testing.expect(ui.beginAsync(.refresh_models, .refresh) != null);
    actions.complete(.none, error.NoOfficialProvider, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("No official provider configured; use /login first", ui.notice);
    try std.testing.expect(ui.beginAsync(.cycle_effort, .effort) != null);
    actions.complete(.none, error.ThinkingCapabilitiesLoading, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("Thinking capabilities are loading; try Shift+Tab again shortly", ui.notice);
}

test "async submit commits once after receipt and preserves newer draft" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try typeDraft(&ui, "first prompt");
    try std.testing.expect(!try ui.remoteStart(fake.client(), .prompt, ui.editor.bytes.items));
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try std.testing.expect(!ui.busy);
    try std.testing.expect(ui.presentationWaiting());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pending_composer = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 79);
    try std.testing.expect(!std.mem.endsWith(u8, pending_composer.decoration.plain, "> "));
    ui.wipeEditor();
    try typeDraft(&ui, "new draft");
    try std.testing.expectEqualStrings("first prompt", actions.requests[0].?.action.submit.text);
    actions.complete(.none, null, false);
    ui.pumpAsync();
    ui.pumpAsync();
    try std.testing.expect(!ui.presentationWaiting());
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqualStrings("first prompt", ui.records.items[0].body.items);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("new draft", ui.editor.bytes.items);
}

test "async acceptance preserves identical text that was cleared and retyped" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try typeDraft(&ui, "repeat this");
    try std.testing.expect(!try ui.remoteStart(fake.client(), .prompt, ui.editor.bytes.items));
    try Ui.key(&ui, .clear);
    try Ui.key(&ui, .{ .text = .{ .value = "repeat this", .pasted = false } });
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("repeat this", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
}

test "async rejected and obsolete submissions keep draft without publishing history" {
    for ([_]bool{ false, true }) |obsolete| {
        var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
        var actions: FakeAsync = .{};
        defer actions.deinit();
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        ui.connection.async_actions = actions.channel();
        try typeDraft(&ui, "keep this");
        try std.testing.expect(!try ui.remoteStart(fake.client(), .prompt, ui.editor.bytes.items));
        actions.complete(.none, if (obsolete) null else error.Rejected, obsolete);
        ui.pumpAsync();
        try std.testing.expectEqualStrings("keep this", ui.editor.bytes.items);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
        try std.testing.expect(!ui.normalAsyncPending());
        try std.testing.expect(!ui.busy);
    }
}

test "authoritative baseline replaces accepted user echo without erasing a new draft" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.notice, "startup banner");
    try std.testing.expect(try ui.remoteStart(fake.client(), .prompt, "accepted prompt"));
    try typeDraft(&ui, "next draft");
    var item = try session_client.ownEvent(std.testing.allocator, 6, .{ .user_committed = .{ .id = 1, .text = "accepted prompt" } });
    item.history_reset = true;
    item.history_display_reset = true;
    item.history_replay = true;
    fake.item = item;
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("startup banner", ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("accepted prompt", ui.records.items[1].body.items);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("next draft", ui.editor.bytes.items);
}

test "async queue reply does not block body delivery or erase typeahead" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try typeDraft(&ui, "queued message");
    try ui.enqueueDraft(.steering);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    ui.wipeEditor();
    try typeDraft(&ui, "typeahead");
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .text = "live body" });
    try ui.pumpDisplay();
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("live body", ui.records.items[ui.draft.?].body.items);
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("typeahead", ui.editor.bytes.items);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expect(publishedNotice(&ui, "Steering pending"));
}

test "late async approval cannot clear or relabel a newer permission" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .permission = .{ .id = 11, .tool_name = "bash", .description = "old request" } });
    try ui.pumpDisplay();
    ui.decidePermission(.deny, false);
    try std.testing.expectEqual(@as(usize, 0), fake.approvals);
    try std.testing.expect(ui.permission != null);
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .permission = .{ .id = 12, .tool_name = "bash", .description = "new request" } });
    try ui.pumpDisplay();
    ui.notice = "New request";
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expectEqual(@as(u64, 12), ui.permission.?.id);
    try std.testing.expectEqualStrings("New request", ui.notice);
}

test "remote queue sends bind the current epoch and are never launched locally" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    try typeDraft(&ui, "please continue");
    try ui.enqueueDraft(.steering);
    try std.testing.expectEqual(@as(usize, 1), fake.enqueues);
    try std.testing.expectEqual(@as(u64, 6), fake.last_enqueue_epoch);
    try std.testing.expectEqual(session_client.QueueKind.steering, fake.last_enqueue_kind);
    try std.testing.expectEqualStrings("please continue", fake.text[0..fake.text_len]);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expect(publishedNotice(&ui, "Steering pending"));
    try std.testing.expectEqual(@as(usize, 0), ui.inbox.snapshot().steering);

    ui.busy = false;
    try ui.dispatchNext();
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
}

test "remote management commands run while busy instead of entering steering" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    try typeDraft(&ui, "/ls --running");
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    try std.testing.expectEqual(@as(?std.meta.Tag(session_client.Manage), .list), fake.last_manage);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);

    // /attach runs before steering too and adopts the new owner snapshot.
    fake.manage_switched = true;
    fake.snapshot.busy = true;
    fake.snapshot.mode = .awaiting_permission;
    fake.snapshot.task_kind = .prompt;
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .text = "old session draft" });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(ui.draft != null);
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .permission = .{ .id = 3, .tool_name = "bash", .description = "old approval" } });
    try ui.pumpRemote();
    try std.testing.expect(ui.permission != null);

    try typeDraft(&ui, "/attach --takeover session-b");
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 2), fake.manages);
    try std.testing.expectEqual(@as(?std.meta.Tag(session_client.Manage), .attach), fake.last_manage);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    try std.testing.expectEqual(@as(u64, 7), ui.remote_epoch);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expect(ui.draft == null);
    try std.testing.expect(ui.permission == null);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .awaiting_permission), ui.mode);
}

test "remote committed flags survive direct application without bridge payload" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for ([_]bool{ true, false }) |clipped| {
        try ui.appendDraft(.assistant, "remote-stream");
        const id = ui.records.items[ui.draft.?].id;
        fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .assistant_committed = &.{} });
        fake.item.?.display_truncated = clipped;
        fake.item.?.canonical_complete = clipped;
        try ui.pumpRemote();
        try std.testing.expect(ui.bridgeEmpty());
        const index = ui.record_index.get(id).?;
        try std.testing.expectEqualStrings("remote-stream", ui.records.items[index].body.items);
        try std.testing.expect(ui.records.items[index].clipped);
    }
}

test "remote terminal completes without a local future and marks the task idle once" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    ui.remote_kind = .prompt;
    ui.mode = .calling_model;
    try std.testing.expect(ui.future == null);
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    try ui.pumpRemote();
    try std.testing.expect(ui.bridge.terminal != null);
    try ui.complete();
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expect(ui.bridge.terminal == null);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    // No second completion from a null future or an already consumed terminal.
    try std.testing.expect(ui.bridge.pop() == null);
}

test "remote lost terminal fallback settles only after two consecutive idle samples" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 8 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(ui.busy);
    const records_before = ui.records.items.len;
    // One idle sample is not enough, and it must leave the view busy.
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try std.testing.expect(ui.busy);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expectEqual(@as(u8, 1), ui.remote_idle_ticks);
    try std.testing.expect(ui.last_terminal == null);
    // The second consecutive idle sample settles the view without a success.
    try ui.pumpRemote();
    try std.testing.expect(!ui.busy);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expect(ui.mode == null);
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expectEqualStrings("Remote task ended without a terminal result; reattach to verify", ui.notice);
    try std.testing.expectEqual(records_before, ui.records.items.len);
}

test "remote idle fallback never settles without an observed busy sample" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 9 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try ui.pumpRemote();
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    // A local busy view alone is not evidence of remote activity either.
    ui.busy = true;
    ui.notice = "Calling model";
    try ui.pumpRemote();
    try ui.pumpRemote();
    try std.testing.expect(ui.busy);
    try std.testing.expectEqualStrings("Calling model", ui.notice);
}

test "remote idle fallback count resets when the backend reports busy again" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 10 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(u8, 1), ui.remote_idle_ticks);
    try std.testing.expect(ui.busy);
    // Busy again: the count restarts, so a single later idle cannot settle.
    fake.snapshot.busy = true;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try std.testing.expect(ui.busy);
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try std.testing.expect(ui.busy);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expectEqualStrings("Attached; task is running", ui.notice);
    try ui.pumpRemote();
    try std.testing.expect(!ui.busy);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expectEqualStrings("Remote task ended without a terminal result; reattach to verify", ui.notice);
}

test "remote idle fallback yields to a real terminal consumed by the normal path" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 11 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 11, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    try ui.pumpRemote();
    try std.testing.expect(ui.bridge.terminal != null);
    // Idle samples while the terminal is pending must not synthesize a fallback.
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try ui.pumpRemote();
    try std.testing.expect(ui.busy);
    try std.testing.expect(ui.last_terminal == null);
    try ui.complete();
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expect(ui.bridge.terminal == null);
    try std.testing.expectEqualStrings("Ready", ui.notice);
}

test "remote finished terminal is consumed from an idle local view without a future" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 12 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // The previous task already returned the view to idle. The second task can
    // start and finish between two client snapshots, so no busy sample exists,
    // yet its real terminal is already waiting in the Bridge.
    try std.testing.expect(!ui.busy and ui.future == null);
    ui.mode = .calling_model;
    fake.item = try session_client.ownEvent(std.testing.allocator, 12, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    try ui.pumpRemote();
    try std.testing.expect(ui.bridge.terminal != null);
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqual(@as(?r.State, .calling_model), ui.mode);
    // The loop's readiness helper, not a direct complete() call, must consume it.
    try ui.finishReadyTask();
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expect(ui.bridge.terminal == null);
    try std.testing.expect(ui.mode == null);
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    // Idempotent: no terminal is left to consume on a later tick.
    try ui.finishReadyTask();
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
}

test "remote decision diagnostic survives terminal copies and empty paused queue stays hidden" {
    var fake = FakeRemote{ .snapshot = .{
        .available = true,
        .attached = true,
        .control_epoch = 12,
        .queue_paused = true,
    } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var diagnostic: @import("../core/decision.zig").Diagnostic = .{
        .stage = .http,
        .backend = .systemone,
        .operation = .command,
        .http_status = 403,
    };
    diagnostic.setError(error.DecisionUnavailable);
    fake.item = try session_client.ownEvent(std.testing.allocator, 12, .{ .finished = (session_client.Terminal{
        .status = .paused,
        .failure = .decision_unavailable,
        .decision_failure = diagnostic,
    }).toRuntime() });
    // Source reuse cannot mutate any queued diagnostic storage.
    diagnostic.setError(error.UnrelatedLaterFailure);
    try ui.pumpRemote();
    try ui.finishReadyTask();
    try std.testing.expectEqualStrings("DecisionUnavailable", ui.last_terminal.?.decision_failure.?.causeName());
    ui.notice = "Ready";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line = try ui.footerHint(arena.allocator(), ui.connection.current());
    try std.testing.expectEqualStrings("Paused: decision review failed [HTTP 403]; operation not executed", line);
    try std.testing.expect(ui.queueSnapshot().paused);
    fake.snapshot.follow_up = 1;
    try std.testing.expect(std.mem.find(u8, try ui.footerHint(arena.allocator(), ui.connection.current()), "/queue resume") != null);
}

test "handled remote terminal keeps the busy composer until ordered owner idle" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .calling_model, .control_epoch = 14 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(ui.busy and ui.remote_observed_busy);
    fake.item = try session_client.ownEvent(std.testing.allocator, 14, .{ .finished = (session_client.Terminal{ .status = .canceled, .failure = .canceled }).toRuntime() });
    try ui.pumpRemote();
    try ui.finishReadyTask();
    // The terminal is handled while the owner still reports this task busy, so
    // no idle composer or settings-idle state is published and the result holds.
    try std.testing.expect(ui.busy);
    try std.testing.expect(ui.remote_terminal_wait);
    try std.testing.expect(!ui.settingsIdle());
    try std.testing.expect(ui.mode == null);
    try std.testing.expectEqual(r.Status.canceled, ui.last_terminal.?.status);
    try std.testing.expectEqual(error.Canceled, ui.last_terminal.?.detail.?);
    try std.testing.expectEqualStrings("Canceled; prior side effects remain", ui.notice);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const held = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 79);
    try std.testing.expect(!std.mem.endsWith(u8, held.decoration.plain, "> "));
    // Ordered owner idle releases the held view without inventing a missing
    // terminal or discarding the real result and its exact failure detail.
    ui.dirty = false;
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try std.testing.expect(ui.busy and ui.remote_terminal_wait);
    try std.testing.expectEqualStrings("Canceled; prior side effects remain", ui.notice);
    try ui.pumpRemote();
    try std.testing.expect(!ui.busy);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expect(ui.mode == null);
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try std.testing.expect(ui.dirty);
    try std.testing.expect(ui.settingsIdle());
    try std.testing.expectEqual(r.Status.canceled, ui.last_terminal.?.status);
    try std.testing.expectEqual(error.Canceled, ui.last_terminal.?.detail.?);
    try std.testing.expectEqualStrings("Canceled; prior side effects remain", ui.notice);
}

test "one display batch settles a terminal before the next task state and text" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .calling_model, .control_epoch = 15 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(ui.busy);
    var items: [3]session_client.Item = undefined;
    var initialized: usize = 0;
    defer for (items[fake.buffered_index..initialized]) |*item| item.deinit();
    items[0] = try session_client.ownEvent(std.testing.allocator, 15, .{ .finished = (session_client.Terminal{ .status = .canceled, .failure = .canceled }).toRuntime() });
    initialized += 1;
    items[1] = try session_client.ownEvent(std.testing.allocator, 15, .{ .state = .awaiting_permission });
    initialized += 1;
    items[2] = try session_client.ownEvent(std.testing.allocator, 15, .{ .text = "second task" });
    initialized += 1;
    fake.buffered_items = &items;
    fake.snapshot.task_kind = .command;
    // finished(task 1), state(task 2) and text(task 2) share one bounded batch:
    // the terminal must settle first, and the ordered state then adopts task 2.
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 3), fake.buffered_index);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .awaiting_permission), ui.mode);
    try std.testing.expectEqual(session_client.TaskKind.command, ui.remote_kind);
    try std.testing.expectEqualStrings("Attached; task is running", ui.notice);
    // Task 2's body is live content, not task 1's interrupted residue.
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("second task", ui.records.items[ui.draft.?].body.items);
    try std.testing.expect(!ui.records.items[ui.draft.?].interrupted);
}

test "one display batch starts a next task after a terminal when the owner already reports idle" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 18 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(!ui.busy);
    var items: [3]session_client.Item = undefined;
    var initialized: usize = 0;
    defer for (items[fake.buffered_index..initialized]) |*item| item.deinit();
    items[0] = try session_client.ownEvent(std.testing.allocator, 18, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    initialized += 1;
    items[1] = try session_client.ownEvent(std.testing.allocator, 18, .{ .state = .executing_tool });
    initialized += 1;
    items[2] = try session_client.ownEvent(std.testing.allocator, 18, .{ .text = "next task" });
    initialized += 1;
    fake.buffered_items = &items;
    fake.snapshot.task_kind = .command;
    // The terminal settles against an already-idle owner view, and the ordered
    // state in the same batch is still the next task, not task 1 residue.
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 3), fake.buffered_index);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .executing_tool), ui.mode);
    try std.testing.expectEqual(session_client.TaskKind.command, ui.remote_kind);
    try std.testing.expectEqualStrings("Attached; task is running", ui.notice);
    try std.testing.expect(!std.mem.eql(u8, ui.notice, "Remote task ended without a terminal result; reattach to verify"));
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("next task", ui.records.items[ui.draft.?].body.items);
    try std.testing.expect(!ui.records.items[ui.draft.?].interrupted);
}

test "late cancel acknowledgement cannot replace a result awaiting owner idle" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .calling_model, .control_epoch = 17 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    fake.item = try session_client.ownEvent(std.testing.allocator, 17, .{ .finished = (session_client.Terminal{ .status = .failed, .failure = .transport }).toRuntime() });
    try ui.pumpRemote();
    try ui.finishReadyTask();
    try std.testing.expect(ui.busy and ui.remote_terminal_wait);
    try std.testing.expectEqualStrings("Failed", ui.notice);
    // The user's late cancellation still travels to the owner, but its receipt
    // must not replace the handled result while ordered idle is still pending.
    try std.testing.expect(ui.beginAsync(.cancel, .cancel) != null);
    try std.testing.expectEqualStrings("Waiting for session...", ui.notice);
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("Failed", ui.notice);
    try std.testing.expect(ui.busy and ui.remote_terminal_wait);
    try std.testing.expectEqual(r.Status.failed, ui.last_terminal.?.status);
    try std.testing.expectEqual(error.Transport, ui.last_terminal.?.detail.?);
    // Ordered idle then releases the view and keeps the same result.
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try ui.pumpRemote();
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqualStrings("Failed", ui.notice);
    try std.testing.expectEqual(r.Status.failed, ui.last_terminal.?.status);
}

test "remote owner still busy keeps the handled result until ordered next-task state" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .calling_model, .control_epoch = 13 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Task 1: the owner stays busy while its terminal arrives, so the view keeps
    // the busy composer instead of painting an idle prompt it would re-busy.
    try std.testing.expect(ui.busy and ui.remote_observed_busy);
    fake.item = try session_client.ownEvent(std.testing.allocator, 13, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    try ui.pumpRemote();
    try ui.finishReadyTask();
    try std.testing.expect(ui.busy);
    try std.testing.expect(ui.remote_terminal_wait);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expect(ui.remote_observed_busy);
    // A bare busy snapshot proves neither ordering nor a next task.
    fake.snapshot.task_kind = .command;
    try ui.pumpRemote();
    try std.testing.expect(ui.remote_terminal_wait);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    // An ordered state event is the next task: it ends the wait and adopts it
    // from the current owner snapshot rather than from a busy boolean edge.
    fake.item = try session_client.ownEvent(std.testing.allocator, 13, .{ .state = .calling_model });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .calling_model), ui.mode);
    try std.testing.expectEqual(session_client.TaskKind.command, ui.remote_kind);
    try std.testing.expectEqualStrings("Attached; task is running", ui.notice);
}

test "startup attach restores a running partial stream and pending approval" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .awaiting_permission, .control_epoch = 3 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .awaiting_permission), ui.mode);
    fake.item = try session_client.ownEvent(std.testing.allocator, 3, .{ .text = "partial answer" });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("partial answer", ui.records.items[0].body.items);
    fake.item = try session_client.ownEvent(std.testing.allocator, 3, .{ .permission = .{ .id = 5, .tool_name = "bash", .description = "pending approval" } });
    try ui.pumpRemote();
    try std.testing.expect(ui.permission != null);
    try std.testing.expectEqual(@as(u64, 3), ui.permission.?.epoch);
    try std.testing.expectEqualStrings("pending approval", ui.permission.?.description);
}

test "deltas from a replaced control epoch are dropped before display" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 5, .{ .text = "stale controller output" });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(ui.draft == null);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}

test "remote busy close requires confirmation before any backend close or steering" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 2, .session_id = @splat(0) } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    const current = "0000000000000000000000000000000000000000000000000000000000000000";
    try typeDraft(&ui, "/close " ++ current);
    try ui.submit();
    // Busy and attached: nothing is sent yet; the ACKed popup owns the decision.
    try std.testing.expectEqual(@as(usize, 0), fake.manages);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    try std.testing.expect(ui.stop_open);
    try std.testing.expect(ui.stop_close != null);
    try std.testing.expectEqualStrings(current, ui.stop_close.?);

    // The typed --force form is an explicit confirmation and skips the popup.
    ui.closeStop();
    try typeDraft(&ui, "/close --force " ++ current);
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    try std.testing.expectEqual(@as(?std.meta.Tag(session_client.Manage), .close), fake.last_manage);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    try std.testing.expect(!ui.stop_open);
}

test "remote stop gates the owner first and authorizes the adopted queue revision" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 5, .queue_revision = 11, .session_id = @splat(1) } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    try std.testing.expectEqual(@as(u64, 11), ui.stopIdentity().revision);
    try Ui.key(&ui, .cancel);
    try std.testing.expect(ui.stop_open and !ui.stop_danger);
    // Exactly one owner request, before the modal exists, and the adopted
    // snapshot (revision 12) is what the identity authorizes against.
    try std.testing.expectEqual(@as(usize, 1), fake.confirmings);
    try std.testing.expect(fake.last_confirming_active);
    try std.testing.expectEqual(@as(u64, 5), fake.last_confirming_epoch);
    try std.testing.expectEqual(@as(u64, 12), fake.last_confirming_revision);
    try std.testing.expectEqual(@as(u64, 12), ui.stop_identity.?.revision);
    try std.testing.expect(ui.queueSnapshot().confirming);
    // Esc releases the barrier without asking the owner to clear the queue.
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(usize, 2), fake.confirmings);
    try std.testing.expect(!fake.last_confirming_active);
    try std.testing.expectEqual(@as(usize, 0), fake.cancel_clears);
    try std.testing.expect(!ui.stop_open and ui.stop_identity == null);
}

test "remote stop requested for a replaced owner is never unbound by a late close" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 5, .queue_revision = 3, .session_id = @splat(2) } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    try Ui.key(&ui, .cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.confirmings);
    // A takeover replaced the epoch and also ended the busy task: the revision
    // and busy changes alone must not stop Esc from releasing the old barrier.
    fake.snapshot.control_epoch = 6;
    fake.snapshot.busy = false;
    ui.remote_epoch = 6;
    ui.busy = false;
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(usize, 1), fake.confirmings);
    try std.testing.expect(!ui.stop_open);

    // Opening a modal and losing the owner before Esc must also stay silent.
    fake.snapshot.busy = true;
    ui.busy = true;
    try Ui.key(&ui, .cancel);
    try std.testing.expectEqual(@as(usize, 2), fake.confirmings);
    fake.snapshot.control_epoch = 7;
    fake.snapshot.session_id = @splat(3);
    ui.remote_epoch = 7;
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(usize, 2), fake.confirmings);
    try std.testing.expect(!ui.stop_open);
}

test "Codex device login binds generation and publishes success once" {
    const Owner = struct {
        state: Connection.State = .{ .runtime = null, .model = "", .base_url = "" },
        starts: usize = 0,
        cancels: usize = 0,
        canceled_generation: u64 = 0,
        fn current(raw: *anyopaque) Connection.State {
            return @as(*@This(), @ptrCast(@alignCast(raw))).state;
        }
        fn configure(_: *anyopaque, _: []const u8) !void {}
        fn login(raw: *anyopaque, action: corecodex.Action, generation: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (action) {
                .start => {
                    self.starts += 1;
                    try std.testing.expectEqual(@as(u64, 0), generation);
                },
                .cancel => {
                    self.cancels += 1;
                    self.canceled_generation = generation;
                },
            }
        }
    };
    var owner: Owner = .{};
    owner.state.codex_login = .{ .generation = 4, .status = .succeeded };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = .{ .context = &owner, .current_fn = Owner.current, .configure_fn = Owner.configure, .codex_login_fn = Owner.login };
    ui.startCodexLogin();
    try std.testing.expect(ui.codex_open and ui.codex_generation == null and owner.starts == 1);
    ui.observeCodexLogin(); // Previous success cannot complete the new attempt.
    try std.testing.expect(ui.codex_open and ui.records.items.len == 0);
    owner.state.codex_login = .{ .generation = 5, .status = .pending };
    @memcpy(owner.state.codex_login.code[0..7], "ABC-123");
    owner.state.codex_login.code_len = 7;
    ui.observeCodexLogin();
    try std.testing.expectEqual(@as(?u64, 5), ui.codex_generation);
    ui.dirty = false;
    ui.display_changed = false;
    ui.observeCodexLogin();
    try std.testing.expect(!ui.dirty and !ui.display_changed);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, corecodex.verification_url) != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "ABC-123") != null);
    discardFixtureFrame(&ui);
    owner.state.codex_login = .{ .generation = 4, .status = .succeeded };
    ui.observeCodexLogin();
    try std.testing.expect(ui.codex_open);
    owner.state.codex_login = .{ .generation = 5, .status = .succeeded };
    ui.observeCodexLogin();
    try std.testing.expect(!ui.codex_open and ui.records.items.len == 1);
    try std.testing.expectEqualStrings("OpenAI Codex connected", ui.records.items[0].body.items);
    ui.observeCodexLogin();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    ui.startCodexLogin();
    ui.cancelCodexLogin(); // Wait for the new generation before canceling.
    try std.testing.expectEqual(@as(usize, 0), owner.cancels);
    owner.state.codex_login = .{ .generation = 6, .status = .pending };
    ui.observeCodexLogin();
    try std.testing.expect(!ui.codex_open and owner.cancels == 1 and owner.canceled_generation == 6);

    // Picker confirmation requires a completely acknowledged fresh frame.
    ui.openProviderPicker();
    for (ui.provider_choices.items[0..ui.provider_choices.len], 0..) |choice, index| {
        if (choice == .provider and choice.provider == .openai_codex) ui.provider_picker.selected = index;
    }
    try ui.providerKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), owner.starts);
    ui.provider_picker.markPaste();
    try ui.providerKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), owner.starts);
    ui.provider_picker.clear();
    try ui.draw();
    try ui.providerKey(.enter); // pending frame does not authorize
    try std.testing.expectEqual(@as(usize, 2), owner.starts);
    testAcknowledgeFullFrame(&ui);
    try ui.providerKey(.enter);
    try std.testing.expect(ui.codex_open and !ui.secret_mode and owner.starts == 3);
    owner.state.codex_login = .{ .generation = 7, .status = .pending };
    ui.observeCodexLogin();
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(u64, 7), owner.canceled_generation);
    _ = try ui.editor.insert("/login openai-codex");
    try ui.submit();
    try std.testing.expect(ui.codex_open and !ui.secret_mode and owner.starts == 4);
}

test "remote codex login opens only after the owner receipt and cancels its exact generation" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6, .session_id = @splat(3) } };
    // A previous completed login must never open or complete the next attempt.
    fake.codex = .{ .generation = 4, .status = .succeeded };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    ui.startCodexLogin();
    // Queue admission is not owner acceptance: no panel, no bound generation.
    try std.testing.expect(ui.codex_opening and !ui.codex_open and ui.codex_generation == null);
    try std.testing.expectEqual(@as(usize, 1), actions.next);
    try std.testing.expectEqual(corecodex.Action.start, actions.requests[0].?.action.codex_login.action);
    try std.testing.expectEqual(@as(u64, 0), actions.requests[0].?.action.codex_login.generation);
    ui.observeCodexLogin();
    try std.testing.expect(!ui.codex_open and ui.records.items.len == 0);

    // Esc before the receipt defers cancellation instead of guessing a generation.
    try Ui.key(&ui, .escape);
    try std.testing.expect(ui.codex_cancel_waiting and !ui.codex_open);
    try std.testing.expectEqual(@as(usize, 1), actions.next);

    // The owner accepts the start and publishes the pending attempt; the
    // deferred Esc then travels as a typed cancel for that exact generation.
    fake.codex = .{ .generation = 5, .status = .pending };
    @memcpy(fake.codex.code[0..7], "ABC-123");
    fake.codex.code_len = 7;
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expect(ui.codex_open and ui.codex_generation == 5);
    try std.testing.expect(ui.presentationWaiting());
    try std.testing.expectEqual(@as(usize, 2), actions.next);
    try std.testing.expectEqual(corecodex.Action.cancel, actions.requests[1].?.action.codex_login.action);
    try std.testing.expectEqual(@as(u64, 5), actions.requests[1].?.action.codex_login.generation);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);

    // Another generation's success is not this attempt's success.
    fake.codex = .{ .generation = 6, .status = .succeeded };
    ui.observeCodexLogin();
    try std.testing.expect(ui.codex_open and ui.codex_generation == 5);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);

    // A rejected cancel keeps both the panel and its generation.
    actions.complete(.none, error.Transport, false);
    ui.pumpAsync();
    try std.testing.expect(ui.codex_open and ui.codex_generation == 5);
    try std.testing.expectEqualStrings("Could not cancel OpenAI Codex login", ui.notice);

    // Cancel admission is not closure either: only the receipt for THIS
    // generation closes the panel, and it never publishes a success.
    fake.codex = .{ .generation = 5, .status = .pending };
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(usize, 3), actions.next);
    try std.testing.expect(ui.codex_open and ui.codex_generation == 5);
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expect(!ui.codex_open and ui.codex_generation == null);
    try std.testing.expect(!ui.presentationWaiting());
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);

    // A rejected start clears the opening state and never shows a panel.
    ui.startCodexLogin();
    try std.testing.expect(ui.codex_opening and !ui.codex_open);
    actions.complete(.none, error.PublicationUnavailable, false);
    ui.pumpAsync();
    try std.testing.expect(!ui.codex_opening and !ui.codex_open and ui.codex_generation == null);
    try std.testing.expectEqualStrings("OpenAI Codex device login unavailable", ui.notice);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);

    // A superseded receipt retires the placeholder without a stale success.
    ui.startCodexLogin();
    try std.testing.expect(ui.codex_opening and !ui.codex_open);
    actions.complete(.none, null, true);
    ui.pumpAsync();
    try std.testing.expect(!ui.codex_opening and !ui.codex_open and ui.codex_generation == null);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}

test "local stop keeps gating the UI inbox without a remote barrier request" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    try Ui.key(&ui, .cancel);
    try std.testing.expect(ui.stop_open and ui.inbox.snapshot().confirming);
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.stop_open and !ui.inbox.snapshot().confirming);
    try std.testing.expect(!cancel.isRequested());
}
