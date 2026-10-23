//! Bounded local value staging. No persistence, network, ACK or generation ownership.
//! The owner uses its existing provider.Picker, rejects paste, and advances that
//! menu's generation on every edit/transition. submitCustom requires a new frame
//! ACK before a second Enter may call chosen and persist the staged choice.
const std = @import("std");
const cfg = @import("../core/config.zig");
const text = @import("text.zig");
const time = @import("settings_time.zig");
const provider = @import("provider_picker.zig");
pub const Key = @import("../core/settings.zig").Key;
pub const Rows = @import("settings_menu.zig").Rows;
pub const max_input_len = 14; // Bounded seconds text, including decimal point.

pub const Picker = struct {
    key: Key,
    current: ?u32,
    editing: bool = false,
    limits: cfg.Limits,
    // Five time presets, a preserved current value and one stage.
    values: [7]?u32 = @splat(null),
    values_len: usize = 0,
    staged_index: ?usize = null,
    input: [max_input_len]u8 = @splat(0),
    input_len: usize = 0,

    pub fn init(key: Key, current: ?u32, limits: cfg.Limits) Picker {
        var result: Picker = .{ .key = key, .current = current, .limits = limits };
        if (key == .compaction_enabled or key == .memory_auto) return result; // Boolean stays in the parent.
        const presets: []const u32 = switch (key) {
            .task_timeout_ms => &.{ 300000, 900000, 1800000, 3600000, 86400000 },
            else => &.{ 30000, 60000, 300000, 900000, 3600000 },
        };
        for (presets) |n| {
            result.validate(n) catch continue;
            result.add(n);
        }
        // Even a legacy/out-of-range value is displayed without normalization.
        // chosen still validates it and fails closed if it cannot be saved.
        if (result.find(current) == null) result.add(current);
        return result;
    }
    /// Initial owner selection; do not silently replace a non-preset current value.
    pub fn currentIndex(self: Picker) usize {
        return self.find(self.current) orelse 0;
    }
    pub fn count(self: Picker) usize {
        return self.values_len + 1;
    }
    pub fn isCustom(self: Picker, index: usize) bool {
        return index == self.values_len;
    }
    pub fn beginCustom(self: *Picker) void {
        self.editing = true;
        self.clear();
    }
    /// All-or-nothing ASCII decimal append. The owner must reject paste events;
    /// text alone cannot prove whether bytes came from a paste.
    pub fn append(self: *Picker, bytes: []const u8) bool {
        const capacity: usize = max_input_len;
        if (!self.editing or bytes.len == 0 or self.input_len > capacity or bytes.len > capacity - self.input_len) return false;
        var next = self.input;
        @memcpy(next[self.input_len..][0..bytes.len], bytes);
        const length = self.input_len + bytes.len;
        if (!time.validPrefix(next[0..length])) return false;
        self.input = next;
        self.input_len = length;
        return true;
    }
    pub fn backspace(self: *Picker) void {
        if (!self.editing or self.input_len == 0) return;
        self.input_len -= 1;
        self.input[self.input_len] = 0;
    }
    pub fn clear(self: *Picker) void {
        self.input = @splat(0);
        self.input_len = 0;
    }
    /// Stages only. The owner selects this index, bumps menu.generation, stops
    /// the current input batch and waits for a fresh full frame before saving.
    pub fn submitCustom(self: *Picker) !usize {
        if (!self.editing) return error.NotEditing;
        const n = try self.parsedInput();
        const index = if (self.find(n)) |existing| existing else blk: {
            if (self.staged_index) |staged| {
                self.values[staged] = n;
                break :blk staged;
            }
            const staged = self.values_len;
            self.add(n);
            self.staged_index = staged;
            break :blk staged;
        };
        self.editing = false;
        self.clear();
        return index;
    }
    /// Returns the exact initialized/staged value, never a recomputed preset.
    pub fn chosen(self: Picker, index: usize) !?u32 {
        if (self.editing) return error.Editing;
        if (index >= self.count()) return error.InvalidIndex;
        if (self.isCustom(index)) return error.CustomChoice;
        const n = self.values[index];
        try self.validate(n);
        return n;
    }
    fn add(self: *Picker, n: ?u32) void {
        std.debug.assert(self.values_len < self.values.len);
        self.values[self.values_len] = n;
        self.values_len += 1;
    }
    fn find(self: Picker, n: ?u32) ?usize {
        for (self.values[0..self.values_len], 0..) |v, index| if (v == n) return index;
        return null;
    }
    fn parsedInput(self: Picker) !u32 {
        if (self.input_len == 0 or self.input_len > max_input_len) return error.InvalidValue;
        const n = try time.parse(self.input[0..self.input_len]);
        try self.validate(n);
        return n;
    }
    fn validate(self: Picker, n: ?u32) !void {
        if (self.key == .compaction_enabled or self.key == .memory_auto) return error.InvalidKey;
        const value = n orelse return error.InvalidValue;
        if (value == 0) return error.InvalidValue;
        const maximum: u32 = switch (self.key) {
            .command_timeout_ms => self.limits.command_max_timeout_ms,
            .request_timeout_ms, .task_timeout_ms => 86400000,
            .compaction_enabled, .memory_auto => unreachable,
        };
        if (value > maximum) return error.InvalidValue;
    }
};

