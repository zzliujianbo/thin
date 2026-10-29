//! Bounded incremental plain-text thinking tail.
//!
//! "Plain" means no Markdown, no prefix/list context and no original-source
//! mapping: every position here is an emit-stream offset of the SANITIZED
//! bytes (util/display_text policy: forbidden controls become U+FFFD, CRLF
//! becomes one LF, a bare CR becomes U+FFFD, ANSI is never interpreted).
//!
//! One heap-owned Tail owns a resumable Writer (columns/ANSI/.thinking tone),
//! a ring of the last completed visible rows and the sanitized source window
//! those rows were rendered from. `append` processes ONLY the new bytes and
//! `snapshot` clones the pending cluster into a throwaway Writer, so a redraw
//! never mutates live cluster state (later combining/VS/ZWJ bytes may still
//! extend it) and full history never enters a redraw.
//!
//! Display rows are produced by the shared Writer, never by a second
//! approximate width engine, so a full-stream tail is byte-identical to the
//! previous plain `Writer` rendering.
//!
//! `byte_budget` bounds the LOGICAL retained payload: the sanitized source
//! window plus the completed-row bytes. It is NOT a total-memory number.
//! Owned memory additionally includes container capacities and one live
//! in-flight row plus one pending cluster; `ownedBytes()` reports all of it and
//! `ownedBound()` gives a conservative, stream-length-independent cap (no
//! rows*columns product, so a combining cluster costs its own capped bytes).
//! Size the budget for at least one visible row plus one cluster, e.g.
//! `64 * columns + 4096` (create floors it at 1024). A pathological oversized
//! cluster, an unsatisfiable budget or ANY allocation failure during `append`
//! freezes the tail in an explicit sticky `Limit` state instead of buffering
//! without bound; the caller's canonical model history is a separate owner and
//! is never touched.
const std = @import("std");
const text = @import("text.zig");
const output = @import("markdown_writer.zig");
const display = @import("../util/display_text.zig");
const Decoder = @import("../util/stream_text.zig").Decoder;
const Writer = output.Writer;
const Allocator = std.mem.Allocator;

/// Terminal, sticky display limit of one tail. `none` is the only state in
/// which input is still accepted; every other state keeps the retained rows
/// and the preview readable and counts later input in `droppedBytes()`.
pub const Limit = enum {
    none,
    /// One cluster exceeded `max_cluster_bytes` (e.g. endless combining marks).
    cluster,
    /// The retained row window cannot satisfy `byte_budget`.
    budget,
    /// Any allocation failure while appending (sanitized source, staging or the
    /// row sink). Retained display state is still readable and `destroy` is
    /// still correct.
    memory,
};

/// Owned copy of the last visible rows. `truncated` reports that older rows
/// fell out of the retention window (or out of this snapshot).
pub const Snapshot = struct {
    rows: []const []const u8 = &.{},
    truncated: bool = false,
    limit: Limit = .none,

    pub fn deinit(self: *Snapshot, a: Allocator) void {
        for (self.rows) |row| a.free(row);
        a.free(self.rows);
        self.* = .{};
    }
};

const Row = struct { bytes: []const u8, src_start: usize };

fn clampColumns(columns: usize) usize {
    return std.math.clamp(columns, 1, 512);
}

