//! Bounded conservative-cluster terminal Markdown writer. emit takes sanitized
//! UTF-8; emitStyled takes renderer-owned SGR only, never provider escapes.
const std = @import("std");
const text = @import("text.zig");
const decode = @import("../util/display_text.zig").decode;
const theme = @import("theme.zig");
const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error || error{ MarkdownRenderLimit, MarkdownCellOverflow };

pub const Tone = enum { normal, heading, strong, code, inline_code, quote, link, link_url, rule, border, muted, table_header, user };
pub const Style = struct { tone: Tone = .normal, bold: bool = false, italic: bool = false, strike: bool = false, underline: bool = false };

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

    pub fn hasContent(self: *const Writer) bool {
        return self.row_started or self.cluster != null or self.col != 0 or self.line.items.len != 0;
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
            .table_header => theme.table_header,
            .user => theme.user,
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
    fn stage(self: *Writer, cp: u21, raw: []const u8, prefix_at: ?usize, bullet: bool, capacity: ?usize) !bool {
        if (self.cluster) |state| {
            var next = state;
            if (next.accept(cp)) {
                if (capacity) |cap| if (next.width > cap -| self.col) {
                    self.dropPending();
                    return false;
                };
                try self.put(&self.pending, raw);
                self.cluster = next;
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
            if (!try self.stage(r.cp, prefix[i..r.end], i, if (bullet_start) |b| i >= b else false, cap)) break;
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
        self.cluster = null;
        self.pending_body = false;
        self.pending_prefix_start = null;
        defer payload.deinit(self.a);
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
            try self.flushPending(false);
            moved = true;
        }
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
        const owned = try self.line.toOwnedSlice(self.a);
        errdefer self.a.free(owned);
        try self.lines.append(self.a, owned);
        self.col = 0;
        self.row_started = false;
        self.row_body = false;
        self.row_prefix = "";
    }

    pub fn finish(self: *Writer) !void {
        if (self.ansi and self.base == .user and !self.row_started) try self.startReserved(1, null);
        try self.flushPending(true);
        try self.finishRow();
    }
    pub fn boundary(self: *Writer) !void {
        if (self.hasContent()) try self.finish();
    }

    fn tab(self: *Writer) !void {
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
        if (n > self.columns -| self.col) {
            try self.byte('?');
            self.col += 1;
        } else {
            for (0..n) |_| try self.byte(' ');
            self.col += n;
        }
        self.row_body = true;
    }

    pub fn emit(self: *Writer, s: []const u8) !void {
        if (self.budget) |budget| try budget.step(s.len);
        var i: usize = 0;
        while (i < s.len) {
            const r = decode(s, i);
            if (r.cp == 10) {
                try self.finish();
            } else if (r.cp == 9) {
                try self.tab();
            } else {
                try self.startReserved(1, null);
                _ = try self.stage(r.cp, s[i..r.end], null, false, null);
            }
            i = r.end;
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
        try self.sgr();
    }
};

pub fn displayWidth(s: []const u8) usize {
    var i: usize = 0;
    var width: usize = 0;
    while (i < s.len) {
        const c = text.nextStyledCluster(s, i, width);
        width += c.width;
        i = c.end;
    }
    return width;
}

test "colored rows preserve width, card background and ANSI ownership" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 10, .ansi = true, .base = .user };
    defer w.deinit();
    try w.emit("中文 é\nnext");
    try w.finish();
    for (w.lines.items) |line| {
        try std.testing.expectEqual(@as(usize, 10), displayWidth(line));
        try std.testing.expect(std.mem.indexOf(u8, line, theme.user_background) != null);
        try std.testing.expect(std.mem.endsWith(u8, line, theme.reset));
    }
}

fn expectRows(w: *const Writer) !void {
    for (w.lines.items) |line| try std.testing.expect(displayWidth(line) <= w.columns);
}

