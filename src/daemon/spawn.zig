//! Owned worker-process spawner for daemon and foreground sessions.
//!
//! Every `create` starts exactly one persistent `thin --internal-worker ...`
//! process through `platform/process.run` (same exec handshake, process-group
//! ownership and bounded TERM->KILL cleanup as background commands). The child
//! runs with bounded captured stdio, never a PTY, in its own process group, so
//! it is independent of the SSH/TUI session that requested it. Nothing here
//! uses `--print`, and a failed start is always cancelled, reaped and cleaned
//! up before the error is returned.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const linux = std.os.linux;

const fs = @import("../platform/filesystem.zig");
const platform_process = @import("../platform/process.zig");
const interrupt = @import("../platform/interrupt.zig");
const p = @import("../core/protocol.zig");
const daemon_protocol = @import("protocol.zig");
const unix = @import("unix.zig");
const registry = @import("registry.zig");
const cli = @import("../app/cli.zig");
const ids = @import("../app/session_id.zig");

/// Requested worker identity. `resume` reuses an existing checkpoint id;
/// `restore_selection` only imports an old selection into a *new* empty id.
pub const Params = struct {
    project: []const u8,
    owner: cli.WorkerOwner,
    @"resume": ?ids.Id = null,
    restore_selection: ?ids.Id = null,
    auto_refresh_models: bool = false,
};

/// Outcome published by the process-run thread. Scalars only, safe cross-thread.
pub const Outcome = struct {
    term: ?std.process.Child.Term = null,
    cleanup_failed: bool = false,
    canceled: bool = false,
    timed_out: bool = false,
    truncated: bool = false,
    unreaped_pid: ?c.pid_t = null,
    exit_error: ?anyerror = null,
    stdout_bytes: u64 = 0,
    stderr_bytes: u64 = 0,
};

const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: ids.Id,
    owner: cli.WorkerOwner,
    project: fs.Root,
    endpoint: []u8,
    instance: [16]u8,
    script: []u8,
    /// Per-worker environment: a private copy of the launcher environment plus
    /// the launcher's real pid for the worker's parent-death handshake. Wiped
    /// and released with this worker.
    env: std.process.Environ.Map,
    cancel: p.Cancellation = .{},
    /// 0 pending, 1 launched, 2 failed (process.LaunchNotice).
    launch: std.atomic.Value(u8) = .init(0),
    launched_pid: std.atomic.Value(i32) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    /// Set only by `awaitReady` when a not-yet-ready worker ended with a
    /// closed private startup exit code. It never relaxes anything for a
    /// worker that produced a `hello`.
    startup_rejected: bool = false,
    outcome: Outcome = .{},
    future: ?std.Io.Future(Outcome) = null,
    /// Bounded tail of the child's captured stderr, for diagnostics only.
    tail: [1024]u8 = undefined,
    tail_len: usize = 0,

    fn publish(self: *Worker, out: Outcome) void {
        self.outcome = out;
        self.done.store(true, .release);
    }
};

