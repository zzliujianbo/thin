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
//! - Linux uses parent-death SIGTERM; Darwin foreground workers watch their
//!   private owner lifetime pipe. No cached PID is ever signalled.
//! - Several RPC connections are served on the single owner thread. EOF only
//!   revokes that connection's controller epoch; the task keeps running.
//! - SIGINT/SIGTERM/HUP/QUIT cancel and join the owned task, save the final
//!   checkpoint, close the endpoint and exit.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const fs = @import("../platform/filesystem.zig");
const native_metadata = @import("../platform/metadata.zig");
const Io = std.Io;
const cli = @import("../app/cli.zig");
const ids = @import("../app/session_id.zig");
const protocol = @import("../daemon/protocol.zig");
const unix = @import("unix.zig");
const interrupt = @import("../platform/interrupt.zig");
const SessionHost = @import("../app/session_host.zig").SessionHost;
const Wakeup = @import("../platform/wakeup.zig").Wakeup;

/// Bounded transport fan-out for one worker. This is not a session quota.
const max_connections = 32;
/// This is a lifecycle fallback, not a per-connection wait. Bridge events wake
/// the shared poll immediately; signals and task-reaping still get a bound.
const idle_timeout_ms: c_int = 20;
const write_timeout_ms: u32 = 10_000;

const Active = struct {
    id: u64,
    conn: unix.Connection,
    write_started_ms: u64 = 0,
    watch: ?Watch = null,
};

const Watch = struct {
    request_id: u64,
    epoch: u64,
    control_id: u64,
    cursor: u64,
    stamp: SessionHost.WatchStamp,
    /// Frozen second baseline frame; first (snapshot) is the outgoing frame.
    baseline: ?[]u8,
    row_cursor: u64 = 0,
    row_group: u64 = 0,
    repeat_first: bool = false,
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
    if (builtin.os.tag == .macos and options.worker_owner == .daemon) return error.UnsupportedPlatform;

    // The launcher passes its real pid in a private child-only variable; it is
    // not a credential and never reaches the model, config or checkpoints.
    const expected_owner = try expectedOwnerPid(environ_map);
    // Check before creating any session state: a worker whose owner already
    // died must not activate a Runtime, even for a moment.
    if (c.getppid() != expected_owner) return error.ParentGone;
    // The child owns only this inherited reader, never the parent's writer.
    // Restore CLOEXEC before any session/tool can spawn; the numeric env value
    // is not a credential and is validated as an actual read-only pipe.
    const lifetime_fd = if (builtin.os.tag == .macos) try takeOwnerPipe(environ_map) else -1;
    defer if (lifetime_fd >= 0) fs.closeFd(lifetime_fd);
    if (lifetime_fd >= 0 and !try lifetimeAlive(lifetime_fd)) return error.ParentGone;

    var guard = try interrupt.Guard.install();
    defer guard.deinit();

    if (builtin.os.tag == .linux) installParentDeath();
    // Cover death during guard/pipe setup. pid 1 remains a valid Linux owner.
    if (c.getppid() != expected_owner) return error.ParentGone;

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

    // Must outlive host.deinit(), which joins every Bridge producer.
    var wake = try Wakeup.init();
    defer wake.deinit();
    // Last startup check immediately before Runtime activation. A death after
    // this check is observed independently by the lifetime poll below.
    if (c.getppid() != expected_owner) return error.ParentGone;
    if (lifetime_fd >= 0 and !try lifetimeAlive(lifetime_fd)) return error.ParentGone;
    const host = try SessionHost.init(a, io, environ_map, .{
        .project = project,
        .id = session_id,
        .@"resume" = if (options.worker_resume) session_id else null,
        .restore_selection = options.worker_restore_selection,
        .auto_refresh_models = options.auto_refresh_models,
        .owner = options.worker_owner,
    });
    defer host.deinit();
    host.bridge.notification = .{ .context = &wake, .notify_fn = Wakeup.callback };

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
    var accept_after_ms: u64 = 0;

    while (true) {
        // Signals first: a stop must cancel/join, not abandon the session.
        stop_signal = interrupt.signal();
        if (stop_signal != 0) break;
        if (lifetime_fd >= 0 and !try lifetimeAlive(lifetime_fd)) break;

        // Drain notification BEFORE checking real work. A racing producer
        // either has its work pumped now, or leaves a readable wake fd.
        wake.drain();
        host.pump(nowMs(io));
        const closing = host.isClosing();
        if (closing and !hasPendingWrites(&slots)) break;

        var descriptors: [max_connections + 3]c.pollfd = undefined;
        const accept_ready = !closing and freeSlot(&slots) != null and nowMs(io) >= accept_after_ms;
        descriptors[0] = .{ .fd = if (accept_ready) listener.fd else -1, .events = c.POLL.IN, .revents = 0 };
        descriptors[1] = .{ .fd = wake.fd, .events = c.POLL.IN, .revents = 0 };
        // Separate from every RPC/TUI slot; peer EOF never owns this lifecycle.
        descriptors[max_connections + 2] = .{ .fd = lifetime_fd, .events = c.POLL.IN, .revents = 0 };
        for (&slots, 0..) |*slot, index| {
            descriptors[index + 2] = .{ .fd = -1, .events = 0, .revents = 0 };
            if (slot.*) |*active| {
                if (active.watch != null and (closing or !watchValid(host, &slots, active))) {
                    dropSlot(host, slot, active);
                    continue;
                }
                if (!closing) advanceWatch(host, a, io, active) catch {
                    // Gap/OOM/expired binding closes this read-only stream,
                    // never the control socket or its task. Reattach needs a
                    // fresh complete baseline, not an invented event suffix.
                    dropSlot(host, slot, active);
                    continue;
                };
                if (active.conn.writePending() and nowMs(io) -| active.write_started_ms >= write_timeout_ms) {
                    dropSlot(host, slot, active);
                    continue;
                }
                descriptors[index + 2] = .{
                    .fd = active.conn.fd,
                    // A subscribed stream stops reading input while a frame is
                    // still being written: the ACK stays buffered in the peer
                    // socket instead of spinning on POLLOUT|POLLIN.
                    .events = (if (active.conn.writePending()) @as(i16, c.POLL.OUT) else 0) |
                        (if (active.watch != null)
                            (if (!active.conn.writePending()) @as(i16, c.POLL.IN) else 0)
                        else
                            (if (!closing and !active.conn.writePending()) @as(i16, c.POLL.IN) else 0)),
                    .revents = 0,
                };
            }
        }
        const ready = std.c.poll(&descriptors, descriptors.len, idle_timeout_ms);
        if (ready < 0) {
            if (c._errno().* == @backingInt(c.E.INTR)) continue;
            return error.TransportPollFailed;
        }
        if (interrupt.signal() != 0) continue;
        // Owner loss has priority over accepting or dispatching more work.
        // Break into the same cancel/save/reap path as an orderly shutdown.
        if (lifetime_fd >= 0 and descriptors[max_connections + 2].revents != 0 and
            !try lifetimeAlive(lifetime_fd)) break;
        if (descriptors[0].revents != 0) {
            if (listener.acceptStep()) |maybe| {
                if (maybe) |connection| {
                    accept_failures = 0;
                    next_connection +%= 1;
                    if (next_connection == 0) next_connection = 1;
                    const index = freeSlot(&slots).?;
                    slots[index] = .{ .id = next_connection, .conn = connection };
                    // The slot had no descriptor in this poll; service it on
                    // the next turn rather than inheriting another fd's flags.
                }
            } else |err| switch (err) {
                error.PeerUidMismatch => {},
                // Resource pressure cannot shut down an accepted task or cause
                // a ready-listener busy loop. Retry admission independently.
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.OutOfMemory,
                error.SystemResources,
                => accept_after_ms = nowMs(io) +| 50,
                else => {
                    accept_failures += 1;
                    if (accept_failures >= 256) return err;
                    accept_after_ms = nowMs(io) +| 50;
                },
            }
        }

        for (&slots, 0..) |*slot, index| {
            if (slot.*) |*active| {
                host.pump(nowMs(io));
                if (descriptors[index + 2].fd != active.conn.fd or descriptors[index + 2].revents == 0) continue;
                if (active.watch != null) {
                    if (!watchValid(host, &slots, active) or
                        descriptors[index + 2].revents & (c.POLL.HUP | c.POLL.ERR | c.POLL.NVAL) != 0)
                    {
                        // A revoked controller binding closes only this stream.
                        dropSlot(host, slot, active);
                        continue;
                    }
                    if (descriptors[index + 2].revents & c.POLL.IN != 0) {
                        // One bounded display ACK. Any other op still closes the
                        // stream, so it never borrows controller mutation rights.
                        serveWatchInput(host, a, io, active, slot, &slots);
                        if (slot.* == null) continue;
                    }
                }
                if (active.conn.writePending()) {
                    _ = active.conn.writeStep() catch {
                        dropSlot(host, slot, active);
                        continue;
                    };
                } else if (!host.isClosing()) {
                    serveOne(host, a, io, active, parent_pid, slot, &slots);
                }
            }
        }
    }

    listener.close();
    // A failed save/cleanup must not be reported as a clean stop.
    try host.shutdown();
    if (stop_signal != 0) return 128 + stop_signal;
    return 0;
}

