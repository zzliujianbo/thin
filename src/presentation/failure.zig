//! Failure rendering shared by TUI and --print: the raw cause we actually got
//! (provider error text, transport/detail error name) plus the HTTP status.
//! No category wording and no next-step hint — only the original text helps.
const std = @import("std");

pub fn write(writer: *std.Io.Writer, label: []const u8, detail: ?anyerror, status: ?u16, message: []const u8) !void {
    try writer.writeAll(label);
    // Put the status before verbose details so narrow terminal rows retain it.
    if (status) |code| try writer.print(" [HTTP {d}]", .{code});
    if (message.len != 0) return writer.print(": {s}", .{message});
    if (detail) |err| return writer.print(": {s}", .{@errorName(err)});
}
