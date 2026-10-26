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
//! - `pump` drains the Bridge on the owner thread, so a slow or absent viewer
//!   never backpressures the Runtime. Nothing in an IPC handler reads
//!   `runtime.messages()` or other live Runtime slices.
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
const App = @import("app.zig").App;
const Session = @import("session.zig").Session;
const bridge_mod = @import("../ui/bridge.zig");
const Bridge = bridge_mod.Bridge;
const tui = @import("../ui/tui.zig");
const session_client = @import("../ui/session_client.zig");
const activity = @import("../presentation/activity.zig");
const protocol = @import("../daemon/protocol.zig");

const Io = std.Io;

/// The anonymous `Job.kind` enum has no public declaration; recover its type.
const JobKind = std.meta.FieldType(task.Job, .kind);

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
    logging: bool = true,
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
    const max_count_default: usize = 1024;

    allocator: std.mem.Allocator,
    items: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    max_count: usize = max_count_default,
    budget: usize = 2 * 1024 * 1024,

    fn deinit(self: *Ring) void {
        for (self.items.items) |entry| self.allocator.free(entry.json);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn push(self: *Ring, seq: u64, json: []u8) !void {
        errdefer self.allocator.free(json);
        try self.items.append(self.allocator, .{ .seq = seq, .json = json });
        self.bytes +|= json.len;
        while (self.items.items.len > 1 and (self.items.items.len > self.max_count or self.bytes > self.budget)) {
            const oldest = self.items.orderedRemove(0);
            self.bytes -= oldest.json.len;
            self.allocator.free(oldest.json);
        }
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

/// Bounded streaming text accumulator for the in-progress assistant draft.
const Draft = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    truncated: bool = false,

    fn reset(self: *Draft) void {
        self.buf.clearRetainingCapacity();
        self.truncated = false;
    }

    fn append(self: *Draft, bytes: []const u8) void {
        if (self.buf.items.len >= protocol.max_text) {
            self.truncated = true;
            return;
        }
        const room = protocol.max_text - self.buf.items.len;
        var n = @min(room, bytes.len);
        if (n < bytes.len) {
            while (n > 0 and (bytes[n] & 0xc0) == 0x80) n -= 1;
            self.truncated = true;
        }
        self.buf.appendSlice(self.allocator, bytes[0..n]) catch {
            self.truncated = true;
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

const max_tool_name: usize = 256;
/// The Bridge copies at most `item_budget` bytes of text per event, so the
/// owned approval detail can never legitimately be larger. Keeping the whole
/// value is what lets a reconnecting viewer read the real dangerous command
/// tail before it answers; a smaller display bound would silently authorize a
/// command the viewer cannot see.
const max_tool_description: usize = bridge_mod.item_budget;

const Controller = struct {
    epoch: u64,
    connection: u64,
    /// The pending approval id displayed to this controller, if any.
    permission: ?u64 = null,
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

    events: Ring,
    history: Ring,
    next_seq: u64 = 1,
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
        if (options.@"resume" == null and options.logging) {
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
            .logging = options.logging,
            .auto_refresh_models = options.auto_refresh_models,
        });
        errdefer host.session.deinit();
        if (options.@"resume" != null and options.logging and host.session.read_only) return error.SessionInUse;
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

    /// Reload the Session callbacks (and reinstall the checkpoint observer)
    /// after an owner-thread settings/login mutation.
    fn refreshConnection(self: *SessionHost) void {
        self.connection = self.session.connection();
        self.attachInbox();
    }

    fn now(self: *SessionHost) u64 {
        const value = Io.Clock.awake.now(self.io).toMilliseconds();
        return if (value < 0) 0 else @intCast(value);
    }

    // -----------------------------------------------------------------------
    // Bridge pump
    // -----------------------------------------------------------------------

    /// Drain the Bridge and join a finished task. Safe to call at any time on
    /// the owner thread; never allocates for task bookkeeping.
    pub fn pump(self: *SessionHost, now_ms: u64) void {
        _ = now_ms;
        while (self.bridge.pop()) |item| {
            var owned = item;
            defer owned.deinit();
            self.observe(owned.event, owned.display_truncated, owned.canonical_complete);
        }
        self.reapTask();
        self.dispatchNext();
    }

    /// Start one accepted queued (steering/follow-up) message when this host is
    /// idle. Mirrors the local TUI lease transaction: claim, start, commit; a
    /// failed start restores the entry and pauses the queue so nothing is
    /// silently dropped or replayed. Remote clients never launch jobs.
    fn dispatchNext(self: *SessionHost) void {
        if (self.closing or self.fatal != null) return;
        if (self.task != null) return;
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
    fn noteSubmittedUser(self: *SessionHost, text: []const u8) void {
        self.next_user_id +%= 1;
        if (self.next_user_id == 0) self.next_user_id = 1;
        const meta = protocol.EventMeta{ .epoch = 0, .truncated = false, .canonical_complete = true };
        const event: r.Event = .{ .user_committed = .{ .id = self.next_user_id, .text = text } };
        self.pushHistory(self.takeSeq(), event, meta);
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
        switch (event) {
            .state => |phase| self.phase = phase,
            .context_snapshot => |snapshot| self.context = snapshot,
            .permission => |permission| self.setPending(permission.id, permission.tool_name, permission.description, display_truncated),
            .permission_cleared => |id| {
                if (self.pending_permission == id) self.clearPending();
            },
            .text => |bytes| self.partial_text.append(bytes),
            .reasoning => |bytes| self.partial_reasoning.append(bytes),
            .assistant_committed => {
                self.partial_text.reset();
                self.partial_reasoning.reset();
            },
            .tool_started, .finished => {
                self.partial_text.reset();
                self.partial_reasoning.reset();
            },
            .usage => |usage| {
                if (self.context) |snapshot| {
                    const total = usage.value.total();
                    self.context = .{ .tokens = total orelse 0, .limit = snapshot.limit, .known = total != null };
                }
            },
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
        const name_len = boundedLen(tool_name, max_tool_name);
        const desc_len = boundedLen(description, max_tool_description);
        // The Bridge's display budget and this host's own bound are the same
        // budget, so clipping is remembered from either of them: a detail that
        // is not the complete request must never be approved as if it were.
        self.pending_detail_incomplete = display_truncated or name_len < tool_name.len or desc_len < description.len;
        self.pending_permission = id;
        self.pending_name = self.allocator.dupe(u8, tool_name[0..name_len]) catch null;
        self.pending_desc = self.allocator.dupe(u8, description[0..desc_len]) catch null;
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

        owned.future.await(self.io);
        const terminal = self.bridge.takeTerminal() orelse (owned.job.result() catch |err| r.Terminal{ .status = .failed, .detail = err });
        self.last_terminal = terminal;
        self.phase = null;
        self.clearPending();
        self.partial_text.reset();
        self.partial_reasoning.reset();
        if (terminal.status != .success) self.inbox.pause();
        if (terminal.detail) |detail| if (detail == error.CleanupFailed) {
            self.fatal = error.CleanupFailed;
        };
        if (self.session.app) |app| if (app.runtime.poisoned) {
            self.fatal = error.UnsafeToContinue;
        };

        const meta = protocol.EventMeta{ .epoch = 0, .truncated = false, .canonical_complete = true };
        const seq = self.takeSeq();
        const encoded: ?[]u8 = protocol.encodeEventMeta(self.allocator, .{ .finished = terminal }, meta) catch |err| blk: {
            self.fatal = err;
            break :blk null;
        };
        if (encoded) |bytes| {
            self.events.push(seq, bytes) catch |err| {
                self.allocator.free(bytes);
                self.fatal = err;
            };
            const copy = protocol.encodeEventMeta(self.allocator, .{ .finished = terminal }, meta) catch null;
            if (copy) |history_bytes| self.history.push(seq, history_bytes) catch |err| {
                self.allocator.free(history_bytes);
                self.fatal = err;
            };
        }

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
        const max_seed_events: usize = 512;
        var seeded: usize = 0;
        var bytes: usize = 0;
        var user_id: u64 = 0;
        var text_buf = std.ArrayList(u8).empty;
        defer text_buf.deinit(self.allocator);
        for (messages) |message| {
            if (seeded >= max_seed_events or bytes > protocol.max_response / 2) break;
            switch (message.role) {
                .context => continue,
                .user => {
                    text_buf.clearRetainingCapacity();
                    for (message.blocks) |block| {
                        const text = switch (block) {
                            .text => |value| value,
                            else => continue,
                        };
                        if (text_buf.items.len != 0) text_buf.append(self.allocator, '\n') catch return;
                        text_buf.appendSlice(self.allocator, text) catch return;
                        if (text_buf.items.len >= protocol.max_text) break;
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
        self.events.push(seq, encoded) catch |err| {
            self.allocator.free(encoded);
            self.fatal = err;
            return false;
        };
        if (canonicalForHistory(event)) {
            const copy = protocol.encodeEventMeta(self.allocator, event, meta) catch |err| {
                self.fatal = err;
                return false;
            };
            self.history.push(seq, copy) catch |err| {
                self.allocator.free(copy);
                self.fatal = err;
                return false;
            };
        }
        seeded.* += 1;
        return true;
    }

    fn canonicalForHistory(event: r.Event) bool {
        return switch (event) {
            .user_committed, .assistant_committed, .tool_started, .tool_result, .compacted, .compaction_failed => true,
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
        if (self.task != null) return error.Busy;
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
            owned.future.await(self.io);
            _ = self.bridge.takeTerminal();
            self.allocator.free(owned.prompt);
            self.allocator.destroy(owned.job);
            self.task = null;
        }
        // The task is joined. Instance-owned background commands are stopped
        // BEFORE any success reply/closing flag: BackgroundService.deinit
        // cancels all jobs, joins them and panics (fail-stop) when cleanup is
        // unconfirmed. It is idempotent; App/session deinit may call it again.
        if (self.session.app) |app| app.background.deinit();
        // Join guarantees no producer remains; only now is Bridge.close safe.
        self.clearPending();
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

    /// The owner thread released every worker: destroy in shutdown order.
    pub fn deinit(self: *SessionHost) void {
        const a = self.allocator;
        if (self.task) |*owned| {
            self.cancel.cancel();
            owned.future.await(self.io);
            a.free(owned.prompt);
            a.destroy(owned.job);
            self.task = null;
        }
        self.clearPending();
        self.bridge.deinit();
        self.inbox.deinit();
        self.partial_text.deinit();
        self.partial_reasoning.deinit();
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
        return switch (request.op) {
            .hello => self.replyHello(a, request.id),
            .snapshot => self.replySnapshot(a, request, connection_id),
            .attach => self.handleAttach(a, request, connection_id),
            .detach => self.handleDetach(a, request, connection_id),
            .events => self.handleEvents(a, request, connection_id),
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
            .refresh_models => self.handleRefresh(a, request, connection_id),
            .poll_metadata => self.handlePollMetadata(a, request, connection_id),
            .close => self.handleClose(a, request, connection_id),
            .shutdown => self.handleShutdown(a, request, owner_authorized),
            .ping => self.replyPing(a, request.id),
            .create, .list => errorReply(a, request.id, error.Unsupported),
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
        try out.field("pid", std.os.linux.getpid());
        try out.field("protocol", protocol.version);
        return replyFrame(&out);
    }

    fn replyPing(self: *SessionHost, a: std.mem.Allocator, id: u64) ![]u8 {
        _ = self;
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(id);
        try out.field("pid", std.os.linux.getpid());
        return replyFrame(&out);
    }

    /// Caller-owned projection storage. `queue` keeps the bytes the preview
    /// slices point at alive; `previews` receives the encoded preview structs.
    /// The returned `Snapshot` borrows both, so it must not outlive the caller
    /// frame that owns them.
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
            .logging = self.session.logging,
            .read_only = self.session.read_only,
            .truncated = self.fatal != null or self.reset_failed != null or self.events.oldestSeq() != null and self.events.oldestSeq().? > 1,
        };
    }

    /// `snapshot` may carry `receipt:u64` to read the disposition of an earlier
    /// submission without resending it. The query is strictly read-only: it
    /// never starts, retries or cancels a task; an unknown or already evicted
    /// nonce reports `receipt_known=false` instead of pretending acceptance.
    fn replySnapshot(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        // Both stores live in this frame and stay valid through encoding: one
        // Inbox snapshot supplies the counts, the revision and the preview text.
        const queue = self.inbox.snapshot();
        var previews: [protocol.max_previews]protocol.QueuePreview = undefined;
        try protocol.encodeSnapshot(&out, self.snapshotFor(connection_id, &queue, previews[0..]));
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
        self.controller = .{ .epoch = self.epoch_seq, .connection = connection_id, .permission = self.pending_permission };
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

    /// Reserved space for JSON framing, field names and the error path.
    const response_reserve: usize = 16 * 1024;

    fn handleEvents(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        _ = connection_id;
        const since = request.u64Field("since") catch return errorReply(a, request.id, error.BadRequest);
        const requested_max = request.optionalU64("max") catch null;
        const maximum: usize = @intCast(@min(requested_max orelse @as(u64, protocol.max_events), @as(u64, protocol.max_events)));
        const requested_wait = request.optionalU64("wait_ms") catch null;
        const wait_ms: u32 = @intCast(@min(requested_wait orelse 0, 20));

        // Short cooperative wait: dispatch runs on the owner thread, so long
        // polling would starve other connections. Clients simply poll again.
        var waited: u32 = 0;
        while (waited < wait_ms) : (waited += 5) {
            if (self.events.newestSeq()) |newest| if (newest > since) break;
            std.Io.sleep(self.io, .fromMilliseconds(5), .awake) catch break;
            self.pump(self.now());
        }

        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        const oldest = self.events.oldestSeq();
        const reset = if (oldest) |value| since != 0 and since + 1 < value else false;
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
                if (used + entry.json.len + 1 > budget) {
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
        const base: u64 = if (self.next_seq == 0) 0 else self.next_seq - 1;

        // Encode the current-state rows first: they must always fit, so their
        // exact size reserves space before the canonical window is chosen.
        var synthetic: [6]?[]u8 = @splat(null);
        defer for (&synthetic) |*item| if (item.*) |json| a.free(json);
        var synthetic_count: usize = 0;
        var synthetic_bytes: usize = 0;
        {
            var scratch = SyntheticWriter{ .host = self, .a = a, .list = &synthetic, .count = &synthetic_count, .bytes = &synthetic_bytes };
            scratch.add(.{ .text = self.partial_text.buf.items }, self.partial_text.buf.items.len != 0);
            scratch.add(.{ .reasoning = self.partial_reasoning.buf.items }, self.partial_reasoning.buf.items.len != 0);
            if (self.phase) |phase| scratch.add(.{ .state = phase }, true);
            if (self.context) |context| scratch.add(.{ .context_snapshot = context }, true);
            // Replay the real owned approval detail, never an empty placeholder.
            if (self.pending_permission != null and self.pending_name != null and self.pending_desc != null) {
                // The rebuilt row keeps the stored clipping flag, so a viewer
                // that reconnects knows the detail is not the whole request.
                scratch.addWith(
                    .{ .permission = .{ .id = self.pending_permission.?, .tool_name = self.pending_name.?, .description = self.pending_desc.? } },
                    true,
                    self.pending_detail_incomplete,
                );
            }
            if (self.task == null) if (self.last_terminal) |terminal| scratch.add(.{ .finished = terminal }, true);
            synthetic_bytes = scratch.total;
        }

        const budget = if (protocol.max_response > response_reserve + synthetic_bytes)
            protocol.max_response - response_reserve - synthetic_bytes
        else
            0;
        const entries = self.history.items.items;
        var used: usize = 0;
        var start: usize = entries.len;
        var taken: usize = 0;
        while (start > 0 and taken < limit) {
            const entry = entries[start - 1];
            if (used + entry.json.len + 1 > budget) break;
            used += entry.json.len + 1;
            start -= 1;
            taken += 1;
        }
        const truncated = start != 0 or taken == 0 and entries.len != 0 or (self.events.oldestSeq() orelse 1) > 1;

        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("base", base);
        try out.beginArray("entries");
        // Canonical blocks first, oldest to newest.
        for (entries[start..]) |entry| try out.element(entry.json);
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
        host: *SessionHost,
        a: std.mem.Allocator,
        list: *[6]?[]u8,
        count: *usize,
        bytes: *usize,
        total: usize = 0,

        fn add(self: *SyntheticWriter, event: r.Event, enable: bool) void {
            self.addWith(event, enable, false);
        }

        fn addWith(self: *SyntheticWriter, event: r.Event, enable: bool, truncated: bool) void {
            if (!enable or self.count.* >= self.list.len) return;
            const meta = protocol.EventMeta{ .epoch = 0, .truncated = truncated, .canonical_complete = true };
            const json = encodeSynthetic(self.a, event, meta) catch return;
            self.list[self.count.*] = json;
            self.count.* += 1;
            self.total += json.len + 1;
        }
    };

    fn handleSubmit(self: *SessionHost, a: std.mem.Allocator, request: *const protocol.Request, connection_id: u64) ![]u8 {
        const epoch = request.u64Field("epoch") catch return errorReply(a, request.id, error.BadRequest);
        const receipt_id = request.u64Field("req") catch return errorReply(a, request.id, error.BadRequest);
        // Zero denotes an empty receipt slot; accepting it would disable replay
        // detection for a request whose acknowledgment was lost.
        if (receipt_id == 0) return errorReply(a, request.id, error.BadRequest);
        const kind = request.stringEnum(protocol.TaskKind, "kind") catch return errorReply(a, request.id, error.BadRequest);
        const text = request.stringField("text", protocol.max_text) catch |err| return errorReply(a, request.id, err);
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
        if (kind == .prompt) self.noteSubmittedUser(text);
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("accepted", true);
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
        const text = request.stringField("text", protocol.max_text) catch |err| return errorReply(a, request.id, err);
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
    fn requireIdleControl(self: *SessionHost, request: *const protocol.Request, connection_id: u64) !void {
        const epoch = request.u64Field("epoch") catch return error.BadRequest;
        try self.requireControl(connection_id, epoch);
        try self.ensureIdle();
        if (self.fatal != null) return error.Unavailable;
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
        // Proxy allowlist projection: configured flag plus the exact bounded
        // model ids. Never an endpoint, a port or a credential.
        try out.field("proxy_configured", state.proxy_configured);
        try encodeProxyModels(&out, state.proxy_models);
        try out.field("memory_auto", state.memory_auto);
        try out.field("memory_notice", state.memory_notice);
        try out.field("decision_enabled", state.decision_enabled);
        try out.field("decision_model", state.decision_model);
        try out.field("global_settings_available", state.global_settings_available);
        try out.field("logging", state.logging_enabled);
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
        try out.field("command_max_timeout_ms", state.limits.command_max_timeout_ms);
        try out.field("read_bytes", state.limits.read_bytes);
        try out.field("output_bytes", state.limits.output_bytes);
        try out.field("max_input_tokens", state.limits.max_input_tokens);
        try out.field("low_price_input", state.limits.low_price_input);
        try out.field("input_margin_tokens", state.limits.input_margin_tokens);
        try out.field("safety_tokens", state.limits.safety_tokens);
        try out.field("request_timeout_ms", state.limits.request_timeout_ms);
        try out.field("task_timeout_ms", state.limits.task_timeout_ms);
        // Published so a spawning owner can bound its TERM->KILL cleanup to the
        // configured budgets instead of an unconditional 30s fallback. Plain
        // numbers only; no raw config and no credential bytes.
        try out.field("cleanup_grace_ms", state.limits.cleanup_grace_ms);
        try out.field("cleanup_timeout_ms", state.limits.cleanup_timeout_ms);
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
        const limit: usize = @min(models.len, 256);
        try out.beginArray(name);
        for (models[0..limit], 0..) |model, i| {
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
        try out.field(flag, models.len > limit);
    }

    /// Bounded proxy allowlist projection: model names only. The list is a
    /// public setting, so a truncated tail is reported instead of silently
    /// shortened; an empty list stays a real JSON array.
    fn encodeProxyModels(out: *protocol.Out, names: []const []const u8) !void {
        const limit: usize = @min(names.len, max_proxy_models);
        try out.beginArray("proxy_models");
        for (names[0..limit]) |name| try out.arrayValue(name);
        try out.endArray();
        try out.field("proxy_models_truncated", names.len > limit);
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
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
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
        self.requireIdleControl(request, connection_id) catch |err| return errorReply(a, request.id, err);
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
        const wait = request.boolField("wait", false) catch return errorReply(a, request.id, error.BadRequest);
        const callback = self.connection.poll_models_fn orelse return errorReply(a, request.id, error.Unsupported);
        const changed = callback(self.connection.context, wait);
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
/// Publication bound for the proxy allowlist, mirroring the model catalogs.
const max_proxy_models: usize = 256;

// ---------------------------------------------------------------------------
// Isolated lifecycle test (temp HOME/project, no network, no real config)
// ---------------------------------------------------------------------------

fn dispatchJson(host: *SessionHost, a: std.mem.Allocator, json: []const u8, connection: u64) ![]u8 {
    var request = try protocol.parseRequest(a, json);
    defer request.deinit();
    return host.dispatch(a, &request, connection, true);
}

test "host lifecycle: attach snapshot settings queue and rejection paths" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    const home = project;

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &env, .{ .project = project, .id = id, .logging = false, .owner = .foreground });
    defer host.deinit();

    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":1,\"op\":\"hello\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"protocol\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"owner\":\"foreground\"") != null);
    }
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":2,\"op\":\"snapshot\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"busy\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"read_only\":false") != null);
    }
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":3,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"effort\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"available\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "api_key") == null);
    }
    // Attach assigns an epoch bound to this connection.
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":4,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"epoch\":1") != null);
    }
    // A second controller is refused without takeover.
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":5,\"op\":\"attach\",\"write\":true}", 8);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "busy") != null);
    }
    // Another connection cannot act with the first connection's epoch.
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":6,\"op\":\"submit\",\"epoch\":1,\"req\":10,\"kind\":\"prompt\",\"text\":\"hi\"}", 8);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "stale_control") != null);
    }
    // Queue enqueue/withdraw uses its own field name and is connection bound.
    var queued_id: u64 = 0;
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":7,\"op\":\"enqueue\",\"epoch\":1,\"kind\":\"steering\",\"text\":\"more\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        const at = std.mem.indexOf(u8, frame, "\"queue\":").?;
        queued_id = try std.fmt.parseInt(u64, frame[at + 8 .. std.mem.indexOfScalarPos(u8, frame, at, '}').?], 10);
    }
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":8,\"op\":\"withdraw\",\"epoch\":1,\"queue_id\":9,\"text\":\"x\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
    }
    {
        const buf = try std.fmt.allocPrint(a, "{{\"v\":1,\"id\":9,\"op\":\"withdraw\",\"epoch\":1,\"queue_id\":{d}}}", .{queued_id});
        defer a.free(buf);
        const frame = try dispatchJson(host, a, buf, 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"text\":\"more\"") != null);
    }
    // Approvals for an id that is not pending are rejected by the Bridge.
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":10,\"op\":\"approve\",\"epoch\":1,\"permission_id\":3,\"allow\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "permission_expired") != null);
    }
    // History base is the last represented sequence and includes current state.
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":11,\"op\":\"history\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"entries\":[") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"base\":") != null);
    }
    // Disconnect revokes the controller but keeps the host usable.
    host.disconnected(7);
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":12,\"op\":\"attach\",\"write\":true}", 8);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"epoch\":2") != null);
    }
    try host.shutdown();
    try std.testing.expect(host.isClosing());
}

