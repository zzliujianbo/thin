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
const c = std.c;
const linux = std.os.linux;

const fs = @import("../platform/filesystem.zig");
const interrupt = @import("../platform/interrupt.zig");
const logs = @import("../app/log_store.zig");
const resume_codec = @import("../app/resume_codec.zig");
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
        try ssh.Listener.init(a, io, init.environ_map, address, options.logging, options.auto_refresh_models)
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
        .logging = options.logging,
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
    logging: bool,
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
        const fd = fs.linux.openat(dir, path, fs.linux.nofollow | fs.linux.nonblock | fs.linux.cloexec, 0);
        if (fd < 0) return false;
        defer fs.closeFd(fd);
        const stat = fs.fileFromFd(fd).stat(self.io) catch return false;
        return stat.kind == .file and stat.size > 0 and stat.size <= resume_codec.max_file_bytes;
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
            const probe = self.registry.probe(record, probe_timeout_ms);
            const json = try self.sessionJson(record, probe);
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

        const requested_logging = try request.boolField("logging", self.logging);
        const requested_auto = try request.boolField("auto_refresh_models", self.auto_refresh_models);
        const logging = self.logging and requested_logging;
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
            .logging = logging,
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
            .logging = false,
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
    var request = try protocol.parseRequest(a, "{\"v\":2,\"id\":1,\"op\":\"attach\",\"write\":true}");
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

fn testWait() unix.Wait {
    return .{ .io = std.testing.io, .timeout_ms = 5_000 };
}

/// One request/reply over the real control socket. The daemon side is driven by
/// the same bounded slice the serve loop uses, never by a special test path.
fn controlRoundTrip(supervisor: *Supervisor, client: *unix.Connection, frame: []const u8) ![]u8 {
    try client.writeFrame(frame, testWait());
    supervisor.serveTick();
    return (try client.readFrame(testWait())) orelse error.ConnectionClosed;
}

fn setupOpFrame(allocator: std.mem.Allocator, id: u64, op: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"v\":{d},\"id\":{d},\"op\":\"{s}\"{s}}}", .{ protocol.version, id, op, body });
}