pub const Tail = struct {
    a: Allocator,
    writer: Writer,
    /// Ring of completed rows; `first` is the oldest retained index.
    rows: std.ArrayList(Row) = .empty,
    first: usize = 0,
    row_bytes: usize = 0,
    /// Sanitized source for [source_base, base + len) == [base, writer.pos).
    source: std.ArrayList(u8) = .empty,
    source_base: usize = 0,
    keep_rows: usize,
    byte_budget: usize,
    max_cluster_bytes: usize,
    limited_by: Limit = .none,
    dropped: usize = 0,
    dropped_rows: usize = 0,
    rows_dirty: bool = false,
    /// Held bytes of an incomplete scalar or of a trailing CR.
    carry: [4]u8 = undefined,
    carry_len: usize = 0,
    held_cr: bool = false,

    pub fn create(a: Allocator, column_count: usize, keep_rows: usize, byte_budget: usize) !*Tail {
        const self = try a.create(Tail);
        errdefer a.destroy(self);
        const budget = @max(byte_budget, 1024);
        self.* = .{
            .a = a,
            .writer = .{ .a = a, .columns = clampColumns(column_count), .ansi = true, .base = .thinking },
            .keep_rows = @max(keep_rows, 1),
            .byte_budget = budget,
            .max_cluster_bytes = @max(64, @min(budget / 8, 4096)),
        };
        // Heap pointer context: never the address of a reallocatable record.
        self.writer.sink = .{ .context = self, .onRow = onRow };
        return self;
    }

    pub fn destroy(self: *Tail) void {
        const a = self.a;
        for (self.rows.items[self.first..]) |row| a.free(row.bytes);
        self.rows.deinit(a);
        self.source.deinit(a);
        self.writer.deinit();
        a.destroy(self);
    }

    pub fn columns(self: *const Tail) usize {
        return self.writer.columns;
    }
    pub fn keepRows(self: *const Tail) usize {
        return self.keep_rows;
    }
    pub fn limitState(self: *const Tail) Limit {
        return self.limited_by;
    }
    pub fn droppedBytes(self: *const Tail) usize {
        return self.dropped;
    }
    pub fn retainedRows(self: *const Tail) usize {
        return self.rows.items.len - self.first;
    }
    /// Logical retained payload constrained by `byte_budget`: completed row
    /// bytes plus retained sanitized source. NOT total memory; see ownedBytes.
    pub fn retainedBytes(self: *const Tail) usize {
        return self.row_bytes + self.source.items.len;
    }
    /// Every byte this Tail currently owns: retained payload, container
    /// capacities (source, row descriptors, live line and pending staging) and
    /// the (normally unused) writer row list header. Excludes caller-owned
    /// `Snapshot` rows.
    pub fn ownedBytes(self: *const Tail) usize {
        const w = &self.writer;
        return self.retainedBytes() +
            self.source.capacity +
            self.rows.capacity * @sizeOf(Row) +
            w.line.capacity +
            w.pending.capacity +
            w.lines.capacity * @sizeOf([]const u8);
    }
    /// Conservative, stream-length-independent upper bound on `ownedBytes()`.
    /// It adds up as: source payload and completed-row payload and the one live
    /// row payload are each capped by `byte_budget` (the tail freezes instead of
    /// exceeding it), every container holds at most ~1.5x its contents, the
    /// pending cluster is capped by `max_cluster_bytes`, and row descriptors
    /// are capped by the retention window. There is deliberately NO
    /// rows*columns term: a combining cluster costs its own capped bytes.
    pub fn ownedBound(self: *const Tail) usize {
        const window = self.keep_rows +| 4;
        return 8 *| self.byte_budget +|
            2 *| self.max_cluster_bytes +|
            2 *| window *| @sizeOf(Row) +|
            8192;
    }
    /// Sanitized source still available for `resize`; forgotten rows are gone.
    pub fn retainedSource(self: *const Tail) []const u8 {
        return self.source.items;
    }

    /// Feed raw provider bytes. Only new bytes are processed: sanitization is
    /// incremental, incomplete scalars and a trailing CR are held until the
    /// next chunk. Never executes ANSI or control input.
    pub fn append(self: *Tail, raw: []const u8) !void {
        if (self.limited_by != .none) {
            self.dropped += raw.len;
            return;
        }
        // Work one byte at a time so a sticky display limit can count the
        // unprocessed suffix. Preserve externally observed carry fields.
        var decoder = self.decoderSnapshot();
        var i: usize = 0;
        while (i < raw.len and self.limited_by == .none) : (i += 1) {
            var next = decoder;
            // A failed writer may have partially advanced, so the Tail freezes;
            // never publish a partially advanced decoder on failure.
            try next.feed(raw[i .. i + 1], self, emitTail);
            decoder = next;
            self.setDecoder(decoder);
        }
        if (i < raw.len) self.dropped += raw.len - i;
        self.enforce();
    }

    /// Owned styled copy of the last `keep_rows` rows, including a preview of
    /// the pending cluster / incomplete row AND the current-prefix sanitizer
    /// view of any held bytes (a trailing CR or partial scalar reads as
    /// U+FFFD). Does not flush or mutate live cluster state: the preview runs
    /// on a bounded owned clone, so a later LF or UTF8 completion replaces only
    /// that throwaway preview.
    pub fn snapshot(self: *Tail, a: Allocator) !Snapshot {
        var preview = try self.previewWriter(a);
        defer preview.deinit();
        // Held bytes are not part of the live sanitized source yet, but the
        // snapshot must show the CURRENT-PREFIX sanitizer result: a trailing CR
        // and every byte of an incomplete scalar display as U+FFFD, exactly as
        // display.sanitize treats the stream so far. Feed that only into the
        // throwaway clone; the live carry stays untouched so a later LF or a
        // UTF8 completion replaces just this mutable preview.
        var decoder = self.decoderSnapshot();
        try decoder.finish(&preview, emitPreview);
        try preview.finish();
        const preview_rows = preview.lines.items;
        const retained = self.rows.items[self.first..];
        const take_preview = @min(preview_rows.len, self.keep_rows);
        const take_rows = @min(retained.len, self.keep_rows - take_preview);
        const total = take_preview + take_rows;
        const rows = try a.alloc([]const u8, total);
        errdefer a.free(rows);
        var made: usize = 0;
        errdefer {
            for (rows[0..made]) |row| a.free(row);
        }
        for (retained[retained.len - take_rows ..]) |row| {
            rows[made] = try a.dupe(u8, row.bytes);
            made += 1;
        }
        for (preview_rows[preview_rows.len - take_preview ..]) |row| {
            rows[made] = try a.dupe(u8, row);
            made += 1;
        }
        return .{
            .rows = rows,
            .truncated = self.dropped_rows != 0 or retained.len != take_rows or preview_rows.len != take_preview,
            .limit = self.limited_by,
        };
    }

    /// Reflow ONLY the retained current-window source at a new width. Text that
    /// already scrolled out of the retention window is not resurrected.
    pub fn resize(self: *Tail, column_count: usize) !void {
        const cols = clampColumns(column_count);
        if (cols == self.writer.columns) return;
        var next: Writer = .{
            .a = self.a,
            .columns = cols,
            .ansi = self.writer.ansi,
            .base = self.writer.base,
            .pos = self.source_base,
        };
        errdefer next.deinit();
        var collector: Collector = .{ .a = self.a, .keep = self.keep_rows +| 1 };
        errdefer collector.deinit();
        next.sink = collector.sink();
        try next.emit(self.source.items);
        next.sink = .{ .context = self, .onRow = onRow };
        for (self.rows.items[self.first..]) |row| self.a.free(row.bytes);
        self.rows.deinit(self.a);
        self.writer.deinit();
        self.writer = next;
        self.rows = collector.rows;
        self.row_bytes = collector.bytes;
        self.first = 0;
        collector.rows = .empty;
        self.rows_dirty = true;
        self.enforce();
    }

    fn onRow(context: *anyopaque, row: []const u8, src_start: usize, _: []const u8) output.Error!void {
        const self: *Tail = @ptrCast(@alignCast(context));
        // Ownership: on failure the Writer still owns `row` and frees it, so
        // this sink must not free before its own bookkeeping succeeded.
        try self.rows.append(self.a, .{ .bytes = row, .src_start = src_start });
        self.row_bytes += row.len;
        self.rows_dirty = true;
    }

    fn decoderSnapshot(self: *const Tail) Decoder {
        return .{ .carry = self.carry, .carry_len = self.carry_len, .held_cr = self.held_cr };
    }

    fn setDecoder(self: *Tail, d: Decoder) void {
        self.carry = d.carry;
        self.carry_len = d.carry_len;
        self.held_cr = d.held_cr;
    }

    fn emitPreview(writer: *Writer, bytes: []const u8) !void {
        try writer.emit(bytes);
    }

    fn emitTail(self: *Tail, bytes: []const u8) !void {
        if (self.limited_by != .none) return;
        const before = self.source.items.len;
        self.source.appendSlice(self.a, bytes) catch |err| {
            self.limited_by = .memory;
            return err;
        };
        self.writer.emit(bytes) catch |err| {
            self.source.shrinkRetainingCapacity(before);
            self.limited_by = .memory;
            return err;
        };
        if (self.writer.cluster != null and
            self.writer.pos -| self.writer.pending_src_start > self.max_cluster_bytes)
        {
            self.limited_by = .cluster;
            return;
        }
        if (self.rows_dirty or self.source.items.len > self.byte_budget) self.enforce();
    }

    /// Retention and byte-budget enforcement. Never allocates.
    fn enforce(self: *Tail) void {
        self.rows_dirty = false;
        const window = self.keep_rows +| 1;
        while (self.rows.items.len - self.first > window) self.dropOldest();
        while (self.rows.items.len != self.first and self.retainedBytes() > self.byte_budget)
            self.dropOldest();
        self.trimSource();
        if (self.limited_by == .none and self.retainedBytes() > self.byte_budget)
            self.limited_by = .budget;
    }

    fn dropOldest(self: *Tail) void {
        if (self.first == self.rows.items.len) return;
        const row = self.rows.items[self.first];
        self.a.free(row.bytes);
        self.row_bytes -= row.bytes.len;
        self.first += 1;
        self.dropped_rows += 1;
        if (self.first == self.rows.items.len) {
            self.rows.clearRetainingCapacity();
            self.first = 0;
        } else if (self.first >= 8 and self.first * 2 >= self.rows.items.len) {
            const live = self.rows.items.len - self.first;
            std.mem.copyForwards(Row, self.rows.items[0..live], self.rows.items[self.first..]);
            self.rows.shrinkRetainingCapacity(live);
            self.first = 0;
        }
    }

    /// Externally the window is trim-able up to the first retained row (or the
    /// current row when nothing is retained); never further.
    fn sourceCut(self: *const Tail) usize {
        if (self.rows.items.len != self.first) return self.rows.items[self.first].src_start;
        const w = &self.writer;
        if (w.row_started) return w.row_src_start;
        if (w.cluster != null) return w.pending_src_start;
        return w.pos;
    }

    fn trimSource(self: *Tail) void {
        const cut = self.sourceCut();
        if (cut <= self.source_base) return;
        const drop = @min(cut - self.source_base, self.source.items.len);
        if (drop == 0) return;
        const keep = self.source.items.len - drop;
        if (keep == 0) self.source.clearRetainingCapacity() else {
            std.mem.copyForwards(u8, self.source.items[0..keep], self.source.items[drop..]);
            self.source.shrinkRetainingCapacity(keep);
        }
        self.source_base += drop;
    }

    /// Bounded owned clone of the resumable staging state. The live pending
    /// cluster stays untouched so later combining bytes still extend it.
    fn previewWriter(self: *const Tail, a: Allocator) !Writer {
        const w = &self.writer;
        var clone: Writer = .{
            .a = a,
            .columns = w.columns,
            .ansi = w.ansi,
            .base = w.base,
            .style = w.style,
            .col = w.col,
            .row_started = w.row_started,
            .cluster = w.cluster,
            .initialStyle = w.initialStyle,
            .initial_bullet = w.initial_bullet,
            .pending_body = w.pending_body,
            .row_body = w.row_body,
            .row_prefix = w.row_prefix,
            .pos = w.pos,
            .row_src_start = w.row_src_start,
            .pending_src_start = w.pending_src_start,
        };
        errdefer clone.deinit();
        try clone.line.appendSlice(a, w.line.items);
        try clone.pending.appendSlice(a, w.pending.items);
        return clone;
    }
};