fn parseJson(a: std.mem.Allocator, frame: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, frame, .{ .allocate = .alloc_always });
}

fn snapshotRevision(a: std.mem.Allocator, frame: []const u8) !u64 {
    // The reply root is `{v,id,ok,snapshot:{...}}`; the queue revision lives in
    // the nested snapshot object. Parse the whole frame strictly so a malformed
    // or duplicated field fails the assertion instead of being guessed.
    var parsed = std.json.parseFromSlice(std.json.Value, a, frame, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory) err else error.InvalidSnapshot;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidSnapshot,
    };
    switch (root.get("ok") orelse return error.InvalidSnapshot) {
        .bool => |ok| if (!ok) return error.InvalidSnapshot,
        else => return error.InvalidSnapshot,
    }
    const snapshot = switch (root.get("snapshot") orelse return error.InvalidSnapshot) {
        .object => |object| object,
        else => return error.InvalidSnapshot,
    };
    const revision = switch (snapshot.get("queue_revision") orelse return error.InvalidSnapshot) {
        .integer => |value| value,
        else => return error.InvalidSnapshot,
    };
    if (revision < 0) return error.InvalidSnapshot;
    return @intCast(revision);
}

test "confirming barrier is controller-bound and released with its view" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &env, .{ .project = project, .id = id, .logging = false, .owner = .foreground });
    defer host.deinit();

    const first = try dispatchJson(host, a, "{\"v\":1,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"epoch\":1") != null);
    const base_rev = host.inbox.snapshot().revision;

    // Pausing claims moves the real revision and the reply already carries it.
    const paused = try dispatchJson(host, a, "{\"v\":1,\"id\":2,\"op\":\"confirming\",\"epoch\":1,\"active\":true}", 7);
    defer a.free(paused);
    try std.testing.expect(std.mem.indexOf(u8, paused, "\"ok\":true") != null);
    try std.testing.expect(host.inbox.snapshot().confirming);
    const paused_rev = try snapshotRevision(a, paused);
    try std.testing.expect(paused_rev != base_rev);
    try std.testing.expectEqual(paused_rev, host.inbox.snapshot().revision);

    // A foreign socket and a stale epoch can neither read nor release it.
    const foreign = try dispatchJson(host, a, "{\"v\":1,\"id\":3,\"op\":\"confirming\",\"epoch\":1,\"active\":false}", 8);
    defer a.free(foreign);
    try std.testing.expect(std.mem.indexOf(u8, foreign, "stale_control") != null);
    const stale = try dispatchJson(host, a, "{\"v\":1,\"id\":4,\"op\":\"confirming\",\"epoch\":9,\"active\":false}", 7);
    defer a.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "stale_control") != null);
    try std.testing.expect(host.inbox.snapshot().confirming);
    try std.testing.expectEqual(paused_rev, host.inbox.snapshot().revision);

    // A refused takeover leaves the owner's barrier alone.
    const refused = try dispatchJson(host, a, "{\"v\":1,\"id\":5,\"op\":\"attach\",\"write\":true}", 8);
    defer a.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "busy") != null);
    try std.testing.expect(host.inbox.snapshot().confirming);

    // An explicit resume is real: the flag drops and the revision moves again.
    const resumed = try dispatchJson(host, a, "{\"v\":1,\"id\":6,\"op\":\"confirming\",\"epoch\":1,\"active\":false}", 7);
    defer a.free(resumed);
    try std.testing.expect(!host.inbox.snapshot().confirming);
    try std.testing.expect((try snapshotRevision(a, resumed)) != paused_rev);

    // A granted takeover retires the previous owner's barrier.
    const again = try dispatchJson(host, a, "{\"v\":1,\"id\":7,\"op\":\"confirming\",\"epoch\":1,\"active\":true}", 7);
    defer a.free(again);
    try std.testing.expect(host.inbox.snapshot().confirming);
    const takeover = try dispatchJson(host, a, "{\"v\":1,\"id\":8,\"op\":\"attach\",\"write\":true,\"takeover\":true}", 8);
    defer a.free(takeover);
    try std.testing.expect(std.mem.indexOf(u8, takeover, "\"epoch\":2") != null);
    try std.testing.expect(!host.inbox.snapshot().confirming);
    // The old socket's epoch is dead, so it cannot re-open the barrier.
    const old = try dispatchJson(host, a, "{\"v\":1,\"id\":9,\"op\":\"confirming\",\"epoch\":1,\"active\":true}", 7);
    defer a.free(old);
    try std.testing.expect(std.mem.indexOf(u8, old, "stale_control") != null);
    try std.testing.expect(!host.inbox.snapshot().confirming);

    // EOF releases the controlling socket only; a non-owner EOF changes nothing.
    const paused_new = try dispatchJson(host, a, "{\"v\":1,\"id\":10,\"op\":\"confirming\",\"epoch\":2,\"active\":true}", 8);
    defer a.free(paused_new);
    try std.testing.expect(host.inbox.snapshot().confirming);
    host.disconnected(7);
    try std.testing.expect(host.inbox.snapshot().confirming);
    host.disconnected(8);
    try std.testing.expect(!host.inbox.snapshot().confirming);

    // A stale detach does not release; the live epoch does.
    const third = try dispatchJson(host, a, "{\"v\":1,\"id\":11,\"op\":\"attach\",\"write\":true}", 9);
    defer a.free(third);
    try std.testing.expect(std.mem.indexOf(u8, third, "\"epoch\":3") != null);
    const paused_third = try dispatchJson(host, a, "{\"v\":1,\"id\":12,\"op\":\"confirming\",\"epoch\":3,\"active\":true}", 9);
    defer a.free(paused_third);
    const stale_detach = try dispatchJson(host, a, "{\"v\":1,\"id\":13,\"op\":\"detach\",\"epoch\":3}", 7);
    defer a.free(stale_detach);
    try std.testing.expect(host.inbox.snapshot().confirming);
    const detach = try dispatchJson(host, a, "{\"v\":1,\"id\":14,\"op\":\"detach\",\"epoch\":3}", 9);
    defer a.free(detach);
    try std.testing.expect(!host.inbox.snapshot().confirming);

    try host.shutdown();
}