test "boolean preferences never offer confirmable numeric values" {
    const a = std.testing.allocator;
    for ([_]Key{ .compaction_enabled, .memory_auto }) |key| {
        var picker = Picker.init(key, 1, .{});
        try std.testing.expectEqual(@as(usize, 0), picker.values_len);
        const rendered = try rows(a, .{}, picker, 80, 3);
        defer {
            for (rendered.lines) |line| a.free(line);
            a.free(rendered.lines);
        }
        try std.testing.expect(!rendered.can_confirm);
        picker.beginCustom();
        try std.testing.expect(picker.append("1"));
        try std.testing.expectError(error.InvalidKey, picker.submitCustom());
    }
}

fn candidate(buffer: *[96]u8, picker: Picker, index: usize) ![]const u8 {
    if (picker.isCustom(index)) {
        if (picker.editing) return std.fmt.bufPrint(buffer, "Custom: {s}_ s", .{picker.input[0..picker.input_len]});
        return "Custom (s)...";
    }
    const n = picker.values[index];
    const marker = if (n == picker.current) " (current)" else if (picker.staged_index == index) " (staged)" else "";
    if (n) |v| {
        var seconds: [32]u8 = undefined;
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ try time.format(&seconds, v), marker });
    }
    return std.fmt.bufPrint(buffer, "Unset (invalid){s}", .{marker});
}
pub fn rows(a: std.mem.Allocator, menu: provider.Picker, self: Picker, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const selected = @min(menu.selected, self.count() - 1);
    const visible = @min(max_rows, self.count());
    const start = @min(selected -| (visible / 2), self.count() - visible);
    var complete = false;
    for (start..start + visible) |index| {
        var buffer: [96]u8 = undefined;
        const label = try candidate(&buffer, self, index);
        const raw = try std.fmt.allocPrint(a, "{s}{s}", .{ if (index == selected) "> " else "  ", label });
        defer a.free(raw);
        if (index == selected) complete = text.width(raw) <= columns;
        try appendLine(a, &out, raw, columns);
    }
    const valid = if (self.editing) blk: {
        _ = self.parsedInput() catch break :blk false;
        break :blk self.isCustom(selected);
    } else if (self.isCustom(selected)) self.key != .compaction_enabled and self.key != .memory_auto else blk: {
        _ = self.chosen(selected) catch break :blk false;
        break :blk true;
    };
    if (max_rows > out.items.len) try appendLine(a, &out, if (self.editing)
        "Positive seconds (s), up to 3 decimals. Enter stages; next Enter saves."
    else
        "Up/Down select  Enter choose  Left/Esc back", columns);
    if (self.editing and !valid and max_rows > out.items.len) try appendLine(a, &out, "Empty, overflow or outside configured bounds; cannot stage.", columns);
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = selected - start,
        .can_confirm = !menu.pasted and menu.selected < self.count() and complete and valid,
    };
}
fn appendLine(a: std.mem.Allocator, out: *std.ArrayList([]const u8), raw: []const u8, columns: usize) !void {
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

test "value picker preserves exact current custom values and stable stages" {
    var picker = Picker.init(.request_timeout_ms, 123456, .{});
    const current_index = picker.currentIndex();
    try std.testing.expectEqual(picker.find(123456).?, current_index);
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(current_index));
    const count_before = picker.count();
    try std.testing.expect(!picker.append("12"));
    picker.beginCustom();
    try std.testing.expectError(error.InvalidValue, picker.submitCustom());
    try std.testing.expect(picker.append("234.567"));
    try std.testing.expectError(error.Editing, picker.chosen(current_index));
    const staged_index = try picker.submitCustom();
    try std.testing.expect(!picker.editing);
    try std.testing.expectEqual(@as(?u32, 123456), picker.current);
    try std.testing.expectEqual(@as(?u32, 234567), try picker.chosen(staged_index));
    try std.testing.expectError(error.NotEditing, picker.submitCustom());
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(current_index));
    try std.testing.expectEqual(count_before + 1, picker.count());
    picker.beginCustom();
    try std.testing.expect(picker.append("345.678"));
    try std.testing.expectEqual(staged_index, try picker.submitCustom());
    try std.testing.expectEqual(@as(?u32, 345678), try picker.chosen(staged_index));
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(current_index));
    try std.testing.expectError(error.CustomChoice, picker.chosen(picker.count() - 1));
    try std.testing.expectError(error.InvalidIndex, picker.chosen(picker.count()));
}
test "value constraints include command maximum and timeout bounds" {
    const legacy = Picker.init(.request_timeout_ms, 86400001, .{});
    try std.testing.expectEqual(@as(?u32, 86400001), legacy.values[legacy.currentIndex()]);
    try std.testing.expectError(error.InvalidValue, legacy.chosen(legacy.currentIndex()));
    const command = Picker.init(.command_timeout_ms, 123, .{ .command_max_timeout_ms = 1000 });
    try std.testing.expectError(error.InvalidValue, command.validate(1001));
    try command.validate(1000);
    try std.testing.expectEqual(@as(?u32, 123), try command.chosen(command.find(123).?));
    for ([_]Key{ .request_timeout_ms, .task_timeout_ms }) |key| {
        const picker = Picker.init(key, 300000, .{});
        const maximum: u32 = 86400000;
        try picker.validate(maximum);
        try std.testing.expectError(error.InvalidValue, picker.validate(maximum + 1));
        try std.testing.expectError(error.InvalidValue, picker.validate(null));
        try std.testing.expectError(error.InvalidValue, picker.validate(0));
    }
}
test "value windows keep selected visible and reject clipped identities and paste" {
    const a = std.testing.allocator;
    const picker = Picker.init(.request_timeout_ms, 123456, .{});
    for (0..picker.count()) |selected| for (0..12) |height| for (0..45) |columns| {
        const rendered = try rows(a, .{ .selected = selected }, picker, columns, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.lines.len <= height);
        var buffer: [96]u8 = undefined;
        const expected = try candidate(&buffer, picker, selected);
        try std.testing.expectEqual(height > 0 and columns >= 2 + text.width(expected), rendered.can_confirm);
        if (rendered.selected_line) |index| {
            try std.testing.expect(index < rendered.lines.len);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[index], expected) != null);
        } else try std.testing.expect(height == 0);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
    };
    const pasted = try rows(a, .{ .pasted = true }, picker, 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
test "editing custom can only stage valid complete input then confirm staged row" {
    const a = std.testing.allocator;
    var picker = Picker.init(.request_timeout_ms, 123456, .{});
    picker.beginCustom();
    const invalid = try rows(a, .{ .selected = picker.count() - 1 }, picker, 80, 1);
    defer freeRows(a, invalid);
    try std.testing.expect(!invalid.can_confirm);
    try std.testing.expect(picker.append("234.567"));
    const valid = try rows(a, .{ .selected = picker.count() - 1 }, picker, 80, 1);
    defer freeRows(a, valid);
    try std.testing.expect(valid.can_confirm);
    const clipped = try rows(a, .{ .selected = picker.count() - 1 }, picker, 10, 1);
    defer freeRows(a, clipped);
    try std.testing.expect(!clipped.can_confirm);
    const index = try picker.submitCustom();
    const staged = try rows(a, .{ .selected = index }, picker, 80, 1);
    defer freeRows(a, staged);
    try std.testing.expect(staged.can_confirm);
    try std.testing.expect(std.mem.find(u8, staged.lines[0], "234.567 s (staged)") != null);
}
test "seconds custom input is exact atomic and strictly bounded" {
    for ([_]Key{ .command_timeout_ms, .request_timeout_ms, .task_timeout_ms }) |key| {
        var picker = Picker.init(key, 123456, .{ .command_max_timeout_ms = 86400000 });
        picker.beginCustom();
        for ([_][]const u8{ ".", ".1", "-1", "1..2", "1.0001", "1e3", "1\n", "auto", "12x", "\x1b[200~12", "１２" }) |bad| {
            try std.testing.expect(!picker.append(bad));
            try std.testing.expectEqual(@as(usize, 0), picker.input_len);
        }
        try std.testing.expect(picker.append("1."));
        try std.testing.expectError(error.InvalidValue, picker.submitCustom());
        try std.testing.expect(!picker.append(".2"));
        try std.testing.expectEqualStrings("1.", picker.input[0..picker.input_len]);
        try std.testing.expect(picker.append("001"));
        try std.testing.expect(!picker.append("0"));
        try std.testing.expectEqualStrings("1.001", picker.input[0..picker.input_len]);
        picker.backspace();
        try std.testing.expectEqualStrings("1.00", picker.input[0..picker.input_len]);
        for ([_][]const u8{ "0", "0.000", "86400.001", "4294967.296", "99999999999999" }) |bad| {
            picker.clear();
            try std.testing.expect(picker.append(bad));
            try std.testing.expectError(error.InvalidValue, picker.submitCustom());
            try std.testing.expect(picker.editing);
        }
        picker.clear();
        try std.testing.expect(!picker.append("123456789012345"));
        try std.testing.expect(picker.append("0.001"));
        const index = try picker.submitCustom();
        try std.testing.expectEqual(@as(?u32, 1), try picker.chosen(index));
        try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(picker.currentIndex()));
        picker.beginCustom();
        try std.testing.expect(picker.append("86400"));
        const maximum = try picker.submitCustom();
        try std.testing.expectEqual(@as(?u32, 86400000), try picker.chosen(maximum));
    }
    var command = Picker.init(.command_timeout_ms, 1, .{ .command_max_timeout_ms = 1500 });
    command.beginCustom();
    try std.testing.expect(command.append("1.501"));
    try std.testing.expectError(error.InvalidValue, command.submitCustom());
    command.clear();
    try std.testing.expect(command.append("1.5"));
    const index = try command.submitCustom();
    try std.testing.expectEqual(@as(?u32, 1500), try command.chosen(index));
}
test "seconds append rejection preserves all bytes and preset staging stays exact" {
    var picker = Picker.init(.request_timeout_ms, 123456, .{});
    picker.beginCustom();
    try std.testing.expect(picker.append("0000000000.001"));
    const before = picker.input;
    const length = picker.input_len;
    for ([_][]const u8{ "0", ".", "x", "\n", "12.3", "123456789012345" }) |bad| {
        try std.testing.expect(!picker.append(bad));
        try std.testing.expectEqual(length, picker.input_len);
        try std.testing.expectEqualSlices(u8, &before, &picker.input);
    }
    const staged = try picker.submitCustom();
    try std.testing.expectEqual(@as(?u32, 1), try picker.chosen(staged));
    const count_before = picker.count();
    picker.beginCustom();
    try std.testing.expect(picker.append("30.000"));
    const preset = try picker.submitCustom();
    try std.testing.expectEqual(@as(?u32, 30000), try picker.chosen(preset));
    try std.testing.expectEqual(count_before, picker.count());
    try std.testing.expectEqual(@as(?u32, 1), try picker.chosen(staged));
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(picker.currentIndex()));
}

