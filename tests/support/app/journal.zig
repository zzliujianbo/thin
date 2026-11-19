fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
}

fn expectWriterWaiting(journal: *Journal) !void {
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (@atomicLoad(std.Io.Event, &journal.wake, .acquire) != .waiting) {
        try std.testing.expectEqual(null, journal.failure());
        try std.testing.expect(start.untilNow(std.testing.io, .awake).toMilliseconds() < 1000);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
}

fn canceledWriterWait(_: ?*anyopaque, _: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
    return error.Canceled;
}
