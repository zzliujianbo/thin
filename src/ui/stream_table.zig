//! Bounded streaming table compositor. Input lines are already wrapped and styled.
//! Source segments are opaque occurrences supplied by the caller, never inferred.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Alignment = enum { left, center, right };
pub const Segment = struct { start: usize, end: usize, atomic: bool = false, generated: bool = false };
/// Sanitized Writer output with renderer-owned SGR only; each line starts in
/// default style. display_width excludes SGR bytes. Cells are reset afterward.
pub const CellLine = struct { text: []const u8, display_width: usize, source_segments: []const Segment = &.{} };
pub const Occurrence = struct { column: usize, segment: Segment };
/// The kind is part of the staged snapshot: border rows have no source but
/// still advance presentation state only after the consumer acknowledges them.
pub const PhysicalRowKind = enum { top, data, middle, bottom };
pub const PhysicalRow = struct { text: []const u8, sources: []const Occurrence, kind: PhysicalRowKind = .data, output_bytes: [max_columns]usize = @splat(0) };
pub const Stage = struct { token: u64, rows: []const PhysicalRow, limited: bool };
pub const Limits = struct { lines: usize = 256, bytes: usize = 1024 * 1024, segments: usize = 4096, physical_width: usize = 512, stage_rows: usize = 256, stage_bytes: usize = 1024 * 1024 };
pub const max_columns = 32;
pub const Continuation = struct {
    columns: usize,
    ended: [max_columns]bool,
    row_open: bool,
    row_ended: bool,
    row_header: bool,
    row_had_output: bool,
    top_done: bool,
    header_done: bool,
    separator_pending: bool = false,
    finish_requested: bool,
    bottom_done: bool,
};
/// Presentation state proven by earlier physical rows. Nothing here carries
/// source: the caller retains the bytes until its own checkpoint accepts them.
/// `top_done` is the top border; `header_done` means the header separator was
/// acknowledged; `separator_pending` means the header row is complete but that
/// separator still has to be emitted before any body row.
pub const Presentation = struct {
    top_done: bool = false,
    header_done: bool = false,
    separator_pending: bool = false,
    finish_requested: bool = false,
    bottom_done: bool = false,
};
var token_source = std.atomic.Value(u64).init(1);
fn geometry(widths: []const usize, limits: Limits) Error!usize {
    if (widths.len == 0 or widths.len > max_columns or limits.physical_width == 0 or limits.stage_rows == 0 or limits.stage_bytes == 0) return error.InvalidConfiguration;
    var total: usize = 1;
    for (widths) |w| {
        if (w == 0) return error.InvalidConfiguration;
        total = std.math.add(usize, total, w) catch return error.InvalidConfiguration;
        total = std.math.add(usize, total, 3) catch return error.InvalidConfiguration;
    }
    if (total > limits.physical_width) return error.InvalidConfiguration;
    const base = std.math.add(usize, std.math.mul(usize, total, 3) catch return error.InvalidConfiguration, widths.len * 4) catch return error.InvalidConfiguration;
    if (base >= limits.stage_bytes or (limits.stage_bytes - base) / widths.len == 0) return error.InvalidConfiguration;
    return base;
}
pub const Error = Allocator.Error || error{ InvalidConfiguration, InvalidState, InvalidColumn, InvalidSource, LineTooWide, NeedDrain, StaleToken, TokenExhausted, LayoutFrozen };

/// Writer-owned SGR is presentation, not a logical UTF-8 output byte.
fn logicalBytes(styled: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < styled.len) {
        if (styled[i] == 0x1b and i + 1 < styled.len and styled[i + 1] == '[') {
            var end = i + 2;
            while (end < styled.len and (std.ascii.isDigit(styled[end]) or styled[end] == ';')) : (end += 1) {}
            if (end < styled.len and styled[end] == 'm') {
                i = end + 1;
                continue;
            }
        }
        count += 1;
        i += 1;
    }
    return count;
}

const OwnedLine = struct {
    text: []u8,
    width: usize,
    sources: []Segment,
    fn deinit(self: OwnedLine, a: Allocator) void {
        a.free(self.text);
        a.free(self.sources);
    }
};
const Column = struct { width: usize, alignment: Alignment, ended: bool = false, lines: std.ArrayList(OwnedLine) = .empty };
const PendingStage = struct {
    token: u64,
    rows: std.ArrayList(PhysicalRow) = .empty,
    counts: []usize,
    top: bool = false,
    separator: bool = false,
    finish_row: bool = false,
    data: bool = false,
    bottom: bool = false,
    /// Physical rows already emitted earlier in the SAME render pass. They are
    /// still counted as consumed so repeated peeks advance instead of repeating.
    skip_rows: usize = 0,
    fn deinit(self: *PendingStage, a: Allocator) void {
        for (self.rows.items) |row| {
            a.free(row.text);
            a.free(row.sources);
        }
        self.rows.deinit(a);
        a.free(self.counts);
    }
};