/// Resize collector: keeps only the last `keep` rows of a reflow pass.
const Collector = struct {
    a: Allocator,
    keep: usize,
    rows: std.ArrayList(Row) = .empty,
    bytes: usize = 0,

    fn onRow(context: *anyopaque, row: []const u8, src_start: usize, _: []const u8) output.Error!void {
        const self: *Collector = @ptrCast(@alignCast(context));
        // Ownership: on failure the Writer still owns `row` and frees it.
        try self.rows.append(self.a, .{ .bytes = row, .src_start = src_start });
        self.bytes += row.len;
        while (self.rows.items.len > self.keep) {
            const oldest = self.rows.orderedRemove(0);
            self.bytes -= oldest.bytes.len;
            self.a.free(oldest.bytes);
        }
    }

    fn sink(self: *Collector) output.RowSink {
        return .{ .context = self, .onRow = onRow };
    }

    fn deinit(self: *Collector) void {
        for (self.rows.items) |row| self.a.free(row.bytes);
        self.rows.deinit(self.a);
    }
};

const testing = std.testing;

/// Expected plain rendering of a complete body: the shared Writer only, which
/// is exactly the previous non-Markdown tail for a full stream.
fn plainRows(a: Allocator, columns: usize, body: []const u8, out: *std.ArrayList([]u8)) !void {
    const clean = try display.sanitize(a, body, 1 << 20);
    defer a.free(clean);
    var w: Writer = .{ .a = a, .columns = clampColumns(columns), .ansi = true, .base = .thinking };
    defer w.deinit();
    try w.emit(clean);
    try w.finish();
    for (w.lines.items) |row| try out.append(a, try a.dupe(u8, row));
}

