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
