//! Local presentation only. The connection owner saves and publishes settings.
const std = @import("std");
const text = @import("text.zig");
const provider = @import("provider_picker.zig");
pub const Menu = provider.Picker;
pub const Snapshot = struct {
    low_price_input_enabled: bool = true,
    decision_enabled: bool = false,
    decision_configured: bool = false,
    global_settings_available: bool = true,
};
pub fn label(selected: usize) []const u8 {
    return if (selected == 0) "Low-price input" else "Decision model";
}
pub fn value(state: Snapshot, selected: usize) []const u8 {
    if (selected != 0 and !state.decision_configured) return "not configured";
    return if (if (selected == 0) state.low_price_input_enabled else state.decision_enabled) "on" else "off";
}
pub fn description(selected: usize) []const u8 {
    return if (selected == 0)
        "Protect input from price surcharges; unknown pricing pauses. Flat pricing: no L."
    else
        "Review commands, Memory and compaction via config.json decision; may cost more.";
}
pub const Rows = struct {
    lines: []const []const u8,
    selected_line: ?usize = null,
    can_confirm: bool = false,
};
pub fn rows(a: std.mem.Allocator, menu: Menu, state: Snapshot, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const selected = @min(menu.selected, 1);
    const count = @min(max_rows, 2);
    const start = if (count == 1) selected else 0;
    const label_width = @max(text.width(label(0)), text.width(label(1)));
    const padding = "                                ";
    for (start..start + count) |index| {
        const gap = label_width - text.width(label(index));
        const raw = try std.fmt.allocPrint(a, "{s}{s}{s}  {s}", .{ if (index == selected) "> " else "  ", label(index), padding[0..gap], value(state, index) });
        defer a.free(raw);
        try append(a, &out, raw, columns);
    }
    if (max_rows > out.items.len) try append(a, &out, description(selected), columns);
    if (max_rows > out.items.len) try append(a, &out, "Up/Down select  Enter toggle  Left back  Esc close", columns);
    if (!state.global_settings_available and max_rows > out.items.len) try append(a, &out, "Global settings unavailable; changes disabled", columns);
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = selected - start,
        .can_confirm = !menu.pasted and columns >= 2 + label_width + 2 + text.width(value(state, selected)),
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
test "settings values descriptions and complete identifier clipping" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("on", value(.{}, 0));
    try std.testing.expectEqualStrings("off", value(.{ .low_price_input_enabled = false }, 0));
    try std.testing.expectEqualStrings("not configured", value(.{}, 1));
    try std.testing.expectEqualStrings("on", value(.{ .decision_configured = true, .decision_enabled = true }, 1));
    try std.testing.expect(std.mem.find(u8, description(0), "unknown") != null);
    try std.testing.expect(std.mem.find(u8, description(1), "Memory") != null);
    for (0..2) |selected| for (0..60) |columns| {
        const rendered = try rows(a, .{ .selected = selected }, .{}, columns, 5);
        defer {
            for (rendered.lines) |line| a.free(line);
            a.free(rendered.lines);
        }
        try std.testing.expectEqual(columns >= 2 + @max(label(0).len, label(1).len) + 2 + value(.{}, selected).len, rendered.can_confirm);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
    };
}