fn expectTail(tail: *Tail, columns: usize, body: []const u8) !void {
    const a = testing.allocator;
    var want: std.ArrayList([]u8) = .empty;
    defer {
        for (want.items) |row| a.free(row);
        want.deinit(a);
    }
    try plainRows(a, columns, body, &want);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    const count = @min(tail.keepRows(), want.items.len);
    try testing.expectEqual(count, snap.rows.len);
    const expected = want.items[want.items.len - count ..];
    for (expected, snap.rows) |e, got| try testing.expectEqualStrings(e, got);
}

test "arbitrary chunk boundaries keep the exact plain tail" {
    try text.initLocale();
    const a = testing.allocator;
    const bodies = [_][]const u8{
        "",
        "plain",
        "h\u{00e9}llo \u{4e2d}\u{6587}\r\nnext \u{1f44d}\u{1f3fd} \u{1f469}\u{200d}\u{1f4bb} \u{1f1fa}\u{1f1f8}\tTabbed\n\nlast",
        "a\rb\rc\r\nd",
        "e\u{0301}\u{fe0f}z",
    };
    for (bodies) |body| {
        for (0..body.len + 1) |split| {
            const tail = try Tail.create(a, 7, 3, 1 << 16);
            defer tail.destroy();
            try tail.append(body[0..split]);
            try tail.append(body[split..]);
            try expectTail(tail, 7, body);
        }
        const bytes = try Tail.create(a, 7, 3, 1 << 16);
        defer bytes.destroy();
        for (0..body.len) |i| try bytes.append(body[i .. i + 1]);
        try expectTail(bytes, 7, body);
    }
}

