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
        const presets: []const u32 = &.{ 30000, 60000, 300000, 900000, 3600000 };
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
    }
};

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