test "history reply is valid JSON with truncated outside the entries array" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &env, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    // Startup canonical rows, exactly as a restored checkpoint publishes them.
    const messages = [_]p.Message{
        .{ .role = .context, .blocks = &.{.{ .text = "machine prefix must not be displayed" }} },
        .{ .role = .user, .blocks = &.{.{ .text = "first question" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "first answer" }} },
    };
    host.seedHistory(&messages);
    try std.testing.expect(host.history.items.items.len == 2);

    const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":21,\"op\":\"history\",\"limit\":4}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("ok").?.bool);
    try std.testing.expect(object.get("truncated") != null);
    try std.testing.expectEqual(std.json.Value{ .bool = false }, object.get("truncated").?);
    const entries = object.get("entries").?.array.items;
    var saw_user = false;
    var saw_assistant = false;
    var saw_prefix = false;
    for (entries) |entry| {
        const kind = entry.object.get("t").?.string;
        if (std.mem.eql(u8, kind, "user")) {
            const value = entry.object.get("v").?;
            if (std.mem.eql(u8, value.string, "first question")) saw_user = true;
        }
        if (std.mem.eql(u8, kind, "assistant")) {
            const blocks = entry.object.get("blocks").?.array.items;
            for (blocks) |block| {
                const text = block.object.get("v") orelse continue;
                if (std.mem.eql(u8, text.string, "first answer")) saw_assistant = true;
                if (std.mem.indexOf(u8, text.string, "machine prefix") != null) saw_prefix = true;
            }
        }
    }
    try std.testing.expect(saw_user and saw_assistant and !saw_prefix);
    try std.testing.expect(object.get("base").?.integer > 0);
}