pub const Workers = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    uid: u32,
    runtime: unix.Directory,
    workers_fd: c.fd_t,
    base_path: []u8,
    environ: *std.process.Environ.Map,
    list: std.ArrayList(*Worker) = .empty,
    /// Bounded readiness budget; a worker that has not answered `hello` by then
    /// is cancelled and reaped.
    startup_timeout_ms: u32 = 15_000,
    /// Minimum grace after the `shutdown` request before TERM, then KILL. The
    /// effective grace is at least this and at least the cleanup budget the
    /// worker itself reported through the public `settings` op.
    shutdown_grace_ms: u64 = 2_000,
    /// Minimum per-worker grace for `close`, same reported-budget rule.
    close_grace_ms: u64 = 2_000,
    poisoned: std.atomic.Value(bool) = .init(false),
    last_failure: [1024]u8 = undefined,
    last_failure_len: usize = 0,
    /// Last unconfirmed-cleanup record: worker id plus the real Term it ended
    /// with. Never a credential; kept as the evidence a failed stop refuses to
    /// discard.
    unclean: [256]u8 = undefined,
    unclean_len: usize = 0,

    pub fn init(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !Workers {
        const uid: u32 = @intCast(c.getuid());
        var runtime = try unix.Directory.resolve(a, environ, uid);
        errdefer runtime.deinit();

        // Create/verify `<runtime>/workers` through the unix layer once, then keep
        // an fd-anchored path for endpoint unlinking.
        var workers_dir = try unix.Directory.resolveUnder(a, runtime.path, "workers", uid);
        workers_dir.deinit();
        const base_path = try std.fmt.allocPrint(a, "{s}/workers", .{runtime.path});
        errdefer a.free(base_path);
        const workers_fd = try fs.openDirectory(runtime.fd, "workers");
        errdefer fs.closeFd(workers_fd);

        const env = try a.create(std.process.Environ.Map);
        errdefer a.destroy(env);
        env.* = try cloneEnvironment(a, environ);

        return .{
            .allocator = a,
            .io = io,
            .uid = uid,
            .runtime = runtime,
            .workers_fd = workers_fd,
            .base_path = base_path,
            .environ = env,
        };
    }

    /// Start one real persistent worker and wait for its `hello`. The returned
    /// record borrows this instance's storage and stays valid until `deinit`.
    pub fn create(self: *Workers, params: Params) !registry.Record {
        try validateParams(params);
        if (self.poisoned.load(.acquire)) return error.CleanupFailed;
        if (params.@"resume" orelse params.restore_selection) |target_id| {
            for (self.list.items) |worker| {
                if (worker.done.load(.acquire)) continue;
                if (std.mem.eql(u8, &worker.id, &target_id)) return error.Busy;
            }
        }

        const a = self.allocator;
        const io = self.io;

        // A restore-selection starts a NEW empty session; the old selection id is
        // only forwarded to the worker as `--worker-restore-selection <id>`.
        const id: ids.Id = params.@"resume" orelse try ids.generate(io);

        // Reserve list capacity before creating any worker so handoff cannot
        // fail after ownership has moved into the heap allocation.
        try self.list.ensureUnusedCapacity(a, 1);

        // Single ownership switch: while false, the guarded errdefers below own
        // project/endpoint/script/env; after the heap Worker is populated, it is
        // the only owner and none of those errdefers may release anything again.
        var handed_off = false;

        // Anchor the project now; the child changes into this exact dirfd.
        const project = try fs.Root.open(a, io, params.project);
        errdefer if (!handed_off) {
            var owned = project;
            owned.deinit();
        };

        var instance: [16]u8 = undefined;
        try randomInstance(io, &instance);
        const endpoint = try std.fmt.allocPrint(a, "{s}/{s}.sock", .{ self.base_path, instance[0..] });
        errdefer if (!handed_off) a.free(endpoint);

        const exe = try selfExecutable(a);
        defer a.free(exe);
        const script = try buildCommand(a, exe, endpoint, id, params);
        errdefer if (!handed_off) {
            wipe(script);
            a.free(script);
        };

        // Independent environment for this child. THIN_WORKER_OWNER_PID is the
        // real pid of the Thin launcher (never the bash wrapper pid), which the
        // worker checks before and after installing PDEATHSIG.
        var env = try cloneEnvironment(a, self.environ);
        errdefer if (!handed_off) deinitEnvironmentWiped(&env);
        {
            var pid_buf: [16]u8 = undefined;
            const pid_text = try std.fmt.bufPrint(&pid_buf, "{d}", .{std.os.linux.getpid()});
            try env.put("THIN_WORKER_OWNER_PID", pid_text);
        }

        const worker = try a.create(Worker);
        worker.* = .{
            .allocator = a,
            .io = io,
            .id = id,
            .owner = params.owner,
            .project = project,
            .endpoint = endpoint,
            .instance = instance,
            .script = script,
            .env = env,
        };
        // Handoff point: from here the Worker is the sole owner of all four
        // resources, including on every error path below.
        handed_off = true;
        worker.future = std.Io.concurrent(io, workerMain, .{worker}) catch |err| {
            self.destroyWorker(worker);
            return err;
        };
        self.list.appendAssumeCapacity(worker);

        const greeting = self.awaitReady(worker) catch |err| {
            self.abort(worker);
            return err;
        };
        if (greeting.owner != params.owner or !std.mem.eql(u8, &greeting.session, &id) or greeting.pid != greeting.peer_pid) {
            self.abort(worker);
            return error.SpawnFailed;
        }

        const now_ms: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toMilliseconds()));
        return .{
            .id = id,
            .project = worker.project.path,
            .endpoint = worker.endpoint,
            .owner = params.owner,
            .owner_instance = worker.instance[0..],
            .state = "running",
            .pid = greeting.pid,
            .generation = now_ms,
            .updated_ms = now_ms,
        };
    }

    /// Stop every worker this instance created: best-effort `shutdown` first,
    /// a bounded grace, then cancel (TERM/KILL through the owned group) and
    /// join all. Every worker is notified before any join, and the single wait
    /// uses the largest cleanup budget the workers reported, never a serial
    /// per-worker grace. A cleanup that cannot be confirmed is an error, never
    /// success.
    pub fn shutdown(self: *Workers) !void {
        if (self.list.items.len == 0) return;
        var grace_ms: u64 = self.shutdown_grace_ms;
        for (self.list.items) |worker| {
            if (worker.done.load(.acquire)) continue;
            grace_ms = @max(grace_ms, self.requestShutdown(worker, self.shutdown_grace_ms));
        }
        self.awaitAll(grace_ms);
        for (self.list.items) |worker| {
            if (!worker.done.load(.acquire)) worker.cancel.cancel();
        }

        var unclean = false;
        for (self.list.items) |worker| {
            const out = self.joinWorker(worker);
            if (self.cleanupUnconfirmed(worker, out)) unclean = true;
            self.removeEndpoint(worker);
        }
        if (unclean) {
            self.poisoned.store(true, .release);
            return error.CleanupFailed;
        }
    }

    /// Stop exactly one owned worker. `project` must match the canonical
    /// project this worker was created for. The reported cleanup budget applies
    /// here as well, so a worker that is still releasing its own nested
    /// services is neither killed early nor reported as a clean stop.
    pub fn close(self: *Workers, id: ids.Id, project: ?[]const u8) !void {
        const worker = self.find(id) orelse return error.SessionNotFound;
        if (project) |expected| {
            if (!std.mem.eql(u8, expected, worker.project.path)) return error.SessionNotFound;
        }
        if (!worker.done.load(.acquire)) {
            const grace_ms = self.requestShutdown(worker, self.close_grace_ms);
            self.awaitWorker(worker, grace_ms);
            if (!worker.done.load(.acquire)) worker.cancel.cancel();
        }
        const out = self.joinWorker(worker);
        if (self.cleanupUnconfirmed(worker, out)) {
            self.poisoned.store(true, .release);
            return error.CleanupFailed;
        }
        self.removeEndpoint(worker);
        self.remove(worker);
        self.destroyWorker(worker);
    }

    /// True while an owned worker with this id is alive. Exited-but-unreaped
    /// workers are not alive; `reap` decides whether they can be released.
    pub fn isAlive(self: *Workers, id: ids.Id) bool {
        for (self.list.items) |worker| {
            if (!std.mem.eql(u8, &worker.id, &id)) continue;
            if (!worker.done.load(.acquire)) return true;
        }
        return false;
    }

    /// Join completed workers; any unconfirmed cleanup poisons new starts.
    pub fn reap(self: *Workers) !void {
        var unclean = false;
        for (self.list.items) |worker| {
            if (!worker.done.load(.acquire)) continue;
            const out = self.joinWorker(worker);
            if (self.cleanupUnconfirmed(worker, out)) unclean = true;
        }
        if (unclean) {
            self.poisoned.store(true, .release);
            return error.CleanupFailed;
        }
    }

    /// Bounded diagnostic tail of the last failed worker (never a credential:
    /// the child's stdio carries no configuration values).
    pub fn failureDetail(self: *const Workers) ?[]const u8 {
        if (self.last_failure_len == 0) return null;
        return self.last_failure[0..self.last_failure_len];
    }

    pub fn deinit(self: *Workers) void {
        var unclean = false;
        for (self.list.items) |worker| {
            if (!worker.done.load(.acquire)) {
                unclean = true;
                continue; // never free a possibly-live owner
            }
            const out = self.joinWorker(worker);
            if (self.cleanupUnconfirmed(worker, out)) {
                unclean = true;
                continue;
            }
            self.destroyWorker(worker);
        }
        if (unclean) {
            // Fail-stop for this instance: do not free shared environment,
            // paths or owned process records that could still be referenced.
            std.debug.print("thin: daemon worker cleanup unconfirmed; refusing to free owned processes\n", .{});
            return;
        }
        self.list.deinit(self.allocator);
        wipe(self.last_failure[0..]);
        var env_it = self.environ.iterator();
        while (env_it.next()) |entry| {
            wipe(@constCast(entry.key_ptr.*));
            wipe(@constCast(entry.value_ptr.*));
        }
        self.environ.deinit();
        self.allocator.destroy(self.environ);
        fs.closeFd(self.workers_fd);
        self.allocator.free(self.base_path);
        self.runtime.deinit();
        self.* = undefined;
    }

    fn find(self: *Workers, id: ids.Id) ?*Worker {
        for (self.list.items) |worker| {
            if (std.mem.eql(u8, &worker.id, &id)) return worker;
        }
        return null;
    }

    fn remove(self: *Workers, worker: *Worker) void {
        for (self.list.items, 0..) |candidate, index| {
            if (candidate == worker) {
                _ = self.list.orderedRemove(index);
                return;
            }
        }
    }

    fn joinWorker(self: *Workers, worker: *Worker) Outcome {
        var future = worker.future orelse return worker.outcome;
        worker.future = null;
        const out = future.await(self.io);
        worker.outcome = out;
        return out;
    }

    /// Failed start: no accepted resource exists yet, so this keeps the original
    /// contract and only requires confirmed process cleanup. A worker that was
    /// cancelled before its `hello` may legitimately end by KILL; the reported
    /// services only exist after acceptance.
    fn abort(self: *Workers, worker: *Worker) void {
        worker.cancel.cancel();
        const out = self.joinWorker(worker);
        self.captureFailure(worker);
        if (out.cleanup_failed or out.unreaped_pid != null) {
            // Keep the owned worker (and its recorded pid) for a later shutdown;
            // never pretend the failure was clean.
            self.poisoned.store(true, .release);
            return;
        }
        self.removeEndpoint(worker);
        self.remove(worker);
        self.destroyWorker(worker);
    }

    fn captureFailure(self: *Workers, worker: *Worker) void {
        if (worker.tail_len == 0) return;
        const n = @min(worker.tail.len, self.last_failure.len);
        @memcpy(self.last_failure[0..n], worker.tail[0..n]);
        self.last_failure_len = n;
    }

    fn awaitReady(self: *Workers, worker: *Worker) !registry.Hello {
        const start = std.Io.Clock.awake.now(self.io);
        while (true) {
            if (worker.done.load(.acquire)) {
                const out = self.joinWorker(worker);
                if (classifyStartupOutcome(out)) |err| {
                    worker.startup_rejected = true;
                    return err;
                }
                return error.SpawnFailed;
            }
            if (interrupt.signal() != 0) return error.Canceled;
            if (worker.launch.load(.acquire) == 2) {
                _ = self.joinWorker(worker);
                return error.SpawnFailed;
            }
            if (registry.helloEndpoint(self.allocator, self.io, self.uid, worker.endpoint, handshake_probe_ms)) |greeting| {
                return greeting;
            } else |_| {}
            if (start.untilNow(self.io, .awake).toMilliseconds() >= @as(i64, @intCast(self.startup_timeout_ms)))
                return error.Timeout;
            std.Io.sleep(self.io, .fromMilliseconds(5), .awake) catch return error.Canceled;
        }
    }

    /// A joined worker is only clean when the process itself confirms it: no
    /// unconfirmed process/group cleanup and a Term it produced on purpose.
    /// Anything else keeps a bounded record and fails the stop.
    fn cleanupUnconfirmed(self: *Workers, worker: *Worker, out: Outcome) bool {
        // A startup rejection is confirmed by the process itself: the worker
        // refused to start and exited with its private mapping code. Only that
        // flag, set on the pre-`hello` path, can use this exception; an
        // unexpected 70..90 exit of a running worker still fails the stop.
        if (worker.startup_rejected and classifyStartupOutcome(out) != null) return false;
        if (out.cleanup_failed or out.unreaped_pid != null or !termConfirmed(out.term)) {
            self.recordUnclean(worker, out);
            return true;
        }
        return false;
    }

    fn recordUnclean(self: *Workers, worker: *Worker, out: Outcome) void {
        var term_buf: [48]u8 = undefined;
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} term={s} cleanup_failed={s} unreaped_pid={d}", .{
            worker.id[0..],
            describeTerm(&term_buf, out.term),
            if (out.cleanup_failed) "true" else "false",
            out.unreaped_pid orelse 0,
        }) catch return;
        const count = @min(text.len, self.unclean.len);
        @memcpy(self.unclean[0..count], text[0..count]);
        self.unclean_len = count;
    }

    /// One shared bounded wait: all notified workers converge in parallel, so
    /// the deadline is the largest reported budget, not the sum of them.
    fn awaitAll(self: *Workers, grace_ms: u64) void {
        const start = std.Io.Clock.awake.now(self.io);
        while (true) {
            var running = false;
            for (self.list.items) |worker| {
                if (!worker.done.load(.acquire)) {
                    running = true;
                    break;
                }
            }
            if (!running) return;
            if (start.untilNow(self.io, .awake).toMilliseconds() >= @as(i64, @intCast(grace_ms))) return;
            std.Io.sleep(self.io, .fromMilliseconds(5), .awake) catch return;
        }
    }

    fn awaitWorker(self: *Workers, worker: *Worker, grace_ms: u64) void {
        const start = std.Io.Clock.awake.now(self.io);
        while (!worker.done.load(.acquire)) {
            if (start.untilNow(self.io, .awake).toMilliseconds() >= @as(i64, @intCast(grace_ms))) return;
            std.Io.sleep(self.io, .fromMilliseconds(5), .awake) catch return;
        }
    }

    /// Ask one worker for a graceful stop and return the cleanup grace its own
    /// limits require. The public `settings` reply is read first and the
    /// replies stay correlated by request id (1 then 2) on one owner-authorized
    /// connection. An unavailable or malformed reply only selects the
    /// conservative fallback: a failed query never starts, resumes or touches
    /// another worker, and cancellation below stays the guaranteed path.
    fn requestShutdown(self: *Workers, worker: *Worker, floor_ms: u64) u64 {
        var conn = unix.connect(self.allocator, worker.endpoint, self.uid, .{
            .io = self.io,
            .timeout_ms = settings_probe_ms,
        }) catch return cleanupGraceMs(null, floor_ms);
        defer conn.close();
        const limits = self.queryCleanupLimits(&conn);
        // The ack is advisory: the worker performs its cleanup before replying,
        // so a short correlated read keeps the notification of every worker
        // parallel instead of waiting for each one's cleanup in turn.
        if (self.exchange(&conn, shutdown_request_id, "shutdown", handshake_probe_ms)) |payload| {
            defer self.allocator.free(payload);
            // Correlated acknowledgement only: the exit path is the authority,
            // and an unreadable ack never changes what this owner does next.
            if (parseReply(self.allocator, payload, shutdown_request_id)) |ack| {
                var owned = ack;
                owned.deinit();
            } else |_| {}
        }
        return cleanupGraceMs(limits, floor_ms);
    }

    fn queryCleanupLimits(self: *Workers, conn: *unix.Connection) ?CleanupLimits {
        const payload = self.exchange(conn, settings_request_id, "settings", settings_reply_ms) orelse return null;
        defer self.allocator.free(payload);
        var doc = parseReply(self.allocator, payload, settings_request_id) catch return null;
        defer doc.deinit();
        return replyCleanupLimits(doc.value);
    }

    /// One correlated request/reply on an already-authorized owner connection.
    /// The returned payload is owned by the caller; any failure yields null.
    fn exchange(self: *Workers, conn: *unix.Connection, id: u64, op: []const u8, reply_ms: u32) ?[]u8 {
        var buf: [96]u8 = undefined;
        const request = std.fmt.bufPrint(&buf, "{{\"v\":{d},\"id\":{d},\"op\":\"{s}\"}}", .{
            daemon_protocol.version, id, op,
        }) catch return null;
        conn.writeFrame(request, .{ .io = self.io, .timeout_ms = settings_probe_ms }) catch return null;
        return (conn.readFrame(.{ .io = self.io, .timeout_ms = reply_ms }) catch return null) orelse null;
    }

    /// Bounded diagnostic record of the last stop that could not be confirmed.
    pub fn uncleanDetail(self: *const Workers) ?[]const u8 {
        if (self.unclean_len == 0) return null;
        return self.unclean[0..self.unclean_len];
    }

    fn removeEndpoint(self: *Workers, worker: *Worker) void {
        var buf: [64]u8 = undefined;
        const name_z = std.fmt.bufPrintSentinel(&buf, "{s}.sock", .{worker.instance[0..]}, 0) catch return;
        var st: linux.Statx = undefined;
        if (c.statx(self.workers_fd, name_z.ptr, linux.AT.SYMLINK_NOFOLLOW, linux.STATX.BASIC_STATS, &st) != 0) return;
        if (st.mode & linux.S.IFMT != linux.S.IFSOCK) return;
        if (st.uid != self.uid) return;
        _ = c.unlinkat(self.workers_fd, name_z.ptr, 0);
    }

    fn destroyWorker(self: *Workers, worker: *Worker) void {
        const a = self.allocator;
        wipe(worker.script);
        a.free(worker.script);
        a.free(worker.endpoint);
        deinitEnvironmentWiped(&worker.env);
        worker.project.deinit();
        a.destroy(worker);
    }
};

