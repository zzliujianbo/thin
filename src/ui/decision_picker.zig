//! Presentation only: backend choices; the owner filters logged-in model identities.
const std = @import("std");
const text = @import("text.zig");
pub const Menu = @import("provider_picker.zig").Picker;
pub const Rows = @import("settings_menu.zig").Rows;
pub const labels = [_][]const u8{ "Off", "OpenCode Jev Free", "Logged-in model", "Request timeout" };
pub fn description(selected: usize) []const u8 {
    return switch (selected) {
        0 => "Disable decision reviews; no decision declaration required.",
        1 => "Uses its independent key; configure its provider via /login. Saves without a key.",
        2 => "Select a logged-in model for independent reviews; the chat model is unchanged.",
        3 => "Independent decision request timeout in ms; maximum 3600000 ms (1 hour).",
        else => "",
    };
}
/// Legacy presentation without a declaration. The timeout row is disabled.
pub fn rows(a: std.mem.Allocator, menu: Menu, columns: usize, max_rows: usize) !Rows {
    return rowsWithTimeout(a, menu, null, columns, max_rows);
}
/// Null means no decision declaration: choose a model before editing its timeout.
pub fn rowsWithTimeout(a: std.mem.Allocator, menu: Menu, timeout_ms: ?u32, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const selected = @min(menu.selected, labels.len - 1);
    const count = @min(max_rows, labels.len);
    const start = @min(selected -| (count / 2), labels.len - count);
    var complete = false;
    for (start..start + count) |index| {
        var buffer: [32]u8 = undefined;
        const suffix = if (index != 3) "" else if (timeout_ms) |ms| try std.fmt.bufPrint(&buffer, "  {d} ms", .{ms}) else "  (select a model first)";
        const raw = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ if (index == selected) "> " else "  ", labels[index], suffix });
        defer a.free(raw);
        if (index == selected) complete = text.width(raw) <= columns;
        try append(a, &out, raw, columns);
    }
    if (max_rows > out.items.len) try append(a, &out, if (selected == 3 and timeout_ms == null) "Select a decision model first; no decision declaration is configured." else description(selected), columns);
    if (max_rows > out.items.len) try append(a, &out, switch (selected) {
        2 => "Up/Down select  Enter choose model  Left/Esc back",
        3 => "Up/Down select  Enter change timeout  Left/Esc back",
        else => "Up/Down select  Enter save  Left/Esc back",
    }, columns);
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = selected - start,
        .can_confirm = !menu.pasted and menu.selected < labels.len and complete and (selected != 3 or timeout_ms != null),
    };
}
fn append(a: std.mem.Allocator, out: *std.ArrayList([]const u8), raw: []const u8, columns: usize) !void {
    var end: usize = 0;
    var width: usize = 0;
    while (end < raw.len) {
        const cluster = text.nextCluster(raw, end, width);
        if (width + cluster.width > columns) break;
        width += cluster.width;
        end = cluster.end;
    }
    const line = try a.dupe(u8, raw[0..end]);
    errdefer a.free(line);
    try out.append(a, line);
}
fn freeRows(a: std.mem.Allocator, rendered: Rows) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}
test "decision choices preserve first three and require declaration for timeout" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 4), labels.len);
    try std.testing.expectEqualStrings("Off", labels[0]);
    try std.testing.expectEqualStrings("OpenCode Jev Free", labels[1]);
    try std.testing.expectEqualStrings("Logged-in model", labels[2]);
    try std.testing.expectEqualStrings("Request timeout", labels[3]);
    try std.testing.expect(std.mem.find(u8, description(1), "independent key") != null);
    try std.testing.expect(std.mem.find(u8, description(2), "chat model is unchanged") != null);
    const missing = try rows(a, .{ .selected = 3 }, 80, 1);
    defer freeRows(a, missing);
    try std.testing.expect(!missing.can_confirm);
    try std.testing.expect(std.mem.find(u8, missing.lines[0], "select a model first") != null);
    const configured = try rowsWithTimeout(a, .{ .selected = 3 }, 123456, 80, 1);
    defer freeRows(a, configured);
    try std.testing.expect(configured.can_confirm);
    try std.testing.expect(std.mem.find(u8, configured.lines[0], "123456 ms") != null);
}
test "decision windows keep selection visible with clipping and paste safety" {
    const a = std.testing.allocator;
    for (0..labels.len) |selected| for (0..7) |height| for (0..65) |columns| {
        const rendered = try rowsWithTimeout(a, .{ .selected = selected }, 300000, columns, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.lines.len <= height);
        if (rendered.selected_line) |index| {
            try std.testing.expect(index < rendered.lines.len);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[index], labels[selected]) != null);
        } else try std.testing.expect(height == 0);
        const needed = 2 + labels[selected].len + (if (selected == 3) @as(usize, "  300000 ms".len) else 0);
        try std.testing.expectEqual(height != 0 and columns >= needed, rendered.can_confirm);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
    };
    const pasted = try rowsWithTimeout(a, .{ .pasted = true }, 300000, 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
fn allocationCase(a: std.mem.Allocator) !void {
    const rendered = try rowsWithTimeout(a, .{ .selected = 3 }, 300000, 40, 7);
    defer freeRows(a, rendered);
}
test "decision rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
