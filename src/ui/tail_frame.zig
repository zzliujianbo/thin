//! Owned, acknowledged live-tail bytes. No rendering or terminal policy lives here.
//! The caller publishes a snapshot only after its complete frame has been written.
const std = @import("std");

const max_rows = 200;
const max_bytes = 4 * 1024 * 1024;

/// ACK-owned visible transcript immediately above the live tail, and rows
/// temporarily borrowed into it by a popup. Never derived from canonical history:
/// these are the exact styled rows actually written at this terminal width.
pub const MenuHistory = struct {
    arena: std.heap.ArenaAllocator,
    above: []const []const u8,
    borrowed: []const []const u8,

    pub fn capture(a: std.mem.Allocator, above: []const []const u8, borrowed: []const []const u8) !MenuHistory {
        if (above.len + borrowed.len > max_rows) return error.InvalidTailFrame;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        var bytes: usize = 0;
        const groups = [_][]const []const u8{ above, borrowed };
        var owned: [2][]const []const u8 = undefined;
        for (groups, 0..) |group, i| {
            const copy = try arena.allocator().alloc([]const u8, group.len);
            for (group, copy) |line, *row| {
                if (line.len > max_bytes - bytes) return error.InvalidTailFrame;
                bytes += line.len;
                row.* = try arena.allocator().dupe(u8, line);
            }
            owned[i] = copy;
        }
        return .{ .arena = arena, .above = owned[0], .borrowed = owned[1] };
    }

    pub fn deinit(self: *MenuHistory) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

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

    const Shift = struct { start: usize, count: usize };

    fn validateDiff(self: *const Snapshot, previous: *const Snapshot) !void {
        if (self.rows.len == 0 or self.rows.len > max_rows or self.rows.len != previous.rows.len)
            return error.InvalidTailFrame;
    }

    fn motionBytes(count: usize) usize {
        if (count == 0) return 0;
        var digits: usize = 1;
        var value = count;
        while (value >= 10) : (value /= 10) digits += 1;
        return digits + 3; // ESC [ digits B (or M).
    }

    fn oldIndex(index: usize, shift: ?Shift) usize {
        return if (shift) |s| if (index >= s.start) index + s.count else index else index;
    }

    /// Exact emitted-byte cost, excluding the common cursor suffix. Both row
    /// count and total bytes are already bounded by capture; stop losing plans early.
    fn diffCost(self: *const Snapshot, previous: *const Snapshot, shift: ?Shift, limit: usize) usize {
        var current: usize = if (shift) |s| s.start else 0;
        var cost: usize = if (shift) |s| 1 + motionBytes(s.start) + motionBytes(s.count) else 0;
        for (self.rows, 0..) |row, index| {
            const old = oldIndex(index, shift);
            if (old < previous.rows.len and std.mem.eql(u8, row, previous.rows[old])) continue;
            cost += 1 + motionBytes(index - current) + row.len;
            if (cost >= limit) return cost;
            current = index;
        }
        return cost + motionBytes(self.rows.len - 1 - current);
    }

    fn chooseShift(self: *const Snapshot, previous: *const Snapshot) ?Shift {
        const first = for (self.rows, previous.rows, 0..) |row, old, index| {
            if (!std.mem.eql(u8, row, old)) break index;
        } else return null;
        var best_cost = self.diffCost(previous, null, std.math.maxInt(usize));
        var best: ?Shift = null;
        const maximum = @min(4, self.rows.len - first - 1);
        for (1..maximum + 1) |count| {
            if (!std.mem.eql(u8, self.rows[first], previous.rows[first + count])) continue;
            const candidate: Shift = .{ .start = first, .count = count };
            const cost = self.diffCost(previous, candidate, best_cost);
            if (cost < best_cost) {
                best = candidate;
                best_cost = cost;
            }
        }
        return best;
    }

    fn emitWithShift(self: *const Snapshot, writer: *std.Io.Writer, previous: *const Snapshot, shift: ?Shift) !void {
        var current: usize = 0;
        if (shift) |s| {
            try writer.writeAll("\r");
            if (s.start != 0) try writer.print("\x1b[{d}B", .{s.start});
            try writer.print("\x1b[{d}M", .{s.count});
            current = s.start;
        }
        for (self.rows, 0..) |row, index| {
            const old = oldIndex(index, shift);
            if (old < previous.rows.len and std.mem.eql(u8, row, previous.rows[old])) continue;
            try writer.writeAll("\r");
            if (index > current) try writer.print("\x1b[{d}B", .{index - current});
            try writer.writeAll(row);
            current = index;
        }
        const last = self.rows.len - 1;
        if (last > current) try writer.print("\x1b[{d}B", .{last - current});
        try writer.writeAll(self.cursor_suffix);
    }

    /// Entry: row 0, column 0; equal dimensions and a valid ACK; no committed
    /// transcript. Exit: final row with the caller's cursor suffix applied.
    /// General row diff never shifts lines or creates history.
    pub fn emitDiff(self: *const Snapshot, writer: *std.Io.Writer, previous: *const Snapshot) !void {
        try self.validateDiff(previous);
        try self.emitWithShift(writer, previous, null);
    }

    /// Entry: row 0 of a fully acknowledged tail, whose last row may or may not
    /// be the physical bottom. Prefix rows are rendered rows released into
    /// native scrollback, not messages. Compare logical indices before moving:
    /// CUD only reaches existing rows; every row beyond the old tail bottom is
    /// appended with CRLF, which creates native history only once it reaches the
    /// physical bottom. No delete-line/scroll-region authority is implied.
    pub fn emitGrowingDiff(self: *const Snapshot, writer: *std.Io.Writer, previous: *const Snapshot, prefix_rows: []const []const u8) !void {
        const limit_rows = 8192;
        const limit_bytes = 8 * 1024 * 1024;
        if (self.rows.len == 0 or self.rows.len > max_rows or
            previous.rows.len == 0 or previous.rows.len > max_rows or
            prefix_rows.len > limit_rows - self.rows.len)
            return error.InvalidTailFrame;
        const total = prefix_rows.len + self.rows.len;
        if (total < previous.rows.len) return error.InvalidTailFrame;

        // Complete preflight, including public fields of manually built snapshots.
        if (self.cursor_suffix.len > limit_bytes or previous.cursor_suffix.len > max_bytes)
            return error.InvalidTailFrame;
        var bytes = self.cursor_suffix.len;
        for ([_][]const []const u8{ prefix_rows, self.rows }) |rows| {
            for (rows) |row| {
                if (row.len > limit_bytes - bytes) return error.InvalidTailFrame;
                bytes += row.len;
            }
        }
        var old_bytes = previous.cursor_suffix.len;
        for (previous.rows) |row| {
            if (row.len > max_bytes - old_bytes) return error.InvalidTailFrame;
            old_bytes += row.len;
        }

        var current: usize = 0;
        const old_last = previous.rows.len - 1;
        for (0..total) |index| {
            const row = if (index < prefix_rows.len) prefix_rows[index] else self.rows[index - prefix_rows.len];
            if (index < previous.rows.len and std.mem.eql(u8, row, previous.rows[index])) continue;
            if (index <= old_last) {
                try writer.writeAll("\r");
                if (index > current) try writer.print("\x1b[{d}B", .{index - current});
            } else {
                if (current < old_last) {
                    try writer.writeAll("\r");
                    try writer.print("\x1b[{d}B", .{old_last - current});
                    current = old_last;
                }
                while (current < index) : (current += 1) try writer.writeAll("\r\n");
            }
            try writer.writeAll(row);
            current = index;
        }
        // Only unchanged rows within the original screen can remain unvisited.
        if (current < total - 1) {
            try writer.writeAll("\r");
            try writer.print("\x1b[{d}B", .{total - 1 - current});
        }
        try writer.writeAll(self.cursor_suffix);
    }

    /// Stronger caller contract: the entire acknowledged tail ends at the
    /// physical screen bottom, with no modal/resize/partial-frame uncertainty.
    /// DL is confined to that owned suffix. Repair moved footer and exposed rows;
    /// use it only when strictly cheaper, never IL/LF, scroll regions or history.
    pub fn emitBottomDiff(self: *const Snapshot, writer: *std.Io.Writer, previous: *const Snapshot) !void {
        try self.validateDiff(previous);
        try self.emitWithShift(writer, previous, self.chooseShift(previous));
    }
};

