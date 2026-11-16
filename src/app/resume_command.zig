//! Minimal user-requested exit line. IDs are fixed lowercase hex, not shell text.
//! Run it from the same project with the current Thin version on PATH.
//! A leading blank line separates it from the conversation; the line is muted
//! so it remains a copyable hint rather than a success banner.
const std = @import("std");
const ids = @import("session_id.zig");
const theme = @import("../ui/theme.zig");

pub fn format(a: std.mem.Allocator, id: ids.Id) ![]u8 {
    if (!ids.valid(id)) return error.InvalidSessionID;
    return std.fmt.allocPrint(a, "\n{s}thin --resume {s}{s}\n", .{ theme.muted, id, theme.reset });
}
