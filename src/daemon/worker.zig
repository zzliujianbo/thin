//! Internal per-session worker process.
//!
//! One worker owns exactly one `SessionHost` (one Session/App/Runtime) and one
//! AF_UNIX endpoint published by its parent (foreground launcher or daemon).
//! It is not a daemon: it never binds `daemon.sock`, never spawns another
//! worker, and exits when its owner says so.
//!
//! Lifecycle rules implemented here:
//! - The endpoint must be exactly `<runtime-dir>/workers/<name>` of this UID;
//!   the worker binds it through `daemon/unix.zig`, so it never unlinks an
//!   arbitrary caller-supplied path.
//! - A parent-death SIGTERM prevents an orphaned worker from keeping a session
//!   alive after its owner was killed. No cached PID is ever signalled.
//! - Several RPC connections are served on the single owner thread. EOF only
//!   revokes that connection's controller epoch; the task keeps running.
//! - SIGINT/SIGTERM/HUP/QUIT cancel and join the owned task, save the final
//!   checkpoint, close the endpoint and exit.

const std = @import("std");
const Io = std.Io;
const cli = @import("../app/cli.zig");
const ids = @import("../app/session_id.zig");
const protocol = @import("../daemon/protocol.zig");
const unix = @import("unix.zig");
const interrupt = @import("../platform/interrupt.zig");
const SessionHost = @import("../app/session_host.zig").SessionHost;

/// Bounded transport fan-out for one worker. This is not a session quota.
const max_connections = 32;
/// Accept/read polling slices keep the single owner thread responsive.
const accept_timeout_ms: u32 = 10;
const read_timeout_ms: u32 = 2;
const write_timeout_ms: u32 = 10_000;

const Active = struct {
    id: u64,
    conn: unix.Connection,
};

pub fn run(init: std.process.Init, options: cli.Options) !u8 {
    return runInner(init.gpa, init.io, init.environ_map, options) catch |err| {
        // A worker that dies before publishing `hello` has no wire channel, so
        // the only truthful report is its process exit status. Only the closed
        // private startup names take this path; everything else keeps the
        // ordinary failure identity (the product CLI still exits 1).
        if (protocol.startupExitCode(err)) |code| return code;
        return err;
    };
}

/// Split from `run` so the entry contract stays fixed while the whole body is
/// analyzable/offline-testable without a real `std.process.Init`.
fn runInner(a: std.mem.Allocator, io: Io, environ_map: *std.process.Environ.Map, options: cli.Options) !u8 {
    if (options.mode != .worker) return error.InvalidArguments;
    const endpoint = options.worker_endpoint orelse return error.InvalidArguments;
    const session_id = options.worker_session orelse return error.InvalidArguments;
    if (!std.fs.path.isAbsolute(endpoint)) return error.InvalidArguments;
    if (options.worker_resume and options.worker_restore_selection != null) return error.InvalidArguments;

    // The launcher passes its real pid in a private child-only variable; it is
    // not a credential and never reaches the model, config or checkpoints.
    const expected_owner = try expectedOwnerPid(environ_map);
    // Check before creating any session state: a worker whose owner already
    // died must not activate a Runtime, even for a moment.
    if (std.os.linux.getppid() != expected_owner) return error.ParentGone;

    var guard = try interrupt.Guard.install();
    defer guard.deinit();

    installParentDeath();
    // prctl cannot help if the owner died between the two checks (and pid 1 is
    // a legitimate containerized daemon owner).
    if (std.os.linux.getppid() != expected_owner) return error.ParentGone;

    // Fixed project root: the startup directory, resolved once.
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const project_len = try Io.Dir.cwd().realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];

    const uid: u32 = @intCast(std.c.geteuid());
    var runtime_dir = try unix.Directory.resolve(a, environ_map, uid);
    defer runtime_dir.deinit();
    var workers = try unix.Directory.resolveUnder(a, runtime_dir.path, "workers", uid);
    defer workers.deinit();

    const name = try endpointName(&workers, a, endpoint);
    defer a.free(name);
    const lock_name = try lockName(a, name);
    defer a.free(lock_name);

    // One endpoint = one worker. The lock also authorizes stale-socket cleanup.
    var lock = try unix.Lock.acquire(a, &workers, lock_name);
    defer lock.release();

    const host = try SessionHost.init(a, io, environ_map, .{
        .project = project,
        .id = session_id,
        .@"resume" = if (options.worker_resume) session_id else null,
        .restore_selection = options.worker_restore_selection,
        .logging = options.logging,
        .auto_refresh_models = options.auto_refresh_models,
        .owner = options.worker_owner,
    });
    defer host.deinit();

    var listener = try unix.Listener.bind(a, &workers, name, .{ .lock = &lock });
    defer listener.deinit();

    const parent_pid = expected_owner;
    var slots: [max_connections]?Active = @splat(null);
    // Every exit path (including shutdown errors) revokes views and closes
    // sockets without cancelling the task; shutdown itself owns cancel/join.
    defer closeSlots(host, &slots);
    var next_connection: u64 = 0;
    var accept_failures: u32 = 0;
    var stop_signal: u8 = 0;

    while (true) {
        // Signals first: a stop must cancel/join, not abandon the session.
        stop_signal = interrupt.signal();
        if (stop_signal != 0) break;

        host.pump(nowMs(io));
        if (host.isClosing()) break;

        if (freeSlot(&slots) != null) {
            if (listener.accept(waitProgress(host, io, accept_timeout_ms))) |connection| {
                accept_failures = 0;
                next_connection +%= 1;
                if (next_connection == 0) next_connection = 1;
                const index = freeSlot(&slots).?;
                slots[index] = .{ .id = next_connection, .conn = connection };
            } else |err| switch (err) {
                // A timeout, a cancelled wait or an unauthorized peer is not a
                // listener failure; other peers still connect.
                error.Timeout,
                error.Canceled,
                error.PeerUidMismatch,
                // A new view cannot turn resource shortage into task shutdown.
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.OutOfMemory,
                error.SystemResources,
                => {},
                else => {
                    accept_failures += 1;
                    if (accept_failures >= 256) return err;
                },
            }
        }

        for (&slots) |*slot| {
            if (slot.*) |*active| {
                // Keep consuming the Bridge between connections as well, so a
                // burst of slow clients cannot delay Runtime progress.
                host.pump(nowMs(io));
                serveOne(host, a, io, active, parent_pid, slot);
                host.pump(nowMs(io));
            }
        }
    }

    listener.close();
    // A failed save/cleanup must not be reported as a clean stop.
    try host.shutdown();
    if (stop_signal != 0) return 128 + stop_signal;
    return 0;
}

