//! Bounded soft-wrap viewport over a sanitized display copy; raw input is untouched.
const std = @import("std");
const text = @import("text.zig");
const clean = @import("../util/display_text.zig");

pub const max_rows: usize = 8;
const Stop = enum { soft, hard, end };
const Segment = struct { start: usize, end: usize, cells: usize, stop: Stop };

const Iterator = struct {
    bytes: []const u8,
    width: usize,
    pos: usize = 0,
    finished: bool = false,

    fn next(self: *Iterator) ?Segment {
        if (self.finished) return null;
        const start = self.pos;
        var cells: usize = 0;
        while (self.pos < self.bytes.len) {
            if (self.bytes[self.pos] == '\n') {
                const end = self.pos;
                self.pos += 1;
                return .{ .start = start, .end = end, .cells = cells, .stop = .hard };
            }
            const cluster = text.nextCluster(self.bytes, self.pos, cells);
            const width = if (cluster.width > self.width) 1 else cluster.width;
            if (width > 0 and cells + width > self.width)
                return .{ .start = start, .end = self.pos, .cells = cells, .stop = .soft };
            cells += width;
            self.pos = cluster.end;
        }
        self.finished = cells < self.width;
        return .{ .start = start, .end = self.pos, .cells = cells, .stop = if (self.finished) .end else .soft };
    }
};

pub const Layout = struct {
    lines: []const []const u8,
    cursor_row: usize,
    cursor_column: usize,
    total_rows: usize,

    pub fn deinit(self: Layout, a: std.mem.Allocator) void {
        for (self.lines) |line| a.free(line);
        a.free(self.lines);
    }
};

fn column(bytes: []const u8, begin: usize, end: usize, width: usize) usize {
    var at = begin;
    var cells: usize = 0;
    while (at < end) {
        const cluster = text.nextCluster(bytes, at, cells);
        if (cluster.end > end) break;
        cells += if (cluster.width > width) 1 else cluster.width;
        at = cluster.end;
    }
    return cells;
}

fn render(a: std.mem.Allocator, bytes: []const u8, segment: Segment, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var at = segment.start;
    var cells: usize = 0;
    while (at < segment.end) {
        const cluster = text.nextCluster(bytes, at, cells);
        if (cluster.width > width) {
            // Even a one-cell editor must progress without triggering native wrap.
            try out.append(a, '?');
            cells += 1;
        } else {
            try out.appendSlice(a, bytes[at..cluster.end]);
            cells += cluster.width;
        }
        at = cluster.end;
    }
    return out.toOwnedSlice(a);
}

const Position = struct { row: usize, column: usize, total: usize };

fn locate(bytes: []const u8, cursor: usize, width: usize) Position {
    var scan: Iterator = .{ .bytes = bytes, .width = width };
    var total: usize = 0;
    var caret_row: ?usize = null;
    var caret_column: usize = 0;
    while (scan.next()) |segment| {
        if (caret_row == null) {
            if (cursor >= segment.start and (cursor < segment.end or
                (cursor == segment.end and (segment.stop == .end or (segment.stop == .hard and segment.cells < width)))))
            {
                caret_row = total;
                caret_column = column(bytes, segment.start, cursor, width);
            } else if (cursor == segment.end and segment.stop == .hard and segment.cells == width) {
                caret_row = total + 1;
                caret_column = 0;
            }
        }
        total += 1;
    }
    return .{ .row = @min(caret_row orelse total - 1, total - 1), .column = caret_column, .total = total };
}

/// Two bounded scans, but allocations only for the visible (at most eight) rows.
/// Exact-width ends get an empty next row so the caret never occupies autowrap.
pub fn layout(a: std.mem.Allocator, bytes: []const u8, raw_cursor: usize, columns: usize, limit: usize) !Layout {
    const width = @max(1, columns);
    const position = locate(bytes, @min(raw_cursor, bytes.len), width);
    const row = position.row;
    const total = position.total;
    const count = @min(total, @min(max_rows, @max(1, limit)));
    const first = @min(row -| (count / 2), total - count);
    const lines = try a.alloc([]const u8, count);
    var made: usize = 0;
    errdefer {
        for (lines[0..made]) |line| a.free(line);
        a.free(lines);
    }
    var scan: Iterator = .{ .bytes = bytes, .width = width };
    var index: usize = 0;
    while (scan.next()) |segment| : (index += 1) {
        if (index < first) continue;
        if (made == count) break;
        lines[made] = try render(a, bytes, segment, width);
        made += 1;
    }
    std.debug.assert(made == count);
    return .{ .lines = lines, .cursor_row = row - first, .cursor_column = position.column, .total_rows = total };
}

