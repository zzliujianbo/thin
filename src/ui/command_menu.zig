//! Small, local-only slash suggestions. No command execution or terminal I/O.
const std = @import("std");
const text = @import("text.zig");

pub const Command = enum { model, auth, compact, settings, sessions, cd, attach, detach, close, exit };
pub const Item = struct { command: Command, value: []const u8, arguments: []const u8 = "", description: []const u8 };
pub const items = [_]Item{
    .{ .command = .model, .value = "/model", .arguments = "[exact-id|--refresh]", .description = "Select model" },
    .{ .command = .auth, .value = "/login", .description = "Configure provider" },
    .{ .command = .compact, .value = "/compact", .description = "Compact conversation" },
    .{ .command = .settings, .value = "/settings", .description = "Global settings" },
    .{ .command = .sessions, .value = "/ls", .arguments = "[--running] [--page N]", .description = "List sessions" },
    .{ .command = .cd, .value = "/cd", .arguments = "<dir>", .description = "Change launcher directory" },
    .{ .command = .attach, .value = "/attach", .arguments = "[--takeover] <id>", .description = "Attach a session" },
    .{ .command = .detach, .value = "/detach", .description = "Leave session view" },
    .{ .command = .close, .value = "/close", .arguments = "[--force] <id>", .description = "Close a session" },
    .{ .command = .exit, .value = "/exit", .description = "Leave this frontend" },
};

/// Session management is only offered when a remote adapter is attached; the
/// local foreground mode never advertises commands it cannot execute.
pub fn sessionOnly(command: Command) bool {
    return switch (command) {
        .model, .auth, .compact, .settings => false,
        else => true,
    };
}

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
    var label_width: usize = 0;
    for (matches.commands[0..matches.len]) |command| {
        const item = info(command);
        const width = text.width(item.value) + if (item.arguments.len != 0) 1 + text.width(item.arguments) else @as(usize, 0);
        label_width = @max(label_width, width);
    }
    const selected_ = @min(selected, matches.len - 1);
    const count = @min(matches.len, @min(max_rows, 10));
    const start = @min(selected_ -| (count / 2), matches.len - count);
    for (matches.commands[start .. start + count], start..) |command, index| {
        const item = info(command);
        var raw: std.Io.Writer.Allocating = .init(a);
        defer raw.deinit();
        // Allocating's only write failure is allocation failure.
        raw.writer.writeAll(if (index == selected_) "> " else "  ") catch return error.OutOfMemory;
        raw.writer.writeAll(item.value) catch return error.OutOfMemory;
        if (item.arguments.len != 0) {
            raw.writer.writeByte(' ') catch return error.OutOfMemory;
            raw.writer.writeAll(item.arguments) catch return error.OutOfMemory;
        }
        const width = text.width(item.value) + if (item.arguments.len != 0) 1 + text.width(item.arguments) else @as(usize, 0);
        raw.writer.splatByteAll(' ', label_width - width + 2) catch return error.OutOfMemory;
        raw.writer.writeAll(item.description) catch return error.OutOfMemory;
        const line = try singleLine(a, raw.written(), columns);
        errdefer a.free(line);
        try lines.append(a, line);
    }
    return .{
        .lines = try lines.toOwnedSlice(a),
        .selected_line = if (count != 0) selected_ - start else null,
        .can_confirm = count != 0 and columns >= 2 + text.width(info(matches.commands[selected_]).value),
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
    try std.testing.expectEqual(items.len, all.len);
    try std.testing.expectEqual(Command.model, all.commands[0]);
    try std.testing.expectEqual(Command.auth, all.commands[1]);
    try std.testing.expectEqual(Command.compact, all.commands[2]);
    try std.testing.expectEqual(Command.settings, all.commands[3]);
    for ([_][]const u8{ "/CPT", "/compact" }) |query| {
        const found = suggestions(query, query.len, false);
        try std.testing.expectEqual(@as(usize, 1), found.len);
        try std.testing.expectEqual(Command.compact, found.commands[0]);
    }
    // /co now genuinely prefixes /compact and /close; both stay candidates.
    const co = suggestions("/co", 3, false);
    try std.testing.expectEqual(@as(usize, 2), co.len);
    try std.testing.expectEqual(Command.compact, co.commands[0]);
    try std.testing.expectEqual(Command.close, co.commands[1]);
    for ([_][]const u8{ "/mo", "/MD", "/model" }) |query| {
        const found = suggestions(query, query.len, false);
        try std.testing.expectEqual(@as(usize, 1), found.len);
        try std.testing.expectEqual(Command.model, found.commands[0]);
    }
    const auth = suggestions("/lgn", 4, false);
    try std.testing.expectEqual(@as(usize, 1), auth.len);
    try std.testing.expectEqual(Command.auth, auth.commands[0]);
    for ([_][]const u8{ "/ls", "/cd", "/attach", "/detach", "/exit" }) |query| {
        const found = suggestions(query, query.len, false);
        try std.testing.expect(found.len >= 1);
        // Subsequence matching may offer extra candidates (/ls also matches
        // /close); the exact command must always be present.
        var hit = false;
        for (found.commands[0..found.len]) |command| {
            if (std.mem.eql(u8, info(command).value, query)) hit = true;
        }
        try std.testing.expect(hit);
    }
}

