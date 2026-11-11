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

const output = @import("markdown_writer.zig");

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

// Expected plain rendering of a complete body: the shared Writer only, which
// is exactly the previous non-Markdown tail for a full stream.

// Sink that only records row source positions. Owns a row on success and
// never frees one it did not receive successfully.