pub const Movement = struct { cursor: usize, preferred_column: usize };

/// Build the same sanitized/tab-expanded display as the composer, with stops
/// only at original grapheme boundaries. Never move into a tab/emoji/UTF8 byte.
pub fn moveVertical(a: std.mem.Allocator, raw: []const u8, cursor: usize, columns: usize, forward: bool, preferred: ?usize) !Movement {
    if (raw.len > 65536) return error.InputTooLong;
    const Offset = struct { raw: usize, display: usize };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var stops: std.ArrayList(Offset) = .empty;
    defer stops.deinit(a);
    var at: usize = 0;
    var display_cursor: usize = 0;
    while (at < raw.len) {
        try stops.append(a, .{ .raw = at, .display = bytes.items.len });
        if (at <= cursor) display_cursor = bytes.items.len;
        const cluster = text.nextCluster(raw, at, 0);
        while (at < cluster.end) {
            const rune = clean.decode(raw, at);
            at = rune.end;
            if (rune.cp == 13 and at < raw.len and raw[at] == 10) continue;
            const cp = clean.displayCodepoint(rune.cp);
            if (cp == '\t') {
                try bytes.appendSlice(a, "    ");
            } else {
                var encoded: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &encoded) catch unreachable;
                try bytes.appendSlice(a, encoded[0..n]);
            }
        }
    }
    try stops.append(a, .{ .raw = raw.len, .display = bytes.items.len });
    if (cursor >= raw.len) display_cursor = bytes.items.len;
    const width = @max(1, columns);
    const position = locate(bytes.items, display_cursor, width);
    const goal = preferred orelse position.column;
    const target = if (forward) @min(position.row + 1, position.total - 1) else position.row -| 1;
    if (target == position.row) return .{ .cursor = cursor, .preferred_column = goal };
    var scan: Iterator = .{ .bytes = bytes.items, .width = width };
    var index: usize = 0;
    const segment = while (scan.next()) |candidate| : (index += 1) {
        if (index == target) break candidate;
    } else unreachable;
    var best: ?usize = null;
    var stop: usize = 0;
    at = segment.start;
    var cells: usize = 0;
    while (true) {
        while (stop < stops.items.len and stops.items[stop].display < at) stop += 1;
        const fits = at < segment.end or (at == segment.end and (segment.stop == .end or (segment.stop == .hard and cells < width)));
        if (fits and cells <= goal) {
            while (stop < stops.items.len and stops.items[stop].display == at) : (stop += 1) best = stops.items[stop].raw;
        }
        if (at == segment.end) break;
        const cluster = text.nextCluster(bytes.items, at, cells);
        cells += if (cluster.width > width) 1 else cluster.width;
        at = cluster.end;
    }
    // A tab can occupy an entire narrow intermediate row, but the raw cursor
    // cannot split it. Skip that row toward the nearest original boundary.
    if (best == null) {
        if (forward) {
            for (stops.items) |offset| {
                if (offset.display >= segment.end) {
                    best = offset.raw;
                    break;
                }
            }
        } else {
            for (stops.items) |offset| {
                if (offset.display >= segment.start) break;
                best = offset.raw;
            }
        }
    }
    return .{ .cursor = best orelse cursor, .preferred_column = goal };
}

fn verticalAllocationScenario(a: std.mem.Allocator) !void {
    _ = try moveVertical(a, "abc\t界\n🙂xyz", "abc\t界\n🙂xyz".len, 4, false, null);
}

test "composer vertical mapping cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, verticalAllocationScenario, .{});
}

test "composer vertical movement follows visual rows and preserves a goal column" {
    const a = std.testing.allocator;
    const up = try moveVertical(a, "abcdefghijkl", 10, 4, false, null);
    try std.testing.expectEqual(@as(usize, 6), up.cursor);
    const down = try moveVertical(a, "abcdefghijkl", up.cursor, 4, true, up.preferred_column);
    try std.testing.expectEqual(@as(usize, 10), down.cursor);
    const short = try moveVertical(a, "abcd\nx\nabcdef", 11, 8, false, 3);
    try std.testing.expectEqual(@as(usize, 6), short.cursor);
    const restored = try moveVertical(a, "abcd\nx\nabcdef", short.cursor, 8, true, short.preferred_column);
    try std.testing.expectEqual(@as(usize, 10), restored.cursor);
    const top = try moveVertical(a, "abcdef", 2, 4, false, null);
    try std.testing.expectEqual(@as(usize, 2), top.cursor);
}