test "supervisor keeps one private setup host per socket without registering a session" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "runtime", .fromMode(0o700));
    try tmp.dir.createDir(io, "project", .default_dir);
    try tmp.dir.createDir(io, "elsewhere", .default_dir);

    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    const runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{base});
    defer a.free(runtime);
    const project = try std.fmt.allocPrint(a, "{s}/project", .{base});
    defer a.free(project);
    const elsewhere = try std.fmt.allocPrint(a, "{s}/elsewhere", .{base});
    defer a.free(elsewhere);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("XDG_RUNTIME_DIR", runtime);

    var reg = try registry.Registry.init(a, io, &env);
    defer reg.deinit();
    var workers = try spawn.Workers.init(a, io, &env);
    defer workers.deinit();

    var lock = try unix.Lock.acquire(a, reg.runtimeDirectory(), daemon_lock);
    defer lock.release();
    var listener = try unix.Listener.bind(a, reg.runtimeDirectory(), daemon_socket, .{ .lock = &lock });
    defer listener.deinit();

    var supervisor = Supervisor{
        .allocator = a,
        .io = io,
        .environ = &env,
        .registry = &reg,
        .workers = &workers,
        .listener = &listener,
        .logging = false,
        .auto_refresh_models = false,
    };
    defer supervisor.deinit();

    const me: u32 = @intCast(c.geteuid());
    var client = try unix.connect(a, listener.socketPath(), me, testWait());
    defer client.close();

    supervisor.acceptTick();
    try std.testing.expect(supervisor.slots[0] != null);
    // Nothing is built until a setup request arrives.
    try std.testing.expect(supervisor.slots[0].?.setup == null);

    // 1. `settings` creates the slot's private host, with no worker/registry row.
    {
        const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{project});
        defer a.free(body);
        const frame = try setupOpFrame(a, 1, "settings", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"session\":\"") != null);
    }
    const setup_host = supervisor.slots[0].?.setup.?.host;
    try std.testing.expectEqualStrings(project, supervisor.slots[0].?.setup.?.project);
    try std.testing.expect(supervisor.slots[0].?.setup.?.epoch != 0);
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);
    {
        const records = try reg.list(a, false, 0);
        defer registry.freeRecords(a, records);
        try std.testing.expectEqual(@as(usize, 0), records.len);
    }

    // 2. `login` with a fake key mutates the same host; no registration and no
    //    automatic metadata refresh (the setup host never auto-refreshes).
    {
        const body = try std.fmt.allocPrint(
            a,
            ",\"key\":\"fake-owner-key\",\"provider\":\"deepseek\",\"project\":\"{s}\"",
            .{project},
        );
        defer a.free(body);
        const frame = try setupOpFrame(a, 2, "login", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    // Cross-request survival: the very same host answered login.
    try std.testing.expect(supervisor.slots[0].?.setup.?.host == setup_host);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);

    // 3. `poll_metadata` is served by the same host and starts no worker/network.
    {
        const body = try std.fmt.allocPrint(a, ",\"wait\":true,\"project\":\"{s}\"", .{project});
        defer a.free(body);
        const frame = try setupOpFrame(a, 3, "poll_metadata", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    try std.testing.expect(supervisor.slots[0].?.setup.?.host == setup_host);
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);

    // 4. Setup never becomes a task endpoint: `submit` stays unsupported.
    {
        const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\",\"text\":\"x\",\"epoch\":9", .{project});
        defer a.free(body);
        const frame = try setupOpFrame(a, 4, "submit", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "unsupported") != null);
    }
    try std.testing.expect(supervisor.slots[0].?.setup.?.host == setup_host);

    // 5. A real project switch rebuilds the setup context from scratch.
    {
        const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 5, "settings", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    try std.testing.expectEqualStrings(elsewhere, supervisor.slots[0].?.setup.?.project);
    try std.testing.expect(supervisor.slots[0].?.setup.?.host != setup_host);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);

    // 6. Proxy allowlist mutations route to the private setup host, not to a
    //    worker. The owner refuses without a configured proxy endpoint, but the
    //    control router no longer answers `unsupported`.
    {
        const body = try std.fmt.allocPrint(a, ",\"name\":\"\",\"enabled\":true,\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 6, "proxy_model", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":false") != null);
        // The host already validates the id, so routing is proven without
        // depending on the owner's proxy-configuration refusal code.
        try std.testing.expect(std.mem.indexOf(u8, reply, "invalid_input") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "unsupported") == null);
    }
    {
        const body = try std.fmt.allocPrint(a, ",\"name\":\"p/m\",\"enabled\":true,\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 7, "proxy_model", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        // Any host answer proves routing; the exact refusal stays the owner's
        // proxy-configuration decision, not this test's assumption.
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "unsupported") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);
    // 7. The public settings projection carries the proxy fields.
    {
        const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 8, "settings", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"proxy_configured\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"proxy_address\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"proxy_port\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"proxy_models\":[]") != null);
    }

    // 8. Proxy endpoint edits route to the private setup host. An invalid
    //    endpoint is rejected by the host itself, so routing is proven without
    //    depending on whether this owner also wired its save callback.
    {
        const body = try std.fmt.allocPrint(a, ",\"value\":\"user@host:8080\",\"epoch\":1,\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 9, "proxy_address", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "invalid_input") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "unsupported") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);

    // 9. EOF destroys the slot and its setup host; nothing was ever listed.
    client.close();
    supervisor.serveTick();
    try std.testing.expect(supervisor.slots[0] == null);
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    {
        const records = try reg.list(a, false, 0);
        defer registry.freeRecords(a, records);
        try std.testing.expectEqual(@as(usize, 0), records.len);
    }
}

/// Minimal isolated daemon fixture for setup-host tests (real socket, tmp HOME).
const TestRig = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    reg: registry.Registry,
    workers: spawn.Workers,
    lock: unix.Lock,
    listener: unix.Listener,
    supervisor: Supervisor,
    base: []u8,
    home: []u8,
    runtime: []u8,
    project: []u8,
    elsewhere: []u8,

    fn create(a: std.mem.Allocator, io: std.Io) !*TestRig {
        const rig = try a.create(TestRig);
        errdefer a.destroy(rig);
        rig.* = undefined;
        rig.tmp = std.testing.tmpDir(.{});
        errdefer rig.tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try rig.tmp.dir.realPath(io, &path_buf);
        rig.base = try a.dupe(u8, path_buf[0..n]);
        errdefer a.free(rig.base);
        try rig.tmp.dir.createDir(io, "home", .default_dir);
        try rig.tmp.dir.createDir(io, "runtime", .fromMode(0o700));
        try rig.tmp.dir.createDir(io, "project", .default_dir);
        try rig.tmp.dir.createDir(io, "elsewhere", .default_dir);
        rig.home = try std.fmt.allocPrint(a, "{s}/home", .{rig.base});
        errdefer a.free(rig.home);
        rig.runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{rig.base});
        errdefer a.free(rig.runtime);
        rig.project = try std.fmt.allocPrint(a, "{s}/project", .{rig.base});
        errdefer a.free(rig.project);
        rig.elsewhere = try std.fmt.allocPrint(a, "{s}/elsewhere", .{rig.base});
        errdefer a.free(rig.elsewhere);

        rig.env = std.process.Environ.Map.init(a);
        errdefer rig.env.deinit();
        try rig.env.put("HOME", rig.home);
        try rig.env.put("XDG_RUNTIME_DIR", rig.runtime);

        rig.reg = try registry.Registry.init(a, io, &rig.env);
        errdefer rig.reg.deinit();
        rig.workers = try spawn.Workers.init(a, io, &rig.env);
        errdefer rig.workers.deinit();
        rig.lock = try unix.Lock.acquire(a, rig.reg.runtimeDirectory(), daemon_lock);
        errdefer rig.lock.release();
        rig.listener = try unix.Listener.bind(a, rig.reg.runtimeDirectory(), daemon_socket, .{ .lock = &rig.lock });
        errdefer rig.listener.deinit();
        rig.supervisor = Supervisor{
            .allocator = a,
            .io = io,
            .environ = &rig.env,
            .registry = &rig.reg,
            .workers = &rig.workers,
            .listener = &rig.listener,
            .logging = false,
            .auto_refresh_models = false,
        };
        return rig;
    }

    fn deinit(self: *TestRig, a: std.mem.Allocator) void {
        self.supervisor.deinit();
        self.listener.deinit();
        self.lock.release();
        self.workers.deinit();
        self.reg.deinit();
        self.env.deinit();
        a.free(self.home);
        a.free(self.runtime);
        a.free(self.project);
        a.free(self.elsewhere);
        a.free(self.base);
        self.tmp.cleanup();
        a.destroy(self);
    }

    fn connect(self: *TestRig, a: std.mem.Allocator) !unix.Connection {
        const me: u32 = @intCast(c.geteuid());
        return unix.connect(a, self.listener.socketPath(), me, testWait());
    }
};

