//! Pure UI-side remote session interface. No daemon, socket, Runtime or JSON
//! dependency: a client adapter (owned by the CLI/host backend) implements this
//! vtable and the TUI treats it as the sole owner of tasks, queues, approvals
//! and checkpoints. Every call is synchronous and must copy borrowed text
//! before returning; nothing here holds a Runtime pointer or a process-local
//! callback across the boundary.
//!
//! Wire-safety rules for the adapter:
//! - `r.Event` values are constructed locally from typed protocol fields; raw
//!   `anyerror` values never cross the wire. Use `Failure` for the wire and
//!   `Terminal.toRuntime` to build the typed terminal event.
//! - `r.Event.permission.interrupt` is a process-local Inbox pointer and is
//!   always cleared by `ownEvent`; adapters must not populate it.
//! - The submitted prompt is rendered once by the TUI after `submit` succeeds.
//!   The backend must not echo it as `user_committed`; that event is reserved
//!   for queued steering/follow-up text the worker actually commits.
//! - `poll` hands ownership to the caller; the TUI applies non-terminal events
//!   directly while the item is alive and routes only finished through the local
//!   Bridge completion path, then frees the item.
const std = @import("std");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const inbox = @import("../core/inbox.zig");

pub const TaskKind = enum { prompt, compact, command };
pub const QueueKind = inbox.Kind;
pub const max_item_bytes = 64 * 1024;
pub const block_limit = 256;
pub const max_previews = 3;
pub const max_notice_bytes = 64 * 1024;

const Storage = []align(@alignOf(p.Block)) u8;

/// Wire-safe task failure detail. `other` is a generic remote failure, never a
/// fabricated local error name. `toError` restores the exact values the local
/// TUI already classifies (poisoning, policy pauses, compaction notices).
pub const Failure = enum {
    other,
    cleanup_failed,
    unsafe_to_continue,
    input_budget_exceeded,
    unknown_input_price_threshold,
    input_budget_summary_failed,
    decision_unavailable,
    subagent_interaction_required,
    no_compaction_candidate,
    canceled,
    transport,
    timeout,
    protocol,
    rejected,

    pub fn fromError(err: anyerror) Failure {
        return switch (err) {
            error.CleanupFailed => .cleanup_failed,
            error.UnsafeToContinue => .unsafe_to_continue,
            error.InputBudgetExceeded => .input_budget_exceeded,
            error.UnknownInputPriceThreshold => .unknown_input_price_threshold,
            error.InputBudgetSummaryFailed => .input_budget_summary_failed,
            error.DecisionUnavailable => .decision_unavailable,
            error.SubagentInteractionRequired => .subagent_interaction_required,
            error.NoCompactionCandidate => .no_compaction_candidate,
            error.Canceled => .canceled,
            error.ConnectionLost, error.Transport => .transport,
            error.Timeout => .timeout,
            error.ProtocolError => .protocol,
            error.Rejected => .rejected,
            else => .other,
        };
    }

    /// Only `other` degrades to a generic remote error; every other code keeps
    /// its local classification.
    pub fn toError(self: Failure) ?anyerror {
        return switch (self) {
            .cleanup_failed => error.CleanupFailed,
            .unsafe_to_continue => error.UnsafeToContinue,
            .input_budget_exceeded => error.InputBudgetExceeded,
            .unknown_input_price_threshold => error.UnknownInputPriceThreshold,
            .input_budget_summary_failed => error.InputBudgetSummaryFailed,
            .decision_unavailable => error.DecisionUnavailable,
            .subagent_interaction_required => error.SubagentInteractionRequired,
            .no_compaction_candidate => error.NoCompactionCandidate,
            .canceled => error.Canceled,
            .transport => error.Transport,
            .timeout => error.Timeout,
            .protocol => error.ProtocolError,
            .rejected => error.Rejected,
            .other => error.RemoteFailure,
        };
    }
};