/// Wait for one transport operation while the owner thread keeps draining the
/// Bridge. Cancellation (a real signal) aborts the wait; the connection is
/// dropped by the caller without cancelling the task.
fn waitProgress(host: *SessionHost, io: Io, timeout_ms: u32) unix.Wait {
    return .{
        .io = io,
        .timeout_ms = timeout_ms,
        .progress_context = host,
        .progress_fn = pumpWhileWaiting,
    };
}

fn pumpWhileWaiting(context: ?*anyopaque) anyerror!void {
    const host: *SessionHost = @ptrCast(@alignCast(context.?));
    if (interrupt.signal() != 0) return error.Canceled;
    host.pump(nowMs(host.io));
}

fn closeSlots(host: *SessionHost, slots: *[max_connections]?Active) void {
    for (slots) |*slot| {
        if (slot.*) |*active| {
            host.disconnected(active.id);
            active.conn.close();
            slot.* = null;
        }
    }
}

/// Serve at most one frame for `active`. Returns false when the connection was
/// closed or replaced and must not be touched again.
fn serveOne(host: *SessionHost, a: std.mem.Allocator, io: Io, active: *Active, parent_pid: std.os.linux.pid_t, slot: *?Active) void {
    const frame = active.conn.readFrame(waitProgress(host, io, read_timeout_ms)) catch |err| switch (err) {
        error.Timeout, error.Canceled => return,
        else => {
            dropSlot(host, slot, active);
            return;
        },
    };
    const raw = frame orelse {
        // Clean EOF: only this view/control epoch is revoked.
        dropSlot(host, slot, active);
        return;
    };
    // Request bytes may contain a login key; never leave them in memory.
    defer {
        std.crypto.secureZero(u8, raw);
        a.free(raw);
    }

    var request = protocol.parseRequest(a, raw) catch {
        // Malformed/unknown frames close this connection, not the session.
        dropSlot(host, slot, active);
        return;
    };
    defer request.deinit();

    const owner_authorized = active.conn.peer.pid == parent_pid;
    const response = host.dispatch(a, &request, active.id, owner_authorized) catch {
        // Only allocation failure escapes dispatch; the reply cannot be built.
        dropSlot(host, slot, active);
        return;
    };
    defer {
        std.crypto.secureZero(u8, response);
        a.free(response);
    }
    // A slow reader must not stall the Runtime: every poll of this wait pumps
    // the Bridge on the owner thread and lets a signal abort the write.
    active.conn.writeFrame(response, waitProgress(host, io, write_timeout_ms)) catch {
        dropSlot(host, slot, active);
        return;
    };
}