pub const Table = struct {
    a: Allocator,
    cols: []Column,
    limits: Limits,
    pending_lines: usize = 0,
    pending_bytes: usize = 0,
    pending_segments: usize = 0,
    row_open: bool = false,
    row_ended: bool = false,
    row_header: bool = false,
    row_had_output: bool = false,
    top_done: bool = false,
    header_done: bool = false,
    finish_requested: bool = false,
    bottom_done: bool = false,
    frozen: bool = false,
    /// The header row is complete but its separator border was not yet
    /// acknowledged; the next stage emits it before any body row.
    separator_pending: bool = false,
    /// Window-relative source end already displayed for the in-progress logical
    /// row. A cell line entirely inside it was written by an earlier frame and
    /// must not be repeated. Reset by beginRow unless it was restored for the
    /// row that is about to begin.
    delivered: [max_columns]usize = @splat(0),
    restored: bool = false,
    inflight: ?PendingStage = null,
    restoring: bool = false,
    row_base_bytes: usize,

    pub fn init(a: Allocator, widths: []const usize, alignments: []const Alignment, limits: Limits) Error!Table {
        if (widths.len == 0 or widths.len != alignments.len or limits.lines == 0 or limits.bytes == 0 or limits.segments == 0) return error.InvalidConfiguration;
        const base = try geometry(widths, limits);
        const cols = try a.alloc(Column, widths.len);
        for (cols, widths, alignments) |*c, w, alignment| c.* = .{ .width = w, .alignment = alignment };
        return .{ .a = a, .cols = cols, .limits = limits, .row_base_bytes = base };
    }
    pub fn deinit(self: *Table) void {
        if (self.inflight) |*s| s.deinit(self.a);
        for (self.cols) |*col| {
            for (col.lines.items) |line| line.deinit(self.a);
            col.lines.deinit(self.a);
        }
        self.a.free(self.cols);
        self.* = undefined;
    }
    /// Layout may change only before any physical row has been acknowledged.
    /// Existing input must fit the new widths; an outstanding stage is invalidated.
    pub fn resize(self: *Table, widths: []const usize, alignments: []const Alignment) Error!void {
        if (self.frozen) return error.LayoutFrozen;
        if (widths.len != self.cols.len or alignments.len != self.cols.len) return error.InvalidConfiguration;
        const base = try geometry(widths, self.limits);
        for (self.cols, widths) |col, width| {
            if (width == 0) return error.InvalidConfiguration;
            for (col.lines.items) |line| {
                if (line.width > width) return error.LineTooWide;
                if (line.text.len > (self.limits.stage_bytes - base) / self.cols.len) return error.InvalidConfiguration;
            }
        }
        self.abort();
        self.row_base_bytes = base;
        for (self.cols, widths, alignments) |*col, width, alignment| {
            col.width = width;
            col.alignment = alignment;
        }
    }
    /// Invalidates any stage. Pending views remain borrowed until the old table
    /// is mutated or destroyed. Rewrap them with upstream source ownership.
    pub fn continuation(self: *Table) Continuation {
        self.abort();
        var c: Continuation = .{ .columns = self.cols.len, .ended = @splat(false), .row_open = self.row_open, .row_ended = self.row_ended, .row_header = self.row_header, .row_had_output = self.row_had_output, .top_done = self.top_done, .header_done = self.header_done, .separator_pending = self.separator_pending, .finish_requested = self.finish_requested, .bottom_done = self.bottom_done };
        for (self.cols, 0..) |col, i| c.ended[i] = col.ended;
        return c;
    }
    pub fn pendingCount(self: *const Table, index: usize) Error!usize {
        if (index >= self.cols.len) return error.InvalidColumn;
        return self.cols[index].lines.items.len;
    }
    /// Renderer-facing state accessors. Column entries stay opaque.
    pub fn setAlignment(self: *Table, index: usize, alignment: Alignment) void {
        if (index < self.cols.len) self.cols[index].alignment = alignment;
    }
    pub fn rowStarted(self: *const Table) bool {
        return self.row_open;
    }
    pub fn headerDone(self: *const Table) bool {
        return self.header_done;
    }
    pub fn rowEnded(self: *const Table) bool {
        return self.row_ended;
    }
    pub fn setRowHadOutput(self: *Table, value: bool) void {
        self.row_had_output = value;
    }
    pub fn hasInflight(self: *const Table) bool {
        return self.inflight != null;
    }
    /// Restore already-acknowledged presentation state without any source. A
    /// header row is only rejected once its separator was acknowledged: a
    /// partially written header row still continues (and must not print a
    /// second top border).
    pub fn resumePresentation(self: *Table, alignments: []const c_int, p: Presentation) void {
        self.top_done = p.top_done or p.header_done;
        self.header_done = p.header_done;
        self.separator_pending = p.separator_pending and !p.header_done;
        self.finish_requested = self.finish_requested or p.finish_requested;
        self.bottom_done = p.bottom_done;
        self.frozen = self.top_done or self.header_done;
        for (self.cols, 0..) |*column, i| {
            if (i >= alignments.len) break;
            column.alignment = switch (alignments[i]) {
                2 => .center,
                3 => .right,
                else => .left,
            };
        }
    }
    /// Ends of source already displayed for the in-progress row, in the same
    /// coordinates as the incoming `CellLine` segments. A line completely
    /// inside them was written before and is not fed again.
    pub fn restoreDelivered(self: *Table, offsets: []const usize) void {
        for (&self.delivered, 0..) |*value, i| value.* = if (i < offsets.len) offsets[i] else 0;
        self.restored = true;
    }
    pub fn cellEnded(self: *const Table, index: usize) bool {
        return index < self.cols.len and self.cols[index].ended;
    }
    /// Restore already-acknowledged presentation state without any source.
    pub fn resumeHeader(self: *Table, alignments: []const c_int, header_done: bool) void {
        self.resumePresentation(alignments, .{ .top_done = header_done, .header_done = header_done });
    }
    pub fn pendingLine(self: *const Table, index: usize, offset: usize) Error!CellLine {
        if (index >= self.cols.len) return error.InvalidColumn;
        if (offset >= self.cols[index].lines.items.len) return error.InvalidState;
        const line = self.cols[index].lines.items[offset];
        return .{ .text = line.text, .display_width = line.width, .source_segments = line.sources };
    }
    /// Feed rewrapped pending lines into the new table before finishRestore.
    /// The old table remains untouched until the caller chooses to destroy it.
    pub fn initContinuation(a: Allocator, widths: []const usize, alignments: []const Alignment, limits: Limits, c: Continuation) Error!Table {
        if (widths.len != c.columns) return error.InvalidConfiguration;
        var t = try init(a, widths, alignments, limits);
        t.row_open = c.row_open;
        t.row_header = c.row_header;
        t.row_had_output = c.row_had_output;
        t.top_done = c.top_done;
        t.header_done = c.header_done;
        t.separator_pending = c.separator_pending;
        t.bottom_done = c.bottom_done;
        t.frozen = c.top_done or c.header_done;
        t.restoring = true;
        return t;
    }
    pub fn finishRestore(self: *Table, c: Continuation) Error!void {
        if (!self.restoring or c.columns != self.cols.len or c.row_open != self.row_open) return error.InvalidState;
        for (self.cols, 0..) |*col, i| col.ended = c.ended[i];
        self.row_ended = c.row_ended;
        self.finish_requested = c.finish_requested;
        self.restoring = false;
    }
    pub fn beginRow(self: *Table, header: bool) Error!void {
        if (self.restoring or self.row_open or self.finish_requested or self.bottom_done or (header and self.header_done)) return error.InvalidState;
        self.row_open = true;
        self.row_ended = false;
        self.row_header = header;
        self.row_had_output = false;
        if (!self.restored) self.delivered = @splat(0);
        self.restored = false;
        for (self.cols) |*col| col.ended = false;
    }
    /// On success owns copies of the complete line and all source occurrences.
    /// NeedDrain leaves input untouched. A line exceeding the configured absolute
    /// bounds can never fit and must be split upstream.
    pub fn feedCellLine(self: *Table, index: usize, line: CellLine) Error!void {
        if (index >= self.cols.len) return error.InvalidColumn;
        if (!self.row_open or self.row_ended or self.cols[index].ended) return error.InvalidState;
        if (line.display_width > self.cols[index].width) return error.LineTooWide;
        // A restored frame can re-render the whole logical row; drop only the
        // cell lines whose every source occurrence was already written.
        if (self.delivered[index] != 0 and line.source_segments.len != 0) {
            var displayed = true;
            for (line.source_segments) |segment| {
                if (segment.generated or segment.end > self.delivered[index]) displayed = false;
            }
            if (displayed) return;
        }
        for (line.source_segments) |seg| if (seg.end <= seg.start) {
            return error.InvalidSource;
        };
        if (line.text.len > self.limits.bytes or line.source_segments.len > self.limits.segments or line.text.len > (self.limits.stage_bytes - self.row_base_bytes) / self.cols.len) return error.InvalidConfiguration;
        if (self.pending_lines >= self.limits.lines or line.text.len > self.limits.bytes - self.pending_bytes or line.source_segments.len > self.limits.segments - self.pending_segments) return error.NeedDrain;
        const copy = try self.a.dupe(u8, line.text);
        errdefer self.a.free(copy);
        const sources = try self.a.dupe(Segment, line.source_segments);
        errdefer self.a.free(sources);
        try self.cols[index].lines.append(self.a, .{ .text = copy, .width = line.display_width, .sources = sources });
        self.pending_lines += 1;
        self.pending_bytes += copy.len;
        self.pending_segments += sources.len;
    }
    pub fn endCell(self: *Table, index: usize) Error!void {
        if (index >= self.cols.len) return error.InvalidColumn;
        if (!self.row_open or self.row_ended or self.cols[index].ended) return error.InvalidState;
        self.cols[index].ended = true;
    }
    pub fn endRow(self: *Table) Error!void {
        if (!self.row_open or self.row_ended) return error.InvalidState;
        for (self.cols) |col| if (!col.ended) {
            return error.InvalidState;
        };
        self.row_ended = true;
    }
    /// Request a bottom border after the current row has been acknowledged.
    pub fn finish(self: *Table) Error!void {
        if (self.finish_requested or self.bottom_done or (self.row_open and !self.row_ended)) return error.InvalidState;
        self.finish_requested = true;
    }
    pub fn abort(self: *Table) void {
        if (self.inflight) |*s| s.deinit(self.a);
        self.inflight = null;
    }
    fn appendSpaces(a: Allocator, out: *std.ArrayList(u8), n: usize) Allocator.Error!void {
        for (0..n) |_| try out.append(a, ' ');
    }
    fn takeSkip(s: *PendingStage) bool {
        if (s.skip_rows == 0) return false;
        s.skip_rows -= 1;
        return true;
    }
    const Border = enum { top, middle, bottom };
    fn addBorder(self: *Table, s: *PendingStage, border: Border) Allocator.Error!void {
        if (takeSkip(s)) return;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.a);
        const chars = switch (border) {
            .top => .{ "┌", "┬", "┐" },
            .middle => .{ "├", "┼", "┤" },
            .bottom => .{ "└", "┴", "┘" },
        };
        try out.appendSlice(self.a, chars[0]);
        for (self.cols, 0..) |col, i| {
            for (0..col.width + 2) |_| try out.appendSlice(self.a, "─");
            try out.appendSlice(self.a, if (i + 1 == self.cols.len) chars[2] else chars[1]);
        }
        const text = try out.toOwnedSlice(self.a);
        errdefer self.a.free(text);
        const sources = try self.a.alloc(Occurrence, 0);
        errdefer self.a.free(sources);
        try s.rows.append(self.a, .{ .text = text, .sources = sources, .kind = switch (border) {
            .top => .top,
            .middle => .middle,
            .bottom => .bottom,
        } });
    }
    fn addData(self: *Table, s: *PendingStage) Allocator.Error!void {
        const skipped = takeSkip(s);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.a);
        var sources: std.ArrayList(Occurrence) = .empty;
        errdefer sources.deinit(self.a);
        var output_bytes: [max_columns]usize = @splat(0);
        try out.appendSlice(self.a, "│");
        for (self.cols, 0..) |col, i| {
            const line: ?OwnedLine = if (s.counts[i] < col.lines.items.len) col.lines.items[s.counts[i]] else null;
            const used = if (line) |l| l.width else 0;
            const padding = col.width - used;
            const left: usize = switch (col.alignment) {
                .left => 0,
                .center => padding / 2,
                .right => padding,
            };
            try appendSpaces(self.a, &out, 1 + left);
            if (line) |l| {
                output_bytes[i] = logicalBytes(l.text);
                try out.appendSlice(self.a, l.text);
                if (std.mem.indexOfScalar(u8, l.text, 0x1b) != null) try out.appendSlice(self.a, "\x1b[0m");
                for (l.sources) |seg| try sources.append(self.a, .{ .column = i, .segment = seg });
                s.counts[i] += 1;
            }
            try appendSpaces(self.a, &out, 1 + padding - left);
            try out.appendSlice(self.a, "│");
        }
        const text = try out.toOwnedSlice(self.a);
        errdefer self.a.free(text);
        const owned_sources = try sources.toOwnedSlice(self.a);
        errdefer self.a.free(owned_sources);
        if (skipped) {
            self.a.free(text);
            self.a.free(owned_sources);
            return;
        }
        try s.rows.append(self.a, .{ .text = text, .sources = owned_sources, .output_bytes = output_bytes });
        s.data = true;
    }
    /// One active immutable snapshot. Empty stages are permitted and must be aborted.
    pub fn stage(self: *Table, requested: usize) Error!Stage {
        return self.stageAfter(0, requested);
    }
    /// Peek the physical rows that follow `already` rows of the current head
    /// state. Nothing is consumed: the caller acknowledges through `commit`.
    pub fn stageAfter(self: *Table, already: usize, requested: usize) Error!Stage {
        return self.stageInner(already, requested);
    }
    fn stageInner(self: *Table, skip: usize, requested: usize) Error!Stage {
        if (self.inflight != null or self.restoring or requested == 0) return error.InvalidState;
        if (requested > self.limits.stage_rows) return error.InvalidConfiguration;
        var per_row = self.row_base_bytes;
        for (self.cols) |col| {
            var longest: usize = 0;
            for (col.lines.items) |line| longest = @max(longest, line.text.len);
            per_row += longest;
        }
        const maxPhysicalRows = @min(requested, self.limits.stage_bytes / per_row);
        const token = token_source.fetchAdd(1, .monotonic);
        if (token == 0 or token == std.math.maxInt(u64)) return error.TokenExhausted;
        const counts = try self.a.alloc(usize, self.cols.len);
        @memset(counts, 0);
        var s: PendingStage = .{ .token = token, .counts = counts, .skip_rows = skip };
        errdefer s.deinit(self.a);
        if (!self.top_done and (self.row_open or self.finish_requested) and s.rows.items.len < maxPhysicalRows) {
            try self.addBorder(&s, .top);
            s.top = true;
        }
        // The header row was already acknowledged; its separator is the first
        // remaining physical row of this table.
        if (self.separator_pending and !self.header_done and s.rows.items.len < maxPhysicalRows) {
            try self.addBorder(&s, .middle);
            s.separator = true;
        }
        if (self.row_open) {
            while (s.rows.items.len < maxPhysicalRows) {
                var available = false;
                for (self.cols, 0..) |col, i| if (s.counts[i] < col.lines.items.len) {
                    available = true;
                    break;
                };
                if (!available) break;
                try self.addData(&s);
            }
            var exhausted = true;
            for (self.cols, 0..) |col, i| if (s.counts[i] < col.lines.items.len) {
                exhausted = false;
                break;
            };
            // A logically empty row still occupies one physical row.
            if (self.row_ended and exhausted and !self.row_had_output and !hasCounts(s.counts) and s.rows.items.len < maxPhysicalRows) try self.addData(&s);
            const has_row = self.row_had_output or s.data;
            if (self.row_ended and exhausted and has_row) {
                if (self.row_header and !self.header_done) {
                    if (s.rows.items.len < maxPhysicalRows) {
                        try self.addBorder(&s, .middle);
                        s.separator = true;
                        s.finish_row = true;
                    }
                } else s.finish_row = true;
            }
        }
        if (self.finish_requested and (!self.row_open or s.finish_row) and !self.bottom_done and s.rows.items.len < maxPhysicalRows) {
            try self.addBorder(&s, .bottom);
            s.bottom = true;
        }
        self.inflight = s;
        return .{ .token = s.token, .rows = self.inflight.?.rows.items, .limited = maxPhysicalRows < requested and s.rows.items.len == maxPhysicalRows };
    }
    /// Returns an owned occurrence list; caller frees it with the table allocator.
    /// The allocation happens before mutation, so OOM leaves the stage retryable.
    pub fn commit(self: *Table, token: u64) Error![]Occurrence {
        const s = if (self.inflight) |*p| p else return error.StaleToken;
        if (s.token != token) return error.StaleToken;
        var count: usize = 0;
        for (s.rows.items) |row| count = std.math.add(usize, count, row.sources.len) catch return error.InvalidConfiguration;
        const result = try self.a.alloc(Occurrence, count);
        var pos: usize = 0;
        for (s.rows.items) |row| {
            @memcpy(result[pos..][0..row.sources.len], row.sources);
            pos += row.sources.len;
        }
        for (self.cols, s.counts) |*col, n| {
            for (col.lines.items[0..n]) |line| {
                self.pending_lines -= 1;
                self.pending_bytes -= line.text.len;
                self.pending_segments -= line.sources.len;
                line.deinit(self.a);
            }
            const remaining = col.lines.items.len - n;
            std.mem.copyForwards(OwnedLine, col.lines.items[0..remaining], col.lines.items[n..]);
            col.lines.items.len = remaining;
        }
        if (s.rows.items.len != 0) self.frozen = true;
        if (s.top) self.top_done = true;
        if (s.separator) {
            self.header_done = true;
            self.separator_pending = false;
        }
        if (s.data) self.row_had_output = true;
        if (s.finish_row) {
            self.row_open = false;
            self.row_ended = false;
        }
        if (s.bottom) self.bottom_done = true;
        self.abort();
        return result;
    }
};
fn hasCounts(counts: []const usize) bool {
    for (counts) |n| if (n != 0) return true;
    return false;
}