/// Per-attempt readiness budget: one connect + hello, never a long block.
const handshake_probe_ms: u32 = 50;

/// Correlated request ids of the stop exchange. They stay fixed so a reply is
/// never accepted for a different operation on the same owner connection.
const settings_request_id: u64 = 1;
const shutdown_request_id: u64 = 2;
/// Bounded link budget for the `settings` request itself.
const settings_probe_ms: u32 = 500;
/// A public `settings` reply also carries the model catalog, so one reply may
/// be much larger than a probe frame; this is still a bounded wait.
const settings_reply_ms: u32 = 1_500;
/// Fixed IPC/teardown margin added to the worker's own cleanup budget: the
/// reply, the worker's exit, the endpoint removal and the reap are all local.
const cleanup_ipc_margin_ms: u64 = 2_000;
/// Conservative grace when the worker cannot report its own limits. Waiting
/// too long only costs a bounded wait; killing too early loses nested services.
const cleanup_fallback_grace_ms: u64 = 30_000;
/// Hard ceiling, so a bogus or hostile reply cannot hold the owner forever.
const cleanup_max_grace_ms: u64 = 120_000;

/// The only two worker limits this spawner needs: how long the worker itself
/// waits for the nested services it owns. Public `core_config.Limits` numbers
/// as published by the public `settings` op, never raw config or a credential.
const CleanupLimits = struct {
    grace_ms: u64,
    timeout_ms: u64,
};