fn hasPendingWrites(slots: *const [max_connections]?Active) bool {
    for (slots) |slot| if (slot) |active| {
        if (active.conn.writePending()) return true;
    };
    return false;
}

fn closeSlots(host: *SessionHost, slots: *[max_connections]?Active) void {
    for (slots) |*slot| {
        if (slot.*) |*active| {
            dropSlot(host, slot, active);
        }
    }
}

/// Decode at most one ready frame, then queue one reply without waiting for its
/// reader. No second request is dispatched until this reply finishes.
fn serveOne(host: *SessionHost, a: std.mem.Allocator, io: Io, active: *Active, parent_pid: c.pid_t, slot: *?Active, slots: *[max_connections]?Active) void {
    const step = active.conn.readStep() catch {
        dropSlot(host, slot, active);
        return;
    };
    const raw = switch (step) {
        .pending => return,
        .eof => {
            dropSlot(host, slot, active);
            return;
        },
        .frame => |frame| frame,
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

    if (request.op == .watch) {
        startWatch(host, a, io, active, &request, slots) catch {
            dropSlot(host, slot, active);
        };
        return;
    }
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
    active.conn.queueFrame(response) catch {
        dropSlot(host, slot, active);
        return;
    };
    active.write_started_ms = nowMs(io);
}

/// Exactly one frame from a subscribed watch socket. Only a display ACK is
/// accepted; it is the sole watermark that reclaims retained live events. The
/// reply is a control frame the receiver consumes, never a display page.
fn serveWatchInput(host: *SessionHost, a: std.mem.Allocator, io: Io, active: *Active, slot: *?Active, slots: *[max_connections]?Active) void {
    const watch = active.watch orelse {
        dropSlot(host, slot, active);
        return;
    };
    const step = active.conn.readStep() catch {
        dropSlot(host, slot, active);
        return;
    };
    const raw = switch (step) {
        .pending => return,
        .eof => {
            dropSlot(host, slot, active);
            return;
        },
        .frame => |frame| frame,
    };
    defer {
        std.crypto.secureZero(u8, raw);
        a.free(raw);
    }
    var request = protocol.parseRequest(a, raw) catch {
        // Only a display ACK is legal on a subscribed stream; everything else
        // keeps the read-only rule and closes this connection.
        dropSlot(host, slot, active);
        return;
    };
    defer request.deinit();
    if (request.op != .ack) {
        dropSlot(host, slot, active);
        return;
    }
    const epoch = request.u64Field("epoch") catch {
        dropSlot(host, slot, active);
        return;
    };
    const sequence = request.u64Field("sequence") catch {
        dropSlot(host, slot, active);
        return;
    };
    // `first` is optional on the wire: absent means the prefix `[0, sequence]`.
    const first = request.optionalU64("first") catch {
        dropSlot(host, slot, active);
        return;
    };
    // Re-check the binding immediately before applying the range: the
    // acknowledgement must come from this controller's own validated viewer.
    if (epoch != watch.epoch or !watchValid(host, slots, active)) {
        dropSlot(host, slot, active);
        return;
    }
    var out = protocol.Out.init(a);
    defer out.deinit();
    // A refused range is reported to the viewer, never silently retired.
    const outcome = host.watchAcknowledgeRange(epoch, first orelse 0, sequence) catch |err| {
        out.fail(request.id, protocol.errorCode(err)) catch {
            dropSlot(host, slot, active);
            return;
        };
        out.field("ack", true) catch {
            dropSlot(host, slot, active);
            return;
        };
        const reply = out.finish() catch {
            dropSlot(host, slot, active);
            return;
        };
        defer a.free(reply);
        active.conn.queueFrame(reply) catch {
            dropSlot(host, slot, active);
            return;
        };
        active.write_started_ms = nowMs(io);
        return;
    };
    out.ok(request.id) catch {
        dropSlot(host, slot, active);
        return;
    };
    out.field("ack", true) catch {
        dropSlot(host, slot, active);
        return;
    };
    out.field("epoch", epoch) catch {
        dropSlot(host, slot, active);
        return;
    };
    out.field("first", outcome.first) catch {
        dropSlot(host, slot, active);
        return;
    };
    out.field("sequence", outcome.sequence) catch {
        dropSlot(host, slot, active);
        return;
    };
    out.field("through", outcome.through) catch {
        dropSlot(host, slot, active);
        return;
    };
    const reply = out.finish() catch {
        dropSlot(host, slot, active);
        return;
    };
    defer a.free(reply);
    active.conn.queueFrame(reply) catch {
        dropSlot(host, slot, active);
        return;
    };
    active.write_started_ms = nowMs(io);
}

fn dropSlot(host: *SessionHost, slot: *?Active, active: *Active) void {
    host.disconnected(active.id);
    if (active.watch) |watch| if (watch.baseline) |bytes| {
        std.crypto.secureZero(u8, bytes);
        active.conn.allocator.free(bytes);
    };
    active.conn.close();
    slot.* = null;
}

fn watchValid(host: *SessionHost, slots: *const [max_connections]?Active, active: *const Active) bool {
    const watch = active.watch orelse return false;
    const control_id = host.watchOwner(watch.epoch) catch return false;
    if (control_id != watch.control_id or control_id == active.id) return false;
    for (slots) |slot| if (slot) |control| {
        if (control.id == control_id) return control.watch == null and
            control.conn.peer.uid == active.conn.peer.uid and control.conn.peer.pid == active.conn.peer.pid;
    };
    return false;
}

fn startWatch(host: *SessionHost, a: std.mem.Allocator, io: Io, active: *Active, request: *const protocol.Request, slots: *[max_connections]?Active) !void {
    const epoch = try request.u64Field("epoch");
    const control_id = try host.watchOwner(epoch);
    // Validation borrows a candidate binding only; no owned storage yet.
    active.watch = .{ .request_id = request.id, .epoch = epoch, .control_id = control_id, .cursor = 0, .stamp = host.watchStamp(), .baseline = null };
    errdefer active.watch = null;
    if (!watchValid(host, slots, active)) return error.StaleControl;
    host.pump(nowMs(io));
    const resume_cursor = try request.optionalU64("since");
    const cursor = try host.watchResume(epoch, resume_cursor);
    const stamp = host.watchStamp();
    // Both encoders run at one owner turn, with no pump/wait in between.
    const snapshot = try host.watchSnapshotPage(a, request.id, epoch, 0, null);
    defer {
        std.crypto.secureZero(u8, snapshot.frame);
        a.free(snapshot.frame);
    }
    const baseline: ?[]u8 = if (resume_cursor == null) try host.watchBaseline(a, request.id, epoch) else null;
    errdefer if (baseline) |bytes| a.free(bytes);
    try active.conn.queueFrame(snapshot.frame);
    active.write_started_ms = nowMs(io);
    // The reconnect client deliberately ignores the first snapshot while it
    // catches up ordered events. Repeat page zero after that catch-up.
    active.watch.?.row_cursor = if (resume_cursor != null) 0 else snapshot.next;
    active.watch.?.repeat_first = resume_cursor != null;
    active.watch.?.row_group = snapshot.group;
    active.watch.?.stamp = stamp;
    active.watch.?.cursor = cursor;
    active.watch.?.baseline = baseline;
    // At most one subscribed connection per controller; replacement succeeds
    // only after its own complete bounded baseline has been frozen.
    for (slots) |*other| if (other.*) |*old| {
        if (old.id != active.id) if (old.watch) |watch| {
            if (watch.control_id == control_id) dropSlot(host, other, old);
        };
    };
}

fn advanceWatch(host: *SessionHost, a: std.mem.Allocator, io: Io, active: *Active) !void {
    const watch = if (active.watch) |*value| value else return;
    if (active.conn.writePending()) return;
    if (watch.baseline) |baseline| {
        try active.conn.queueFrame(baseline);
        std.crypto.secureZero(u8, baseline);
        a.free(baseline);
        watch.baseline = null;
    } else if (try host.watchEvents(a, watch.request_id, watch.epoch, watch.cursor)) |page| {
        defer a.free(page.frame);
        try active.conn.queueFrame(page.frame);
        try host.watchOffered(watch.epoch, page.through);
        watch.cursor = page.through;
    } else {
        const stamp = host.watchStamp();
        if (stamp.eql(watch.stamp) and watch.row_cursor == 0 and !watch.repeat_first) return;
        // Drain all ordered events first, then continue the current group page
        // sequence. A new group restarts at zero in watchSnapshotPage.
        const starting = watch.row_cursor == 0;
        const page = try host.watchSnapshotPage(a, watch.request_id, watch.epoch, watch.row_cursor, watch.row_group);
        defer a.free(page.frame);
        try active.conn.queueFrame(page.frame);
        watch.row_cursor = page.next;
        watch.row_group = page.group;
        watch.repeat_first = false;
        if (starting) watch.stamp = stamp;
    }
    active.write_started_ms = nowMs(io);
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
fn expectedOwnerPid(environ: *const std.process.Environ.Map) !c.pid_t {
    const raw = environ.get("THIN_WORKER_OWNER_PID") orelse return error.MissingOwnerPid;
    if (raw.len == 0 or raw.len > 10) return error.InvalidOwnerPid;
    for (raw) |byte| if (byte < '0' or byte > '9') return error.InvalidOwnerPid;
    const value = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidOwnerPid;
    if (value == 0 or value > std.math.maxInt(c.pid_t)) return error.InvalidOwnerPid;
    return @intCast(value);
}

/// Adopt only a valid nonblocking read pipe. On failure after parsing, this
/// function closes it; after success, runInner's defer is the sole owner.
fn takeOwnerPipe(environ: *const std.process.Environ.Map) !c.fd_t {
    const raw = environ.get("THIN_WORKER_OWNER_FD") orelse return error.MissingOwnerFd;
    const fd = try parseOwnerFd(raw);
    errdefer fs.closeFd(fd);
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return error.InvalidOwnerFd;
    const access: c.O = @bitCast(@as(u32, @intCast(flags)));
    if (access.ACCMODE != .RDONLY or !access.NONBLOCK) return error.InvalidOwnerFd;
    const st = native_metadata.statFd(fd) catch return error.InvalidOwnerFd;
    if (st.mode & c.S.IFMT != c.S.IFIFO) return error.InvalidOwnerFd;
    const descriptor_flags = c.fcntl(fd, c.F.GETFD);
    if (descriptor_flags < 0 or c.fcntl(fd, c.F.SETFD, descriptor_flags | c.FD_CLOEXEC) < 0)
        return error.InvalidOwnerFd;
    return fd;
}

fn parseOwnerFd(raw: []const u8) !c.fd_t {
    if (raw.len == 0 or raw.len > 10) return error.InvalidOwnerFd;
    for (raw) |byte| if (byte < '0' or byte > '9') return error.InvalidOwnerFd;
    const value = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidOwnerFd;
    // stdio cannot be a private lifecycle channel.
    if (value < 3 or value > std.math.maxInt(c.fd_t)) return error.InvalidOwnerFd;
    return @intCast(value);
}

/// No data is ever sent on this pipe. EOF/HUP/error (or unexpected input)
/// revokes the owner; EAGAIN is the only live state. Never waits for data.
fn lifetimeAlive(fd: c.fd_t) !bool {
    var descriptors = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    while (c.poll(&descriptors, 1, 0) < 0) {
        if (c._errno().* != @backingInt(c.E.INTR)) return error.TransportPollFailed;
    }
    if (descriptors[0].revents & (c.POLL.HUP | c.POLL.ERR | c.POLL.NVAL) != 0) return false;
    var byte: [1]u8 = undefined;
    while (true) {
        const n = c.read(fd, &byte, byte.len);
        if (n >= 0) return false;
        switch (fs.errno()) {
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }
    }
}

/// Ask Linux to TERM this process when its owner dies. Best effort: the owner
/// also joins workers explicitly, and the actual ppid is checked separately.
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

test "watch binds kernel peer and epoch and pushes without events RPC" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // Linux socketpair flags
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    var slots: [max_connections]?Active = @splat(null);
    defer closeSlots(host, &slots);
    var peers: [2]?unix.Connection = @splat(null);
    defer for (&peers) |*peer| if (peer.*) |*conn| conn.close();
    for (0..2) |i| {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const credentials: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        slots[i] = .{ .id = i + 1, .conn = unix.Connection.init(a, fds[0], credentials) };
        peers[i] = unix.Connection.init(a, fds[1], credentials);
    }
    var attach = try protocol.parseRequest(a, "{\"v\":4,\"id\":1,\"op\":\"attach\"}");
    defer attach.deinit();
    const attached = try host.dispatch(a, &attach, 1, false);
    defer a.free(attached);
    var request = try protocol.parseRequest(a, "{\"v\":4,\"id\":2,\"op\":\"watch\",\"epoch\":1}");
    defer request.deinit();
    // A stream on the control socket itself must not erase its identity.
    try std.testing.expectError(error.StaleControl, startWatch(host, a, io, &slots[0].?, &request, &slots));
    try std.testing.expect(slots[0].?.watch == null);
    slots[1].?.conn.peer.pid +%= 1;
    try std.testing.expectError(error.StaleControl, startWatch(host, a, io, &slots[1].?, &request, &slots));
    slots[1].?.conn.peer.pid -%= 1;
    try startWatch(host, a, io, &slots[1].?, &request, &slots);
    try std.testing.expect(watchValid(host, &slots, &slots[1].?));
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const first = (try peers[1].?.readStep()).frame;
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"stream\":\"snapshot\"") != null);
    // A real Bridge event arrives AFTER baseline freeze but before delivery.
    const bridge_host = host.bridge.host();
    try bridge_host.emit_fn(bridge_host.context, .{ .text = "live after freeze" }, &host.cancel);
    host.pump(nowMs(io));
    try advanceWatch(host, a, io, &slots[1].?);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const baseline = (try peers[1].?.readStep()).frame;
    defer a.free(baseline);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "\"stream\":\"baseline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "live after freeze") == null);
    // No inbound RPC at all: advancing the owner publishes the event.
    try advanceWatch(host, a, io, &slots[1].?);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const event = (try peers[1].?.readStep()).frame;
    defer a.free(event);
    try std.testing.expect(std.mem.indexOf(u8, event, "live after freeze") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"from\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"through\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"seq\":1") != null);
    var invalid = try protocol.parseRequest(a, "{\"v\":4,\"id\":3,\"op\":\"watch\",\"epoch\":1,\"since\":2}");
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidSequence, host.watchResume(1, try invalid.u64Field("since")));
    var resumed = try protocol.parseRequest(a, "{\"v\":4,\"id\":4,\"op\":\"watch\",\"epoch\":1,\"since\":1}");
    defer resumed.deinit();
    try startWatch(host, a, io, &slots[1].?, &resumed, &slots);
    try std.testing.expect(slots[1].?.watch.?.baseline == null);
    try std.testing.expectEqual(@as(u64, 1), slots[1].?.watch.?.cursor);
    // The resumed subscription first sends its snapshot, without a history baseline.
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const resume_snapshot = (try peers[1].?.readStep()).frame;
    defer a.free(resume_snapshot);
    var resume_doc = try std.json.parseFromSlice(std.json.Value, a, resume_snapshot, .{});
    defer resume_doc.deinit();
    try std.testing.expectEqualStrings("snapshot", resume_doc.value.object.get("stream").?.string);
    try std.testing.expectEqual(@as(i64, 4), resume_doc.value.object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 1), resume_doc.value.object.get("epoch").?.integer);
    try std.testing.expectEqual(@as(i64, 1), resume_doc.value.object.get("through").?.integer);
    try std.testing.expect(resume_doc.value.object.get("history") == null);
    try std.testing.expect(!slots[1].?.conn.writePending());
    // The bound watch socket is the only stream-side mutation: a display ACK.
    // A future watermark is refused without retiring anything.
    try peers[1].?.writeFrame("{\"v\":4,\"id\":5,\"op\":\"ack\",\"epoch\":1,\"sequence\":9}", .{ .io = io, .timeout_ms = 2_000 });
    serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const refused = (try peers[1].?.readStep()).frame;
    defer a.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "invalid_input") != null);
    try std.testing.expectEqual(@as(u64, 0), host.events.reclaimed_through);
    // The displayed watermark retires exactly through the offered page and the
    // reply is a control frame, not a display page.
    try peers[1].?.writeFrame("{\"v\":4,\"id\":6,\"op\":\"ack\",\"epoch\":1,\"sequence\":1}", .{ .io = io, .timeout_ms = 2_000 });
    serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const confirmed = (try peers[1].?.readStep()).frame;
    defer a.free(confirmed);
    try std.testing.expect(std.mem.indexOf(u8, confirmed, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, confirmed, "\"ack\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, confirmed, "\"stream\"") == null);
    try std.testing.expectEqual(@as(u64, 1), host.events.reclaimed_through);

    // A connected socket without a subscription cannot ACK: the watch path is
    // not a general RPC surface for any peer of this worker.
    {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const credentials: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        var impostor = unix.Connection.init(a, fds[1], credentials);
        defer impostor.close();
        slots[2] = .{ .id = 3, .conn = unix.Connection.init(a, fds[0], credentials) };
        try impostor.writeFrame("{\"v\":4,\"id\":7,\"op\":\"ack\",\"epoch\":1,\"sequence\":2}", .{ .io = io, .timeout_ms = 2_000 });
        serveWatchInput(host, a, io, &slots[2].?, &slots[2], &slots);
        try std.testing.expect(slots[2] == null);
        try std.testing.expectEqual(@as(u64, 1), host.events.reclaimed_through);
        try std.testing.expect(!host.cancel.isRequested());
    }
    // A different kernel peer cannot borrow the controller's binding even with
    // a plausible epoch and a byte-identical ACK.
    {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const peer: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        const other: unix.Credentials = .{ .pid = peer.pid +% 1, .uid = peer.uid, .gid = peer.gid };
        var impostor = unix.Connection.init(a, fds[1], other);
        defer impostor.close();
        slots[2] = .{ .id = 4, .conn = unix.Connection.init(a, fds[0], other) };
        slots[2].?.watch = .{ .request_id = 9, .epoch = 1, .control_id = 1, .cursor = 1, .stamp = host.watchStamp(), .baseline = null };
        try impostor.writeFrame("{\"v\":4,\"id\":8,\"op\":\"ack\",\"epoch\":1,\"sequence\":2}", .{ .io = io, .timeout_ms = 2_000 });
        serveWatchInput(host, a, io, &slots[2].?, &slots[2], &slots);
        try std.testing.expect(slots[2] == null);
        try std.testing.expectEqual(@as(u64, 1), host.events.reclaimed_through);
        try std.testing.expect(!host.cancel.isRequested());
    }
    // Revoking the control view invalidates only the subscription; nothing in
    // this path owns task cancellation or grants the stream mutation rights.
    host.disconnected(1);
    try std.testing.expect(!watchValid(host, &slots, &slots[1].?));
    // After revocation an ACK-shaped frame with a stale epoch is dropped: no
    // position is retired and the session task is untouched.
    try peers[1].?.writeFrame("{\"v\":4,\"id\":9,\"op\":\"ack\",\"epoch\":1,\"sequence\":2}", .{ .io = io, .timeout_ms = 2_000 });
    serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    try std.testing.expect(slots[1] == null);
    try std.testing.expectEqual(@as(u64, 1), host.events.reclaimed_through);
    try std.testing.expect(!host.cancel.isRequested());
}

