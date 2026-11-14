//! Per-UID daemon supervisor: one instance lock, one control socket, one owner
//! of the workers it created.
//!
//! It never starts a Runtime itself, never restarts tasks and never touches a
//! foreground-owned endpoint. `list`/`attach` merge the on-disk index with a
//! live endpoint probe; `create` spawns one persistent worker through
//! `spawn.Workers`.
//!
//! Setup ops (`settings`, `login`, model/effort/preference/helper selection and
//! metadata refresh/poll) are served by one lazily created, *stable* setup
//! `SessionHost` per authenticated connection. That host is never registered,
//! never listed, never attached to a worker and never submits a task: it only
//! exists so a single connection can read and mutate its own settings projection
//! across requests. Keeping it alive is what lets an asynchronous metadata
//! refresh finish between two requests; it is destroyed (cancelling and joining
//! that refresh) on EOF, idle timeout or daemon exit.

const std = @import("std");

const linux = std.os.linux;

const fs = @import("../platform/filesystem.zig");
const interrupt = @import("../platform/interrupt.zig");
const logs = @import("../app/log_store.zig");
const protocol = @import("protocol.zig");
const unix = @import("unix.zig");
const registry = @import("registry.zig");
const spawn = @import("spawn.zig");
const ssh = @import("ssh.zig");
const session_host = @import("../app/session_host.zig");
const cli = @import("../app/cli.zig");
const ids = @import("../app/session_id.zig");

const daemon_lock = "daemon.lock";
const daemon_socket = "daemon.sock";
/// Bounded control-plane budgets. No operation waits forever.
const tick_ms: u32 = 10;
const read_slice_ms: u32 = 5;
const write_timeout_ms: u32 = 2_000;
const idle_timeout_ms: i64 = 120_000;
const probe_timeout_ms: u32 = registry.probe_timeout_ms;
/// Bounded concurrent control connections; single-threaded round-robin so one
/// slow or idle client cannot block the rest.
const max_connections: usize = 32;

pub fn run(init: std.process.Init, options: cli.Options) !u8 {
    if (options.mode != .daemon) return error.InvalidArguments;
    const a = init.gpa;
    const io = init.io;

    var guard = try interrupt.Guard.install();
    defer guard.deinit();

    var reg = try registry.Registry.init(a, io, init.environ_map);
    defer reg.deinit();
    var workers = try spawn.Workers.init(a, io, init.environ_map);
    defer workers.deinit();

    const runtime = reg.runtimeDirectory();
    // One daemon per UID: fixed-inode lock, never unlinked, stale socket
    // cleanup authorized only by this very lock.
    var lock = unix.Lock.acquire(a, runtime, daemon_lock) catch |err| switch (err) {
        error.AlreadyRunning => return error.DaemonAlreadyRunning,
        else => return err,
    };
    defer lock.release();
    var listener = try unix.Listener.bind(a, runtime, daemon_socket, .{ .lock = &lock });
    defer listener.deinit();

    var ssh_listener: ?ssh.Listener = if (options.ssh_listen) |address|
        try ssh.Listener.init(a, io, init.environ_map, address, options.auto_refresh_models)
    else
        null;
    defer if (ssh_listener) |*active| active.deinit();

    var supervisor = Supervisor{
        .allocator = a,
        .io = io,
        .environ = init.environ_map,
        .ssh_listener = if (ssh_listener) |*active| active else null,
        .registry = &reg,
        .workers = &workers,
        .listener = &listener,
        .auto_refresh_models = options.auto_refresh_models,
    };
    defer supervisor.deinit();

    return supervisor.serve();
}

const Created = struct {
    id: ids.Id,
    project: []u8,
    /// The exact endpoint this daemon's worker published. It still identifies
    /// this daemon's index record after the process is gone, so a retired
    /// worker can never delete a record a later owner republished.
    endpoint: []u8,
};

const Slot = struct {
    id: u64,
    conn: unix.Connection,
    last_active_ms: i64,
    /// This slot's private setup context; created on the first setup request.
    setup: ?Setup = null,
};

/// One slot's stable setup host. `epoch` came from this host's own `attach` on
/// the slot's connection id: it is private to the slot and never delegated to an
/// external caller.
const Setup = struct {
    host: *session_host.SessionHost,
    project: []u8,
    epoch: u64,
};