test "bridge display metadata is stored and the approval detail survives reconnect" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    // A truncated canonical array must keep both flags in the stored ring.
    const blocks = try a.alloc(p.Block, protocol.max_blocks + 1);
    defer a.free(blocks);
    for (blocks) |*block| block.* = .{ .text = "x" };
    host.observe(.{ .assistant_committed = blocks }, true, false);
    const stored = host.history.items.items[host.history.items.items.len - 1].json;
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"disp_trunc\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"canon_complete\":false") != null);
    // Stored events are epoch-free: old history replays after takeover.
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"epoch\":0") != null);

    host.setPending(9, "bash", "rm -rf /var/tmp/x", false);
    const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":22,\"op\":\"history\"}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    var saw_permission = false;
    for (parsed.value.object.get("entries").?.array.items) |entry| {
        if (!std.mem.eql(u8, entry.object.get("t").?.string, "permission")) continue;
        try std.testing.expectEqual(@as(i64, 9), entry.object.get("id").?.integer);
        try std.testing.expectEqualStrings("bash", entry.object.get("name").?.string);
        try std.testing.expectEqualStrings("rm -rf /var/tmp/x", entry.object.get("desc").?.string);
        saw_permission = true;
    }
    try std.testing.expect(saw_permission);
    host.clearPending();
}

