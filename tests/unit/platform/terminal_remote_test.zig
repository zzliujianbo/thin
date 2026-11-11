test "macOS remote terminal is unavailable without C SSH symbols or side effects" {
    if (comptime enabled) return error.SkipZigTest;
    try std.testing.expect(!active());
    var bytes: [8]u8 = @splat(42);
    try std.testing.expectEqual(@as(isize, -1), read(&bytes, bytes.len));
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(42)), &bytes);
    try std.testing.expectEqual(@as(isize, -1), write(&bytes, bytes.len));
    try std.testing.expectEqual(@as(c_int, -1), wait(0, 0));
    try std.testing.expectEqual(@as(c_int, -1), notificationFd(-1));
    var columns: c_uint = 80;
    var rows: c_uint = 24;
    size(&columns, &rows);
    try std.testing.expectEqual(@as(c_uint, 0), columns);
    try std.testing.expectEqual(@as(c_uint, 0), rows);
}
