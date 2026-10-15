//! Small, local-only slash suggestions. No command execution or terminal I/O.
const std = @import("std");
const text = @import("text.zig");

pub const Command = enum { model, auth, compact };
pub const Item = struct { command: Command, value: []const u8, arguments: []const u8 = "", description: []const u8 };
pub const items = [_]Item{
    .{ .command = .model, .value = "/model", .arguments = "[exact-id|--refresh]", .description = "Select model" },
    .{ .command = .auth, .value = "/login", .description = "Configure provider" },
    .{ .command = .compact, .value = "/compact", .description = "Compact conversation" },
};

pub const Matches = struct {
    commands: [items.len]Command = undefined,
    len: usize = 0,
};

pub fn info(command: Command) Item {
    return items[@backingInt(command)];
}

/// Only a single slash token at the beginning of the editor is a command.
/// Pasted text and a cursor inside the token never open the menu.
pub fn suggestions(value: []const u8, cursor: usize, pasted: bool) Matches {
    var result: Matches = .{};
    if (pasted or value.len == 0 or cursor != value.len or value[0] != '/') return result;
    for (value[1..]) |byte| if (!std.ascii.isAlphabetic(byte)) return result;
    for (items) |item| {
        var at: usize = 1;
        for (item.value[1..]) |byte| {
            if (at < value.len and std.ascii.toLower(byte) == std.ascii.toLower(value[at])) at += 1;
        }
        if (at != value.len) continue;
        result.commands[result.len] = item.command;
        result.len += 1;
    }
    return result;
}

/// Rendered dropdown lines; owned by the caller (freed like model_picker rows).
pub const Rows = struct {
    lines: []const []const u8,
    selected_line: ?usize = null,
    can_confirm: bool = false,
};

/// Only candidate rows, capped at ten and `max_rows`; each row is clipped
/// to `columns` display cells so a narrow terminal cannot overflow.
pub fn rows(a: std.mem.Allocator, matches: Matches, selected: usize, columns: usize, max_rows: usize) !Rows {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| a.free(line);
        lines.deinit(a);
    }
    if (max_rows == 0 or matches.len == 0) return .{ .lines = try lines.toOwnedSlice(a) };
    const selected_ = @min(selected, matches.len - 1);
    const count = @min(matches.len, @min(max_rows, 10));
    const start = @min(selected_ -| (count / 2), matches.len - count);
    for (matches.commands[start .. start + count], start..) |command, index| {
        const item = info(command);
        const raw = try std.fmt.allocPrint(a, "{s}{s}{s}{s}  {s}", .{ if (index == selected_) "> " else "  ", item.value, if (item.arguments.len != 0) " " else "", item.arguments, item.description });
        defer a.free(raw);
        const line = try singleLine(a, raw, columns);
        errdefer a.free(line);
        try lines.append(a, line);
    }
    return .{
        .lines = try lines.toOwnedSlice(a),
        .selected_line = if (count != 0) selected_ - start else null,
        .can_confirm = count != 0 and columns >= 2 + info(matches.commands[selected_]).value.len,
    };
}

/// Width-clipped single line without terminal escape sequences.
fn singleLine(a: std.mem.Allocator, raw: []const u8, columns: usize) ![]const u8 {
    if (columns == 0) return a.dupe(u8, "");
    var width: usize = 0;
    var end: usize = 0;
    while (end < raw.len) {
        const cluster = text.nextCluster(raw, end, 0);
        if (width + cluster.width > columns) break;
        width += cluster.width;
        end = cluster.end;
    }
    return a.dupe(u8, raw[0..end]);
}

pub const Menu = struct {
    selected: usize = 0,
    generation: u64 = 1,
    dismissed: bool = false,

    pub fn changed(self: *Menu) void {
        self.selected = 0;
        self.dismissed = false;
        self.generation +%= 1;
    }
    pub fn dismiss(self: *Menu) void {
        self.dismissed = true;
        self.generation +%= 1;
    }
    pub fn move(self: *Menu, down: bool, count: usize) void {
        if (count == 0) return;
        self.selected = @min(self.selected, count - 1);
        self.selected = if (down) (self.selected + 1) % count else if (self.selected == 0) count - 1 else self.selected - 1;
        self.generation +%= 1;
    }
    pub fn choice(self: *const Menu, matches: Matches) ?Command {
        if (self.dismissed or matches.len == 0) return null;
        return matches.commands[@min(self.selected, matches.len - 1)];
    }
};