test "long approval detail survives reconnect whole and stays approvable" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    // 12 KiB of a real destructive command: far past the old 4096 display
    // bound but inside the Bridge's 64 KiB per-event budget.
    const command = try a.alloc(u8, 12 * 1024);
    defer a.free(command);
    @memset(command, 'x');
    @memcpy(command[0.."rm -rf /".len], "rm -rf /");
    @memcpy(command[command.len - 3 ..], "-rf");

    const runtime_host = host.bridge.host();
    try runtime_host.emit_fn(runtime_host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = command } }, &host.cancel);
    host.pump(0);
    try std.testing.expectEqual(@as(?u64, 1), host.pending_permission);
    try std.testing.expect(!host.pending_detail_incomplete);
    try std.testing.expectEqual(command.len, host.pending_desc.?.len);

    // A reconnected viewer sees the whole command and no clipping marker.
    const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":80,\"op\":\"history\"}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    var seen = false;
    for (parsed.value.object.get("entries").?.array.items) |entry| {
        if (!std.mem.eql(u8, entry.object.get("t").?.string, "permission")) continue;
        const desc = entry.object.get("desc").?.string;
        try std.testing.expect(command.len > 4096);
        try std.testing.expectEqualStrings(command, desc);
        try std.testing.expect(entry.object.get("disp_trunc") == null);
        seen = true;
    }
    try std.testing.expect(seen);

    // Offline approval of an untruncated dangerous request still works.
    const attach = try dispatchJson(host, a, "{\"v\":1,\"id\":81,\"op\":\"attach\",\"write\":true}", 1);
    defer a.free(attach);
    const granted = try dispatchJson(host, a, "{\"v\":1,\"id\":82,\"op\":\"approve\",\"epoch\":1,\"permission_id\":1,\"allow\":true}", 1);
    defer a.free(granted);
    try std.testing.expect(std.mem.indexOf(u8, granted, "\"ok\":true") != null);
}

test "a clipped approval detail is never silently allowed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    // Above the Bridge's single-event text budget: the display copy is a prefix.
    const command = try a.alloc(u8, bridge_mod.item_budget + 1024);
    defer a.free(command);
    @memset(command, 'y');

    const runtime_host = host.bridge.host();
    try runtime_host.emit_fn(runtime_host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = command } }, &host.cancel);
    host.pump(0);
    try std.testing.expectEqual(@as(?u64, 1), host.pending_permission);
    try std.testing.expect(host.pending_detail_incomplete);
    // The name is copied first, so the detail keeps the remaining budget.
    try std.testing.expectEqual(bridge_mod.item_budget - "bash".len, host.pending_desc.?.len);

    // The rebuilt row carries the clipping flag instead of looking complete.
    const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":90,\"op\":\"history\"}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    var seen = false;
    for (parsed.value.object.get("entries").?.array.items) |entry| {
        if (!std.mem.eql(u8, entry.object.get("t").?.string, "permission")) continue;
        try std.testing.expectEqual(bridge_mod.item_budget - "bash".len, entry.object.get("desc").?.string.len);
        try std.testing.expectEqual(std.json.Value{ .bool = true }, entry.object.get("disp_trunc").?);
        seen = true;
    }
    try std.testing.expect(seen);

    const attach = try dispatchJson(host, a, "{\"v\":1,\"id\":91,\"op\":\"attach\",\"write\":true}", 1);
    defer a.free(attach);
    // Allowing what the viewer cannot fully see is refused, not applied.
    const refused = try dispatchJson(host, a, "{\"v\":1,\"id\":92,\"op\":\"approve\",\"epoch\":1,\"permission_id\":1,\"allow\":true}", 1);
    defer a.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "input_too_large") != null);
    // Nothing was answered: a deny for the same id is still a live decision.
    const denied = try dispatchJson(host, a, "{\"v\":1,\"id\":93,\"op\":\"approve\",\"epoch\":1,\"permission_id\":1,\"allow\":false}", 1);
    defer a.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "\"ok\":true") != null);
}

test "submit receipt nonce is bound to kind and exact content" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    // Attach a controller epoch on connection 1.
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":30,\"op\":\"attach\",\"write\":true}", 1);
        defer a.free(frame);
    }
    const zero = try dispatchJson(host, a, "{\"v\":1,\"id\":35,\"op\":\"submit\",\"epoch\":1,\"req\":0,\"kind\":\"prompt\",\"text\":\"alpha\"}", 1);
    defer a.free(zero);
    var parsed_zero = try parseJson(a, zero);
    defer parsed_zero.deinit();
    try std.testing.expect(!parsed_zero.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("protocol", parsed_zero.value.object.get("err").?.string);
    try std.testing.expectEqual(@as(usize, 0), host.receipt_next);
    try std.testing.expect(host.task == null);

    const first = try dispatchJson(host, a, "{\"v\":1,\"id\":31,\"op\":\"submit\",\"epoch\":1,\"req\":77,\"kind\":\"prompt\",\"text\":\"alpha\"}", 1);
    defer a.free(first);
    // No credentials: the task is rejected but the rejection is recorded.
    try std.testing.expect(std.mem.indexOf(u8, first, "\"ok\":false") != null);

    const replay = try dispatchJson(host, a, "{\"v\":1,\"id\":32,\"op\":\"submit\",\"epoch\":1,\"req\":77,\"kind\":\"prompt\",\"text\":\"alpha\"}", 1);
    defer a.free(replay);
    var parsed_replay = try parseJson(a, replay);
    defer parsed_replay.deinit();
    try std.testing.expect(parsed_replay.value.object.get("ok").?.bool);
    try std.testing.expect(!parsed_replay.value.object.get("accepted").?.bool);
    try std.testing.expect(parsed_replay.value.object.get("duplicate").?.bool);

    // Same nonce, different content/kind: rejected instead of "already accepted".
    const other_text = try dispatchJson(host, a, "{\"v\":1,\"id\":33,\"op\":\"submit\",\"epoch\":1,\"req\":77,\"kind\":\"prompt\",\"text\":\"beta\"}", 1);
    defer a.free(other_text);
    try std.testing.expect(std.mem.indexOf(u8, other_text, "invalid_input") != null);
    const other_kind = try dispatchJson(host, a, "{\"v\":1,\"id\":34,\"op\":\"submit\",\"epoch\":1,\"req\":77,\"kind\":\"compact\",\"text\":\"alpha\"}", 1);
    defer a.free(other_kind);
    try std.testing.expect(std.mem.indexOf(u8, other_kind, "invalid_input") != null);
}

test "history and event replies are clipped by encoded bytes not ring capacity" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    // Canonical rows of ~60 KiB each; the ring keeps several MiB in total.
    const chunk = try a.alloc(u8, 60 * 1024);
    defer a.free(chunk);
    @memset(chunk, 'a');
    for (0..40) |_| {
        const json = try protocol.encodeEventMeta(a, .{ .user_committed = .{ .id = 1, .text = chunk } }, .{ .epoch = 0, .truncated = false, .canonical_complete = true });
        try host.history.push(host.takeSeq(), json);
        const text_json = try protocol.encodeEventMeta(a, .{ .text = chunk }, .{ .epoch = 0, .truncated = false, .canonical_complete = true });
        try host.events.push(host.takeSeq(), text_json);
    }

    const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":40,\"op\":\"history\",\"limit\":32}", 1);
    defer a.free(frame);
    try std.testing.expect(frame.len <= protocol.max_response);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);

    const events = try dispatchJson(host, a, "{\"v\":1,\"id\":41,\"op\":\"events\",\"since\":0,\"max\":32}", 1);
    defer a.free(events);
    try std.testing.expect(events.len <= protocol.max_response);
    var events_parsed = try parseJson(a, events);
    defer events_parsed.deinit();
    try std.testing.expect(events_parsed.value.object.get("truncated").?.bool);
    try std.testing.expect(events_parsed.value.object.get("next").?.integer > 0);
}

