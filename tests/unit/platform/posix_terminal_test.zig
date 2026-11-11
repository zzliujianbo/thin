test "file flag comparison retains nonblocking append and access configuration" {
    const flags: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .RDWR, .NONBLOCK = true, .APPEND = true })));
    try std.testing.expectEqual(flags, configuredFileFlags(flags));
    if (comptime darwin) try std.testing.expectEqual(flags, configuredFileFlags(flags | 0x00010000));
}
test "terminal winsize uses the supported POSIX libc layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(std.c.winsize));
    try std.testing.expectEqual(@as(usize, 2), @alignOf(std.c.winsize));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(std.c.winsize, "row"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(std.c.winsize, "col"));
}