/// Typed terminal result. Status plus a wire code plus provider metadata; no
/// pointer, no raw error value and no local usage borrow.
pub const Terminal = struct {
    status: r.Status = .failed,
    failure: Failure = .other,
    model_failure: ?p.FailureKind = null,
    http_status: ?u16 = null,
    decision_failure: ?@import("../core/decision.zig").Diagnostic = null,
    usage: r.UsageTotals = .{},
    context: ?r.ContextSnapshot = null,

    pub fn toRuntime(self: Terminal) r.Terminal {
        return .{
            .status = self.status,
            .detail = if (self.status == .success) null else self.failure.toError(),
            .model_failure = self.model_failure,
            .http_status = self.http_status,
            .decision_failure = self.decision_failure,
            .usage = self.usage,
            .context_snapshot = self.context,
        };
    }
};

/// One polled display event with independently owned storage. The TUI applies
/// non-terminal events directly while this item lives; finished alone goes
/// through the local Bridge terminal/completion path.
pub const Item = struct {
    /// Control epoch the event belongs to. Stale events are still displayed but
    /// their approval ids cannot authorize a newer controller epoch.
    epoch: u64 = 0,
    /// Live delivery watermark; zero denotes a non-live item.
    delivery_sequence: u64 = 0,
    /// First raw stream position represented by this item's payload. Zero means
    /// a single event or a fallback where `delivery_sequence` is the first too.
    /// After coalescing it is the OLDEST hidden/raw event, so selective ACK can
    /// prove the whole span instead of leaving phantom sequences retained.
    delivery_first_sequence: u64 = 0,
    delivery_epoch: u64 = 0,
    event: r.Event,
    display_truncated: bool = false,
    canonical_complete: bool = true,
    /// Local adapter metadata only: this item came from an owned history page,
    /// not from the live delta stream. It is never a Runtime or wire event
    /// field, and the TUI decides what a replay means for its own history.
    history_replay: bool = false,
    /// Local adapter metadata only: the first item of a history snapshot that
    /// replaces the previous page, so a consumer can reset before replaying.
    history_reset: bool = false,
    /// An authoritative streamed baseline replaces the transcript. A baseline
    /// frozen before an accepted local submit must not erase its newly shown row.
    history_display_reset: bool = false,
    storage: Storage,
    allocator: std.mem.Allocator,

    /// Append a still-unconsumed live body run. No event is dropped: only the
    /// obsolete intermediate boundaries disappear. Ownership stays exclusive,
    /// growth is amortized and bounded, and allocation failure leaves both
    /// items intact. History, truncation and semantic barriers never merge.
    pub fn appendText(self: *Item, next: *const Item, byte_limit: usize) !bool {
        if (self.epoch != next.epoch or self.delivery_epoch != next.delivery_epoch or
            (self.delivery_sequence == 0) != (next.delivery_sequence == 0) or
            self.history_replay or next.history_replay or
            self.history_reset or next.history_reset or self.history_display_reset or next.history_display_reset or
            self.display_truncated or next.display_truncated or !self.canonical_complete or !next.canonical_complete or
            std.meta.activeTag(self.event) != std.meta.activeTag(next.event)) return false;
        const live = self.delivery_sequence != 0;
        if (live) {
            // A merged payload represents ONE contiguous raw interval. Gaps and
            // overlaps are refused conservatively instead of inventing coverage.
            const first_next = if (next.delivery_first_sequence != 0) next.delivery_first_sequence else next.delivery_sequence;
            if (first_next != self.delivery_sequence +% 1) return false;
        }
        const left = switch (self.event) {
            .text => |bytes| bytes,
            .reasoning => |bytes| bytes,
            else => return false,
        };
        const right = switch (next.event) {
            .text => |bytes| bytes,
            .reasoning => |bytes| bytes,
            else => unreachable,
        };
        // A held CR spans two raw events: merging them would let one display
        // target swallow the earlier event's sequence and hide the boundary
        // from selective ACK proof. Both sides must stay individually ownable.
        if (std.mem.indexOfScalar(u8, left, '\r') != null or std.mem.indexOfScalar(u8, right, '\r') != null) return false;
        const limit = @min(max_item_bytes, byte_limit);
        if (left.len > limit or right.len > limit - left.len) return false;
        const len = left.len + right.len;
        if (len > self.storage.len) {
            const capacity = @min(limit, @max(len, @max(256, self.storage.len * 2)));
            self.storage = try self.allocator.realloc(self.storage, capacity);
        }
        @memcpy(self.storage[left.len..len], right);
        switch (self.event) {
            .text => self.event = .{ .text = self.storage[0..len] },
            .reasoning => self.event = .{ .reasoning = self.storage[0..len] },
            else => unreachable,
        }
        if (live) {
            // Materialize the span start before the newest position replaces the
            // left sequence; otherwise the merged item would claim to begin at
            // its end and hide every raw event in between.
            if (self.delivery_first_sequence == 0) self.delivery_first_sequence = self.delivery_sequence;
        }
        self.delivery_sequence = next.delivery_sequence;
        return true;
    }

    pub fn deinit(self: *Item) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

/// Bounded, caller-owned deep copy of one typed event. Adapters build an
/// `r.Event` from their own typed snapshot/delta and call this before returning
/// it from `poll`; thereafter no backend memory is borrowed. The local history
/// markers stay false here: only an adapter that read an owned history page
/// sets them on the items it produced.
pub fn ownEvent(a: std.mem.Allocator, epoch: u64, event: r.Event) !Item {
    var measure = Copy{};
    _ = measure.event(event);
    const storage = try a.alignedAlloc(u8, .of(p.Block), measure.used);
    errdefer a.free(storage);
    var copy = Copy{ .storage = storage };
    const owned = copy.event(event);
    return .{
        .epoch = epoch,
        .event = owned,
        .display_truncated = copy.clipped,
        .canonical_complete = copy.canonical_complete,
        .storage = storage,
        .allocator = a,
    };
}

const Copy = struct {
    storage: ?Storage = null,
    used: usize = 0,
    clipped: bool = false,
    canonical_complete: bool = true,

    fn text(self: *Copy, src: []const u8) []const u8 {
        const room = if (self.used < max_item_bytes) max_item_bytes - self.used else 0;
        var n = @min(src.len, room);
        if (n < src.len) {
            while (n > 0 and (src[n] & 0xc0) == 0x80) n -= 1;
            self.clipped = true;
        }
        const start = self.used;
        self.used += n;
        if (self.storage) |buf| {
            @memcpy(buf[start..][0..n], src[0..n]);
            return buf[start..][0..n];
        }
        return "";
    }

    fn field(self: *Copy, src: ?@import("../core/tool_preview.zig").Field) ?@import("../core/tool_preview.zig").Field {
        const value = src orelse return null;
        const before = self.used;
        const copied = self.text(value.text);
        return .{ .text = copied, .truncated = value.truncated or self.used - before < value.text.len };
    }

    fn block(self: *Copy, b: p.Block) p.Block {
        return switch (b) {
            .text => |s| .{ .text = self.text(s) },
            .reasoning => |s| .{ .reasoning = self.text(s) },
            .tool_call => |c| .{ .tool_call = .{ .id = self.text(c.id), .name = self.text(c.name), .arguments = self.text(c.arguments), .item_id = if (c.item_id) |s| self.text(s) else null } },
            .tool_result => |v| blk: {
                var c = v;
                c.call_id = self.text(v.call_id);
                c.text = self.text(v.text);
                break :blk .{ .tool_result = c };
            },
        };
    }

    fn event(self: *Copy, e: r.Event) r.Event {
        return switch (e) {
            .text => |s| .{ .text = self.text(s) },
            .reasoning => |s| .{ .reasoning = self.text(s) },
            .user_committed => |v| .{ .user_committed = .{ .id = v.id, .text = self.text(v.text) } },
            .tool_preview => |v| .{ .tool_preview = .{ .index = v.index, .arguments = self.text(v.arguments), .write_file = v.write_file, .argument_bytes = v.argument_bytes } },
            .tool_view => |v| blk: {
                var c = v;
                c.name = self.text(v.name);
                c.fields.path = self.field(v.fields.path);
                c.fields.command = self.field(v.fields.command);
                c.fields.action = self.field(v.fields.action);
                c.fields.topic = self.field(v.fields.topic);
                c.fields.task = self.field(v.fields.task);
                c.fields.id = self.field(v.fields.id);
                break :blk .{ .tool_view = c };
            },
            // Never carry a process-local Inbox pointer across the boundary.
            .permission => |v| .{ .permission = .{ .id = v.id, .tool_name = self.text(v.tool_name), .description = self.text(v.description) } },
            .tool_started => |v| blk: {
                var c = v;
                c.name = self.text(v.name);
                break :blk .{ .tool_started = c };
            },
            .tool_result => |v| blk: {
                var c = v;
                c.name = self.text(v.name);
                c.result.text = self.text(v.result.text);
                break :blk .{ .tool_result = c };
            },
            .assistant_committed => |blocks| blk: {
                const n: usize = @min(blocks.len, block_limit);
                self.canonical_complete = blocks.len == n;
                self.clipped = self.clipped or !self.canonical_complete;
                self.used = n * @sizeOf(p.Block);
                var dst: []p.Block = &.{};
                if (self.storage) |buf| dst = @as([*]p.Block, @ptrCast(buf.ptr))[0..n];
                for (blocks[0..n], 0..) |b, i| {
                    const cloned = self.block(b);
                    if (self.storage != null) dst[i] = cloned;
                }
                break :blk .{ .assistant_committed = dst };
            },
            else => e,
        };
    }
};

pub const QueuePreview = struct {
    id: u64 = 0,
    kind: QueueKind = .steering,
    text: []const u8 = "",
};

/// Borrowed owner snapshot. Every slice is client-owned and valid until the
/// adapter documents otherwise (normally until the next snapshot update); the
/// TUI copies what it keeps. No Runtime, socket or callback lives here.
pub const Snapshot = struct {
    available: bool = false,
    attached: bool = false,
    busy: bool = false,
    mode: ?r.State = null,
    task_kind: TaskKind = .prompt,
    session_id: ?[32]u8 = null,
    session_label: ?[]const u8 = null,
    launcher_dir: ?[]const u8 = null,
    control_epoch: u64 = 0,
    queue_revision: u64 = 0,
    queue_paused: bool = false,
    steering: usize = 0,
    follow_up: usize = 0,
    newest_id: ?u64 = null,
    newest_bytes: usize = 0,
    previews: []const QueuePreview = &.{},
    running_sessions: usize = 0,
};

/// Session-management request. `id`, `cd` and `close` arguments are borrowed for
/// the duration of `manage` only; the adapter must copy anything it retains.
pub const Manage = union(enum) {
    list: struct { running_only: bool = false, page: usize = 0 },
    cd: []const u8,
    attach: struct { id: []const u8, takeover: bool = false },
    detach,
    exit,
    close: struct { id: []const u8, force: bool = false },
};

/// Management result. `notice`/`listing` are allocated with the allocator passed
/// to `manage` and freed by `Outcome.deinit`. `switched` asks the TUI to clear
/// the old display/approval/queue/input-history state and adopt the new epoch;
/// `exit` asks the frontend to leave without touching the daemon session.
pub const Outcome = struct {
    notice: ?[]u8 = null,
    listing: ?[]u8 = null,
    switched: bool = false,
    exit: bool = false,

    pub fn deinit(self: *Outcome, a: std.mem.Allocator) void {
        if (self.notice) |value| a.free(value);
        if (self.listing) |value| a.free(value);
        self.* = undefined;
    }
};

pub const VTable = struct {
    /// Stable address owned by the adapter; re-read every loop tick.
    snapshot_fn: *const fn (*anyopaque) *const Snapshot,
    /// Copy `text` before returning. Rejects while another task owns the session.
    submit_fn: *const fn (*anyopaque, u64, TaskKind, []const u8) anyerror!void,
    /// Next display event, or null. Ownership passes to the caller.
    poll_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror!?Item,
    /// True only when poll can consume locally buffered data (an owned item or
    /// complete received frame), without socket I/O. Pure, nonblocking; lets the
    /// UI drain a bounded batch independently of the receive task.
    buffered_fn: ?*const fn (*anyopaque) bool = null,
    /// Nonblocking admission of an epoch-bound delivery prefix watermark.
    acknowledge_fn: ?*const fn (*anyopaque, u64, u64) anyerror!void = null,
    /// Nonblocking admission of one already-displayed inclusive range.
    /// `first == 0` is the prefix `[0, last]`. A missing callback stays
    /// Unsupported: it is never replaced by a cumulative ACK across a hole.
    acknowledge_range_fn: ?*const fn (*anyopaque, u64, u64, u64) anyerror!void = null,
    /// Cancel the current task only; the connection itself stays attached.
    cancel_fn: *const fn (*anyopaque, u64) anyerror!void,
    /// Cancel the current task and clear the pending queue for `revision`.
    cancel_clear_fn: *const fn (*anyopaque, u64, u64) anyerror!void,
    /// Suspend (`active=true`) or resume automatic claims while a local stop or
    /// approval modal owns the decision. Optional so unrelated adapters and
    /// fixtures keep compiling; without it the owner barrier stays local-only.
    set_confirming_fn: ?*const fn (*anyopaque, u64, bool) anyerror!void = null,
    /// Answer one approval id in the control epoch it was displayed in.
    approve_fn: *const fn (*anyopaque, u64, u64, r.Decision) anyerror!void,
    /// Queue steering/follow-up text for this epoch.
    enqueue_fn: *const fn (*anyopaque, u64, QueueKind, []const u8) anyerror!void,
    /// Withdraw one pending queue entry into caller-owned text, or null when it
    /// was already consumed.
    withdraw_fn: *const fn (*anyopaque, std.mem.Allocator, u64, u64) anyerror!?[]u8,
    /// Explicitly resume a paused queue.
    queue_resume_fn: *const fn (*anyopaque, u64) anyerror!void,
    /// Run a session-management request; the adapter owns path validation,
    /// attach/takeover epochs, listing pagination and close confirmation needs.
    manage_fn: *const fn (*anyopaque, std.mem.Allocator, Manage) anyerror!Outcome,
    /// Release this view/control without canceling the task. Called once when
    /// the TUI exits or the connection ends; must not fail or block forever.
    detach_fn: *const fn (*anyopaque) void,
};

pub const Client = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub fn snapshot(self: Client) *const Snapshot {
        return self.vtable.snapshot_fn(self.context);
    }
    pub fn submit(self: Client, epoch: u64, kind: TaskKind, text: []const u8) !void {
        try self.vtable.submit_fn(self.context, epoch, kind, text);
    }
    pub fn poll(self: Client, a: std.mem.Allocator) !?Item {
        return self.vtable.poll_fn(self.context, a);
    }
    pub fn buffered(self: Client) bool {
        const ready = self.vtable.buffered_fn orelse return false;
        return ready(self.context);
    }
    pub fn acknowledge(self: Client, epoch: u64, sequence: u64) !void {
        if (sequence == 0) return;
        if (self.vtable.acknowledge_range_fn) |range| {
            try range(self.context, epoch, 0, sequence);
            return;
        }
        const ack = self.vtable.acknowledge_fn orelse return error.Unsupported;
        try ack(self.context, epoch, sequence);
    }
    pub fn acknowledgeRange(self: Client, epoch: u64, first: u64, last: u64) !void {
        if (last == 0) return;
        if (first != 0 and first > last) return error.InvalidInput;
        const range = self.vtable.acknowledge_range_fn orelse return error.Unsupported;
        try range(self.context, epoch, first, last);
    }
    pub fn cancel(self: Client, epoch: u64) !void {
        try self.vtable.cancel_fn(self.context, epoch);
    }
    pub fn cancelClear(self: Client, epoch: u64, revision: u64) !void {
        try self.vtable.cancel_clear_fn(self.context, epoch, revision);
    }
    pub fn setConfirming(self: Client, epoch: u64, active: bool) !void {
        const set = self.vtable.set_confirming_fn orelse return error.Unsupported;
        try set(self.context, epoch, active);
    }
    pub fn approve(self: Client, epoch: u64, permission_id: u64, decision: r.Decision) !void {
        try self.vtable.approve_fn(self.context, epoch, permission_id, decision);
    }
    pub fn enqueue(self: Client, epoch: u64, kind: QueueKind, text: []const u8) !void {
        try self.vtable.enqueue_fn(self.context, epoch, kind, text);
    }
    pub fn withdraw(self: Client, a: std.mem.Allocator, epoch: u64, id: u64) !?[]u8 {
        return self.vtable.withdraw_fn(self.context, a, epoch, id);
    }
    pub fn queueResume(self: Client, epoch: u64) !void {
        try self.vtable.queue_resume_fn(self.context, epoch);
    }
    pub fn manage(self: Client, a: std.mem.Allocator, request: Manage) !Outcome {
        return self.vtable.manage_fn(self.context, a, request);
    }
    pub fn detach(self: Client) void {
        self.vtable.detach_fn(self.context);
    }
};