/// Saturated sum of the worker's own cleanup budget plus the IPC/teardown
/// margin, never below the local floor and never above the hard ceiling.
fn cleanupGraceMs(limits: ?CleanupLimits, floor_ms: u64) u64 {
    const value = limits orelse return @min(@max(cleanup_fallback_grace_ms, floor_ms), cleanup_max_grace_ms);
    const reported = std.math.add(u64, value.grace_ms, value.timeout_ms) catch std.math.maxInt(u64);
    const total = std.math.add(u64, reported, cleanup_ipc_margin_ms) catch std.math.maxInt(u64);
    return @min(@max(total, floor_ms), cleanup_max_grace_ms);
}

/// A worker that refused to start reports the exact reason only through its
/// private exit code. This accepts nothing else: cleanup must be confirmed, no
/// pid may be unreaped, and the Term must be a real normal exit carrying a
/// mapped code. Any other shape (signal, KILL, timeout, kill after cancel,
/// unmapped code) stays `null` so the ordinary `SpawnFailed` path is kept.
fn classifyStartupOutcome(out: Outcome) ?anyerror {
    if (out.cleanup_failed or out.unreaped_pid != null) return null;
    if (out.canceled or out.timed_out) return null;
    const code = switch (out.term orelse return null) {
        .exited => |status| status,
        else => return null,
    };
    return daemon_protocol.startupError(code);
}

