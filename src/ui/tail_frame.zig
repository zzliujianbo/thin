//! Owned, acknowledged live-tail bytes. No rendering or terminal policy lives here.
//! The caller publishes a snapshot only after its complete frame has been written.
const std = @import("std");

const max_rows = 200;
const max_bytes = 4 * 1024 * 1024;

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const []const u8,
    cursor_suffix: []const u8,
    full: []const u8,

    /// `cursor_offset` precedes the trusted final cursor suffix. Rows are complete
    /// styled payloads, separated (not terminated) by CRLF. This is deliberately
    /// not a tokenizer or sanitizer: only structured UI-generated rows belong here.
    pub fn capture(a: std.mem.Allocator, raw: []const u8, expected_rows: usize, cursor_offset: usize) !?Snapshot {
        if (expected_rows == 0 or expected_rows > max_rows or raw.len > max_bytes) return null;
        if (cursor_offset > raw.len) return error.InvalidTailFrame;
        var count: usize = 0;
        var check = std.mem.splitSequence(u8, raw[0..cursor_offset], "\r\n");
        while (check.next() != null) {
            count += 1;
            if (count > expected_rows) return error.InvalidTailFrame;
        }
        if (count != expected_rows) return error.InvalidTailFrame;

        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = try arena.allocator().dupe(u8, raw);
        const rows = try arena.allocator().alloc([]const u8, expected_rows);
        var split = std.mem.splitSequence(u8, owned[0..cursor_offset], "\r\n");
        for (rows) |*row| row.* = split.next().?;
        return .{ .arena = arena, .rows = rows, .cursor_suffix = owned[cursor_offset..], .full = owned };
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Entry: row 0, column 0; equal dimensions and a valid ACK; no committed
    /// transcript. Exit: final row with the caller's cursor suffix applied.
    /// Uses only CR and bounded relative downward motion, never line feeds.
    pub fn emitDiff(self: *const Snapshot, writer: *std.Io.Writer, previous: *const Snapshot) !void {
        if (self.rows.len == 0 or self.rows.len > max_rows or self.rows.len != previous.rows.len)
            return error.InvalidTailFrame;
        var current: usize = 0;
        for (self.rows, previous.rows, 0..) |row, old, i| {
            if (std.mem.eql(u8, row, old)) continue;
            try writer.writeAll("\r");
            if (i > current) try writer.print("\x1b[{d}B", .{i - current});
            try writer.writeAll(row);
            current = i;
        }
        const last = self.rows.len - 1;
        if (last > current) try writer.print("\x1b[{d}B", .{last - current});
        try writer.writeAll(self.cursor_suffix);
    }
};

const suffix = "\r\x1b[3C\x1b[?25h";
const stable = "\x1b[0m\x1b[2Kstable table\x1b[0m";
const footer_a = "\x1b[0m\x1b[2Kfooter A\x1b[0m";
const footer_b = "\x1b[0m\x1b[2Kfooter B\x1b[0m";

fn fixture(a: std.mem.Allocator, rows: []const []const u8) !Snapshot {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (rows, 0..) |row, i| {
        if (i != 0) try out.writer.writeAll("\r\n");
        try out.writer.writeAll(row);
    }
    const offset = out.written().len;
    try out.writer.writeAll(suffix);
    return (try Snapshot.capture(a, out.written(), rows.len, offset)).?;
}

