//! SessionHost: the single owner of one live Thin session.
//!
//! One process hosts exactly one `Session` (App + Runtime). The host owns the
//! display `Bridge`, the current `task.Job` and its `Future`, the only task
//! `Cancellation`, the `Inbox`, the controller epoch, approval routing,
//! submit-receipt deduplication and bounded display event/history rings.
//!
//! Threading contract:
//! - Every Session/App/Runtime/Inbox call happens on the host owner thread
//!   (the worker main loop). `dispatch` is called only from that thread.
//! - The Runtime producer thread only talks to the Bridge (existing contract).
//! - `pump` admits Bridge items only while bounded unacknowledged live
//!   retention has room. The owner continues polling controls while a slow or
//!   absent viewer backpressures the Runtime. IPC never reads live slices.
//! - Connection EOF calls `disconnected`, which only revokes the controller
//!   epoch/view. It never cancels the task and never closes the Bridge.
//!
//! Wire semantics are documented in `.pi/daemon-backend-api.md`.

const std = @import("std");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const task = @import("../core/task.zig");
const inbox_mod = @import("../core/inbox.zig");
const settings_preferences = @import("../core/settings.zig");
const providers = @import("../core/providers.zig");
const ids = @import("session_id.zig");
const cli = @import("cli.zig");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const resume_store = @import("resume_store.zig");

const Session = @import("session.zig").Session;
const bridge_mod = @import("../ui/bridge.zig");
const Bridge = bridge_mod.Bridge;
const tui = @import("../ui/tui.zig");

const activity = @import("../presentation/activity.zig");
const protocol = @import("../daemon/protocol.zig");
const codex_login = @import("../core/codex_login.zig");
const background_status = @import("../core/background_status.zig");

const Io = std.Io;

/// The anonymous `Job.kind` enum has no public declaration; recover its type.
pub const Owner = cli.WorkerOwner;

pub const Options = struct {
    /// Fixed project root for this worker; never changes after startup.
    project: []const u8,
    /// Authoritative session id (new session or resumed session).
    id: ids.Id,
    /// Resume an existing checkpoint of `id` instead of starting empty.
    @"resume": ?ids.Id = null,
    /// Read an old selection into a new empty session (same id as `id`).
    restore_selection: ?ids.Id = null,
    auto_refresh_models: bool = false,
    owner: Owner = .daemon,
};

// ---------------------------------------------------------------------------
// Bounded display rings
// ---------------------------------------------------------------------------

/// One encoded display event with its stream position.
const Entry = struct {
    seq: u64,
    json: []u8,
};

/// Bounded FIFO of already-encoded events. Owns each json buffer; evicts the
/// oldest entries when the count or byte budget would be exceeded.
const Ring = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    /// Only actual eviction establishes a gap: history-only sequence positions
    /// need not appear in this ring at all.
    evicted_through: u64 = 0,

    fn deinit(self: *Ring) void {
        for (self.items.items) |entry| self.allocator.free(entry.json);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn push(self: *Ring, seq: u64, json: []u8) !void {
        // The caller retains ownership unless append succeeds.
        try self.items.append(self.allocator, .{ .seq = seq, .json = json });
        self.bytes +|= json.len;
    }

    fn oldestSeq(self: *const Ring) ?u64 {
        if (self.items.items.len == 0) return null;
        return self.items.items[0].seq;
    }

    fn newestSeq(self: *const Ring) ?u64 {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1].seq;
    }
};

/// Bounded unacknowledged live-event storage. Unlike the history Ring, this
/// never evicts to make space. Ownership transfers only on successful push.
/// `reclaimed_through` is a stream watermark and may include positions that
/// were occupied by history-only rows rather than live entries.
const LiveRing = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    /// Contiguous retirement watermark: every position up to here is proven.
    reclaimed_through: u64 = 0,
    /// Highest position any proven range retired. It may be ahead of
    /// `reclaimed_through` while an earlier independently shown event is still
    /// unproven; the retained entries are exactly those holes.
    highest_acknowledged: u64 = 0,

    fn deinit(self: *LiveRing) void {
        for (self.items.items) |entry| self.allocator.free(entry.json);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn oldestSeq(self: *const LiveRing) ?u64 {
        return if (self.items.items.len == 0) null else self.items.items[0].seq;
    }

    fn newestSeq(self: *const LiveRing) ?u64 {
        return if (self.items.items.len == 0) null else self.items.items[self.items.items.len - 1].seq;
    }

    fn contains(self: *const LiveRing, seq: u64) bool {
        for (self.items.items) |entry| {
            if (entry.seq == seq) return true;
            if (entry.seq > seq) break;
        }
        return false;
    }

    fn push(self: *LiveRing, seq: u64, json: []u8) !void {
        if (seq <= self.reclaimed_through or (self.items.items.len != 0 and seq <= self.items.items[self.items.items.len - 1].seq)) return error.InvalidSequence;
        try self.items.append(self.allocator, .{ .seq = seq, .json = json });
        self.bytes += json.len;
    }

    /// Validate controller authority and the published high watermark before
    /// reclamation. Older acknowledgements are harmless retransmissions.
    fn acknowledge(self: *LiveRing, active_epoch: u64, epoch: u64, through: u64, high: u64) !void {
        return self.acknowledgeRange(active_epoch, epoch, 0, through, high);
    }

    /// Selective full-display proof. `first == 0` is the prefix `[0, last]`;
    /// otherwise exactly the inclusive interval is retired. Only positions
    /// inside the proven interval are removed, so an earlier unshown event is
    /// never covered by a later one. Retained entries are the holes.
    fn acknowledgeRange(self: *LiveRing, active_epoch: u64, epoch: u64, first: u64, last: u64, high: u64) !void {
        if (epoch == 0 or epoch != active_epoch) return error.StaleControl;
        if (first != 0 and first > last) return error.InvalidInput;
        if (last > high) return error.InvalidSequence;
        if (last == 0) return;
        var retained: usize = 0;
        for (self.items.items, 0..) |entry, index| {
            const inside = if (first == 0) entry.seq <= last else entry.seq >= first and entry.seq <= last;
            if (inside) {
                self.bytes -= entry.json.len;
                self.allocator.free(entry.json);
            } else {
                if (retained != index) self.items.items[retained] = entry;
                retained += 1;
            }
        }
        self.items.items.len = retained;
        if (last > self.highest_acknowledged) self.highest_acknowledged = last;
        // Contiguous retirement may only advance up to the oldest retained
        // position; a remaining hole keeps the exact-recovery cursor below it.
        const oldest = self.oldestSeq();
        const contiguous = if (oldest) |seq| @min(self.highest_acknowledged, seq -| 1) else self.highest_acknowledged;
        if (contiguous > self.reclaimed_through) self.reclaimed_through = contiguous;
    }
};

/// One exact draft boundary: the cumulative text/reasoning length after the
/// event at `seq`. Marks belong only to the current uncommitted run.
const DraftMark = struct { seq: u64, text: usize, reasoning: usize };
const DraftCut = struct { text: usize, reasoning: usize };