test "long ASCII without newlines stays bounded and tail-exact" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 10, 3, 4096);
    defer tail.destroy();
    const chunk: [97]u8 = @splat('x');
    for (0..200) |_| try tail.append(&chunk);
    try testing.expect(tail.retainedBytes() <= 4096);
    try testing.expect(tail.retainedRows() <= 4);
    try testing.expect(tail.retainedSource().len <= 4096);
    try testing.expectEqual(Limit.none, tail.limitState());
    const body: [97 * 200]u8 = @splat('x');
    try expectTail(tail, 10, &body);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    try testing.expectEqual(@as(usize, 3), snap.rows.len);
}

test "tabs keep the shared writer tab stops at narrow and wide columns" {
    try text.initLocale();
    const a = testing.allocator;
    const body = "a\tb\t\tc\td\te\tf\tg";
    for ([_]usize{ 1, 2, 79 }) |columns| {
        const tail = try Tail.create(a, columns, 4, 1 << 16);
        defer tail.destroy();
        for (0..body.len) |i| try tail.append(body[i .. i + 1]);
        try expectTail(tail, columns, body);
    }
}

test "snapshots are clones: later combining bytes still extend a pending cluster" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 4, 3, 1 << 16);
    defer tail.destroy();
    try tail.append("e");
    var first = try tail.snapshot(a);
    defer first.deinit(a);
    var second = try tail.snapshot(a);
    defer second.deinit(a);
    try testing.expectEqual(first.rows.len, second.rows.len);
    for (first.rows, second.rows) |x, y| try testing.expectEqualStrings(x, y);
    try tail.append("\u{0301}");
    try tail.append("\n");
    try tail.append("\u{1f469}\u{200d}\u{1f4bb}\u{1f1fa}\u{1f1f8}\u{fe0f}");
    try expectTail(tail, 4, "e\u{0301}\n\u{1f469}\u{200d}\u{1f4bb}\u{1f1fa}\u{1f1f8}\u{fe0f}");
}

test "input ANSI, controls, CRLF and bidi controls never reach the tail" {
    try text.initLocale();
    const a = testing.allocator;
    const body = "\x1b[31mred\x1b[0m\x07\x00a\rb\r\nc\u{202e}d\x7f\x9b\u{2066}e";
    const tail = try Tail.create(a, 6, 3, 1 << 16);
    defer tail.destroy();
    for (0..body.len) |i| try tail.append(body[i .. i + 1]);
    try expectTail(tail, 6, body);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    for (snap.rows) |row| {
        try testing.expect(std.mem.indexOf(u8, row, "\x1b[31") == null);
        try testing.expect(std.mem.indexOfScalar(u8, row, 0x07) == null);
        try testing.expect(std.mem.indexOfScalar(u8, row, 0x00) == null);
        try testing.expect(std.mem.indexOfScalar(u8, row, '\r') == null);
    }
}

