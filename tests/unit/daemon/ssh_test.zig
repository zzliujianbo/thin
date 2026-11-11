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
