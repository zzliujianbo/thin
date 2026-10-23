//! Local presentation only. The connection owner saves and publishes settings.
const std = @import("std");
const text = @import("text.zig");
const time = @import("settings_time.zig");
const provider = @import("provider_picker.zig");
const cfg = @import("../core/config.zig");
pub const Key = @import("../core/settings.zig").Key;
pub const Menu = provider.Picker;
pub const labels = [_][]const u8{
    "Low-price input", "Decision model", "Auto compaction", "Command timeout",
    "Request timeout", "Task timeout",   "Image model",     "Auto memory",
};
pub const count = labels.len;
pub const Snapshot = struct {
    low_price_input_enabled: bool = true,
    decision_enabled: bool = false,
    image_enabled: bool = false,
    memory_auto: bool = true,
    image_model: ?[]const u8 = null,
    /// Borrowed provider/rawID reference; rows copies the displayed bytes.
    decision_model: ?[]const u8 = null,
    global_settings_available: bool = true,
    limits: cfg.Limits = .{},
};
pub fn preferenceKey(selected: usize) ?Key {
    return switch (selected) {
        2 => .compaction_enabled,
        3 => .command_timeout_ms,
        4 => .request_timeout_ms,
        5 => .task_timeout_ms,
        7 => .memory_auto,
        else => null,
    };
}
pub fn label(selected: usize) []const u8 {
    return if (selected < labels.len) labels[selected] else "";
}
/// Borrowed display values; rows renders exact copied numeric values, with units.
pub fn value(state: Snapshot, selected: usize) []const u8 {
    return switch (selected) {
        0 => if (state.low_price_input_enabled) "on" else "off",
        1 => if (!state.decision_enabled) "Off" else state.decision_model orelse "Not set",
        6 => if (!state.image_enabled) "Off" else state.image_model orelse "Not set",
        2 => if (state.limits.compaction_enabled) "on" else "off",
        7 => if (state.memory_auto) "on" else "off",
        3, 4, 5 => "s",
        else => "",
    };
}
pub fn description(selected: usize) []const u8 {
    return switch (selected) {
        0 => "Protect input from price surcharges; unknown pricing pauses. Flat pricing: no L.",
        1 => "Review commands, Memory and compaction. Enter selects Off or a logged-in model.",
        2 => "Automatic compaction only; manual /compact and hard preflight remain available.",
        3 => "Command timeout in s (up to 3 decimals); cannot exceed configured command maximum.",
        4 => "All inference requests, including decisions, in s (up to 3 decimals); maximum 86400 s (24 hours).",
        5 => "Whole task timeout in s (up to 3 decimals); maximum 86400 s (24 hours).",
        6 => "Read images through a separate helper returning text. Off unless explicitly selected.",
        7 => "Automatically extract and maintain useful memory. On by default.",
        else => "",
    };
}
pub const Rows = struct {
    lines: []const []const u8,
    selected_line: ?usize = null,
    can_confirm: bool = false,
};
fn renderedValue(state: Snapshot, selected: usize, buffer: *[32]u8) ![]const u8 {
    return switch (selected) {
        3 => try time.format(buffer, state.limits.command_timeout_ms),
        4 => try time.format(buffer, state.limits.request_timeout_ms),
        5 => try time.format(buffer, state.limits.task_timeout_ms),
        else => value(state, selected),
    };
}
pub fn rows(a: std.mem.Allocator, menu: Menu, state: Snapshot, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const selected = @min(menu.selected, labels.len - 1);
    const visible = @min(max_rows, labels.len);
    const start = @min(selected -| (visible / 2), labels.len - visible);
    var label_width: usize = 0;
    for (labels) |item| label_width = @max(label_width, text.width(item));
    const padding = "                                ";
    var complete = false;
    for (start..start + visible) |index| {
        var buffer: [32]u8 = undefined;
        const v = try renderedValue(state, index, &buffer);
        const gap = label_width - text.width(label(index));
        const raw = try std.fmt.allocPrint(a, "{s}{s}{s}  {s}", .{ if (index == selected) "> " else "  ", label(index), padding[0..gap], v });
        defer a.free(raw);
        // Decision only opens a read-only submenu; its current value is not
        // being saved. All saving root rows still require the complete value.
        if (index == selected) complete = if (index == 1 or index == 6)
            2 + text.width(label(index)) <= columns
        else
            text.width(raw) <= columns;
        try append(a, &out, raw, columns);
    }
    if (max_rows > out.items.len) try append(a, &out, description(selected), columns);
    if (max_rows > out.items.len) try append(a, &out, "Up/Down select  Enter change  Left back  Esc close", columns);
    if (!state.global_settings_available and max_rows > out.items.len) try append(a, &out, "Global settings unavailable; changes disabled", columns);
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = selected - start,
        .can_confirm = state.global_settings_available and !menu.pasted and menu.selected < labels.len and complete,
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
test "settings preserve old values and expose eight preference rows" {
    try std.testing.expectEqual(@as(usize, 8), count);
    try std.testing.expectEqualStrings("Auto memory", label(7));
    try std.testing.expectEqualStrings("on", value(.{}, 7));
    try std.testing.expectEqualStrings("off", value(.{ .memory_auto = false }, 7));
    try std.testing.expectEqual(@as(?Key, .memory_auto), preferenceKey(7));
    try std.testing.expectEqualStrings("Off", value(.{}, 6));
    try std.testing.expectEqualStrings("login/deepseek-flash", value(.{ .image_enabled = true, .image_model = "login/deepseek-flash" }, 6));
    try std.testing.expectEqualStrings("on", value(.{}, 0));
    try std.testing.expectEqualStrings("off", value(.{ .low_price_input_enabled = false }, 0));
    try std.testing.expectEqualStrings("Off", value(.{}, 1));
    try std.testing.expectEqualStrings("Not set", value(.{ .decision_enabled = true }, 1));
    try std.testing.expectEqualStrings("provider/rawID", value(.{ .decision_enabled = true, .decision_model = "provider/rawID" }, 1));
    try std.testing.expect(std.mem.find(u8, description(4), "including decisions") != null);
    try std.testing.expectEqual(@as(?Key, .compaction_enabled), preferenceKey(2));
    try std.testing.expectEqual(@as(?Key, .task_timeout_ms), preferenceKey(5));
    try std.testing.expectEqual(@as(?Key, null), preferenceKey(1));
    try std.testing.expectEqual(@as(?Key, null), preferenceKey(6));
    try std.testing.expect(std.mem.find(u8, description(0), "unknown") != null);
    try std.testing.expect(std.mem.find(u8, description(1), "Memory") != null);
}
test "settings bounded windows keep selection visible and clipping disables confirmation" {
    const a = std.testing.allocator;
    for (0..count) |selected| for (0..10) |height| for (0..65) |columns| {
        const rendered = try rows(a, .{ .selected = selected }, .{}, columns, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.lines.len <= height);
        if (rendered.selected_line) |index| {
            try std.testing.expect(index < rendered.lines.len);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[index], label(selected)) != null);
        } else try std.testing.expect(height == 0);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
        if (height == 0 or columns < 2 + label(selected).len) try std.testing.expect(!rendered.can_confirm);
    };
    const exact = try rows(a, .{ .selected = 3 }, .{ .limits = .{ .command_timeout_ms = 123456 } }, 80, 1);
    defer freeRows(a, exact);
    try std.testing.expect(std.mem.find(u8, exact.lines[0], "123.456 s") != null);
    const unavailable = try rows(a, .{}, .{ .global_settings_available = false }, 80, 1);
    defer freeRows(a, unavailable);
    try std.testing.expect(!unavailable.can_confirm);
    const pasted = try rows(a, .{ .pasted = true }, .{}, 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
test "decision root opens with complete static label even when model is clipped" {
    const a = std.testing.allocator;
    var model: [512]u8 = @splat('x');
    @memcpy(model[0..9], "provider/");
    const state: Snapshot = .{ .decision_enabled = true, .decision_model = &model };
    for (0..90) |columns| {
        const rendered = try rows(a, .{ .selected = 1 }, state, columns, 1);
        defer freeRows(a, rendered);
        try std.testing.expectEqual(columns >= 2 + label(1).len, rendered.can_confirm);
        try std.testing.expect(text.width(rendered.lines[0]) <= columns);
    }
    const copied = try rows(a, .{ .selected = 1 }, state, 600, 1);
    defer freeRows(a, copied);
    model[9] = 'y';
    try std.testing.expect(std.mem.find(u8, copied.lines[0], "provider/xxx") != null);
    for ([_]usize{ 0, 2, 3, 4, 5, 7 }) |selected| {
        const clipped = try rows(a, .{ .selected = selected }, .{}, 2 + label(selected).len, 1);
        defer freeRows(a, clipped);
        try std.testing.expect(!clipped.can_confirm);
    }
    const pasted = try rows(a, .{ .selected = 1, .pasted = true }, state, 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
test "Image root long value opens independently with static label" {
    const a = std.testing.allocator;
    const long: [512]u8 = @splat('x');
    for (0..90) |columns| {
        const rendered = try rows(a, .{ .selected = 6 }, .{ .image_enabled = true, .image_model = &long, .decision_enabled = true, .decision_model = "decision/other" }, columns, 1);
        defer freeRows(a, rendered);
        try std.testing.expectEqual(columns >= 2 + label(6).len, rendered.can_confirm);
    }
    try std.testing.expectEqualStrings("Image model", label(6));
    try std.testing.expectEqualStrings("Off", value(.{ .image_model = "stale/model" }, 6));
}
fn allocationCase(a: std.mem.Allocator) !void {
    const rendered = try rows(a, .{ .selected = 5 }, .{}, 40, 10);
    defer freeRows(a, rendered);
}
test "settings rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