fn acknowledge(t: *Table, token: u64) !void {
    const occurrences = try t.commit(token);
    t.a.free(occurrences);
}

test "styled table checkpoints count logical UTF-8 bytes not SGR or columns" {
    const a = std.testing.allocator;
    var t = try Table.init(a, &.{ 4, 4 }, &.{ .left, .left }, .{});
    defer t.deinit();
    try t.beginRow(false);
    try t.feedCellLine(0, .{ .text = "\x1b[38;2;1;2;3mA\x1b[0m", .display_width = 1 });
    try t.feedCellLine(1, .{ .text = "\x1b[31m中\x1b[0m", .display_width = 2 });
    const staged = try t.stage(2);
    try std.testing.expectEqual(PhysicalRowKind.data, staged.rows[1].kind);
    try std.testing.expectEqual(@as(usize, 1), staged.rows[1].output_bytes[0]);
    try std.testing.expectEqual(@as(usize, 3), staged.rows[1].output_bytes[1]);
    t.abort();
}

test "alignment, source occurrences and immutable inflight append" {
    const a = std.testing.allocator;
    var t = try Table.init(a, &.{ 4, 4 }, &.{ .left, .right }, .{});
    defer t.deinit();
    try t.beginRow(true);
    const seg = [_]Segment{ .{ .start = 3, .end = 8, .atomic = true }, .{ .start = 3, .end = 8, .atomic = true } };
    try t.feedCellLine(0, .{ .text = "a", .display_width = 1, .source_segments = &seg });
    try t.feedCellLine(1, .{ .text = "b", .display_width = 1 });
    const s = try t.stage(2);
    try std.testing.expectEqual(PhysicalRowKind.top, s.rows[0].kind);
    try std.testing.expectEqual(PhysicalRowKind.data, s.rows[1].kind);
    try std.testing.expectEqualStrings("│ a    │    b │", s.rows[1].text);
    try t.feedCellLine(0, .{ .text = "late", .display_width = 4 });
    const got = try t.commit(s.token);
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(got[0].segment.atomic and got[1].segment.atomic);
    try std.testing.expectEqual(@as(usize, 1), t.pending_lines);
    try t.endCell(0);
    try t.endCell(1);
    try t.endRow();
    const next = try t.stage(8);
    try std.testing.expectEqualStrings("│ late │      │", next.rows[0].text);
    try acknowledge(&t, next.token);
    try std.testing.expect(t.header_done);
}

