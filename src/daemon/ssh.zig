//! D entry ownership: daemon accepts only raw sockets; the existing process
//! executor hands one to a child as stdin and owns its exec handshake/group.
//! No SSH session exists in this parent. Connection loss never owns a Runtime.
const std = @import("std");
const process = @import("../platform/process.zig");
const p = @import("../core/protocol.zig");
extern "c" fn thin_ssh_listen([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn thin_ssh_accept(c_int) c_int;
extern "c" fn thin_ssh_init(c_int, [*:0]const u8, c_int) c_int;
extern "c" fn thin_ssh_finish(c_int) c_int;
extern "c" fn thin_ssh_close() void;

pub fn initializeConnection(a: std.mem.Allocator, environ: *const std.process.Environ.Map, owner: u32) !void {
    const home = try a.dupeSentinel(u8, environ.get("HOME") orelse return error.MissingHome, 0);
    defer a.free(home);
    if (thin_ssh_init(0, home, @intCast(owner)) != 0) return error.SshConnectionRejected;
    errdefer thin_ssh_close();
    // Dedicated parent readiness pipe, not the SSH channel. No UI/backend is
    // created until signature+PTY+shell have all succeeded.
    if (std.c.write(1, "R", 1) != 1) return error.SshReadyFailed;
}
pub fn finish(code: u8) !void {
    if (thin_ssh_finish(code) != 0) return error.SshFinishFailed;
}
pub fn close() void {
    thin_ssh_close();
}

const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    fd: std.atomic.Value(c_int),
    script: []u8,
    started_ms: i64,
    cancel: p.Cancellation = .{},
    ready: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failed: bool = false,
    future: ?std.Io.Future(void) = null,

    fn releaseSocket(self: *Connection) void {
        const fd = self.fd.swap(-1, .acq_rel);
        if (fd >= 0) _ = std.c.close(fd);
    }
    fn launched(context: *anyopaque, _: process.LaunchNotice) void {
        const self: *Connection = @ptrCast(@alignCast(context));
        // startWithInput has duplicated the borrowed fd before exec. Parent
        // drops its original immediately on exec success/failure notification.
        self.releaseSocket();
    }
    fn readyBytes(context: *anyopaque, bytes: []const u8) !void {
        const self: *Connection = @ptrCast(@alignCast(context));
        if (bytes.len != 1 or bytes[0] != 'R' or self.ready.swap(true, .acq_rel)) return error.InvalidSshReady;
    }
    fn run(self: *Connection) void {
        defer self.done.store(true, .release);
        defer self.releaseSocket();
        // Match the connect launcher's HOME root in the initial TUI header too.
        const cwd = self.environ.get("HOME") orelse "/";
        const result = process.run(self.allocator, self.io, cwd, self.script, self.environ, .{
            .timeout_ms = null,
            .output_bytes = 2048,
            .stdin_file = .{ .handle = self.fd.load(.acquire), .flags = .{ .nonblocking = true } },
            .on_launch = .{ .context = self, .notify_fn = launched },
            .stdout_sink = .{ .context = self, .write_fn = readyBytes },
            .term_grace_ms = 500,
            .cleanup_timeout_ms = 5000,
        }, &self.cancel) catch {
            // process.run returns an error only before a child exists or AFTER
            // cleanup was confirmed. Uncertain ownership is returned separately
            // as Result.cleanup_failed, even if formatting/output also failed.
            // Refuse just this connection; do not cancel unrelated sessions.
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        self.failed = result.cleanup_failed;
    }
};

pub const Listener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    fd: c_int,
    script: []u8,
    connections: std.ArrayList(*Connection) = .empty,
    poisoned: bool = false,
    // Resource protection for untrusted handshakes, not an authenticated
    // connection quota. Once ready, a connection no longer occupies this pool.
    const max_pending = 32;
    const ready_timeout_ms = 15000;

    pub fn init(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, address: []const u8, refresh: bool) !Listener {
        const listen = try a.dupeSentinel(u8, address, 0);
        defer a.free(listen);
        const home = try a.dupeSentinel(u8, env.get("HOME") orelse return error.MissingHome, 0);
        defer a.free(home);
        const fd = thin_ssh_listen(listen, home);
        if (fd < 0) return error.SshListenerInitializationFailed;
        errdefer _ = std.c.close(fd);
        const pid = std.os.linux.getpid();
        const script = try std.fmt.allocPrint(a, "exec '/proc/{d}/exe' --internal-ssh {d}{s}", .{
            pid, pid, if (refresh) @as([]const u8, "") else " --no-model-auto-refresh",
        });
        return .{ .allocator = a, .io = io, .environ = env, .fd = fd, .script = script };
    }

    pub fn tick(self: *Listener) !void {
        var i: usize = 0;
        var pending: usize = 0;
        const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
        while (i < self.connections.items.len) {
            const conn = self.connections.items[i];
            if (conn.done.load(.acquire)) {
                conn.future.?.await(self.io);
                self.poisoned = self.poisoned or conn.failed;
                self.destroy(conn);
                _ = self.connections.swapRemove(i);
                continue;
            }
            if (!conn.ready.load(.acquire)) {
                pending += 1;
                if (now - conn.started_ms >= ready_timeout_ms) conn.cancel.cancel();
            }
            i += 1;
        }
        if (self.poisoned) return error.CleanupFailed;
        if (pending >= max_pending or self.fd < 0) return;
        // One accept per tick preserves fairness with the existing control plane.
        const fd = thin_ssh_accept(self.fd);
        if (fd == -2) return;
        if (fd < 0) return error.SshAcceptFailed;
        self.admit(fd, now);
    }

    // Before the concurrent job starts, rejection owns only this accepted fd.
    // Local resource shortage is not evidence of a runaway child.
    fn admit(self: *Listener, fd: c_int, now: i64) void {
        var transferred = false;
        defer if (!transferred) {
            _ = std.c.close(fd);
        };
        self.connections.ensureUnusedCapacity(self.allocator, 1) catch return;
        const conn = self.allocator.create(Connection) catch return;
        conn.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .fd = .init(fd),
            .script = self.script,
            .started_ms = now,
        };
        conn.future = std.Io.concurrent(self.io, Connection.run, .{conn}) catch {
            self.allocator.destroy(conn);
            return;
        };
        transferred = true;
        self.connections.appendAssumeCapacity(conn);
    }

    fn destroy(self: *Listener, conn: *Connection) void {
        conn.releaseSocket();
        self.allocator.destroy(conn);
    }
    pub fn stop(self: *Listener) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
        // Notify ALL before joining ANY; each uses the proven owned group cleanup.
        for (self.connections.items) |conn| conn.cancel.cancel();
    }
    pub fn shutdown(self: *Listener) !void {
        self.stop();
        for (self.connections.items) |conn| {
            conn.future.?.await(self.io);
            self.poisoned = self.poisoned or conn.failed;
            self.destroy(conn);
        }
        self.connections.clearRetainingCapacity();
        if (self.poisoned) return error.CleanupFailed;
    }
    pub fn deinit(self: *Listener) void {
        self.shutdown() catch {};
        self.connections.deinit(self.allocator);
        self.allocator.free(self.script);
    }
};