/// User-facing notice for a failed client call. Static strings only.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.StaleControl => "Connection is no longer the controller; /attach --takeover or reconnect",
        error.SessionNotFound => "Session not found",
        error.InvalidPath => "Directory is not accessible; launcher unchanged",
        error.Busy => "Session is busy",
        error.QueueFull => "Queue is full; draft kept",
        error.QueueEmpty => "Message already consumed; nothing withdrawn",
        error.QueueChanged => "Queue changed; try again",
        error.PermissionExpired => "Permission expired",
        error.InvalidInput => "Input rejected",
        error.Unavailable => "Session unavailable; /exit and reconnect",
        error.Transport, error.ConnectionLost => "Connection lost; the task was not canceled",
        error.ProtocolMismatch => "Session worker speaks an incompatible Thin protocol version; restart Thin to start a compatible worker",
        error.OutOfMemory => "Out of memory",
        else => "Remote session request failed",
    };
}

test "body append keeps all bytes and stops at semantic ownership and size barriers" {
    const a = std.testing.allocator;
    var body = try ownEvent(a, 7, .{ .text = "" });
    defer body.deinit();
    var next = try ownEvent(a, 7, .{ .text = "中🙂" });
    defer next.deinit();
    for (0..1600) |_| try std.testing.expect(try body.appendText(&next, max_item_bytes));
    try std.testing.expectEqual(@as(usize, 1600 * "中🙂".len), body.event.text.len);
    var offset: usize = 0;
    while (offset < body.event.text.len) : (offset += "中🙂".len)
        try std.testing.expectEqualStrings("中🙂", body.event.text[offset..][0.."中🙂".len]);
    const len = body.event.text.len;
    try std.testing.expect(!try body.appendText(&next, len));
    next.epoch = 8;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.epoch = 7;
    next.history_replay = true;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.history_replay = false;
    next.history_reset = true;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.history_reset = false;
    next.history_display_reset = true;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.history_display_reset = false;
    next.display_truncated = true;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.display_truncated = false;
    next.canonical_complete = false;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.canonical_complete = true;
    const reasoning_bytes = next.event.text;
    next.event = .{ .reasoning = reasoning_bytes };
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    var thought = try ownEvent(a, 7, .{ .reasoning = "think:" });
    defer thought.deinit();
    try std.testing.expect(try thought.appendText(&next, max_item_bytes));
    try std.testing.expectEqualStrings("think:中🙂", thought.event.reasoning);
    try std.testing.expectEqual(len, body.event.text.len);

    // A held CR is a raw-source boundary: merging either side would hide the
    // earlier event's own sequence from selective ACK proof.
    var cr_head = try ownEvent(a, 7, .{ .text = "line\r" });
    defer cr_head.deinit();
    var cr_tail = try ownEvent(a, 7, .{ .text = "\nnext" });
    defer cr_tail.deinit();
    try std.testing.expect(!try cr_head.appendText(&cr_tail, max_item_bytes));
    try std.testing.expectEqualStrings("line\r", cr_head.event.text);
    try std.testing.expectEqualStrings("\nnext", cr_tail.event.text);
    var plain_head = try ownEvent(a, 7, .{ .text = "plain" });
    defer plain_head.deinit();
    var cr_inside = try ownEvent(a, 7, .{ .text = "a\rb" });
    defer cr_inside.deinit();
    try std.testing.expect(!try plain_head.appendText(&cr_inside, max_item_bytes));
    try std.testing.expectEqualStrings("plain", plain_head.event.text);
}