test "setup host is private per connection and rejects a client-supplied epoch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    var first = try rig.connect(a);
    defer first.close();
    var second = try rig.connect(a);
    defer second.close();
    rig.supervisor.acceptTick();
    rig.supervisor.acceptTick();
    try std.testing.expect(rig.supervisor.slots[0] != null and rig.supervisor.slots[1] != null);

    const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{rig.project});
    defer a.free(body);
    const one = try setupOpFrame(a, 1, "settings", body);
    defer a.free(one);
    const reply_one = try controlRoundTrip(&rig.supervisor, &first, one);
    defer a.free(reply_one);
    try std.testing.expect(std.mem.indexOf(u8, reply_one, "\"ok\":true") != null);

    const two = try setupOpFrame(a, 2, "settings", body);
    defer a.free(two);
    const reply_two = try controlRoundTrip(&rig.supervisor, &second, two);
    defer a.free(reply_two);
    try std.testing.expect(std.mem.indexOf(u8, reply_two, "\"ok\":true") != null);

    const slot_a = rig.supervisor.slots[0].?.setup.?;
    const slot_b = rig.supervisor.slots[1].?.setup.?;
    try std.testing.expect(slot_a.host != slot_b.host);
    try std.testing.expect(slot_a.epoch != 0 and slot_b.epoch != 0);

    // A client-supplied epoch never becomes the setup host's control epoch.
    const spoof = try std.fmt.allocPrint(
        a,
        ",\"key\":\"fake-owner-key\",\"provider\":\"deepseek\",\"epoch\":999,\"project\":\"{s}\"",
        .{rig.project},
    );
    defer a.free(spoof);
    const login = try setupOpFrame(a, 3, "login", spoof);
    defer a.free(login);
    const reply_login = try controlRoundTrip(&rig.supervisor, &first, login);
    defer a.free(reply_login);
    try std.testing.expect(std.mem.indexOf(u8, reply_login, "\"ok\":true") != null);
    try std.testing.expect(rig.supervisor.slots[0].?.setup.?.host == slot_a.host);
    try std.testing.expect(rig.supervisor.slots[1].?.setup == null or rig.supervisor.slots[1].?.setup.?.host == slot_b.host);

    try std.testing.expectEqual(@as(usize, 0), rig.supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.workers.list.items.len);
}

