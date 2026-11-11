test "Darwin anonymous input streams beyond pipe capacity with protected descriptors" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    var input = try Input.init(bytes);
    defer input.deinit(io);
    for ([_]c.fd_t{ input.fd, input.write_fd }) |fd| {
        try std.testing.expect(fd > 2);
        try std.testing.expect(c.fcntl(fd, c.F.GETFD) & c.FD_CLOEXEC != 0);
    }
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    try std.testing.expect(c.fcntl(input.fd, c.F.GETFL) & nonblock == 0);
    try std.testing.expect(c.fcntl(input.write_fd, c.F.GETFL) & nonblock != 0);
    try std.testing.expectEqual(@as(c_int, 1), c.fcntl(input.write_fd, c.F.GETNOSIGPIPE));
    var cancel: protocol.Cancellation = .{};
    try input.start(io, &cancel, 2000);
    // Native blocking consumer runs concurrently with the producer, as curl
    // does. Producer error/deadline closes its end, so this also terminates.
    var buffer: [8192]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = c.read(input.fd, &buffer, buffer.len);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.TestReadFailed;
        }
        if (n == 0) break;
        const count: usize = @intCast(n);
        try std.testing.expect(total + count <= bytes.len);
        try std.testing.expectEqualSlices(u8, bytes[total..][0..count], buffer[0..count]);
        total += count;
    }
    try std.testing.expectEqual(bytes.len, total);
    try std.testing.expectEqual(@as(?WriteError, null), input.finish(io));
    try std.testing.expectEqual(@as(c.fd_t, -1), input.fd);
    try std.testing.expectEqual(@as(c.fd_t, -1), input.write_fd);
    try std.testing.expect(!cancel.isRequested());
}
test "Darwin stalled input is bounded and parent cancellation is not mutated" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    var input = try Input.init(bytes);
    defer input.deinit(io);
    var parent: protocol.Cancellation = .{};
    try input.start(io, &parent, 10);
    if (input.future) |*future| try std.testing.expectError(error.Timeout, future.await(io));
    try std.testing.expect(input.cancellation.isRequested());
    try std.testing.expect(!parent.isRequested());
    try std.testing.expectEqual(@as(?WriteError, error.Timeout), input.finish(io));

    var stopped = try Input.init(bytes);
    defer stopped.deinit(io);
    try stopped.start(io, &parent, 2000);
    // No consumer: an input larger than pipe capacity cannot have completed.
    try std.testing.expectEqual(@as(?WriteError, error.Canceled), stopped.finish(io));
    try std.testing.expect(!parent.isRequested());

    var canceled = try Input.init(bytes);
    defer canceled.deinit(io);
    parent.cancel();
    try canceled.start(io, &parent, 2000);
    try std.testing.expectEqual(@as(?WriteError, error.Canceled), canceled.finish(io));
}
test "Darwin closed anonymous input peer is a producer failure not SIGPIPE" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var input = try Input.init("secret");
    defer input.deinit(io);
    _ = c.close(input.fd);
    input.fd = -1;
    var parent: protocol.Cancellation = .{};
    try input.start(io, &parent, 2000);
    if (input.future) |*future| try std.testing.expectError(error.AnonymousInputFailed, future.await(io));
    try std.testing.expectEqual(@as(?WriteError, error.AnonymousInputFailed), input.finish(io));
    try std.testing.expect(!parent.isRequested());
}