test "a pathological cluster stops in a bounded display-limit state" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 8, 3, 4096);
    defer tail.destroy();
    try tail.append("ok\n");
    try tail.append("a");
    for (0..20000) |_| try tail.append("\u{0301}");
    try testing.expectEqual(Limit.cluster, tail.limitState());
    try testing.expect(tail.retainedBytes() <= 4096);
    try testing.expect(tail.retainedSource().len <= 4096);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    try testing.expectEqual(Limit.cluster, snap.limit);
    var saw_ok = false;
    for (snap.rows) |row| saw_ok = saw_ok or std.mem.indexOf(u8, row, "ok") != null;
    try testing.expect(saw_ok);
    // Further input is counted, never buffered.
    const dropped = tail.droppedBytes();
    try tail.append("tail");
    try testing.expectEqual(dropped + 4, tail.droppedBytes());
    try testing.expect(tail.retainedBytes() <= 4096);
}

test "resize reflows only the retained source window" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 12, 3, 1 << 16);
    defer tail.destroy();
    var buf: [64]u8 = undefined;
    for (0..60) |i| {
        const line = try std.fmt.bufPrint(&buf, "row {d} with text\n", .{i});
        try tail.append(line);
    }
    const retained = try a.dupe(u8, tail.retainedSource());
    defer a.free(retained);
    try testing.expect(std.mem.indexOf(u8, retained, "row 0 ") == null);
    try tail.resize(28);
    try testing.expectEqual(@as(usize, 28), tail.columns());
    try expectTail(tail, 28, retained);
    const narrow = try a.dupe(u8, tail.retainedSource());
    defer a.free(narrow);
    try testing.expect(std.mem.indexOf(u8, narrow, "row 0 ") == null);
    try tail.resize(64);
    try expectTail(tail, 64, narrow);
}

test "allocation failures release every owned row and source byte" {
    try text.initLocale();
    const Scenario = struct {
        fn run(a: Allocator) !void {
            const tail = try Tail.create(a, 9, 3, 1 << 12);
            defer tail.destroy();
            const chunks = [_][]const u8{ "ab", "\u{00e9}", "\u{1f469}\u{200d}\u{1f4bb}", "\r", "\n", "line two\tend", "\n" };
            for (chunks) |chunk| try tail.append(chunk);
            var snap = try tail.snapshot(a);
            defer snap.deinit(a);
            try tail.resize(4);
            try tail.append("more\n");
            var again = try tail.snapshot(a);
            defer again.deinit(a);
        }
    };
    var backing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    try testing.checkAllAllocationFailures(backing.allocator(), Scenario.run, .{});
    try testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

/// Sink that only records row source positions. Owns a row on success and
/// never frees one it did not receive successfully.
const StartProbe = struct {
    a: Allocator,
    starts: std.ArrayList(usize) = .empty,

    fn onRow(context: *anyopaque, row: []const u8, src_start: usize, _: []const u8) output.Error!void {
        const self: *StartProbe = @ptrCast(@alignCast(context));
        // On failure the Writer still owns `row` and frees it.
        try self.starts.append(self.a, src_start);
        self.a.free(row);
    }

    fn sink(self: *StartProbe) output.RowSink {
        return .{ .context = self, .onRow = onRow };
    }

    fn deinit(self: *StartProbe) void {
        self.starts.deinit(self.a);
    }
};

test "snapshot at every prefix shows the sanitized held bytes, then completion" {
    try text.initLocale();
    const a = testing.allocator;
    const bodies = [_][]const u8{
        "a\r\nb",
        "x\ty",
        "\u{00e9}",
        "e\u{0301}",
        "\u{1f469}\u{200d}\u{1f4bb}",
        "cr\r",
        "end\r\n",
    };
    for (bodies) |body| {
        for (0..body.len + 1) |split| {
            const tail = try Tail.create(a, 5, 3, 1 << 16);
            defer tail.destroy();
            for (0..split) |i| try tail.append(body[i .. i + 1]);
            // Prefix: a trailing CR or a partial scalar must already read as
            // U+FFFD, but only inside the clone.
            try expectTail(tail, 5, body[0..split]);
            for (split..body.len) |i| try tail.append(body[i .. i + 1]);
            // Completion replaced the preview: a CRLF is one newline and a
            // finished scalar extends the live cluster.
            try expectTail(tail, 5, body);
        }
    }
}

test "retained row source starts align with a resized refeed" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 12, 3, 1 << 16);
    defer tail.destroy();
    var buf: [48]u8 = undefined;
    for (0..40) |i| {
        const line = try std.fmt.bufPrint(&buf, "line {d} tab\tend\r\n", .{i});
        try tail.append(line);
    }
    try tail.resize(6);
    try tail.resize(20);
    // Re-emitting the retained window at the current width must reproduce the
    // exact same absolute emit-stream row starts.
    var probe: StartProbe = .{ .a = a };
    defer probe.deinit();
    var w: Writer = .{ .a = a, .columns = tail.columns(), .ansi = true, .base = .thinking, .sink = probe.sink() };
    defer w.deinit();
    w.pos = tail.source_base;
    try w.emit(tail.retainedSource());
    const rows = tail.rows.items[tail.first..];
    try testing.expect(rows.len != 0);
    try testing.expect(probe.starts.items.len >= rows.len);
    const offset = probe.starts.items.len - rows.len;
    for (rows, probe.starts.items[offset..]) |row, start| try testing.expectEqual(row.src_start, start);
}