test "owner pid rejects values outside target signed pid range without trapping" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    for ([_][]const u8{ "2147483648", "4294967295", "4294967296", "00000000000" }) |raw| {
        try env.put("THIN_WORKER_OWNER_PID", raw);
        try std.testing.expectError(error.InvalidOwnerPid, expectedOwnerPid(&env));
    }
    try env.put("THIN_WORKER_OWNER_PID", "1");
    try std.testing.expectEqual(@as(c.pid_t, 1), try expectedOwnerPid(&env));
    try env.put("THIN_WORKER_OWNER_PID", "2147483647");
    try std.testing.expectEqual(std.math.maxInt(c.pid_t), try expectedOwnerPid(&env));
}

test "owner fd rejects stdio signed nonnumeric and overflowing values" {
    for ([_][]const u8{ "", "0", "1", "2", "-7", "+3", "3x", "2147483648", "4294967296", "00000000003" }) |raw| {
        try std.testing.expectError(error.InvalidOwnerFd, parseOwnerFd(raw));
    }
    try std.testing.expectEqual(@as(c.fd_t, 3), try parseOwnerFd("3"));
    try std.testing.expectEqual(std.math.maxInt(c.fd_t), try parseOwnerFd("2147483647"));
}

test "Darwin worker rejects daemon owner before activating a session" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.UnsupportedPlatform, runInner(std.testing.allocator, std.testing.io, &env, .{
        .mode = .worker,
        .worker_owner = .daemon,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
}

test "Darwin owner pipe restores CLOEXEC and EOF ignores retained readers" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // Wakeup supplies a NONBLOCK/CLOEXEC Darwin pipe for this unit fixture;
    // production lifetime pipes remain separate from all notification pipes.
    var pipe = try Wakeup.init();
    defer pipe.deinit();
    const reader = pipe.fd;
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(reader, c.F.SETFD, @as(c_int, 0)));
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var buf: [16]u8 = undefined;
    try env.put("THIN_WORKER_OWNER_FD", try std.fmt.bufPrint(&buf, "{d}", .{reader}));
    pipe.fd = -1; // transfer into takeOwnerPipe, including its failure paths
    const owned = try takeOwnerPipe(&env);
    defer fs.closeFd(owned);
    try std.testing.expect(c.fcntl(owned, c.F.GETFD) & c.FD_CLOEXEC != 0);
    try std.testing.expect(try lifetimeAlive(owned));
    const retained = c.fcntl(owned, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    try std.testing.expect(retained >= 0);
    defer fs.closeFd(retained);
    pipe.deinit(); // close only writer, not either independently owned reader
    try std.testing.expect(!try lifetimeAlive(owned));
    try std.testing.expect(!try lifetimeAlive(retained));
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
        .worker_owner = .foreground,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
    try env.put("THIN_WORKER_OWNER_PID", "0");
    try std.testing.expectError(error.InvalidOwnerPid, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_owner = .foreground,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
    try env.put("THIN_WORKER_OWNER_PID", "-7");
    try std.testing.expectError(error.InvalidOwnerPid, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_owner = .foreground,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
}

test "watch ACK retires a full ring past its bound while the control channel stays live" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // Linux socketpair flags
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    var slots: [max_connections]?Active = @splat(null);
    defer closeSlots(host, &slots);
    var peers: [2]?unix.Connection = @splat(null);
    defer for (&peers) |*peer| if (peer.*) |*conn| conn.close();
    for (0..2) |i| {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const credentials: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        slots[i] = .{ .id = i + 1, .conn = unix.Connection.init(a, fds[0], credentials) };
        peers[i] = unix.Connection.init(a, fds[1], credentials);
    }
    const parent_pid: std.os.linux.pid_t = @intCast(std.os.linux.getpid());
    var attach = try protocol.parseRequest(a, "{\"v\":4,\"id\":1,\"op\":\"attach\"}");
    defer attach.deinit();
    const attached = try host.dispatch(a, &attach, 1, false);
    defer a.free(attached);
    var watch = try protocol.parseRequest(a, "{\"v\":4,\"id\":2,\"op\":\"watch\",\"epoch\":1}");
    defer watch.deinit();
    try startWatch(host, a, io, &slots[1].?, &watch, &slots);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const snapshot = (try peers[1].?.readStep()).frame;
    defer a.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"stream\":\"snapshot\"") != null);
    try advanceWatch(host, a, io, &slots[1].?);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const baseline = (try peers[1].?.readStep()).frame;
    defer a.free(baseline);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "\"stream\":\"baseline\"") != null);

    // Phase 1: no ACK at all. The ring fills and the producer stops; the held
    // event plus the ring retain more than the 1024-entry bound without loss.
    const bridge_host = host.bridge.host();
    var produced: usize = 0;
    while (produced < 4096) {
        host.pump(0);
        if (host.pending_event != null and host.events.items.items.len >= host.events.max_count) break;
        try bridge_host.emit_fn(bridge_host.context, .{ .text = "s" }, &host.cancel);
        produced += 1;
    }
    host.pump(0);
    try std.testing.expect(produced > host.events.max_count);
    try std.testing.expect(produced < 4096);
    try std.testing.expectEqual(host.events.max_count, host.events.items.items.len);
    try std.testing.expect(host.pending_event != null);
    try std.testing.expectEqual(@as(u64, 0), host.events.reclaimed_through);
    // Saturation of the display path does not gate this control connection.
    try peers[0].?.writeFrame("{\"v\":4,\"id\":9,\"op\":\"ping\"}", .{ .io = io, .timeout_ms = 2_000 });
    serveOne(host, a, io, &slots[0].?, parent_pid, &slots[0], &slots);
    try std.testing.expect(try slots[0].?.conn.writeStep());
    const pong = (try peers[0].?.readStep()).frame;
    defer a.free(pong);
    try std.testing.expect(std.mem.indexOf(u8, pong, "\"ok\":true") != null);

    // Phase 2: every page is acknowledged on the bound watch socket; the ring
    // is reclaimed and production completes with no missing position.
    var delivered: usize = 0;
    var acked: u64 = 0;
    var rounds: usize = 0;
    while (delivered < produced and rounds < 400_000) : (rounds += 1) {
        host.pump(0);
        if (!slots[1].?.conn.writePending()) try advanceWatch(host, a, io, &slots[1].?);
        _ = try slots[1].?.conn.writeStep();
        while (true) {
            const step = try peers[1].?.readStep();
            const frame = switch (step) {
                .pending => break,
                .eof => return error.TestUnexpectedResult,
                .frame => |bytes| bytes,
            };
            defer a.free(frame);
            var document = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
            defer document.deinit();
            const object = switch (document.value) {
                .object => |value| value,
                else => return error.TestUnexpectedResult,
            };
            if (object.get("ack")) |value| {
                try std.testing.expect(value.bool);
                continue;
            }
            const stream_kind = switch (object.get("stream") orelse return error.TestUnexpectedResult) {
                .string => |value| value,
                else => return error.TestUnexpectedResult,
            };
            if (!std.mem.eql(u8, stream_kind, "events")) continue;
            const entries = switch (object.get("events") orelse return error.TestUnexpectedResult) {
                .array => |value| value,
                else => return error.TestUnexpectedResult,
            };
            delivered += entries.items.len;
            const through = switch (object.get("through") orelse return error.TestUnexpectedResult) {
                .integer => |value| @as(u64, @intCast(value)),
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expect(through > acked);
            acked = through;
            var buffer: [160]u8 = undefined;
            const ack = try std.fmt.bufPrint(&buffer, "{{\"v\":{d},\"id\":7,\"op\":\"ack\",\"epoch\":1,\"sequence\":{d}}}", .{ protocol.version, through });
            try peers[1].?.writeFrame(ack, .{ .io = io, .timeout_ms = 2_000 });
        }
        serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    }
    try std.testing.expectEqual(produced, delivered);
    try std.testing.expect(delivered > host.events.max_count);
    try std.testing.expectEqual(acked, host.events.reclaimed_through);
    try std.testing.expect(host.pending_event == null);
    try std.testing.expectEqual(@as(usize, 0), host.events.items.items.len);
    // Reversible pause: one more ordinary event is admitted after reclamation.
    try bridge_host.emit_fn(bridge_host.context, .{ .text = "resumed" }, &host.cancel);
    host.pump(0);
    try std.testing.expectEqual(@as(usize, 1), host.events.items.items.len);
}