test "deferred FE0F and style boundary wrap the complete cluster" {
    try text.initLocale();
    for ([_]bool{ false, true }) |ansi| {
        var w: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = ansi };
        defer w.deinit();
        try w.emit("x❤");
        try std.testing.expectEqual(@as(usize, 1), w.col);
        try std.testing.expect(w.hasContent());
        try w.setStyle(.{ .bold = true });
        try w.emit("️");
        try w.setStyle(.{});
        try w.boundary();
        try std.testing.expectEqual(@as(usize, 2), w.lines.items.len);
        try std.testing.expectEqual(@as(usize, 1), displayWidth(w.lines.items[0]));
        try std.testing.expectEqual(@as(usize, 2), displayWidth(w.lines.items[1]));
        try std.testing.expect(std.mem.indexOf(u8, w.lines.items[1], "❤") != null);
        try std.testing.expect(std.mem.indexOf(u8, w.lines.items[1], "?") == null);
        if (ansi) try std.testing.expect(std.mem.indexOf(u8, w.lines.items[1], "❤" ++ theme.reset ++ "\x1b[1m️") != null);
        try expectRows(&w);
    }
}

test "combining modifiers ZWJ and regional triples across callbacks" {
    try text.initLocale();
    const Case = struct { pieces: []const []const u8, expected: []const u8, width: usize };
    const cases = [_]Case{
        .{ .pieces = &.{ "e", "́" }, .expected = "é", .width = 1 },
        .{ .pieces = &.{ "👍", "🏽" }, .expected = "👍🏽", .width = text.width("👍🏽") },
        .{ .pieces = &.{ "👩", "‍", "💻" }, .expected = "👩‍💻", .width = 4 },
        .{ .pieces = &.{ "🇺", "🇸", "🇨" }, .expected = "🇺🇸🇨", .width = 6 },
    };
    for (cases) |case| for ([_]bool{ false, true }) |ansi| {
        var w: Writer = .{ .a = std.testing.allocator, .columns = 20, .ansi = ansi };
        defer w.deinit();
        for (case.pieces, 0..) |piece, i| {
            try w.setStyle(.{ .italic = i % 2 == 1 });
            try w.emit(piece);
        }
        try w.finish();
        try std.testing.expectEqual(@as(usize, 1), w.lines.items.len);
        try std.testing.expectEqual(case.width, displayWidth(w.lines.items[0]));
        if (!ansi) try std.testing.expectEqualStrings(case.expected, w.lines.items[0]);
        try expectRows(&w);
    };
}

test "first glyph style and later logical style survive moved cluster" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = true };
    defer w.deinit();
    try w.emit("x");
    try w.setStyle(.{ .italic = true });
    try w.emit("❤");
    try w.setStyle(.{ .bold = true });
    try w.emit("️");
    try w.setStyle(.{ .underline = true });
    try w.emit("z");
    try w.finish();
    try std.testing.expectEqual(@as(usize, 3), w.lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, w.lines.items[1], theme.reset ++ "\x1b[3m❤" ++ theme.reset ++ "\x1b[1m️") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.lines.items[2], "\x1b[4mz") != null);
    try expectRows(&w);
}

test "prefix shares incremental state continuation physical rows and narrow glyphs" {
    try text.initLocale();
    var joined: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = false, .prefix = "❤" };
    defer joined.deinit();
    try joined.emit("️");
    try joined.finish();
    try std.testing.expectEqual(@as(usize, 1), joined.lines.items.len);
    try std.testing.expectEqualStrings("❤️", joined.lines.items[0]);
    var tight: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = false, .prefix = "> " };
    defer tight.deinit();
    try tight.emit("中");
    try tight.finish();
    try std.testing.expectEqual(@as(usize, 1), tight.lines.items.len);
    try std.testing.expectEqualStrings("中", tight.lines.items[0]);
    var cont: Writer = .{ .a = std.testing.allocator, .columns = 4, .ansi = false, .prefix = "- ", .continuation = "  " };
    defer cont.deinit();
    try cont.emit("abc");
    try cont.finish();
    try std.testing.expectEqualStrings("- ab", cont.lines.items[0]);
    try std.testing.expectEqualStrings("  c", cont.lines.items[1]);
    var leading: Writer = .{ .a = std.testing.allocator, .columns = 1, .ansi = false };
    defer leading.deinit();
    try leading.emit("́");
    try leading.emit("x");
    try leading.finish();
    try std.testing.expectEqualStrings("◌́", leading.lines.items[0]);
    try std.testing.expectEqualStrings("x", leading.lines.items[1]);
    var oversized: Writer = .{ .a = std.testing.allocator, .columns = 1, .ansi = false };
    defer oversized.deinit();
    try oversized.emit("❤");
    try oversized.emit("️");
    try oversized.finish();
    try std.testing.expectEqualStrings("?", oversized.lines.items[0]);
    try expectRows(&joined);
    try expectRows(&tight);
    try expectRows(&cont);
    try expectRows(&leading);
}

