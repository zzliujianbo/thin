//! Bounded local value staging. No persistence, network, ACK or generation ownership.
//! The owner uses its existing provider.Picker, rejects paste, and advances that
//! menu's generation on every edit/transition. submitCustom requires a new frame
//! ACK before a second Enter may call chosen and persist the staged choice.
const std = @import("std");
const cfg = @import("../core/config.zig");
const text = @import("text.zig");
const provider = @import("provider_picker.zig");
pub const Key = @import("../core/settings.zig").Key;
pub const Rows = @import("settings_menu.zig").Rows;
pub const max_digits = 10;

pub const Picker = struct {
    key: Key,
    current: ?u32,
    editing: bool = false,
    limits: cfg.Limits,
    // Six presets (including Auto), a preserved current value and one stage.
    values: [8]?u32 = @splat(null),
    values_len: usize = 0,
    staged_index: ?usize = null,
    input: [max_digits]u8 = @splat(0),
    input_len: usize = 0,

    pub fn init(key: Key, current: ?u32, limits: cfg.Limits) Picker {
        var result: Picker = .{ .key = key, .current = current, .limits = limits };
        if (key == .compaction_enabled) return result; // Boolean stays in the parent.
        if (key == .max_output_tokens) result.add(null);
        const presets: []const u32 = switch (key) {
            .max_output_tokens => &.{ 4096, 8192, 16384, 32768, 65536 },
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
    /// digit-only text cannot itself prove whether bytes came from a paste.
    pub fn append(self: *Picker, bytes: []const u8) bool {
        if (!self.editing or bytes.len == 0 or bytes.len > max_digits - self.input_len) return false;
        for (bytes) |byte| if (byte < '0' or byte > '9') return false;
        @memcpy(self.input[self.input_len..][0..bytes.len], bytes);
        self.input_len += bytes.len;
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
        if (self.input_len == 0) return error.InvalidValue;
        const n = std.fmt.parseInt(u32, self.input[0..self.input_len], 10) catch return error.InvalidValue;
        try self.validate(n);
        return n;
    }
    fn validate(self: Picker, n: ?u32) !void {
        if (self.key == .compaction_enabled) return error.InvalidKey;
        const value = n orelse return if (self.key == .max_output_tokens) {} else error.InvalidValue;
        if (value == 0) return error.InvalidValue;
        const maximum: u32 = switch (self.key) {
            .command_timeout_ms => self.limits.command_max_timeout_ms,
            .request_timeout_ms, .task_timeout_ms => 86400000,
            .decision_timeout_ms => 3600000,
            .max_output_tokens => 1024 * 1024,
            .compaction_enabled => unreachable,
        };
        if (value > maximum) return error.InvalidValue;
        if (self.key == .max_output_tokens) if (self.limits.summary_tokens) |summary| {
            if (value < summary) return error.InvalidValue;
        };
    }
};

fn unit(key: Key) []const u8 {
    return if (key == .max_output_tokens) "tokens" else "ms";
}
fn candidate(buffer: *[96]u8, picker: Picker, index: usize) ![]const u8 {
    if (picker.isCustom(index)) {
        if (picker.editing) return std.fmt.bufPrint(buffer, "Custom: {s}_ {s}", .{ picker.input[0..picker.input_len], unit(picker.key) });
        return std.fmt.bufPrint(buffer, "Custom ({s})...", .{unit(picker.key)});
    }
    const n = picker.values[index];
    const marker = if (n == picker.current) " (current)" else if (picker.staged_index == index) " (staged)" else "";
    if (n) |v| return std.fmt.bufPrint(buffer, "{d} {s}{s}", .{ v, unit(picker.key), marker });
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ if (picker.key == .max_output_tokens) "Auto" else "Unset (invalid)", marker });
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
    } else if (self.isCustom(selected)) self.key != .compaction_enabled else blk: {
        _ = self.chosen(selected) catch break :blk false;
        break :blk true;
    };
    if (max_rows > out.items.len) try appendLine(a, &out, if (self.editing)
        "Positive decimal only, at most 10 digits. Enter stages; next Enter saves."
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
    picker.beginCustom();
    try std.testing.expect(picker.append("234567"));
    try std.testing.expectError(error.Editing, picker.chosen(current_index));
    const staged_index = try picker.submitCustom();
    try std.testing.expect(!picker.editing);
    try std.testing.expectEqual(@as(?u32, 123456), picker.current);
    try std.testing.expectEqual(@as(?u32, 234567), try picker.chosen(staged_index));
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(current_index));
    try std.testing.expectEqual(count_before + 1, picker.count());
    picker.beginCustom();
    try std.testing.expect(picker.append("345678"));
    try std.testing.expectEqual(staged_index, try picker.submitCustom());
    try std.testing.expectEqual(@as(?u32, 345678), try picker.chosen(staged_index));
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(current_index));
    try std.testing.expectError(error.CustomChoice, picker.chosen(picker.count() - 1));
    try std.testing.expectError(error.InvalidIndex, picker.chosen(picker.count()));
}
test "custom input is atomic bounded decimal and checked positive u32" {
    var picker = Picker.init(.request_timeout_ms, 300000, .{});
    try std.testing.expect(!picker.append("12"));
    picker.beginCustom();
    try std.testing.expectError(error.InvalidValue, picker.submitCustom());
    for ([_][]const u8{ "auto", "-1", "1\n", "12x", "\x1b[200~12", "１２" }) |bad| {
        try std.testing.expect(!picker.append(bad));
        try std.testing.expectEqual(@as(usize, 0), picker.input_len);
    }
    try std.testing.expect(!picker.append("12345678901"));
    try std.testing.expect(picker.append("4294967296"));
    try std.testing.expect(!picker.append("1"));
    try std.testing.expectEqualStrings("4294967296", picker.input[0..picker.input_len]);
    try std.testing.expectError(error.InvalidValue, picker.submitCustom());
    try std.testing.expect(picker.editing);
    picker.backspace();
    try std.testing.expectEqualStrings("429496729", picker.input[0..picker.input_len]);
    picker.clear();
    try std.testing.expect(picker.append("0"));
    try std.testing.expectError(error.InvalidValue, picker.submitCustom());
    picker.clear();
    try std.testing.expect(picker.append("0000000001"));
    const one_index = try picker.submitCustom();
    try std.testing.expectEqual(@as(?u32, 1), try picker.chosen(one_index));
    try std.testing.expectError(error.NotEditing, picker.submitCustom());
}
test "value constraints include auto command maximum summary and timeout bounds" {
    var output = Picker.init(.max_output_tokens, null, .{ .summary_tokens = 8192 });
    try std.testing.expectEqual(@as(?u32, null), try output.chosen(output.find(null).?));
    try std.testing.expect(output.find(4096) == null);
    output.beginCustom();
    try std.testing.expect(output.append("8191"));
    try std.testing.expectError(error.InvalidValue, output.submitCustom());
    output.clear();
    try std.testing.expect(output.append("8192"));
    const summary_index = try output.submitCustom();
    try std.testing.expectEqual(@as(?u32, 8192), try output.chosen(summary_index));
    output.beginCustom();
    try std.testing.expect(output.append("1048577"));
    try std.testing.expectError(error.InvalidValue, output.submitCustom());
    output.clear();
    try std.testing.expect(output.append("1048576"));
    const maximum_index = try output.submitCustom();
    try std.testing.expectEqual(@as(?u32, 1048576), try output.chosen(maximum_index));
    const legacy = Picker.init(.max_output_tokens, 4096, .{ .summary_tokens = 8192 });
    try std.testing.expectEqual(@as(?u32, 4096), legacy.values[legacy.currentIndex()]);
    try std.testing.expectError(error.InvalidValue, legacy.chosen(legacy.currentIndex()));
    const command = Picker.init(.command_timeout_ms, 123, .{ .command_max_timeout_ms = 1000 });
    try std.testing.expectError(error.InvalidValue, command.validate(1001));
    try command.validate(1000);
    try std.testing.expectEqual(@as(?u32, 123), try command.chosen(command.find(123).?));
    for ([_]Key{ .request_timeout_ms, .task_timeout_ms, .decision_timeout_ms }) |key| {
        const picker = Picker.init(key, 300000, .{});
        const maximum: u32 = if (key == .decision_timeout_ms) 3600000 else 86400000;
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
    try std.testing.expect(picker.append("234567"));
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
    try std.testing.expect(std.mem.find(u8, staged.lines[0], "234567 ms (staged)") != null);
}
fn allocationCase(a: std.mem.Allocator) !void {
    var picker = Picker.init(.max_output_tokens, 12345, .{});
    picker.beginCustom();
    try std.testing.expect(picker.append("67890"));
    const rendered = try rows(a, .{ .selected = picker.count() - 1 }, picker, 40, 12);
    defer freeRows(a, rendered);
}
test "value rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