/// True only for a worker that ended on its own terms: exit code 0, or the
/// `128+signal` code it returns *after* cancelling, saving its checkpoint and
/// closing its endpoint. A real signal termination (including SIGKILL) reaps
/// the worker leader only: the nested services it owned live in their own
/// process groups, so a reaped leader is never proof that they are gone.
fn termConfirmed(term: ?std.process.Child.Term) bool {
    const code = switch (term orelse return false) {
        .exited => |status| status,
        else => return false,
    };
    if (code == 0) return true;
    if (code <= 128) return false;
    const signal_code: u32 = code -% 128;
    return signal_code == @backingInt(std.c.SIG.HUP) or
        signal_code == @backingInt(std.c.SIG.INT) or
        signal_code == @backingInt(std.c.SIG.QUIT) or
        signal_code == @backingInt(std.c.SIG.TERM);
}

/// Bounded parsing of one correlated reply. Only a successful reply carrying
/// the expected request id may become a budget source or an acknowledgement.
fn parseReply(a: std.mem.Allocator, payload: []const u8, expected_id: u64) !std.json.Parsed(std.json.Value) {
    if (payload.len == 0 or payload.len > unix.max_frame_len) return error.BadResponse;
    var doc = std.json.parseFromSlice(std.json.Value, a, payload, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.BadResponse;
    errdefer doc.deinit();
    const object = switch (doc.value) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const id = switch (object.get("id") orelse return error.BadResponse) {
        .integer => |value| value,
        else => return error.BadResponse,
    };
    if (id < 0 or @as(u64, @intCast(id)) != expected_id) return error.BadResponse;
    const ok = switch (object.get("ok") orelse return error.BadResponse) {
        .bool => |value| value,
        else => return error.BadResponse,
    };
    if (!ok) return error.BadResponse;
    return doc;
}

/// Project the public `limits` object onto the two cleanup numbers. Anything
/// missing, negative or out of range means "no usable budget reported".
fn replyCleanupLimits(value: std.json.Value) ?CleanupLimits {
    const object = switch (value) {
        .object => |value_object| value_object,
        else => return null,
    };
    const limits = switch (object.get("limits") orelse return null) {
        .object => |limits_object| limits_object,
        else => return null,
    };
    return .{
        .grace_ms = replyLimit(limits.get("cleanup_grace_ms") orelse return null) orelse return null,
        .timeout_ms = replyLimit(limits.get("cleanup_timeout_ms") orelse return null) orelse return null,
    };
}

fn replyLimit(value: std.json.Value) ?u64 {
    const integer = switch (value) {
        .integer => |number| number,
        else => return null,
    };
    if (integer < 0) return null;
    const positive: u64 = @intCast(integer);
    if (positive > cleanup_max_grace_ms) return null;
    return positive;
}

fn workerMain(worker: *Worker) Outcome {
    const options: platform_process.Options = .{
        // A persistent session has no command deadline; cancellation still
        // performs the bounded TERM->KILL group cleanup and reap.
        .timeout_ms = null,
        // Bounded captured stdio, never a PTY.
        .output_bytes = 16 * 1024,
        .term_grace_ms = 1_000,
        .cleanup_timeout_ms = 5_000,
        .cwd_dir = worker.project.dir,
        .on_launch = .{ .context = worker, .notify_fn = launchNotify },
    };
    const result = platform_process.run(worker.allocator, worker.io, worker.project.path, worker.script, &worker.env, options, &worker.cancel) catch |err| {
        const out: Outcome = .{ .exit_error = err };
        worker.publish(out);
        return out;
    };
    defer {
        worker.allocator.free(result.stdout);
        worker.allocator.free(result.stderr);
    }
    const tail_len = @min(result.stderr.len, worker.tail.len);
    @memcpy(worker.tail[0..tail_len], result.stderr[0..tail_len]);
    worker.tail_len = tail_len;

    const out: Outcome = .{
        .term = result.term,
        .cleanup_failed = result.cleanup_failed,
        .canceled = result.canceled,
        .timed_out = result.timed_out,
        .truncated = result.truncated,
        .unreaped_pid = result.unreaped_pid,
        .stdout_bytes = result.stdout_bytes,
        .stderr_bytes = result.stderr_bytes,
    };
    worker.publish(out);
    return out;
}

fn describeTerm(buf: []u8, term: ?std.process.Child.Term) []const u8 {
    const value = term orelse return std.fmt.bufPrint(buf, "none", .{}) catch "none";
    return std.fmt.bufPrint(buf, "{f}", .{value}) catch "unknown";
}

fn launchNotify(context: *anyopaque, notice: platform_process.LaunchNotice) void {
    const worker: *Worker = @ptrCast(@alignCast(context));
    worker.launched_pid.store(@intCast(notice.pid), .release);
    worker.launch.store(if (notice.launched and notice.group_owned) 1 else 2, .release);
}

fn validateParams(params: Params) !void {
    if (params.project.len == 0 or params.project.len > 4096) return error.InvalidArguments;
    if (std.mem.findScalar(u8, params.project, 0) != null) return error.InvalidArguments;
    if (params.@"resume" != null and params.restore_selection != null) return error.InvalidArguments;
    if (params.@"resume") |id| if (!ids.valid(id)) return error.InvalidSessionID;
    if (params.restore_selection) |id| if (!ids.valid(id)) return error.InvalidSessionID;
}

fn randomInstance(io: std.Io, out: *[16]u8) !void {
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    out.* = std.fmt.bytesToHex(random, .lower);
}

fn selfExecutable(a: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rc = c.readlink("/proc/self/exe", &buf, buf.len);
    if (rc < 0) return fs.osError();
    return a.dupe(u8, buf[0..@intCast(rc)]);
}

/// Build the exact `exec` script. Sessions IDs are lowercase hex and owner tags
/// are fixed, so only the executable path, endpoint and selection id can carry
/// shell metacharacters; those are single-quoted. No credential ever appears in
/// the child argv.
fn buildCommand(a: std.mem.Allocator, exe: []const u8, endpoint: []const u8, id: ids.Id, params: Params) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("exec ");
    try writeQuoted(w, exe);
    try w.writeAll(" --internal-worker ");
    try writeQuoted(w, endpoint);
    try w.writeByte(' ');
    try w.writeAll(id[0..]);
    try w.writeByte(' ');
    try w.writeAll(@tagName(params.owner));
    if (params.@"resume" != null) try w.writeAll(" --worker-resume");
    if (params.restore_selection) |selection| {
        try w.writeAll(" --worker-restore-selection ");
        try w.writeAll(selection[0..]);
    }
    if (!params.auto_refresh_models) try w.writeAll(" --no-model-auto-refresh");
    return a.dupe(u8, out.written());
}