const Supervisor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    registry: *registry.Registry,
    workers: *spawn.Workers,
    listener: *unix.Listener,
    ssh_listener: ?*ssh.Listener = null,
    auto_refresh_models: bool,
    created: std.ArrayList(Created) = .empty,
    /// Directory of the first user input this daemon accepted (the first
    /// successful `create` project). Used as the setup workspace when a setup
    /// request carries no explicit projectHint. Owned; never a session history.
    first_project: ?[]u8 = null,
    slots: [max_connections]?Slot = @splat(null),
    next_connection: u64 = 0,
    stop_requested: bool = false,
    accept_failures: u32 = 0,

    fn deinit(self: *Supervisor) void {
        for (&self.slots) |*slot| {
            if (slot.*) |*active| {
                // Cancels and joins any in-flight setup metadata refresh.
                self.disposeSetup(active);
                active.conn.close();
            }
            slot.* = null;
        }
        for (self.created.items) |item| {
            self.allocator.free(item.project);
            self.allocator.free(item.endpoint);
        }
        self.created.deinit(self.allocator);
        if (self.first_project) |value| self.allocator.free(value);
        self.first_project = null;
        self.* = undefined;
    }

    fn serve(self: *Supervisor) !u8 {
        var failure: ?anyerror = null;
        while (!self.stop_requested and interrupt.signal() == 0) {
            self.maintain() catch |err| {
                failure = err;
                break;
            };
            if (self.ssh_listener) |active| active.tick() catch |err| {
                failure = err;
                break;
            };
            self.acceptTick();
            self.serveTick();
        }
        // Every owned worker is notified, then cancelled, then joined. A failed
        // cleanup is reported and never presented as a clean daemon stop.
        self.shutdownOwned() catch |err| {
            failure = err;
        };
        if (failure) |err| return err;
        const signal = interrupt.signal();
        if (signal != 0) return 128 + signal;
        return 0;
    }

    /// Cancels/joins only *this* daemon's workers and retires their index
    /// entries. Foreground-owned endpoints are never touched.
    fn shutdownOwned(self: *Supervisor) !void {
        for (&self.slots) |*slot| {
            if (slot.*) |*active| {
                self.disposeSetup(active);
                active.conn.close();
            }
            slot.* = null;
        }
        var unclean = false;
        // Stop every connection before waiting for workers; connection cleanup
        // runs concurrently, and no new view can arrive during daemon shutdown.
        if (self.ssh_listener) |active| active.stop();
        self.workers.shutdown() catch {
            unclean = true;
        };
        if (self.ssh_listener) |active| active.shutdown() catch {
            unclean = true;
        };
        // A joined worker that left a complete checkpoint stays the durable
        // locator of that history: `create resume`, `attach` and cross-project
        // `list` read the record, while liveness is still proven only by the
        // endpoint probe and the writer lease stays the execution authority.
        for (self.created.items) |item| {
            self.retireWorker(item.id, item.project, item.endpoint);
            self.allocator.free(item.project);
            self.allocator.free(item.endpoint);
        }
        self.created.clearRetainingCapacity();
        if (unclean) return error.CleanupFailed;
    }

    /// Reap finished workers and retire their index entries. Unknown cleanup
    /// failures poison further starts instead of being ignored.
    fn maintain(self: *Supervisor) !void {
        self.workers.reap() catch return error.CleanupFailed;
        var index: usize = 0;
        while (index < self.created.items.len) {
            const item = self.created.items[index];
            if (self.workers.isAlive(item.id)) {
                index += 1;
                continue;
            }
            self.retireWorker(item.id, item.project, item.endpoint);
            self.allocator.free(item.project);
            self.allocator.free(item.endpoint);
            _ = self.created.orderedRemove(index);
        }
    }

    /// Retire one owned worker's locator metadata once its process is gone.
    /// The record is kept (not rewritten) when this project still holds a
    /// complete checkpoint for the session, and it is never removed when the
    /// on-disk entry already belongs to a later owner. `list` reports a kept
    /// record as not-live; the index is never a live-owner authority.
    fn retireWorker(self: *Supervisor, id: ids.Id, project: []const u8, endpoint: []const u8) void {
        var record = (self.registry.resolve(self.allocator, id, project) catch return) orelse return;
        defer registry.freeRecord(self.allocator, &record);
        if (!std.mem.eql(u8, record.endpoint, endpoint)) return;
        if (self.hasCheckpoint(project, id)) return;
        self.registry.unpublish(id, project) catch {};
    }

    /// Anchored, nofollow check of the published checkpoint file in this
    /// project's own checkpoint directory. It never creates a directory, never
    /// follows a link and never mistakes diagnostics for resumable history.
    fn hasCheckpoint(self: *Supervisor, project: []const u8, id: ids.Id) bool {
        var root = fs.Root.open(self.allocator, self.io, project) catch return false;
        defer root.deinit();
        const dir = logs.openExistingDirectory(&root) catch return false;
        defer fs.closeFd(dir);
        var buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buffer, "{s}.session", .{id}, 0) catch return false;
        const fd = fs.openAt(dir, path, .{ .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (fd < 0) return false;
        defer fs.closeFd(fd);
        const stat = fs.fileFromFd(fd).stat(self.io) catch return false;
        // Actual frame validation belongs to the resume reader; this is only
        // an existence check before launching the owner.
        return stat.kind == .file and stat.size > 0;
    }

    fn acceptTick(self: *Supervisor) void {
        if (freeSlot(&self.slots) == null) return;
        const conn = self.listener.accept(.{ .io = self.io, .timeout_ms = tick_ms }) catch |err| switch (err) {
            error.Timeout,
            error.Canceled,
            error.Interrupted,
            error.PeerUidMismatch,
            // Admission shortage is not a broken listener or lost worker.
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.OutOfMemory,
            error.SystemResources,
            => return,
            else => {
                self.accept_failures += 1;
                // Bound persistent listener errors; a transient refusal is not
                // a reason to kill every session.
                if (self.accept_failures >= 256) self.stop_requested = true;
                return;
            },
        };
        self.accept_failures = 0;
        self.next_connection +%= 1;
        if (self.next_connection == 0) self.next_connection = 1;
        const slot = freeSlot(&self.slots).?;
        self.slots[slot] = .{
            .id = self.next_connection,
            .conn = conn,
            .last_active_ms = self.now(),
        };
    }

    /// One bounded read slice per connection per tick. Partial frames are kept
    /// by `unix.Connection`, so a slow sender is throttled instead of blocking
    /// the whole service.
    fn serveTick(self: *Supervisor) void {
        for (&self.slots) |*slot| {
            if (slot.* == null) continue;
            const active = if (slot.*) |*value| value else unreachable;
            const frame = active.conn.readFrame(.{ .io = self.io, .timeout_ms = read_slice_ms }) catch |err| switch (err) {
                error.Timeout, error.Canceled, error.Interrupted => {
                    // An idle connection releases its setup host too, so a
                    // forgotten client cannot pin a metadata refresh forever.
                    if (self.now() - active.last_active_ms > idle_timeout_ms) self.closeSlot(slot);
                    continue;
                },
                else => {
                    self.closeSlot(slot);
                    continue;
                },
            };
            const raw = frame orelse {
                self.closeSlot(slot);
                continue;
            };
            defer {
                // Launcher setup can carry the same login secret as a worker
                // request; wipe the transport copy on every dispatch outcome.
                std.crypto.secureZero(u8, raw);
                self.allocator.free(raw);
            }
            active.last_active_ms = self.now();
            self.handleFrame(slot, active, raw);
        }
    }

    fn handleFrame(self: *Supervisor, slot: *?Slot, active: *Slot, raw: []const u8) void {
        var request = protocol.parseRequest(self.allocator, raw) catch {
            // A malformed or unknown frame closes this connection only.
            self.closeSlot(slot);
            return;
        };
        defer request.deinit();
        const reply = self.route(&request, active) catch |err| blk: {
            var out = protocol.Out.init(self.allocator);
            defer out.deinit();
            out.fail(request.id, localErrorCode(err)) catch {
                self.closeSlot(slot);
                return;
            };
            break :blk out.finish() catch {
                self.closeSlot(slot);
                return;
            };
        };
        defer self.allocator.free(reply);
        active.conn.writeFrame(reply, .{ .io = self.io, .timeout_ms = write_timeout_ms }) catch {
            self.closeSlot(slot);
            return;
        };
    }

    // -----------------------------------------------------------------------
    // Control ops
    // -----------------------------------------------------------------------

    fn route(self: *Supervisor, request: *const protocol.Request, active: *Slot) ![]u8 {
        return switch (request.op) {
            .hello => self.replyHello(request.id),
            .ping => self.replyPing(request.id),
            .list => self.handleList(request),
            .create => self.handleCreate(request),
            .attach => self.handleAttach(request),
            .close => self.handleClose(request),
            .shutdown => self.handleShutdown(request.id),
            // Launcher/login setup before any worker exists. Only this slot's
            // private setup host answers; it never becomes a listed session.
            .settings,
            .model_select,
            .effort,
            .cycle_effort,
            .login,
            .preference,
            .setting,
            .decision_model,
            .image_model,
            .proxy_model,
            .proxy_address,
            .refresh_models,
            .poll_metadata,
            => self.handleSetup(request, active),
            else => self.failFrame(request.id, error.Unsupported),
        };
    }

    fn replyHello(self: *Supervisor, id: u64) ![]u8 {
        var out = protocol.Out.init(self.allocator);
        defer out.deinit();
        try out.ok(id);
        try out.field("daemon", true);
        try out.field("pid", linux.getpid());
        try out.field("protocol", protocol.version);
        return out.finish();
    }

    fn replyPing(self: *Supervisor, id: u64) ![]u8 {
        var out = protocol.Out.init(self.allocator);
        defer out.deinit();
        try out.ok(id);
        try out.field("pid", linux.getpid());
        return out.finish();
    }

    fn localErrorCode(err: anyerror) protocol.ErrorCode {
        return switch (err) {
            error.Unsupported => .unsupported,
            else => protocol.errorCode(err),
        };
    }

    fn failFrame(self: *Supervisor, id: u64, err: anyerror) ![]u8 {
        var out = protocol.Out.init(self.allocator);
        defer out.deinit();
        try out.fail(id, localErrorCode(err));
        return out.finish();
    }

    /// Merge index entries with live snapshot state. `running_only` filters on
    /// the endpoint probe, never on pid or the index alone.
    fn handleList(self: *Supervisor, request: *const protocol.Request) ![]u8 {
        const running_only = try request.boolField("running_only", true);
        const page_u64 = try request.optionalU64("page");
        const page: usize = @intCast(page_u64 orelse 0);
        const records = try self.registry.list(self.allocator, running_only, page);
        defer registry.freeRecords(self.allocator, records);
        const truncated = self.registry.wasTruncated();

        var out = protocol.Out.init(self.allocator);
        defer out.deinit();
        try out.ok(request.id);
        try out.beginArray("sessions");
        for (records) |record| {
            const json = try self.sessionJson(record, record.probe);
            defer self.allocator.free(json);
            try out.element(json);
        }
        try out.endArray();
        try out.field("page", page);
        // A bounded scan window is reported, never presented as the total.
        try out.field("truncated", truncated);
        return out.finish();
    }

    fn sessionJson(self: *Supervisor, record: registry.Record, probe: registry.Probe) ![]u8 {
        const state = switch (probe.state) {
            .dead => "unreachable",
            .idle => "idle",
            .running => "running",
            .waiting_approval => "waiting_approval",
            .unknown => "unknown",
        };
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        const w = &writer.writer;
        try w.writeAll("{\"id\":");
        try writeString(w, record.id[0..]);
        try w.writeAll(",\"project\":");
        try writeString(w, record.project);
        try w.writeAll(",\"endpoint\":");
        try writeString(w, record.endpoint);
        try w.writeAll(",\"owner\":");
        try writeString(w, @tagName(record.owner));
        try w.writeAll(",\"state\":");
        try writeString(w, state);
        try w.print(",\"busy\":{s},\"stale\":{s},\"attached\":{s}", .{
            if (probe.busy) "true" else "false",
            if (!probe.live) "true" else "false",
            if (probe.attached) "true" else "false",
        });
        try w.print(",\"pid\":{d},\"updated_ms\":{d},\"generation\":{d}}}", .{
            record.pid, record.updated_ms, record.generation,
        });
        return self.allocator.dupe(u8, writer.written());
    }

    /// Explicitly create one session worker. A live owner for the same id always
    /// wins: the reply is `busy`, never a second Runtime. If only a stale index
    /// or a released history exists, the worker's fixed checkpoint lease decides;
    /// a busy lease makes `create` fail instead of forking a second writer.
    fn handleCreate(self: *Supervisor, request: *const protocol.Request) ![]u8 {
        const project_text = try request.stringField("project", registry.max_project_bytes);
        const canonical = try self.canonicalProject(project_text);
        defer self.allocator.free(canonical);

        if (request.field("logging") != null) return error.BadRequest;
        const requested_auto = try request.boolField("auto_refresh_models", self.auto_refresh_models);
        const auto_refresh = self.auto_refresh_models and requested_auto;

        const resume_id = try optionalId(request.optionalString("resume"));
        const restore_id = try optionalId(request.optionalString("restore_selection"));
        if (resume_id != null and restore_id != null) return error.InvalidArguments;

        const target = resume_id orelse restore_id;
        if (target) |id| {
            if (try self.registry.resolve(self.allocator, id, null)) |found| {
                var record = found;
                defer registry.freeRecord(self.allocator, &record);
                if (!std.mem.eql(u8, record.project, canonical)) return error.AmbiguousSession;
                // Live (or merely reachable) owner: never start a second Runtime.
                if (self.registry.isLive(record, probe_timeout_ms)) return error.Busy;
            }
        }

        const record = try self.workers.create(.{
            .project = canonical,
            .owner = .daemon,
            .@"resume" = resume_id,
            .restore_selection = restore_id,
            .auto_refresh_models = auto_refresh,
        });
        self.registry.register(record) catch |err| {
            // Never leave an unindexed owner behind.
            self.workers.close(record.id, record.project) catch {};
            return err;
        };
        const project_copy = try self.allocator.dupe(u8, record.project);
        // Owned copy: the worker's own endpoint storage dies with its process
        // record, but this daemon must still identify its index entry later.
        const endpoint_copy = self.allocator.dupe(u8, record.endpoint) catch |err| {
            self.allocator.free(project_copy);
            self.registry.unpublish(record.id, record.project) catch {};
            self.workers.close(record.id, record.project) catch {};
            return err;
        };
        // First accepted user input defines the setup default workspace.
        if (self.first_project == null) {
            self.first_project = self.allocator.dupe(u8, record.project) catch null;
        }
        self.created.append(self.allocator, .{ .id = record.id, .project = project_copy, .endpoint = endpoint_copy }) catch |err| {
            self.allocator.free(project_copy);
            self.allocator.free(endpoint_copy);
            self.registry.unpublish(record.id, record.project) catch {};
            self.workers.close(record.id, record.project) catch {};
            return err;
        };

        var out = protocol.Out.init(self.allocator);
        defer out.deinit();
        try out.ok(request.id);
        // The envelope already owns `id`; the session id travels as `session`.
        try out.field("session", record.id);
        try out.field("endpoint", record.endpoint);
        try out.field("owner", @tagName(record.owner));
        try out.field("pid", record.pid);
        return out.finish();
    }

    /// Attach returns the endpoint of a *live* worker only. Historical entries
    /// are resumed through `create`, never through `attach`.
    fn handleAttach(self: *Supervisor, request: *const protocol.Request) ![]u8 {
        const id = try sessionIdField(request);
        var record = (try self.registry.resolve(self.allocator, id, null)) orelse return error.SessionNotFound;
        defer registry.freeRecord(self.allocator, &record);
        if (!self.registry.isLive(record, probe_timeout_ms)) return error.SessionNotFound;

        var out = protocol.Out.init(self.allocator);
        defer out.deinit();
        try out.ok(request.id);
        try out.field("endpoint", record.endpoint);
        try out.field("session", record.id);
        try out.field("owner", @tagName(record.owner));
        return out.finish();
    }

    /// Close only a worker this daemon created. Any close that goes through this
    /// owner manager rather than the live worker's own control channel stops a
    /// whole owner lifecycle, so it is always an explicit confirmation: probing
    /// for a busy task here would race with another controller submitting after
    /// the probe, and this process cannot atomically check-then-stop.
    fn handleClose(self: *Supervisor, request: *const protocol.Request) ![]u8 {
        const id = try sessionIdField(request);
        const force = try request.boolField("force", false);
        const owned = self.createdProject(id);
        if (owned == null) {
            // A foreground-owned (or otherwise foreign) live endpoint is never
            // killed by the daemon; report it instead.
            var record = (try self.registry.resolve(self.allocator, id, null)) orelse return error.SessionNotFound;
            defer registry.freeRecord(self.allocator, &record);
            const live = self.registry.isLive(record, probe_timeout_ms);
            return self.acceptedFrame(request.id, false, if (live) "not_owned" else "not_found");
        }
        // Never probe and then kill: `accepted=false` asks the operator for
        // `force` without touching the worker or its created entry.
        if (!force) return self.acceptedFrame(request.id, false, "busy");
        const project = owned.?;
        // Identity of this daemon's own record, captured before the worker's
        // process storage is released by `close`.
        const endpoint = if (self.createdEntry(id)) |entry| entry.endpoint else return error.SessionNotFound;
        try self.workers.close(id, project);
        // Keep the locator when a complete checkpoint remains, so the history is
        // still discoverable/resumable after this clean close.
        self.retireWorker(id, project, endpoint);
        self.retireCreated(id);
        return self.acceptedFrame(request.id, true, null);
    }

    fn handleShutdown(self: *Supervisor, id: u64) ![]u8 {
        var out = protocol.Out.init(self.allocator);
        defer out.deinit();
        try out.ok(id);
        try out.field("stopping", true);
        self.stop_requested = true;
        return out.finish();
    }

    fn acceptedFrame(self: *Supervisor, id: u64, accepted: bool, reason: ?[]const u8) ![]u8 {
        var out = protocol.Out.init(self.allocator);
        defer out.deinit();
        try out.ok(id);
        try out.field("accepted", accepted);
        if (reason) |text| try out.field("reason", text);
        return out.finish();
    }

    /// Setup ops never create, register or submit to a worker. They are served
    /// by the slot's stable setup host so a settings mutation and the metadata
    /// refresh it started both survive until the next request.
    fn handleSetup(self: *Supervisor, request: *const protocol.Request, active: *Slot) ![]u8 {
        const project_text = request.optionalString("project") orelse
            self.first_project orelse
            (self.environ.get("HOME") orelse return error.InvalidInput);
        if (project_text.len == 0 or project_text.len > registry.max_project_bytes) return error.InvalidInput;
        // Canonicalization opens the directory: an unreadable or foreign path
        // never replaces an already working setup host.
        const canonical = try self.canonicalProject(project_text);
        defer self.allocator.free(canonical);

        try self.ensureSetupHost(active, canonical);
        const setup = active.setup orelse return error.Unavailable;
        // The forwarded copy reuses the caller's arena (so no second deinit) and
        // only adds the private epoch this host's own attach granted.
        const forwarded = try forwardRequest(request, setup.epoch);
        return setup.host.dispatch(self.allocator, &forwarded, active.id, false);
    }

    /// Lazily create the slot's setup host, reuse it across requests and rebuild
    /// it only when the requested project actually changes.
    fn ensureSetupHost(self: *Supervisor, active: *Slot, canonical: []const u8) !void {
        if (active.setup) |setup| {
            if (std.mem.eql(u8, setup.project, canonical)) return;
            // Project switch: the old context (and its pending refresh) is gone
            // before a new host can exist.
            self.disposeSetup(active);
        }

        const id = try ids.generate(self.io);
        // Random id, never registered: this host exists only for settings/setup.
        const host = try session_host.SessionHost.init(self.allocator, self.io, self.environ, .{
            .project = canonical,
            .id = id,
            .@"resume" = null,
            .restore_selection = null,
            .auto_refresh_models = false,
            .owner = .daemon,
        });
        errdefer host.deinit();
        const project = try self.allocator.dupe(u8, canonical);
        errdefer self.allocator.free(project);
        const epoch = try attachSetupHost(self.allocator, host, active.id);
        active.setup = .{ .host = host, .project = project, .epoch = epoch };
    }

    /// Releases a setup host: cancel/join any in-flight metadata refresh first,
    /// then destroy it. The host never owns a task, so this cannot cancel work.
    fn disposeSetup(self: *Supervisor, active: *Slot) void {
        const setup = active.setup orelse return;
        active.setup = null;
        setup.host.shutdown() catch {};
        setup.host.deinit();
        self.allocator.free(setup.project);
    }

    fn closeSlot(self: *Supervisor, slot: *?Slot) void {
        if (slot.*) |*active| {
            self.disposeSetup(active);
            active.conn.close();
        }
        slot.* = null;
    }

    fn createdProject(self: *Supervisor, id: ids.Id) ?[]const u8 {
        for (self.created.items) |item| {
            if (std.mem.eql(u8, &item.id, &id)) return item.project;
        }
        return null;
    }

    fn createdEntry(self: *Supervisor, id: ids.Id) ?*Created {
        for (self.created.items) |*item| {
            if (std.mem.eql(u8, &item.id, &id)) return item;
        }
        return null;
    }

    fn retireCreated(self: *Supervisor, id: ids.Id) void {
        var index: usize = 0;
        while (index < self.created.items.len) {
            const item = self.created.items[index];
            if (!std.mem.eql(u8, &item.id, &id)) {
                index += 1;
                continue;
            }
            self.allocator.free(item.project);
            self.allocator.free(item.endpoint);
            _ = self.created.orderedRemove(index);
        }
    }

    fn canonicalProject(self: *Supervisor, path: []const u8) ![]u8 {
        var root = try fs.Root.open(self.allocator, self.io, path);
        defer root.deinit();
        return self.allocator.dupe(u8, root.path);
    }

    fn now(self: *Supervisor) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }
};

