//! Presentation only: exactly two choices, never credentials or network access.
const std = @import("std");
const text = @import("text.zig");
pub const Menu = @import("provider_picker.zig").Picker;
pub const Rows = @import("settings_menu.zig").Rows;
pub const labels = [_][]const u8{ "Off", "OpenCode Jev Free" };
pub fn description(selected: usize) []const u8 {
    return if (selected == 0) "Disable decision reviews; no decision declaration required." else "Uses its independent key; configure its provider via /login. Saves without a key.";
}
pub fn rows(a: std.mem.Allocator, menu: Menu, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const selected = @min(menu.selected, labels.len - 1);
    const count = @min(max_rows, labels.len);
    const start = if (count == 1) selected else 0;
    for (start..start + count) |index| {
        const raw = try std.fmt.allocPrint(a, "{s}{s}", .{ if (index == selected) "> " else "  ", labels[index] });
        defer a.free(raw);
        try append(a, &out, raw, columns);
    }
    if (max_rows > out.items.len) try append(a, &out, description(selected), columns);
    if (max_rows > out.items.len) try append(a, &out, "Up/Down select  Enter save  Left/Esc back", columns);
    return .{ .lines = try out.toOwnedSlice(a), .selected_line = selected - start, .can_confirm = !menu.pasted and columns >= 2 + text.width(labels[selected]) };
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
test "decision choices exactly two complete identifiers clipped and paste safe" {
    try std.testing.expectEqual(@as(usize, 2), labels.len);
    try std.testing.expectEqualStrings("Off", labels[0]);
    try std.testing.expectEqualStrings("OpenCode Jev Free", labels[1]);
    try std.testing.expect(std.mem.find(u8, description(1), "independent key") != null);
    for (0..2) |selected| for (0..60) |columns| {
        const rendered = try rows(std.testing.allocator, .{ .selected = selected }, columns, 5);
        defer {
            for (rendered.lines) |line| std.testing.allocator.free(line);
            std.testing.allocator.free(rendered.lines);
        }
        try std.testing.expectEqual(columns >= 2 + labels[selected].len, rendered.can_confirm);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
    };
    const pasted = try rows(std.testing.allocator, .{ .pasted = true }, 80, 1);
    defer {
        for (pasted.lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(pasted.lines);
    }
    try std.testing.expect(!pasted.can_confirm);
}
