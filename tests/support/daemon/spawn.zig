const testing = std.testing;

// Real direct child, deliberately independent of model/API/worker executable.
// Only async-signal-safe libc calls occur between fork and exec.
const SlowOwnedChild = struct {
    extern "c" fn dup2(c_int, c_int) c_int;
    extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;

    pid: ?c.pid_t,
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    worker: *Worker,
    io: std.Io,
    status: c_int = -1,
    wait_error: bool = false,

    fn lock(self: *@This()) void {
        std.debug.assert(c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }

    fn unlock(self: *@This()) void {
        std.debug.assert(c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }

    fn reap(self: *@This()) void {
        while (true) {
            self.lock();
            const pid = self.pid orelse {
                self.unlock();
                return;
            };
            var status: c_int = 0;
            const result = c.waitpid(pid, &status, c.W.NOHANG);
            if (result == pid) {
                self.pid = null;
                self.status = status;
                self.worker.publish(.{ .term = if (status & 0x7f == 0) .{ .exited = @intCast((status >> 8) & 0xff) } else .{ .unknown = @intCast(status) } });
                self.unlock();
                return;
            }
            if (result < 0 and c.errno(result) != .INTR) {
                self.wait_error = true;
                self.pid = null;
                self.worker.publish(.{ .exit_error = error.TestWaitFailed });
                self.unlock();
                return;
            }
            self.unlock();
            std.Io.sleep(self.io, .fromMilliseconds(5), .awake) catch {};
        }
    }

    // Reap and signal ownership share a mutex: a cached PID/PGID can never be
    // signalled after waitpid has released it for reuse.
    fn signal(self: *@This(), signum: c.SIG) !void {
        self.lock();
        defer self.unlock();
        const pid = self.pid orelse return error.TestChildAlreadyReaped;
        if (c.kill(pid, signum) != 0) return error.TestSignalFailed;
    }

    fn killOwned(self: *@This()) void {
        self.lock();
        defer self.unlock();
        if (self.pid) |pid| {
            _ = c.kill(-pid, .KILL);
            _ = c.kill(pid, .KILL);
        }
    }

    fn marker(fd: c.fd_t, expected: u8, timeout_ms: c_int) !void {
        var descriptors = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&descriptors, 1, timeout_ms) != 1) return error.TestMarkerTimeout;
        var byte: [1]u8 = undefined;
        if (c.read(fd, &byte, 1) != 1 or byte[0] != expected) return error.TestUnexpectedMarker;
    }
};