fn shellSafe(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        const ok = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or byte == '_' or byte == '-' or byte == '.' or
            byte == '/' or byte == ':' or byte == '=' or byte == '+' or byte == '@' or byte == '%';
        if (!ok) return false;
    }
    return true;
}

fn writeQuoted(w: *std.Io.Writer, bytes: []const u8) !void {
    if (shellSafe(bytes)) return w.writeAll(bytes);
    try w.writeByte('\'');
    for (bytes) |byte| {
        if (byte == '\'') {
            try w.writeAll("'\\''");
        } else try w.writeByte(byte);
    }
    try w.writeByte('\'');
}

fn cloneEnvironment(a: std.mem.Allocator, source: *const std.process.Environ.Map) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(a);
    errdefer result.deinit();
    var it = source.iterator();
    while (it.next()) |entry| try result.put(entry.key_ptr.*, entry.value_ptr.*);
    return result;
}

fn deinitEnvironmentWiped(env: *std.process.Environ.Map) void {
    var it = env.iterator();
    while (it.next()) |entry| {
        wipe(@constCast(entry.key_ptr.*));
        wipe(@constCast(entry.value_ptr.*));
    }
    env.deinit();
}

fn wipe(bytes: []u8) void {
    for (bytes) |*byte| @as(*volatile u8, @ptrCast(byte)).* = 0;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "worker argv quotes paths, selection ids and optional flags" {
    const a = testing.allocator;
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const selection: ids.Id = "fedcba9876543210fedcba9876543210".*;

    const plain = try buildCommand(a, "/usr/bin/thin", "/run/user/1/thin/workers/aaaaaaaaaaaaaaaa.sock", id, .{
        .project = "/tmp/project",
        .owner = .daemon,
    });
    defer a.free(plain);
    try testing.expectEqualStrings(
        "exec /usr/bin/thin --internal-worker /run/user/1/thin/workers/aaaaaaaaaaaaaaaa.sock " ++
            "0123456789abcdef0123456789abcdef daemon --no-model-auto-refresh",
        plain,
    );
    try testing.expect(std.mem.indexOf(u8, plain, "--no-log") == null);

    const quoted = try buildCommand(a, "/opt/thin bin/thin", "/tmp/a b/it's.sock", id, .{
        .project = "/tmp/project",
        .owner = .foreground,
        .@"resume" = id,
        .auto_refresh_models = true,
    });
    defer a.free(quoted);
    try testing.expectEqualStrings(
        "exec '/opt/thin bin/thin' --internal-worker '/tmp/a b/it'\\''s.sock' " ++
            "0123456789abcdef0123456789abcdef foreground --worker-resume",
        quoted,
    );

    const restored = try buildCommand(a, "/bin/thin", "/run/aaaaaaaaaaaaaaaa.sock", id, .{
        .project = "/tmp/project",
        .owner = .daemon,
        .restore_selection = selection,
        .auto_refresh_models = true,
    });
    defer a.free(restored);
    try testing.expectEqualStrings(
        "exec /bin/thin --internal-worker /run/aaaaaaaaaaaaaaaa.sock " ++
            "0123456789abcdef0123456789abcdef daemon --worker-restore-selection fedcba9876543210fedcba9876543210",
        restored,
    );
}

test "worker params reject conflicting resume and selection modes" {
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    try testing.expectError(error.InvalidArguments, validateParams(.{
        .project = "/tmp/project",
        .owner = .daemon,
        .@"resume" = id,
        .restore_selection = id,
    }));
    try testing.expectError(error.InvalidArguments, validateParams(.{
        .project = "",
        .owner = .daemon,
    }));
    try validateParams(.{ .project = "/tmp/project", .owner = .foreground });
}

test "cleanup grace covers the reported worker budget and never kills early" {
    // A worker that reports its own grace+timeout gets that budget plus the
    // fixed IPC/teardown margin, so legitimate long cleanups are never cut to
    // the local floor (the earlier fixed 2s + 1s behaviour).
    try testing.expectEqual(@as(u64, 12_000), cleanupGraceMs(.{ .grace_ms = 4_000, .timeout_ms = 6_000 }, 2_000));
    // The local floor stays a floor, never a cap.
    try testing.expectEqual(@as(u64, 2_300), cleanupGraceMs(.{ .grace_ms = 100, .timeout_ms = 200 }, 2_000));
    try testing.expectEqual(@as(u64, 2_000), cleanupGraceMs(.{ .grace_ms = 0, .timeout_ms = 0 }, 2_000));
    // No usable reply: conservative fallback, still above the old floor.
    try testing.expectEqual(@as(u64, 30_000), cleanupGraceMs(null, 2_000));
    try testing.expectEqual(@as(u64, 45_000), cleanupGraceMs(null, 45_000));
    // Saturated addition cannot wrap; the hard ceiling still bounds the wait.
    try testing.expectEqual(@as(u64, cleanup_max_grace_ms), cleanupGraceMs(.{ .grace_ms = 60_000, .timeout_ms = 60_000 }, 2_000));
    try testing.expectEqual(@as(u64, cleanup_max_grace_ms), cleanupGraceMs(.{ .grace_ms = std.math.maxInt(u64), .timeout_ms = std.math.maxInt(u64) }, 2_000));
    try testing.expectEqual(@as(u64, cleanup_max_grace_ms), cleanupGraceMs(null, std.math.maxInt(u64)));
}

test "private startup rejection is classified only from a confirmed mapped exit" {
    const Term = std.process.Child.Term;
    // A clean, mapped normal exit is the only accepted shape.
    try testing.expectEqual(error.SelectionNotFound, classifyStartupOutcome(.{ .term = .{ .exited = 70 } }).?);
    try testing.expectEqual(error.ApiKeyNotFound, classifyStartupOutcome(.{ .term = .{ .exited = 81 } }).?);
    try testing.expectEqual(error.SelectionEndpointUnavailable, classifyStartupOutcome(.{ .term = .{ .exited = 82 } }).?);
    // Unmapped, reserved-but-empty and out-of-band codes stay unclassified, so
    // the caller keeps the ordinary SpawnFailed path.
    for ([_]u8{ 0, 1, 69, 83, 90, 130, 143, 255 }) |code| {
        try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = code } }) == null);
    }
    try testing.expect(classifyStartupOutcome(.{}) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = Term{ .signal = .KILL } }) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = Term{ .signal = .TERM } }) == null);
    // A mapped code is not proof while cleanup is unconfirmed or a pid leaked.
    try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = 70 }, .cleanup_failed = true }) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = 70 }, .unreaped_pid = 1234 }) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = 70 }, .canceled = true }) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = 70 }, .timed_out = true }) == null);
}

