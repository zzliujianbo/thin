//! API-key provider selection. No secrets, network access or credential storage.
const std = @import("std");
const text = @import("text.zig");
const Id = @import("../core/providers.zig").Id;

pub const Choice = union(enum) {
    current,
    provider: Id,

    pub fn label(self: Choice) []const u8 {
        return switch (self) {
            .current => "Current endpoint",
            .provider => |id| id.label(),
        };
    }
};
pub const Choices = struct {
    items: [4]Choice = undefined,
    len: usize = 0,
};
pub fn choices(include_current: bool) Choices {
    var result: Choices = .{};
    if (include_current) {
        result.items[0] = .current;
        result.len = 1;
    }
    for (Id.all) |id| {
        result.items[result.len] = .{ .provider = id };
        result.len += 1;
    }
    return result;
}

pub const Picker = struct {
    selected: usize = 0,
    generation: u64 = 1,
    pasted: bool = false,

    pub fn move(self: *Picker, down: bool, count: usize) void {
        if (count == 0) return;
        self.selected = @min(self.selected, count - 1);
        self.selected = if (down) (self.selected + 1) % count else if (self.selected == 0) count - 1 else self.selected - 1;
        self.generation +%= 1;
    }
    pub fn clear(self: *Picker) void {
        self.pasted = false;
        self.generation +%= 1;
    }
    pub fn markPaste(self: *Picker) void {
        self.pasted = true;
        self.generation +%= 1;
    }
};

pub const Rows = struct {
    checked_mask: u16 = 0,
    lines: []const []const u8,
    selected_line: ?usize = null,
    can_confirm: bool = false,
};

pub fn rows(a: std.mem.Allocator, picker: Picker, available: Choices, configured: u8, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0 or available.len == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const selected = @min(picker.selected, available.len - 1);
    const count = @min(@min(max_rows, 10), available.len);
    const start = @min(selected -| (count / 2), available.len - count);
    var checked_mask: u16 = 0;
    for (available.items[start .. start + count], start..) |item, index| {
        const saved = switch (item) {
            .current => false,
            .provider => |id| configured & (@as(u8, 1) << @intCast(@backingInt(id))) != 0,
        };
        if (saved) checked_mask |= @as(u16, 1) << @intCast(index - start);
        const raw = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ if (selected == index) "> " else "  ", if (saved) "✓ " else "  ", item.label() });
        defer a.free(raw);
        const line = try clip(a, raw, columns);
        errdefer a.free(line);
        try out.append(a, line);
    }
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = if (count != 0) selected - start else null,
        .can_confirm = !picker.pasted and count != 0 and columns >= 4 and text.width(available.items[selected].label()) <= columns - 4,
        .checked_mask = checked_mask,
    };
}

fn clip(a: std.mem.Allocator, value: []const u8, columns: usize) ![]const u8 {
    var end: usize = 0;
    var width: usize = 0;
    while (end < value.len) {
        const cluster = text.nextCluster(value, end, width);
        if (width + cluster.width > columns) break;
        width += cluster.width;
        end = cluster.end;
    }
    return a.dupe(u8, value[0..end]);
}

test "provider selection wraps in both directions" {
    var picker: Picker = .{};
    picker.move(false, 4);
    try std.testing.expectEqual(@as(usize, 3), picker.selected);
    picker.move(true, 4);
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
    picker.selected = 99;
    picker.move(true, 4);
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
    const generation = picker.generation;
    picker.move(false, 0);
    try std.testing.expectEqual(generation, picker.generation);
}