test "a held CR cannot block selectively acknowledged metadata before its LF" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // Linux socketpair flags
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    var slots: [max_connections]?Active = @splat(null);
    defer closeSlots(host, &slots);
    var peers: [2]?unix.Connection = @splat(null);
    defer for (&peers) |*peer| if (peer.*) |*conn| conn.close();
    for (0..2) |i| {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const credentials: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        slots[i] = .{ .id = i + 1, .conn = unix.Connection.init(a, fds[0], credentials) };
        peers[i] = unix.Connection.init(a, fds[1], credentials);
    }
    var attach = try protocol.parseRequest(a, "{\"v\":4,\"id\":1,\"op\":\"attach\"}");
    defer attach.deinit();
    const attached = try host.dispatch(a, &attach, 1, false);
    defer a.free(attached);
    var watch = try protocol.parseRequest(a, "{\"v\":4,\"id\":2,\"op\":\"watch\",\"epoch\":1}");
    defer watch.deinit();
    try startWatch(host, a, io, &slots[1].?, &watch, &slots);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const snapshot = (try peers[1].?.readStep()).frame;
    defer a.free(snapshot);
    try advanceWatch(host, a, io, &slots[1].?);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const baseline = (try peers[1].?.readStep()).frame;
    defer a.free(baseline);

    // seq1 is text ending in a held CR: it can never be proven until the LF
    // arrives. Metadata follows and must remain independently ackable.
    const metadata: usize = 1080;
    const planned: usize = metadata + 2;
    const bridge_host = host.bridge.host();
    var produced: usize = 0;
    var delivered: usize = 0;
    var cursor: u64 = 0;
    var highest: u64 = 0;
    var got_cr = false;
    var got_lf = false;
    var rounds: usize = 0;
    while (delivered < planned and rounds < 2_000_000) : (rounds += 1) {
        host.pump(0);
        if (produced < planned and host.pending_event == null) {
            if (produced == 0) {
                try bridge_host.emit_fn(bridge_host.context, .{ .text = "x\r" }, &host.cancel);
            } else if (produced == planned - 1) {
                try bridge_host.emit_fn(bridge_host.context, .{ .text = "\n" }, &host.cancel);
            } else {
                try bridge_host.emit_fn(bridge_host.context, .{ .state = .calling_model }, &host.cancel);
            }
            produced += 1;
        }
        if (!slots[1].?.conn.writePending()) try advanceWatch(host, a, io, &slots[1].?);
        _ = try slots[1].?.conn.writeStep();
        while (true) {
            const step = try peers[1].?.readStep();
            const frame = switch (step) {
                .pending => break,
                .eof => return error.TestUnexpectedResult,
                .frame => |bytes| bytes,
            };
            defer a.free(frame);
            var document = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
            defer document.deinit();
            const object = switch (document.value) {
                .object => |value| value,
                else => return error.TestUnexpectedResult,
            };
            if (object.get("ack")) |value| {
                try std.testing.expect(value.bool);
                continue;
            }
            const stream_kind = switch (object.get("stream") orelse return error.TestUnexpectedResult) {
                .string => |value| value,
                else => return error.TestUnexpectedResult,
            };
            if (!std.mem.eql(u8, stream_kind, "events")) continue;
            const entries = switch (object.get("events") orelse return error.TestUnexpectedResult) {
                .array => |value| value,
                else => return error.TestUnexpectedResult,
            };
            for (entries.items) |entry| {
                const event = switch (entry) {
                    .object => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                const kind = switch (event.get("t") orelse return error.TestUnexpectedResult) {
                    .string => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                if (std.mem.eql(u8, kind, "text")) {
                    const text = switch (event.get("v") orelse return error.TestUnexpectedResult) {
                        .string => |value| value,
                        else => return error.TestUnexpectedResult,
                    };
                    if (std.mem.eql(u8, text, "x\r")) got_cr = true;
                    if (std.mem.eql(u8, text, "\n")) got_lf = true;
                }
            }
            delivered += entries.items.len;
            const through = switch (object.get("through") orelse return error.TestUnexpectedResult) {
                .integer => |value| @as(u64, @intCast(value)),
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expect(through > cursor);
            // The CR position (1) is never part of a proven range.
            const first = @max(cursor + 1, 2);
            cursor = through;
            if (first > through) continue;
            highest = through;
            var buffer: [192]u8 = undefined;
            const ack = try std.fmt.bufPrint(&buffer, "{{\"v\":{d},\"id\":8,\"op\":\"ack\",\"epoch\":1,\"sequence\":{d},\"first\":{d}}}", .{ protocol.version, through, first });
            try peers[1].?.writeFrame(ack, .{ .io = io, .timeout_ms = 2_000 });
        }
        serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    }
    try std.testing.expectEqual(planned, produced);
    try std.testing.expectEqual(planned, delivered);
    try std.testing.expect(got_cr and got_lf);
    // Metadata was retired selectively; the unproven CR keeps the exact-recovery
    // cursor at zero instead of fabricating its proof.
    try std.testing.expectEqual(@as(u64, 0), host.events.reclaimed_through);
    try std.testing.expectEqual(highest, host.events.highest_acknowledged);
    try std.testing.expectEqual(@as(usize, 1), host.events.items.items.len);
    try std.testing.expectEqual(@as(u64, 1), host.events.items.items[0].seq);
    // Once the CR text is really proven as a prefix, everything retires.
    const all = try std.fmt.allocPrint(a, "{{\"v\":4,\"id\":9,\"op\":\"ack\",\"epoch\":1,\"sequence\":{d}}}", .{highest});
    defer a.free(all);
    try peers[1].?.writeFrame(all, .{ .io = io, .timeout_ms = 2_000 });
    serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    try std.testing.expectEqual(highest, host.events.reclaimed_through);
    try std.testing.expectEqual(@as(usize, 0), host.events.items.items.len);
}