test "only a self-terminated worker counts as a confirmed clean stop" {
    const Term = std.process.Child.Term;
    try testing.expect(termConfirmed(.{ .exited = 0 }));
    // The worker returns 128+signal only after cancelling, saving its final
    // checkpoint and closing its endpoint.
    for ([_]u8{ 129, 130, 131, 143 }) |code| try testing.expect(termConfirmed(.{ .exited = code }));
    try testing.expect(!termConfirmed(null));
    try testing.expect(!termConfirmed(.{ .exited = 1 }));
    try testing.expect(!termConfirmed(.{ .exited = 128 }));
    try testing.expect(!termConfirmed(.{ .exited = 137 }));
    // A reaped leader killed by a real signal proves nothing about the nested
    // services it owned in their own process groups.
    try testing.expect(!termConfirmed(Term{ .signal = .KILL }));
    try testing.expect(!termConfirmed(Term{ .signal = .TERM }));
    try testing.expect(!termConfirmed(Term{ .stopped = .TERM }));
    try testing.expect(!termConfirmed(.{ .unknown = 0x7f }));
}

test "settings reply budgets are read only from a correlated successful reply" {
    const a = testing.allocator;
    const ok_reply =
        "{\"v\":2,\"id\":1,\"ok\":true,\"limits\":{\"cleanup_grace_ms\":4000,\"cleanup_timeout_ms\":6000}}";
    {
        var doc = try parseReply(a, ok_reply, settings_request_id);
        defer doc.deinit();
        const limits = replyCleanupLimits(doc.value) orelse return error.TestExpectedLimits;
        try testing.expectEqual(@as(u64, 4_000), limits.grace_ms);
        try testing.expectEqual(@as(u64, 6_000), limits.timeout_ms);
    }
    // Correlation is mandatory: another request id or a failed reply is not a
    // budget source, so the caller keeps the conservative fallback.
    try testing.expectError(error.BadResponse, parseReply(a, ok_reply, shutdown_request_id));
    try testing.expectError(error.BadResponse, parseReply(
        a,
        "{\"v\":2,\"id\":2,\"ok\":false,\"err\":\"rejected\"}",
        shutdown_request_id,
    ));
    try testing.expectError(error.BadResponse, parseReply(a, "{\"v\":2,\"id\":0,\"ok\":true}", shutdown_request_id));
    try testing.expectError(error.BadResponse, parseReply(a, "", settings_request_id));
    try testing.expectError(error.BadResponse, parseReply(a, "[]", settings_request_id));

    // A reply without the two numbers, or with unusable ones, yields no budget.
    const missing = try std.json.parseFromSlice(std.json.Value, a, "{\"v\":2,\"id\":1,\"ok\":true,\"limits\":{\"command_timeout_ms\":10000}}", .{});
    defer missing.deinit();
    try testing.expect(replyCleanupLimits(missing.value) == null);
    const malformed = try std.json.parseFromSlice(std.json.Value, a, "{\"v\":2,\"id\":1,\"ok\":true,\"limits\":{\"cleanup_grace_ms\":-1,\"cleanup_timeout_ms\":6000}}", .{});
    defer malformed.deinit();
    try testing.expect(replyCleanupLimits(malformed.value) == null);
    const too_large = try std.json.parseFromSlice(std.json.Value, a, "{\"v\":2,\"id\":1,\"ok\":true,\"limits\":{\"cleanup_grace_ms\":4000,\"cleanup_timeout_ms\":60000000}}", .{});
    defer too_large.deinit();
    try testing.expect(replyCleanupLimits(too_large.value) == null);
}

