//! Bounded conservative-cluster terminal Markdown writer. emit takes sanitized
//! UTF-8; emitStyled takes renderer-owned SGR only, never provider escapes.
const std = @import("std");
const text = @import("text.zig");
const decode = @import("../util/display_text.zig").decode;
const theme = @import("theme.zig");
const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error || error{ MarkdownRenderLimit, MarkdownCellOverflow };

pub const Tone = enum { normal, heading, strong, code, inline_code, quote, link, link_url, rule, border, muted, thinking, table_header, user, success, warning, failure };
pub const Style = struct { tone: Tone = .normal, bold: bool = false, italic: bool = false, strike: bool = false, underline: bool = false };

/// Optional completion sink, default off. When set, a finished row is handed to
/// the sink instead of being appended to `Writer.lines`, so a long stream does
/// not accumulate rows. OWNERSHIP: on success the sink owns `row`; on failure
/// the WRITER still owns it and frees it, so a sink must never free a row whose
/// callback returned an error (and must not free before its own bookkeeping
/// succeeded). `src_start` is the emit-stream offset of the first source byte
/// displayed on that row (0 for synthetic-only rows). The callback must never
/// reenter the writer.
pub const RowSink = struct {
    context: *anyopaque,
    onRow: *const fn (context: *anyopaque, row: []const u8, src_start: usize, prefix: []const u8) Error!void,
};

/// Temporary translation for ONE emit: bytes [start,end) of the parser source
/// produced `emit`-stream bytes. `exact` means the emitted bytes are a
/// byte-for-byte copy of that source span (no entities/escapes/replacements),
/// so wrapped rows can be attributed per scalar. Non-exact spans are attributed
/// atomically to the first scalar of the emit.
pub const SourceMap = struct { start: usize, end: usize, exact: bool };

pub const Budget = struct {
    bytes: usize = 0,
    lines: usize = 0,
    work: usize = 0,
    max_bytes: usize = 4 * 1024 * 1024,
    max_lines: usize = 256 * 1024 + 64,
    max_work: usize = 1024 * 1024,

    pub fn step(self: *Budget, n: usize) !void {
        if (n > self.max_work -| self.work) return error.MarkdownRenderLimit;
        self.work += n;
    }
    fn append(self: *Budget, n: usize) !void {
        if (n > self.max_bytes -| self.bytes) return error.MarkdownRenderLimit;
        self.bytes += n;
    }
    fn finish(self: *Budget) !void {
        if (self.lines >= self.max_lines) return error.MarkdownRenderLimit;
        self.lines += 1;
    }
};