/// Bounded streaming text accumulator for the in-progress assistant draft.
const Draft = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    truncated: bool = false,

    fn reset(self: *Draft) void {
        self.buf.clearRetainingCapacity();
        self.truncated = false;
    }

    fn append(self: *Draft, bytes: []const u8) !void {
        self.buf.appendSlice(self.allocator, bytes) catch |err| {
            self.truncated = true;
            return err;
        };
    }

    fn deinit(self: *Draft) void {
        self.buf.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Task bookkeeping
// ---------------------------------------------------------------------------

const Task = struct {
    job: *task.Job,
    future: std.Io.Future(void),
    joined: bool = false,
    id: u64,
    kind: protocol.TaskKind,
    /// Owned prompt; `job.prompt` borrows it and it outlives the join.
    prompt: []u8,
};

const Receipt = struct {
    request: u64 = 0,
    kind: protocol.TaskKind = .prompt,
    /// SHA-256 over kind and exact text; a reused nonce with other content is
    /// rejected rather than being answered as "already accepted".
    digest: [32]u8 = @splat(0),
    accepted: bool = false,
    task: u64 = 0,
};

const Controller = struct {
    epoch: u64,
    connection: u64,
    delivered: u64 = 0,
    /// The pending approval id displayed to this controller, if any.
    permission: ?u64 = null,
    /// Highest canonical position this controller's own direct submit already
    /// rendered locally. History-only rows at or below it are never echoed back
    /// to the same viewer; a later controller starts at zero and sees them.
    suppressed_history_through: u64 = 0,
};

/// Decision result of one dispatch call: the encoded frame plus nothing else.
/// All state changes are already committed when the frame is returned.
pub const SessionHost = struct {
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    project: []u8,
    owner: Owner,

    session: Session,
    connection: tui.Connection,
    bridge: Bridge,
    inbox: r.Inbox,
    /// The only task cancellation. Never a parent of any client token.
    cancel: p.Cancellation,

    task: ?Task = null,
    task_seq: u64 = 0,
    last_terminal: ?r.Terminal = null,
    phase: ?r.State = null,
    context: ?r.ContextSnapshot = null,
    partial_text: Draft,
    partial_reasoning: Draft,
    /// Cumulative draft lengths after each text/reasoning event of the current
    /// (uncommitted) run, ordered by position. A fresh-viewer baseline uses
    /// this to cut its synthetic draft exactly at the ordered cutoff, so
    /// retained live deltas are not duplicated and retired ones are not lost.
    draft_marks: std.ArrayList(DraftMark) = .empty,
    /// False once a mark was dropped: the exact cut is unknown, so the baseline
    /// omits the draft and reports shortened history instead of guessing.
    draft_marks_exact: bool = true,

    events: LiveRing,
    history: Ring,
    pending_event: ?struct { item: bridge_mod.Item, json: []u8 } = null,
    pending_terminal: ?struct { terminal: r.Terminal, json: []u8 } = null,
    next_seq: u64 = 1,
    /// Rotate independent notification sources even with a one-entry live ring.
    background_first: bool = false,
    /// Display-only identity for canonical user rows; never authority.
    next_user_id: u64 = 0,

    epoch_seq: u64 = 0,
    controller: ?Controller = null,
    /// Cached pending approval id (Bridge remains authoritative).
    pending_permission: ?u64 = null,
    /// Owned copy of the pending approval detail. A reconnecting viewer must
    /// see the real tool and description before deciding; an empty placeholder
    /// is never replayed as if it were the original request.
    pending_name: ?[]u8 = null,
    pending_desc: ?[]u8 = null,
    /// True when the stored detail is known to be a clipped prefix, either by
    /// the Bridge display budget or by this host's own bound. A clipped detail
    /// may be shown but never approved (`allow=true`); denying stays possible.
    pending_detail_incomplete: bool = false,

    receipts: [16]Receipt = @splat(.{}),
    receipt_next: usize = 0,

    closing: bool = false,
    saved_on_shutdown: bool = false,
    fatal: ?anyerror = null,
    reset_failed: ?anyerror = null,
    /// Owner-only non-event changes, consumed by read-only subscriptions.
    view_revision: u64 = 0,

    pub fn init(a: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, options: Options) !*SessionHost {
        if (!ids.valid(options.id)) return error.InvalidArguments;
        // Only a resume is required to keep its own identity. A restored
        // selection deliberately reads an OLD source id into a NEW session id.
        if (options.@"resume") |resume_id| if (!std.mem.eql(u8, &resume_id, &options.id)) return error.InvalidArguments;
        if (options.@"resume" != null and options.restore_selection != null) return error.InvalidArguments;

        const project = try a.dupe(u8, options.project);
        errdefer a.free(project);

        // Allocate the stable host first: the Runtime stores a permanent Host
        // pointer, so the Bridge must exist before Session.init binds it.
        const host = try a.create(SessionHost);
        errdefer a.destroy(host);
        host.* = .{
            .allocator = a,
            .io = io,
            .environ = environ,
            .project = project,
            .owner = options.owner,
            .session = undefined,
            .connection = undefined,
            .bridge = undefined,
            .inbox = .{},
            .cancel = .{},
            .events = .{ .allocator = a },
            .history = .{ .allocator = a },
            .partial_text = .{ .allocator = a },
            .partial_reasoning = .{ .allocator = a },
        };
        host.bridge = Bridge.init(a, io, &host.cancel);
        errdefer host.bridge.deinit();

        // Prove single-owner startup before creating a new session, and KEEP the
        // lease for the whole session lifetime. A transient check would let a
        // second worker activate between the probe and the first save.
        var preflight: ?resume_store.Lease = null;
        defer if (preflight) |*lease| lease.deinit();
        if (options.@"resume" == null) {
            var root = try fs.Root.open(a, io, project);
            defer root.deinit();
            preflight = resume_store.Lease.create(&root, options.id) catch |err| switch (err) {
                error.SessionInUse => return error.SessionInUse,
                else => return err,
            };
        }

        host.session = try Session.initWithOptions(a, io, environ, project, host.bridge.host(), .{
            .session_id = options.id,
            .resume_session = options.@"resume",
            .restore_selection = options.restore_selection,
            .auto_refresh_models = options.auto_refresh_models,
        });
        errdefer host.session.deinit();
        if (options.@"resume" != null and host.session.read_only) return error.SessionInUse;
        if (host.session.resume_lease == null) {
            // Transfer the already-held write lease to the Session so the first
            // checkpoint save reuses it instead of racing for the same inode.
            host.session.resume_lease = preflight;
            preflight = null;
        }
        host.connection = host.session.connection();
        host.attachInbox();
        host.context = host.connection.current().initial_context;
        // Startup-only canonical history: this is the single safe point before
        // any producer exists. It is copied into the owned display ring so a
        // remote frontend sees restored checkpoints without ever reading live
        // Runtime slices, native replay or configuration.
        if (host.connection.initial_history_fn) |history| host.seedHistory(history(host.connection.context));
        return host;
    }

    /// Runtime owns a pointer to this stable Inbox for its whole lifetime.
    fn attachInbox(self: *SessionHost) void {
        if (self.session.app) |app| {
            app.runtime.inbox = &self.inbox;
        }
    }

    /// Reload callbacks and display context at an owner-thread idle safe point.
    fn refreshConnection(self: *SessionHost) void {
        // A task may exist before busy is set or after it is cleared; only the
        // joined/cleared task guarantees that Runtime fields are safe to read.
        if (self.task != null) return;
        if (self.session.app) |app| if (app.runtime.busy.load(.acquire)) return;
        self.connection = self.session.connection();
        self.attachInbox();
        self.context = if (self.session.app) |app|
            app.runtime.contextSnapshot()
        else
            self.connection.current().initial_context;
    }

    fn now(self: *SessionHost) u64 {
        const value = Io.Clock.awake.now(self.io).toMilliseconds();
        return if (value < 0) 0 else @intCast(value);
    }

    // -----------------------------------------------------------------------
    // Bridge pump
    // -----------------------------------------------------------------------

    /// Admit one completion only after its full encoded event is retained.
    /// The Session is the sole consumer and peek/take are owner-thread calls;
    /// no second producer touches the Runtime Bridge. On allocation failure or
    /// backpressure the queue head and stream sequence remain unchanged.
    const MemoryAdmission = enum { admitted, empty, blocked, unavailable };

    fn admitMemoryCompletion(self: *SessionHost, source: anytype) MemoryAdmission {
        const terminal = source.peekMemoryCompletion() orelse return .empty;
        const event: r.Event = .{ .memory_completed = terminal };
        const json = protocol.encodeEventMeta(self.allocator, event, .{}) catch return .unavailable;
        self.commitObserved(event, false, true, json) catch |err| {
            self.allocator.free(json);
            // Allocation failure retains the independently owned completion.
            // Invalid sequence is a host invariant violation.
            if (err != error.OutOfMemory) self.fatal = err;
            return .unavailable;
        };
        const taken = source.takeMemoryCompletion();
        std.debug.assert(taken != null);
        return .admitted;
    }

    /// Retain the exact copied completion before retiring its source job.
    /// Another job may finish after peek; never take an unspecified head.
    fn admitBackgroundCompletion(self: *SessionHost, source: anytype) MemoryAdmission {
        const terminal = source.peekBackgroundCompletion() orelse return .empty;
        const event: r.Event = .{ .background_completed = terminal };
        const json = protocol.encodeEventMeta(self.allocator, event, .{}) catch return .unavailable;
        self.commitObserved(event, false, true, json) catch |err| {
            self.allocator.free(json);
            if (err != error.OutOfMemory) self.fatal = err;
            return .unavailable;
        };
        source.takeBackgroundCompletion(terminal.id);
        return .admitted;
    }

    /// Drain the primary Bridge, finish the task, and only then publish a
    /// bounded batch of Memory completions at the safe boundary before the next task.
    pub fn pump(self: *SessionHost, now_ms: u64) void {
        self.pumpFrom(now_ms, &self.session);
    }

    // The source is parameterized only to exercise the same admission path
    // with an isolated deterministic FIFO in inline tests.
    fn pumpFrom(self: *SessionHost, now_ms: u64, source: anytype) void {
        _ = now_ms;
        while (true) {
            if (self.pending_event == null) {
                const item = self.bridge.pop() orelse break;
                const meta = protocol.EventMeta{ .epoch = 0, .truncated = item.display_truncated, .canonical_complete = item.canonical_complete };
                const json = protocol.encodeEventMeta(self.allocator, item.event, meta) catch |err| {
                    var owned = item;
                    owned.deinit();
                    self.fatal = err;
                    return;
                };
                self.pending_event = .{ .item = item, .json = json };
            }
            const pending = &self.pending_event.?;
            self.commitObserved(pending.item.event, pending.item.display_truncated, pending.item.canonical_complete, pending.json) catch |err| {
                self.fatal = err;
                return;
            };
            pending.item.deinit();
            self.pending_event = null;
        }
        self.reapTask();
        if (self.task == null and self.pending_terminal == null and self.pending_event == null) {
            var completed: usize = 0;
            while (completed < 64) : (completed += 1) {
                // Rotate on each admission so a one-entry ring cannot starve
                // either independent source across successive acknowledgements.
                var admitted = false;
                if (@hasDecl(@TypeOf(source.*), "peekBackgroundCompletion")) {
                    if (self.background_first) {
                        if (self.admitBackgroundCompletion(source) == .admitted) {
                            self.background_first = false;
                            admitted = true;
                        } else if (self.admitMemoryCompletion(source) == .admitted) {
                            self.background_first = true;
                            admitted = true;
                        }
                    } else if (self.admitMemoryCompletion(source) == .admitted) {
                        self.background_first = true;
                        admitted = true;
                    } else if (self.admitBackgroundCompletion(source) == .admitted) {
                        self.background_first = false;
                        admitted = true;
                    }
                } else {
                    admitted = self.admitMemoryCompletion(source) == .admitted;
                }
                if (!admitted) break;
            }
        }
        // A completed login may reload configuration only after the primary
        // owner has fully joined, not merely after runtime.busy went false.
        if (self.task == null) _ = self.session.pollCodexLogin() catch false;
        self.dispatchNext();
    }

    /// Start one accepted queued (steering/follow-up) message when this host is
    /// idle. Mirrors the local TUI lease transaction: claim, start, commit; a
    /// failed start restores the entry and pauses the queue so nothing is
    /// silently dropped or replayed. Remote clients never launch jobs.
    fn dispatchNext(self: *SessionHost) void {
        if (self.closing or self.fatal != null) return;
        if (self.task != null or self.pending_event != null or self.pending_terminal != null) return;
        if (self.session.app == null or self.session.read_only) return;
        if (self.session.app) |app| if (app.runtime.busy.load(.acquire) or app.runtime.poisoned) return;
        const lease = self.inbox.claimNext() orelse return;
        _ = self.startTask(.prompt, lease.text) catch {
            self.inbox.restore(lease);
            self.inbox.pause();
            return;
        };
        if (self.inbox.commit(lease)) |value| {
            var entry = value;
            // Queued input was never rendered by a direct submit, so publish
            // exactly one canonical user row for live/remote views.
            self.noteQueuedUser(entry.id, entry.text);
            entry.deinit();
        } else {
            self.inbox.restore(lease);
            self.inbox.pause();
        }
    }

    /// Canonical history row for a queued/steering message actually committed by
    /// the Runtime (also delivered live, exactly once).
    fn noteQueuedUser(self: *SessionHost, id: u64, text: []const u8) void {
        const meta = protocol.EventMeta{ .epoch = 0, .truncated = false, .canonical_complete = true };
        const event: r.Event = .{ .user_committed = .{ .id = id, .text = text } };
        const seq = self.takeSeq();
        const encoded = protocol.encodeEventMeta(self.allocator, event, meta) catch |err| {
            self.fatal = err;
            return;
        };
        self.events.push(seq, encoded) catch |err| {
            self.allocator.free(encoded);
            self.fatal = err;
            return;
        };
        self.pushHistory(seq, event, meta);
    }

    /// Directly submitted text was already shown by the submitting frontend, so
    /// it is recorded in canonical history only: no event echo, no duplicate UI
    /// row. Runtime does not emit user_committed for the initial append.
    fn noteSubmittedUser(self: *SessionHost, text: []const u8) u64 {
        self.next_user_id +%= 1;
        if (self.next_user_id == 0) self.next_user_id = 1;
        const meta = protocol.EventMeta{ .epoch = 0, .truncated = false, .canonical_complete = true };
        const event: r.Event = .{ .user_committed = .{ .id = self.next_user_id, .text = text } };
        const seq = self.takeSeq();
        self.pushHistory(seq, event, meta);
        return seq;
    }

    fn pushHistory(self: *SessionHost, seq: u64, event: r.Event, meta: protocol.EventMeta) void {
        const copy = protocol.encodeEventMeta(self.allocator, event, meta) catch |err| {
            self.fatal = err;
            return;
        };
        self.history.push(seq, copy) catch |err| {
            self.allocator.free(copy);
            self.fatal = err;
        };
    }

    fn observe(self: *SessionHost, event: r.Event, display_truncated: bool, canonical_complete: bool) void {
        const meta = protocol.EventMeta{ .epoch = 0, .truncated = display_truncated, .canonical_complete = canonical_complete };
        const encoded = protocol.encodeEventMeta(self.allocator, event, meta) catch |err| {
            self.fatal = err;
            return;
        };
        self.commitObserved(event, display_truncated, canonical_complete, encoded) catch |err| {
            self.allocator.free(encoded);
            self.fatal = err;
        };
    }

    /// Exact draft boundary for the ordered cutoff. See `DraftMark`.
    fn recordDraftMark(self: *SessionHost, seq: u64) void {
        self.draft_marks.append(self.allocator, .{
            .seq = seq,
            .text = self.partial_text.buf.items.len,
            .reasoning = self.partial_reasoning.buf.items.len,
        }) catch |err| {
            self.draft_marks_exact = false;
            self.draft_marks.clearRetainingCapacity();
            self.fatal = err;
        };
    }

    fn resetDraftMarks(self: *SessionHost) void {
        self.draft_marks.clearRetainingCapacity();
        self.draft_marks_exact = true;
    }

    /// Keep one floor mark at or below the contiguous watermark plus every mark
    /// above it; a baseline can only cut at or after that floor.
    fn pruneDraftMarks(self: *SessionHost) void {
        const marks = self.draft_marks.items;
        var drop: usize = 0;
        while (drop + 1 < marks.len and marks[drop + 1].seq <= self.events.reclaimed_through) : (drop += 1) {}
        if (drop != 0) {
            std.mem.copyForwards(DraftMark, marks[0 .. marks.len - drop], marks[drop..]);
            self.draft_marks.items.len = marks.len - drop;
        }
    }

    /// Cumulative draft lengths at `cutoff`, or null when an overflow made the
    /// exact boundary unknown.
    fn draftCut(self: *const SessionHost, cutoff: u64) ?DraftCut {
        if (!self.draft_marks_exact) return null;
        var text: usize = 0;
        var reasoning: usize = 0;
        for (self.draft_marks.items) |mark| {
            if (mark.seq > cutoff) break;
            text = mark.text;
            reasoning = mark.reasoning;
        }
        return .{ .text = text, .reasoning = reasoning };
    }

    fn commitObserved(self: *SessionHost, event: r.Event, display_truncated: bool, canonical_complete: bool, encoded: []u8) !void {
        const seq = self.next_seq;
        try self.events.push(seq, encoded);
        _ = self.takeSeq();
        // Body deltas already travel on the ordered event stream. Re-encoding
        // an otherwise unchanged snapshot after every chunk creates barriers
        // between appendable text runs and adds needless work at both ends.
        switch (event) {
            .text, .reasoning => {},
            else => self.view_revision +%= 1,
        }
        switch (event) {
            .state => |phase| self.phase = phase,
            .context_snapshot => |snapshot| self.context = snapshot,
            .permission => |permission| self.setPending(permission.id, permission.tool_name, permission.description, display_truncated),
            .permission_cleared => |id| {
                if (self.pending_permission == id) self.clearPending();
            },
            .text => |bytes| self.partial_text.append(bytes) catch |err| {
                self.fatal = err;
            },
            .reasoning => |bytes| self.partial_reasoning.append(bytes) catch |err| {
                self.fatal = err;
            },
            .assistant_committed => {
                self.partial_text.reset();
                self.partial_reasoning.reset();
            },
            .tool_started, .finished => {
                self.partial_text.reset();
                self.partial_reasoning.reset();
            },
            // UI-only completion: never changes the primary task, draft,
            // approval state or model-visible history.
            .memory_completed, .background_completed => {},
            .usage => |usage| {
                if (self.context) |snapshot| {
                    const total = usage.value.total();
                    self.context = .{ .tokens = total orelse 0, .limit = snapshot.limit, .known = total != null };
                }
            },
            else => {},
        }
        switch (event) {
            .text, .reasoning => self.recordDraftMark(seq),
            .assistant_committed, .tool_started, .finished => self.resetDraftMarks(),
            else => {},
        }

        // Stored events carry no controller epoch: the page decides which view
        // epoch an event is displayed under. Replaying old history after a
        // takeover must not look like a stale control epoch.
        const meta = protocol.EventMeta{
            .epoch = 0,
            .truncated = display_truncated,
            .canonical_complete = canonical_complete,
        };
        if (canonicalForHistory(event)) {
            // A cut canonical array (block limit) stays marked incomplete, so
            // the remote TUI never treats it as the final answer.
            const copy = protocol.encodeEventMeta(self.allocator, event, meta) catch |err| {
                self.fatal = err;
                return;
            };
            self.history.push(seq, copy) catch |err| {
                self.allocator.free(copy);
                self.fatal = err;
            };
        }
    }

    /// Owned, bounded copy of the approval detail plus id. The Bridge stays the
    /// authority for whether this id can still be answered.
    fn setPending(self: *SessionHost, id: u64, tool_name: []const u8, description: []const u8, display_truncated: bool) void {
        self.clearPending();
        self.pending_detail_incomplete = display_truncated;
        self.pending_permission = id;
        self.pending_name = self.allocator.dupe(u8, tool_name) catch null;
        self.pending_desc = self.allocator.dupe(u8, description) catch null;
        if (self.pending_name == null or self.pending_desc == null) {
            // Without the real detail a reconnect cannot show what it approves.
            self.clearPending();
            self.fatal = error.OutOfMemory;
        }
    }

    fn clearPending(self: *SessionHost) void {
        if (self.pending_name) |value| self.allocator.free(value);
        if (self.pending_desc) |value| self.allocator.free(value);
        self.pending_name = null;
        self.pending_desc = null;
        self.pending_permission = null;
        self.pending_detail_incomplete = false;
    }

    fn takeSeq(self: *SessionHost) u64 {
        const seq = self.next_seq;
        self.next_seq +%= 1;
        if (self.next_seq == 0) self.next_seq = 1;
        return seq;
    }

    fn reapTask(self: *SessionHost) void {
        if (self.task == null) return;
        const owned = &self.task.?;
        if (!owned.job.done.load(.acquire)) return;

        if (self.pending_terminal == null) {
            if (!owned.joined) {
                owned.future.await(self.io);
                owned.joined = true;
            }
            const terminal = self.bridge.takeTerminal() orelse (owned.job.result() catch |err| r.Terminal{ .status = .failed, .detail = err });
            const json = protocol.encodeEventMeta(self.allocator, .{ .finished = terminal }, .{}) catch |err| {
                self.fatal = err;
                return;
            };
            self.pending_terminal = .{ .terminal = terminal, .json = json };
        }
        const pending = self.pending_terminal.?;
        const seq = self.next_seq;
        self.events.push(seq, pending.json) catch |err| {
            self.fatal = err;
            return;
        };
        _ = self.takeSeq();
        self.pending_terminal = null;
        const terminal = pending.terminal;
        self.last_terminal = terminal;
        self.phase = null;
        self.clearPending();
        self.partial_text.reset();
        self.partial_reasoning.reset();
        self.resetDraftMarks();
        if (terminal.status != .success) self.inbox.pause();
        if (terminal.detail) |detail| if (detail == error.CleanupFailed) {
            self.fatal = error.CleanupFailed;
        };
        if (self.session.app) |app| if (app.runtime.poisoned) {
            self.fatal = error.UnsafeToContinue;
        };

        const meta = protocol.EventMeta{ .epoch = 0, .truncated = false, .canonical_complete = true };
        const copy = protocol.encodeEventMeta(self.allocator, .{ .finished = terminal }, meta) catch null;
        if (copy) |history_bytes| self.history.push(seq, history_bytes) catch |err| {
            self.allocator.free(history_bytes);
            self.fatal = err;
        };

        self.session.finishOwnerTask();
        self.allocator.free(owned.prompt);
        self.allocator.destroy(owned.job);
        self.task = null;
        // Reuse the bridge for the next task. Bridge.reset refuses while any
        // emit/authorize call is still active or an item is outstanding; the
        // join above plus the full drain make that transient. Retry next pump.
        self.bridge.reset() catch |err| {
            self.reset_failed = err;
            return;
        };
        self.reset_failed = null;
    }

    /// Convert startup canonical messages into owned display rows. Bounded by
    /// count and bytes; native replay, configuration and credentials never
    /// cross this conversion.
    fn seedHistory(self: *SessionHost, messages: []const p.Message) void {
        var seeded: usize = 0;
        var bytes: usize = 0;
        var user_id: u64 = 0;
        var text_buf = std.ArrayList(u8).empty;
        defer text_buf.deinit(self.allocator);
        for (messages) |message| {
            switch (message.role) {
                .context => continue,
                .user => {
                    text_buf.clearRetainingCapacity();
                    for (message.blocks) |block| {
                        const text = switch (block) {
                            .text => |value| value,
                            else => continue,
                        };
                        if (text_buf.items.len != 0) text_buf.append(self.allocator, '\n') catch |err| {
                            self.fatal = err;
                            return;
                        };
                        text_buf.appendSlice(self.allocator, text) catch |err| {
                            self.fatal = err;
                            return;
                        };
                    }
                    if (text_buf.items.len == 0) continue;
                    user_id +%= 1;
                    if (user_id == 0) user_id = 1;
                    if (!self.seedEvent(.{ .user_committed = .{ .id = user_id, .text = text_buf.items } }, &seeded, &bytes)) return;
                },
                .assistant, .tool => {
                    if (message.blocks.len == 0) continue;
                    if (!self.seedEvent(.{ .assistant_committed = message.blocks }, &seeded, &bytes)) return;
                },
            }
        }
    }

    fn seedEvent(self: *SessionHost, event: r.Event, seeded: *usize, bytes: *usize) bool {
        const meta = protocol.EventMeta{ .epoch = 0, .truncated = false, .canonical_complete = true };
        const seq = self.takeSeq();
        const encoded = protocol.encodeEventMeta(self.allocator, event, meta) catch |err| {
            self.fatal = err;
            return false;
        };
        bytes.* +|= encoded.len;
        self.history.push(seq, encoded) catch |err| {
            self.allocator.free(encoded);
            self.fatal = err;
            return false;
        };
        seeded.* += 1;
        return true;
    }

    fn canonicalForHistory(event: r.Event) bool {
        return switch (event) {
            .user_committed, .assistant_committed, .tool_started, .tool_result, .compacted, .compaction_failed => true,
            .memory_completed => false,
            else => false,
        };
    }

    // -----------------------------------------------------------------------
    // Controller epoch
    // -----------------------------------------------------------------------

    fn controllerFor(self: *SessionHost, connection_id: u64) ?*Controller {
        // Capture the payload by pointer so this returns the real field address
        // instead of a temporary copy.
        if (self.controller) |*controller| {
            if (controller.connection != connection_id) return null;
            return controller;
        }
        return null;
    }

    fn requireControl(self: *SessionHost, connection_id: u64, epoch: u64) !void {
        const controller = self.controllerFor(connection_id) orelse return error.StaleControl;
        if (controller.epoch != epoch) return error.StaleControl;
    }

    /// A view was revoked (EOF or explicit detach). Never touches the task.
    pub fn disconnected(self: *SessionHost, connection_id: u64) void {
        if (self.controller) |controller| {
            if (controller.connection != connection_id) return;
            // An EOF must release the confirmation barrier: otherwise automatic
            // claims stay suspended with nobody left to confirm or resume.
            self.inbox.pauseClaims(false);
            self.controller = null;
        }
    }

    pub fn isClosing(self: *SessionHost) bool {
        return self.closing;
    }

    pub fn sessionId(self: *SessionHost) ids.Id {
        return self.session.session_id;
    }

    // -----------------------------------------------------------------------
    // Task lifecycle used by dispatch
    // -----------------------------------------------------------------------

    fn ensureIdle(self: *SessionHost) !void {
        if (self.task != null or self.pending_event != null or self.pending_terminal != null) return error.Busy;
        if (self.session.app) |app| if (app.runtime.busy.load(.acquire)) return error.Busy;
        if (self.reset_failed != null) return error.Busy;
    }

    fn startTask(self: *SessionHost, kind: protocol.TaskKind, text: []const u8) !u64 {
        try self.ensureIdle();
        if (self.fatal != null) return error.Unavailable;
        const app = self.session.app orelse return error.Unavailable;
        if (self.session.read_only) return error.Unavailable;
        // Refresh the observer/Inbox attachment at the idle safe point before
        // the Runtime worker exists for this task.
        self.refreshConnection();
        self.bridge.reset() catch return error.Busy;

        const prompt = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(prompt);
        const job = try self.allocator.create(task.Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .runtime = &app.runtime,
            .cancel = &self.cancel,
            .prompt = prompt,
            .kind = switch (kind) {
                .prompt => .prompt,
                .compact => .compact,
                .command => .command,
            },
        };
        try self.session.beginOwnerTask();
        errdefer self.session.finishOwnerTask();
        const future = try std.Io.concurrent(self.io, task.Job.run, .{job});
        self.task_seq +%= 1;
        if (self.task_seq == 0) self.task_seq = 1;
        self.task = .{ .job = job, .future = future, .id = self.task_seq, .kind = kind, .prompt = prompt };
        self.phase = .calling_model;
        return self.task_seq;
    }

    /// Cancel and join every owned task/job, then publish the final checkpoint.
    /// Idempotent; a second call after a successful shutdown returns immediately.
    pub fn shutdown(self: *SessionHost) !void {
        if (self.closing) return;
        if (self.task) |*owned| {
            self.cancel.cancel();
            if (!owned.joined) owned.future.await(self.io);
            self.session.finishOwnerTask();
            _ = self.bridge.takeTerminal();
            self.allocator.free(owned.prompt);
            self.allocator.destroy(owned.job);
            self.task = null;
        }
        // The task is joined. Instance-owned background commands are stopped
        // BEFORE any success reply/closing flag: BackgroundService.close
        // cancels all jobs and joins them, returning error.CleanupUnconfirmed
        // instead of panicking. Propagate it so the owner reports a failed
        // stop; App/session deinit may call deinit() again (no panic).
        if (self.session.app) |app| try app.background.close();
        // Join guarantees no producer remains; only now is Bridge.close safe.
        self.clearPending();
        self.releasePendingDelivery();
        self.bridge.close();
        var display_error: ?anyerror = null;
        while (self.bridge.pop()) |item| {
            var owned = item;
            defer owned.deinit();
            _ = &display_error;
        }
        self.saved_on_shutdown = self.session.saveOnExit() catch |err| blk: {
            self.fatal = self.fatal orelse err;
            break :blk false;
        };
        self.closing = true;
    }

    fn releasePendingDelivery(self: *SessionHost) void {
        if (self.pending_event) |*pending| {
            self.allocator.free(pending.json);
            pending.item.deinit();
            self.pending_event = null;
        }
        if (self.pending_terminal) |pending| {
            self.allocator.free(pending.json);
            self.pending_terminal = null;
        }
    }

    /// The owner thread released every worker: destroy in shutdown order.
    pub fn deinit(self: *SessionHost) void {
        const a = self.allocator;
        if (self.task) |*owned| {
            self.cancel.cancel();
            if (!owned.joined) owned.future.await(self.io);
            self.session.finishOwnerTask();
            a.free(owned.prompt);
            a.destroy(owned.job);
            self.task = null;
        }
        self.clearPending();
        self.releasePendingDelivery();
        self.bridge.deinit();
        self.inbox.deinit();
        self.partial_text.deinit();
        self.partial_reasoning.deinit();
        self.draft_marks.deinit(self.allocator);
        self.events.deinit();
        self.history.deinit();
        self.session.deinit();
        a.free(self.project);
        a.destroy(self);
    }

    // -----------------------------------------------------------------------
    // Dispatch
    // -----------------------------------------------------------------------

    /// Handle exactly one parsed request on the owner thread and return the
    /// complete JSON response frame (allocated with `a`). Handler failures are
    /// encoded as error replies; only allocation failure propagates.
    pub fn dispatch(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64, owner_authorized: bool) ![]u8 {
        // Drain first so a reply reflects the current display state.
        self.pump(self.now());
        switch (request.op) {
            .hello, .snapshot, .events, .history, .settings, .ping, .watch, .ack => {},
            else => self.view_revision +%= 1,
        }
        return switch (request.op) {
            .hello => self.replyHello(a, request.id),
            .snapshot => self.replySnapshot(a, request, connection_id),
            .attach => self.handleAttach(a, request, connection_id),
            .detach => self.handleDetach(a, request, connection_id),
            .events => self.handleEvents(a, request, connection_id),
            .ack => self.handleAck(a, request, connection_id),
            .history => self.replyHistory(a, request),
            .submit => self.handleSubmit(a, request, connection_id),
            .cancel => self.handleCancel(a, request, connection_id),
            .cancel_clear => self.handleCancelClear(a, request, connection_id),
            .confirming => self.handleConfirming(a, request, connection_id),
            .approve => self.handleApprove(a, request, connection_id),
            .enqueue => self.handleEnqueue(a, request, connection_id),
            .withdraw => self.handleWithdraw(a, request, connection_id),
            .queue_resume => self.handleQueueResume(a, request, connection_id),
            .settings => self.replySettings(a, request.id),
            .model_select => self.handleModelSelect(a, request, connection_id),
            .effort => self.handleEffort(a, request, connection_id),
            .cycle_effort => self.handleCycleEffort(a, request, connection_id),
            .login => self.handleLogin(a, request, connection_id),
            .preference => self.handlePreference(a, request, connection_id),
            .setting => self.handleSetting(a, request, connection_id),
            .decision_model => self.handleDecisionModel(a, request, connection_id),
            .image_model => self.handleImageModel(a, request, connection_id),
            .proxy_model => self.handleProxyModel(a, request, connection_id),
            .proxy_address => self.handleProxyAddress(a, request, connection_id),
            .refresh_models => self.handleRefresh(a, request, connection_id),
            .codex_login => self.handleCodexLogin(a, request, connection_id),
            .poll_metadata => self.handlePollMetadata(a, request, connection_id),
            .close => self.handleClose(a, request, connection_id),
            .shutdown => self.handleShutdown(a, request, owner_authorized),
            .ping => self.replyPing(a, request.id),
            .create, .list, .watch => errorReply(a, request.id, error.Unsupported),
        };
    }

    fn errorReply(a: std.mem.Allocator, id: u64, err: anyerror) ![]u8 {
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.fail(id, protocol.errorCode(err));
        return out.finish();
    }

    fn replyFrame(out: *protocol.Out) ![]u8 {
        return out.finish();
    }

    fn replyHello(self: *SessionHost, a: std.mem.Allocator, id: u64) ![]u8 {
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(id);
        try out.field("session", self.session.session_id);
        try out.field("owner", @tagName(self.owner));
        try out.field("pid", std.c.getpid());
        try out.field("protocol", protocol.version);
        try out.field("watch", true);
        return replyFrame(&out);
    }

    fn replyPing(self: *SessionHost, a: std.mem.Allocator, id: u64) ![]u8 {
        _ = self;
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(id);
        try out.field("pid", std.c.getpid());
        return replyFrame(&out);
    }

    /// Caller-owned projection storage. `queue` keeps the bytes the preview
    /// slices point at alive; `previews` receives the encoded preview structs.
    /// The returned `Snapshot` borrows both, so it must not outlive the caller
    /// frame that owns them.
    fn codexView(self: *SessionHost) codex_login.View {
        var view = self.session.codexLoginView();
        if (self.task != null and view.status == .succeeded) view.status = .pending;
        return view;
    }

    fn snapshotFor(self: *SessionHost, connection_id: u64, queue: *const inbox_mod.Snapshot, previews: []protocol.QueuePreview) protocol.Snapshot {
        const state = self.connection.current();
        const is_controller = if (self.controllerFor(connection_id)) |controller| controller.epoch else 0;
        const count = @min(queue.preview_count, previews.len);
        for (queue.previews[0..count], 0..) |*preview, i| {
            previews[i] = .{ .id = preview.id, .kind = switch (preview.kind) {
                .steering => .steering,
                .follow_up => .follow_up,
            }, .text = preview.text() };
        }
        return .{
            .session = self.session.session_id,
            .label = null,
            .project = self.project,
            .owner = switch (self.owner) {
                .foreground => .foreground,
                .daemon => .daemon,
            },
            .busy = self.task != null,
            .phase = self.phase,
            .task = if (self.task) |value| value.id else 0,
            .task_kind = if (self.task) |value| value.kind else .prompt,
            .epoch = is_controller,
            .attached = self.controller != null,
            .pending_permission = self.pending_permission,
            .queue_revision = queue.revision,
            .queue_paused = queue.paused,
            .steering = @intCast(@min(queue.steering, std.math.maxInt(u32))),
            .follow_up = @intCast(@min(queue.follow_up, std.math.maxInt(u32))),
            .newest_id = queue.newest_id,
            .newest_bytes = @intCast(queue.newest_bytes),
            .previews = previews[0..count],
            .context = self.context,
            .model = state.model,
            .provider = if (state.provider) |provider| provider.slug() else null,
            .codex_login = self.codexView(),
            .memory = state.memory,
            .background = state.background,
            .subagents = state.subagents,
            .subagents_supported = state.subagents_supported,
            .read_only = self.session.read_only,
            .truncated = self.fatal != null or self.reset_failed != null or self.history.evicted_through != 0 or self.partial_text.truncated or self.partial_reasoning.truncated,
        };
    }

    const SubagentPage = struct { next: u64, group: u64 };

    fn pageSnapshot(snapshot: *protocol.Snapshot, requested: u64, group: ?u64) SubagentPage {
        const view = &snapshot.subagents;
        if (!snapshot.subagents_supported) return .{ .next = 0, .group = view.group_id };
        const total = view.agents.len;
        const start: usize = if (group != null and group.? != view.group_id) 0 else @intCast(@min(requested, total));
        const aligned = if (start % 64 == 0 and (start < total or start == 0)) start else 0;
        const end = @min(total, aligned + 64);
        view.page_offset = aligned;
        view.page_total = total;
        view.agents = view.agents[aligned..end];
        return .{ .next = if (end < total) end else 0, .group = view.group_id };
    }

    /// `snapshot` may carry `receipt:u64` to read the disposition of an earlier
    /// submission without resending it. The query is strictly read-only: it
    /// never starts, retries or cancels a task; an unknown or already evicted
    /// nonce reports `receipt_known=false` instead of pretending acceptance.
    fn replySnapshot(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("through", self.next_seq -| 1);
        // Both stores live in this frame and stay valid through encoding: one
        // Inbox snapshot supplies the counts, the revision and the preview text.
        const queue = self.inbox.snapshot();
        var previews: [protocol.max_previews]protocol.QueuePreview = undefined;
        const row_cursor = request.optionalU64("row_cursor") catch return errorReply(a, request.id, error.BadRequest);
        const row_group = request.optionalU64("row_group") catch return errorReply(a, request.id, error.BadRequest);
        if ((row_cursor == null) != (row_group == null)) return errorReply(a, request.id, error.BadRequest);
        if (row_cursor) |cursor| if (cursor % 64 != 0) return errorReply(a, request.id, error.BadRequest);
        var snapshot = self.snapshotFor(connection_id, &queue, previews[0..]);
        _ = pageSnapshot(&snapshot, row_cursor orelse 0, row_group);
        try protocol.encodeSnapshot(&out, snapshot);
        const receipt_id = request.optionalU64("receipt") catch return errorReply(a, request.id, error.BadRequest);
        if (receipt_id) |id| {
            const known = self.receipt(id);
            try out.field("receipt_known", known != null);
            try out.field("receipt_accepted", if (known) |value| value.accepted else false);
            try out.field("receipt_task", if (known) |value| value.task else @as(u64, 0));
        }
        return replyFrame(&out);
    }

    fn handleAttach(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const write = request.boolField("write", true) catch return errorReply(a, request.id, error.BadRequest);
        const takeover = request.boolField("takeover", false) catch return errorReply(a, request.id, error.BadRequest);
        if (!write) {
            var out = protocol.Out.init(a);
            defer out.deinit();
            try out.ok(request.id);
            try out.field("epoch", @as(u64, 0));
            return replyFrame(&out);
        }
        if (self.controller) |controller| {
            if (controller.connection != connection_id and !takeover) return errorReply(a, request.id, error.Busy);
        }
        // Replacing the controller (takeover or same-socket re-attach) retires
        // the previous epoch's confirmation barrier; it belongs to that owner.
        if (self.controller != null) self.inbox.pauseClaims(false);
        self.epoch_seq +%= 1;
        if (self.epoch_seq == 0) self.epoch_seq = 1;
        self.controller = .{ .epoch = self.epoch_seq, .connection = connection_id, .permission = self.pending_permission, .delivered = self.events.reclaimed_through };
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("epoch", self.epoch_seq);
        return replyFrame(&out);
    }

    fn handleDetach(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        if (self.controller) |controller| {
            if (controller.epoch == epoch and controller.connection == connection_id) {
                self.inbox.pauseClaims(false);
                self.controller = null;
            }
        }
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    pub const WatchStamp = struct {
        sequence: u64,
        revision: u64,
        queue_revision: u64,
        task: u64,
        codex: codex_login.View,
        memory: @import("../core/memory_status.zig").View = .{},
        background: background_status.View = .{},
        subagents: @import("../core/subagent_status.zig").View = .{},
        subagents_supported: bool = false,
        subagent_rows_hash: u64 = 0,

        pub fn eql(left: WatchStamp, right: WatchStamp) bool {
            // sequence is a coverage watermark, not a snapshot invalidation.
            return left.revision == right.revision and
                left.queue_revision == right.queue_revision and left.task == right.task and std.meta.eql(left.codex, right.codex) and std.meta.eql(left.memory, right.memory) and std.meta.eql(left.background, right.background) and @import("../core/subagent_status.zig").View.eql(left.subagents, right.subagents) and left.subagent_rows_hash == right.subagent_rows_hash and left.subagents_supported == right.subagents_supported;
        }
    };

    /// A stream is a view of an EXISTING controller, never a way to acquire it.
    /// The worker must additionally bind the stream's kernel peer PID to the
    /// returned live control connection before exposing any controller state.
    pub fn watchOwner(self: *const SessionHost, epoch: u64) !u64 {
        const controller = self.controller orelse return error.StaleControl;
        if (epoch == 0 or controller.epoch != epoch) return error.StaleControl;
        return controller.connection;
    }

    pub fn watchResume(self: *const SessionHost, epoch: u64, cursor: ?u64) !u64 {
        _ = try self.watchOwner(epoch);
        const controller = self.controller.?;
        const since = cursor orelse self.events.reclaimed_through;
        if (since < self.events.reclaimed_through or since > controller.delivered) return error.InvalidSequence;
        return since;
    }

    /// Called only after the worker successfully queues the complete page.
    pub fn watchOffered(self: *SessionHost, epoch: u64, through: u64) !void {
        _ = try self.watchOwner(epoch);
        if (through > self.next_seq -| 1) return error.InvalidSequence;
        self.controller.?.delivered = @max(self.controller.?.delivered, through);
    }

    fn handleAck(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        const sequence = request.u64Field("sequence") catch return errorReply(a, request.id, error.BadRequest);
        const first = request.optionalU64("first") catch return errorReply(a, request.id, error.BadRequest);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        const outcome = self.watchAcknowledgeRange(epoch, first orelse 0, sequence) catch |err| return errorReply(a, request.id, err);
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("first", outcome.first);
        try out.field("sequence", outcome.sequence);
        try out.field("through", outcome.through);
        return replyFrame(&out);
    }

    pub const AckOutcome = struct { first: u64, sequence: u64, through: u64 };

    /// The only way a display position is retired. The worker calls this after
    /// it has validated that the frame arrived on a watch connection still
    /// bound to the live controller epoch and to the controller's kernel peer.
    /// The epoch re-check here is what makes a takeover invalidate ACKs from the
    /// replaced view; no new socket or credential stands in for that binding.
    /// Only positions inside the accepted range are removed; a retained hole
    /// keeps `through` behind it.
    pub fn watchAcknowledgeRange(self: *SessionHost, epoch: u64, first: u64, last: u64) !AckOutcome {
        _ = try self.watchOwner(epoch);
        try self.events.acknowledgeRange(epoch, epoch, first, last, self.controller.?.delivered);
        self.pruneDraftMarks();
        return .{ .first = first, .sequence = last, .through = self.events.reclaimed_through };
    }

    /// Cumulative prefix proof retained for existing viewers.
    pub fn watchAcknowledge(self: *SessionHost, epoch: u64, sequence: u64) !u64 {
        return (try self.watchAcknowledgeRange(epoch, 0, sequence)).through;
    }

    pub fn watchStamp(self: *SessionHost) WatchStamp {
        const queue = self.inbox.snapshot();
        const state = self.connection.current();
        var subagents = state.subagents;
        var hash = std.hash.Wyhash.init(0);
        for (subagents.agents) |row| {
            hash.update(std.mem.asBytes(&row.id));
            hash.update(std.mem.asBytes(&row.revision));
            hash.update(&.{@backingInt(row.phase)});
            hash.update(std.mem.asBytes(&row.elapsed_ms));
            hash.update(row.latestText());
        }
        const rows_hash = hash.final();
        subagents.agents = &.{};
        return .{
            .sequence = self.next_seq -| 1,
            .revision = self.view_revision,
            .queue_revision = queue.revision,
            .task = if (self.task) |task_| task_.id else 0,
            .codex = self.codexView(),
            .memory = state.memory,
            .background = state.background,
            .subagents = subagents,
            .subagent_rows_hash = rows_hash,
            .subagents_supported = state.subagents_supported,
        };
    }

    /// No pumping/await between these two encoders at subscription admission:
    /// snapshot and baseline then describe the same display watermark. Each is
    /// independently bounded by max_response (not an oversized nested frame).
    pub fn watchSnapshot(self: *SessionHost, a: std.mem.Allocator, id: u64, epoch: u64) ![]u8 {
        return (try self.watchSnapshotPage(a, id, epoch, 0, null)).frame;
    }

    pub const WatchSnapshotPage = struct { frame: []u8, next: u64, group: u64 };

    pub fn watchSnapshotPage(self: *SessionHost, a: std.mem.Allocator, id: u64, epoch: u64, row_cursor: u64, row_group: ?u64) !WatchSnapshotPage {
        const control_id = try self.watchOwner(epoch);
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(id);
        try out.field("stream", "snapshot");
        try out.field("epoch", epoch);
        try out.field("through", self.next_seq -| 1);
        const queue = self.inbox.snapshot();
        var previews: [protocol.max_previews]protocol.QueuePreview = undefined;
        var snapshot = self.snapshotFor(control_id, &queue, &previews);
        const page = pageSnapshot(&snapshot, row_cursor, row_group);
        try protocol.encodeSnapshot(&out, snapshot);
        return .{ .frame = try replyFrame(&out), .next = page.next, .group = page.group };
    }

    pub fn watchBaseline(self: *SessionHost, a: std.mem.Allocator, id: u64, epoch: u64) ![]u8 {
        _ = try self.watchOwner(epoch);
        return self.historyFrame(a, id, protocol.max_history, epoch);
    }

    pub const WatchPage = struct { frame: []u8, through: u64 };

    /// Ordered union of retained live entries and canonical history rows in
    /// `(since, high]`. A shared position is emitted once, preferring the live
    /// entry. History-only positions (direct submits, canonical rows already
    /// ACKed out of the ring) therefore arrive in exact sequence order instead
    /// of being appended after later live deltas. Positions that exist nowhere
    /// any more are reported as incomplete rather than silently claimed as
    /// exact recovery. `first`/`sequence` of each entry is its absolute stream
    /// position, so the caller's monotonic cursor stays truthful.
    pub fn watchEvents(self: *SessionHost, a: std.mem.Allocator, id: u64, epoch: u64, since: u64) !?WatchPage {
        const control_id = try self.watchOwner(epoch);
        const high = self.next_seq -| 1;
        if (since > high or since < self.events.reclaimed_through) return error.StreamGap;
        if (since == high) return null;
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(id);
        try out.field("stream", "events");
        try out.field("epoch", epoch);
        try out.field("from", since);
        try out.beginArray("events");
        const suppressed: u64 = if (self.controller) |controller|
            (if (controller.connection == control_id) controller.suppressed_history_through else 0)
        else
            0;
        var count: usize = 0;
        var through = since;
        var more = false;
        var incomplete = false;
        // Last position that was delivered or intentionally suppressed for this
        // viewer. A jump means content is gone (shortened context).
        var covered = since;
        const lives = self.events.items.items;
        var live_index: usize = 0;
        while (live_index < lives.len and lives[live_index].seq <= since) live_index += 1;
        const rows = self.history.items.items;
        var row_index: usize = 0;
        while (row_index < rows.len and rows[row_index].seq <= since) row_index += 1;
        const budget = if (protocol.max_response > response_reserve) protocol.max_response - response_reserve else 0;
        scan: while (true) {
            const live_seq: ?u64 = if (live_index < lives.len) lives[live_index].seq else null;
            while (row_index < rows.len and rows[row_index].seq <= covered) row_index += 1;
            const row_seq: ?u64 = if (row_index < rows.len) rows[row_index].seq else null;
            // A history-only row this controller submitted itself was already
            // rendered locally; consume its position without echoing it.
            if (row_seq) |position| {
                if (live_seq == null or position < live_seq.?) {
                    if (position <= suppressed) {
                        // Locally rendered by this viewer; its position is
                        // covered but nothing is echoed back.
                        if (position > covered + 1) incomplete = true;
                        covered = position;
                        row_index += 1;
                        continue;
                    }
                    if (position > covered + 1) incomplete = true;
                    const wire = try std.fmt.allocPrint(a, "{s},\"seq\":{d}}}", .{ rows[row_index].json[0 .. rows[row_index].json.len - 1], position });
                    defer a.free(wire);
                    if (count == protocol.max_events or (count != 0 and out.buf.items.len + wire.len + 32 > budget)) {
                        more = true;
                        break :scan;
                    }
                    try out.element(wire);
                    through = position;
                    covered = position;
                    count += 1;
                    row_index += 1;
                    continue;
                }
            }
            const position = live_seq orelse break;
            if (position > covered + 1) incomplete = true;
            const wire = try std.fmt.allocPrint(a, "{s},\"seq\":{d}}}", .{ lives[live_index].json[0 .. lives[live_index].json.len - 1], position });
            defer a.free(wire);
            if (count == protocol.max_events or (count != 0 and out.buf.items.len + wire.len + 32 > budget)) {
                more = true;
                break :scan;
            }
            try out.element(wire);
            through = position;
            covered = position;
            count += 1;
            live_index += 1;
            if (row_seq != null and row_seq.? == position) row_index += 1;
        }
        if (more and count == 0) return error.FrameTooLarge;
        if (!more) {
            through = high;
            if (through > covered) incomplete = true;
        }
        try out.endArray();
        try out.field("through", through);
        try out.field("incomplete", incomplete);
        return .{ .frame = try replyFrame(&out), .through = through };
    }

    /// Reserved space for JSON framing, field names and the error path.
    const response_reserve: usize = 16 * 1024;

    fn handleEvents(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        _ = connection_id;
        const since = request.u64Field("since") catch return errorReply(a, request.id, error.BadRequest);
        const requested_max = request.optionalU64("max") catch null;
        const maximum: usize = @intCast(@min(requested_max orelse @as(u64, protocol.max_events), @as(u64, protocol.max_events)));
        // Legacy polling remains an immediate bounded read. A wait_ms ceiling
        // is not a minimum delay; waiting for output belongs to the dedicated
        // watch socket, never a sleep inside the shared owner dispatch loop.

        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        const oldest = self.events.oldestSeq();
        const reset = since != 0 and since < self.events.reclaimed_through;
        try out.field("reset", reset);
        try out.beginArray("events");
        const budget = if (protocol.max_response > response_reserve) protocol.max_response - response_reserve else 0;
        var used: usize = 0;
        var newest: u64 = since;
        var cut = false;
        if (!reset) {
            var taken: usize = 0;
            for (self.events.items.items) |entry| {
                if (entry.seq <= since) continue;
                if (taken >= maximum) {
                    cut = true;
                    break;
                }
                // Real encoded size, not the ring capacity: a single large tool
                // result must not push a legal frame over the transport bound.
                if (taken != 0 and used + entry.json.len + 1 > budget) {
                    cut = true;
                    break;
                }
                try out.element(entry.json);
                used += entry.json.len + 1;
                newest = entry.seq;
                taken += 1;
            }
        }
        try out.endArray();
        try out.field("base", if (oldest) |value| value else @as(u64, 0));
        try out.field("next", newest);
        try out.field("truncated", cut);
        return replyFrame(&out);
    }

    /// `base` is the last sequence already represented by this snapshot: the
    /// client sets its cursor to it, then asks for events with seq > base.
    /// Canonical rows are bounded by real encoded bytes so a large checkpoint
    /// can never make a legal history reply exceed the transport limit.
    fn replyHistory(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request) ![]u8 {
        const requested = request.optionalU64("limit") catch null;
        const limit: usize = @intCast(@min(requested orelse @as(u64, protocol.max_history), @as(u64, protocol.max_history)));
        return self.historyFrame(a, request.id, limit, null);
    }

    fn historyFrame(self: *SessionHost, a: std.mem.Allocator, id: u64, limit: usize, stream_epoch: ?u64) ![]u8 {
        const base: u64 = if (stream_epoch != null) self.events.reclaimed_through else self.next_seq -| 1;

        // Encode the current-state rows first: they must always fit, so their
        // exact size reserves space before the canonical window is chosen.
        var synthetic: [6]?[]u8 = @splat(null);
        defer for (&synthetic) |*item| if (item.*) |json| a.free(json);
        var synthetic_count: usize = 0;
        {
            var scratch = SyntheticWriter{ .a = a, .list = &synthetic, .count = &synthetic_count };
            // A streaming baseline is the ordered cutoff `base`; any live delta
            // after it is delivered by the merged events page, so the synthetic
            // draft must hold exactly the bytes retired at or before `base`.
            const cut: DraftCut = if (stream_epoch != null) self.draftCut(base) orelse DraftCut{ .text = 0, .reasoning = 0 } else .{
                .text = self.partial_text.buf.items.len,
                .reasoning = self.partial_reasoning.buf.items.len,
            };
            if (cut.text != 0) try scratch.addWith(.{ .text = self.partial_text.buf.items[0..cut.text] }, true, self.partial_text.truncated);
            if (cut.reasoning != 0) try scratch.addWith(.{ .reasoning = self.partial_reasoning.buf.items[0..cut.reasoning] }, true, self.partial_reasoning.truncated);
            if (self.phase) |phase| try scratch.add(.{ .state = phase }, true);
            if (self.context) |context| try scratch.add(.{ .context_snapshot = context }, true);
            // Replay the real owned approval detail, never an empty placeholder.
            if (self.pending_permission != null and self.pending_name != null and self.pending_desc != null) {
                // The rebuilt row keeps the stored clipping flag, so a viewer
                // that reconnects knows the detail is not the whole request.
                try scratch.addWith(
                    .{ .permission = .{ .id = self.pending_permission.?, .tool_name = self.pending_name.?, .description = self.pending_desc.? } },
                    true,
                    self.pending_detail_incomplete,
                );
            }
            if (self.task == null) if (self.last_terminal) |terminal| try scratch.add(.{ .finished = terminal }, true);
        }
        const entries = self.history.items.items;
        var end = entries.len;
        if (stream_epoch != null) {
            // Only positions at or below the ordered cutoff belong to the
            // baseline: later canonical/history-only rows are delivered by the
            // merged events pages in exact sequence order.
            while (end > 0 and entries[end - 1].seq > base) end -= 1;
        }
        _ = limit; // No continuation exists for a shortened baseline.
        var start: usize = end;
        while (start > 0) {
            start -= 1;
        }
        const draft_shortened = stream_epoch != null and self.draftCut(base) == null;
        const truncated = start != 0 or self.history.evicted_through != 0 or
            self.partial_text.truncated or self.partial_reasoning.truncated or draft_shortened;

        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(id);
        if (stream_epoch) |epoch| {
            try out.field("stream", "baseline");
            try out.field("epoch", epoch);
            try out.field("through", base);
        }
        try out.field("base", base);
        try out.beginArray("entries");
        // Canonical blocks first, oldest to newest.
        for (entries[start..end]) |entry| {
            try out.element(entry.json);
        }
        // Then the current in-progress state at `base`. These are synthetic and
        // are never inserted into the event ring, so events(since=base) cannot
        // duplicate them.
        for (synthetic[0..synthetic_count]) |maybe| if (maybe) |json| try out.element(json);
        try out.endArray();
        try out.field("truncated", truncated);
        return replyFrame(&out);
    }

    /// Owns the encoded synthetic history rows so their exact byte count can
    /// reserve room before canonical selection.
    const SyntheticWriter = struct {
        a: std.mem.Allocator,
        list: *[6]?[]u8,
        count: *usize,

        fn add(self: *SyntheticWriter, event: r.Event, enable: bool) !void {
            try self.addWith(event, enable, false);
        }

        fn addWith(self: *SyntheticWriter, event: r.Event, enable: bool, truncated: bool) !void {
            if (!enable) return;
            std.debug.assert(self.count.* < self.list.len);
            const meta = protocol.EventMeta{ .epoch = 0, .truncated = truncated, .canonical_complete = true };
            const json = try encodeSynthetic(self.a, event, meta);
            self.list[self.count.*] = json;
            self.count.* += 1;
        }
    };

    fn handleSubmit(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        const receipt_id = request.u64Field("req") catch return errorReply(a, request.id, error.BadRequest);
        // Zero denotes an empty receipt slot; accepting it would disable replay
        // detection for a request whose acknowledgment was lost.
        if (receipt_id == 0) return errorReply(a, request.id, error.BadRequest);
        const kind = request.stringEnum(protocol.TaskKind, "kind") catch return errorReply(a, request.id, error.BadRequest);
        const text = request.stringField("text", null) catch |err| return errorReply(a, request.id, err);
        const digest = submitDigest(kind, text);

        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        if (self.receipt(receipt_id)) |known| {
            // A nonce is only replayable for the exact same request. Reusing it
            // for other content must never look like an accepted submission.
            if (known.kind != kind or !std.mem.eql(u8, &known.digest, &digest)) {
                return errorReply(a, request.id, error.InvalidInput);
            }
            var out = protocol.Out.init(a);
            defer out.deinit();
            try out.ok(request.id);
            try out.field("accepted", known.accepted);
            try out.field("task", known.task);
            try out.field("duplicate", true);
            return replyFrame(&out);
        }

        const accepted = self.startTask(kind, text) catch |err| {
            // Record the rejection so a client that lost the previous reply
            // cannot cause a second, different outcome on retry.
            self.recordReceipt(receipt_id, kind, digest, false, 0);
            return errorReply(a, request.id, err);
        };
        self.recordReceipt(receipt_id, kind, digest, true, accepted);
        // Direct input is shown by the submitting frontend already; only the
        // canonical history row is added (Runtime emits no user event for it).
        // The same viewer's ordered pages must not echo it back, while a new
        // controller still receives the canonical row in sequence order.
        if (kind == .prompt) {
            const seq = self.noteSubmittedUser(text);
            if (self.controller) |*controller| {
                if (controller.connection == connection_id) controller.suppressed_history_through = @max(controller.suppressed_history_through, seq);
            }
        }
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("accepted", true);
        try out.field("through", self.next_seq -| 1);
        try out.field("task", accepted);
        try out.field("duplicate", false);
        return replyFrame(&out);
    }

    fn receipt(self: *SessionHost, id: u64) ?Receipt {
        for (self.receipts) |entry| if (entry.request == id and entry.request != 0) return entry;
        return null;
    }

    fn recordReceipt(self: *SessionHost, id: u64, kind: protocol.TaskKind, digest: [32]u8, accepted: bool, task_id: u64) void {
        self.receipts[self.receipt_next] = .{ .request = id, .kind = kind, .digest = digest, .accepted = accepted, .task = task_id };
        self.receipt_next = (self.receipt_next + 1) % self.receipts.len;
    }

    fn handleCancel(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        const canceled = self.task != null;
        if (canceled) self.cancel.cancel();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("canceled", canceled);
        return replyFrame(&out);
    }

    fn handleCancelClear(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        const revision = request.u64Field("revision") catch return errorReply(a, request.id, error.BadRequest);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        const canceled = self.inbox.cancelClear(revision, &self.cancel);
        if (canceled and self.task != null) self.cancel.cancel();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("canceled", canceled);
        return replyFrame(&out);
    }

    fn handleConfirming(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        const active = request.boolField("active", false) catch return errorReply(a, request.id, error.BadRequest);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        // Only the claim barrier moves: no task is paused, canceled or started.
        self.inbox.pauseClaims(active);
        // The real encoder (same as `snapshot`) guarantees the caller adopts the
        // revision produced by this change instead of trusting a local guess.
        return self.replySnapshot(a, request, connection_id);
    }

    fn handleApprove(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        const permission_id = request.u64Field("permission_id") catch return errorReply(a, request.id, error.BadRequest);
        const allow = request.boolField("allow", false) catch return errorReply(a, request.id, error.BadRequest);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        // Authorizing a request whose visible detail is a clipped prefix would
        // approve a command the viewer never saw. Refuse the allow explicitly
        // instead of quietly running it; denying is always safe and stays open.
        if (allow and self.pending_detail_incomplete and self.pending_permission == permission_id) {
            return errorReply(a, request.id, error.InputTooLarge);
        }
        const decision: r.Decision = if (allow) .allow_once else .deny;
        // Bridge.decide is the authority: a stale id, a cleared request or a
        // cancelled task answers false and the tool is not executed.
        if (!self.bridge.decide(permission_id, decision)) return errorReply(a, request.id, error.PermissionExpired);
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    fn handleEnqueue(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        const kind = request.stringEnum(protocol.QueueKind, "kind") catch return errorReply(a, request.id, error.BadRequest);
        const text = request.stringField("text", null) catch |err| return errorReply(a, request.id, err);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        const queued = self.inbox.enqueue(self.allocator, kind.toInbox(), text) catch |err| return errorReply(a, request.id, err);
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("queue", queued);
        return replyFrame(&out);
    }

    fn handleWithdraw(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        const queue_id = request.u64Field("queue_id") catch return errorReply(a, request.id, error.BadRequest);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        var entry = self.inbox.withdraw(queue_id) orelse return errorReply(a, request.id, error.QueueEmpty);
        defer entry.deinit();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("text", entry.text);
        return replyFrame(&out);
    }

    fn handleQueueResume(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        self.inbox.@"resume"();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("revision", self.inbox.snapshot().revision);
        return replyFrame(&out);
    }

    // -----------------------------------------------------------------------
    // Settings (idle owner-thread callbacks)
    // -----------------------------------------------------------------------

    /// Socket-only idle guard for read-only projections. A viewer must be able
    /// to read the settings projection while its control epoch is still being
    /// established, so the first frame always renders.
    fn requireIdleSocket(self: *SessionHost, connection_id: u64) !void {
        if (self.controllerFor(connection_id) == null) return error.StaleControl;
        try self.ensureIdle();
        if (self.fatal != null) return error.Unavailable;
    }

    /// Every settings mutation is bound to the socket AND its current control
    /// epoch: a re-attach on the same socket issues a new epoch, so a cached
    /// frame carrying the previous epoch can never mutate this session.
    fn requireLiveControl(self: *SessionHost, request: *const protocol.Request, connection_id: u64) !void {
        const epoch = request.u64Field("epoch") catch return error.BadRequest;
        try self.requireControl(connection_id, epoch);
        if (self.fatal != null) return error.Unavailable;
    }

    fn requireEffortControl(self: *SessionHost, request: *const protocol.Request, connection_id: u64) !void {
        try self.requireLiveControl(request, connection_id);
        if (self.task) |owned| {
            if (owned.joined) if (self.session.app) |app| {
                if (app.runtime.poisoned) return error.UnsafeToContinue;
            };
        } else try self.ensureIdle();
    }

    fn requireIdleControl(self: *SessionHost, request: *const protocol.Request, connection_id: u64) !void {
        try self.requireLiveControl(request, connection_id);
        try self.ensureIdle();
    }

    fn replySettings(self: *SessionHost, a: std.mem.Allocator, id: u64) ![]u8 {
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(id);
        const state = self.connection.current();
        // A real owner-reported readiness flag for the remote frontend. It is
        // true only when a configured Runtime exists (or the owner explicitly
        // reports an attachable session); a model string alone is never ready.
        try out.field("available", state.runtime != null or state.available);
        try out.field("model", state.model);
        try out.field("selection_name", state.selection_name);
        try out.field("base_url", state.base_url);
        try out.field("provider", if (state.provider) |provider| provider.slug() else @as(?[]const u8, null));
        try out.beginArray("allowed_providers");
        for (allowed) |value| try out.arrayValue(value);
        try out.endArray();
        try out.field("configured", state.configured_providers);
        try out.field("allow_custom_models", state.allow_custom_models);
        try out.field("context_limit", state.context_limit);
        try out.field("context_official", state.context_official);
        if (state.initial_context) |context| {
            try out.beginObject("initial_context");
            try out.field("tokens", context.tokens);
            try out.field("limit", context.limit);
            try out.field("known", context.known);
            try out.endObject();
        } else try out.field("initial_context", @as(?u8, null));
        if (self.context) |context| {
            try out.beginObject("context");
            try out.field("tokens", context.tokens);
            try out.field("limit", context.limit);
            try out.field("known", context.known);
            try out.endObject();
        } else try out.field("context", @as(?u8, null));
        try out.field("low_price_input", state.low_price_input);
        try out.field("low_price_input_enabled", state.low_price_input_enabled);
        try out.field("image_enabled", state.image_enabled);
        try out.field("image_model", state.image_model);
        // Proxy projection: presence of a configuration is the only enable
        // state; address/port are the one non-secret host/port pair allowed on
        // the wire. Never a scheme, credential, header or path.
        try out.field("proxy_configured", state.proxy_configured);
        try out.field("proxy_address", state.proxy_address);
        try out.field("proxy_port", state.proxy_port);
        try encodeProxyModels(&out, state.proxy_models);
        try out.field("memory_auto", state.memory_auto);
        try protocol.encodeMemoryView(&out, state.memory);
        // Dynamic child rows belong to snapshots, not the settings reply.
        try out.field("decision_enabled", state.decision_enabled);
        try out.field("decision_model", state.decision_model);
        try out.field("global_settings_available", state.global_settings_available);
        try out.field("settings_notice", state.settings_notice);
        try out.field("settings_error", if (state.settings_error) |err| @as(?[]const u8, @errorName(err)) else @as(?[]const u8, null));
        try out.field("metadata_notice", state.metadata_notice);
        try out.field("metadata_ttl_ms", state.metadata_notice_ttl_ms);
        try out.field("effort", state.reasoning_effort.name());
        try out.field("pending_effort", if (state.pending_default_effort) |effort| effort.name() else @as(?[]const u8, null));
        try out.field("log_error", if (state.log_error) |err| @as(?[]const u8, @errorName(err)) else @as(?[]const u8, null));
        try out.field("read_only", self.session.read_only);
        try out.field("project", self.project);
        try out.field("session", self.session.session_id);

        try out.beginObject("limits");
        try out.field("command_timeout_ms", state.limits.command_timeout_ms);
        try out.field("low_price_input", state.limits.low_price_input);
        try out.field("request_timeout_ms", state.limits.request_timeout_ms);
        try out.field("compaction_enabled", state.limits.compaction_enabled);
        try out.endObject();

        try out.beginArray("effort_levels");
        for (activity.effort_order) |effort| {
            if (!state.effort_levels.contains(effort)) continue;
            try out.arrayValue(effort.name().?);
        }
        try out.endArray();
        try out.field("effort_levels_known", state.effort_levels.mask != 0);

        try encodeModels(&out, "models", state.models, state.model_context_official, state.model_disabled);
        try encodeModels(&out, "decision_models", state.decision_models, null, null);
        try encodeModels(&out, "image_models", state.image_models, null, null);

        try out.beginArray("providers");
        for (state.model_providers) |provider| {
            try out.beginObjectElement();
            try out.field("name", provider.name);
            try out.field("allow_custom", provider.allow_custom);
            try out.endObject();
        }
        try out.endArray();
        return replyFrame(&out);
    }

    /// Bounded model catalog projection: names plus capability numbers only.
    fn encodeModels(out: *protocol.Out, name: []const u8, models: []const cfg.Model, official: ?[]const bool, disabled: ?[]const bool) !void {
        try out.beginArray(name);
        for (models, 0..) |model, i| {
            try out.beginObjectElement();
            try out.field("name", model.name);
            try out.field("context_tokens", model.context_tokens);
            try out.field("protocol", @tagName(model.protocol));
            try out.field("output_tokens", model.output_tokens);
            if (official) |values| if (i < values.len) try out.field("official", values[i]);
            if (disabled) |values| if (i < values.len) try out.field("disabled", values[i]);
            try out.endObject();
        }
        try out.endArray();
        // One flag per catalog: the three calls share one root object, so a
        // single shared name would duplicate a field and be rejected by a
        // strict parser.
        var flag_buffer: [64]u8 = undefined;
        const flag = try std.fmt.bufPrint(&flag_buffer, "{s}_truncated", .{name});
        try out.field(flag, false);
    }

    /// Bounded proxy allowlist projection: model names only. The list is a
    /// public setting, so a truncated tail is reported instead of silently
    /// shortened; an empty list stays a real JSON array.
    fn encodeProxyModels(out: *protocol.Out, names: []const []const u8) !void {
        try out.beginArray("proxy_models");
        for (names) |name| try out.arrayValue(name);
        try out.endArray();
        try out.field("proxy_models_truncated", false);
    }

    fn handleModelSelect(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const name = request.stringField("name", protocol.max_name) catch |err| return errorReply(a, request.id, err);
        self.connection.selectModel(name) catch |err| return errorReply(a, request.id, err);
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    fn handleEffort(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireEffortControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const raw = request.stringField("value", 16) catch |err| return errorReply(a, request.id, err);
        const effort = activity.ReasoningEffort.fromName(raw);
        if (effort == .unknown or effort == .unspecified) return errorReply(a, request.id, error.InvalidInput);
        self.connection.setEffort(effort) catch |err| return errorReply(a, request.id, err);
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("value", self.connection.current().reasoning_effort.name());
        return replyFrame(&out);
    }

    fn handleCycleEffort(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireEffortControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const callback = self.connection.cycle_effort_fn orelse return errorReply(a, request.id, error.Unsupported);
        const effort = callback(self.connection.context) catch |err| return errorReply(a, request.id, err);
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("value", effort.name());
        return replyFrame(&out);
    }

    fn handleLogin(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const key = request.stringField("key", 4096) catch |err| return errorReply(a, request.id, err);
        defer std.crypto.secureZero(u8, @constCast(key));
        if (request.optionalString("provider")) |slug| {
            const provider = providerFromSlug(slug) orelse return errorReply(a, request.id, error.InvalidInput);
            self.connection.configureProvider(provider, key) catch |err| return errorReply(a, request.id, err);
        } else {
            self.connection.configure(key) catch |err| return errorReply(a, request.id, err);
        }
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    fn handlePreference(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const key_name = request.stringField("key", 64) catch |err| return errorReply(a, request.id, err);
        const key = std.meta.stringToEnum(settings_preferences.Key, key_name) orelse return errorReply(a, request.id, error.InvalidInput);
        const raw_value = request.optionalU64("value") catch return errorReply(a, request.id, error.BadRequest);
        const value: ?u32 = if (raw_value) |parsed| @intCast(@min(parsed, std.math.maxInt(u32))) else null;
        const callback = self.connection.preference_fn orelse return errorReply(a, request.id, error.Unsupported);
        callback(self.connection.context, key, value) catch |err| return errorReply(a, request.id, err);
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    fn handleSetting(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const key_name = request.stringField("key", 64) catch |err| return errorReply(a, request.id, err);
        const key = std.meta.stringToEnum(tui.Connection.Setting, key_name) orelse return errorReply(a, request.id, error.InvalidInput);
        const value = request.boolField("value", false) catch return errorReply(a, request.id, error.BadRequest);
        const callback = self.connection.setting_fn orelse return errorReply(a, request.id, error.Unsupported);
        callback(self.connection.context, key, value) catch |err| return errorReply(a, request.id, err);
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    fn helperChoice(request: *const protocol.Request) !?tui.Connection.DecisionChoice {
        if (request.boolField("off", false) catch return error.BadRequest) return .off;
        const name = request.optionalString("name") orelse return null;
        if (name.len == 0 or name.len > protocol.max_name) return error.InvalidInput;
        return .{ .model = name };
    }

    fn handleDecisionModel(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const choice = helperChoice(request) catch |err| return errorReply(a, request.id, err);
        const callback = self.connection.decision_fn orelse return errorReply(a, request.id, error.Unsupported);
        if (choice) |value| callback(self.connection.context, value) catch |err| return errorReply(a, request.id, err);
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    fn handleImageModel(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const choice = helperChoice(request) catch |err| return errorReply(a, request.id, err);
        const callback = self.connection.image_fn orelse return errorReply(a, request.id, error.Unsupported);
        if (choice) |value| callback(self.connection.context, value) catch |err| return errorReply(a, request.id, err);
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    /// Proxy allowlist mutation. The wire carries only one exact
    /// provider/raw-model id and an explicit enable flag; the owner callback
    /// decides whether an endpoint may exist. Nothing here creates one.
    fn handleProxyModel(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const name = request.stringField("name", protocol.max_name) catch |err| return errorReply(a, request.id, err);
        if (name.len == 0) return errorReply(a, request.id, error.InvalidInput);
        const enabled = request.requiredBool("enabled") catch |err| return errorReply(a, request.id, err);
        const callback = self.connection.proxy_fn orelse return errorReply(a, request.id, error.Unsupported);
        callback(self.connection.context, name, enabled) catch |err| return errorReply(a, request.id, err);
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    /// Explicit proxy endpoint mutation. `value` is mandatory and strict: an
    /// empty string clears the configured endpoint, anything else must parse as
    /// a bare host:port (or [IPv6]:port). The endpoint is validated locally
    /// before the owner callback so a malformed request never reaches it, and a
    /// failed save never republishes a settings projection.
    fn handleProxyAddress(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const value = request.stringField("value", cfg.max_proxy_endpoint_bytes) catch |err| return errorReply(a, request.id, err);
        _ = cfg.parseProxyEndpoint(value) catch return errorReply(a, request.id, error.InvalidProxyEndpoint);
        const callback = self.connection.proxy_address_fn orelse return errorReply(a, request.id, error.Unsupported);
        callback(self.connection.context, value) catch |err| return errorReply(a, request.id, err);
        self.refreshConnection();
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    fn handleCodexLogin(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        const action = request.stringEnum(codex_login.Action, "action") catch return errorReply(a, request.id, error.BadRequest);
        const generation = request.u64Field("generation") catch return errorReply(a, request.id, error.BadRequest);
        switch (action) {
            .start => {
                self.ensureIdle() catch |err| return errorReply(a, request.id, err);
                if (self.fatal != null) return errorReply(a, request.id, error.Unavailable);
                self.session.startCodexLogin() catch |err| return errorReply(a, request.id, err);
            },
            .cancel => self.session.cancelCodexLogin(generation) catch |err| return errorReply(a, request.id, err),
        }
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    fn handleRefresh(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
        const callback = self.connection.refresh_models_fn orelse return errorReply(a, request.id, error.Unsupported);
        callback(self.connection.context) catch |err| return errorReply(a, request.id, err);
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        return replyFrame(&out);
    }

    fn handlePollMetadata(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        // Read-only projection poll: socket-bound but never epoch-bound, so a
        // viewer can render its first frame before control is established.
        self.requireIdleSocket(connection_id) catch |err| return errorReply(a, request.id, err);
        _ = request.boolField("wait", false) catch return errorReply(a, request.id, error.BadRequest);
        const callback = self.connection.poll_models_fn orelse return errorReply(a, request.id, error.Unsupported);
        // The backend idle guard is authoritative; the client's polling hint is not owner state.
        const changed = callback(self.connection.context, true);
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("changed", changed);
        return replyFrame(&out);
    }

    // -----------------------------------------------------------------------
    // Close / shutdown
    // -----------------------------------------------------------------------

    fn handleClose(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        const force = request.boolField("force", false) catch return errorReply(a, request.id, error.BadRequest);
        self.requireControl(connection_id, epoch) catch |err| return errorReply(a, request.id, err);
        if (self.task != null and !force) {
            var out = protocol.Out.init(a);
            defer out.deinit();
            try out.ok(request.id);
            try out.field("accepted", false);
            return replyFrame(&out);
        }
        self.shutdown() catch |err| return errorReply(a, request.id, err);
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("accepted", true);
        return replyFrame(&out);
    }

    fn handleShutdown(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, owner_authorized: bool) ![]u8 {
        if (!owner_authorized) return errorReply(a, request.id, error.Unavailable);
        self.shutdown() catch |err| return errorReply(a, request.id, err);
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("saved", self.saved_on_shutdown);
        try out.field("session", self.session.session_id);
        return replyFrame(&out);
    }

    fn encodeSynthetic(a: std.mem.Allocator, event: r.Event, meta: protocol.EventMeta) ![]u8 {
        return protocol.encodeEventMeta(a, event, meta);
    }
};

fn submitDigest(kind: protocol.TaskKind, text: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(@tagName(kind));
    hash.update(&[_]u8{0});
    hash.update(text);
    return hash.finalResult();
}

/// Length of the longest prefix that fits `maximum`, never inside a codepoint.
fn boundedLen(bytes: []const u8, maximum: usize) usize {
    var n = @min(bytes.len, maximum);
    if (n < bytes.len) {
        while (n > 0 and (bytes[n] & 0xc0) == 0x80) n -= 1;
    }
    return n;
}

fn providerFromSlug(slug: []const u8) ?providers.Id {
    for (providers.Id.all) |provider| {
        if (std.mem.eql(u8, provider.slug(), slug)) return provider;
    }
    return null;
}

const allowed = [_][]const u8{ "deepseek", "opencode-zen", "opencode-go" };

// ---------------------------------------------------------------------------
// Isolated lifecycle test (temp HOME/project, no network, no real config)
// ---------------------------------------------------------------------------

// The first real Runtime model call is held while the owner changes thinking.
// Both the gate and owner-side waits are bounded even on assertion failure.

// A deterministic source implements only the Session FIFO contract. The
// tests below exercise the actual pump/admission path, not a Bridge producer.

// A boundary spy deliberately models the owner-idle argument, not client wait.

// Regression: the snapshot reply used to encode a `Snapshot` whose preview
// slices pointed at the already-returned `snapshotFor` frame. It only passed
// while at most one short preview was queued. Two owned Inbox entries now
// exercise the full reply path (`Out` + `encodeSnapshot`) after stack churn, so
// storage must be caller-owned and every field must come from one Inbox
// snapshot.

// ---------------------------------------------------------------------------
// Focused settings-projection tests (no network, no real config, no API key)
// ---------------------------------------------------------------------------

// Owner-side projection wrapper: keeps every real snapshot field and only
// substitutes the two cleanup budgets, so the reply is checked against values
// a hardcoded encoder could never match by accident.

// Records whether one settings mutation actually reached the owner callback.

// Exact `"name":value,` projection of one public budget field. The limits
// object is a flat scalar envelope, so the field name plus the exact digits
// and their separator identifies the value without ambiguity.

// Records every proxy mutation that actually reached the owner callback. The
// name is copied into owned storage because the request document dies first.

// Owner-side projection wrapper for the public proxy settings only.

// Records the exact endpoint string handed to the owner callback. The value is
// copied because the request document dies before the assertion runs.

// Test-only pairing of a fake settings view with the endpoint recorder. Both
// the current projection and the save callback share one hosted context, so a
// raw cast to either half would corrupt the other; every entry point forwards
// to its own half instead.

// Settings view that overrides only the catalog slices, so the reply can be
// checked with more than one model, provider and effort level.

// The whole reply must parse: the frontend runs `json.loads` over it, so a
// missing comma between array elements is a hard startup failure even though
// every field is present.