test "tab LF emitStyled user padding and discard APIs drain pending" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 8, .ansi = false };
    defer w.deinit();
    try w.emit("e");
    try w.emit("́\tq\n");
    try std.testing.expectEqualStrings("é   q", w.lines.items[0]);
    try w.emit("❤");
    try w.emit("️");
    try w.emitStyled("\x1b[1mx\x1b[0m");
    try std.testing.expectEqual(@as(usize, 3), w.col);
    try w.finish();
    try std.testing.expectEqual(@as(usize, 3), displayWidth(w.lines.items[1]));
    try w.setStyle(.{ .bold = true });
    w.prefix = "> ";
    try w.emit("discard");
    w.discardLine();
    try std.testing.expect(!w.hasContent());
    try std.testing.expectEqual(@as(usize, 0), w.col);
    try std.testing.expect(!w.row_started);
    try std.testing.expect(w.style.bold);
    try std.testing.expectEqualStrings("> ", w.prefix);
    try std.testing.expectEqual(@as(usize, 2), w.lines.items.len);
    var prefixed_tab: Writer = .{ .a = std.testing.allocator, .columns = 5, .ansi = false, .prefix = ">>>> " };
    defer prefixed_tab.deinit();
    try prefixed_tab.emit("\t");
    try prefixed_tab.finish();
    try std.testing.expectEqual(@as(usize, 1), prefixed_tab.lines.items.len);
    try std.testing.expectEqualStrings(">   ", prefixed_tab.lines.items[0]);
    var overflow: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = false };
    defer overflow.deinit();
    try overflow.emit("❤️");
    try std.testing.expectError(error.MarkdownCellOverflow, overflow.emitStyled("x"));
    try std.testing.expectEqual(@as(usize, 2), overflow.col);
    try std.testing.expect(overflow.cluster == null);
    var card: Writer = .{ .a = std.testing.allocator, .columns = 4, .ansi = true, .base = .user };
    defer card.deinit();
    try card.emit("❤");
    try card.setStyle(.{ .bold = true });
    try card.emit("️");
    try card.finish();
    try std.testing.expectEqual(@as(usize, 4), displayWidth(card.lines.items[0]));
    try std.testing.expect(std.mem.indexOf(u8, card.lines.items[0], "️  ") != null);
}

