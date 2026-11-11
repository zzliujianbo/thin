//! Coalescing notification, never the source of queue truth.
//! The owner must join all producers before closing these descriptors.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Wakeup = struct {
    fd: std.c.fd_t,
    write_fd: std.c.fd_t = -1,

    pub fn init() !Wakeup {
        if (builtin.os.tag == .linux) {
            const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(rc) != .SUCCESS) return error.WakeupUnavailable;
            return .{ .fd = @intCast(rc) };
        }
        if (builtin.os.tag != .macos) @compileError("unsupported wakeup platform");

        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) < 0) return error.WakeupUnavailable;
        errdefer {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        }
        // pipe + fcntl is NOT atomic against concurrent spawn. Future Darwin
        // spawn must use CLOEXEC_DEFAULT / an explicit fd whitelist; this does
        // not provide pipe2's atomic CLOEXEC guarantee.
        for (fds) |fd| {
            if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0)
                return error.WakeupUnavailable;
            const flags = std.c.fcntl(fd, std.c.F.GETFL);
            if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) < 0)
                return error.WakeupUnavailable;
        }
        return .{ .fd = fds[0], .write_fd = fds[1] };
    }

    /// EAGAIN means an unread notification already exists; never wait for space.
    pub fn notify(self: *const Wakeup) void {
        const value: u64 = 1;
        const byte: u8 = 1;
        const fd = if (builtin.os.tag == .linux) self.fd else self.write_fd;
        const data: [*]const u8 = if (builtin.os.tag == .linux) @ptrCast(&value) else @ptrCast(&byte);
        const size: usize = if (builtin.os.tag == .linux) @sizeOf(u64) else 1;
        while (std.c.write(fd, data, size) < 0) {
            if (std.c._errno().* != @backingInt(std.c.E.INTR)) return;
        }
    }

    pub fn callback(raw: *anyopaque) void {
        const self: *const Wakeup = @ptrCast(@alignCast(raw));
        self.notify();
    }

    /// Drain before checking the real work queue, then poll. A bounded pipe
    /// drain may leave readable bytes under load: the owner MUST recheck the
    /// queue even then. Never let continuous producers monopolize the owner.
    pub fn drain(self: *const Wakeup) void {
        if (builtin.os.tag == .linux) {
            // One eventfd read consumes all coalesced notifications.
            var value: u64 = undefined;
            while (std.c.read(self.fd, @ptrCast(&value), @sizeOf(u64)) < 0) {
                if (std.c._errno().* != @backingInt(std.c.E.INTR)) return;
            }
        } else {
            var bytes: [4096]u8 = undefined;
            // Bound syscall attempts too, including EINTR retries.
            for (0..16) |_| {
                const rc = std.c.read(self.fd, &bytes, bytes.len);
                if (rc == 0) return;
                if (rc < 0 and std.c._errno().* != @backingInt(std.c.E.INTR)) return;
            }
        }
    }

    pub fn deinit(self: *Wakeup) void {
        if (self.write_fd >= 0 and self.write_fd != self.fd) _ = std.c.close(self.write_fd);
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
        self.write_fd = -1;
    }
};
