//! Small, local-only slash suggestions. No command execution or terminal I/O.
const std = @import("std");
const text = @import("text.zig");

pub const Command = enum { model, auth };
pub const Item = struct { command: Command, value: []const u8, description: []const u8 };
pub const items = [_]Item{
    .{ .command = .model, .value = "/model", .description = "Select model" },
    .{ .command = .auth, .value = "/auth", .description = "Configure provider" },
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

/// One row per match plus a title. Bounded by `max_rows`; each row is clipped
/// to `columns` display cells so a narrow terminal cannot overflow.
pub fn rows(a: std.mem.Allocator, matches: Matches, selected: usize, columns: usize, max_rows: usize) !Rows {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| a.free(line);
        lines.deinit(a);
    }
    if (max_rows == 0 or matches.len == 0) return .{ .lines = try lines.toOwnedSlice(a) };
    {
        const header = try singleLine(a, "Commands", columns);
        errdefer a.free(header);
        try lines.append(a, header);
    }
    const selected_ = @min(selected, matches.len - 1);
    const count = @min(matches.len, max_rows - 1);
    const start = @min(selected_ -| (count / 2), matches.len - count);
    for (matches.commands[start .. start + count], start..) |command, index| {
        const item = info(command);
        const raw = try std.fmt.allocPrint(a, "{s}{s}  {s}", .{ if (index == selected_) "> " else "  ", item.value, item.description });
        defer a.free(raw);
        const line = try singleLine(a, raw, columns);
        errdefer a.free(line);
        try lines.append(a, line);
    }
    return .{
        .lines = try lines.toOwnedSlice(a),
        .selected_line = if (count != 0) 1 + selected_ - start else null,
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
        self.selected = if (down) @min(self.selected + 1, count - 1) else self.selected -| 1;
        self.generation +%= 1;
    }
    pub fn choice(self: *const Menu, matches: Matches) ?Command {
        if (self.dismissed or matches.len == 0) return null;
        return matches.commands[@min(self.selected, matches.len - 1)];
    }
};

test "slash suggestions contain only model and auth and support local fuzzy search" {
    const all = suggestions("/", 1, false);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqual(Command.model, all.commands[0]);
    try std.testing.expectEqual(Command.auth, all.commands[1]);
    for ([_][]const u8{ "/mo", "/MD", "/model" }) |query| {
        const found = suggestions(query, query.len, false);
        try std.testing.expectEqual(@as(usize, 1), found.len);
        try std.testing.expectEqual(Command.model, found.commands[0]);
    }
    const auth = suggestions("/ath", 4, false);
    try std.testing.expectEqual(@as(usize, 1), auth.len);
    try std.testing.expectEqual(Command.auth, auth.commands[0]);
}

test "slash suggestions exclude arguments multiline prompts paste and mid-token cursor" {
    for ([_][]const u8{ "", "hello /", " /model", "/auth key", "/model\n", "/unknown", "/../" }) |value|
        try std.testing.expectEqual(@as(usize, 0), suggestions(value, value.len, false).len);
    try std.testing.expectEqual(@as(usize, 0), suggestions("/auth", 5, true).len);
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
    try std.testing.expectEqual(@as(usize, 2), rendered.selected_line.?);
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[2], "> ") != null);
    for (rendered.lines) |line| try std.testing.expect(text.width(line) <= 24);
    const none = try rows(a, .{}, 0, 24, 8);
    defer a.free(none.lines);
    try std.testing.expectEqual(@as(usize, 0), none.lines.len);
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
            try std.testing.expectEqual(height >= 2 and width >= 7, rendered.can_confirm);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[rendered.selected_line.?], "> /auth") != null);
        }
    }
}

test "slash selection clamps and dismissal lasts until an edit" {
    var menu: Menu = .{};
    const all = suggestions("/", 1, false);
    menu.move(false, all.len);
    try std.testing.expectEqual(Command.model, menu.choice(all).?);
    menu.move(true, all.len);
    menu.move(true, all.len);
    try std.testing.expectEqual(Command.auth, menu.choice(all).?);
    const generation = menu.generation;
    menu.dismiss();
    try std.testing.expect(menu.generation != generation and menu.choice(all) == null);
    menu.changed();
    try std.testing.expectEqual(Command.model, menu.choice(all).?);
    try std.testing.expectEqualStrings("/auth", info(.auth).value);
}
