//! Local presentation only. The connection owner saves and publishes settings.
const std = @import("std");
const text = @import("text.zig");
const provider = @import("provider_picker.zig");
const cfg = @import("../core/config.zig");
pub const Key = @import("../core/settings.zig").Key;
pub const Menu = provider.Picker;
pub const labels = [_][]const u8{
    "Low-price input", "Decision model", "Auto compaction", "Command timeout",
    "Request timeout", "Output limit",   "Task timeout",
};
pub const count = labels.len;
pub const Snapshot = struct {
    low_price_input_enabled: bool = true,
    decision_enabled: bool = false,
    global_settings_available: bool = true,
    limits: cfg.Limits = .{},
};
pub fn preferenceKey(selected: usize) ?Key {
    return switch (selected) {
        2 => .compaction_enabled,
        3 => .command_timeout_ms,
        4 => .request_timeout_ms,
        5 => .max_output_tokens,
        6 => .task_timeout_ms,
        else => null,
    };
}
pub fn label(selected: usize) []const u8 {
    return if (selected < labels.len) labels[selected] else "";
}
/// Static labels only; rows renders exact copied numeric values, with units.
pub fn value(state: Snapshot, selected: usize) []const u8 {
    return switch (selected) {
        0 => if (state.low_price_input_enabled) "on" else "off",
        1 => if (!state.decision_enabled) "off" else "Configured",
        2 => if (state.limits.compaction_enabled) "on" else "off",
        3, 4, 6 => "ms",
        5 => if (state.limits.max_output_tokens == null) "Auto" else "tokens",
        else => "",
    };
}
pub fn description(selected: usize) []const u8 {
    return switch (selected) {
        0 => "Protect input from price surcharges; unknown pricing pauses. Flat pricing: no L.",
        1 => "Review commands, Memory and compaction. Enter selects Off or a logged-in model.",
        2 => "Automatic compaction only; manual /compact and hard preflight remain available.",
        3 => "Command timeout in ms; cannot exceed command_max_timeout_ms.",
        4 => "All inference requests, including decisions, in ms; maximum 86400000 ms (24 hours).",
        5 => "Output cap in tokens; Auto uses model policy. Explicit cap must cover summary_tokens.",
        6 => "Whole task timeout in ms; maximum 86400000 ms (24 hours).",
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
        3 => try std.fmt.bufPrint(buffer, "{d} ms", .{state.limits.command_timeout_ms}),
        4 => try std.fmt.bufPrint(buffer, "{d} ms", .{state.limits.request_timeout_ms}),
        5 => if (state.limits.max_output_tokens) |n| try std.fmt.bufPrint(buffer, "{d} tokens", .{n}) else "Auto",
        6 => try std.fmt.bufPrint(buffer, "{d} ms", .{state.limits.task_timeout_ms}),
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
        if (index == selected) complete = text.width(raw) <= columns;
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
test "settings preserve old values and expose seven preference rows" {
    try std.testing.expectEqual(@as(usize, 7), count);
    try std.testing.expectEqualStrings("on", value(.{}, 0));
    try std.testing.expectEqualStrings("off", value(.{ .low_price_input_enabled = false }, 0));
    try std.testing.expectEqualStrings("off", value(.{}, 1));
    try std.testing.expectEqualStrings("Configured", value(.{ .decision_enabled = true }, 1));
    try std.testing.expect(std.mem.find(u8, description(4), "including decisions") != null);
    try std.testing.expectEqual(@as(?Key, .compaction_enabled), preferenceKey(2));
    try std.testing.expectEqual(@as(?Key, .task_timeout_ms), preferenceKey(6));
    try std.testing.expectEqual(@as(?Key, null), preferenceKey(1));
    try std.testing.expectEqual(@as(?Key, null), preferenceKey(7));
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
    try std.testing.expect(std.mem.find(u8, exact.lines[0], "123456 ms") != null);
    const unavailable = try rows(a, .{}, .{ .global_settings_available = false }, 80, 1);
    defer freeRows(a, unavailable);
    try std.testing.expect(!unavailable.can_confirm);
    const pasted = try rows(a, .{ .pasted = true }, .{}, 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
fn allocationCase(a: std.mem.Allocator) !void {
    const rendered = try rows(a, .{ .selected = 6 }, .{}, 40, 10);
    defer freeRows(a, rendered);
}
test "settings rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