test "setup host honors first user input directory then explicit project hint" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    var client = try rig.connect(a);
    defer client.close();
    rig.supervisor.acceptTick();
    try std.testing.expect(rig.supervisor.slots[0] != null);

    // No hint and no accepted input yet: the owner's HOME is the fallback.
    {
        const frame = try setupOpFrame(a, 1, "settings", "");
        defer a.free(frame);
        const reply = try controlRoundTrip(&rig.supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    try std.testing.expectEqualStrings(rig.home, rig.supervisor.slots[0].?.setup.?.project);

    // Simulate the first accepted user input (a created session's directory)
    // without spawning a worker.
    rig.supervisor.first_project = try a.dupe(u8, rig.project);

    {
        const frame = try setupOpFrame(a, 2, "settings", "");
        defer a.free(frame);
        const reply = try controlRoundTrip(&rig.supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    try std.testing.expectEqualStrings(rig.project, rig.supervisor.slots[0].?.setup.?.project);

    const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{rig.elsewhere});
    defer a.free(body);
    const frame = try setupOpFrame(a, 2, "settings", body);
    defer a.free(frame);
    const reply = try controlRoundTrip(&rig.supervisor, &client, frame);
    defer a.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    try std.testing.expectEqualStrings(rig.elsewhere, rig.supervisor.slots[0].?.setup.?.project);
    // The remembered first input directory is not overwritten by a hint.
    try std.testing.expectEqualStrings(rig.project, rig.supervisor.first_project.?);
}

/// One index record with a valid endpoint, exactly the shape `spawn` publishes,
/// for lifecycle tests that must not start a real worker.
fn publishTestRecord(a: std.mem.Allocator, reg: *registry.Registry, id: ids.Id, project: []const u8, instance: []const u8) ![]u8 {
    const endpoint = try std.fmt.allocPrint(a, "{s}/workers/{s}.sock", .{ reg.runtimeDirectory().path, instance });
    errdefer a.free(endpoint);
    try reg.register(.{
        .id = id,
        .project = project,
        .endpoint = endpoint,
        .owner = .daemon,
        .owner_instance = instance,
        .state = "running",
        .pid = 4242,
        .generation = 1,
    });
    return endpoint;
}

/// A real published checkpoint, the only durable resume locator, inside the
/// owned project's own checkpoint directory.
fn writeTestCheckpoint(a: std.mem.Allocator, io: std.Io, project: []const u8, id: ids.Id) !void {
    try writeTestSessionsFile(a, io, project, id, ".session");
}

/// Diagnostics share the checkpoint directory but are never history.
fn writeTestDiagnostic(a: std.mem.Allocator, io: std.Io, project: []const u8, id: ids.Id) !void {
    try writeTestSessionsFile(a, io, project, id, ".log");
}

fn writeTestSessionsFile(a: std.mem.Allocator, io: std.Io, project: []const u8, id: ids.Id, suffix: []const u8) !void {
    var root = try fs.Root.open(a, io, project);
    defer root.deinit();
    const dir = try logs.openCheckpointDirectory(&root);
    defer fs.closeFd(dir);
    var buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buffer, "{s}{s}", .{ id, suffix }, 0);
    const fd = fs.linux.openat(dir, path, 1 | fs.linux.create | fs.linux.exclusive | fs.linux.nofollow | fs.linux.cloexec, 0o600);
    if (fd < 0) return fs.osError();
    defer fs.closeFd(fd);
    try fs.fileFromFd(fd).writePositionalAll(io, "{}", 0);
}

fn ownedCreated(a: std.mem.Allocator, project: []const u8, id: ids.Id, endpoint: []const u8) !Created {
    const project_copy = try a.dupe(u8, project);
    errdefer a.free(project_copy);
    return .{ .id = id, .project = project_copy, .endpoint = try a.dupe(u8, endpoint) };
}

test "closed worker keeps a resumable locator and drops an empty session" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    const keep_id = try ids.generate(io);
    const drop_id = try ids.generate(io);
    const diagnostics_id = try ids.generate(io);

    const keep_ep = try publishTestRecord(a, &rig.reg, keep_id, rig.project, "aaaaaaaaaaaaaaa1");
    defer a.free(keep_ep);
    const drop_ep = try publishTestRecord(a, &rig.reg, drop_id, rig.project, "aaaaaaaaaaaaaaa2");
    defer a.free(drop_ep);
    const diagnostics_ep = try publishTestRecord(a, &rig.reg, diagnostics_id, rig.project, "aaaaaaaaaaaaaaa3");
    defer a.free(diagnostics_ep);

    try rig.supervisor.created.append(a, try ownedCreated(a, rig.project, keep_id, keep_ep));
    try rig.supervisor.created.append(a, try ownedCreated(a, rig.project, drop_id, drop_ep));
    try rig.supervisor.created.append(a, try ownedCreated(a, rig.project, diagnostics_id, diagnostics_ep));

    // One clean join with a complete checkpoint, one empty session, and one
    // session that only ever wrote a diagnostic log.
    try writeTestCheckpoint(a, io, rig.project, keep_id);
    try writeTestDiagnostic(a, io, rig.project, diagnostics_id);

    try rig.supervisor.shutdownOwned();

    // The checkpointed session keeps its locator metadata for resume and list.
    var kept = (try rig.reg.resolve(a, keep_id, rig.project)) orelse return error.TestExpectedRecord;
    defer registry.freeRecord(a, &kept);
    try std.testing.expectEqualStrings(keep_ep, kept.endpoint);
    try std.testing.expectEqualStrings(rig.project, kept.project);
    // A session with nothing to resume loses exactly its own record.
    try std.testing.expect((try rig.reg.resolve(a, drop_id, rig.project)) == null);
    // Diagnostics are never treated as history.
    try std.testing.expect((try rig.reg.resolve(a, diagnostics_id, rig.project)) == null);
    try std.testing.expectEqual(@as(usize, 0), rig.supervisor.created.items.len);
}

