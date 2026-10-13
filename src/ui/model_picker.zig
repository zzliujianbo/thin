//! Local endpoint model metadata only. Search/confirmation sends no requests,
//! checks no credentials and never claims discovered provider capabilities.
const std = @import("std");
const cfg = @import("../core/config.zig");
const input = @import("input.zig");
const presentation = @import("presentation.zig");
const Allocator = std.mem.Allocator;

pub const Choice = struct {
    name: []const u8,
    context_tokens: u32,
    current: bool = false,
    inherited: bool = false,
};
pub const Rows = struct { lines: []const []const u8, can_confirm: bool };

pub const Picker = struct {
    query: input.Editor,
    selected: usize = 0,
    generation: u64 = 1,
    pasted: bool = false,
    allow_custom: bool = true,

    pub fn init(a: Allocator) Picker {
        return .{ .query = .{ .allocator = a } };
    }
    pub fn deinit(self: *Picker) void {
        self.query.deinit();
    }
    pub fn changed(self: *Picker) void {
        self.selected = 0;
        self.generation +%= 1;
    }
    pub fn insert(self: *Picker, bytes: []const u8, pasted: bool) !bool {
        if (bytes.len > 1024 -| self.query.bytes.items.len) return false;
        if (!try self.query.insert(bytes)) return false;
        self.pasted = self.pasted or pasted;
        self.changed();
        return true;
    }
    pub fn clear(self: *Picker) void {
        self.query.clear();
        self.pasted = false;
        self.changed();
    }
    pub fn move(self: *Picker, down: bool, count: usize) void {
        if (count == 0) return;
        self.selected = if (down) (self.selected + 1) % count else if (self.selected == 0) count - 1 else self.selected - 1;
        self.generation +%= 1;
    }
    pub fn choices(self: *const Picker, a: Allocator, current: []const u8, limit: u32, profiles: []const cfg.Model) ![]Choice {
        var result: std.ArrayList(Choice) = .empty;
        errdefer result.deinit(a);
        const query = std.mem.trim(u8, self.query.bytes.items, " \t\r\n");
        if (matches(current, query)) try result.append(a, .{ .name = current, .context_tokens = limit, .current = true });
        var exact = std.ascii.eqlIgnoreCase(current, query);
        for (profiles) |profile| {
            if (std.ascii.eqlIgnoreCase(profile.name, query)) exact = true;
            if (std.mem.eql(u8, profile.name, current) or !matches(profile.name, query)) continue;
            try result.append(a, .{ .name = profile.name, .context_tokens = profile.context_tokens });
        }
        if (self.allow_custom and query.len != 0 and !exact and manualName(query)) try result.append(a, .{ .name = query, .context_tokens = limit, .inherited = true });
        return result.toOwnedSlice(a);
    }
    pub fn rows(self: *const Picker, a: Allocator, current: []const u8, limit: u32, profiles: []const cfg.Model, columns: usize, max_rows: usize) !Rows {
        const choices_ = try self.choices(a, current, limit, profiles);
        defer a.free(choices_);
        var lines: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (lines.items) |line| a.free(line);
            lines.deinit(a);
        }
        if (max_rows == 0) return .{ .lines = try lines.toOwnedSlice(a), .can_confirm = false };
        {
            const header = try presentation.singleLine(a, if (self.allow_custom) "Select model (configured endpoint)" else "Select model (saved providers)", columns);
            errdefer a.free(header);
            try lines.append(a, header);
        }
        const count = @min(@min(8, max_rows - 1), choices_.len);
        const selected = @min(self.selected, choices_.len -| 1);
        const start = @min(selected -| (count / 2), choices_.len - count);
        for (choices_[start .. start + count], start..) |choice, index| {
            const raw = try std.fmt.allocPrint(a, "{s}{s}  ({d} tokens{s})", .{ if (index == selected) "> " else "  ", choice.name, choice.context_tokens, if (choice.current) "; current" else if (choice.inherited) "; inherited budget" else "" });
            defer a.free(raw);
            const line = try presentation.singleLine(a, raw, columns);
            errdefer a.free(line);
            try lines.append(a, line);
        }
        return .{ .lines = try lines.toOwnedSlice(a), .can_confirm = count != 0 and !self.pasted };
    }
};

pub fn manualName(name: []const u8) bool {
    if (name.len == 0 or name.len > 1024 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    return true;
}
fn matches(name: []const u8, query: []const u8) bool {
    var at: usize = 0;
    for (name) |byte| {
        if (at < query.len and std.ascii.toLower(byte) == std.ascii.toLower(query[at])) at += 1;
    }
    return at == query.len;
}

test "local picker keeps current first searches metadata and labels inherited names" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const profiles = [_]cfg.Model{
        .{ .name = "current", .context_tokens = 32768 },
        .{ .name = "fast-code", .context_tokens = 65536 },
        .{ .name = "deep-code", .context_tokens = 131072 },
    };
    const all = try picker.choices(a, "current", 32768, &profiles);
    defer a.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expect(all[0].current);
    try std.testing.expectEqualStrings("fast-code", all[1].name);
    try std.testing.expect(try picker.insert("FSC", false));
    const filtered = try picker.choices(a, "current", 32768, &profiles);
    defer a.free(filtered);
    try std.testing.expectEqualStrings("fast-code", filtered[0].name);
    try std.testing.expect(filtered[filtered.len - 1].inherited);
    picker.clear();
    try std.testing.expect(try picker.insert("FAST-CODE", false));
    const exact = try picker.choices(a, "current", 32768, &profiles);
    defer a.free(exact);
    try std.testing.expectEqual(@as(usize, 1), exact.len);
    picker.move(false, 3);
    try std.testing.expectEqual(@as(usize, 2), picker.selected);
    picker.move(true, 3);
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
}

test "named provider picker does not guess protocols for unknown custom IDs" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    picker.allow_custom = false;
    try std.testing.expect(try picker.insert("claude-unknown", false));
    const found = try picker.choices(a, "opencode-go/minimax-m2.7", 204800, &.{});
    defer a.free(found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "picker bytes rows and paste confirmation are bounded" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const full: [1024]u8 = @splat('a');
    try std.testing.expect(try picker.insert(&full, true));
    try std.testing.expect(!try picker.insert("b", false));
    const rendered = try picker.rows(a, "current", 32768, &.{}, 20, 3);
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expect(rendered.lines.len <= 3);
    try std.testing.expect(!rendered.can_confirm);
    for (rendered.lines) |line| try std.testing.expect(@import("text.zig").width(line) <= 20);
    picker.clear();
    try std.testing.expect(!picker.pasted);
    try std.testing.expect(!manualName("space name") and !manualName("\x1b[31m"));
}
