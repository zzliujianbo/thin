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
        self.selected = if (down) @min(self.selected + 1, count - 1) else self.selected -| 1;
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
    {
        const title = try clip(a, "Configure provider (API key)", columns);
        errdefer a.free(title);
        try out.append(a, title);
    }
    const selected = @min(picker.selected, available.len - 1);
    const count = @min(max_rows - 1, available.len);
    const start = @min(selected -| (count / 2), available.len - count);
    for (available.items[start .. start + count], start..) |item, index| {
        const saved = switch (item) {
            .current => false,
            .provider => |id| configured & (@as(u8, 1) << @intCast(@backingInt(id))) != 0,
        };
        const raw = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ if (selected == index) "> " else "  ", item.label(), if (saved) "  configured locally" else "" });
        defer a.free(raw);
        const line = try clip(a, raw, columns);
        errdefer a.free(line);
        try out.append(a, line);
    }
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = if (count != 0) 1 + selected - start else null,
        .can_confirm = !picker.pasted and count != 0 and columns >= 2 + available.items[selected].label().len,
    };
}

fn clip(a: std.mem.Allocator, value: []const u8, columns: usize) ![]const u8 {
    var end: usize = 0;
    var width: usize = 0;
    while (end < value.len) {
        const cluster = text.nextCluster(value, end, 0);
        if (width + cluster.width > columns) break;
        width += cluster.width;
        end = cluster.end;
    }
    return a.dupe(u8, value[0..end]);
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
    try std.testing.expect(std.mem.find(u8, rendered.lines[2], "configured locally") != null);
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
