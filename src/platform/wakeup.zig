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

test "wakeup coalesces notifications and draining restores quiet readiness" {
    var wake = try Wakeup.init();
    defer wake.deinit();
    var descriptors = [_]std.c.pollfd{.{ .fd = wake.fd, .events = std.c.POLL.IN }};
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&descriptors, 1, 0));
    for (0..1000) |_| wake.notify();
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&descriptors, 1, 0));
    wake.drain();
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&descriptors, 1, 0));
    wake.drain(); // Empty drain is nonblocking too.
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&descriptors, 1, 0));
    Wakeup.callback(@ptrCast(&wake));
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&descriptors, 1, 0));
}

test "wakeup descriptors are nonblocking and close-on-exec" {
    var wake = try Wakeup.init();
    defer wake.deinit();
    for ([_]std.c.fd_t{ wake.fd, wake.write_fd }) |fd| {
        if (fd < 0) continue; // Linux owns only the eventfd.
        const descriptor_flags = std.c.fcntl(fd, std.c.F.GETFD);
        try std.testing.expect(descriptor_flags >= 0);
        try std.testing.expect(descriptor_flags & std.c.FD_CLOEXEC != 0);
        const status_flags = std.c.fcntl(fd, std.c.F.GETFL);
        try std.testing.expect(status_flags >= 0);
        try std.testing.expect(status_flags & @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })) != 0);
    }
}

test "wakeup deinit owns both pipe ends and is repeatable" {
    var wake = try Wakeup.init();
    defer wake.deinit();
    const fds = [_]std.c.fd_t{ wake.fd, wake.write_fd };
    if (builtin.os.tag == .macos) {
        try std.testing.expect(fds[1] >= 0 and fds[0] != fds[1]);
    } else {
        try std.testing.expectEqual(@as(std.c.fd_t, -1), fds[1]);
    }
    wake.deinit();
    try std.testing.expectEqual(@as(std.c.fd_t, -1), wake.fd);
    try std.testing.expectEqual(@as(std.c.fd_t, -1), wake.write_fd);
    for (fds) |fd| {
        if (fd < 0) continue;
        try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(fd, std.c.F.GETFD));
        try std.testing.expectEqual(@as(c_int, @backingInt(std.c.E.BADF)), std.c._errno().*);
    }
    // A new wakeup may reuse the old fd numbers; repeated cleanup must not
    // close its descriptors.
    var next = try Wakeup.init();
    defer next.deinit();
    wake.deinit();
    for ([_]std.c.fd_t{ next.fd, next.write_fd }) |fd| {
        if (fd >= 0) try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) >= 0);
    }
    next.notify();
    var descriptors = [_]std.c.pollfd{.{ .fd = next.fd, .events = std.c.POLL.IN }};
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&descriptors, 1, 0));
}

test "macos saturated wakeup never waits and bounded drains restore quiet" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var wake = try Wakeup.init();
    defer wake.deinit();
    var bytes: [4096]u8 = undefined;
    @memset(&bytes, 1);
    var saturated = false;
    // Fill efficiently, with a finite guard so a regression cannot loop forever.
    for (0..1024) |_| {
        const rc = std.c.write(wake.write_fd, &bytes, bytes.len);
        if (rc < 0) {
            try std.testing.expectEqual(@as(c_int, @backingInt(std.c.E.AGAIN)), std.c._errno().*);
            saturated = true;
            break;
        }
        try std.testing.expect(rc > 0);
    }
    try std.testing.expect(saturated);
    // A failed 4096-byte atomic write may leave room for single-byte writes.
    // Fill that tail too, proving that notify sees EAGAIN rather than blocking.
    var tail_full = false;
    const byte: u8 = 1;
    for (0..4096) |_| {
        if (std.c.write(wake.write_fd, @ptrCast(&byte), 1) < 0) {
            try std.testing.expectEqual(@as(c_int, @backingInt(std.c.E.AGAIN)), std.c._errno().*);
            tail_full = true;
            break;
        }
    }
    try std.testing.expect(tail_full);
    for (0..1000) |_| wake.notify();
    var descriptors = [_]std.c.pollfd{.{ .fd = wake.fd, .events = std.c.POLL.IN }};
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&descriptors, 1, 0));
    for (0..128) |_| {
        wake.drain();
        if (std.c.poll(&descriptors, 1, 0) == 0) break;
    }
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&descriptors, 1, 0));
    wake.drain();
    wake.notify();
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&descriptors, 1, 0));
    wake.drain();
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&descriptors, 1, 0));
}
