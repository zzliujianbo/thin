//! Minimal user-requested exit line. IDs are fixed lowercase hex, not shell text.
//! Run it from the same project with the current Thin version on PATH.
const std = @import("std");
const ids = @import("session_id.zig");

pub fn format(a: std.mem.Allocator, id: ids.Id) ![]u8 {
    if (!ids.valid(id)) return error.InvalidSessionID;
    return std.fmt.allocPrint(a, "thin --resume {s}\n", .{id});
}

test "resume command is one minimal line with only a validated ID" {
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const a = std.testing.allocator;
    const line = try format(a, id);
    defer a.free(line);
    try std.testing.expectEqualStrings("thin --resume " ++ id ++ "\n", line);
    try std.testing.expectError(error.InvalidSessionID, format(a, @splat(';')));
}