fn freeSlot(slots: *[max_connections]?Slot) ?usize {
    for (slots, 0..) |slot, index| if (slot == null) return index;
    return null;
}

/// Take this slot's private epoch. The attach is a real dispatch on the host's
/// own connection id, so the host's controller bookkeeping stays authoritative;
/// the value is never handed to an external caller.
fn attachSetupHost(a: std.mem.Allocator, host: *session_host.SessionHost, connection_id: u64) !u64 {
    var buffer: [128]u8 = undefined;
    const wire = std.fmt.bufPrint(&buffer, "{{\"v\":{d},\"id\":1,\"op\":\"attach\",\"write\":true}}", .{protocol.version}) catch unreachable;
    var request = try protocol.parseRequest(a, wire);
    defer request.deinit();
    const frame = try host.dispatch(a, &request, connection_id, false);
    defer a.free(frame);
    var parsed = std.json.parseFromSlice(std.json.Value, a, frame, .{}) catch return error.ProtocolError;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.ProtocolError,
    };
    const ok = switch (object.get("ok") orelse return error.ProtocolError) {
        .bool => |value| value,
        else => return error.ProtocolError,
    };
    if (!ok) return error.ProtocolError;
    const raw = switch (object.get("epoch") orelse return error.ProtocolError) {
        .integer => |value| value,
        else => return error.ProtocolError,
    };
    if (raw <= 0) return error.ProtocolError;
    return @intCast(raw);
}