/// Contract a floating tail whose new footprint is shorter than the ACKed one.
/// Entry: the cursor is on the frame's last written row, at the same width and
/// geometry as the previous complete ACK, and every vacated row was inside that
/// ACKed footprint. Descent is CR+CUD only, never LF (which could scroll) or DL
/// (which could shift a foreign row below the footprint). Each visited row is
/// erased with EL after a constant CR+CUD1 descent, so exactly one owned row is
/// consumed per step; CUU then returns to the frame row. Rows below the old
/// footprint are never addressed.
pub fn emitVacatedRows(writer: *std.Io.Writer, vacated: usize) !void {
    if (vacated == 0) return;
    if (vacated > max_rows) return error.InvalidTailFrame;
    for (0..vacated) |_| try writer.writeAll("\r\x1b[1B\x1b[0K");
    try writer.print("\r\x1b[{d}A", .{vacated});
}

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

test "small upward shifts reuse exact rows and repair footer without adding history" {
    const Screen = @import("../tests/regular_screen.zig").Screen;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body: [17][]const u8 = undefined;
    for (&body, 0..) |*row, index|
        row.* = try std.fmt.allocPrint(a, "\x1b[0mrow-{d:0>2} abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz\x1b[0m\x1b[K", .{index});
    body[4] = "\x1b[0m\x1b[K";
    body[8] = body[7]; // Identical duplicates must not confuse the shift.
    body[11] = "\x1b[0m\x1b[31mstyled duplicate\x1b[0m\x1b[K";
    body[12] = "\x1b[0m\x1b[34mstyled duplicate\x1b[0m\x1b[K";
    for ([_]usize{ 1, 2, 4 }) |count| {
        var old_rows: [18][]const u8 = undefined;
        var next_rows: [18][]const u8 = undefined;
        old_rows[0] = stable;
        old_rows[1] = stable;
        next_rows[0] = stable;
        next_rows[1] = stable;
        for (0..13) |index| {
            old_rows[index + 2] = body[index];
            next_rows[index + 2] = body[index + count];
        }
        for (15..18) |index| {
            old_rows[index] = footer_a;
            next_rows[index] = footer_b;
        }
        var old = try fixture(std.testing.allocator, &old_rows);
        defer old.deinit();
        var next = try fixture(std.testing.allocator, &next_rows);
        defer next.deinit();
        const shift = next.chooseShift(&old).?;
        try std.testing.expectEqual(count, shift.count);
        var ordinary: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer ordinary.deinit();
        var reused: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer reused.deinit();
        try next.emitDiff(&ordinary.writer, &old);
        try next.emitBottomDiff(&reused.writer, &old);
        try std.testing.expectEqual(next.diffCost(&old, shift, std.math.maxInt(usize)) + suffix.len, reused.written().len);
        try std.testing.expect(reused.written().len < ordinary.written().len);
        if (count == 1) try std.testing.expect(reused.written().len * 2 < ordinary.written().len);
        try std.testing.expect(std.mem.find(u8, reused.written(), "\n") == null);
        var expected: Screen = .{};
        try expected.replay("prior\r\nabove1\r\nabove2\r\nabove3\r\nabove4\r\nabove5\r\n");
        try expected.replay(old.full);
        try expected.replay("\r\x1b[17A");
        var actual = expected;
        try expected.replay(ordinary.written());
        try actual.replay(reused.written());
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.grid), std.mem.asBytes(&actual.grid));
        try std.testing.expectEqual(expected.row, actual.row);
        try std.testing.expectEqual(expected.col, actual.col);
        try std.testing.expectEqual(@as(usize, 0), actual.history_len);
        try std.testing.expectEqual(@as(usize, 1), actual.count("prior"));
        try std.testing.expect(actual.visible("above5"));
    }
}