test "direct input is history-only while queued input is rendered exactly once" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    host.noteSubmittedUser("direct prompt");
    host.noteQueuedUser(11, "queued follow-up");

    // The direct prompt is canonical history but was never echoed as an event.
    var direct_in_events = false;
    for (host.events.items.items) |entry| {
        if (std.mem.indexOf(u8, entry.json, "direct prompt") != null) direct_in_events = true;
    }
    try std.testing.expect(!direct_in_events);

    const queued_events = blk: {
        var count: usize = 0;
        for (host.events.items.items) |entry| {
            if (std.mem.indexOf(u8, entry.json, "queued follow-up") != null) count += 1;
        }
        break :blk count;
    };
    try std.testing.expectEqual(@as(usize, 1), queued_events);

    const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":50,\"op\":\"history\",\"limit\":8}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    var direct_rows: usize = 0;
    var queued_rows: usize = 0;
    for (parsed.value.object.get("entries").?.array.items) |entry| {
        const value = entry.object.get("v") orelse continue;
        const text = switch (value) {
            .string => |bytes| bytes,
            else => continue,
        };
        if (std.mem.eql(u8, text, "direct prompt")) direct_rows += 1;
        if (std.mem.eql(u8, text, "queued follow-up")) queued_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), direct_rows);
    try std.testing.expectEqual(@as(usize, 1), queued_rows);
}

test "accepted queue entries are kept and paused when no runtime can start them" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    const attach = try dispatchJson(host, a, "{\"v\":1,\"id\":60,\"op\":\"attach\",\"write\":true}", 1);
    defer a.free(attach);
    const queued = try dispatchJson(host, a, "{\"v\":1,\"id\":61,\"op\":\"enqueue\",\"epoch\":1,\"kind\":\"follow_up\",\"text\":\"next step\"}", 1);
    defer a.free(queued);
    try std.testing.expect(std.mem.indexOf(u8, queued, "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), host.inbox.snapshot().follow_up);

    // No configured Runtime: the pump must not drop or duplicate the message.
    host.pump(0);
    try std.testing.expectEqual(@as(usize, 1), host.inbox.snapshot().follow_up);
    try std.testing.expect(host.task == null);

    // An explicit resume while still unavailable also keeps the message.
    const resumed = try dispatchJson(host, a, "{\"v\":1,\"id\":62,\"op\":\"queue_resume\",\"epoch\":1}", 1);
    defer a.free(resumed);
    host.pump(0);
    try std.testing.expectEqual(@as(usize, 1), host.inbox.snapshot().follow_up);
    var rendered: usize = 0;
    for (host.events.items.items) |entry| {
        if (std.mem.indexOf(u8, entry.json, "next step") != null) rendered += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), rendered);
}

// Regression: the snapshot reply used to encode a `Snapshot` whose preview
// slices pointed at the already-returned `snapshotFor` frame. It only passed
// while at most one short preview was queued. Two owned Inbox entries now
// exercise the full reply path (`Out` + `encodeSnapshot`) after stack churn, so
// storage must be caller-owned and every field must come from one Inbox
// snapshot.
test "snapshot reply encodes caller-owned queued previews consistently" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    const attach = try dispatchJson(host, a, "{\"v\":1,\"id\":80,\"op\":\"attach\",\"write\":true}", 1);
    defer a.free(attach);
    var attach_parsed = try parseJson(a, attach);
    defer attach_parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), attach_parsed.value.object.get("epoch").?.integer);

    const expected = [_][]const u8{ "第一条 \"引号\" 预览", "第二条 中文 \"quotes\" 预览" };
    const enqueued = [_][]const u8{
        "{\"v\":1,\"id\":81,\"op\":\"enqueue\",\"epoch\":1,\"kind\":\"steering\",\"text\":\"第一条 \\\"引号\\\" 预览\"}",
        "{\"v\":1,\"id\":82,\"op\":\"enqueue\",\"epoch\":1,\"kind\":\"follow_up\",\"text\":\"第二条 中文 \\\"quotes\\\" 预览\"}",
    };
    for (enqueued) |request| {
        const reply = try dispatchJson(host, a, request, 1);
        defer a.free(reply);
        var parsed = try parseJson(a, reply);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("ok").?.bool);
    }

    var round: usize = 0;
    while (round < 3) : (round += 1) {
        // Stack churn between rounds: sibling replies reuse the frames that held
        // the previous projection. Only caller-owned storage survives this.
        const churn_requests = [_][]const u8{
            "{\"v\":1,\"id\":83,\"op\":\"history\",\"limit\":8}",
            "{\"v\":1,\"id\":84,\"op\":\"events\",\"since\":0,\"max\":8}",
        };
        for (churn_requests) |request| {
            const churn = try dispatchJson(host, a, request, 1);
            var churn_parsed = try parseJson(a, churn);
            churn_parsed.deinit();
            a.free(churn);
        }

        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":90,\"op\":\"snapshot\"}", 1);
        var parsed = try parseJson(a, frame);
        a.free(frame);
        defer parsed.deinit();
        // Missing or mistyped fields fail the test as errors instead of
        // panicking through `.?` on the optional.
        const Probe = struct {
            fn of(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
                return object.get(name) orelse error.TestExpectedField;
            }
            fn integer(object: std.json.ObjectMap, name: []const u8) !i64 {
                return switch (try of(object, name)) {
                    .integer => |value| value,
                    else => error.TestUnexpectedFieldType,
                };
            }
            fn boolean(object: std.json.ObjectMap, name: []const u8) !bool {
                return switch (try of(object, name)) {
                    .bool => |value| value,
                    else => error.TestUnexpectedFieldType,
                };
            }
            fn string(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
                return switch (try of(object, name)) {
                    .string => |value| value,
                    else => error.TestUnexpectedFieldType,
                };
            }
            fn objectOf(value: std.json.Value) !std.json.ObjectMap {
                return switch (value) {
                    .object => |value_object| value_object,
                    else => error.TestUnexpectedFieldType,
                };
            }
            fn arrayOf(value: std.json.Value) ![]std.json.Value {
                return switch (value) {
                    .array => |value_array| value_array.items,
                    else => error.TestUnexpectedFieldType,
                };
            }
        };

        const root = parsed.value.object;
        try std.testing.expectEqual(true, try Probe.boolean(root, "ok"));
        // protocol.encodeSnapshot publishes every probe field inside the
        // `snapshot` object; the reply root only carries `ok`.
        const object = try Probe.objectOf(try Probe.of(root, "snapshot"));
        try std.testing.expectEqual(@as(i64, 1), try Probe.integer(object, "steering"));
        try std.testing.expectEqual(@as(i64, 1), try Probe.integer(object, "follow_up"));
        try std.testing.expectEqual(@as(i64, 2), try Probe.integer(object, "queue_revision"));
        try std.testing.expectEqual(@as(i64, 2), try Probe.integer(object, "newest_id"));
        try std.testing.expectEqual(@as(i64, @intCast(expected[1].len)), try Probe.integer(object, "newest_bytes"));
        try std.testing.expectEqual(false, try Probe.boolean(object, "queue_paused"));

        const previews = try Probe.arrayOf(try Probe.of(object, "previews"));
        try std.testing.expectEqual(expected.len, previews.len);
        const kinds = [_][]const u8{ "steering", "follow_up" };
        for (previews, 0..) |item, i| {
            const entry = try Probe.objectOf(item);
            try std.testing.expectEqual(@as(i64, @intCast(i + 1)), try Probe.integer(entry, "id"));
            try std.testing.expectEqualStrings(kinds[i], try Probe.string(entry, "kind"));
            try std.testing.expectEqualStrings(expected[i], try Probe.string(entry, "text"));
        }
    }
}

test "snapshot receipt query is read-only and reports known accepted rejected unknown" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    const digest = submitDigest(.prompt, "alpha");
    host.recordReceipt(55, .prompt, digest, true, 42);
    host.recordReceipt(66, .prompt, digest, false, 0);

    // Accepted, rejected and unknown receipts are answered without any task.
    const cases = [_]struct { id: u64, known: bool, accepted: bool, task: i64 }{
        .{ .id = 55, .known = true, .accepted = true, .task = 42 },
        .{ .id = 66, .known = true, .accepted = false, .task = 0 },
        .{ .id = 777, .known = false, .accepted = false, .task = 0 },
    };
    for (cases) |case| {
        const request = try std.fmt.allocPrint(a, "{{\"v\":1,\"id\":70,\"op\":\"snapshot\",\"receipt\":{d}}}", .{case.id});
        defer a.free(request);
        const frame = try dispatchJson(host, a, request, 1);
        defer a.free(frame);
        var parsed = try parseJson(a, frame);
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expect(object.get("ok").?.bool);
        try std.testing.expectEqual(case.known, object.get("receipt_known").?.bool);
        try std.testing.expectEqual(case.accepted, object.get("receipt_accepted").?.bool);
        try std.testing.expectEqual(case.task, object.get("receipt_task").?.integer);
        try std.testing.expect(host.task == null);
        try std.testing.expectEqual(@as(usize, 0), host.events.items.items.len);
        try std.testing.expectEqual(@as(usize, 0), host.history.items.items.len);
    }

    // A malformed nonce is rejected; it never starts work either.
    const bad = try dispatchJson(host, a, "{\"v\":1,\"id\":71,\"op\":\"snapshot\",\"receipt\":\"abc\"}", 1);
    defer a.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "\"ok\":false") != null);
    try std.testing.expect(host.task == null);
}