test "bounded long cell drain, late column, abort and header not repeated" {
    const a = std.testing.allocator;
    var t = try Table.init(a, &.{ 1, 1 }, &.{ .left, .left }, .{ .lines = 1, .bytes = 16, .segments = 4 });
    defer t.deinit();
    try t.beginRow(true);
    for (0..1000) |_| {
        try t.feedCellLine(0, .{ .text = "x", .display_width = 1 });
        try std.testing.expectError(error.NeedDrain, t.feedCellLine(1, .{ .text = "y", .display_width = 1 }));
        const staged = try t.stage(2);
        const token = staged.token;
        t.abort();
        try std.testing.expectError(error.StaleToken, t.commit(token));
        const again = try t.stage(2);
        try acknowledge(&t, again.token);
        try std.testing.expectEqual(@as(usize, 0), t.pending_lines);
    }
    try t.endCell(0);
    try t.feedCellLine(1, .{ .text = "y", .display_width = 1 });
    try t.endCell(1);
    try t.endRow();
    const end = try t.stage(4);
    try std.testing.expectEqualStrings("│   │ y │", end.rows[0].text);
    try acknowledge(&t, end.token);
    try t.beginRow(false);
    try t.endCell(0);
    try t.endCell(1);
    try t.endRow();
    const body = try t.stage(4);
    try std.testing.expectEqual(@as(usize, 1), body.rows.len);
    try acknowledge(&t, body.token);
}

