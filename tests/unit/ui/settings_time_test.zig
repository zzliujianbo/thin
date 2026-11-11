test "seconds formatter roundtrips every fractional millisecond and boundaries" {
    for ([_]u32{ 0, 1000, 86399000, 4294966000 }) |base| {
        for (0..1000) |fraction| {
            const ms = base + @as(u32, @intCast(fraction));
            var buffer: [32]u8 = undefined;
            const rendered = try format(&buffer, ms);
            try std.testing.expectEqual(ms, try parse(rendered[0 .. rendered.len - 2]));
        }
    }
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, format(&tiny, 1));
    try std.testing.expect(validPrefix(""));
    try std.testing.expect(validPrefix("0."));
    try std.testing.expect(!validPrefix("0.0000"));
}
test "seconds format and parse preserve every millisecond without rounding" {
    const Case = struct { ms: u32, seconds: []const u8 };
    for ([_]Case{
        .{ .ms = 300000, .seconds = "300" },
        .{ .ms = 123456, .seconds = "123.456" },
        .{ .ms = 1, .seconds = "0.001" },
        .{ .ms = 1500, .seconds = "1.5" },
        .{ .ms = 10, .seconds = "0.01" },
        .{ .ms = 1010, .seconds = "1.01" },
        .{ .ms = 4294967295, .seconds = "4294967.295" },
    }) |case| {
        var buffer: [32]u8 = undefined;
        const rendered = try format(&buffer, case.ms);
        try std.testing.expectEqualStrings(case.seconds, rendered[0 .. rendered.len - 2]);
        try std.testing.expect(std.mem.endsWith(u8, rendered, " s"));
        try std.testing.expectEqual(case.ms, try parse(case.seconds));
    }
    for ([_][]const u8{ "", ".1", "1.", "1.0001", "1..2", "1x", "-1", "4294967.296", "4294968", "4294967296", "1e2", " 1", "1\n" }) |bad| {
        try std.testing.expectError(error.InvalidValue, parse(bad));
    }
}