test "a retired worker never deletes a locator a later owner republished" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    const id = try ids.generate(io);
    const old_ep = try publishTestRecord(a, &rig.reg, id, rig.project, "bbbbbbbbbbbbbbb1");
    defer a.free(old_ep);
    // A later owner (a foreground resume of the same id) republished the entry.
    const new_ep = try publishTestRecord(a, &rig.reg, id, rig.project, "bbbbbbbbbbbbbbb2");
    defer a.free(new_ep);

    // The older worker exits with no checkpoint; its retirement must leave the
    // newer record untouched instead of unpublishing by id alone.
    rig.supervisor.retireWorker(id, rig.project, old_ep);

    var kept = (try rig.reg.resolve(a, id, rig.project)) orelse return error.TestExpectedRecord;
    defer registry.freeRecord(a, &kept);
    try std.testing.expectEqualStrings(new_ep, kept.endpoint);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbb2", kept.owner_instance);
}

test "an owner lifecycle stop is never probed and then killed without force" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    const id = try ids.generate(io);
    const endpoint = try publishTestRecord(a, &rig.reg, id, rig.project, "ccccccccccccccc1");
    defer a.free(endpoint);
    try rig.supervisor.created.append(a, try ownedCreated(a, rig.project, id, endpoint));

    var client = try rig.connect(a);
    defer client.close();
    rig.supervisor.acceptTick();

    const frame = try std.fmt.allocPrint(
        a,
        "{{\"v\":{d},\"id\":1,\"op\":\"close\",\"session\":\"{s}\"}}",
        .{ protocol.version, id },
    );
    defer a.free(frame);
    const reply = try controlRoundTrip(&rig.supervisor, &client, frame);
    defer a.free(reply);
    // A probe-then-stop could kill a task submitted between the probe and the
    // kill, so `force` is required instead of probing at all.
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"accepted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"busy\"") != null);
    try std.testing.expectEqual(@as(usize, 1), rig.supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.workers.list.items.len);
    var kept = (try rig.reg.resolve(a, id, rig.project)) orelse return error.TestExpectedRecord;
    defer registry.freeRecord(a, &kept);
    try std.testing.expectEqualStrings(endpoint, kept.endpoint);
}