// ---------------------------------------------------------------------------
// Focused settings-projection tests (no network, no real config, no API key)
// ---------------------------------------------------------------------------

/// Owner-side projection wrapper: keeps every real snapshot field and only
/// substitutes the two cleanup budgets, so the reply is checked against values
/// a hardcoded encoder could never match by accident.
const FakeLimitsView = struct {
    prev_fn: *const fn (*anyopaque) tui.Connection.State,
    prev_context: *anyopaque,
    limits: cfg.Limits,

    fn current(context: *anyopaque) tui.Connection.State {
        const self: *FakeLimitsView = @ptrCast(@alignCast(context));
        var state = self.prev_fn(self.prev_context);
        state.limits = self.limits;
        return state;
    }
};

/// Records whether one settings mutation actually reached the owner callback.
const SettingSink = struct {
    calls: usize = 0,
    last_key: ?tui.Connection.Setting = null,
    last_value: bool = false,

    fn set(context: *anyopaque, key: tui.Connection.Setting, enabled: bool) anyerror!void {
        const self: *SettingSink = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.last_key = key;
        self.last_value = enabled;
    }
};

/// Exact `"name":value,` projection of one public budget field. The limits
/// object is a flat scalar envelope, so the field name plus the exact digits
/// and their separator identifies the value without ambiguity.
fn settingsFieldIs(frame: []const u8, name: []const u8, value: u64) !bool {
    var buf: [96]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "\"{s}\":{d},", .{ name, value });
    return std.mem.indexOf(u8, frame, needle) != null;
}

test "settings reply publishes the configured cleanup budgets" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    // A spawning owner reads these two numbers from the public projection; they
    // must be the configured budgets instead of a fixed 30s fallback.
    {
        var fake = FakeLimitsView{
            .prev_fn = host.connection.current_fn,
            .prev_context = host.connection.context,
            .limits = .{ .cleanup_grace_ms = 4_000, .cleanup_timeout_ms = 12_000 },
        };
        defer {
            host.connection.current_fn = fake.prev_fn;
            host.connection.context = fake.prev_context;
        }
        host.connection.current_fn = FakeLimitsView.current;
        host.connection.context = &fake;
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":30,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        try std.testing.expect(try settingsFieldIs(frame, "cleanup_grace_ms", 4_000));
        try std.testing.expect(try settingsFieldIs(frame, "cleanup_timeout_ms", 12_000));
        // The defaults are not what this projection reports, so the two fields
        // are owner state and not literals in the encoder.
        try std.testing.expect(!try settingsFieldIs(frame, "cleanup_grace_ms", 1_000));
        try std.testing.expect(!try settingsFieldIs(frame, "cleanup_timeout_ms", 5_000));
    }

    // The restored real projection reports its own defaults, so both fields are
    // wired to owner state rather than written as literals in the encoder.
    {
        const defaults: cfg.Limits = .{};
        try std.testing.expectEqual(@as(u32, 1_000), defaults.cleanup_grace_ms);
        try std.testing.expectEqual(@as(u32, 5_000), defaults.cleanup_timeout_ms);
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":31,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        try std.testing.expect(try settingsFieldIs(frame, "cleanup_grace_ms", 1_000));
        try std.testing.expect(try settingsFieldIs(frame, "cleanup_timeout_ms", 5_000));
        // And the fake never leaks into the restored real projection.
        try std.testing.expect(!try settingsFieldIs(frame, "cleanup_grace_ms", 4_000));
        try std.testing.expect(!try settingsFieldIs(frame, "cleanup_timeout_ms", 12_000));
    }
}

test "a re-attach on the same socket invalidates cached settings frames by epoch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":40,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"epoch\":1") != null);
    }
    // The same owner and socket attach again: this is a real new epoch.
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":41,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"epoch\":2") != null);
    }

    var sink = SettingSink{};
    // A cached frame from the replaced epoch is refused before any owner
    // callback runs: no mutation and no persistence.
    {
        host.connection.setting_fn = SettingSink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":42,\"op\":\"setting\",\"epoch\":1,\"key\":\"low_price_input\",\"value\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "stale_control") != null);
        try std.testing.expectEqual(@as(usize, 0), sink.calls);
    }
    // The current epoch on the same socket is allowed and reaches the owner.
    {
        host.connection.setting_fn = SettingSink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":43,\"op\":\"setting\",\"epoch\":2,\"key\":\"low_price_input\",\"value\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") == null);
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
        try std.testing.expectEqual(tui.Connection.Setting.low_price_input, sink.last_key.?);
        try std.testing.expect(sink.last_value);
    }
    // A different socket still has no authority, even with the live epoch.
    {
        host.connection.setting_fn = SettingSink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":44,\"op\":\"setting\",\"epoch\":2,\"key\":\"low_price_input\",\"value\":false}", 8);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "stale_control") != null);
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
    }
    // A missing epoch never degrades to socket-only authority.
    {
        host.connection.setting_fn = SettingSink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":45,\"op\":\"setting\",\"key\":\"low_price_input\",\"value\":false}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
    }
}