test "provider candidate window has no title and confirms complete labels only" {
    const a = std.testing.allocator;
    const available = choices(true);
    for (0..available.len) |selected| {
        const picker: Picker = .{ .selected = selected };
        const width = 4 + text.width(available.items[selected].label());
        for (0..width + 1) |columns| {
            const rendered = try rows(a, picker, available, 7, columns, 1);
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
            try std.testing.expectEqual(@as(usize, 1), rendered.lines.len);
            try std.testing.expectEqual(@as(usize, 0), rendered.selected_line.?);
            try std.testing.expectEqual(columns == width, rendered.can_confirm);
            try std.testing.expectEqual(@as(u16, if (selected == 0) 0 else 1), rendered.checked_mask);
            try std.testing.expect(text.width(rendered.lines[0]) <= columns);
            try std.testing.expect(std.unicode.utf8ValidateSlice(rendered.lines[0]));
            if (rendered.can_confirm) try std.testing.expectEqualStrings(available.items[selected].label(), rendered.lines[0][if (selected == 0) @as(usize, 4) else 6..]);
        }
    }
    const all = try rows(a, .{ .selected = 3 }, available, 0, 80, 20);
    defer {
        for (all.lines) |line| a.free(line);
        a.free(all.lines);
    }
    try std.testing.expectEqual(@as(u16, 0), all.checked_mask);
    try std.testing.expectEqual(available.len, all.lines.len);
    try std.testing.expectEqual(@as(usize, 3), all.selected_line.?);
    const empty = try rows(a, .{}, available, 0, 80, 0);
    defer a.free(empty.lines);
    try std.testing.expect(empty.lines.len == 0 and empty.selected_line == null and !empty.can_confirm);
}

test "provider checked bits follow saved visible rows not navigation selection" {
    const a = std.testing.allocator;
    const available = choices(true);
    const saved_id = available.items[2].provider;
    const configured = @as(u8, 1) << @intCast(@backingInt(saved_id));
    for (0..available.len) |selected| {
        const rendered = try rows(a, .{ .selected = selected }, available, configured, 80, 2);
        defer {
            for (rendered.lines) |line| a.free(line);
            a.free(rendered.lines);
        }
        const start = @min(selected -| 1, available.len - 2);
        try std.testing.expectEqual(selected - start, rendered.selected_line.?);
        try std.testing.expect(rendered.can_confirm);
        for (rendered.lines, start..) |line, index| {
            const saved = index == 2;
            try std.testing.expectEqual(saved, rendered.checked_mask & (@as(u16, 1) << @intCast(index - start)) != 0);
            try std.testing.expectEqualStrings(if (selected == index) "> " else "  ", line[0..2]);
            const prefix_bytes: usize = if (saved) 6 else 4;
            try std.testing.expectEqualStrings(if (saved) "✓ " else "  ", line[2..prefix_bytes]);
            try std.testing.expect(std.mem.startsWith(u8, line[prefix_bytes..], available.items[index].label()));
            try std.testing.expectEqualStrings(available.items[index].label(), line[prefix_bytes..]);
            try std.testing.expect(std.mem.findScalar(u8, line, 0x1b) == null);
        }
    }
}

test "provider picker distinguishes Zen Go and local setup without holding keys" {
    const available = choices(true);
    try std.testing.expectEqual(@as(usize, 4), available.len);
    try std.testing.expectEqualStrings("Current endpoint", available.items[0].label());
    try std.testing.expectEqualStrings("OpenCode Zen", available.items[2].label());
    try std.testing.expectEqualStrings("OpenCode Go", available.items[3].label());
    var picker: Picker = .{};
    picker.move(true, available.len);
    try std.testing.expectEqualStrings("DeepSeek", available.items[picker.selected].label());
    picker.markPaste();
    const a = std.testing.allocator;
    const rendered = try rows(a, picker, available, 7, 80, 8);
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expect(!rendered.can_confirm);
    try std.testing.expectEqual(@as(u16, 0b1110), rendered.checked_mask);
    try std.testing.expectEqualStrings("> ✓ DeepSeek", rendered.lines[1]);
    try std.testing.expectEqualStrings("    Current endpoint", rendered.lines[0]);
    picker.clear();
    for (0..7) |height| {
        const clipped = try rows(a, picker, available, 0, 5, height);
        defer {
            for (clipped.lines) |line| a.free(line);
            a.free(clipped.lines);
        }
        try std.testing.expect(!clipped.can_confirm and clipped.lines.len <= height);
        for (clipped.lines) |line| try std.testing.expect(text.width(line) <= 5);
    }
}