test "budget charges staged bytes once and bounds work lines and SGR" {
    var work: Budget = .{ .max_work = 3 };
    var w: Writer = .{ .a = std.testing.allocator, .columns = 10, .ansi = false, .budget = &work };
    defer w.deinit();
    try std.testing.expectError(error.MarkdownRenderLimit, w.emit("long"));
    try std.testing.expect(!w.hasContent());
    var bytes: Budget = .{ .max_bytes = 3 };
    var b: Writer = .{ .a = std.testing.allocator, .columns = 10, .ansi = false, .budget = &bytes };
    defer b.deinit();
    try b.emit("abc");
    try b.finish();
    try std.testing.expectEqual(@as(usize, 3), bytes.bytes);
    try std.testing.expectEqual(@as(usize, 3), bytes.work);
    try std.testing.expectError(error.MarkdownRenderLimit, b.emit("d"));
    var lines: Budget = .{ .max_lines = 1 };
    var l: Writer = .{ .a = std.testing.allocator, .columns = 1, .ansi = false, .budget = &lines };
    defer l.deinit();
    try l.emit("abc");
    try std.testing.expectError(error.MarkdownRenderLimit, l.finish());
    try std.testing.expectEqual(@as(usize, 1), l.lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), lines.lines);
    var ansi_bytes: Budget = .{ .max_bytes = 1 };
    var s: Writer = .{ .a = std.testing.allocator, .columns = 10, .ansi = true, .budget = &ansi_bytes };
    defer s.deinit();
    try std.testing.expectError(error.MarkdownRenderLimit, s.emit("a"));
    try std.testing.expectEqual(@as(usize, 0), ansi_bytes.bytes);
    try std.testing.expectEqual(@as(usize, 0), s.line.items.len);
}

test "joined scalars and regional pairs move atomically at narrow boundaries" {
    try text.initLocale();
    const cases = [_][]const []const u8{
        &.{ "x👩", "‍", "💻" },
        &.{ "x👍", "🏽" },
        &.{ "x🇺", "🇸", "🇨" },
    };
    for (cases) |pieces| for ([_]bool{ false, true }) |ansi| {
        var w: Writer = .{ .a = std.testing.allocator, .columns = 4, .ansi = ansi };
        defer w.deinit();
        for (pieces) |piece| {
            try w.emit(piece);
            try w.setStyle(.{ .italic = true });
        }
        try w.finish();
        try std.testing.expectEqual(@as(usize, 1), displayWidth(w.lines.items[0]));
        try std.testing.expectEqual(@as(usize, 4), displayWidth(w.lines.items[1]));
        try expectRows(&w);
        for (w.lines.items) |line| try std.testing.expect(std.mem.indexOfScalar(u8, line, '?') == null);
    };
    var w: Writer = .{ .a = std.testing.allocator, .columns = 4, .ansi = false };
    defer w.deinit();
    try w.emit("a‍");
    try w.emit("\n");
    try w.emit("b");
    try w.finish();
    try std.testing.expectEqualStrings("a‍", w.lines.items[0]);
    try std.testing.expectEqualStrings("b", w.lines.items[1]);
}

test "many extensions are linear and style changes are generated-byte bounded" {
    try text.initLocale();
    var budget: Budget = .{};
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), budget.max_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), budget.max_work);
    var w: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = false, .budget = &budget };
    defer w.deinit();
    try w.emit("a");
    for (0..4096) |_| try w.emit("́");
    try std.testing.expectEqual(@as(usize, 0), w.col);
    try std.testing.expectEqual(@as(usize, 8193), budget.work);
    try w.finish();
    try std.testing.expectEqual(@as(usize, 8193), budget.bytes);
    try std.testing.expectEqual(@as(usize, 1), displayWidth(w.lines.items[0]));
    var capped: Budget = .{ .max_bytes = 40 };
    var styled: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = true, .budget = &capped };
    defer styled.deinit();
    try styled.emit("a");
    var exceeded = false;
    for (0..20) |_| {
        styled.setStyle(.{ .bold = true }) catch |err| {
            try std.testing.expectEqual(error.MarkdownRenderLimit, err);
            exceeded = true;
            break;
        };
    }
    try std.testing.expect(exceeded);
    try std.testing.expect(capped.bytes <= capped.max_bytes);
}

fn allocationScenario(a: Allocator) !void {
    var w: Writer = .{ .a = a, .columns = 4, .ansi = true, .prefix = "- ", .continuation = "  ", .base = .user };
    defer w.deinit();
    try w.emit("x❤");
    try w.setStyle(.{ .bold = true });
    try w.emit("️z\nnext");
    try w.finish();
}

test "allocation failures release detached clusters and owned finished rows" {
    try text.initLocale();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