test "non shifts and unprofitable shifts keep the ordinary row diff" {
    const Case = struct { old: []const []const u8, next: []const []const u8 };
    for ([_]Case{
        .{ .old = &.{ "a", "b" }, .next = &.{ "b", "c" } },
        .{ .old = &.{ stable, footer_a }, .next = &.{ stable, footer_b } },
        .{ .old = &.{ stable, stable }, .next = &.{ stable, stable } },
    }) |case| {
        var old = try fixture(std.testing.allocator, case.old);
        defer old.deinit();
        var next = try fixture(std.testing.allocator, case.next);
        defer next.deinit();
        try std.testing.expect(next.chooseShift(&old) == null);
        var ordinary: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer ordinary.deinit();
        var reused: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer reused.deinit();
        try next.emitDiff(&ordinary.writer, &old);
        try next.emitBottomDiff(&reused.writer, &old);
        try std.testing.expectEqualStrings(ordinary.written(), reused.written());
    }
}

fn expectGrowing(old_rows: []const []const u8, new_rows: []const []const u8, prefix: []const []const u8, expected: []const u8) !void {
    var old = try fixture(std.testing.allocator, old_rows);
    defer old.deinit();
    var new = try fixture(std.testing.allocator, new_rows);
    defer new.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitGrowingDiff(&out.writer, &old, prefix);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "growing diff preserves old rows and uses exactly one CRLF per added row" {
    try expectGrowing(&.{ stable, footer_a }, &.{ stable, footer_a, footer_b, stable }, &.{}, "\r\x1b[1B\r\n" ++ footer_b ++ "\r\n" ++ stable ++ suffix);
    try expectGrowing(&.{stable}, &.{ stable, footer_a }, &.{}, "\r\n" ++ footer_a ++ suffix);
    try expectGrowing(&.{ stable, footer_a, stable }, &.{ footer_b, footer_a, stable, footer_b }, &.{}, "\r" ++ footer_b ++ "\r\x1b[2B\r\n" ++ footer_b ++ suffix);
}

test "growing diff shorter tail and prefixes compare original logical indices" {
    try expectGrowing(&.{ stable, footer_a, footer_b }, &.{footer_b}, &.{ stable, footer_a }, "\r\x1b[2B" ++ suffix);
    try expectGrowing(&.{ stable, footer_a, footer_b }, &.{stable}, &.{ stable, footer_b }, "\r\x1b[1B" ++ footer_b ++ "\r\x1b[1B" ++ stable ++ suffix);
    try expectGrowing(&.{ stable, footer_a, footer_b }, &.{stable}, &.{ stable, footer_a, footer_b }, "\r\x1b[2B\r\n" ++ stable ++ suffix);
}

test "growing diff style equality and current cursor suffix are exact" {
    try expectGrowing(&.{"\x1b[31mx"}, &.{"\x1b[34mx"}, &.{}, "\r\x1b[34mx" ++ suffix);
    var old = try fixture(std.testing.allocator, &.{stable});
    defer old.deinit();
    var new = try fixture(std.testing.allocator, &.{stable});
    defer new.deinit();
    new.cursor_suffix = "\r\x1b[7C";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitGrowingDiff(&out.writer, &old, &.{});
    try std.testing.expectEqualStrings(new.cursor_suffix, out.written());
}

test "growing diff rejects all invalid dimensions and byte sizes before output" {
    var old = try fixture(std.testing.allocator, &.{ stable, footer_a });
    defer old.deinit();
    var new = try fixture(std.testing.allocator, &.{stable});
    defer new.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{}));
    var prefixes: [8192][]const u8 = @splat("");
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &prefixes));
    const saved = new.rows;
    new.rows = &.{};
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    var too_many: [201][]const u8 = @splat("");
    new.rows = &too_many;
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{}));
    new.rows = saved;
    const old_saved = old.rows;
    old.rows = &.{};
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    old.rows = &too_many;
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    old.rows = old_saved;
    const large = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024 + 1);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{large}));
    new.cursor_suffix = large;
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    new.cursor_suffix = suffix;
    old.rows = &.{ large, stable };
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    old.rows = old_saved;
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "growing diff accepts exact combined row bound" {
    var old = try fixture(std.testing.allocator, &.{""});
    defer old.deinit();
    var new = try fixture(std.testing.allocator, &.{""});
    defer new.deinit();
    var prefixes: [8191][]const u8 = @splat("");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitGrowingDiff(&out.writer, &old, &prefixes);
    try std.testing.expectEqual(8191 * 2 + suffix.len, out.written().len);
    for (0..8191) |i| try std.testing.expectEqualStrings("\r\n", out.written()[i * 2 ..][0..2]);
    try std.testing.expectEqualStrings(suffix, out.written()[8191 * 2 ..]);
}

