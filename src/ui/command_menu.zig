//! Small, local-only slash suggestions. No command execution or terminal I/O.
const std = @import("std");
const text = @import("text.zig");

pub const Command = enum { model, auth, compact, settings, sessions, cd, attach, detach, close, @"resume", exit };
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
    .{ .command = .@"resume", .value = "/resume", .arguments = "[id]", .description = "Resume saved session" },
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
    // Rows are built from static single-line command metadata (no tabs).
    return a.dupe(u8, raw[0..text.fitBytes(raw, columns)]);
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
