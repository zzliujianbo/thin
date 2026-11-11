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
    items: [Id.all.len + 1]Choice = undefined,
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
    return a.dupe(u8, value[0..text.fitBytes(value, columns)]);
}