fn expectDiff(old_rows: []const []const u8, new_rows: []const []const u8, expected: []const u8) !void {
    var old = try fixture(std.testing.allocator, old_rows);
    defer old.deinit();
    var new = try fixture(std.testing.allocator, new_rows);
    defer new.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitDiff(&out.writer, &old);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "capture owns full bytes, rows and suffix independently of mutable input" {
    var raw = (stable ++ "\r\n" ++ footer_a ++ suffix).*;
    var snap = (try Snapshot.capture(std.testing.allocator, &raw, 2, raw.len - suffix.len)).?;
    defer snap.deinit();
    @memset(&raw, 'x');
    try std.testing.expectEqualStrings(stable, snap.rows[0]);
    try std.testing.expectEqualStrings(footer_a, snap.rows[1]);
    try std.testing.expectEqualStrings(suffix, snap.cursor_suffix);
    try std.testing.expectEqualStrings(stable ++ "\r\n" ++ footer_a ++ suffix, snap.full);
}

test "identical rows emit navigation and cursor only, no EL or payload" {
    try expectDiff(&.{ stable, stable, footer_a }, &.{ stable, stable, footer_a }, "\x1b[2B" ++ suffix);
    try expectDiff(&.{stable}, &.{stable}, suffix);
}

test "cursor-only movement leaves identical styled rows untouched" {
    var old = try fixture(std.testing.allocator, &.{ stable, footer_a });
    defer old.deinit();
    const moved_suffix = "\r\x1b[1C\x1b[?25h";
    const raw = stable ++ "\r\n" ++ footer_a ++ moved_suffix;
    var new = (try Snapshot.capture(std.testing.allocator, raw, 2, raw.len - moved_suffix.len)).?;
    defer new.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitDiff(&out.writer, &old);
    try std.testing.expectEqualStrings("\x1b[1B" ++ moved_suffix, out.written());
}

test "footer-only diff writes one EL and no stable table text" {
    try expectDiff(&.{ stable, stable, footer_a }, &.{ stable, stable, footer_b }, "\r\x1b[2B" ++ footer_b ++ suffix);
}

test "style-only and shorter changes replace exact complete styled row" {
    const red = "\x1b[0m\x1b[2K\x1b[31mlong text\x1b[0m";
    const blue = "\x1b[0m\x1b[2K\x1b[34mlong text\x1b[0m";
    const short = "\x1b[0m\x1b[2Kx\x1b[0m";
    try expectDiff(&.{red}, &.{blue}, "\r" ++ blue ++ suffix);
    try expectDiff(&.{blue}, &.{short}, "\r" ++ short ++ suffix);
}

test "monotonic relative navigation has no CRLF, CUP, ED or scrolling" {
    try expectDiff(&.{ footer_a, stable, footer_a, stable, stable }, &.{ footer_b, stable, footer_b, stable, stable }, "\r" ++ footer_b ++ "\r\x1b[2B" ++ footer_b ++ "\x1b[2B" ++ suffix);
    try expectDiff(&.{ stable, footer_a, stable, footer_a }, &.{ stable, footer_b, stable, footer_b }, "\r\x1b[1B" ++ footer_b ++ "\r\x1b[2B" ++ footer_b ++ suffix);
}

test "capture rejects mismatched count and invalid cursor offset" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidTailFrame, Snapshot.capture(a, "a\r\nb", 1, 4));
    try std.testing.expectError(error.InvalidTailFrame, Snapshot.capture(a, "a", 2, 1));
    try std.testing.expectError(error.InvalidTailFrame, Snapshot.capture(a, "a", 1, 2));
}

test "capture bounds return null without allocation; exact bounds accepted" {
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect((try Snapshot.capture(fail.allocator(), "", 0, 0)) == null);
    try std.testing.expect((try Snapshot.capture(fail.allocator(), "", 201, 0)) == null);
    const raw = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(raw);
    @memset(raw, 'x');
    try std.testing.expect((try Snapshot.capture(fail.allocator(), raw, 1, raw.len)) == null);
    var snap = (try Snapshot.capture(std.testing.allocator, raw[0..max_bytes], 1, max_bytes)).?;
    defer snap.deinit();
    try std.testing.expectEqual(max_bytes, snap.full.len);
    var rows: [max_rows][]const u8 = @splat(stable);
    var bounded = try fixture(std.testing.allocator, &rows);
    defer bounded.deinit();
    try std.testing.expectEqual(max_rows, bounded.rows.len);
}

test "diff rejects unequal or out of bounds heights before writing" {
    var one = try fixture(std.testing.allocator, &.{stable});
    defer one.deinit();
    var two = try fixture(std.testing.allocator, &.{ stable, stable });
    defer two.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidTailFrame, one.emitDiff(&out.writer, &two));
    const saved = one.rows;
    one.rows = &.{};
    try std.testing.expectError(error.InvalidTailFrame, one.emitDiff(&out.writer, &one));
    var excessive: [201][]const u8 = @splat("");
    one.rows = &excessive;
    try std.testing.expectError(error.InvalidTailFrame, one.emitDiff(&out.writer, &one));
    one.rows = saved;
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

fn allocationScenario(a: std.mem.Allocator) !void {
    // Enough bytes that allocating the row descriptors also exercises arena growth.
    var raw: [16384]u8 = @splat('x');
    for (0..199) |i| {
        raw[i * 2] = '\r';
        raw[i * 2 + 1] = '\n';
    }
    var snap = (try Snapshot.capture(a, &raw, 200, raw.len)).?;
    defer snap.deinit();
    try std.testing.expectEqual(@as(usize, 200), snap.rows.len);
    try std.testing.expectEqualStrings(&raw, snap.full);
}

test "exhaustive capture allocation failures leak no bytes" {
    // Disable optional arena backing resize so replayed allocation counts stay
    // deterministic; production allocation behavior remains unchanged.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationScenario, .{});
}