test "clean connection output failure does not poison session ownership" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const script = try a.dupe(u8, "printf invalid");
    defer a.free(script);
    const fd = std.c.open("/dev/null", .{ .CLOEXEC = true });
    try std.testing.expect(fd >= 0);
    var conn: Connection = .{
        .allocator = a,
        .io = std.testing.io,
        .environ = &env,
        .fd = .init(fd),
        .script = script,
        .started_ms = 0,
    };
    defer conn.releaseSocket();
    conn.run();
    try std.testing.expect(conn.done.load(.acquire));
    try std.testing.expect(!conn.ready.load(.acquire));
    try std.testing.expect(!conn.failed);
    try std.testing.expectEqual(@as(c_int, -1), conn.fd.load(.acquire));
}

test "failed connection admission closes its socket without poisoning listener" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // The first allocation reserves the list; the second allocates the job.
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var listener: Listener = .{
            .allocator = failing.allocator(),
            .io = std.testing.io,
            .environ = &env,
            .fd = -1,
            .script = &.{},
        };
        defer listener.connections.deinit(failing.allocator());
        const fd = std.c.open("/dev/null", .{ .CLOEXEC = true });
        try std.testing.expect(fd >= 0);
        listener.admit(fd, 0);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), listener.connections.items.len);
        try std.testing.expect(!listener.poisoned);
        try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(fd, std.c.F.GETFD));
    }
}