test "resize invalidates stage and contracts reject oversize" {
    const a = std.testing.allocator;
    var t = try Table.init(a, &.{4}, &.{.center}, .{});
    defer t.deinit();
    try t.beginRow(false);
    try t.feedCellLine(0, .{ .text = "中", .display_width = 2 });
    const s = try t.stage(2);
    const token = s.token;
    try t.resize(&.{3}, &.{.right});
    try std.testing.expectError(error.StaleToken, t.commit(token));
    try std.testing.expectError(error.LineTooWide, t.feedCellLine(0, .{ .text = "wide", .display_width = 4 }));
    const n = try t.stage(2);
    try acknowledge(&t, n.token);
    try std.testing.expectError(error.LayoutFrozen, t.resize(&.{4}, &.{.left}));
}

test "geometry limits and styled cell reset" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidConfiguration, Table.init(a, &.{std.math.maxInt(usize)}, &.{.left}, .{}));
    var t = try Table.init(a, &.{ 2, 2 }, &.{ .left, .left }, .{});
    defer t.deinit();
    try t.beginRow(false);
    try t.feedCellLine(0, .{ .text = "\x1b[31m中", .display_width = 2 });
    try t.feedCellLine(1, .{ .text = "b", .display_width = 1 });
    const s = try t.stage(2);
    try std.testing.expectEqualStrings("│ \x1b[31m中\x1b[0m │ b  │", s.rows[1].text);
    try acknowledge(&t, s.token);
}