test "session commands are classified apart from local commands" {
    try std.testing.expect(!sessionOnly(.model) and !sessionOnly(.auth) and !sessionOnly(.compact) and !sessionOnly(.settings));
    for ([_]Command{ .sessions, .cd, .attach, .detach, .close, .exit }) |command| try std.testing.expect(sessionOnly(command));
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
    try std.testing.expectEqual(@as(usize, 8), rendered.lines.len);
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
    try std.testing.expectEqualStrings("  /login                       Configure provider", rendered.lines[1]);
    try std.testing.expectEqualStrings("  /compact                     Compact conversation", rendered.lines[2]);
    try std.testing.expectEqualStrings("", info(.auth).arguments);
    try std.testing.expectEqualStrings("", info(.compact).arguments);
}

test "command rows clean up every allocation failure" {
    const Check = struct {
        fn render(a: std.mem.Allocator) !void {
            const rendered = try rows(a, suggestions("/", 1, false), 1, 80, 8);
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.render, .{});
}

test "command descriptions align across selections windows filters and clipping" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "/", "/o", "/lgn", "/co" }) |query| {
        const matches = suggestions(query, query.len, false);
        var label_width: usize = 0;
        for (matches.commands[0..matches.len]) |command| {
            const item = info(command);
            label_width = @max(label_width, text.width(item.value) + if (item.arguments.len != 0) 1 + text.width(item.arguments) else @as(usize, 0));
        }
        const description_column = 2 + label_width + 2;
        for (matches.commands[0..matches.len], 0..) |_, selected| {
            for ([_]usize{ 1, items.len }) |height| {
                for ([_]usize{ 0, 8, description_column - 1, description_column, description_column + 3, 80 }) |columns| {
                    const rendered = try rows(a, matches, selected, columns, height);
                    defer {
                        for (rendered.lines) |line| a.free(line);
                        a.free(rendered.lines);
                    }
                    const count = @min(matches.len, height);
                    const start = @min(selected -| (count / 2), matches.len - count);
                    try std.testing.expectEqual(selected - start, rendered.selected_line.?);
                    for (rendered.lines, start..) |line, index| {
                        const item = info(matches.commands[index]);
                        try std.testing.expectEqual(@min(columns, description_column + text.width(item.description)), text.width(line));
                        try std.testing.expect(std.mem.indexOfScalar(u8, line, '\t') == null);
                        if (columns > description_column) {
                            const visible = @min(columns - description_column, item.description.len);
                            try std.testing.expectEqualStrings(item.description[0..visible], line[description_column..]);
                            if (columns == 80) {
                                const offset = std.mem.indexOf(u8, line, item.description).?;
                                try std.testing.expectEqual(description_column, text.width(line[0..offset]));
                            }
                        }
                    }
                }
            }
        }
    }
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
    try text.initLocale();
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
    try std.testing.expectEqual(Command.exit, menu.choice(all).?);
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
