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