test "continuation retains acknowledged state and pending sources" {
    const a = std.testing.allocator;
    var old = try Table.init(a, &.{4}, &.{.left}, .{});
    defer old.deinit();
    try old.beginRow(true);
    try old.feedCellLine(0, .{ .text = "a", .display_width = 1 });
    const first = try old.stage(2);
    try acknowledge(&old, first.token);
    const seg = [_]Segment{.{ .start = 10, .end = 15, .atomic = true }};
    try old.feedCellLine(0, .{ .text = "bc", .display_width = 2, .source_segments = &seg });
    try old.endCell(0);
    try old.endRow();
    const stale = try old.stage(1);
    const stale_token = stale.token;
    const c = old.continuation();
    try std.testing.expectError(error.StaleToken, old.commit(stale_token));
    const pending = try old.pendingLine(0, 0);
    var next = try Table.initContinuation(a, &.{2}, &.{.left}, .{}, c);
    defer next.deinit();
    try next.feedCellLine(0, pending);
    try next.finishRestore(c);
    const s = try next.stage(1);
    try std.testing.expectEqualStrings("│ bc │", s.rows[0].text);
    try std.testing.expectError(error.StaleToken, next.commit(stale_token));
    const ack = try next.commit(s.token);
    defer a.free(ack);
    try std.testing.expectEqual(@as(usize, 1), ack.len);
    try std.testing.expect(ack[0].segment.atomic);
    const separator = try next.stage(1);
    try acknowledge(&next, separator.token);
    try std.testing.expect(next.header_done and !next.row_open);
    try std.testing.expectEqual(@as(usize, 1), try old.pendingCount(0));
}

