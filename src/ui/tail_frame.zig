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