test "workers runtime directory is private and endpoints use only owner instance" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const base = buf[0..n];
    try tmp.dir.createDir(testing.io, "runtime", .fromMode(0o700));
    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    try tmp.dir.createDir(testing.io, "home", .default_dir);
    const runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{base});
    defer a.free(runtime);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("XDG_RUNTIME_DIR", runtime);

    var workers = try Workers.init(a, testing.io, &env);
    defer workers.deinit();

    var st: linux.Statx = undefined;
    try testing.expectEqual(@as(c_int, 0), c.statx(workers.workers_fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &st));
    try testing.expectEqual(@as(u16, 0o700), @as(u16, @intCast(st.mode & 0o777)));
    try testing.expect(std.mem.endsWith(u8, workers.base_path, "/workers"));

    // Endpoint names are `<16hex>.sock`; the session id is not in the name.
    const endpoint = try std.fmt.allocPrint(a, "{s}/{s}.sock", .{ workers.base_path, "abcdef0123456789" });
    defer a.free(endpoint);
    try testing.expect(std.mem.endsWith(u8, endpoint, "/abcdef0123456789.sock"));
}

test "workers create rejects a missing project without leaving a child" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const base = buf[0..n];
    try tmp.dir.createDir(testing.io, "runtime", .fromMode(0o700));
    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    try tmp.dir.createDir(testing.io, "home", .default_dir);
    const runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{base});
    defer a.free(runtime);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("XDG_RUNTIME_DIR", runtime);

    var workers = try Workers.init(a, testing.io, &env);
    defer workers.deinit();
    try testing.expectError(error.FileNotFound, workers.create(.{
        .project = "/definitely/missing/project",
        .owner = .daemon,
    }));
    try testing.expectEqual(@as(usize, 0), workers.list.items.len);
}