test "one row stages empty header without duplicate blank row" {
    const a = std.testing.allocator;
    var t = try Table.init(a, &.{1}, &.{.left}, .{});
    defer t.deinit();
    const empty = try t.stage(1);
    try std.testing.expectEqual(@as(usize, 0), empty.rows.len);
    try acknowledge(&t, empty.token);
    try t.beginRow(true);
    try t.endCell(0);
    try t.endRow();
    const top = try t.stage(1);
    try acknowledge(&t, top.token);
    const data = try t.stage(1);
    try std.testing.expectEqualStrings("│   │", data.rows[0].text);
    try acknowledge(&t, data.token);
    const sep = try t.stage(1);
    try std.testing.expectEqualStrings("├───┤", sep.rows[0].text);
    try acknowledge(&t, sep.token);
    try std.testing.expect(t.header_done and !t.row_open);
}

test "one-row border stages retry and commit for one and two columns" {
    const a = std.testing.allocator;
    const cases = [_]struct { widths: []const usize, alignments: []const Alignment, borders: [3][]const u8 }{
        .{ .widths = &.{1}, .alignments = &.{.left}, .borders = .{ "┌───┐", "├───┤", "└───┘" } },
        .{ .widths = &.{ 1, 2 }, .alignments = &.{ .left, .left }, .borders = .{ "┌───┬────┐", "├───┼────┤", "└───┴────┘" } },
    };
    for (cases) |case| {
        var t = try Table.init(a, case.widths, case.alignments, .{});
        defer t.deinit();
        try t.beginRow(true);
        for (case.widths, 0..) |_, i| try t.endCell(i);
        try t.endRow();
        for (0..2) |i| {
            const border = try t.stage(1);
            try std.testing.expectEqual(@as(usize, 1), border.rows.len);
            try std.testing.expectEqualStrings(case.borders[i], border.rows[0].text);
            t.abort();
            const retry = try t.stage(1);
            try std.testing.expectEqualStrings(case.borders[i], retry.rows[0].text);
            try acknowledge(&t, retry.token);
            if (i == 0) {
                const data = try t.stage(1);
                try std.testing.expectEqual(@as(usize, 1), data.rows.len);
                try acknowledge(&t, data.token);
            }
        }
        try t.finish();
        const bottom = try t.stage(1);
        try std.testing.expectEqualStrings(case.borders[2], bottom.rows[0].text);
        t.abort();
        const retry = try t.stage(1);
        try std.testing.expectEqualStrings(case.borders[2], retry.rows[0].text);
        try acknowledge(&t, retry.token);
        const done = try t.stage(1);
        try std.testing.expectEqual(@as(usize, 0), done.rows.len);
        t.abort();
    }
}

test "stage allocation failure preserves pending source and layout" {
    const a = std.testing.allocator;
    var f = std.testing.FailingAllocator.init(a, .{});
    var t = try Table.init(f.allocator(), &.{ 2, 2 }, &.{ .left, .right }, .{});
    defer t.deinit();
    try t.beginRow(false);
    const seg = [_]Segment{.{ .start = 1, .end = 3, .atomic = true }};
    try t.feedCellLine(0, .{ .text = "a", .display_width = 1, .source_segments = &seg });
    try t.feedCellLine(1, .{ .text = "b", .display_width = 1, .source_segments = &seg });
    f.fail_index = f.alloc_index;
    try std.testing.expectError(error.OutOfMemory, t.stage(3));
    try std.testing.expectEqual(@as(usize, 2), t.pending_lines);
    try std.testing.expect(!t.top_done);
    f.fail_index = std.math.maxInt(usize);
    const s = try t.stage(3);
    const got = try t.commit(s.token);
    defer f.allocator().free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
}

