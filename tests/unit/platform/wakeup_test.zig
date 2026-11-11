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