pub const Writer = struct {
    a: Allocator,
    columns: usize,
    ansi: bool,
    base: Tone = .normal,
    style: Style = .{},
    prefix: []const u8 = "",
    continuation: ?[]const u8 = null,
    lines: std.ArrayList([]const u8) = .empty,
    line: std.ArrayList(u8) = .empty,
    /// Committed columns only. Use hasContent(), not col, for emptiness.
    col: usize = 0,
    row_started: bool = false,
    budget: ?*Budget = null,
    pending: std.ArrayList(u8) = .empty,
    cluster: ?text.ClusterState = null,
    initialStyle: Style = .{},
    initial_bullet: bool = false,
    pending_body: bool = false,
    pending_prefix_start: ?usize = null,
    row_body: bool = false,
    row_prefix: []const u8 = "",
    /// Completed-row sink; see RowSink. Default off keeps the old behavior.
    sink: ?RowSink = null,
    /// Number of rows successfully delivered or retained.
    completed_rows: usize = 0,
    /// Bytes of emit/emitStyled source consumed so far (emit-stream position).
    pos: usize = 0,
    /// Emit-stream offset of the first source byte on the current physical row.
    row_src_start: usize = 0,
    /// Emit-stream offset associated with the pending cluster's first byte.
    /// Prefix staging reports the position of the glyph that owns the row.
    pending_src_start: usize = 0,
    /// Provenance of the current physical row in PARSER-SOURCE coordinates,
    /// deliberately independent of `pos` (emit-stream bytes). A renderer marks
    /// source spans before emitting transformed text; synthetic bytes (table
    /// borders, list markers, math delimiters, owned attribute copies) are not
    /// marked, so a row with no mark is synthetic. Reset after each finished
    /// row; a wrapped row keeps only the span of the glyphs it actually owns.
    origin_start: usize = std.math.maxInt(usize),
    origin_end: usize = 0,
    origin_synthetic: bool = true,
    map: ?SourceMap = null,
    /// Parser-source origin of the glyph currently staged in `pending`.
    pending_origin_start: usize = 0,
    pending_origin_end: usize = 0,
    pending_origin_synthetic: bool = true,

    pub fn hasContent(self: *const Writer) bool {
        return self.row_started or self.cluster != null or self.col != 0 or self.line.items.len != 0;
    }

    /// Record a source span for the current row. min/max accumulation keeps a
    /// wrapped row's provenance conservative; it never invents a source byte.
    pub fn markSource(self: *Writer, start: usize, end: usize) void {
        if (end <= start) return;
        self.origin_start = @min(self.origin_start, start);
        self.origin_end = @max(self.origin_end, end);
        self.origin_synthetic = false;
    }

    /// Emit bytes that are a transformed view of `[start,end)` parser source.
    pub fn emitSourced(self: *Writer, s: []const u8, start: usize, end: usize, exact: bool) !void {
        const prior = self.map;
        self.map = .{ .start = start, .end = end, .exact = exact };
        defer self.map = prior;
        try self.emit(s);
    }

    /// Emit bytes that have no parser-source origin (renderer-generated).
    pub fn emitSynthetic(self: *Writer, s: []const u8) !void {
        try self.emit(s);
    }

    pub fn dropPending(self: *Writer) void {
        self.pending.clearRetainingCapacity();
        self.cluster = null;
        self.pending_body = false;
        self.pending_prefix_start = null;
        self.initial_bullet = false;
    }

    /// Discard an unfinished row only; completed rows and budget are retained.
    pub fn discardLine(self: *Writer) void {
        self.dropPending();
        self.line.clearRetainingCapacity();
        self.col = 0;
        self.row_started = false;
        self.row_body = false;
        self.row_prefix = "";
    }

    /// Also useful with non-arena allocators, including fault-injection tests.
    pub fn deinit(self: *Writer) void {
        self.pending.deinit(self.a);
        self.line.deinit(self.a);
        for (self.lines.items) |line| self.a.free(line);
        self.lines.deinit(self.a);
    }

    fn put(self: *Writer, dest: *std.ArrayList(u8), s: []const u8) !void {
        if (self.budget) |budget| try budget.append(s.len);
        try dest.appendSlice(self.a, s);
    }
    fn append(self: *Writer, s: []const u8) !void {
        try self.put(&self.line, s);
    }
    fn byte(self: *Writer, value: u8) !void {
        if (self.budget) |budget| try budget.append(1);
        try self.line.append(self.a, value);
    }

    fn styleInto(self: *Writer, dest: *std.ArrayList(u8), style: Style) !void {
        if (!self.ansi) return;
        try self.put(dest, theme.reset);
        const tone = if (style.tone == .normal) self.base else style.tone;
        try self.put(dest, switch (tone) {
            .normal => "",
            .heading => theme.heading,
            .strong => theme.strong,
            .code => theme.code,
            .inline_code => theme.inline_code,
            .quote => theme.quote,
            .link => theme.link,
            .link_url, .rule => theme.md_dim,
            .border => "\x1b[39m",
            .muted => theme.muted,
            .thinking => theme.thinking,
            .table_header => theme.table_header,
            .user => theme.user,
            .success => theme.success,
            .warning => theme.warning,
            .failure => theme.failure,
        });
        if (style.bold) try self.put(dest, "\x1b[1m");
        if (style.italic) try self.put(dest, "\x1b[3m");
        if (style.strike) try self.put(dest, "\x1b[9m");
        if (style.underline) try self.put(dest, "\x1b[4m");
    }

    pub fn sgr(self: *Writer) !void {
        try self.styleInto(if (self.cluster != null) &self.pending else &self.line, self.style);
    }
    pub fn setStyle(self: *Writer, style: Style) !void {
        self.style = style;
        if (self.row_started or self.cluster != null) try self.sgr();
    }

    /// Stage a decoded glyph. SGR is never passed to ClusterState. Each glyph
    /// is decoded once, accepted once, and copied at most twice (stage/commit).
    fn stage(self: *Writer, cp: u21, raw: []const u8, prefix_at: ?usize, bullet: bool, capacity: ?usize, origin: ?SourceMap) !bool {
        if (self.cluster) |state| {
            var next = state;
            if (next.accept(cp)) {
                if (capacity) |cap| if (next.width > cap -| self.col) {
                    self.dropPending();
                    return false;
                };
                try self.put(&self.pending, raw);
                self.cluster = next;
                if (origin) |o| {
                    if (self.pending_origin_synthetic) {
                        self.pending_origin_start = o.start;
                        self.pending_origin_end = o.end;
                        self.pending_origin_synthetic = false;
                    } else {
                        self.pending_origin_start = @min(self.pending_origin_start, o.start);
                        self.pending_origin_end = @max(self.pending_origin_end, o.end);
                    }
                }
                if (prefix_at == null) self.pending_body = true;
                return true;
            }
            try self.flushPending(capacity == null);
        }
        var state = text.ClusterState.init(cp, self.col);
        const leading = state.width == 0 and self.col == 0;
        if (leading) {
            // The visible dotted-circle base participates in width accounting:
            // a leading FE0F may promote it to two columns, or a ZWJ join it.
            state = text.ClusterState.init('◌', self.col);
            _ = state.accept(cp);
        }
        if (capacity) |cap| if (state.width > cap -| self.col) return false;
        self.initialStyle = self.style;
        self.initial_bullet = bullet;
        self.pending_prefix_start = prefix_at;
        self.pending_body = prefix_at == null;
        self.pending_src_start = self.pos;
        self.pending_origin_synthetic = true;
        if (origin) |o| {
            self.pending_origin_synthetic = false;
            self.pending_origin_start = o.start;
            self.pending_origin_end = o.end;
        }
        // Set state before allocation: discardLine/deinit can always recover.
        self.cluster = state;
        if (bullet and self.ansi) try self.put(&self.pending, theme.bullet);
        if (leading) try self.put(&self.pending, "◌");
        try self.put(&self.pending, raw);
        return true;
    }

    /// A physical row starts exactly once. Reserve the full detached cluster
    /// on wrap; a prefix must never make an otherwise valid glyph become '?'.
    fn startReserved(self: *Writer, reserve: usize, replay: ?[]const u8) !void {
        if (self.row_started) return;
        self.row_started = true;
        self.row_src_start = self.pos;
        const prefix = replay orelse self.prefix;
        self.row_prefix = prefix;
        var bullet_start: ?usize = null;
        if (replay == null) {
            if (self.ansi) if (self.continuation) |continuation| {
                var common: usize = 0;
                while (common < @min(prefix.len, continuation.len) and prefix[common] == continuation[common]) : (common += 1) {}
                if (common < prefix.len) bullet_start = common;
            };
            if (self.continuation) |continuation| {
                self.prefix = continuation;
                self.continuation = null;
            }
        }
        try self.styleInto(&self.line, self.style);
        if (self.budget) |budget| try budget.step(prefix.len);
        const cap = self.columns -| @min(reserve, self.columns);
        var i: usize = 0;
        while (i < prefix.len) {
            const r = decode(prefix, i);
            if (r.cp == 10 or r.cp == 9) break;
            if (!try self.stage(r.cp, prefix[i..r.end], i, if (bullet_start) |b| i >= b else false, cap, null)) break;
            i = r.end;
        }
        // Reset bullet color without introducing a cluster boundary.
        if (bullet_start != null) try self.sgr();
    }

    fn flushPending(self: *Writer, wrap: bool) Error!void {
        const state = self.cluster orelse return;
        // Detach before starting a new row: its prefix uses the SAME staging
        // machinery but must not overwrite the cluster being moved.
        var payload = self.pending;
        self.pending = .empty;
        const first_style = self.initialStyle;
        const first_bullet = self.initial_bullet;
        const body = self.pending_body;
        const prefix_start = self.pending_prefix_start;
        const source = self.pending_src_start;
        const glyph_origin_start = self.pending_origin_start;
        const glyph_origin_end = self.pending_origin_end;
        const glyph_synthetic = self.pending_origin_synthetic;
        self.cluster = null;
        self.pending_body = false;
        self.pending_prefix_start = null;
        defer {
            // Ordinary flushes used to allocate/free staging storage for every
            // glyph on every redraw. Keep it for the next cluster. Wrapping
            // can recursively stage a prefix; that buffer has independent
            // ownership and wins if it exists, including failure paths.
            if (self.pending.capacity == 0) {
                payload.clearRetainingCapacity();
                self.pending = payload;
            } else payload.deinit(self.a);
        }
        var moved = false;
        const needed = if (state.width == 0 and self.col == 0) 1 else state.width;
        if (wrap and needed > self.columns -| self.col and self.col != 0) {
            if (!self.row_body) {
                // Do not emit a prefix-only row. Rebuild a shorter prefix on
                // this physical row, excluding a prefix glyph in the payload.
                const replay = self.row_prefix[0 .. prefix_start orelse self.row_prefix.len];
                self.line.clearRetainingCapacity();
                self.col = 0;
                self.row_started = false;
                try self.startReserved(@max(1, state.width), replay);
            } else {
                try self.finishRow();
                try self.startReserved(@max(1, state.width), null);
            }
            // The moved cluster carries its own source span onto the new row:
            // the previous row's origin reset must not swallow it.
            self.row_src_start = source;
            try self.flushPending(false);
            moved = true;
        }
        if (!glyph_synthetic) self.markSource(glyph_origin_start, glyph_origin_end);
        if (moved) {
            try self.styleInto(&self.line, first_style);
            if (first_bullet and self.ansi) try self.append(theme.bullet);
        }
        if (state.width > self.columns -| self.col) {
            // Explicit conservative oversized-cluster policy, not a repair for
            // ordinary glyphs made too wide by an optional prefix.
            try self.byte('?');
            self.col += 1;
            try self.styleInto(&self.line, self.style);
        } else {
            if (state.width == 0 and self.col == 0) {
                try self.append("◌");
                self.col = 1;
            }
            // Payload was already charged before staging, never charge twice.
            try self.line.appendSlice(self.a, payload.items);
            self.col += state.width;
            if (moved) try self.styleInto(&self.line, self.style);
        }
        self.row_body = self.row_body or body;
    }

    /// No call back into finish/flush: detaching a cluster can finish a row.
    fn finishRow(self: *Writer) !void {
        if (self.budget) |budget| try budget.finish();
        if (self.ansi) {
            if (self.base == .user) {
                for (self.col..self.columns) |_| try self.byte(' ');
            }
            try self.append(theme.reset);
        }
        const start = if (self.row_started) self.row_src_start else self.pos;
        const row_prefix = self.row_prefix;
        const owned = try self.line.toOwnedSlice(self.a);
        errdefer self.a.free(owned);
        if (self.sink) |sink| try sink.onRow(sink.context, owned, start, row_prefix) else try self.lines.append(self.a, owned);
        self.completed_rows +|= 1;
        self.col = 0;
        self.row_started = false;
        self.row_body = false;
        self.row_prefix = "";
        self.origin_start = std.math.maxInt(usize);
        self.origin_end = 0;
        self.origin_synthetic = true;
    }

    pub fn finish(self: *Writer) !void {
        if (self.ansi and self.base == .user and !self.row_started) try self.startReserved(1, null);
        try self.flushPending(true);
        try self.finishRow();
    }
    pub fn boundary(self: *Writer) !void {
        if (self.hasContent()) try self.finish();
    }

    fn tab(self: *Writer, origin: ?SourceMap) !void {
        try self.flushPending(true);
        try self.startReserved(1, null);
        try self.flushPending(true);
        var n = 4 - self.col % 4;
        if (n > self.columns -| self.col and self.col != 0) {
            if (!self.row_body) {
                const replay = self.row_prefix;
                self.line.clearRetainingCapacity();
                self.col = 0;
                self.row_started = false;
                try self.startReserved(@min(4, self.columns), replay);
            } else {
                try self.finishRow();
                try self.startReserved(@min(4, self.columns), null);
            }
            try self.flushPending(false);
            n = 4 - self.col % 4;
        }
        if (origin) |o| self.markSource(o.start, o.end);
        if (n > self.columns -| self.col) {
            try self.byte('?');
            self.col += 1;
        } else {
            for (0..n) |_| try self.byte(' ');
            self.col += n;
        }
        self.row_body = true;
    }

    /// Processes whole UTF-8 scalars only. A scalar may exceed the byte budget
    /// by at most three bytes; LF or tab may complete two rows, exceeding the
    /// row budget by at most one. A zero budget makes no changes. Exhaustion
    /// is not EOF and does not flush the pending cluster.
    pub fn emitBounded(self: *Writer, s: []const u8, byte_budget: usize, row_budget: usize) !usize {
        const initial_rows = self.completed_rows;
        var i: usize = 0;
        while (i < s.len and i < byte_budget and self.completed_rows -| initial_rows < row_budget) {
            const r = decode(s, i);
            if (self.budget) |budget| {
                if (r.end - i > budget.max_work -| budget.work) break;
                try budget.step(r.end - i);
            }
            const origin: ?SourceMap = if (self.map) |map| blk: {
                if (map.exact and map.end >= map.start and map.end - map.start == s.len)
                    break :blk .{ .start = map.start + i, .end = map.start + r.end, .exact = true };
                break :blk map;
            } else null;
            if (r.cp == 10) {
                if (self.ansi and self.base == .user and !self.row_started) try self.startReserved(1, null);
                try self.flushPending(true);
                if (origin) |o| self.markSource(o.start, o.end);
                try self.finishRow();
            } else if (r.cp == 9) {
                try self.tab(origin);
            } else {
                try self.startReserved(1, null);
                _ = try self.stage(r.cp, s[i..r.end], null, false, null, origin);
            }
            self.pos += r.end - i;
            i = r.end;
        }
        return i;
    }

    /// The source interval describes the entire supplied slice, not the
    /// budget-limited portion. For an exact continuation advance `start` by
    /// the returned byte count; for an atomic mapping retain the same span.
    pub fn emitSourcedBounded(self: *Writer, s: []const u8, start: usize, end: usize, exact: bool, byte_budget: usize, row_budget: usize) !usize {
        const prior = self.map;
        self.map = .{ .start = start, .end = end, .exact = exact };
        defer self.map = prior;
        return self.emitBounded(s, byte_budget, row_budget);
    }

    /// Unbounded convenience wrapper. Budget exhaustion is surfaced as an error
    /// only after bounded progress: bytes already consumed stay staged and are
    /// never silently dropped.
    pub fn emit(self: *Writer, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            const n = try self.emitBounded(s[i..], std.math.maxInt(usize), std.math.maxInt(usize));
            if (n == 0) {
                if (self.budget) |budget| try budget.step(1);
                return error.MarkdownRenderLimit;
            }
            i += n;
        }
    }

    /// Atomic pre-rendered cell boundary. Width traversal is charged once;
    /// unlike emit it cannot extend the preceding pending cluster.
    pub fn emitStyled(self: *Writer, s: []const u8) !void {
        if (self.budget) |budget| try budget.step(s.len);
        try self.flushPending(true);
        const width = displayWidth(s);
        try self.startReserved(@max(1, width), null);
        try self.flushPending(true);
        if (width > self.columns -| self.col) return error.MarkdownCellOverflow;
        try self.append(s);
        self.col += width;
        self.row_body = self.row_body or s.len != 0;
        self.pos += s.len;
        try self.sgr();
    }
};

pub fn displayWidth(s: []const u8) usize {
    return text.styledWidth(s);
}
