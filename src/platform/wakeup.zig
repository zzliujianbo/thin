//! Linux coalescing notification, never the source of queue truth.
//! The owner must join all producers before closing this descriptor.
const std = @import("std");
const linux = std.os.linux;

pub const Wakeup = struct {
    fd: std.c.fd_t,

    pub fn init() !Wakeup {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.WakeupUnavailable;
        return .{ .fd = @intCast(rc) };
    }

    /// EAGAIN means an unread notification already exists; never wait for space.
    pub fn notify(self: *const Wakeup) void {
        const value: u64 = 1;
        while (std.c.write(self.fd, @ptrCast(&value), @sizeOf(u64)) < 0) {
            if (std.c._errno().* != @backingInt(linux.E.INTR)) return;
        }
    }

    pub fn callback(raw: *anyopaque) void {
        const self: *const Wakeup = @ptrCast(@alignCast(raw));
        self.notify();
    }

    /// One eventfd read consumes all coalesced notifications. Drain before
    /// checking the work queue, then poll; producers racing either step wake it.
    pub fn drain(self: *const Wakeup) void {
        var value: u64 = undefined;
        while (std.c.read(self.fd, @ptrCast(&value), @sizeOf(u64)) < 0) {
            if (std.c._errno().* != @backingInt(linux.E.INTR)) return;
        }
    }

    pub fn deinit(self: *Wakeup) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }
};

test "wakeup coalesces notifications and draining restores quiet readiness" {
    var wake = try Wakeup.init();
    defer wake.deinit();
    var descriptors = [_]std.c.pollfd{.{ .fd = wake.fd, .events = linux.POLL.IN }};
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&descriptors, 1, 0));
    for (0..1000) |_| wake.notify();
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&descriptors, 1, 0));
    wake.drain();
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&descriptors, 1, 0));
    wake.drain(); // Empty drain is nonblocking too.
    wake.notify();
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&descriptors, 1, 0));
}