test "composer vertical mapping respects tabs CJK and joined emoji" {
    try text.initLocale();
    const a = std.testing.allocator;
    const raw = "a\t界\n🙂abc";
    const up = try moveVertical(a, raw, raw.len, 8, false, null);
    try std.testing.expectEqual(@as(usize, "a\t".len), up.cursor);
    const down = try moveVertical(a, raw, up.cursor, 8, true, up.preferred_column);
    try std.testing.expectEqual(raw.len, down.cursor);
    const joined = "👩‍💻x\n👩‍💻y";
    const moved = try moveVertical(a, joined, joined.len, 8, false, null);
    try std.testing.expectEqual(@as(usize, "👩‍💻x".len), moved.cursor);
    const narrow = try moveVertical(a, "a\tb", 2, 1, false, null);
    try std.testing.expectEqual(@as(usize, 1), narrow.cursor);
    const narrow_down = try moveVertical(a, "a\tb", narrow.cursor, 1, true, narrow.preferred_column);
    try std.testing.expectEqual(@as(usize, 2), narrow_down.cursor);
}

test "composer soft wraps and puts exact-width caret on the next row" {
    const a = std.testing.allocator;
    const wrapped = try layout(a, "abcdef", 6, 4, 8);
    defer wrapped.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("abcd", wrapped.lines[0]);
    try std.testing.expectEqualStrings("ef", wrapped.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), wrapped.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), wrapped.cursor_column);
    const exact = try layout(a, "abcd", 4, 4, 8);
    defer exact.deinit(a);
    try std.testing.expectEqualStrings("", exact.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), exact.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), exact.cursor_column);
}

test "composer newline caret and CJK clusters retain raw bytes" {
    try text.initLocale();
    const a = std.testing.allocator;
    const value = try layout(a, "ab\n\ncd\n", 7, 4, 8);
    defer value.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), value.lines.len);
    try std.testing.expectEqualStrings("", value.lines[3]);
    const wide = try layout(a, "世界a", "世界a".len, 4, 8);
    defer wide.deinit(a);
    try std.testing.expectEqualStrings("世界", wide.lines[0]);
    try std.testing.expectEqualStrings("a", wide.lines[1]);
    const narrow = try layout(a, "世a", "世a".len, 1, 8);
    defer narrow.deinit(a);
    try std.testing.expectEqualStrings("?", narrow.lines[0]);
    const boundary = try layout(a, "abcd\nx", 4, 4, 8);
    defer boundary.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), boundary.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), boundary.cursor_column);
}

test "composer emoji clusters and caret boundaries never split a glyph" {
    try text.initLocale();
    const a = std.testing.allocator;
    const emoji = try layout(a, "a🙂b", "a🙂b".len, 3, 8);
    defer emoji.deinit(a);
    try std.testing.expectEqualStrings("a🙂", emoji.lines[0]);
    try std.testing.expectEqualStrings("b", emoji.lines[1]);
    const boundary = try layout(a, "a🙂b", "a🙂".len, 3, 8);
    defer boundary.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), boundary.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), boundary.cursor_column);
    // Preserve text.zig's existing conservative SUM width for ZWJ clusters.
    const joined = try layout(a, "👩‍💻x", "👩‍💻x".len, text.width("👩‍💻"), 8);
    defer joined.deinit(a);
    try std.testing.expectEqualStrings("👩‍💻", joined.lines[0]);
    try std.testing.expectEqualStrings("x", joined.lines[1]);
    const narrow = try layout(a, "👩‍💻x", "👩‍💻x".len, 2, 8);
    defer narrow.deinit(a);
    try std.testing.expectEqualStrings("?x", narrow.lines[0]);
}

test "composer viewport follows a middle cursor and bounds long input allocations" {
    const a = std.testing.allocator;
    const middle = try layout(a, "abcdefghijklmnopqrst", 5, 4, 2);
    defer middle.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), middle.lines.len);
    try std.testing.expect(middle.cursor_row < middle.lines.len and middle.cursor_column < 4);
    const bytes = try a.alloc(u8, 65536);
    defer a.free(bytes);
    @memset(bytes, 'a');
    const long = try layout(a, bytes, bytes.len, 8, 999);
    defer long.deinit(a);
    try std.testing.expectEqual(max_rows, long.lines.len);
    try std.testing.expectEqual(@as(usize, 8193), long.total_rows);
    try std.testing.expectEqual(@as(usize, 7), long.cursor_row);
    try std.testing.expectEqual(@as(usize, 65536), bytes.len);
}

fn allocationCase(a: std.mem.Allocator) !void {
    const value = try layout(a, "abcdefghijklmno", 7, 3, 4);
    defer value.deinit(a);
}

test "composer viewport cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