test "live body append retains latest delivery sequence and rejects barriers" {
    const a = std.testing.allocator;
    var first = try ownEvent(a, 1, .{ .text = "a" });
    defer first.deinit();
    var second = try ownEvent(a, 1, .{ .text = "b" });
    defer second.deinit();
    first.delivery_epoch = 2;
    first.delivery_sequence = 10;
    second.delivery_epoch = 3;
    second.delivery_sequence = 11;
    try std.testing.expect(!try first.appendText(&second, max_item_bytes));
    second.delivery_epoch = 2;
    second.delivery_sequence = 0;
    try std.testing.expect(!try first.appendText(&second, max_item_bytes));
    second.delivery_sequence = 9;
    try std.testing.expect(!try first.appendText(&second, max_item_bytes));
    second.delivery_sequence = 11;
    try std.testing.expect(try first.appendText(&second, max_item_bytes));
    try std.testing.expectEqual(@as(u64, 11), first.delivery_sequence);
    // The merged item starts at its own first live position, not at 11.
    try std.testing.expectEqual(@as(u64, 10), first.delivery_first_sequence);
    try std.testing.expectEqualStrings("ab", first.event.text);
}

test "coalesced live spans keep every raw sequence and refuse gaps or overlaps" {
    const a = std.testing.allocator;
    var span = try ownEvent(a, 1, .{ .reasoning = "r2" });
    defer span.deinit();
    span.delivery_epoch = 4;
    span.delivery_sequence = 2;
    span.delivery_first_sequence = 2;
    var initial = try ownEvent(a, 1, .{ .text = "x" });
    defer initial.deinit();
    try std.testing.expectEqual(@as(u64, 0), initial.delivery_first_sequence);
    var next = try ownEvent(a, 1, .{ .reasoning = "r3" });
    defer next.deinit();
    next.delivery_epoch = 4;
    next.delivery_sequence = 3;
    next.delivery_first_sequence = 3;
    try std.testing.expect(try span.appendText(&next, max_item_bytes));
    try std.testing.expectEqual(@as(u64, 2), span.delivery_first_sequence);
    try std.testing.expectEqual(@as(u64, 3), span.delivery_sequence);
    try std.testing.expectEqualStrings("r2r3", span.event.reasoning);
    // A gap (5) and an overlap (3) are refused; only contiguous raw coverage
    // coalesces. A single event that omits `first` falls back to its sequence.
    next.delivery_sequence = 5;
    next.delivery_first_sequence = 5;
    try std.testing.expect(!try span.appendText(&next, max_item_bytes));
    next.delivery_sequence = 3;
    next.delivery_first_sequence = 3;
    try std.testing.expect(!try span.appendText(&next, max_item_bytes));
    next.delivery_sequence = 4;
    next.delivery_first_sequence = 0;
    try std.testing.expect(try span.appendText(&next, max_item_bytes));
    try std.testing.expectEqual(@as(u64, 2), span.delivery_first_sequence);
    try std.testing.expectEqual(@as(u64, 4), span.delivery_sequence);
    // A different epoch never merges, so a span cannot cross authority.
    next.delivery_epoch = 5;
    next.delivery_sequence = 5;
    next.delivery_first_sequence = 5;
    try std.testing.expect(!try span.appendText(&next, max_item_bytes));
}