fn dropSlot(host: *SessionHost, slot: *?Active, active: *Active) void {
    host.disconnected(active.id);
    active.conn.close();
    slot.* = null;
}

fn freeSlot(slots: *[max_connections]?Active) ?usize {
    for (slots, 0..) |slot, i| if (slot == null) return i;
    return null;
}

/// Resolve the caller-supplied endpoint to a single name inside this worker's
/// private directory. The exact joined path must match; anything else is
/// rejected before any socket operation, so no arbitrary path is unlinked.
fn endpointName(workers: *const unix.Directory, a: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    const base = std.fs.path.basename(endpoint);
    if (base.len == 0) return error.InvalidArguments;
    const expected = try workers.join(a, base);
    defer a.free(expected);
    if (!std.mem.eql(u8, expected, endpoint)) return error.InvalidArguments;
    return a.dupe(u8, base);
}

/// Stable per-endpoint instance lock name (fixed-width hash keeps it bounded).
fn lockName(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0x7468696e, name);
    return std.fmt.allocPrint(a, "w-{x:0>16}.lock", .{hash});
}

/// Strictly parse the launcher-provided owner pid. Reject empty, signed,
/// zero-padded-and-huge or non-numeric values; pid 1 is accepted.
fn expectedOwnerPid(environ: *const std.process.Environ.Map) !std.os.linux.pid_t {
    const raw = environ.get("THIN_WORKER_OWNER_PID") orelse return error.MissingOwnerPid;
    if (raw.len == 0 or raw.len > 10) return error.InvalidOwnerPid;
    for (raw) |byte| if (byte < '0' or byte > '9') return error.InvalidOwnerPid;
    const value = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidOwnerPid;
    if (value == 0 or value > std.math.maxInt(std.os.linux.pid_t)) return error.InvalidOwnerPid;
    return @intCast(value);
}

/// Ask Linux to TERM this process when its owner dies. Best effort: the owner
/// also joins workers explicitly, and ppid==1 is checked separately.
fn installParentDeath() void {
    _ = std.os.linux.prctl(
        @backingInt(std.os.linux.PR.SET_PDEATHSIG),
        @backingInt(std.os.linux.SIG.TERM),
        0,
        0,
        0,
    );
}

fn nowMs(io: Io) u64 {
    const value = Io.Clock.awake.now(io).toMilliseconds();
    return if (value < 0) 0 else @intCast(value);
}

test "owner pid rejects values outside Linux signed pid range without trapping" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    for ([_][]const u8{ "2147483648", "4294967295", "4294967296", "00000000000" }) |raw| {
        try env.put("THIN_WORKER_OWNER_PID", raw);
        try std.testing.expectError(error.InvalidOwnerPid, expectedOwnerPid(&env));
    }
    try env.put("THIN_WORKER_OWNER_PID", "1");
    try std.testing.expectEqual(@as(std.os.linux.pid_t, 1), try expectedOwnerPid(&env));
    try env.put("THIN_WORKER_OWNER_PID", "2147483647");
    try std.testing.expectEqual(std.math.maxInt(std.os.linux.pid_t), try expectedOwnerPid(&env));
}

test "endpoint validation rejects paths outside the private workers directory" {
    try std.testing.expectEqualStrings("ok.sock", std.fs.path.basename("/run/thin/workers/ok.sock"));
    try std.testing.expectEqualStrings("escape.sock", std.fs.path.basename("../escape.sock"));
}

test "worker entry rejects non-worker mode before creating any session state" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expectError(error.InvalidArguments, runInner(a, std.testing.io, &env, .{ .mode = .foreground }));
    try std.testing.expectError(error.InvalidArguments, runInner(a, std.testing.io, &env, .{ .mode = .worker }));
    try std.testing.expectError(error.InvalidArguments, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_endpoint = "relative.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
    // A missing or malformed owner pid is refused before any session state.
    try std.testing.expectError(error.MissingOwnerPid, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
    try env.put("THIN_WORKER_OWNER_PID", "0");
    try std.testing.expectError(error.InvalidOwnerPid, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
    try env.put("THIN_WORKER_OWNER_PID", "-7");
    try std.testing.expectError(error.InvalidOwnerPid, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
}