/// Records every proxy mutation that actually reached the owner callback. The
/// name is copied into owned storage because the request document dies first.
const ProxySink = struct {
    calls: usize = 0,
    name_len: usize = 0,
    name: [128]u8 = undefined,
    last_enabled: bool = false,

    fn set(context: *anyopaque, name: []const u8, enabled: bool) anyerror!void {
        const self: *ProxySink = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.name_len = @min(name.len, self.name.len);
        @memcpy(self.name[0..self.name_len], name[0..self.name_len]);
        self.last_enabled = enabled;
    }

    fn recorded(self: *const ProxySink) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Owner-side projection wrapper for the public proxy settings only.
const FakeProxyView = struct {
    prev_fn: *const fn (*anyopaque) tui.Connection.State,
    prev_context: *anyopaque,
    configured: bool,
    names: []const []const u8,

    fn current(context: *anyopaque) tui.Connection.State {
        const self: *FakeProxyView = @ptrCast(@alignCast(context));
        var state = self.prev_fn(self.prev_context);
        state.proxy_configured = self.configured;
        state.proxy_models = self.names;
        return state;
    }
};

test "proxy mutations require the live epoch and one exact model id" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    {
        const attached = try dispatchJson(host, a, "{\"v\":1,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(attached);
        try std.testing.expect(std.mem.indexOf(u8, attached, "\"epoch\":1") != null);
    }

    var sink = ProxySink{};

    // The current epoch on the controller socket reaches the owner with the
    // complete provider/raw-model id and the explicit enable flag. A successful
    // mutation refreshes the connection, so the sink is reinstalled per call.
    {
        host.connection.proxy_fn = ProxySink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":2,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"opencode-go/deepseek-v3\",\"enabled\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
        try std.testing.expectEqualStrings("opencode-go/deepseek-v3", sink.recorded());
        try std.testing.expect(sink.last_enabled);
    }
    // Disabling the same entry is a real mutation, not a no-op inference.
    {
        host.connection.proxy_fn = ProxySink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":3,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"opencode-go/deepseek-v3\",\"enabled\":false}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
        try std.testing.expect(!sink.last_enabled);
    }
    // Every later refusal keeps the owner callback untouched.
    host.connection.proxy_fn = ProxySink.set;
    host.connection.context = &sink;
    // A stale epoch and a foreign socket both fail with stale_control; a
    // missing epoch is a bad request. None of them reaches the callback.
    {
        const stale = try dispatchJson(host, a, "{\"v\":1,\"id\":4,\"op\":\"proxy_model\",\"epoch\":9,\"name\":\"p/m\",\"enabled\":true}", 7);
        defer a.free(stale);
        try std.testing.expect(std.mem.indexOf(u8, stale, "stale_control") != null);
    }
    {
        const foreign = try dispatchJson(host, a, "{\"v\":1,\"id\":5,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":true}", 8);
        defer a.free(foreign);
        try std.testing.expect(std.mem.indexOf(u8, foreign, "stale_control") != null);
    }
    {
        const bare = try dispatchJson(host, a, "{\"v\":1,\"id\":6,\"op\":\"proxy_model\",\"name\":\"p/m\",\"enabled\":true}", 7);
        defer a.free(bare);
        try std.testing.expect(std.mem.indexOf(u8, bare, "\"ok\":false") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), sink.calls);
    // Loose parameter shapes are rejected instead of defaulted.
    for ([_][]const u8{
        "{\"v\":1,\"id\":7,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\"}",
        "{\"v\":1,\"id\":8,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":\"true\"}",
        "{\"v\":1,\"id\":9,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"\",\"enabled\":true}",
        "{\"v\":1,\"id\":10,\"op\":\"proxy_model\",\"epoch\":1,\"enabled\":true}",
    }) |json| {
        const frame = try dispatchJson(host, a, json, 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
    }
    // A busy owner refuses before the callback runs.
    {
        host.reset_failed = error.ResetFailed;
        defer host.reset_failed = null;
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":11,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "busy") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
    }
    // Without an owner callback the op is unsupported, never silently accepted.
    {
        host.connection.proxy_fn = null;
        defer host.connection.proxy_fn = ProxySink.set;
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":12,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "unsupported") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
    }
}

test "settings reply publishes the proxy allowlist without addresses or secrets" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    const names = [_][]const u8{ "opencode-go/deepseek-v3", "deepseek/deepseek-chat" };
    var fake = FakeProxyView{
        .prev_fn = host.connection.current_fn,
        .prev_context = host.connection.context,
        .configured = true,
        .names = &names,
    };
    {
        host.connection.current_fn = FakeProxyView.current;
        host.connection.context = &fake;
        defer {
            host.connection.current_fn = fake.prev_fn;
            host.connection.context = fake.prev_context;
        }
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":20,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        var doc = try parseWholeReply(a, frame);
        defer doc.deinit();
        const root = doc.value.object;
        try std.testing.expectEqual(true, root.get("proxy_configured").?.bool);
        const list = root.get("proxy_models").?.array;
        try std.testing.expectEqual(names.len, list.items.len);
        try std.testing.expectEqualStrings(names[0], list.items[0].string);
        try std.testing.expectEqualStrings(names[1], list.items[1].string);
        try std.testing.expectEqual(false, root.get("proxy_models_truncated").?.bool);
        // A model id is projected verbatim: no endpoint, host or credential.
        for (list.items) |entry| {
            try std.testing.expect(std.mem.indexOf(u8, entry.string, "://") == null);
            try std.testing.expect(std.mem.indexOf(u8, entry.string, "@") == null);
        }
        for ([_][]const u8{ "\"key\"", "api_key", "credential", "sk-" }) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, frame, needle) == null);
        }
    }

    // The catalog bound is reported, not silently truncated.
    var many: [257][]const u8 = undefined;
    for (&many) |*entry| entry.* = "p/m";
    fake.names = &many;
    fake.configured = true;
    {
        host.connection.current_fn = FakeProxyView.current;
        host.connection.context = &fake;
        defer {
            host.connection.current_fn = fake.prev_fn;
            host.connection.context = fake.prev_context;
        }
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":21,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        var doc = try parseWholeReply(a, frame);
        defer doc.deinit();
        const root = doc.value.object;
        try std.testing.expectEqual(@as(usize, max_proxy_models), root.get("proxy_models").?.array.items.len);
        try std.testing.expectEqual(true, root.get("proxy_models_truncated").?.bool);
    }

    // The real projection stays unconfigured with a real empty array.
    {
        const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":22,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        var doc = try parseWholeReply(a, frame);
        defer doc.deinit();
        const root = doc.value.object;
        try std.testing.expectEqual(false, root.get("proxy_configured").?.bool);
        try std.testing.expectEqual(@as(usize, 0), root.get("proxy_models").?.array.items.len);
    }
}

/// Settings view that overrides only the catalog slices, so the reply can be
/// checked with more than one model, provider and effort level.
const FakeCatalogView = struct {
    prev_fn: *const fn (*anyopaque) tui.Connection.State,
    prev_context: *anyopaque,
    models: []const cfg.Model,
    providers: []const tui.ModelProvider,
    levels: activity.EffortSet,

    fn current(context: *anyopaque) tui.Connection.State {
        const self: *FakeCatalogView = @ptrCast(@alignCast(context));
        var state = self.prev_fn(self.prev_context);
        state.models = self.models;
        state.decision_models = self.models;
        state.image_models = self.models;
        state.model_providers = self.providers;
        state.effort_levels = self.levels;
        return state;
    }
};

/// The whole reply must parse: the frontend runs `json.loads` over it, so a
/// missing comma between array elements is a hard startup failure even though
/// every field is present.
fn parseWholeReply(a: std.mem.Allocator, frame: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, frame, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

test "settings reply is one parseable JSON object with complete array elements" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .logging = false, .owner = .daemon });
    defer host.deinit();

    const models = [_]cfg.Model{
        .{ .name = "fake-one", .context_tokens = 32_000, .output_tokens = 4_000 },
        .{ .name = "fake-two", .context_tokens = 64_000 },
    };
    const model_providers = [_]tui.ModelProvider{
        .{ .name = "fake-login" },
        .{ .name = "fake-proxy", .allow_custom = true },
    };
    // off | low | high: three levels, so the array needs two separators.
    const levels: activity.EffortSet = .{ .mask = 1 | 4 | 16 };

    var fake = FakeCatalogView{
        .prev_fn = host.connection.current_fn,
        .prev_context = host.connection.context,
        .models = &models,
        .providers = &model_providers,
        .levels = levels,
    };
    defer {
        host.connection.current_fn = fake.prev_fn;
        host.connection.context = fake.prev_context;
    }
    host.connection.current_fn = FakeCatalogView.current;
    host.connection.context = &fake;

    const frame = try dispatchJson(host, a, "{\"v\":1,\"id\":50,\"op\":\"settings\"}", 7);
    defer a.free(frame);

    var doc = try parseWholeReply(a, frame);
    defer doc.deinit();
    const root = doc.value.object;
    try std.testing.expectEqual(true, root.get("ok").?.bool);

    const allowed_json = root.get("allowed_providers").?.array;
    try std.testing.expect(allowed_json.items.len > 1);
    try std.testing.expectEqual(@as(usize, 3), allowed_json.items.len);
    try std.testing.expectEqualStrings("deepseek", allowed_json.items[0].string);
    try std.testing.expectEqualStrings("opencode-go", allowed_json.items[2].string);

    const levels_json = root.get("effort_levels").?.array;
    try std.testing.expectEqual(@as(usize, 3), levels_json.items.len);
    try std.testing.expectEqualStrings("off", levels_json.items[0].string);
    try std.testing.expectEqualStrings("high", levels_json.items[2].string);

    const providers_json = root.get("providers").?.array;
    try std.testing.expectEqual(model_providers.len, providers_json.items.len);
    try std.testing.expectEqualStrings("fake-login", providers_json.items[0].object.get("name").?.string);
    try std.testing.expectEqual(true, providers_json.items[1].object.get("allow_custom").?.bool);

    for ([_][]const u8{ "models", "decision_models", "image_models" }) |name| {
        const list = root.get(name).?.array;
        try std.testing.expectEqual(models.len, list.items.len);
        try std.testing.expectEqualStrings("fake-one", list.items[0].object.get("name").?.string);
        try std.testing.expectEqualStrings("fake-two", list.items[1].object.get("name").?.string);
    }

    // A catalog reply never carries credential bytes or credential-shaped keys.
    for ([_][]const u8{ "\"key\"", "api_key", "credential", "sk-" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, frame, needle) == null);
    }
}