test "floating contraction erases only the vacated owned rows and restores the cursor" {
    const Screen = @import("../tests/regular_screen.zig").Screen;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitVacatedRows(&out.writer, 0);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try emitVacatedRows(&out.writer, 2);
    try std.testing.expectEqualStrings("\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[2A", out.written());
    // Descent never uses LF or DL: neither can scroll or shift foreign rows.
    try std.testing.expect(std.mem.indexOfScalar(u8, out.written(), '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[M") == null);

    // Prior shell output, a floating tail whose popup row is returned, and a
    // foreign row below the owned footprint that must never be erased.
    var screen: Screen = .{};
    try screen.replay("shell-prior\r\nabove-1\r\nold-tail-1\r\nold-tail-2\r\npopup-1\r\npopup-2\r\nforeign-row");
    try std.testing.expectEqual(@as(usize, 6), screen.row);
    // Entry is the ACKed tail top (row 2) after the composer row (row 5).
    try screen.replay("\r\x1b[1A\r\x1b[3A");
    try screen.replay("\rnew-tail-1\r\nnew-tail-2\r\nnew-tail-3");
    var contract: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer contract.deinit();
    try emitVacatedRows(&contract.writer, 1);
    try std.testing.expectEqualStrings("\r\x1b[1B\x1b[0K\r\x1b[1A", contract.written());
    try screen.replay(contract.written());
    try std.testing.expectEqual(@as(usize, 0), screen.history_len);
    try std.testing.expectEqual(@as(usize, 4), screen.row);
    try std.testing.expectEqual(@as(usize, 0), screen.col);
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[0], "shell-prior"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[1], "above-1"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[2], "new-tail-1"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[3], "new-tail-2"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[4], "new-tail-3"));
    // Exactly the vacated owned row is blank; rows below it are untouched.
    try std.testing.expectEqualStrings("", std.mem.trim(u8, &screen.grid[5], " "));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[6], "foreign-row"));
}