test "body append allocation failure preserves both owned inputs" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2, .resize_fail_index = 0 });
    const a = failing.allocator();
    var first = try ownEvent(a, 1, .{ .text = "first" });
    defer first.deinit();
    var second = try ownEvent(a, 1, .{ .text = "second" });
    defer second.deinit();
    try std.testing.expectError(error.OutOfMemory, first.appendText(&second, max_item_bytes));
    try std.testing.expectEqualStrings("first", first.event.text);
    try std.testing.expectEqualStrings("second", second.event.text);
}

test "setConfirming is optional and refuses without an adapter" {
    var vt: VTable = .{
        .snapshot_fn = undefined,
        .submit_fn = undefined,
        .poll_fn = undefined,
        .cancel_fn = undefined,
        .cancel_clear_fn = undefined,
        .approve_fn = undefined,
        .enqueue_fn = undefined,
        .withdraw_fn = undefined,
        .queue_resume_fn = undefined,
        .manage_fn = undefined,
        .detach_fn = undefined,
    };
    var context: u8 = 0;
    const client: Client = .{ .context = &context, .vtable = &vt };
    try std.testing.expectError(error.Unsupported, client.setConfirming(1, true));
}

test "owned events deep-copy text and drop local inbox pointers" {
    const a = std.testing.allocator;
    var description = [_]u8{ 'd', 'e', 's', 'c' };
    var local_inbox: r.Inbox = .{};
    var item = try ownEvent(a, 7, .{ .permission = .{ .id = 3, .tool_name = "bash", .description = &description, .interrupt = &local_inbox } });
    defer item.deinit();
    @memset(&description, 'x');
    try std.testing.expectEqual(@as(u64, 7), item.epoch);
    try std.testing.expectEqual(@as(u64, 3), item.event.permission.id);
    try std.testing.expectEqualStrings("desc", item.event.permission.description);
    try std.testing.expect(item.event.permission.interrupt == null);
}

