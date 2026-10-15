//! Minimal user-requested exit line. IDs are fixed lowercase hex, not shell text.
//! Run it from the same project with the current Thin version on PATH.
//! A leading blank line separates it from the conversation, and the whole line
//! is green (then reset) so an exited user notices the copyable command.
const std = @import("std");
const ids = @import("session_id.zig");
const theme = @import("../ui/theme.zig");

pub fn format(a: std.mem.Allocator, id: ids.Id) ![]u8 {
    if (!ids.valid(id)) return error.InvalidSessionID;
    return std.fmt.allocPrint(a, "\n{s}thin --resume {s}{s}\n", .{ theme.success, id, theme.reset });
}

test "resume command is one green line after a blank separator with only a validated ID" {
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const a = std.testing.allocator;
    const line = try format(a, id);
    defer a.free(line);
    try std.testing.expectEqualStrings("\n" ++ theme.success ++ "thin --resume " ++ id ++ theme.reset ++ "\n", line);
    try std.testing.expectError(error.InvalidSessionID, format(a, @splat(';')));
}
