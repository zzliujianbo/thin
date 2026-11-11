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