fn aggregateFailureCase(a: Allocator) !void {
    var t = try Table.init(a, &.{ 3, 3 }, &.{ .left, .right }, .{});
    defer t.deinit();
    try t.beginRow(false);
    const segments = [_]Segment{ .{ .start = 1, .end = 2 }, .{ .start = 2, .end = 5, .atomic = true } };
    try t.feedCellLine(0, .{ .text = "abc", .display_width = 3, .source_segments = &segments });
    try t.feedCellLine(1, .{ .text = "def", .display_width = 3, .source_segments = &segments });
    const s = t.stage(3) catch |err| {
        try std.testing.expectEqual(@as(usize, 2), t.pending_lines);
        try std.testing.expect(!t.top_done and t.inflight == null);
        return err;
    };
    const ack = try t.commit(s.token);
    defer a.free(ack);
    try std.testing.expectEqual(@as(usize, 4), ack.len);
}
test "all allocation failures during layout and source aggregation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, aggregateFailureCase, .{});
}

test "allocation failure leaves owned input and stage transactional" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{});
    var t = try Table.init(failing.allocator(), &.{2}, &.{.left}, .{});
    defer t.deinit();
    try t.beginRow(false);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, t.feedCellLine(0, .{ .text = "a", .display_width = 1 }));
    try std.testing.expectEqual(@as(usize, 0), t.pending_lines);
    failing.fail_index = std.math.maxInt(usize);
    const origin = [_]Segment{.{ .start = 0, .end = 1 }};
    try t.feedCellLine(0, .{ .text = "a", .display_width = 1, .source_segments = &origin });
    const s = try t.stage(2);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, t.commit(s.token));
    try std.testing.expectEqual(@as(usize, 1), t.pending_lines);
    failing.fail_index = std.math.maxInt(usize);
    try acknowledge(&t, s.token);
}

test "presentation resume skips written header lines and defers the separator" {
    const a = std.testing.allocator;
    const first = [_]Segment{.{ .start = 2, .end = 8, .atomic = true }};
    const second = [_]Segment{.{ .start = 8, .end = 12, .atomic = true }};

    // A resumed document header does not reprint lines already written.
    var header = try Table.init(a, &.{ 6, 6 }, &.{ .left, .left }, .{});
    defer header.deinit();
    header.resumePresentation(&.{ 0, 0 }, .{ .top_done = true });
    header.restoreDelivered(&.{ 8, 8 });
    try header.beginRow(true);
    try header.feedCellLine(0, .{ .text = "abcdef", .display_width = 6, .source_segments = &first });
    try header.feedCellLine(1, .{ .text = "aaaaaa", .display_width = 6, .source_segments = &first });
    try header.feedCellLine(0, .{ .text = "ghij", .display_width = 4, .source_segments = &second });
    try header.feedCellLine(1, .{ .text = "bbbb", .display_width = 4, .source_segments = &second });
    const resumed = try header.stage(2);
    try std.testing.expectEqual(@as(usize, 1), resumed.rows.len);
    try std.testing.expectEqual(PhysicalRowKind.data, resumed.rows[0].kind);
    try std.testing.expectEqualStrings("│ ghij   │ bbbb   │", resumed.rows[0].text);
    try acknowledge(&header, resumed.token);
    try std.testing.expect(!header.headerDone());

    // The header row is complete but its separator border was not written.
    var body = try Table.init(a, &.{ 6, 6 }, &.{ .left, .left }, .{});
    defer body.deinit();
    body.resumePresentation(&.{ 0, 0 }, .{ .top_done = true, .separator_pending = true });
    try body.beginRow(false);
    try body.feedCellLine(0, .{ .text = "b", .display_width = 1 });
    try body.feedCellLine(1, .{ .text = "c", .display_width = 1 });
    try body.endCell(0);
    try body.endCell(1);
    try body.endRow();
    const stage = try body.stage(2);
    try std.testing.expectEqual(@as(usize, 2), stage.rows.len);
    try std.testing.expectEqual(PhysicalRowKind.middle, stage.rows[0].kind);
    try std.testing.expectEqualStrings("├────────┼────────┤", stage.rows[0].text);
    try std.testing.expectEqualStrings("│ b      │ c      │", stage.rows[1].text);
    body.abort();
    const retry = try body.stage(2);
    try std.testing.expectEqualStrings("├────────┼────────┤", retry.rows[0].text);
    const got = try body.commit(retry.token);
    a.free(got);
    try std.testing.expect(body.headerDone());
    const done = try body.stage(2);
    try std.testing.expectEqual(@as(usize, 0), done.rows.len);
    body.abort();
}
