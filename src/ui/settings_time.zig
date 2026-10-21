//! Exact UI-only seconds conversion; settings and transport remain milliseconds.
const std = @import("std");

/// Includes the unit. No rounding, floating point or allocation.
pub fn format(buffer: []u8, milliseconds: u32) ![]const u8 {
    const whole = milliseconds / 1000;
    const fraction = milliseconds % 1000;
    if (fraction == 0) return std.fmt.bufPrint(buffer, "{d} s", .{whole});
    if (fraction % 100 == 0) return std.fmt.bufPrint(buffer, "{d}.{d} s", .{ whole, fraction / 100 });
    if (fraction % 10 == 0) return std.fmt.bufPrint(buffer, "{d}.{d:0>2} s", .{ whole, fraction / 10 });
    return std.fmt.bufPrint(buffer, "{d}.{d:0>3} s", .{ whole, fraction });
}

/// Editing prefix: a trailing decimal point is allowed, never a second point.
pub fn validPrefix(input: []const u8) bool {
    var point = false;
    var decimals: usize = 0;
    for (input, 0..) |byte, index| {
        if (byte == '.') {
            if (point or index == 0) return false;
            point = true;
        } else {
            if (byte < '0' or byte > '9') return false;
            if (point) {
                decimals += 1;
                if (decimals > 3) return false;
            }
        }
    }
    return true;
}

/// Strict complete decimal seconds, checked into exact integer milliseconds.
/// Bounds/positivity belong to the caller's setting-specific validation.
pub fn parse(input: []const u8) !u32 {
    if (input.len == 0 or !validPrefix(input) or input[input.len - 1] == '.') return error.InvalidValue;
    const point = std.mem.findScalar(u8, input, '.') orelse input.len;
    const seconds = std.fmt.parseInt(u32, input[0..point], 10) catch return error.InvalidValue;
    const whole = std.math.mul(u32, seconds, 1000) catch return error.InvalidValue;
    var fraction: u32 = 0;
    if (point < input.len) {
        const digits = input[point + 1 ..];
        fraction = std.fmt.parseInt(u32, digits, 10) catch return error.InvalidValue;
        for (digits.len..3) |_| fraction *= 10;
    }
    return std.math.add(u32, whole, fraction) catch return error.InvalidValue;
}

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