test "slash suggestions preserve model login compact order and support local fuzzy search" {
    const all = suggestions("/", 1, false);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqual(Command.model, all.commands[0]);
    try std.testing.expectEqual(Command.auth, all.commands[1]);
    try std.testing.expectEqual(Command.compact, all.commands[2]);
    for ([_][]const u8{ "/co", "/CPT", "/compact" }) |query| {
        const found = suggestions(query, query.len, false);
        try std.testing.expectEqual(@as(usize, 1), found.len);
        try std.testing.expectEqual(Command.compact, found.commands[0]);
    }
    for ([_][]const u8{ "/mo", "/MD", "/model" }) |query| {
        const found = suggestions(query, query.len, false);
        try std.testing.expectEqual(@as(usize, 1), found.len);
        try std.testing.expectEqual(Command.model, found.commands[0]);
    }
    const auth = suggestions("/lgn", 4, false);
    try std.testing.expectEqual(@as(usize, 1), auth.len);
    try std.testing.expectEqual(Command.auth, auth.commands[0]);
}

test "slash suggestions exclude arguments multiline prompts paste and mid-token cursor" {
    for ([_][]const u8{ "", "hello /", " /model", "/login key", "/model\n", "/unknown", "/../", "/compact now", "/压缩", "/compact1" }) |value|
        try std.testing.expectEqual(@as(usize, 0), suggestions(value, value.len, false).len);
    try std.testing.expectEqual(@as(usize, 0), suggestions("/login", 6, true).len);
    try std.testing.expectEqual(@as(usize, 0), suggestions("/model", 3, false).len);
}

test "command rows are bounded clipped and mark the selection" {
    const a = std.testing.allocator;
    const all = suggestions("/", 1, false);
    const rendered = try rows(a, all, 1, 24, 8);
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expectEqual(@as(usize, 3), rendered.lines.len);
    try std.testing.expect(rendered.can_confirm);
    try std.testing.expectEqual(@as(usize, 1), rendered.selected_line.?);
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[1], "> ") != null);
    for (rendered.lines) |line| try std.testing.expect(text.width(line) <= 24);
    const none = try rows(a, .{}, 0, 24, 8);
    defer a.free(none.lines);
    try std.testing.expectEqual(@as(usize, 0), none.lines.len);
}

test "command rows show optional arguments and descriptions" {
    const a = std.testing.allocator;
    const rendered = try rows(a, suggestions("/", 1, false), 0, 80, 8);
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expectEqualStrings("> /model [exact-id|--refresh]  Select model", rendered.lines[0]);
    try std.testing.expectEqualStrings("  /login  Configure provider", rendered.lines[1]);
    try std.testing.expectEqualStrings("  /compact  Compact conversation", rendered.lines[2]);
    try std.testing.expectEqualStrings("", info(.auth).arguments);
    try std.testing.expectEqualStrings("", info(.compact).arguments);
}

test "command confirmation needs only the complete command and keeps selection in a narrow window" {
    const a = std.testing.allocator;
    const all = suggestions("/", 1, false);
    for (all.commands[0..all.len], 0..) |command, selected| {
        const command_width = 2 + text.width(info(command).value);
        for (0..command_width + 3) |width| {
            const rendered = try rows(a, all, selected, width, 1);
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
            try std.testing.expectEqual(@as(usize, 1), rendered.lines.len);
            try std.testing.expectEqual(@as(usize, 0), rendered.selected_line.?);
            try std.testing.expect(text.width(rendered.lines[0]) <= width);
            try std.testing.expectEqual(width >= command_width, rendered.can_confirm);
            if (width == command_width) {
                try std.testing.expectEqualStrings(info(command).value, rendered.lines[0][2..]);
            }
        }
    }
    const clipped = try singleLine(a, "中a文", 4);
    defer a.free(clipped);
    try std.testing.expectEqualStrings("中a", clipped);
}

test "command rows never authorize a hidden or clipped command" {
    const a = std.testing.allocator;
    const all = suggestions("/", 1, false);
    for (0..4) |height| {
        for (0..10) |width| {
            const rendered = try rows(a, all, 1, width, height);
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
            try std.testing.expect(rendered.lines.len <= height);
            for (rendered.lines) |line| try std.testing.expect(text.width(line) <= width);
            try std.testing.expectEqual(height >= 1 and width >= 8, rendered.can_confirm);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[rendered.selected_line.?], "> /login") != null);
        }
    }
}

test "slash selection wraps and dismissal lasts until an edit" {
    var menu: Menu = .{};
    const all = suggestions("/", 1, false);
    menu.move(false, all.len);
    try std.testing.expectEqual(Command.compact, menu.choice(all).?);
    menu.move(true, all.len);
    try std.testing.expectEqual(Command.model, menu.choice(all).?);
    menu.move(true, all.len);
    try std.testing.expectEqual(Command.auth, menu.choice(all).?);
    menu.move(true, all.len);
    try std.testing.expectEqual(Command.compact, menu.choice(all).?);
    const generation = menu.generation;
    menu.dismiss();
    try std.testing.expect(menu.generation != generation and menu.choice(all) == null);
    menu.changed();
    try std.testing.expectEqual(Command.model, menu.choice(all).?);
    try std.testing.expectEqualStrings("/login", info(.auth).value);
}