test "owned memory stays inside its documented bound" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 7, 3, 2048);
    defer tail.destroy();
    try testing.expect(tail.ownedBytes() <= tail.ownedBound());
    const chunk: [128]u8 = @splat('x');
    for (0..400) |_| {
        try tail.append(&chunk);
        try testing.expect(tail.ownedBytes() <= tail.ownedBound());
    }
    try testing.expect(tail.ownedBytes() >= tail.retainedBytes());
    try testing.expectEqual(Limit.none, tail.limitState());
    // A single huge combining cluster is capped by max_cluster_bytes, so the
    // bound must never need a rows*columns*4 estimate.
    try tail.append("\n");
    for (0..4000) |_| try tail.append("\u{0301}");
    try testing.expectEqual(Limit.cluster, tail.limitState());
    try testing.expect(tail.ownedBytes() <= tail.ownedBound());
    try testing.expect(tail.ownedBytes() >= tail.retainedBytes());
}

test "any append allocation failure latches the display limit" {
    try text.initLocale();
    var backing = testing.FailingAllocator.init(testing.allocator, .{});
    const tail = try Tail.create(backing.allocator(), 8, 3, 1 << 12);
    {
        defer tail.destroy();
        try tail.append("warm\n");
        try testing.expectEqual(Limit.none, tail.limitState());
        backing.fail_index = backing.alloc_index; // the very next allocation fails
        try testing.expectError(error.OutOfMemory, tail.append("another line\n"));
        try testing.expectEqual(Limit.memory, tail.limitState());
        // Frozen, countable and still readable; nothing is silently retried.
        const dropped = tail.droppedBytes();
        try tail.append("later");
        try testing.expectEqual(dropped + 5, tail.droppedBytes());
        var snap = try tail.snapshot(testing.allocator);
        defer snap.deinit(testing.allocator);
        try testing.expectEqual(Limit.memory, snap.limit);
        try testing.expect(snap.rows.len != 0);
    }
    try testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "row sinks never free a row the writer still owns" {
    const a = testing.allocator;
    var backing = testing.FailingAllocator.init(a, .{});
    const tail = try Tail.create(backing.allocator(), 8, 3, 1 << 12);
    {
        defer tail.destroy();
        const row = try backing.allocator().dupe(u8, "owned-row");
        backing.fail_index = backing.alloc_index; // row push must fail
        try testing.expectError(error.OutOfMemory, Tail.onRow(tail, row, 0, ""));
        // The sink did not free it: the writer (this test) still owns it, so
        // exactly one free happens here. A sink-side free would double free.
        backing.allocator().free(row);
    }
    try testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);

    // Same contract for the resize collector.
    var second = testing.FailingAllocator.init(a, .{});
    var collector: Collector = .{ .a = second.allocator(), .keep = 2 };
    {
        defer collector.deinit();
        const row = try second.allocator().dupe(u8, "collector-row");
        second.fail_index = second.alloc_index;
        try testing.expectError(error.OutOfMemory, Collector.onRow(&collector, row, 0, ""));
        second.allocator().free(row);
    }
    try testing.expectEqual(second.allocated_bytes, second.freed_bytes);
}