test "floating contraction erases every vacated owned row and keeps the foreign row below" {
    const Screen = @import("../tests/regular_screen.zig").Screen;
    // Prior shell output, an eight-row ACKed tail, then a distinct foreign
    // sentinel immediately below the owned footprint.
    var screen: Screen = .{};
    try screen.replay("shell-prior\r\nabove-1\r\nold-tail-1\r\nold-tail-2\r\nold-tail-3\r\nold-tail-4\r\nold-tail-5\r\nold-tail-6\r\nold-tail-7\r\nold-tail-8\r\nforeign-sentinel");
    try std.testing.expectEqual(@as(usize, 10), screen.row);
    const history_before = screen.history_len;
    // Entry: the tail top (row 2), as if the cursor sat on the old last row.
    try screen.replay("\r\x1b[8A");
    try screen.replay("\rnew-tail-1\r\nnew-tail-2\r\nnew-tail-3");
    try std.testing.expectEqual(@as(usize, 4), screen.row);
    var contract: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer contract.deinit();
    try emitVacatedRows(&contract.writer, 5);
    try std.testing.expectEqualStrings(
        "\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[5A",
        contract.written(),
    );
    try screen.replay(contract.written());
    // Constant CR+CUD1 per row cannot overshoot into or erase the foreign row,
    // and CUU(5) lands back on the original last new row.
    try std.testing.expectEqual(history_before, screen.history_len);
    try std.testing.expectEqual(@as(usize, 4), screen.row);
    try std.testing.expectEqual(@as(usize, 0), screen.col);
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[0], "shell-prior"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[1], "above-1"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[2], "new-tail-1"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[3], "new-tail-2"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[4], "new-tail-3"));
    // Every vacated owned row is blank; the foreign sentinel is untouched.
    for (5..10) |row_index|
        try std.testing.expectEqualStrings("", std.mem.trim(u8, &screen.grid[row_index], " "));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[10], "foreign-sentinel"));
}

test "vacated rows reject an unbounded plan before writing" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidTailFrame, emitVacatedRows(&out.writer, max_rows + 1));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try emitVacatedRows(&out.writer, max_rows);
    // Constant CR+CUD1+EL per row, then CR+CUU(max_rows).
    try std.testing.expectEqual(@as(usize, 1807), out.written().len);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.written(), '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[M") == null);
}

fn menuHistoryAllocationScenario(a: std.mem.Allocator) !void {
    var raw = "committed row".*;
    var history = try MenuHistory.capture(a, &.{&raw}, &.{stable});
    defer history.deinit();
    @memset(&raw, 'x');
    try std.testing.expectEqualStrings("committed row", history.above[0]);
    try std.testing.expectEqualStrings(stable, history.borrowed[0]);
}

test "popup history copies are independent bounded and allocation failure safe" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), menuHistoryAllocationScenario, .{});
    var rows: [201][]const u8 = @splat("");
    try std.testing.expectError(error.InvalidTailFrame, MenuHistory.capture(std.testing.allocator, &rows, &.{}));
}

test "exhaustive capture allocation failures leak no bytes" {
    // Disable optional arena backing resize so replayed allocation counts stay
    // deterministic; production allocation behavior remains unchanged.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationScenario, .{});
}