test "seconds current and staged identities require complete rows and reject paste" {
    const a = std.testing.allocator;
    var picker = Picker.init(.request_timeout_ms, 123456, .{});
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("123.456 s (current)", try candidate(&buffer, picker, picker.currentIndex()));
    picker.beginCustom();
    try std.testing.expect(picker.append("0.001"));
    const editing = try rows(a, .{ .selected = picker.count() - 1 }, picker, 100, 12);
    defer freeRows(a, editing);
    try std.testing.expect(editing.can_confirm);
    try std.testing.expect(std.mem.find(u8, editing.lines[editing.lines.len - 1], "up to 3 decimals") != null);
    const index = try picker.submitCustom();
    try std.testing.expectEqualStrings("0.001 s (staged)", try candidate(&buffer, picker, index));
    const clipped = try rows(a, .{ .selected = index }, picker, 16, 1);
    defer freeRows(a, clipped);
    try std.testing.expect(!clipped.can_confirm);
    const pasted = try rows(a, .{ .selected = index, .pasted = true }, picker, 100, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
    const short = try rows(a, .{ .selected = index }, picker, 100, 0);
    defer freeRows(a, short);
    try std.testing.expect(!short.can_confirm);
}
fn allocationCase(a: std.mem.Allocator) !void {
    var picker = Picker.init(.request_timeout_ms, 12345, .{});
    picker.beginCustom();
    try std.testing.expect(picker.append("67.890"));
    const rendered = try rows(a, .{ .selected = picker.count() - 1 }, picker, 40, 12);
    defer freeRows(a, rendered);
}
test "value rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