test "owned assistant blocks stay canonical while text is bounded" {
    const a = std.testing.allocator;
    var text = [_]u8{ 'a', 'b', 'c' };
    const blocks = [_]p.Block{ .{ .text = &text }, .{ .reasoning = "why" } };
    var item = try ownEvent(a, 1, .{ .assistant_committed = &blocks });
    defer item.deinit();
    @memset(&text, 'z');
    try std.testing.expectEqual(@as(usize, 2), item.event.assistant_committed.len);
    try std.testing.expectEqualStrings("abc", item.event.assistant_committed[0].text);
    try std.testing.expectEqualStrings("why", item.event.assistant_committed[1].reasoning);
    try std.testing.expect(item.canonical_complete);
    try std.testing.expect(!item.display_truncated);
}

test "wire failure codes round-trip the details the local TUI classifies" {
    for ([_]anyerror{ error.CleanupFailed, error.UnsafeToContinue, error.InputBudgetExceeded, error.UnknownInputPriceThreshold, error.DecisionUnavailable, error.NoCompactionCandidate }) |err| {
        const code = Failure.fromError(err);
        try std.testing.expectEqual(err, code.toError().?);
    }
    try std.testing.expectEqual(error.RemoteFailure, Failure.fromError(error.SomethingElse).toError().?);
    const terminal = (Terminal{ .status = .canceled, .failure = .canceled }).toRuntime();
    try std.testing.expectEqual(r.Status.canceled, terminal.status);
    try std.testing.expectEqual(error.Canceled, terminal.detail.?);
    try std.testing.expectEqual(@as(?anyerror, null), (Terminal{ .status = .success }).toRuntime().detail);
}