/// Shallow body copy in the parsed request's own arena plus the private epoch.
/// Values are arena-owned slices, so the copy borrows exactly as long as the
/// original. The caller must not deinit the returned value: `doc` is shared.
fn forwardRequest(request: *const protocol.Request, epoch: u64) !protocol.Request {
    // `arenaalloc` needs a mutable receiver; this local copy is never deinited.
    var source_request = request.*;
    const arena = source_request.arenaalloc();
    const source = switch (request.body) {
        .object => |value| value,
        else => return error.BadRequest,
    };
    const epoch_value = std.math.cast(i64, epoch) orelse return error.InvalidInput;
    var body: std.json.ObjectMap = .empty;
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        // A client-supplied epoch never overrides the slot's private one.
        if (std.mem.eql(u8, entry.key_ptr.*, "epoch")) continue;
        try body.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    try body.put(arena, "epoch", .{ .integer = epoch_value });
    var forwarded = request.*;
    forwarded.body = .{ .object = body };
    return forwarded;
}

fn optionalId(text: ?[]const u8) !?ids.Id {
    const raw = text orelse return null;
    if (raw.len != 32) return error.InvalidSessionID;
    const value: ids.Id = raw[0..32].*;
    if (!ids.valid(value)) return error.InvalidSessionID;
    return value;
}

/// The envelope `id` belongs to the RPC, so a target session id travels as
/// `session` in control requests.
fn sessionIdField(request: *const protocol.Request) !ids.Id {
    const raw = try request.stringField("session", 64);
    if (raw.len != 32) return error.InvalidSessionID;
    const value: ids.Id = raw[0..32].*;
    if (!ids.valid(value)) return error.InvalidSessionID;
    return value;
}

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.encodeJsonString(text, .{}, w);
}

// ---------------------------------------------------------------------------
// Owned control-socket lifecycle test: temp HOME/runtime/project, fake key,
// no worker, no network and no real configuration.
// ---------------------------------------------------------------------------

// One request/reply over the real control socket. The daemon side is driven by
// the same bounded slice the serve loop uses, never by a special test path.

// Minimal isolated daemon fixture for setup-host tests (real socket, tmp HOME).

// One index record with a valid endpoint, exactly the shape `spawn` publishes,
// for lifecycle tests that must not start a real worker.

// A real published checkpoint, the only durable resume locator, inside the
// owned project's own checkpoint directory.

// Diagnostics share the checkpoint directory but are never history.
