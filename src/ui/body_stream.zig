//! Incremental, bounded active-answer body.
//!
//! Contract (docs/current-screen-rendering.md §6.3/6.5):
//!  * input, parse progress and confirmed display progress are separate;
//!  * a BOUNDED mutable window may be re-analyzed, retired source never is;
//!  * transport-chunk end is not document EOF;
//!  * a freeze only happens after a full fresh frame ACK and freezes the
//!    displayed interpretation of anything still unresolved;
//!  * rows that leave the mutable viewport are final: they are never
//!    regenerated or re-parsed from raw text.
//!
//! Implementation shape: the vendored native MD4C grammar (through
//! `markdown.renderWindow`) parses `[synthesized context][unretired source]`.
//! The context is captured from the real renderer block/container state
//! (prefix, continuation, fence char, table header) so a resumed window keeps
//! actual container and leaf semantics without re-scanning retired bytes.
//! `commit` is the only operation that retires source; it uses row-level
//! parser-source provenance, not emit-stream offsets.
const std = @import("std");
const builtin = @import("builtin");
const markdown = @import("markdown.zig");
const native = @import("md4c.zig");
const md = native;
const output = @import("markdown_writer.zig");
const display = @import("../util/display_text.zig");
const decode = display.decode;
const Writer = output.Writer;
const Allocator = std.mem.Allocator;

/// One display row of the active body. `start`/`end` are SANITIZED source
/// offsets relative to this Body's current window (`source[0]`), not raw
/// provider bytes and not emit-stream bytes. `synthetic` rows carry no source
/// byte at all (borders, markers, a context sentinel).
pub const Row = struct { text: []const u8, start: usize, end: usize, synthetic: bool, leaf: usize, output_start: usize = 0, output_end: usize = 0, output_window: usize = 0, table: ?markdown.TableProgress = null, table_kind: ?markdown.TableRowKind = null, table_checkpoint: ?markdown.TableProgress = null, table_occurrences: []const markdown.TableOccurrence = &.{}, prefix: []const u8 = "" };

/// Explicit, sticky display limits. Input is retained (backpressure) instead of
/// being truncated; the caller may stop feeding while `pendingBytes()` grows.
pub const Limit = enum {
    none,
    /// The unretired window exceeded the documented parse budget.
    window,
    /// The renderer produced more rows than the bounded row cap.
    rows,
    /// Any allocation failure while parsing/rendering.
    memory,
    /// The bounded reference store could not retain a definition that must
    /// survive retirement; display stops instead of silently losing link
    /// targets.
    refs,
    /// The bounded ambiguous-candidate freeze budget is exhausted. Display
    /// stops with the source untouched rather than forgetting an active freeze.
    ambiguity,
    /// A table's native container nesting exceeded the bounded checkpoint; the
    /// table fails closed instead of silently truncating its container prefix.
    containers,
};

const Ctx = struct {
    kind: markdown.LeafKind = .document,
    prefix: []const u8 = "",
    continuation: []const u8 = "",
    style: output.Style = .{},
    fence: u8 = '`',
    fence_length: usize = 3,
    header_open: bool = false,
    header_run: bool = false,
    closing_begin: ?usize = null,
    closing_end: ?usize = null,
    indented: bool = false,
    table_header: []const u8 = "",
    table_header_begin: usize = 0,
    table_body_begin: usize = 0,
    table_header_complete: bool = false,
    table_columns: usize = 0,
    table_align: [32]c_int = @splat(0),
    /// Native container snapshot of the CURRENT table (outermost first). Owned
    /// by this Body's checkpoint arena; never a global last-table seed.
    table_containers: []const md.TableContainer = &.{},
    /// Resume column and per-column delivered ends (absolute source) of the
    /// in-progress logical row. Later columns may be ahead of the retirement
    /// cursor; their bytes stay retained and are trimmed by the native skip.
    table_column: usize = 0,
    table_delivered: [32]usize = @splat(0),
    table_row: ?usize = null,
    table_row_had_output: bool = false,
    table_trim_leading: bool = false,
    table_settled: u32 = 0,
    /// Physical rows already written: top border, header separator, and the
    /// header row + delimiter source itself (`table_head_done`).
    table_top_done: bool = false,
    table_head_done: bool = false,
    table_sep_done: bool = false,
};

const max_columns = 32;
/// Per-Body committed reference store bounds. Exceeding them is an explicit
/// resource failure, never a silent loss of a definition.
const reference_entries = 4096;
const reference_bytes = 1024 * 1024;
/// Native-ambiguous ranges explicitly frozen as literal displayed text.
const frozen_capacity = 4;
const FrozenRange = struct { begin: usize, end: usize };
/// Scratch size for the sorted union of committed + frame decisions plus one
/// candidate. Building the union never allocates and never evicts a decision.
const frozen_scratch = frozen_capacity * 2 + 1;
fn lessThanFrozenRange(_: void, left: FrozenRange, right: FrozenRange) bool {
    return left.begin < right.begin or (left.begin == right.begin and left.end < right.end);
}

/// Sorted, coalesced union of already-authorized ranges plus one optional
/// candidate. Overlap OR adjacency coalesces only because every input range in
/// `left`/`right` is an authorized freeze decision; `extra` is projected, never
/// authority by itself. Allocation-free and bounded by `frozen_scratch`.
fn buildFrozenUnion(left: []const FrozenRange, right: []const FrozenRange, extra: ?FrozenRange, out: *[frozen_scratch]FrozenRange) usize {
    var count: usize = 0;
    for (left) |range| {
        out[count] = range;
        count += 1;
    }
    for (right) |range| {
        out[count] = range;
        count += 1;
    }
    if (extra) |range| {
        out[count] = range;
        count += 1;
    }
    std.mem.sort(FrozenRange, out[0..count], {}, lessThanFrozenRange);
    var merged: usize = 0;
    for (out[0..count]) |range| {
        if (merged != 0 and range.begin <= out[merged - 1].end) {
            out[merged - 1].end = @max(out[merged - 1].end, range.end);
            continue;
        }
        out[merged] = range;
        merged += 1;
    }
    return merged;
}
/// Per-frame accumulation across every subparse window of one render.
const Accum = struct {
    a: Allocator,
    definitions: std.ArrayList(markdown.Definition) = .empty,
    candidate: ?markdown.Candidate = null,

    fn add(self: *Accum, window: markdown.Window) !void {
        try self.definitions.appendSlice(self.a, window.definitions);
        if (window.candidate) |candidate| {
            if (self.candidate == null or candidate.begin < self.candidate.?.begin or
                (candidate.begin == self.candidate.?.begin and candidate.reason == md.candidate_reference and self.candidate.?.reason != md.candidate_reference))
                self.candidate = candidate;
        }
    }
};

const Leaf = struct {
    ctx: Ctx,
    row_start: usize,
    row_end: usize,
    /// Normalized source offsets of the table header cells (0/0 when absent).
    head_start: usize = 0,
    head_end: usize = 0,
    /// Rows (border + header + rule) that must be written before body rows.
    head_rows: usize = 0,
};

const Render = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    leaves: []Leaf = &.{},
    confirmed: []markdown.ConfirmedSpan = &.{},
    cells: []markdown.CellRange = &.{},
    end: Ctx = .{},
    end_is_document: bool = true,
    end_authoritative: bool = false,
    leaf_open: bool = false,
    /// Definitions and the earliest native candidate captured by this render.
    definitions: []const markdown.Definition = &.{},
    candidate: ?markdown.Candidate = null,
    /// Source length (in current-window coordinates) covered by this render.
    source_len: usize = 0,
    /// The document parser reached the end of this snapshot without a yield.
    visibility_complete: bool = false,
    metadata: ?Metadata = null,
};

const Metadata = struct {
    cut: usize,
    next: Ctx,
    inline_resume: bool,
};

pub const Stats = struct {
    renders: usize = 0,
    window_bytes: usize = 0,
    retired_bytes: usize = 0,
    rows_rendered: usize = 0,
    max_window_bytes: usize = 0,
    frozen_rows: usize = 0,
};

pub const Body = struct {
    a: Allocator,
    columns: usize,
    /// Sanitized, not-yet-retired source. `source[0]` is the resume anchor.
    source: std.ArrayList(u8) = .empty,
    /// Absolute sanitized offset of source[0] (for reports/tests only).
    base: usize = 0,
    ctx: Ctx = .{},
    /// Semantic state owned independently of the currently pinned render arena.
    confirmed: std.ArrayList(markdown.ConfirmedSpan) = .empty,
    /// True when `source[0]` starts in the middle of a physical line.
    inline_resume: bool = false,
    /// Owned bytes backing ctx.prefix/continuation/table_header.
    ctx_arena: std.heap.ArenaAllocator,
    render: Render,
    render_valid: bool = false,
    /// A frame is being built from the current render; append must not change
    /// the row identity that frame will ACK.
    pinned: bool = false,
    /// This render's slice reaches the real EOF of accepted input.
    render_final: bool = false,
    /// Bytes held by the sanitizer (incomplete scalar / trailing CR).
    carry: [4]u8 = undefined,
    carry_len: usize = 0,
    held_cr: bool = false,
    finished: bool = false,
    /// True once a bounded fallback froze a construct the window could not
    /// reconstruct (an unreconstructable table row / no retained header) or an
    /// ambiguous native candidate that could not stay inside the mutable tail.
    /// Only a decision PUBLISHED by a fresh ACK sets this: staging a freeze is
    /// frame-local, and abort/resize/OOM never turn a provisional display into
    /// a committed interpretation.
    diverged: bool = false,
    /// Committed reference definitions (lazy, bounded). Never published from a
    /// discarded frame; destroyed with the Body.
    references: ?*md.ReferenceStore = null,
    /// Committed freeze decisions (survive abort) and this frame's decisions.
    /// Both are consulted immediately; only a fresh commit publishes the frame
    /// ones. Frame entries are kept coalesced among themselves, so one bounded
    /// array holds every distinct authorized range. The active union budget is
    /// `frozen_capacity`.
    frozen: [frozen_capacity]FrozenRange = @splat(.{ .begin = 0, .end = 0 }),
    frozen_count: usize = 0,
    frame_frozen: [frozen_capacity]FrozenRange = @splat(.{ .begin = 0, .end = 0 }),
    frame_frozen_count: usize = 0,
    limit: Limit = .none,
    /// Work quantum, NOT an admission/source limit. Remaining accepted bytes
    /// stay queued and are parsed after this prefix is acknowledged.
    max_window_bytes: usize = 4096,
    final_metadata_lookahead: bool = false,
    max_rows: usize = 65536,
    stats: Stats = .{},

    pub fn create(a: Allocator, columns: usize) !*Body {
        const self = try a.create(Body);
        errdefer a.destroy(self);
        self.* = .{
            .a = a,
            .columns = std.math.clamp(columns, 1, 512),
            .ctx_arena = std.heap.ArenaAllocator.init(a),
            .render = .{ .arena = std.heap.ArenaAllocator.init(a) },
        };
        return self;
    }

    pub fn destroy(self: *Body) void {
        const a = self.a;
        if (self.references) |store| md.md_reference_store_destroy(store);
        self.references = null;
        self.source.deinit(a);
        self.ctx_arena.deinit();
        self.render.arena.deinit();
        a.destroy(self);
    }

    /// Sanitized source bytes still inside the mutable window.
    pub fn windowBytes(self: *const Body) usize {
        return self.source.items.len;
    }

    /// Sanitized bytes accepted but not yet rendered (bounded backpressure
    /// signal, never a reason to drop bytes).
    pub fn pendingBytes(self: *const Body) usize {
        return self.source.items.len -| self.render.source_len;
    }

    /// Normalized source admitted so far. A pending CR reserves one normalized
    /// byte for a possible CRLF. UI delivery supplies whole valid UTF-8 chunks.
    pub fn acceptedSourceEnd(self: *const Body) usize {
        return self.base + self.source.items.len + @intFromBool(self.held_cr);
    }

    /// Source actually retired by successful commits, including metadata-only
    /// frames. This is not a claim that zero rows displayed any glyphs.
    pub fn committedSourceEnd(self: *const Body) usize {
        return self.base;
    }

    /// Conservative proof for an all-rows, fresh pinned frame: the contiguous
    /// absolute source end represented by every pinned row. This does not
    /// retire source; a complete fresh frame may show mutable rows the Body
    /// still keeps to resolve future syntax.
    pub fn visibleSourceEnd(self: *const Body) usize {
        if (!self.pinned) return self.base;
        return self.base + self.frameCoverage(self.render.rows.len, false);
    }

    /// Exact contiguous source represented by only the first `count` pinned
    /// rows. A cropped frame must not claim rows it did not write; the source
    /// retirement itself stays device-side (see `commit`).
    pub fn visibleSourceEndForRows(self: *const Body, count: usize) usize {
        if (!self.pinned) return self.base;
        const n = @min(count, self.render.rows.len);
        if (n == 0) return self.base;
        return self.base + self.frameCoverage(n, false);
    }

    /// Presentation still owed after the last source byte, independently of
    /// pendingBytes(): EOF must acknowledge the table's bottom border.
    pub fn hasPendingPresentation(self: *const Body) bool {
        return self.finished and self.source.items.len == 0 and self.ctx.kind == .table;
    }

    /// True only after EOF and acknowledgement of all retained source and rows.
    /// pendingBytes() alone excludes source already included in a pinned render.
    pub fn isDrained(self: *const Body) bool {
        return self.finished and self.limit == .none and self.source.items.len == 0 and
            self.render.rows.len == 0 and self.carry_len == 0 and !self.held_cr and
            !self.hasPendingPresentation();
    }

    pub fn hasMetadataProgress(self: *const Body) bool {
        if (!self.pinned or self.render.rows.len != 0) return false;
        return if (self.render.metadata) |metadata| metadata.cut > self.base else false;
    }

    pub fn columnCount(self: *const Body) usize {
        return self.columns;
    }

    /// Rows of the current render (empty until `build` succeeds).
    pub fn visibleRows(self: *const Body) []const Row {
        if (!self.render_valid and !self.pinned) return &.{};
        return self.render.rows;
    }

    /// Drop frame ownership without discarding the cached rows (nothing was
    /// written, so nothing needs re-analysis on the next ordinary repaint).
    pub fn releasePin(self: *Body) void {
        self.pinned = false;
    }

    /// Called when the terminal width changes. Only the retained window is
    /// re-analyzed; rows already released are gone and are never replayed.
    pub fn resize(self: *Body, columns: usize) void {
        const next = std.math.clamp(columns, 1, 512);
        if (next == self.columns) return;
        self.columns = next;
        self.pinned = false;
        self.render_valid = false;
        // A discarded frame never publishes its staged freeze decisions.
        self.frame_frozen_count = 0;
    }

    fn resetRender(self: *Body) void {
        self.render.arena.deinit();
        self.render = .{ .arena = std.heap.ArenaAllocator.init(self.a) };
        self.render_valid = false;
    }

    /// Feed raw provider bytes. Only new bytes are processed by the sanitizer;
    /// a trailing CR or an incomplete UTF-8 scalar is held until the next chunk
    /// (transport-chunk end is not a document boundary).
    pub fn append(self: *Body, raw: []const u8) !void {
        // A finished body is the canonical answer; a late transport delta after
        // the final event is not part of it (and must not add stray rows).
        if (self.finished or self.limit == .memory) return;
        var i: usize = 0;
        if (self.held_cr or self.carry_len != 0) i = try self.resolve(raw);
        while (i < raw.len) {
            const byte = raw[i];
            if (byte < 0x80) {
                if (byte == 13) {
                    if (i + 1 == raw.len) {
                        self.held_cr = true;
                        i = raw.len;
                        break;
                    }
                    if (raw[i + 1] == 10) {
                        i += 1;
                        continue;
                    }
                    try self.pushScalar(0xfffd);
                } else try self.pushScalar(display.displayCodepoint(byte));
                i += 1;
                continue;
            }
            const need: usize = std.unicode.utf8ByteSequenceLength(byte) catch 0;
            if (need == 0) {
                try self.pushScalar(0xfffd);
                i += 1;
                continue;
            }
            if (need > raw.len - i) {
                if (!continuations(raw[i + 1 ..])) {
                    try self.pushScalar(0xfffd);
                    i += 1;
                    continue;
                }
                self.carry_len = raw.len - i;
                @memcpy(self.carry[0..self.carry_len], raw[i..]);
                i = raw.len;
                break;
            }
            const r = decode(raw, i);
            try self.pushScalar(display.displayCodepoint(r.cp));
            i = r.end;
        }
        self.render_valid = false;
    }

    /// Explicit end of the canonical answer. Not implied by any chunk boundary.
    pub fn finish(self: *Body) !void {
        if (self.finished) return;
        self.finished = true;
        // A final partial scalar/CR is invalid input at EOF, never a reason to
        // invent a newline or drop the retained bytes.
        if (self.held_cr) {
            self.held_cr = false;
            try self.pushScalar(0xfffd);
        }
        if (self.carry_len != 0) {
            const n = self.carry_len;
            self.carry_len = 0;
            for (0..n) |_| try self.pushScalar(0xfffd);
        }
        self.render_valid = false;
    }

    fn continuations(bytes: []const u8) bool {
        for (bytes) |b| if (b & 0xc0 != 0x80) return false;
        return true;
    }

    fn resolve(self: *Body, raw: []const u8) !usize {
        var i: usize = 0;
        if (self.held_cr) {
            if (raw.len == 0) return 0;
            self.held_cr = false;
            if (raw[0] == 10) {
                try self.pushScalar(10);
                return 1;
            }
            try self.pushScalar(0xfffd);
            return 0;
        }
        const need: usize = std.unicode.utf8ByteSequenceLength(self.carry[0]) catch 2;
        var buf: [4]u8 = undefined;
        var n = self.carry_len;
        @memcpy(buf[0..n], self.carry[0..n]);
        self.carry_len = 0;
        while (n < need and i < raw.len and raw[i] & 0xc0 == 0x80) : (i += 1) {
            buf[n] = raw[i];
            n += 1;
        }
        if (n < need and i == raw.len) {
            self.carry_len = n;
            @memcpy(self.carry[0..n], buf[0..n]);
            return i;
        }
        if (n < need) {
            for (buf[0..n]) |_| try self.pushScalar(0xfffd);
            return i;
        }
        const r = decode(buf[0..need], 0);
        if (r.end != need) {
            for (buf[0..need]) |_| try self.pushScalar(0xfffd);
            return i;
        }
        try self.pushScalar(display.displayCodepoint(r.cp));
        return i;
    }

    fn pushScalar(self: *Body, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const safe: u21 = if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) 0xfffd else cp;
        const n = std.unicode.utf8Encode(safe, &buf) catch {
            @memcpy(buf[0..3], "\xef\xbf\xbd");
            return self.pushBytes(buf[0..3]);
        };
        return self.pushBytes(buf[0..n]);
    }

    fn pushBytes(self: *Body, bytes: []const u8) !void {
        self.source.appendSlice(self.a, bytes) catch |err| {
            self.limit = .memory;
            return err;
        };
    }

    /// Number of leading rows a caller may write and then commit. Tables retire
    /// per physical row (a partial first column may advance while a later column
    /// is still pending); only an overlapping atomic source occurrence forces the
    /// caller to include the following row.
    pub fn releaseLimit(self: *Body, wanted: usize) usize {
        if ((!self.render_valid and !self.pinned) or self.limit != .none) return 0;
        const rows = self.render.rows;
        const n = @min(wanted, rows.len);
        if (n == 0) return 0;
        var limit_n = self.atomicRelease(n);
        // A native-confirmed ambiguous trailing header (or a definition whose
        // optional title is undecided) must stay in the mutable viewport: its
        // source may still be reinterpreted. The caller's own mutable-tail
        // budget decides whether it can still fit; an oversized one is frozen
        // explicitly instead of blocking every later release forever.
        if (self.candidateHold()) |_| {
            if (self.render.candidate) |candidate| {
                var first: ?usize = null;
                var last: usize = 0;
                const candidate_begin = candidate.begin -| self.base;
                const candidate_end = candidate.end -| self.base;
                for (rows, 0..) |row, index| {
                    if (row.synthetic or row.start == std.math.maxInt(usize) or row.end <= row.start) continue;
                    if (row.end <= candidate_begin or row.start >= candidate_end) continue;
                    if (first == null) first = index;
                    last = index;
                }
                if (first) |first_index| {
                    if (first_index < limit_n) {
                        const mutable_tail = rows.len -| limit_n;
                        const candidate_rows = last - first_index + 1;
                        if (candidate_rows > mutable_tail) {
                            if (!self.freezeCandidate(candidate.begin, candidate.end)) {
                                // Never forget an active freeze. Stop display
                                // with the source untouched instead.
                                self.limit = .ambiguity;
                                return 0;
                            }
                        } else limit_n = first_index;
                    }
                }
            }
        }
        return limit_n;
    }

    /// Drop committed decisions whose source is fully retired. Frame-local
    /// decisions are pruned by clearing them on abort instead.
    fn pruneFrozen(self: *Body) void {
        var keep: usize = 0;
        for (self.frozen[0..self.frozen_count]) |range| {
            if (range.end <= self.base) continue;
            self.frozen[keep] = range;
            keep += 1;
        }
        self.frozen_count = keep;
    }

    /// Distinct active decisions: the union of committed + frame ranges. The
    /// raw array counts are not capacity: ranges owned by the same ambiguity
    /// merge into one decision.
    fn frozenCount(self: *const Body) usize {
        var scratch: [frozen_scratch]FrozenRange = undefined;
        return buildFrozenUnion(self.frozen[0..self.frozen_count], self.frame_frozen[0..self.frame_frozen_count], null, &scratch);
    }

    /// Half-open full containment in the authorized union. A candidate that
    /// merely touches or partly overlaps a decision is NOT already frozen: only
    /// the overlapping bytes were decided, so it must still be held or widened.
    fn isFrozen(self: *const Body, begin: usize, end: usize) bool {
        var scratch: [frozen_scratch]FrozenRange = undefined;
        const count = buildFrozenUnion(self.frozen[0..self.frozen_count], self.frame_frozen[0..self.frame_frozen_count], null, &scratch);
        for (scratch[0..count]) |range| {
            if (range.begin <= begin and end <= range.end) return true;
        }
        return false;
    }

    /// Publish the staged union into the committed set. Capacity was reserved
    /// when the decision was staged, so this never evicts an active decision;
    /// it runs only after a successful fresh ACK, which is also the moment the
    /// provisional interpretation becomes final.
    fn mergeFrameFrozen(self: *Body) void {
        if (self.frame_frozen_count == 0) return;
        self.pruneFrozen();
        for (self.frame_frozen[0..self.frame_frozen_count], 0..) |range, index| self.frozen[index] = range;
        self.frozen_count = self.frame_frozen_count;
        self.frame_frozen_count = 0;
        self.pruneFrozen();
        // The frame was acknowledged: whatever it displayed provisionally is
        // now final and must never be rewritten.
        self.diverged = true;
    }

    /// Earliest ambiguous native range that still has to remain mutable. The
    /// range must live inside the retained window; an already cut range can no
    /// longer be reinterpreted and never blocks progress.
    fn candidateHold(self: *const Body) ?usize {
        const candidate = self.render.candidate orelse return null;
        if (candidate.begin < self.base or candidate.end <= self.base) return null;
        if (self.isFrozen(candidate.begin, candidate.end)) return null;
        return candidate.begin;
    }

    /// Stage the projected freeze union. Nothing is committed and no display
    /// decision becomes final until a fresh ACK publishes it. Returns false when
    /// the bounded budget is truly exhausted: no active decision is evicted,
    /// nothing is written and the caller must fail instead of forgetting it.
    fn freezeCandidate(self: *Body, begin: usize, end: usize) bool {
        if (end <= begin) return true;
        self.pruneFrozen();
        // An authorized decision (committed or staged in this frame) that fully
        // contains the candidate needs no change.
        if (self.isFrozen(begin, end)) return true;
        // Project the union BEFORE touching the frame snapshot: a candidate
        // that overlaps or touches an authorized range merges into it instead
        // of consuming another slot, so raw array counts are not capacity.
        const baseline = if (self.frame_frozen_count != 0)
            self.frame_frozen[0..self.frame_frozen_count]
        else
            self.frozen[0..self.frozen_count];
        var scratch: [frozen_scratch]FrozenRange = undefined;
        const count = buildFrozenUnion(baseline, &.{}, .{ .begin = begin, .end = end }, &scratch);
        if (count > frozen_capacity) return false;
        // Frame-local only: committed decisions stay untouched until the fresh
        // ACK, and abort/resize/OOM simply drop this snapshot.
        @memcpy(self.frame_frozen[0..count], scratch[0..count]);
        self.frame_frozen_count = count;
        return true;
    }

    fn referenceStore(self: *Body) !*md.ReferenceStore {
        if (self.references) |store| return store;
        const created = md.md_reference_store_create(reference_entries, reference_bytes) orelse return error.OutOfMemory;
        self.references = created;
        return created;
    }

    /// Stage every definition entirely before `cut`. The native update is
    /// prepared without mutating the store, so a later failure publishes
    /// nothing; commit is allocation-free.
    fn prepareDefinitionUpdate(self: *Body, cut: usize) !?*md.ReferenceUpdate {
        var count: usize = 0;
        for (self.render.definitions) |definition| {
            if (definition.end <= cut) count += 1;
        }
        if (count == 0) return null;
        const store = self.referenceStore() catch |err| {
            self.limit = .memory;
            return err;
        };
        const events = try self.a.alloc(md.ReferenceDefinition, count);
        defer self.a.free(events);
        var index: usize = 0;
        for (self.render.definitions) |definition| {
            if (definition.end > cut) continue;
            events[index] = definition.event;
            index += 1;
        }
        var update: ?*md.ReferenceUpdate = null;
        const result = md.md_reference_store_prepare(store, events.ptr, @intCast(count), &update);
        if (result == -1) {
            self.limit = .memory;
            return error.OutOfMemory;
        }
        if (result == -2) {
            // Explicit bounded resource failure. Retiring the source without
            // retaining the definition would silently break future links.
            self.limit = .refs;
            return null;
        }
        return update;
    }

    /// Publish the frame's context and any reference definitions atomically,
    /// before the caller retires source. Returns false when the bounded store
    /// refused them; nothing was published in that case.
    fn publishCommit(self: *Body, next: Ctx, spans: []const markdown.ConfirmedSpan, cut: usize) !bool {
        const update = self.prepareDefinitionUpdate(cut) catch |err| {
            self.frame_frozen_count = 0;
            return err;
        };
        if (self.limit == .refs) {
            if (update) |pending| md.md_reference_store_abort(pending);
            self.frame_frozen_count = 0;
            return false;
        }
        self.setCtx(next, spans, cut) catch |err| {
            if (update) |pending| md.md_reference_store_abort(pending);
            self.frame_frozen_count = 0;
            self.limit = .memory;
            return err;
        };
        if (update) |pending| md.md_reference_store_commit(self.references.?, pending);
        return true;
    }

    fn atomicRelease(self: *const Body, requested: usize) usize {
        const rows = self.render.rows;
        var n = @min(requested, rows.len);
        // A decoded entity or conservative Unicode cluster may straddle rows.
        // Never retire its source after displaying only part of its expansion.
        while (n != 0 and n < rows.len) {
            const prior = rows[n - 1];
            const after = rows[n];
            var shared = false;
            if (prior.table) |left| {
                if (after.table) |right| {
                    if (left.row_begin == right.row_begin) {
                        for (prior.table_occurrences) |a| {
                            if (!a.segment.atomic or a.segment.generated) continue;
                            for (after.table_occurrences) |b| {
                                if (b.segment.atomic and !b.segment.generated and a.column == b.column and
                                    a.segment.start < b.segment.end and b.segment.start < a.segment.end)
                                {
                                    shared = true;
                                    break;
                                }
                            }
                            if (shared) break;
                        }
                    }
                }
            } else if (!prior.synthetic and !after.synthetic) {
                shared = after.start < prior.end;
            }
            if (!shared) break;
            n += 1;
        }
        return n;
    }

    /// Produce rows for the current window. A successful call pins the render so
    /// an in-flight frame keeps the exact row identities and checkpoint it was
    /// built from; `commit` or `abort` releases the pin.
    pub fn build(self: *Body) !void {
        if (self.render_valid or self.pinned) {
            self.pinned = true;
            return;
        }
        if (self.limit != .none) {
            // A sticky limit keeps the last successfully rendered rows readable.
            self.render_valid = self.render.rows.len != 0;
            return;
        }
        self.renderAttempt() catch |err| {
            self.limit = switch (err) {
                error.OutOfMemory => .memory,
                error.MarkdownContainerLimit => .containers,
                else => .rows,
            };
            self.render_valid = self.render.rows.len != 0;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return;
        };
        // Only native reference candidates require bounded metadata lookahead;
        // a deciding physical line can arrive before transport EOF.
        if (self.ctx.kind != .table and
            self.render.source_len < self.source.items.len and self.candidateHold() != null and
            self.render.candidate.?.reason == md.candidate_reference)
        {
            self.final_metadata_lookahead = true;
            defer self.final_metadata_lookahead = false;
            self.renderAttempt() catch |err| {
                self.limit = switch (err) {
                    error.OutOfMemory => .memory,
                    error.MarkdownContainerLimit => .containers,
                    else => .rows,
                };
                self.render_valid = false;
                if (err == error.OutOfMemory) return err;
                return;
            };
            if (self.render.source_len < self.source.items.len and self.candidateHold() != null and
                self.render.candidate.?.reason == md.candidate_reference and
                (self.finished or self.source.items.len -| (self.render.candidate.?.begin -| self.base) > 64 * 1024))
            {
                self.limit = .window;
                self.render_valid = false;
                return;
            }
        }
        self.pinned = true;
    }

    /// Discard a frame without acknowledging it: unacknowledged source and rows
    /// are retained, and the next build re-renders the same window.
    pub fn abort(self: *Body) void {
        self.pinned = false;
        self.render_valid = false;
        // A discarded frame never publishes its freeze decisions; committed
        // decisions and the retained source are untouched.
        self.frame_frozen_count = 0;
        self.pruneFrozen();
    }

    const TableAck = struct {
        covered: usize = 0,
        row: ?usize = null,
        column: usize = 0,
        delivered: [max_columns]usize = @splat(0),
        settled: u32 = 0,
        /// Column count / alignments of the table segment being acknowledged.
        columns: usize = 0,
        alignments: [32]c_int = @splat(0),
        top_done: bool = false,
        head_done: bool = false,
        sep_done: bool = false,
        in_header: bool = false,
        closed: bool = false,
        stopped: bool = false,
    };

    const RowAck = struct {
        covered: usize = 0,
        column: usize = 0,
        delivered: [max_columns]usize = @splat(0),
        settled: u32 = 0,
        columns: usize = 0,
        alignments: [32]c_int = @splat(0),
        header: bool = false,
        stopped: bool = false,
    };

    /// Full fresh ACK: retire exactly `count` written rows and the source they
    /// displayed. Never called for a partial write.
    pub fn commit(self: *Body, count: usize) !usize {
        if (self.limit == .memory or self.limit == .refs or self.limit == .ambiguity or self.limit == .containers) return 0;
        if (self.hasMetadataProgress()) {
            const metadata = self.render.metadata.?;
            const size = metadata.cut - self.base;
            const spans = if (self.ctx.kind == .table) self.confirmed.items else self.render.confirmed;
            if (!try self.publishCommit(metadata.next, spans, metadata.cut)) {
                self.pinned = false;
                self.resetRender();
                return 0;
            }
            const keep = self.source.items.len - size;
            std.mem.copyForwards(u8, self.source.items[0..keep], self.source.items[size..]);
            self.source.shrinkRetainingCapacity(keep);
            self.base += size;
            self.mergeFrameFrozen();
            self.pruneFrozen();
            self.inline_resume = metadata.inline_resume;
            self.pinned = false;
            if (builtin.is_test) self.stats.retired_bytes += size;
            self.resetRender();
            return 0;
        }
        const rows = self.render.rows;
        const requested = @min(count, rows.len);
        if (rows.len == 0) {
            // A fresh empty frame owns no semantic decision if it retired no
            // source. Keep an unchanged cache, but allow a pending append or
            // EOF (which invalidated it) to be parsed on the next build.
            self.pinned = false;
            self.frame_frozen_count = 0;
            return 0;
        }
        if (requested == 0) return 0;
        // Recompute the frame proposal for exactly the ACKed prefix. A caller
        // may commit directly without releaseLimit, or may acknowledge fewer
        // rows than a previously prepared release. Neither case may publish a
        // freeze authorized only by a larger prefix.
        self.frame_frozen_count = 0;
        if (self.atomicRelease(requested) > requested) return 0;
        const n = self.releaseLimit(requested);
        if (n == 0 or n > requested) {
            self.frame_frozen_count = 0;
            return 0;
        }
        if (rows[n - 1].table_kind != null) return self.commitTable(n);
        self.pinned = false;
        const len = self.render.source_len;
        var retire: usize = len;
        var next: Ctx = self.render.end;
        var next_inline = false;
        if (n < rows.len) {
            retire = std.math.maxInt(usize);
            for (rows[n..]) |row| {
                if (!row.synthetic) retire = @min(retire, row.start);
            }
            if (retire == std.math.maxInt(usize) or retire > len) {
                // No retained row carries source (context-only rows): retire the
                // source actually displayed by the released rows.
                retire = 0;
                for (rows[0..n]) |row| {
                    if (!row.synthetic) retire = @max(retire, row.end);
                }
                // A purely synthetic frame (closing blank/context rows) can only
                // be retired once the whole frame has been written.
                if (retire == 0 and n == rows.len) retire = len;
                if (retire > len) retire = len;
            }
            var first = n;
            while (first < rows.len and rows[first].leaf >= self.render.leaves.len) first += 1;
            if (first < rows.len) {
                const leaf = self.render.leaves[rows[first].leaf];
                next = leaf.ctx;
                // A continued list/quote row must not print its opener again:
                // mid-line resume and wrapped rows both use the hanging indent.
                if (next.continuation.len != 0 and (first > leaf.row_start or isMidLine(self.source.items, rows[first].start)))
                    next.prefix = next.continuation;
            }
            next_inline = if (retire == 0) self.inline_resume else isMidLine(self.source.items, retire);
        } else {
            next_inline = if (retire == 0) self.inline_resume else isMidLine(self.source.items, retire);
            // EOF closes blocks, but a transport-chunk end is not a document
            // end. When the trailing source is not genuinely blank-terminated,
            // keep the last real leaf/container context so the next chunk
            // continues the same block instead of becoming a new document.
            if (self.render.end_authoritative or self.render.source_len < self.source.items.len) {
                // Work slicing is not EOF: the renderer supplied the exact
                // continuation after this prefix, not the end of the feed.
            } else if (!trailingClosed(self.source.items[0..len], self.render.leaves, self.render.rows)) {
                if (self.render.leaves.len != 0) {
                    next = self.render.leaves[self.render.leaves.len - 1].ctx;
                } else {
                    next = .{ .kind = .container, .prefix = self.ctx.prefix, .continuation = self.ctx.continuation, .style = self.ctx.style };
                }
            } else if (next.kind == .code) {
                // The trailing fence really closed the block.
                next = .{ .kind = .document };
            }
        }
        // A document render closes its last block at EOF, but a missing trailing
        // newline means the physical line is still open. Keep the real leaf
        // context so the fragment resume preserves container indentation.
        if (next_inline and next.kind == .document and self.render.leaves.len != 0) {
            next = self.render.leaves[self.render.leaves.len - 1].ctx;
        }
        if (next_inline and next.prefix.len == 0) {
            // The following physical row already knows the indentation it must
            // use, so a resumed window does not need to reconstruct container
            // bytes that were retired with the previous row.
            if (n < rows.len and rows[n].prefix.len != 0) {
                next.prefix = rows[n].prefix;
                if (next.continuation.len == 0) next.continuation = rows[n].prefix;
            }
        }
        if (next_inline and next.prefix.len == 0 and self.ctx.prefix.len != 0) {
            // The last block was closed by input exhaustion; the physical line is
            // still open, so it continues with the hanging indent, not a new item.
            if (self.ctx.continuation.len != 0) {
                next.prefix = self.ctx.continuation;
                next.continuation = self.ctx.continuation;
            } else next.prefix = self.ctx.prefix;
            if (next.kind == .container or next.kind == .document) next.kind = self.ctx.kind;
        }
        // Only completed physical rows advance generated output. In particular,
        // a yield may leave bytes in the writer's unfinished row.
        const output_cursor = if (n < rows.len) rows[n].output_start else rows[n - 1].output_end;
        const output_window = if (n < rows.len) rows[n].output_window else rows[n - 1].output_window;
        for (self.render.confirmed) |span| {
            if (span.output_window == output_window and
                (span.suffix_pending or (output_cursor >= span.suffix_start and output_cursor < span.suffix_end)))
                retire = @min(retire, span.closer_begin -| self.base);
        }
        // An unresolved native candidate keeps its own source mutable even if a
        // caller ACKed the rows that provisionally displayed it.
        if (self.candidateHold()) |hold| retire = @min(retire, hold -| self.base);
        next_inline = if (retire == 0) self.inline_resume else isMidLine(self.source.items, retire);
        // At an unacknowledged native table candidate boundary the retained
        // header must return to block grammar, not a paragraph fragment. Keep
        // the parent presentation context, but not the previous paragraph.
        if (retire != 0) if (self.candidateHold()) |hold| {
            if (self.base + retire == hold and self.render.candidate.?.reason == md.candidate_table) {
                next_inline = false;
                if (next.kind == .paragraph) next.kind = if (next.prefix.len == 0) .document else .container;
            }
        };
        // A preceding list marker can be a prose row even though native has
        // already proven the following table. Preserve that exact table proof if
        // the ACK reaches or cuts into its header, before releasing the source prefix.
        for (rows[n..]) |row| {
            if (row.table_kind == null or row.leaf >= self.render.leaves.len) continue;
            const proof = self.render.leaves[row.leaf].ctx;
            if (proof.kind == .table and proof.table_header_complete and
                proof.table_body_begin > proof.table_header_begin and
                proof.table_header.len == proof.table_body_begin - proof.table_header_begin and
                retire != 0 and self.base + retire >= proof.table_header_begin and self.base + retire < proof.table_body_begin)
            {
                for (self.render.cells) |cell| {
                    if (cell.header and cell.present and cell.begin >= proof.table_header_begin and cell.begin < proof.table_body_begin)
                        retire = @min(retire, cell.begin -| self.base);
                }
                if (retire != 0 and self.base + retire >= proof.table_header_begin) {
                    next = proof;
                    next_inline = false;
                }
            }
            break;
        }
        // Capture the frame's semantic checkpoint BEFORE releasing its arena.
        // Appends may have arrived since build(), but cannot change this snapshot.
        const cut = self.base + retire;
        var confirmed: std.ArrayList(markdown.ConfirmedSpan) = .empty;
        defer confirmed.deinit(self.a);
        for (self.render.confirmed) |span| {
            if (span.opener_end <= cut and span.closer_end > cut) {
                var checkpoint = span;
                if (span.output_window == output_window)
                    checkpoint.suffix_skip += @min(output_cursor -| span.suffix_start, span.suffix_end -| span.suffix_start);
                try confirmed.append(self.a, checkpoint);
            }
        }
        if (!try self.publishCommit(next, confirmed.items, cut)) {
            self.pinned = false;
            self.resetRender();
            return 0;
        }
        if (retire != 0) {
            const keep = self.source.items.len - retire;
            std.mem.copyForwards(u8, self.source.items[0..keep], self.source.items[retire..]);
            self.source.shrinkRetainingCapacity(keep);
            self.base += retire;
            if (builtin.is_test) self.stats.retired_bytes += retire;
        }
        self.mergeFrameFrozen();
        self.pruneFrozen();
        self.inline_resume = next_inline;
        self.resetRender();
        if (builtin.is_test) self.stats.frozen_rows += n;
        return n;
    }

    /// Stage only a contiguous native-proven prefix. A skipped or nonempty
    /// cell is not metadata proof; unknown columns never authorize a cut.
    fn stageMetadata(self: *const Body) ?Metadata {
        if (self.render.rows.len != 0 or self.render.source_len == 0) return null;
        const end = self.base + self.render.source_len;
        const table = self.ctx.kind == .table or self.render.end.kind == .table or self.frameHasTable();
        if (!table) {
            var cut = end;
            if (self.candidateHold()) |hold| cut = @min(cut, hold);
            // The end checkpoint describes the whole parse, not a candidate
            // prefix. Never publish it at a different source position.
            if (cut <= self.base or cut != end) return null;
            return .{ .cut = cut, .next = self.render.end, .inline_resume = if (self.render.end.kind == .table) isMidLine(self.source.items, cut - self.base) else self.render.end.header_open };
        }
        if (self.ctx.kind != .table or !self.ctx.table_head_done or self.ctx.table_columns == 0) return null;
        var next = self.ctx;
        var cut = self.base;
        var column = self.ctx.table_column;
        var row: ?usize = self.ctx.table_row;
        var first = true;
        var complete = false;
        for (self.render.cells, 0..) |cell, index| {
            if (!cell.present) break;
            if (cell.header or cell.column != column or cell.column >= self.ctx.table_columns) break;
            if (row) |expected| {
                if (cell.row_begin != expected) break;
            } else row = cell.row_begin;
            if (cell.raw_begin < self.base or cell.raw_end > end or cell.next_begin > end or cell.raw_begin < cut) break;
            // A native prefix can precede the first cell only on this physical
            // line; it cannot authorize skipping an earlier unseen row.
            if (first and std.mem.indexOfScalar(u8, self.source.items[0 .. cell.raw_begin - self.base], '\n') != null) break;
            if (!first and cell.raw_begin != cut) break;
            if (self.ctx.table_delivered[column] > cell.raw_begin) break;
            const trims = !first or !self.inline_resume or self.ctx.table_trim_leading;
            next.table_column = column;
            next.table_row = row;
            if (!(cell.cell_complete and cell.begin == cell.end)) {
                // An unfinished cell's whitespace can become interior payload.
                // Only native-proven leading trim is safe before completion.
                if (!trims) break;
                cut = cell.begin;
                next.table_trim_leading = true;
                break;
            }
            // No skip was applied (checked above), and native proved this cell
            // complete and empty. Its trailing blanks and actual separator or
            // line ending are syntax even after previously displayed payload.
            cut = cell.next_begin;
            column += 1;
            next.table_column = column;
            next.table_trim_leading = true;
            first = false;
            if (cell.row_complete and cell.next_begin >= cell.row_end) {
                // Missing cells are proof only when native explicitly reported
                // each remaining padding column for this exact logical row.
                var expected = column;
                var proof_index = index + 1;
                while (expected < self.ctx.table_columns and proof_index < self.render.cells.len) : (proof_index += 1) {
                    const padding = self.render.cells[proof_index];
                    if (padding.row_begin != cell.row_begin or padding.column != expected or padding.present or
                        !padding.cell_complete or !padding.row_complete) break;
                    expected += 1;
                }
                if (expected == self.ctx.table_columns) {
                    complete = true;
                    break;
                }
                // Do not publish a cut past the physical row ending while an
                // unreported column could still contain payload.
                return null;
            }
            if (column >= self.ctx.table_columns) break;
        }
        if (cut <= self.base) return null;
        if (self.candidateHold()) |hold| if (cut > hold) return null;
        for (self.render.confirmed) |span| {
            if (span.opener_begin < cut and span.closer_end > self.base) return null;
        }
        if (complete) {
            next.table_row = null;
            next.table_row_had_output = false;
            next.table_column = 0;
            next.table_delivered = @splat(0);
            next.table_settled = 0;
            next.table_trim_leading = false;
        } else if (next.table_column >= self.ctx.table_columns) return null;
        return .{ .cut = cut, .next = next, .inline_resume = isMidLine(self.source.items, cut - self.base) };
    }

    fn frameHasTable(self: *const Body) bool {
        for (self.render.rows) |row| {
            if (row.table_kind != null) return true;
        }
        return false;
    }

    fn tableColumns(self: *const Body) usize {
        const columns = if (self.ctx.kind == .table and self.ctx.table_columns != 0)
            self.ctx.table_columns
        else
            self.render.end.table_columns;
        return @min(columns, max_columns);
    }

    fn tableAlignments(self: *const Body) [32]c_int {
        if (self.ctx.kind == .table and self.ctx.table_columns != 0) return self.ctx.table_align;
        return self.render.end.table_align;
    }

    fn tableContinuation(self: *const Body) markdown.TableContinuation {
        return .{
            .columns = self.ctx.table_columns,
            .header = self.ctx.table_header,
            .header_begin = self.ctx.table_header_begin,
            .body_begin = self.ctx.table_body_begin,
            .header_complete = self.ctx.table_header_complete,
            .first_column = self.ctx.table_column,
            .alignments = self.ctx.table_align,
            .delivered = self.ctx.table_delivered,
            .partial_cell = self.inline_resume,
            .trim_leading = self.ctx.table_trim_leading,
            .containers = self.ctx.table_containers,
            .first_line_partial = self.inline_resume,
            .header_done = self.ctx.table_head_done and self.ctx.table_sep_done,
            .top_done = self.ctx.table_top_done,
            .separator_pending = self.ctx.table_head_done and !self.ctx.table_sep_done,
            .row_had_output = self.ctx.table_row_had_output,
            .row_begin = self.ctx.table_row,
            .prefix = self.ctx.prefix,
            .continuation = self.ctx.continuation,
        };
    }

    /// Container/prefix context of the exact table being acknowledged. A window
    /// may contain the close of one table and the start of another: the new
    /// table's own top border identifies where that segment begins, and only the
    /// acknowledged rows decide which table is current. A table resumed from an
    /// earlier frame has no top border here and keeps `self.ctx`.
    fn tableCtxForAck(self: *const Body, requested: usize) Ctx {
        const rows = self.render.rows;
        var segment_start: ?usize = null;
        var index: usize = 0;
        while (index < @min(requested, rows.len)) : (index += 1) {
            if (rows[index].table_kind == .top) segment_start = index;
        }
        if (segment_start == null and self.ctx.kind == .table) return self.ctx;
        const row_index = segment_start orelse 0;
        if (rows.len != 0 and row_index < rows.len) {
            const leaf = rows[row_index].leaf;
            if (leaf < self.render.leaves.len) return self.render.leaves[leaf].ctx;
        }
        return self.ctx;
    }

    /// Contiguous source (window-relative) represented by the first `count`
    /// rows. Prose uses row spans; a table resolves per-column progress and
    /// never jumps over an undisplayed earlier column.
    fn frameCoverage(self: *const Body, count: usize, retire_mode: bool) usize {
        const rows = self.render.rows;
        const n = @min(count, rows.len);
        if (n == 0) return 0;
        var has_table = false;
        for (rows[0..n]) |row| {
            if (row.table_kind != null) {
                has_table = true;
                break;
            }
        }
        if (!has_table) return self.proseCoverage(n);
        return @min(self.tableAck(n, retire_mode).covered, self.render.source_len);
    }

    fn proseCoverage(self: *const Body, count: usize) usize {
        const rows = self.render.rows;
        const n = @min(count, rows.len);
        const limit = self.render.source_len;
        var end: usize = 0;
        for (rows[0..n]) |row| {
            if (row.synthetic) continue;
            end = @max(end, @min(row.end, limit));
        }
        if (n < rows.len and !rows[n].synthetic and rows[n].start != std.math.maxInt(usize))
            end = @min(end, rows[n].start);
        const output_cursor = rows[n - 1].output_end;
        const output_window = rows[n - 1].output_window;
        for (self.render.confirmed) |span| {
            const begin = span.closer_begin -| self.base;
            if (span.suffix_pending) {
                end = @min(end, begin);
            } else if (span.column == std.math.maxInt(usize) and span.output_window == output_window and
                output_cursor >= span.suffix_end and end >= begin)
            {
                end = @max(end, @min(span.closer_end -| self.base, limit));
            }
        }
        if (n < rows.len and !rows[n].synthetic and spanBoundaryAfter(self.render.confirmed, rows[n]))
            end = @min(end, rows[n].start);
        if (end != 0 and end < limit and end < self.source.items.len and self.source.items[end] == '\n') end += 1;
        return @min(end, limit);
    }

    /// Column count and alignments of the table segment whose first row is at
    /// `index` (used when the ACK stops on a border before any cell is read).
    fn tableSegmentGeometry(self: *const Body, index: usize) struct { columns: usize, alignments: [32]c_int } {
        if (index < self.render.rows.len) {
            const leaf_index = self.render.rows[index].leaf;
            if (leaf_index < self.render.leaves.len) {
                const ctx = self.render.leaves[leaf_index].ctx;
                if (ctx.kind == .table and ctx.table_columns != 0)
                    return .{ .columns = @min(ctx.table_columns, max_columns), .alignments = ctx.table_align };
            }
        }
        if (self.ctx.kind == .table)
            return .{ .columns = @min(self.ctx.table_columns, max_columns), .alignments = self.ctx.table_align };
        return .{ .columns = 0, .alignments = @splat(0) };
    }

    /// Per-column progress of the acknowledged prefix. `retire_mode` applies
    /// the strict retirement policy (an incompletely acknowledged header row
    /// keeps all of its source); visibility only needs the represented prefix.
    fn tableAck(self: *const Body, count: usize, retire_mode: bool) TableAck {
        const rows = self.render.rows;
        const n = @min(count, rows.len);
        const limit = self.render.source_len;
        const src = self.source.items;
        var ack: TableAck = .{
            .top_done = self.ctx.table_top_done,
            .head_done = self.ctx.table_head_done,
            .sep_done = self.ctx.table_sep_done,
            .row = self.ctx.table_row,
            .column = self.ctx.table_column,
            .delivered = self.ctx.table_delivered,
            .settled = self.ctx.table_settled,
        };
        if (self.ctx.kind != .table) {
            ack.top_done = false;
            ack.head_done = false;
            ack.sep_done = false;
            ack.row = null;
            ack.column = 0;
            ack.delivered = @splat(0);
            ack.settled = 0;
        }
        var i: usize = 0;
        while (i < n and rows[i].table_kind == null) i += 1;
        if (i == n) return ack;
        const initial_geometry = self.tableSegmentGeometry(i);
        if (initial_geometry.columns == 0) return ack;
        ack.columns = initial_geometry.columns;
        ack.alignments = initial_geometry.alignments;
        // Rows before the first table are ordinary displayed rows: their source
        // is a safe prefix even while a table header still lacks a checkpoint.
        // A resumed table window already starts at the table's own line.
        var cursor: usize = if (self.ctx.kind == .table) 0 else self.tableLineStart(i);
        var cells_at: usize = 0;
        while (i < n) {
            if (rows[i].table_kind == null) {
                // A table closed inside this frame. Ordinary rows after it share
                // the same source prefix; another table is a new segment.
                var end = cursor;
                while (i < n and rows[i].table_kind == null) : (i += 1) {
                    if (rows[i].synthetic) continue;
                    end = @max(end, @min(rows[i].end, limit));
                }
                if (i < n and !rows[i].synthetic) end = @min(end, rows[i].start);
                if (i == n and n < rows.len and !rows[n].synthetic) end = @min(end, rows[n].start);
                cursor = @max(cursor, @min(end, limit));
                if (i >= n) break;
                ack.top_done = false;
                ack.head_done = false;
                ack.sep_done = false;
                ack.closed = false;
                ack.row = null;
                ack.column = 0;
                ack.delivered = @splat(0);
                ack.settled = 0;
                ack.columns = 0;
                ack.alignments = @splat(0);
                ack.in_header = false;
                cursor = @max(cursor, self.tableLineStart(i));
                continue;
            }
            const row = rows[i];
            const kind = row.table_kind.?;
            if (kind == .top) {
                ack.top_done = true;
                ack.head_done = false;
                ack.sep_done = false;
                ack.closed = false;
                // A border-only ACK must still remember THIS table's geometry,
                // not the last table's leaf in the window.
                const geometry = self.tableSegmentGeometry(i);
                if (geometry.columns != 0) {
                    ack.columns = geometry.columns;
                    ack.alignments = geometry.alignments;
                }
                i += 1;
                continue;
            }
            if (kind == .middle) {
                // The header row's data rows all belong to earlier frames (their
                // source was already written). The separator's own checkpoint
                // proves the header cells were fully materialized and terminated.
                if (!ack.head_done and ack.row != null) {
                    if (row.table_checkpoint) |separator| {
                        const row_ack = self.tableRowAck(ack.row.?, &.{}, rows, n, &cells_at, cursor, separator.settled, i);
                        if (row_ack.stopped) {
                            ack.stopped = true;
                            ack.column = row_ack.column;
                            ack.delivered = row_ack.delivered;
                            ack.settled = row_ack.settled;
                            ack.columns = row_ack.columns;
                            ack.alignments = row_ack.alignments;
                            ack.in_header = true;
                            ack.covered = if (retire_mode) cursor else @min(row_ack.covered, limit);
                            return ack;
                        }
                        cursor = @min(row_ack.covered, limit);
                        ack.columns = row_ack.columns;
                        ack.alignments = row_ack.alignments;
                        ack.head_done = true;
                        ack.row = null;
                        ack.column = 0;
                        ack.delivered = @splat(0);
                        ack.settled = 0;
                    }
                }
                ack.sep_done = true;
                i += 1;
                continue;
            }
            if (kind == .bottom) {
                ack.closed = true;
                // The border was produced by the closing blank line; that line
                // is syntax of the acknowledged border, never later content.
                var pos = cursor;
                while (blankLineEnd(src, pos, limit)) |next| pos = next;
                cursor = pos;
                i += 1;
                continue;
            }
            const checkpoint = row.table_checkpoint orelse {
                i += 1;
                continue;
            };
            const row_begin = checkpoint.row_begin;
            var j = i;
            while (j + 1 < n) {
                const next = rows[j + 1];
                if (next.table_kind != .data) break;
                const next_checkpoint = next.table_checkpoint orelse break;
                if (next_checkpoint.row_begin != row_begin) break;
                j += 1;
            }
            const row_ack = self.tableRowAck(row_begin, rows[i .. j + 1], rows, n, &cells_at, cursor, 0, i);
            if (row_ack.stopped) {
                ack.stopped = true;
                ack.row = row_begin;
                ack.column = row_ack.column;
                ack.delivered = row_ack.delivered;
                ack.settled = row_ack.settled;
                ack.columns = row_ack.columns;
                ack.alignments = row_ack.alignments;
                ack.in_header = row_ack.header;
                ack.covered = @min(row_ack.covered, limit);
                if (retire_mode and row_ack.header and !self.ctx.table_head_done) {
                    // The header is re-parsed until its own row (and the
                    // delimiter line) are fully proven; the compositor skips
                    // the physical lines already written.
                    ack.covered = cursor;
                }
                return ack;
            }
            cursor = @min(row_ack.covered, limit);
            ack.row = null;
            ack.column = 0;
            ack.delivered = @splat(0);
            ack.settled = 0;
            ack.columns = row_ack.columns;
            ack.alignments = row_ack.alignments;
            ack.in_header = false;
            if (row_ack.header) ack.head_done = true;
            i = j + 1;
        }
        ack.covered = @min(cursor, limit);
        return ack;
    }

    /// Start of the physical line that owns the first table row at `index`.
    fn tableLineStart(self: *const Body, index: usize) usize {
        const rows = self.render.rows;
        if (index >= rows.len) return 0;
        // Border rows inherit the current logical row's checkpoint, so the first
        // cell of THIS table segment locates its physical line start.
        const checkpoint = rows[index].table_checkpoint orelse return 0;
        var column_begin: ?usize = null;
        for (self.render.cells) |cell| {
            if (cell.row_begin != checkpoint.row_begin or !cell.present) continue;
            column_begin = cell.begin -| self.base;
            break;
        }
        const from = column_begin orelse return 0;
        return lineStart(self.source.items, @min(from, self.render.source_len));
    }

    /// Contiguous progress of one logical table row over the acknowledged
    /// physical rows. Cells keep their own column identity, and the row's own
    /// column count comes from this row's native table leaf.
    fn tableRowAck(self: *const Body, row_begin: usize, group: []const Row, all: []const Row, acked: usize, cells_at: *usize, start: usize, hint_settled: u32, row_index: usize) RowAck {
        const limit = self.render.source_len;
        const src = self.source.items;
        const base = self.base;
        const resumed = self.ctx.kind == .table and self.ctx.table_row != null and self.ctx.table_row.? == row_begin;
        var delivered: [max_columns]usize = if (resumed) self.ctx.table_delivered else @splat(0);
        var settled: u32 = (if (resumed) self.ctx.table_settled else 0) | hint_settled;
        while (cells_at.* < self.render.cells.len and self.render.cells[cells_at.*].row_begin != row_begin) cells_at.* += 1;
        const cell_first = cells_at.*;
        while (cells_at.* < self.render.cells.len and self.render.cells[cells_at.*].row_begin == row_begin) cells_at.* += 1;
        const cells = self.render.cells[cell_first..cells_at.*];
        var header = false;
        for (cells) |cell| {
            if (cell.header) header = true;
        }
        if (cells.len == 0) {
            if (self.ctx.kind == .table and !self.ctx.table_head_done) header = true;
            return .{ .covered = start, .column = 0, .delivered = delivered, .settled = settled, .header = header, .stopped = true };
        }
        const geometry = self.tableSegmentGeometry(row_index);
        const columns = geometry.columns;
        if (columns == 0) return .{ .covered = start, .column = 0, .delivered = delivered, .settled = settled, .header = header, .stopped = true };
        var alignments: [32]c_int = geometry.alignments;
        for (cells) |cell| {
            if (cell.column < 32) alignments[cell.column] = cell.alignment;
        }
        var cov: [max_columns]usize = @splat(0);
        for (group) |row| {
            const checkpoint = row.table_checkpoint orelse continue;
            if (checkpoint.settled != 0) settled |= checkpoint.settled;
            for (checkpoint.delivered, 0..) |value, c| {
                if (value > delivered[c]) delivered[c] = value;
            }
            for (row.table_occurrences) |occurrence| {
                const c = occurrence.column;
                if (c >= columns or occurrence.segment.generated) continue;
                const stop = @min(occurrence.segment.end, limit);
                if (stop > cov[c]) cov[c] = stop;
            }
        }
        for (0..columns) |c| {
            if (delivered[c] > base) cov[c] = @max(cov[c], @min(delivered[c] - base, limit));
        }
        // The first unwritten physical row of this same logical row may share an
        // atomic source occurrence; never retire half of it.
        if (acked < all.len) {
            var k = acked;
            while (k < all.len) : (k += 1) {
                const next = all[k];
                if (next.table_kind != .data) break;
                const checkpoint = next.table_checkpoint orelse break;
                if (checkpoint.row_begin != row_begin) break;
                for (next.table_occurrences) |occurrence| {
                    const c = occurrence.column;
                    if (c < columns and !occurrence.segment.generated and occurrence.segment.start < cov[c]) cov[c] = occurrence.segment.start;
                }
                break;
            }
        }
        var covered = start;
        var stop_pos = start;
        var anchor_column: usize = 0;
        var anchor_end = start;
        var row_end = start;
        var row_complete = true;
        var observed: u32 = 0;
        for (cells) |cell| {
            const c = cell.column;
            if (c >= columns) continue;
            observed |= @as(u32, 1) << @intCast(c);
            const cell_begin = cell.begin -| base;
            const cell_end = @min(cell.end -| base, limit);
            const cell_settled = (settled & (@as(u32, 1) << @intCast(c))) != 0;
            if (!cell.present) {
                if (cell.cell_complete and cell.row_complete) continue;
                var next_delivered = delivered;
                next_delivered[anchor_column] = @max(next_delivered[anchor_column], anchor_end + base);
                return .{ .covered = @min(@max(covered, stop_pos), limit), .column = anchor_column, .delivered = next_delivered, .settled = settled, .columns = columns, .alignments = alignments, .header = header, .stopped = true };
            }
            var value = @min(@max(cell_begin, cov[c]), cell_end);
            if (cell_settled and cell.cell_complete) value = cell_end;
            if (value < cell_end) {
                var next_delivered = delivered;
                next_delivered[c] = @max(next_delivered[c], value + base);
                return .{ .covered = @min(value, limit), .column = c, .delivered = next_delivered, .settled = settled, .columns = columns, .alignments = alignments, .header = header, .stopped = true };
            }
            covered = @max(covered, cell_end);
            row_end = @max(row_end, @min(cell.row_end -| base, limit));
            if (!cell.row_complete) row_complete = false;
            if (!cell.cell_complete) {
                var next_delivered = delivered;
                next_delivered[c] = @max(next_delivered[c], cell_end + base);
                return .{ .covered = @min(covered, limit), .column = c, .delivered = next_delivered, .settled = settled, .columns = columns, .alignments = alignments, .header = header, .stopped = true };
            }
            var pos = cell_end;
            while (pos < limit and (src[pos] == ' ' or src[pos] == '\t')) pos += 1;
            stop_pos = pos;
            anchor_column = c;
            anchor_end = cell_end;
        }
        const first_column = if (resumed) @min(self.ctx.table_column, columns) else 0;
        for (first_column..columns) |c| {
            if ((observed & (@as(u32, 1) << @intCast(c))) == 0) row_complete = false;
        }
        if (!row_complete) {
            var next_delivered = delivered;
            next_delivered[anchor_column] = @max(next_delivered[anchor_column], anchor_end + base);
            return .{ .covered = @min(@max(covered, stop_pos), limit), .column = anchor_column, .delivered = next_delivered, .settled = settled, .columns = columns, .alignments = alignments, .header = header, .stopped = true };
        }
        var pos = row_end;
        while (pos < limit and (src[pos] == ' ' or src[pos] == '\t')) pos += 1;
        const line_break = eolLength(src, pos, limit);
        if (line_break != 0) {
            pos += line_break;
        } else if (pos < limit) {
            var next_delivered = delivered;
            next_delivered[anchor_column] = @max(next_delivered[anchor_column], anchor_end + base);
            return .{ .covered = @min(covered, limit), .column = anchor_column, .delivered = next_delivered, .settled = settled, .columns = columns, .alignments = alignments, .header = header, .stopped = true };
        }
        if (header) {
            const leaf_index = if (row_index < all.len) all[row_index].leaf else self.render.leaves.len;
            const proof = if (leaf_index < self.render.leaves.len) self.render.leaves[leaf_index].ctx else self.ctx;
            const retained_header_proof = self.ctx.kind == .table and self.ctx.table_header_complete and
                self.ctx.table_header_begin == proof.table_header_begin and self.ctx.table_body_begin == proof.table_body_begin and
                self.ctx.table_header.len == proof.table_body_begin -| proof.table_header_begin;
            if (!proof.table_header_complete or proof.table_body_begin <= proof.table_header_begin or
                (proof.table_header_begin < base and !retained_header_proof) or proof.table_body_begin > base + limit or
                proof.table_body_begin < base + pos)
                return .{ .covered = start, .column = anchor_column, .delivered = delivered, .settled = settled, .columns = columns, .alignments = alignments, .header = true, .stopped = true };
            pos = proof.table_body_begin - base;
        }
        return .{ .covered = @min(pos, limit), .column = 0, .delivered = @splat(0), .settled = 0, .columns = columns, .alignments = alignments, .header = header, .stopped = false };
    }

    fn commitTable(self: *Body, requested: usize) !usize {
        const rows = self.render.rows;
        const limit = self.render.source_len;
        const ack = self.tableAck(requested, true);
        var covered = @min(ack.covered, limit);
        var cut = self.base + covered;
        var capped_span: ?markdown.ConfirmedSpan = null;
        var confirmed: std.ArrayList(markdown.ConfirmedSpan) = .empty;
        defer confirmed.deinit(self.a);
        const group_output: ?markdown.TableProgress = blk: {
            var k = requested;
            while (k > 0) {
                k -= 1;
                if (rows[k].table_kind != .data) continue;
                break :blk rows[k].table_checkpoint;
            }
            break :blk null;
        };
        for (self.render.confirmed) |span| {
            if (span.opener_end > cut or span.closer_end <= cut) continue;
            const displayed = if (span.column < max_columns) (if (group_output) |checkpoint| checkpoint.output_bytes[span.column] else 0) else 0;
            if (!span.suffix_pending and displayed >= span.suffix_end) {
                // Every generated suffix byte was written; its exact source
                // anchor is part of the displayed row.
                covered = @max(covered, @min(span.closer_end -| self.base, limit));
                cut = self.base + covered;
                continue;
            }
            covered = @min(covered, span.closer_begin -| self.base);
            cut = self.base + covered;
            var checkpoint = span;
            const skip = @min(displayed -| span.suffix_start, span.suffix.len);
            checkpoint.suffix_skip = span.suffix_skip + skip;
            capped_span = checkpoint;
            try confirmed.append(self.a, checkpoint);
        }
        // A candidate never lives inside a table row, but a trailing candidate
        // after it still caps this frame's cut.
        if (self.candidateHold()) |hold| covered = @min(covered, hold -| self.base);
        const retire = @min(covered, limit);
        // A header-phase table (or a table that starts later in a multi-table
        // window) has no committed table Ctx yet: take the exact current table's
        // own leaf (prefix/continuation/container snapshot), never the window's
        // last leaf.
        var next: Ctx = self.tableCtxForAck(requested);
        next.table_columns = if (ack.columns != 0) ack.columns else self.tableColumns();
        next.table_align = if (ack.columns != 0) ack.alignments else self.tableAlignments();
        next.table_column = ack.column;
        next.table_delivered = ack.delivered;
        next.table_row = ack.row;
        next.table_row_had_output = ack.row != null;
        next.table_trim_leading = false;
        if (retire == 0 and ack.column == self.ctx.table_column) {
            next.table_trim_leading = self.ctx.table_trim_leading;
        } else if (ack.column < max_columns) {
            for (self.render.cells) |cell| {
                if (!cell.present or cell.column != ack.column or cell.header) continue;
                if (self.base + retire >= cell.raw_begin and self.base + retire <= cell.begin and
                    ack.delivered[ack.column] <= cell.raw_begin and
                    (ack.column != self.ctx.table_column or !self.inline_resume or self.ctx.table_trim_leading))
                    next.table_trim_leading = true;
                break;
            }
        }
        next.table_settled = ack.settled;
        next.table_top_done = ack.top_done;
        next.table_head_done = ack.head_done;
        next.table_sep_done = ack.sep_done;
        if (ack.closed) {
            next = .{ .kind = .document, .prefix = self.ctx.prefix, .continuation = self.ctx.continuation, .style = self.ctx.style };
        } else {
            next.kind = .table;
            if (capped_span) |span| {
                next.table_row = ack.row orelse self.ctx.table_row;
                next.table_row_had_output = next.table_row != null;
                if (span.column < max_columns) {
                    next.table_column = span.column;
                    next.table_delivered[span.column] = @max(next.table_delivered[span.column], self.base + retire);
                }
            }
        }
        const next_inline = if (retire == 0) self.inline_resume else isMidLine(self.source.items, retire);
        if (!try self.publishCommit(next, confirmed.items, self.base + retire)) {
            self.pinned = false;
            self.resetRender();
            return 0;
        }
        if (retire != 0) {
            const keep = self.source.items.len - retire;
            std.mem.copyForwards(u8, self.source.items[0..keep], self.source.items[retire..]);
            self.source.shrinkRetainingCapacity(keep);
            self.base += retire;
            if (builtin.is_test) self.stats.retired_bytes += retire;
        }
        self.mergeFrameFrozen();
        self.pruneFrozen();
        self.inline_resume = next_inline;
        self.pinned = false;
        self.resetRender();
        if (builtin.is_test) self.stats.frozen_rows += requested;
        return requested;
    }

    /// True when the retained source really ended the last block: a trailing
    /// blank line, or a closed fenced-code line. End-of-input alone is not a
    /// document end for a streamed transport.
    fn trailingClosed(source: []const u8, leaves: []const Leaf, _: []const Row) bool {
        if (source.len == 0) return true;
        var end = source.len;
        if (source[end - 1] == '\n') end -= 1;
        var start = end;
        while (start > 0 and source[start - 1] != '\n') start -= 1;
        const last = std.mem.trim(u8, source[start..end], " \t\r");
        if (leaves.len != 0) {
            const leaf = leaves[leaves.len - 1];
            if (leaf.ctx.kind == .code and !leaf.ctx.indented)
                return leaf.ctx.closing_end != null;
        }
        return last.len == 0;
    }

    fn isMidLine(source: []const u8, offset: usize) bool {
        if (offset == 0 or offset > source.len) return false;
        return source[offset - 1] != '\n';
    }

    fn setCtx(self: *Body, ctx: Ctx, spans: []const markdown.ConfirmedSpan, cut: usize) !void {
        var next_arena = std.heap.ArenaAllocator.init(self.a);
        errdefer next_arena.deinit();
        const arena = next_arena.allocator();
        const next: Ctx = .{
            .kind = ctx.kind,
            .style = ctx.style,
            .fence = ctx.fence,
            .fence_length = ctx.fence_length,
            .header_open = ctx.header_open,
            .header_run = ctx.header_run,
            .closing_begin = ctx.closing_begin,
            .closing_end = ctx.closing_end,
            .indented = ctx.indented,
            .prefix = try arena.dupe(u8, ctx.prefix),
            .continuation = try arena.dupe(u8, ctx.continuation),
            .table_header = try arena.dupe(u8, ctx.table_header),
            .table_header_begin = ctx.table_header_begin,
            .table_body_begin = ctx.table_body_begin,
            .table_header_complete = ctx.table_header_complete,
            .table_columns = ctx.table_columns,
            .table_align = ctx.table_align,
            .table_containers = try arena.dupe(md.TableContainer, ctx.table_containers),
            .table_column = ctx.table_column,
            .table_delivered = ctx.table_delivered,
            .table_row = ctx.table_row,
            .table_row_had_output = ctx.table_row_had_output,
            .table_trim_leading = ctx.table_trim_leading,
            .table_settled = ctx.table_settled,
            .table_top_done = ctx.table_top_done,
            .table_head_done = ctx.table_head_done,
            .table_sep_done = ctx.table_sep_done,
        };
        const next_spans = try arena.alloc(markdown.ConfirmedSpan, spans.len);
        for (spans, next_spans) |span, *destination| destination.* = try span.clone(arena, cut);
        self.ctx_arena.deinit();
        self.ctx_arena = next_arena;
        self.ctx = next;
        self.confirmed = .{ .items = next_spans, .capacity = next_spans.len, .pointer_stability = .{} };
    }

    fn renderAttempt(self: *Body) !void {
        // Slicing controls THIS operation's work only. It neither drops input
        // nor pretends to finish the provider's physical line/document.
        const accepted = self.source.items;
        const final = self.finished;
        var size = @min(accepted.len, @max(4, self.max_window_bytes));
        while (size < accepted.len and accepted[size] & 0xc0 == 0x80) size += 1;
        // Established table rows continue inside a bounded quantum: native
        // partial input reports the trailing cell as incomplete, so a huge cell
        // is parsed once per displayed checkpoint instead of whole-line.
        const table_phase = self.ctx.kind == .table and self.ctx.table_columns != 0 and self.ctx.table_head_done;
        if (!table_phase) {
            // Prefer a physical-line boundary within a bounded lookahead: setext,
            // table and container decisions are line-granular. A genuinely huge
            // single line falls back to the documented freeze-at-display policy.
            // A not-yet-retired table header always keeps this lookahead: native
            // recognition needs its delimiter line in the same window.
            const lookahead = !self.finished or self.ctx.kind == .table or self.final_metadata_lookahead;
            if (lookahead and size < accepted.len and accepted[size - 1] != '\n') {
                if (std.mem.indexOfScalarPos(u8, accepted, size, '\n')) |end| {
                    if (end + 1 - size <= 64 * 1024) size = end + 1;
                } else if (self.final_metadata_lookahead and accepted.len - size <= 64 * 1024) {
                    size = accepted.len;
                }
            }
            // Include one further complete line so a setext underline, table
            // delimiter or paragraph continuation is decided with native grammar
            // instead of being guessed at a cut boundary.
            if (lookahead and size < accepted.len and accepted[size - 1] == '\n') {
                if (std.mem.indexOfScalarPos(u8, accepted, size, '\n')) |end| {
                    if (end + 1 - size <= 64 * 1024) size = end + 1;
                } else if (self.final_metadata_lookahead and accepted.len - size <= 64 * 1024) {
                    size = accepted.len;
                }
            }
        }
        for (self.confirmed.items) |span| {
            const begin = span.closer_begin -| self.base;
            const end = span.closer_end -| self.base;
            // A known delimiter/URL has already been analyzed. Consume its
            // exact syntax atomically rather than re-scan or split it.
            if (begin < size and end > size) size = @min(end, accepted.len);
        }
        // A cut window must not end in blanks: the document parser trims trailing
        // spaces as a hard-break marker, which would silently drop them. Keep
        // them in the queue for the next window instead.
        if (!final and size == accepted.len) {
            var trimmed = size;
            while (trimmed != 0 and (accepted[trimmed - 1] == ' ' or accepted[trimmed - 1] == '\t')) trimmed -= 1;
            // Keep at least one byte so a blanks-only prefix still progresses.
            if (trimmed != 0) size = trimmed;
        }
        self.source.items = accepted[0..size];
        self.finished = final and size == accepted.len;
        self.render_final = self.finished;
        defer {
            self.source.items = accepted;
            self.finished = final;
        }
        // A new render starts a new display frame: only committed freeze
        // decisions survive.
        self.frame_frozen_count = 0;
        self.pruneFrozen();
        var arena = std.heap.ArenaAllocator.init(self.a);
        errdefer arena.deinit();
        const a = arena.allocator();
        var rows: std.ArrayList(Row) = .empty;
        var leaves: std.ArrayList(Leaf) = .empty;
        var confirmed: std.ArrayList(markdown.ConfirmedSpan) = .empty;
        var cells: std.ArrayList(markdown.CellRange) = .empty;
        var accum: Accum = .{ .a = a };
        var end: Ctx = .{};
        var end_document = true;
        var leaf_open = false;
        var source_len = self.source.items.len;
        var authoritative = false;
        var visibility_complete = false;
        if (self.ctx.kind == .table and self.ctx.table_columns != 0) {
            if (self.ctx.table_head_done) {
                source_len = try self.renderTable(a, &rows, &leaves, &confirmed, &cells, &end, &accum);
                end_document = end.kind == .document;
                leaf_open = !end_document;
                authoritative = end.kind == .table;
            } else {
                // Header phase. The retained source starts at the header line, so
                // the document grammar re-derives header, delimiter and body;
                // acknowledged physical rows are presentation proof only.
                const prefix_len = self.base -| self.ctx.table_header_begin;
                if (prefix_len > self.ctx.table_header.len) return error.InvalidMarkdownBlock;
                const input = if (prefix_len == 0) self.source.items else try std.mem.concat(a, u8, &.{ self.ctx.table_header[0..prefix_len], self.source.items });
                const window = try markdown.renderWindow(a, input, .{
                    .columns = self.columns,
                    .ansi = true,
                    .source_base = self.base,
                    .context_bytes = prefix_len,
                    .final = self.render_final,
                    .streaming_tables = true,
                    .references = self.references,
                    .table = self.tableContinuation(),
                    .table_fragment = false,
                    .confirmed = self.confirmed.items,
                    .max_rows = self.max_rows,
                });
                visibility_complete = !window.yielded;
                try accum.add(window);
                try confirmed.appendSlice(a, window.confirmed);
                try cells.appendSlice(a, window.cells);
                try appendRows(a, &rows, window.rows, 0, 0);
                try appendLeaves(a, &leaves, window.leaves, 0);
                end = ctxOf(window.end);
                end_document = window.end_is_document;
                leaf_open = window.leaf_open;
            }
        } else if (self.ctx.kind == .code and !self.ctx.indented and (self.ctx.prefix.len == 0 or self.ctx.header_open)) {
            source_len = try self.renderCode(a, &rows, &leaves, &confirmed, &cells, &end, &accum);
            end_document = end.kind == .document;
            leaf_open = !end_document;
            authoritative = end.kind == .code;
        } else if (self.ctx.kind == .html or (self.inline_resume and self.ctx.kind == .code)) {
            try self.renderLiteralChain(a, &rows, &leaves, &confirmed, &cells, &end, &accum);
            end_document = end.kind == .document;
        } else if (self.inline_resume or self.confirmed.items.len != 0) {
            try self.renderFragment(a, &rows, &leaves, &confirmed, &cells, &end, &end_document, &leaf_open, &accum);
        } else {
            const input, const context_bytes = try self.windowInput(a);
            const window = try markdown.renderWindow(a, input, .{
                .columns = self.columns,
                .ansi = true,
                .context_bytes = context_bytes,
                .source_base = self.base,
                .final = self.render_final,
                .streaming_tables = true,
                .references = self.references,
                .max_rows = self.max_rows,
            });
            visibility_complete = !window.yielded;
            try accum.add(window);
            try confirmed.appendSlice(a, window.confirmed);
            try cells.appendSlice(a, window.cells);
            try appendRows(a, &rows, window.rows, 0, 0);
            try appendLeaves(a, &leaves, window.leaves, 0);
            end = ctxOf(window.end);
            end_document = window.end_is_document;
            leaf_open = window.leaf_open;
        }
        if (rows.items.len > self.max_rows) return error.MarkdownRenderLimit;
        const owned_rows = try rows.toOwnedSlice(a);
        const owned_leaves = try leaves.toOwnedSlice(a);
        const owned_confirmed = try confirmed.toOwnedSlice(a);
        const owned_cells = try cells.toOwnedSlice(a);
        self.render.arena.deinit();
        self.render = .{
            .arena = arena,
            .rows = owned_rows,
            .leaves = owned_leaves,
            .confirmed = owned_confirmed,
            .cells = owned_cells,
            .end = end,
            .end_is_document = end_document,
            .end_authoritative = authoritative,
            .leaf_open = leaf_open,
            .source_len = source_len,
            .visibility_complete = visibility_complete,
            .definitions = try accum.definitions.toOwnedSlice(a),
            .candidate = accum.candidate,
        };
        self.render.metadata = self.stageMetadata();
        self.render_valid = true;
        if (builtin.is_test) {
            self.stats.renders += 1;
            self.stats.window_bytes += self.source.items.len;
            self.stats.rows_rendered += self.render.rows.len;
            self.stats.max_window_bytes = @max(self.stats.max_window_bytes, self.source.items.len);
        }
    }

    /// After a construct ends inside this slice, the remainder is ordinary
    /// document content. Rendering it in the same frame keeps a single ACK from
    /// showing stale rows; the next frame resumes from the recorded context.
    fn renderTail(self: *Body, a: Allocator, rows: *std.ArrayList(Row), leaves: *std.ArrayList(Leaf), confirmed: *std.ArrayList(markdown.ConfirmedSpan), cells: *std.ArrayList(markdown.CellRange), from: usize, end: *Ctx, accum: *Accum) !usize {
        if (from >= self.source.items.len) {
            end.* = .{ .kind = .document };
            return from;
        }
        const rest = self.source.items[from..];
        const row_base = rows.items.len;
        const leaf_base = leaves.items.len;
        const window = try markdown.renderWindow(a, rest, .{
            .columns = self.columns,
            .ansi = true,
            .source_base = self.base + from,
            .final = self.render_final,
            .streaming_tables = true,
            .references = self.references,
            .max_rows = self.max_rows,
        });
        try accum.add(window);
        try confirmed.appendSlice(a, window.confirmed);
        try cells.appendSlice(a, window.cells);
        try appendRows(a, rows, window.rows, from, leaf_base);
        try appendLeaves(a, leaves, window.leaves, row_base);
        end.* = ctxOf(window.end);
        return self.source.items.len;
    }

    fn renderTable(self: *Body, a: Allocator, rows: *std.ArrayList(Row), leaves: *std.ArrayList(Leaf), confirmed: *std.ArrayList(markdown.ConfirmedSpan), cells: *std.ArrayList(markdown.CellRange), end: *Ctx, accum: *Accum) !usize {
        const accepted = self.source.items;
        // Native fragment grammar consumes each physical line's real container
        // prefix, keeps original raw source offsets and reports the exact line
        // where the table ends. Zig must not duplicate that grammar by scanning
        // blank lines or trimming `>`/list indentation itself.
        const window = try markdown.renderWindow(a, accepted, .{
            .columns = self.columns,
            .ansi = true,
            .source_base = self.base,
            .final = self.render_final,
            .streaming_tables = true,
            .references = self.references,
            .table = self.tableContinuation(),
            .table_fragment = true,
            .confirmed = self.confirmed.items,
            .max_rows = self.max_rows,
        });
        try appendRows(a, rows, window.rows, 0, 0);
        try appendLeaves(a, leaves, window.leaves, 0);
        try accum.add(window);
        try confirmed.appendSlice(a, window.confirmed);
        try cells.appendSlice(a, window.cells);
        end.* = self.ctx;
        const table_end = @min(window.table_end, accepted.len);
        // A native-proved container blank/dedent ends the table: emit the bottom
        // border once in this frame, then parse the remaining real source at its
        // original line start as ordinary content.
        if (window.table_closed and table_end < accepted.len)
            return self.renderTail(a, rows, leaves, confirmed, cells, table_end, end, accum);
        return table_end;
    }

    /// The native code recognizer owns only an input quantum and the possible
    /// closing line. The Writer owns a pending Unicode cluster. Neither grows
    /// with the already delivered code block, and no code text goes to md_parse.
    fn renderCode(self: *Body, a: Allocator, rows: *std.ArrayList(Row), leaves: *std.ArrayList(Leaf), confirmed: *std.ArrayList(markdown.ConfirmedSpan), cells: *std.ArrayList(markdown.CellRange), end: *Ctx, accum: *Accum) !usize {
        if (self.ctx.header_open) {
            var header = self.ctx;
            var size: usize = 0;
            while (size < self.source.items.len) {
                const byte = self.source.items[size];
                size += 1;
                if (byte == '\n') {
                    header.header_open = false;
                    header.header_run = false;
                    break;
                }
                if (header.header_run and byte == header.fence)
                    header.fence_length += 1
                else
                    header.header_run = false;
            }
            if (self.finished and size == self.source.items.len) header.header_open = false;
            end.* = header;
            return size;
        }
        const decoder = native.md_stream_code_create(self.ctx.fence, self.ctx.fence_length, 4, 0, 4096, self.base) orelse return error.OutOfMemory;
        defer native.md_stream_code_destroy(decoder);
        if (native.md_stream_code_checkpoint(decoder) != native.code_ok) return error.InvalidMarkdownBlock;
        if (self.inline_resume and native.md_stream_code_literalize(decoder) != native.code_ok) return error.InvalidMarkdownBlock;
        try leaves.append(a, .{ .ctx = self.ctx, .row_start = 0, .row_end = 0 });
        var writer: Writer = .{ .a = a, .columns = self.columns, .ansi = true, .style = self.ctx.style };
        var sink = LiteralSink{ .a = a, .rows = rows, .leaf = 0, .w = &writer };
        writer.sink = .{ .context = &sink, .onRow = LiteralSink.onRow };
        var fed: usize = 0;
        var displayed: usize = 0;
        var scalar: [4]u8 = undefined;
        var scalar_len: usize = 0;
        var scalar_begin: usize = 0;
        var need: usize = 0;
        var closed = false;
        var offered_literal = false;
        while (rows.items.len < 64 or scalar_len != 0) {
            var work: usize = 0;
            var event: native.CodeEvent = undefined;
            var has_event: c_int = 0;
            const result = native.md_stream_code_step(decoder, 4096, &work, &event, &has_event);
            if (result == native.code_error) return error.InvalidMarkdownBlock;
            if (has_event != 0) {
                if (event.kind == 1) {
                    displayed = @intCast(event.end - self.base);
                    closed = true;
                    break;
                }
                if (scalar_len == 0) {
                    scalar_begin = @intCast(event.begin - self.base);
                    need = std.unicode.utf8ByteSequenceLength(event.byte) catch return error.InvalidMarkdownBlock;
                }
                scalar[scalar_len] = event.byte;
                scalar_len += 1;
                if (scalar_len == need) {
                    const stop: usize = @intCast(event.end - self.base);
                    _ = try writer.emitSourcedBounded(scalar[0..scalar_len], scalar_begin, stop, true, 4, 2);
                    displayed = stop;
                    scalar_len = 0;
                }
                continue;
            }
            if (result == native.code_closed) {
                closed = true;
                break;
            }
            if (result == native.code_done) break;
            if (result == native.code_need_input or result == native.code_need_drain) {
                if (fed < self.source.items.len) {
                    if (native.md_stream_code_commit(decoder) != native.code_ok or native.md_stream_code_checkpoint(decoder) != native.code_ok)
                        return error.InvalidMarkdownBlock;
                    const stop = @min(self.source.items.len, fed + 2048);
                    var consumed: usize = 0;
                    const admission = native.md_stream_code_feed_at(decoder, self.base + fed, self.source.items[fed..stop].ptr, stop - fed, @intFromBool(self.finished and stop == self.source.items.len), &consumed);
                    if (admission == native.code_error) return error.InvalidMarkdownBlock;
                    fed += consumed;
                    if (consumed != 0) continue;
                }
                // This is a tentative display interpretation, not an EOF. A
                // dropped frame rebuilds from retained bytes; only ACK freezes it.
                if (!offered_literal) {
                    if (native.md_stream_code_literalize(decoder) != native.code_ok) return error.InvalidMarkdownBlock;
                    offered_literal = true;
                    continue;
                }
                break;
            }
        }
        if (writer.hasContent()) try writer.finish();
        if (rows.items.len == 0 and displayed != 0) try writer.finish();
        leaves.items[0].row_end = rows.items.len;
        if (!closed) {
            end.* = self.ctx;
            end.closing_begin = null;
            end.closing_end = null;
            return displayed;
        }
        end.* = .{ .kind = .document };
        if (displayed < self.source.items.len)
            return self.renderTail(a, rows, leaves, confirmed, cells, displayed, end, accum);
        return displayed;
    }

    /// Build the md input for a context window. The leading context bytes are
    /// synthetic provenance; the rest is unretired source.
    fn windowInput(self: *Body, a: Allocator) !struct { []const u8, usize } {
        var prefix: std.ArrayList(u8) = .empty;
        const ctx = self.ctx;
        if (ctx.kind == .document) return .{ self.source.items, 0 };
        try prefix.appendSlice(a, ctx.prefix);
        if (ctx.kind == .code) {
            if (ctx.indented) {
                try prefix.appendSlice(a, "    ");
            } else {
                for (0..ctx.fence_length) |_| try prefix.append(a, ctx.fence);
            }
        }
        // One sentinel glyph opens the container chain and the leaf; its row is
        // dropped because it has no source provenance.
        try prefix.appendSlice(a, "\x01\n");
        try prefix.appendSlice(a, self.source.items);
        return .{ prefix.items, prefix.items.len - self.source.items.len };
    }

    /// Render the first physical-line fragment with the leaf's preset prefix.
    /// Block constructs cannot start mid-line, so inline grammar is exactly the
    /// right interpretation for this bounded fragment.
    fn renderFragment(self: *Body, a: Allocator, rows: *std.ArrayList(Row), leaves: *std.ArrayList(Leaf), confirmed: *std.ArrayList(markdown.ConfirmedSpan), cells: *std.ArrayList(markdown.CellRange), end: *Ctx, end_document: *bool, leaf_open: *bool, accum: *Accum) !void {
        // A confirmed span can cross physical newlines. Resume through its exact
        // closer before returning to block parsing at the following real LF.
        var boundary: usize = 0;
        for (self.confirmed.items) |span| boundary = @max(boundary, span.closer_end -| self.base);
        boundary = @min(boundary, self.source.items.len);
        const eol = std.mem.indexOfScalarPos(u8, self.source.items, boundary, '\n');
        const end_offset = if (eol) |i| i + 1 else self.source.items.len;
        const fragment = self.source.items[0..end_offset];
        const window = try markdown.renderWindow(a, fragment, .{
            .columns = self.columns,
            .ansi = true,
            .fragment = .{ .kind = self.ctx.kind, .prefix = self.ctx.prefix, .continuation = self.ctx.continuation, .style = self.ctx.style },
            .source_base = self.base,
            .final = self.render_final,
            .streaming_tables = true,
            .references = self.references,
            .confirmed = self.confirmed.items,
            .max_rows = self.max_rows,
        });
        try accum.add(window);
        try confirmed.appendSlice(a, window.confirmed);
        try cells.appendSlice(a, window.cells);
        try appendRows(a, rows, window.rows, 0, 0);
        try appendLeaves(a, leaves, window.leaves, 0);
        end.* = ctxOf(window.end);
        end_document.* = false;
        leaf_open.* = window.leaf_open;
        if (end_offset >= self.source.items.len) return;
        const rest = self.source.items[end_offset..];
        if (rest.len == 0) return;
        // The rest starts at a real line boundary. A heading cannot continue:
        // its line ended, so the remainder is ordinary document content again.
        var prefix: std.ArrayList(u8) = .empty;
        var context_bytes: usize = 0;
        if (self.ctx.kind == .paragraph) {
            try prefix.appendSlice(a, self.ctx.prefix);
            try prefix.appendSlice(a, "\x01\n");
            try prefix.appendSlice(a, rest);
            context_bytes = prefix.items.len - rest.len;
        } else {
            try prefix.appendSlice(a, rest);
        }
        const row_base = rows.items.len;
        const leaf_base = leaves.items.len;
        const window2 = try markdown.renderWindow(a, prefix.items, .{
            .columns = self.columns,
            .ansi = true,
            .context_bytes = context_bytes,
            .source_base = self.base + end_offset,
            .final = self.render_final,
            .streaming_tables = true,
            .references = self.references,
            .max_rows = self.max_rows,
        });
        try accum.add(window2);
        try confirmed.appendSlice(a, window2.confirmed);
        try cells.appendSlice(a, window2.cells);
        try appendRows(a, rows, window2.rows, end_offset, leaf_base);
        try appendLeaves(a, leaves, window2.leaves, row_base);
        end.* = ctxOf(window2.end);
        end_document.* = window2.end_is_document;
        leaf_open.* = window2.leaf_open;
    }

    /// Literal leaves (HTML and code) continue literally through the current
    /// physical line. Tables never enter this path; they retain native columns.
    fn renderLiteralChain(self: *Body, a: Allocator, rows: *std.ArrayList(Row), leaves: *std.ArrayList(Leaf), confirmed: *std.ArrayList(markdown.ConfirmedSpan), cells: *std.ArrayList(markdown.CellRange), end: *Ctx, accum: *Accum) !void {
        const eol = std.mem.indexOfScalar(u8, self.source.items, '\n');
        const cut = if (eol) |i| i + 1 else self.source.items.len;
        const kind: markdown.LeafKind = switch (self.ctx.kind) {
            .code => .code,
            else => .html,
        };
        try self.literalRange(a, rows, leaves, 0, cut, kind);
        if (cut >= self.source.items.len) {
            end.* = switch (self.ctx.kind) {
                .code => self.ctx,
                else => .{ .kind = .document },
            };
            return;
        }
        const rest = self.source.items[cut..];
        if (self.ctx.kind == .code) {
            // Keep real fenced/indented code context for the remaining lines.
            var prefix: std.ArrayList(u8) = .empty;
            try prefix.appendSlice(a, self.ctx.prefix);
            if (self.ctx.indented) {
                try prefix.appendSlice(a, "    ");
            } else {
                for (0..self.ctx.fence_length) |_| try prefix.append(a, self.ctx.fence);
            }
            try prefix.appendSlice(a, "\x01\n");
            try prefix.appendSlice(a, rest);
            const leaf_base = leaves.items.len;
            const row_base = rows.items.len;
            const window = try markdown.renderWindow(a, prefix.items, .{
                .columns = self.columns,
                .ansi = true,
                .context_bytes = prefix.items.len - rest.len,
                .source_base = self.base + cut,
                .final = self.render_final,
                .streaming_tables = true,
                .references = self.references,
                .max_rows = self.max_rows,
            });
            try accum.add(window);
            try confirmed.appendSlice(a, window.confirmed);
            try cells.appendSlice(a, window.cells);
            try appendRows(a, rows, window.rows, cut, leaf_base);
            try appendLeaves(a, leaves, window.leaves, row_base);
            end.* = ctxOf(window.end);
            if (end.kind == .document) end.* = self.ctx;
            return;
        }
        const leaf_base = leaves.items.len;
        const row_base = rows.items.len;
        const window = try markdown.renderWindow(a, rest, .{ .columns = self.columns, .ansi = true, .source_base = self.base + cut, .final = self.render_final, .streaming_tables = true, .references = self.references, .max_rows = self.max_rows });
        try accum.add(window);
        try confirmed.appendSlice(a, window.confirmed);
        try cells.appendSlice(a, window.cells);
        try appendRows(a, rows, window.rows, cut, leaf_base);
        try appendLeaves(a, leaves, window.leaves, row_base);
        end.* = ctxOf(window.end);
    }

    fn literalRange(self: *Body, a: Allocator, rows: *std.ArrayList(Row), leaves: *std.ArrayList(Leaf), from: usize, to: usize, kind: markdown.LeafKind) !void {
        const start = rows.items.len;
        try leaves.append(a, .{ .ctx = .{ .kind = kind, .prefix = self.ctx.prefix, .continuation = self.ctx.continuation, .style = self.ctx.style }, .row_start = start, .row_end = start });
        var w: Writer = .{ .a = a, .columns = self.columns, .ansi = true, .style = self.ctx.style, .prefix = self.ctx.prefix, .continuation = self.ctx.continuation };
        var sink = LiteralSink{ .a = a, .rows = rows, .leaf = leaves.items.len - 1, .w = &w };
        w.sink = .{ .context = &sink, .onRow = LiteralSink.onRow };
        var offset = from;
        while (offset < to) {
            const eol = std.mem.indexOfScalarPos(u8, self.source.items[0..to], offset, '\n');
            const line_end = if (eol) |i| i + 1 else to;
            try w.emitSourced(self.source.items[offset..line_end], offset, line_end, true);
            offset = line_end;
        }
        if (w.hasContent()) try w.finish();
        leaves.items[leaves.items.len - 1].row_end = rows.items.len;
    }

    fn appendRows(a: Allocator, rows: *std.ArrayList(Row), source: []const markdown.WindowRow, base: usize, leaf_base: usize) !void {
        for (source) |row| {
            const start = if (row.synthetic) std.math.maxInt(usize) else base + row.start;
            const end = if (row.synthetic) 0 else base + row.end;
            try rows.append(a, .{ .text = row.text, .start = start, .end = end, .synthetic = row.synthetic, .leaf = leaf_base + row.leaf, .output_start = row.output_start, .output_end = row.output_end, .output_window = row.output_window, .table = row.table, .table_kind = row.table_kind, .table_checkpoint = row.table_checkpoint, .table_occurrences = row.table_occurrences, .prefix = row.prefix });
        }
    }

    fn appendLeaves(a: Allocator, leaves: *std.ArrayList(Leaf), source: []const markdown.WindowLeaf, row_base: usize) !void {
        for (source) |leaf| {
            try leaves.append(a, .{ .ctx = ctxOf(leaf.ctx), .row_start = row_base + leaf.row_start, .row_end = row_base + leaf.row_end, .head_start = leaf.ctx.table_head_start, .head_end = leaf.ctx.table_head_end, .head_rows = leaf.ctx.table_head_rows });
        }
    }

    fn ctxOf(value: markdown.LeafCtx) Ctx {
        return .{
            .kind = value.kind,
            .prefix = value.prefix,
            .continuation = value.continuation,
            .style = value.style,
            .fence = value.fence,
            .fence_length = value.fence_length,
            .header_open = value.header_open,
            .header_run = value.header_run,
            .closing_begin = value.closing_begin,
            .closing_end = value.closing_end,
            .indented = value.indented,
            .table_header = value.table_header,
            .table_header_begin = value.table_header_begin,
            .table_body_begin = value.table_body_begin,
            .table_header_complete = value.table_header_complete,
            .table_columns = value.table_columns,
            .table_align = value.table_align,
            .table_containers = value.table_containers,
        };
    }
};

/// First byte of the physical line containing `offset`.
fn lineStart(source: []const u8, offset: usize) usize {
    var pos = @min(offset, source.len);
    while (pos > 0 and source[pos - 1] != '\n') pos -= 1;
    return pos;
}

/// Physical line terminator length at `pos`: LF or CRLF, zero when the byte is
/// not a terminator (including a not-yet-arrived break at the window end).
fn eolLength(source: []const u8, pos: usize, limit: usize) usize {
    if (pos >= limit) return 0;
    if (source[pos] == '\n') return 1;
    if (source[pos] == '\r' and pos + 1 < limit and source[pos + 1] == '\n') return 2;
    return 0;
}

/// A physical table line ends the table when native container grammar would see
/// nothing but container markers on it (blockquote `>` marks, list/quote
/// indentation). Raw empty-line trimming is not enough inside a container.
fn tableLineIsBlank(line: []const u8) bool {
    for (line) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '>' or byte == '\r') continue;
        return false;
    }
    return true;
}

/// Length of a blank (container-aware) physical line starting at `from`, or null
/// when the line is not blank or is not yet complete.
fn blankLineEnd(source: []const u8, from: usize, limit: usize) ?usize {
    if (from >= limit) return null;
    const eol = std.mem.indexOfScalarPos(u8, source[0..limit], from, '\n') orelse return null;
    if (!tableLineIsBlank(source[from..eol])) return null;
    return eol + 1;
}

/// True when a row starts inside a generated link/image suffix, which has its
/// own output cursor and cannot be judged by raw source position alone.
fn spanBoundaryAfter(spans: []const markdown.ConfirmedSpan, row: Row) bool {
    for (spans) |span| {
        if (span.output_window == row.output_window and
            row.output_start >= span.suffix_start and row.output_start < span.suffix_end) return true;
    }
    return false;
}

const LiteralSink = struct {
    a: Allocator,
    rows: *std.ArrayList(Row),
    leaf: usize,
    w: *Writer,

    fn onRow(context: *anyopaque, row: []const u8, _: usize, _: []const u8) output.Error!void {
        const self: *LiteralSink = @ptrCast(@alignCast(context));
        const synthetic = self.w.origin_synthetic or self.w.origin_start == std.math.maxInt(usize);
        try self.rows.append(self.a, .{
            .text = row,
            .start = if (synthetic) std.math.maxInt(usize) else self.w.origin_start,
            .end = if (synthetic) 0 else self.w.origin_end,
            .synthetic = synthetic,
            .leaf = self.leaf,
        });
    }
};

// ---------------------------------------------------------------------------
// Offline regressions. Every case drives the real native parser through the
// same bounded-window path used by the TUI; no network, no credentials.
// ---------------------------------------------------------------------------

fn countRows(body: *Body) usize {
    return body.visibleRows().len;
}

fn cycleCommit(a: Allocator, body: *Body, out: *std.ArrayList(u8)) !usize {
    try body.build();
    const rows = body.visibleRows();
    if (rows.len == 0) {
        body.abort();
        return 0;
    }
    const n = body.releaseLimit(rows.len);
    if (n == 0) {
        body.abort();
        return 0;
    }
    for (rows[0..n]) |row| try out.appendSlice(a, row.text);
    _ = try body.commit(n);
    return n;
}

test "plain line without newline keeps progressing past 128 KiB" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 32);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    var chunk: [1024]u8 = @splat('x');
    var fed: usize = 0;
    while (fed < 200 * 1024) : (fed += chunk.len) {
        try body.append(&chunk);
        _ = try cycleCommit(a, body, &seen);
        try std.testing.expect(body.limit == .none);
        // The mutable parser window must stay bounded; bytes already released
        // are never retained or re-parsed.
        try std.testing.expect(body.windowBytes() < 8192);
    }
    // Every input byte was displayed exactly once (prefixes add no 'x').
    try std.testing.expectEqual(fed, std.mem.count(u8, seen.items, "x"));
    try std.testing.expect(body.stats.retired_bytes > 128 * 1024);
    try std.testing.expect(body.stats.max_window_bytes < 8192);
}

test "released history does not grow per-frame parse work" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    // 400 short lines, committing after each one.
    for (0..400) |i| {
        var line: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "line-{d} tok\n", .{i});
        try body.append(text);
        _ = try cycleCommit(a, body, &seen);
    }
    try std.testing.expect(body.limit == .none);
    try std.testing.expect(body.stats.max_window_bytes <= 128);
    for (0..400) |i| {
        var line: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "line-{d} tok", .{i});
        try std.testing.expect(std.mem.indexOf(u8, seen.items, text[0..std.mem.indexOfScalar(u8, text, ' ').?]) != null);
    }
}

test "unresolved and closed emphasis freezes the displayed interpretation" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 30);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("**open emphasis ");
    _ = try cycleCommit(a, body, &seen);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "**open emphasis") != null);
    // The opener was frozen as literal; a later closer is literal too and never
    // reopens a span across the freeze boundary.
    try body.append("still open** tail\n");
    _ = try cycleCommit(a, body, &seen);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "still open** tail") != null);
    // A span fully inside the mutable window still renders with real grammar.
    try body.append("\n**closed** span\n");
    _ = try cycleCommit(a, body, &seen);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "closed") != null);
}

test "fenced code continues without reinterpretation across freezes" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 30);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("```\ncode *literal* one\n");
    _ = try cycleCommit(a, body, &seen);
    try body.append("``` not a closer inside\n```\nafter **bold**\n");
    _ = try cycleCommit(a, body, &seen);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "code *literal* one") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "``` not a closer inside") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "after") != null);
    try std.testing.expect(body.limit == .none);
}

test "nested list context resumes with hanging indentation and lazy continuation" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 30);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("> - quoted item first\n");
    _ = try cycleCommit(a, body, &seen);
    try body.append("lazy continuation\n> - second item\n");
    _ = try cycleCommit(a, body, &seen);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "lazy continuation") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "second item") != null);
    try std.testing.expect(body.limit == .none);
}

test "late reference definitions only affect the mutable window" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("see [label][r]\n");
    _ = try cycleCommit(a, body, &seen);
    try body.append("\n[r]: https://example.org/path\n");
    _ = try cycleCommit(a, body, &seen);
    // The frozen occurrence displayed its literal form; no retroactive rewrite.
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "[label][r]") != null);
    try std.testing.expect(body.limit == .none);
}

test "table rows keep header context and never duplicate released rows" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("| Name | Value |\n| --- | ---: |\n");
    _ = try cycleCommit(a, body, &seen);
    try body.append("| alpha | 1 |\n| beta | 2 |\n");
    var rounds: usize = 0;
    while (body.pendingBytes() != 0) {
        rounds += 1;
        try std.testing.expect(rounds < 8);
        if (try cycleCommit(a, body, &seen) == 0) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "beta") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "alpha"));
    try std.testing.expect(body.limit == .none);
}

/// Text as displayed, with terminal style sequences removed. Row boundaries are
/// not part of the answer, so cross-row equality is asserted on characters.
fn plainText(a: Allocator, styled: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < styled.len) {
        if (styled[i] == 0x1b and i + 1 < styled.len and styled[i + 1] == '[') {
            const end = std.mem.indexOfScalarPos(u8, styled, i + 2, 'm') orelse return error.InvalidTestSgr;
            i = end + 1;
            continue;
        }
        try out.append(a, styled[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

test "CRLF CJK combining and ZWJ survive every chunk split" {
    const a = std.testing.allocator;
    const text = "中e\u{301}👨‍👩‍👧 ok\r\nnext line\n";
    for (1..text.len) |split| {
        const body = try Body.create(a, 20);
        defer body.destroy();
        var seen: std.ArrayList(u8) = .empty;
        defer seen.deinit(a);
        try body.append(text[0..split]);
        _ = try cycleCommit(a, body, &seen);
        try body.append(text[split..]);
        _ = try cycleCommit(a, body, &seen);
        try std.testing.expect(body.limit == .none);
        const plain = try plainText(a, seen.items);
        defer a.free(plain);
        // Every source scalar survives exactly once, in order. A combining mark
        // that arrives after its base was already acknowledged may be displayed
        // on a placeholder base, so the cluster is compared without its marks.
        try std.testing.expect(std.mem.indexOf(u8, plain, "\xef\xbf\xbd") == null);
        try std.testing.expect(std.mem.indexOf(u8, plain, "next line") != null);
        try std.testing.expect(std.mem.indexOf(u8, plain, "中") != null);
        try std.testing.expect(std.mem.indexOf(u8, plain, "e") != null);
        try std.testing.expect(std.mem.indexOf(u8, plain, "👨") != null);
        try std.testing.expect(std.mem.indexOf(u8, plain, "👧") != null);
    }
}

test "row provenance advances monotonically and stays inside the window" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 24);
    defer body.destroy();
    try body.append("# Heading\n\nfirst paragraph with **bold** text\n\n- one\n- two\n");
    try body.build();
    const rows = body.visibleRows();
    try std.testing.expect(rows.len > 2);
    var previous: usize = 0;
    for (rows) |row| {
        if (row.synthetic) {
            try std.testing.expectEqual(std.math.maxInt(usize), row.start);
            continue;
        }
        try std.testing.expect(row.end > row.start);
        try std.testing.expect(row.start >= previous);
        try std.testing.expect(row.end <= body.windowBytes());
        previous = row.start;
    }
    body.abort();
}

test "in-flight append does not change the pinned frame rows; ACK then abort" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 24);
    defer body.destroy();
    try body.append("committed prefix\n");
    try body.build();
    const pinned = try a.dupe(Row, body.visibleRows());
    defer a.free(pinned);
    // New transport bytes arrive while the frame is in flight.
    try body.append("more text while pending\n");
    try std.testing.expectEqual(pinned.len, body.visibleRows().len);
    _ = try body.commit(pinned.len);
    try body.build();
    try std.testing.expect(body.visibleRows().len >= 1);
    // An aborted frame retains unacknowledged source and rows.
    body.abort();
    const before = body.windowBytes();
    try body.build();
    try std.testing.expectEqual(before, body.windowBytes());
    body.abort();
    try std.testing.expect(body.windowBytes() != 0);
}

test "isDrained requires EOF and acknowledged source and rows" {
    const body = try Body.create(std.testing.allocator, 20);
    defer body.destroy();
    try std.testing.expect(!body.isDrained());
    try body.append("hello");
    try body.build();
    try body.finish();
    try std.testing.expectEqual(@as(usize, 0), body.pendingBytes());
    try std.testing.expect(!body.isDrained());
    body.abort();
    try std.testing.expect(!body.isDrained());
    try body.build();
    const count = body.visibleRows().len;
    try std.testing.expect(count > 0);
    _ = try body.commit(count);
    try std.testing.expect(body.isDrained());
}

test "EOF table presentation remains pending until bottom acknowledgement" {
    const body = try Body.create(std.testing.allocator, 40);
    defer body.destroy();
    body.ctx = .{ .kind = .table, .table_columns = 2, .table_top_done = true, .table_head_done = true, .table_sep_done = true };
    try body.finish();
    try std.testing.expect(body.hasPendingPresentation());
    try std.testing.expect(!body.isDrained());
    try body.build();
    try std.testing.expectEqual(@as(usize, 1), body.visibleRows().len);
    try std.testing.expectEqual(@as(?markdown.TableRowKind, .bottom), body.visibleRows()[0].table_kind);
    try std.testing.expectEqual(@as(usize, 1), try body.commit(1));
    try std.testing.expect(!body.hasPendingPresentation());
    try std.testing.expect(body.isDrained());
}

test "work quantum yields and eventually displays every accepted byte" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 20);
    defer body.destroy();
    body.max_window_bytes = 64;
    const data: [512]u8 = @splat('y');
    try body.append(&data);
    try body.finish();
    var delivered: usize = 0;
    var steps: usize = 0;
    while (!body.isDrained() and steps < 64) {
        steps += 1;
        try body.build();
        try std.testing.expectEqual(Limit.none, body.limit);
        try std.testing.expect(body.render.source_len <= 64);
        try std.testing.expect(body.render.source_len > 0);
        for (body.visibleRows()) |row| for (row.text) |byte| {
            if (byte == 'y') delivered += 1;
        };
        _ = try body.commit(body.visibleRows().len);
    }
    try std.testing.expect(body.isDrained());
    try std.testing.expectEqual(@as(usize, 512), delivered);
    try std.testing.expectEqual(@as(usize, 512), body.stats.retired_bytes);
    try std.testing.expect(body.stats.max_window_bytes <= 64);
}

test "candidate release after metadata retirement uses window row coordinates" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 20);
    defer body.destroy();
    const blanks: [1024]u8 = @splat('\n');
    try body.append(&blanks);
    try body.build();
    try std.testing.expectEqual(@as(usize, 0), body.visibleRows().len);
    try std.testing.expect(body.hasMetadataProgress());
    try std.testing.expectEqual(@as(usize, 0), try body.commit(0));
    try std.testing.expectEqual(@as(usize, 1024), body.base);
    body.max_window_bytes = 64;
    body.stats = .{};
    const data: [512]u8 = @splat('y');
    try body.append(&data);
    try body.finish();
    var delivered: usize = 0;
    var steps: usize = 0;
    while (!body.isDrained() and steps < 64) {
        steps += 1;
        try body.build();
        try std.testing.expectEqual(Limit.none, body.limit);
        try std.testing.expect(body.render.source_len > 0 and body.render.source_len <= 64);
        const rows = body.visibleRows();
        try std.testing.expect(rows.len != 0);
        for (rows) |row| for (row.text) |byte| {
            if (byte == 'y') delivered += 1;
        };
        try std.testing.expectEqual(rows.len, try body.commit(rows.len));
    }
    try std.testing.expect(body.isDrained());
    try std.testing.expectEqual(@as(usize, 512), delivered);
    try std.testing.expectEqual(@as(usize, 512), body.stats.retired_bytes);
    try std.testing.expectEqual(@as(usize, 1536), body.base);
    try std.testing.expect(body.stats.max_window_bytes <= 64);
}

/// Compare actual character styling, not redundant SGR byte sequences. Each
/// output byte carries emphasis flags and foreground; row boundaries are explicit.
fn fingerprintRow(a: Allocator, out: *std.ArrayList(u8), row: []const u8) !void {
    var flags: u8 = 0;
    var foreground: u16 = 256;
    var i: usize = 0;
    while (i < row.len) {
        if (row[i] == 0x1b) {
            if (i + 1 >= row.len or row[i + 1] != '[') return error.InvalidTestSgr;
            const end = std.mem.indexOfScalarPos(u8, row, i + 2, 'm') orelse return error.InvalidTestSgr;
            var values: [16]u16 = undefined;
            var count: usize = 0;
            var parts = std.mem.splitScalar(u8, row[i + 2 .. end], ';');
            while (parts.next()) |part| {
                if (count == values.len) return error.InvalidTestSgr;
                values[count] = if (part.len == 0) 0 else try std.fmt.parseInt(u16, part, 10);
                count += 1;
            }
            var p: usize = 0;
            while (p < count) : (p += 1) switch (values[p]) {
                0 => {
                    flags = 0;
                    foreground = 256;
                },
                1 => flags |= 1,
                2 => flags |= 16,
                3 => flags |= 2,
                4 => flags |= 4,
                9 => flags |= 8,
                22 => flags &= ~@as(u8, 17),
                23 => flags &= ~@as(u8, 2),
                24 => flags &= ~@as(u8, 4),
                29 => flags &= ~@as(u8, 8),
                39 => foreground = 256,
                38 => {
                    if (p + 2 >= count or values[p + 1] != 5) return error.InvalidTestSgr;
                    foreground = values[p + 2];
                    p += 2;
                },
                else => return error.InvalidTestSgr,
            };
            i = end + 1;
            continue;
        }
        try out.appendSlice(a, &.{ row[i], flags, @as(u8, @truncate(foreground)), @as(u8, @truncate(foreground >> 8)) });
        i += 1;
    }
    try out.appendSlice(a, &.{ '\n', 0, 0, 1 });
}

fn drainFingerprint(a: Allocator, body: *Body, out: *std.ArrayList(u8)) !void {
    var steps: usize = 0;
    const max_steps = body.windowBytes() * 2 + 64;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps <= max_steps);
        try body.build();
        try std.testing.expectEqual(Limit.none, body.limit);
        try std.testing.expect(body.visibleRows().len != 0);
        try fingerprintRow(a, out, body.visibleRows()[0].text);
        try std.testing.expectEqual(@as(usize, 1), try body.commit(1));
    }
}

test "confirmed emphasis survives every row ACK with exact characters and styles" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "**abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ** PLAIN",
        "*abcdefghijklmnopqrstuvwxyz0123456789* PLAIN",
        "~~abcdefghijklmnopqrstuvwxyz0123456789~~ PLAIN",
        "`abcdefghijklmnopqrstuvwxyz0123456789` PLAIN",
        "`` abcdefghijklmnopqrstuvwxyz ` middle 0123456789 `` PLAIN",
        "`abcdefghijklmnop\nqrstuvwxyz0123456789` PLAIN",
        "[abcdefghijklmnopqrstuvwxyz0123456789](https://example.org/path) PLAIN",
        "[label](https://example.org/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/0123456789) PLAIN",
        "[label](https://example.org/a&amp;b/abcdefghijklmnopqrstuvwxyz0123456789) PLAIN",
        "![abcdefghijklmnopqrstuvwxyz0123456789](https://example.org/image.png) PLAIN",
        "**outer *nested abcdefghijklmnopqrstuvwxyz0123456789* outer tail** PLAIN",
        "*outer **nested abcdefghijklmnopqrstuvwxyz0123456789** outer tail* PLAIN",
        "~~outer **nested abcdefghijklmnopqrstuvwxyz** outer tail~~ PLAIN",
        "**abcdefghijklmnopqrstuvwxyz\nsecond physical line abcdefghijklmnopqrstuvwxyz** PLAIN",
        "# **abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ** PLAIN",
        "- **abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ** PLAIN",
    }) |source| {
        const body = try Body.create(a, 13);
        defer body.destroy();
        try body.append(source);
        try body.finish();
        try body.build();
        try std.testing.expect(body.render.confirmed.len > 0);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(a);
        for (body.visibleRows()) |row| try fingerprintRow(a, &expected, row.text);
        var actual: std.ArrayList(u8) = .empty;
        defer actual.deinit(a);
        try fingerprintRow(a, &actual, body.visibleRows()[0].text);
        try std.testing.expectEqual(@as(usize, 1), try body.commit(1));
        try std.testing.expect(body.confirmed.items.len > 0);
        try drainFingerprint(a, body, &actual);
        try std.testing.expectEqualSlices(u8, expected.items, actual.items);
    }
}

test "confirmed span checkpoint belongs to the ACKed frame not a later append" {
    const a = std.testing.allocator;
    const source = "**abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ** PLAIN";
    const body = try Body.create(a, 13);
    defer body.destroy();
    try body.append(source);
    try body.build();
    const pinned_length = body.render.source_len;
    try body.append(" EXTRA");
    try std.testing.expectEqual(pinned_length, body.render.source_len);
    try std.testing.expectEqual(@as(usize, 0), body.confirmed.items.len);
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(a);
    try fingerprintRow(a, &actual, body.visibleRows()[0].text);
    // The trailing line is a native candidate (possible table header), so the
    // caller's own mutable-tail budget decides; a one-row ACK of a short line
    // freezes it explicitly instead of blocking release.
    const take = body.releaseLimit(1);
    try std.testing.expectEqual(@as(usize, 1), take);
    _ = try body.commit(take);
    const acknowledged = body.base;
    const closer = body.confirmed.items[0].closer_end;
    try body.build();
    body.abort();
    try std.testing.expectEqual(acknowledged, body.base);
    try std.testing.expectEqual(closer, body.confirmed.items[0].closer_end);
    try body.finish();
    try drainFingerprint(a, body, &actual);
    const reference = try Body.create(a, 13);
    defer reference.destroy();
    try reference.append(source ++ " EXTRA");
    try reference.finish();
    try reference.build();
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(a);
    for (reference.visibleRows()) |row| try fingerprintRow(a, &expected, row.text);
    try std.testing.expectEqualSlices(u8, expected.items, actual.items);
}

fn confirmedSpanAllocationCase(a: Allocator) !void {
    const body = try Body.create(a, 13);
    defer body.destroy();
    try body.append("**abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ** PLAIN");
    try body.finish();
    try body.build();
    _ = try body.commit(1);
    try body.build();
    body.abort();
    try body.build();
    _ = try body.commit(body.visibleRows().len);
}

test "confirmed span checkpoint construction is allocation transactional" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, confirmedSpanAllocationCase, .{});
}

test "fence header continuation extends native opener length without showing info" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 32);
    defer body.destroy();
    try body.append("````");
    try body.build();
    _ = try body.commit(body.visibleRows().len);
    try std.testing.expect(body.ctx.header_open);
    try std.testing.expectEqual(@as(usize, 4), body.ctx.fence_length);
    try body.append("```lang\n");
    try body.build();
    try std.testing.expect(body.hasMetadataProgress());
    try std.testing.expectEqual(@as(usize, 4), body.ctx.fence_length);
    body.abort();
    try std.testing.expectEqual(@as(usize, 4), body.ctx.fence_length);
    try body.build();
    _ = try body.commit(0);
    try std.testing.expectEqual(@as(usize, 7), body.ctx.fence_length);
    try std.testing.expect(!body.ctx.header_open);
    try body.append("````\nbody\n```````\nafter\n");
    try body.finish();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 32);
        try body.build();
        for (body.visibleRows()) |row| try seen.appendSlice(a, row.text);
        _ = try body.commit(body.visibleRows().len);
    }
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "lang") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "````") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "body") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "```````") == null);
}

test "known fenced code uses bounded native steps and leaves later Markdown queued" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 20);
    defer body.destroy();
    try body.append("````\n");
    try body.build();
    _ = try body.commit(body.visibleRows().len);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    for (0..400) |_| try source.appendSlice(a, "code *literal*\n");
    try source.appendSlice(a, "```\n````\n**AFTER**\n");
    try body.append(source.items);
    try body.finish();
    var count: usize = 0;
    var after = false;
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 128);
        try body.build();
        if (body.ctx.kind == .code and body.ctx.prefix.len == 0)
            try std.testing.expect(body.visibleRows().len <= 66);
        for (body.visibleRows()) |row| {
            if (std.mem.indexOf(u8, row.text, "code *literal*") != null) count += 1;
            if (std.mem.indexOf(u8, row.text, "AFTER") != null) {
                after = true;
                try std.testing.expect(std.mem.indexOf(u8, row.text, @import("theme.zig").strong) != null);
            }
        }
        _ = try body.commit(body.visibleRows().len);
    }
    try std.testing.expectEqual(@as(usize, 400), count);
    try std.testing.expect(after);
}

test "long generated URL advances an output cursor without losing later text" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 20);
    defer body.destroy();
    body.max_window_bytes = 32 * 1024;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "[label](https://example.org/");
    for (0..10000) |_| try source.append(a, 'q');
    try source.appendSlice(a, ") AFTER");
    try body.append(source.items);
    try body.finish();
    var delivered: usize = 0;
    var after = false;
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 64);
        try body.build();
        try std.testing.expect(body.visibleRows().len <= 68);
        for (body.visibleRows()) |row| {
            for (row.text) |byte| if (byte == 'q') {
                delivered += 1;
            };
            if (std.mem.indexOf(u8, row.text, "AFTER") != null) after = true;
        }
        _ = try body.commit(body.visibleRows().len);
    }
    try std.testing.expectEqual(@as(usize, 10000), delivered);
    try std.testing.expect(after);
}

test "table continuation consumes each column once after partial row acknowledgements" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    try body.append("| Head | Value |\n| --- | ---: |\n| abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 | late-column |\n");
    try body.finish();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 64);
        try body.build();
        const take = body.releaseLimit(1);
        try std.testing.expect(take != 0);
        for (body.visibleRows()[0..take]) |row| try seen.appendSlice(a, row.text);
        _ = try body.commit(take);
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "Head"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "late-column"));
    var styled: std.ArrayList(u8) = .empty;
    defer styled.deinit(a);
    try fingerprintRow(a, &styled, seen.items);
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") |byte| {
        if (byte == 'H' or byte == 'V') continue;
        var occurrences: usize = 0;
        var i: usize = 0;
        while (i < styled.items.len) : (i += 4) {
            if (styled.items[i] == byte) occurrences += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), occurrences);
    }
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "│") != null);
    try std.testing.expect(!body.diverged);
}

test "visibility fence belongs to pinned normalized snapshot" {
    const body = try Body.create(std.testing.allocator, 40);
    defer body.destroy();
    try body.append("hello");
    try std.testing.expectEqual(@as(usize, 5), body.acceptedSourceEnd());
    try body.build();
    try std.testing.expectEqual(@as(usize, 5), body.visibleSourceEnd());
    try body.append(" world\r");
    try std.testing.expectEqual(@as(usize, 12), body.acceptedSourceEnd());
    try std.testing.expectEqual(@as(usize, 5), body.visibleSourceEnd());
    body.abort();
    try std.testing.expectEqual(@as(usize, 0), body.visibleSourceEnd());
}

test "table atomic release compares source occurrences, not delivered cursors" {
    const body = try Body.create(std.testing.allocator, 40);
    defer body.destroy();
    const a = body.render.arena.allocator();
    const occurrences = try a.dupe(markdown.TableOccurrence, &.{
        .{ .column = 0, .segment = .{ .start = 10, .end = 11, .atomic = true } },
        .{ .column = 0, .segment = .{ .start = 11, .end = 12, .atomic = true } },
        .{ .column = 0, .segment = .{ .start = 11, .end = 12, .atomic = true } },
    });
    var progress: markdown.TableProgress = .{ .row_begin = 0, .row_end = 20 };
    progress.delivered[0] = 12;
    body.render.rows = try a.dupe(Row, &.{
        .{ .text = "a", .start = 10, .end = 11, .synthetic = false, .leaf = 0, .table = progress, .table_occurrences = occurrences[0..1] },
        .{ .text = "b", .start = 11, .end = 12, .synthetic = false, .leaf = 0, .table = progress, .table_occurrences = occurrences[1..2] },
        .{ .text = "c", .start = 11, .end = 12, .synthetic = false, .leaf = 0, .table = progress, .table_occurrences = occurrences[2..3] },
    });
    try std.testing.expectEqual(@as(usize, 1), body.atomicRelease(1));
    try std.testing.expectEqual(@as(usize, 3), body.atomicRelease(2));
}

test "long table cell yields bounded one-row checkpoints with a delayed tail at EOF" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    try body.append("| A | B | C |\n| --- | --- | --- |\n| ");
    const long = try a.alloc(u8, 12000);
    defer a.free(long);
    @memset(long, 'x');
    try body.append(long);

    // The old pinned render must not absorb a later column or EOF.
    try body.build();
    const pinned_count = body.visibleRows().len;
    try body.append(" | TAIL | LAST |");
    try std.testing.expectEqual(pinned_count, body.visibleRows().len);
    body.abort();
    try body.finish();

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 4096);
        try body.build();
        try std.testing.expectEqual(Limit.none, body.limit);
        if (body.hasMetadataProgress()) {
            _ = try body.commit(0);
            continue;
        }
        const take = body.releaseLimit(1);
        try std.testing.expectEqual(@as(usize, 1), take);
        try seen.appendSlice(a, body.visibleRows()[0].text);
        _ = try body.commit(take);
    }
    try std.testing.expectEqual(@as(usize, 12000), std.mem.count(u8, seen.items, "x"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "TAIL"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "LAST"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "└"));
    try std.testing.expect(!body.diverged);
    try std.testing.expect(body.stats.max_window_bytes < 8192);
}

test "long table cell keeps the pinned cut across abort resize and in-flight append" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    try body.append("| A | B |\n| --- | --- |\n| ");
    const long = try a.alloc(u8, 12000);
    defer a.free(long);
    @memset(long, 'x');
    try body.append(long);
    try body.build();
    const pinned = body.visibleRows().len;
    try std.testing.expect(pinned > 1);
    const accepted = body.acceptedSourceEnd();
    try body.append(" | TAIL |");
    try std.testing.expectEqual(pinned, body.visibleRows().len);
    try std.testing.expect(body.acceptedSourceEnd() > accepted);
    // One physical row (the top border) retires no source at all.
    try std.testing.expectEqual(@as(usize, 1), try body.commit(1));
    try std.testing.expectEqual(@as(usize, 0), body.stats.retired_bytes);
    try std.testing.expectEqual(@as(usize, 0), body.base);
    body.abort();
    try body.finish();

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    var steps: usize = 0;
    var resized = false;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 4096);
        try body.build();
        try std.testing.expectEqual(Limit.none, body.limit);
        if (body.hasMetadataProgress()) {
            _ = try body.commit(0);
            continue;
        }
        const visible = body.visibleSourceEnd();
        try std.testing.expect(visible <= body.acceptedSourceEnd());
        const take = body.releaseLimit(1);
        try std.testing.expectEqual(@as(usize, 1), take);
        try std.testing.expect(body.visibleSourceEndForRows(1) <= visible);
        try seen.appendSlice(a, body.visibleRows()[0].text);
        _ = try body.commit(take);
        if (!resized and body.base > 600) {
            resized = true;
            body.resize(24);
            try std.testing.expectEqual(body.base, body.visibleSourceEnd());
            try std.testing.expect(body.base <= body.acceptedSourceEnd());
        }
    }
    try std.testing.expect(resized);
    try std.testing.expectEqual(@as(usize, 12000), std.mem.count(u8, seen.items, "x"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "TAIL"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "└"));
    try std.testing.expect(!body.diverged);
    try std.testing.expect(body.stats.max_window_bytes < 8192);
}

test "streamed two column table keeps the standard grid alignment" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    try body.append("| Name | Value |\n| --- | ---: |\n| alpha | 1 |\n| beta | 2 |\n");
    try body.finish();
    var seen_rows: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen_rows.items) |row| a.free(@constCast(row));
        seen_rows.deinit(a);
    }
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 32);
        try body.build();
        try std.testing.expect(body.visibleRows().len != 0);
        for (body.visibleRows()) |row| try seen_rows.append(a, try plainText(a, row.text));
        _ = try body.commit(body.visibleRows().len);
    }
    const plain = try std.mem.join(a, "\n", seen_rows.items);
    defer a.free(plain);
    // columns=40, two columns: width = (40 - 3*2 - 1) / 2 = 16.
    var dashes_buf: [64]u8 = undefined;
    var dashes_len: usize = 0;
    for (0..18) |_| {
        @memcpy(dashes_buf[dashes_len..][0..3], "─");
        dashes_len += 3;
    }
    const dashes = dashes_buf[0..dashes_len];
    // Streaming rows keep the header separator and the outer rules; body rows
    // stay on the same grid without an extra rule between them.
    const expected = [_][]const u8{
        try std.fmt.allocPrint(a, "┌{s}┬{s}┐", .{ dashes, dashes }),
        try std.fmt.allocPrint(a, "│ {s:<16} │ {s:>16} │", .{ "Name", "Value" }),
        try std.fmt.allocPrint(a, "├{s}┼{s}┤", .{ dashes, dashes }),
        try std.fmt.allocPrint(a, "│ {s:<16} │ {s:>16} │", .{ "alpha", "1" }),
        try std.fmt.allocPrint(a, "│ {s:<16} │ {s:>16} │", .{ "beta", "2" }),
        try std.fmt.allocPrint(a, "└{s}┴{s}┘", .{ dashes, dashes }),
    };
    const joined_expected = try std.mem.join(a, "\n", &expected);
    defer a.free(joined_expected);
    for (expected) |row| a.free(row);
    try std.testing.expectEqualStrings(joined_expected, plain);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "Name"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "└"));
    for (seen_rows.items) |row| try std.testing.expectEqual(@as(usize, 39), output.displayWidth(row));
}

test "streamed table cells keep entities links and Unicode exactly once" {
    const a = std.testing.allocator;
    const source = "| H | Note |\n| --- | --- |\n| a&amp;b | [x](https://e.org/p) |\n| 中文e\u{301} | 👨‍👩‍👧 |\n";
    const body = try Body.create(a, 80);
    defer body.destroy();
    try body.append(source);
    try body.finish();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 256);
        try body.build();
        try std.testing.expectEqual(Limit.none, body.limit);
        if (body.hasMetadataProgress()) {
            _ = try body.commit(0);
            continue;
        }
        const take = body.releaseLimit(1);
        try std.testing.expect(take != 0);
        for (body.visibleRows()[0..take]) |row| try seen.appendSlice(a, row.text);
        _ = try body.commit(take);
    }
    const plain = try plainText(a, seen.items);
    defer a.free(plain);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "a&b"));
    try std.testing.expect(std.mem.indexOf(u8, plain, "&amp;") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "(https://e.org/p)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "x (https://e.org/p)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "中文e\u{301}"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "👨‍👩‍👧"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "└"));
    try std.testing.expect(!body.diverged);
}

/// Drain one bounded window of an unfinished stream (all displayed rows), so a
/// later append must reparse the retained (not yet cut) source.
fn drainOnce(a: Allocator, body: *Body, out: *std.ArrayList(u8)) !void {
    try body.build();
    if (body.hasMetadataProgress()) _ = try body.commit(0);
    const rows = body.visibleRows().len;
    if (rows != 0) {
        const take = body.releaseLimit(rows);
        if (take == 0) return error.TestUnexpectedResult;
        for (body.visibleRows()[0..take]) |row| try out.appendSlice(a, row.text);
        _ = try body.commit(take);
    }
    try std.testing.expectEqual(@as(usize, 0), body.windowBytes());
}

fn drainBody(a: Allocator, body: *Body, out: *std.ArrayList(u8), max_steps: usize) !void {
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        if (steps > max_steps) return error.TestUnexpectedResult;
        try body.build();
        if (body.hasMetadataProgress()) {
            _ = try body.commit(0);
            continue;
        }
        const rows = body.visibleRows().len;
        if (rows == 0) return error.TestUnexpectedResult;
        const take = body.releaseLimit(rows);
        if (take == 0) return error.TestUnexpectedResult;
        for (body.visibleRows()[0..take]) |row| try out.appendSlice(a, row.text);
        _ = try body.commit(take);
    }
}

test "fresh empty candidate frame releases ownership without publishing semantics" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 60);
    defer body.destroy();
    try body.append("[ref]: /url\n");
    try body.build();
    try std.testing.expectEqual(@as(usize, 0), body.visibleRows().len);
    try std.testing.expect(!body.hasMetadataProgress());
    const before = body.base;
    _ = try body.commit(0);
    try std.testing.expect(!body.pinned);
    try body.build();
    try std.testing.expect(!body.hasMetadataProgress());
    try std.testing.expectEqual(before, body.base);
    try body.append("  \"title\"\n\n[link][ref]\n");
    _ = try body.commit(0);
    try std.testing.expect(!body.pinned);
    try std.testing.expectEqual(before, body.base);
    try std.testing.expect(body.references == null);
    try std.testing.expectEqual(@as(usize, 0), body.frozen_count);
    try body.build();
    try std.testing.expect(body.visibleRows().len != 0);
    body.abort();
    try std.testing.expectEqual(before, body.base);
    try std.testing.expect(body.references == null);
    try body.finish();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try drainOneRowAtATime(a, body, &seen, 128, 0);
    const plain = try stripTestCsi(a, seen.items);
    defer a.free(plain);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "link (/url)"));
    try std.testing.expectEqual(body.acceptedSourceEnd(), body.base);
}

fn stripTestCsi(a: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len) {
                const c = input[i];
                i += 1;
                if (c >= 0x40 and c <= 0x7e) break;
            }
        } else {
            try out.append(a, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

test "retired reference definitions resolve links in later windows" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 60);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("see [one][r]\n\n[r]: https://example.org/one\n\n");
    try drainOnce(a, body, &seen);
    try std.testing.expect(body.references != null);
    try std.testing.expectEqual(@as(usize, 0), body.windowBytes());
    const first_plain = try stripTestCsi(a, seen.items);
    defer a.free(first_plain);
    try std.testing.expect(std.mem.indexOf(u8, first_plain, "one (https://example.org/one)") != null);
    // The definition is already retired source; a later window still resolves it.
    try body.append("later [two][r]\n");
    try body.finish();
    try drainBody(a, body, &seen, 32);
    const plain = try stripTestCsi(a, seen.items);
    defer a.free(plain);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "two (https://example.org/one)"));
}

test "reference store keeps duplicates Unicode labels and multiline titles" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 80);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("[r]: https://example.org/a\n[ünïcode]: https://example.org/ü\n[ml]: https://example.org/ml\n  \"multi\n   line\"\n\n");
    try drainOnce(a, body, &seen);
    try std.testing.expect(body.references != null);
    // A newer duplicate of an already committed label never overrides it.
    try body.append("[r]: https://example.org/b\n\n[a][r] [b][ünïcode] [c][ml]\n");
    try body.finish();
    try drainBody(a, body, &seen, 32);
    const plain = try stripTestCsi(a, seen.items);
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "a (https://example.org/a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "b (https://example.org/ü)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "c (https://example.org/ml)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "https://example.org/b") == null);
}

test "retired definition resolves a streamed table cell link" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 80);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("[r]: https://example.org/one\n\n");
    try drainOnce(a, body, &seen);
    try std.testing.expect(body.references != null);
    try body.append("| H | Note |\n| --- | --- |\n| [x][r] | a&amp;b |\n");
    try body.finish();
    try drainBody(a, body, &seen, 64);
    const plain = try stripTestCsi(a, seen.items);
    defer a.free(plain);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "x (https://example.org/one)"));
    try std.testing.expect(std.mem.indexOf(u8, plain, "a&b") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "└"));
}

test "aborted frames never publish reference definitions" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 60);
    defer body.destroy();
    try body.append("see [x][r]\n\n[r]: https://example.org/one\n");
    try body.build();
    body.abort();
    try std.testing.expect(body.references == null);
    try std.testing.expectEqual(@as(usize, 0), body.base);
    try body.finish();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try drainBody(a, body, &seen, 32);
    try std.testing.expect(body.references != null);
    const plain = try stripTestCsi(a, seen.items);
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "x (https://example.org/one)") != null);
}

fn referenceAllocationCase(a: Allocator) !void {
    const body = try Body.create(a, 60);
    defer body.destroy();
    try body.append("see [one][r]\n\n[r]: https://example.org/one\n");
    try body.finish();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try drainBody(a, body, &seen, 64);
}

test "reference store commit is allocation transactional" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, referenceAllocationCase, .{});
}

test "ambiguous freeze budget is bounded, coalescing and never evicts" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    // Sequential real frames: each ambiguous line is frozen, then pruned by the
    // commit that retires it, so the bounded budget is reusable.
    var step: usize = 0;
    while (step < 6) : (step += 1) {
        var line: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "line-{d}\n", .{step});
        try body.append(text);
        try body.build();
        try std.testing.expect(body.render.candidate != null);
        const take = body.releaseLimit(1);
        try std.testing.expectEqual(@as(usize, 1), take);
        _ = try body.commit(take);
        try std.testing.expectEqual(@as(usize, 0), body.frozenCount());
    }
    try std.testing.expectEqual(@as(usize, 0), body.windowBytes());
    // Fill the bounded budget with distinct active decisions.
    step = 0;
    while (step < frozen_capacity) : (step += 1) {
        try std.testing.expect(body.freezeCandidate(1000 + step * 100, 1000 + step * 100 + 10));
    }
    try std.testing.expectEqual(frozen_capacity, body.frozenCount());
    // Overlap and adjacency coalesce into an existing decision.
    try std.testing.expect(body.freezeCandidate(1005, 1015));
    try std.testing.expect(body.freezeCandidate(1015, 1020));
    try std.testing.expectEqual(frozen_capacity, body.frozenCount());
    try std.testing.expect(body.isFrozen(1000, 1005) and body.isFrozen(1019, 1020));
    // One more distinct decision cannot silently evict an older active one.
    try std.testing.expect(!body.freezeCandidate(9000, 9010));
    try std.testing.expectEqual(frozen_capacity, body.frozenCount());
    step = 0;
    while (step < frozen_capacity) : (step += 1) {
        try std.testing.expect(body.isFrozen(1000 + step * 100, 1000 + step * 100 + 10));
    }
    // A fresh commit publishes the frame decisions; abort keeps them and the
    // source untouched while dropping only the aborted frame's decisions.
    body.mergeFrameFrozen();
    try std.testing.expectEqual(frozen_capacity, body.frozenCount());
    try body.append("tail\n");
    const source = body.windowBytes();
    try body.build();
    body.abort();
    try std.testing.expectEqual(frozen_capacity, body.frozenCount());
    try std.testing.expectEqual(source, body.windowBytes());
}

test "exhausted freeze budget fails explicitly with the source untouched" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    var step: usize = 0;
    while (step < frozen_capacity) : (step += 1) {
        try std.testing.expect(body.freezeCandidate(1_000_000 + step * 100, 1_000_000 + step * 100 + 10));
    }
    body.mergeFrameFrozen();
    try body.append("| ");
    const long = try a.alloc(u8, 4000);
    defer a.free(long);
    @memset(long, 'h');
    try body.append(long);
    try body.build();
    const rows = body.visibleRows().len;
    try std.testing.expect(rows > 4);
    const before = body.windowBytes();
    try std.testing.expectEqual(@as(usize, 0), body.releaseLimit(rows - 3));
    try std.testing.expectEqual(Limit.ambiguity, body.limit);
    try std.testing.expectEqual(before, body.windowBytes());
    try std.testing.expectEqual(@as(usize, 0), body.base);
    try std.testing.expectEqual(frozen_capacity, body.frozenCount());
}

test "ambiguous short table header stays mutable and resolves natively" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("intro\n| a | b |\n");
    try body.build();
    try std.testing.expect(body.render.candidate != null);
    try std.testing.expect(body.visibleRows().len >= 2);
    const first = body.releaseLimit(1);
    try std.testing.expectEqual(@as(usize, 1), first);
    try seen.appendSlice(a, body.visibleRows()[0].text);
    _ = try body.commit(first);
    // A short header is not frozen by a one-row ACK; its source stays mutable.
    try std.testing.expect(!body.diverged);
    try std.testing.expect(body.base > 0);
    try std.testing.expect(body.windowBytes() != 0);
    try body.append("| --- | --- |\n| 1 | 2 |\n");
    try body.finish();
    try drainBody(a, body, &seen, 64);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "┌"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "a"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "b"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "└"));
}

test "adjacent table recognition keeps the original source offsets" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    try body.append("intro\n| a | b |\n");
    try body.build();
    try std.testing.expect(body.render.candidate != null);
    const rows = body.visibleRows();
    try std.testing.expect(rows.len >= 2);
    // The provisional header line is the real second physical line, at its
    // original absolute offset; no preprocessor rewrote the input.
    try std.testing.expectEqual(@as(usize, 6), rows[1].start);
    try std.testing.expect(rows[1].end <= body.windowBytes());
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(a);
    var i: usize = 0;
    while (i < rows[1].text.len) {
        if (rows[1].text[i] == 0x1b and i + 1 < rows[1].text.len and rows[1].text[i + 1] == '[') {
            i += 2;
            while (i < rows[1].text.len and (rows[1].text[i] < 0x40 or rows[1].text[i] > 0x7e)) : (i += 1) {}
            if (i < rows[1].text.len) i += 1;
        } else {
            try plain.append(a, rows[1].text[i]);
            i += 1;
        }
    }
    try std.testing.expectEqualStrings("| a | b |", plain.items);
    body.abort();
}

test "oversized ambiguous header freezes explicitly instead of blocking release" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    try body.append("| ");
    const long = try a.alloc(u8, 4000);
    defer a.free(long);
    @memset(long, 'h');
    try body.append(long);
    try body.build();
    try std.testing.expect(body.render.candidate != null);
    const rows = body.visibleRows().len;
    try std.testing.expect(rows > 4);
    const take = body.releaseLimit(rows - 3);
    try std.testing.expect(take > 0);
    // Staged only: the provisional display is not a committed interpretation.
    try std.testing.expect(!body.diverged);
    try std.testing.expectEqual(@as(usize, 0), body.frozen_count);
    try std.testing.expect(body.frozenCount() != 0);
    _ = try body.commit(take);
    try std.testing.expect(body.base > 0);
    try std.testing.expect(body.diverged);
    try std.testing.expectEqual(@as(usize, 0), body.frame_frozen_count);
    try std.testing.expect(body.frozen_count != 0);
}

test "staged freeze becomes final only after a fresh ACK" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    try body.append("| ");
    const long = try a.alloc(u8, 4000);
    defer a.free(long);
    @memset(long, 'h');
    try body.append(long);
    try body.build();
    try std.testing.expect(body.render.candidate != null);
    const rows = body.visibleRows().len;
    const take = body.releaseLimit(rows - 3);
    try std.testing.expect(take > 0);
    try std.testing.expect(!body.diverged);
    try std.testing.expect(body.frozenCount() != 0);
    const before = body.windowBytes();
    try std.testing.expectEqual(@as(usize, 0), try body.commit(0));
    try std.testing.expectEqual(@as(usize, 0), body.frozen_count);
    try std.testing.expect(!body.diverged);
    try std.testing.expectEqual(before, body.windowBytes());
    // A discarded frame keeps the prior committed decision (none here) and the
    // retained source; only the frame-local snapshot is dropped.
    body.abort();
    try std.testing.expect(!body.diverged);
    try std.testing.expectEqual(@as(usize, 0), body.frozenCount());
    try std.testing.expectEqual(@as(usize, 0), body.frozen_count);
    try std.testing.expectEqual(before, body.windowBytes());
    try body.build();
    const rows2 = body.visibleRows().len;
    const again = body.releaseLimit(rows2 - 3);
    try std.testing.expectEqual(take, again);
    try std.testing.expect(!body.diverged);
    try std.testing.expectEqual(@as(usize, again), try body.commit(again));
    try std.testing.expect(body.diverged);
    try std.testing.expectEqual(@as(usize, 0), body.frame_frozen_count);
    try std.testing.expect(body.frozen_count != 0);
}

test "freeze commit allocation failure never publishes a semantic decision" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{});
    const body = try Body.create(failing.allocator(), 40);
    defer body.destroy();
    // A retained definition forces the commit path to allocate before any
    // publication; the trailing ambiguous header forces the staged freeze.
    try body.append("[r]: https://example.org/one\n\nintro\n| ");
    const long = try a.alloc(u8, 4000);
    defer a.free(long);
    @memset(long, 'h');
    try body.append(long);
    try body.build();
    try std.testing.expect(body.render.candidate != null);
    try std.testing.expect(body.render.definitions.len != 0);
    const rows = body.visibleRows().len;
    const take = body.releaseLimit(rows - 3);
    try std.testing.expect(take > 0);
    try std.testing.expect(!body.diverged);
    try std.testing.expectEqual(@as(usize, 0), body.frozen_count);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, body.commit(take));
    // Nothing was published: no committed freeze, no final interpretation.
    try std.testing.expect(!body.diverged);
    try std.testing.expectEqual(@as(usize, 0), body.frozen_count);
    try std.testing.expectEqual(@as(usize, 0), body.frame_frozen_count);
    try std.testing.expect(body.base == 0);
    // The same frame can be acknowledged once allocation succeeds.
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, take), try body.commit(take));
    try std.testing.expect(body.diverged);
    try std.testing.expect(body.frozen_count != 0);
}

test "frozen containment requires full coverage and never overextends" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    try std.testing.expect(body.freezeCandidate(0, 100));
    // Staged, not committed.
    try std.testing.expect(!body.diverged);
    try std.testing.expectEqual(@as(usize, 0), body.frozen_count);
    body.mergeFrameFrozen();
    try std.testing.expect(body.diverged);
    try std.testing.expectEqual(@as(usize, 1), body.frozenCount());
    try std.testing.expect(body.isFrozen(0, 100));
    // Touching the old decision is a NEW ambiguity, not an already-frozen one.
    try std.testing.expect(!body.isFrozen(100, 200));
    // A partial overlap decided only the shared bytes: the rest stays unknown.
    try std.testing.expect(!body.isFrozen(50, 150));
    // Contained candidates need no extra decision.
    try std.testing.expect(body.freezeCandidate(10, 20));
    try std.testing.expectEqual(@as(usize, 0), body.frame_frozen_count);
    // A candidate touching the committed range widens it, still one decision.
    try std.testing.expect(body.freezeCandidate(100, 200));
    try std.testing.expect(body.diverged);
    try std.testing.expectEqual(@as(usize, 1), body.frozen_count);
    try std.testing.expectEqual(@as(usize, 1), body.frozenCount());
    try std.testing.expect(body.isFrozen(100, 200));
    body.abort();
    try std.testing.expect(!body.isFrozen(100, 200));
    try std.testing.expect(body.isFrozen(0, 100));
}

test "coalesced freeze decisions never consume false capacity" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    var step: usize = 0;
    while (step < frozen_capacity) : (step += 1) {
        try std.testing.expect(body.freezeCandidate(step * 100, step * 100 + 50));
    }
    body.mergeFrameFrozen();
    try std.testing.expectEqual(frozen_capacity, body.frozenCount());
    // The committed set is full, but ranges that merge into existing decisions
    // need no fifth slot.
    try std.testing.expect(body.freezeCandidate(50, 100));
    try std.testing.expect(body.freezeCandidate(150, 200));
    try std.testing.expect(body.freezeCandidate(250, 300));
    try std.testing.expect(body.isFrozen(0, 350));
    try std.testing.expectEqual(@as(usize, 1), body.frozenCount());
    try std.testing.expect(body.freezeCandidate(500, 550));
    try std.testing.expect(body.freezeCandidate(700, 750));
    try std.testing.expect(body.freezeCandidate(900, 950));
    try std.testing.expectEqual(@as(usize, frozen_capacity), body.frozenCount());
    // A genuinely new ambiguity cannot silently evict the active decisions.
    try std.testing.expect(!body.freezeCandidate(1100, 1150));
    try std.testing.expectEqual(@as(usize, frozen_capacity), body.frozenCount());
    body.mergeFrameFrozen();
    try std.testing.expectEqual(@as(usize, frozen_capacity), body.frozenCount());
    try std.testing.expect(body.isFrozen(0, 350));
    try std.testing.expect(body.isFrozen(900, 950));
    try std.testing.expect(!body.isFrozen(1100, 1150));
}

test "partial ack of the first table keeps its own columns and alignments" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 60);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    var width_two_column: usize = 0;
    var width_three_column: usize = 0;
    try body.append("| aa | bb |\n| --- | ---: |\n| 11 | 22 |\n\nprose\n\n| xx | yy | zz |\n| :--- | ---: | :---: |\n| 33 | 44 | 55 |\n");
    try body.finish();
    try body.build();
    const first = body.releaseLimit(1);
    try std.testing.expectEqual(@as(usize, 1), first);
    try seen.appendSlice(a, body.visibleRows()[0].text);
    _ = try body.commit(first);
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 64);
        try body.build();
        if (body.hasMetadataProgress()) {
            _ = try body.commit(0);
            continue;
        }
        const take = body.releaseLimit(body.visibleRows().len);
        try std.testing.expect(take != 0);
        for (body.visibleRows()[0..take]) |row| {
            try seen.appendSlice(a, row.text);
            if (std.mem.indexOf(u8, row.text, "aa") != null) width_two_column = output.displayWidth(row.text);
            if (std.mem.indexOf(u8, row.text, "xx") != null) width_three_column = output.displayWidth(row.text);
        }
        _ = try body.commit(take);
    }
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, seen.items, "┬"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, seen.items, "┼"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, seen.items, "┴"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, seen.items, "└"));
    for ([_][]const u8{ "aa", "bb", "11", "22", "xx", "yy", "zz", "33", "44", "55" }) |cell| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, cell));
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "prose"));
    // Widths prove each table kept its own column count after the partial ACK:
    // 60 columns -> 2 * (26 + 3) + 1 = 59, 3 * (16 + 3) + 1 = 58.
    try std.testing.expectEqual(@as(usize, 59), width_two_column);
    try std.testing.expectEqual(@as(usize, 58), width_three_column);
}

fn countVisible(seen: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, seen, needle);
}

/// A container (blockquote/list) table must never put its marker or indent in a
/// cell, must close on a container-only line, and must release following prose
/// after the bottom rule. These expectations depend on the native container
/// fragment ABI.
fn expectContainerTableExactlyOnce(seen: []const u8, cells: []const []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), countVisible(seen, "┌"));
    try std.testing.expectEqual(@as(usize, 1), countVisible(seen, "└"));
    for (cells) |cell| {
        try std.testing.expectEqual(@as(usize, 1), countVisible(seen, cell));
    }
    // No container marker or indentation leaked into the first cell.
    try std.testing.expect(std.mem.indexOf(u8, seen, "│ > ") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "│ - ") == null);
}

fn drainOneRowAtATime(a: Allocator, body: *Body, out: *std.ArrayList(u8), max_steps: usize, resize_after: usize) !void {
    var steps: usize = 0;
    var resized = false;
    while (!body.isDrained()) {
        steps += 1;
        if (steps > max_steps) return error.TestUnexpectedResult;
        try body.build();
        if (body.hasMetadataProgress()) {
            _ = try body.commit(0);
            continue;
        }
        const take = body.releaseLimit(1);
        if (take == 0) return error.TestUnexpectedResult;
        for (body.visibleRows()[0..take]) |row| try out.appendSlice(a, row.text);
        _ = try body.commit(take);
        if (!resized and resize_after != 0 and body.base >= resize_after and !body.isDrained()) {
            resized = true;
            body.resize(48);
        }
    }
}

test "native metadata retires long leading table whitespace with bounded work" {
    const a = std.testing.allocator;
    const cases = [_]struct { header: []const u8, prefix: []const u8, split: bool, eof: bool }{
        .{ .header = "| A | B |\n| --- | --- |\n", .prefix = "|", .split = false, .eof = false },
        .{ .header = "| A | B |\n| --- | --- |\n", .prefix = "|", .split = true, .eof = true },
        .{ .header = "> | A | B |\n> | --- | --- |\n", .prefix = "> |", .split = true, .eof = false },
        .{ .header = "- | A | B |\n  | --- | --- |\n", .prefix = "  |", .split = true, .eof = true },
    };
    for (cases) |case| {
        const body = try Body.create(a, 40);
        defer body.destroy();
        var seen: std.ArrayList(u8) = .empty;
        defer seen.deinit(a);
        const spaces = try a.alloc(u8, 21000);
        defer a.free(spaces);
        @memset(spaces, ' ');
        try body.append(case.header);
        try body.append(case.prefix);
        var steps: usize = 0;
        while (!body.ctx.table_head_done or !body.ctx.table_sep_done) {
            steps += 1;
            try std.testing.expect(steps < 100);
            try body.build();
            try std.testing.expectEqual(Limit.none, body.limit);
            const take = body.releaseLimit(1);
            try std.testing.expectEqual(@as(usize, 1), take);
            try seen.appendSlice(a, body.visibleRows()[0].text);
            _ = try body.commit(take);
        }
        try body.append(spaces);
        if (!case.split) try body.append("|TAIL|\n");
        try body.build();
        try std.testing.expectEqual(@as(usize, 0), body.visibleRows().len);
        try std.testing.expect(body.hasMetadataProgress());
        try std.testing.expectEqual(body.base, body.visibleSourceEndForRows(0));
        const pinned_end = body.base + body.render.source_len;
        if (case.split) try body.append("|TAIL|");
        const old = body.base;
        _ = try body.commit(0);
        try std.testing.expect(body.base > old and body.base <= pinned_end);
        const committed = body.base;
        try body.build();
        try std.testing.expect(body.hasMetadataProgress());
        body.abort();
        try std.testing.expectEqual(committed, body.base);
        body.resize(44);
        try body.build();
        try std.testing.expect(body.hasMetadataProgress());
        _ = try body.commit(0);
        try std.testing.expect(body.base > committed);
        if (!case.eof) {
            if (case.split) try body.append("\n");
            if (std.mem.startsWith(u8, case.prefix, ">")) {
                try body.append("> | x > y | ZED |\n");
            } else if (std.mem.startsWith(u8, case.prefix, "  ")) {
                try body.append("  | x > y | ZED |\n");
            } else try body.append("| x > y | ZED |\n");
        }
        try body.finish();
        try drainOneRowAtATime(a, body, &seen, 4096, 0);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "TAIL"));
        if (!case.eof) {
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "> y"));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "ZED"));
        }
        try std.testing.expectEqual(body.acceptedSourceEnd(), body.base);
        try std.testing.expectEqual(Limit.none, body.limit);
        try std.testing.expect(body.stats.max_window_bytes <= 4096 + case.header.len + 128);
    }
}

test "finished sliced reference definition retains native deciding line" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 80);
    defer body.destroy();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "[r]: /url \"");
    try source.appendNTimes(a, 't', 9000);
    try source.appendSlice(a, "\"\n\n[link][r]\n");
    try body.append(source.items);
    try body.finish();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try drainOneRowAtATime(a, body, &seen, 128, 0);
    const plain = try stripTestCsi(a, seen.items);
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "link (/url)") != null);
    try std.testing.expectEqual(body.acceptedSourceEnd(), body.base);
    try std.testing.expectEqual(Limit.none, body.limit);
}

test "live sliced reference definition resolves before finish" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 80);
    defer body.destroy();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "[r]: /url \"");
    try source.appendNTimes(a, 't', 9000);
    try source.appendSlice(a, "\"\n\n[link][r]\n\n");
    try body.append(source.items);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    var steps: usize = 0;
    while (body.base < body.acceptedSourceEnd() and steps < 128) : (steps += 1) {
        try body.build();
        try std.testing.expectEqual(Limit.none, body.limit);
        if (body.hasMetadataProgress()) {
            _ = try body.commit(0);
            continue;
        }
        const take = body.releaseLimit(1);
        if (take == 0) break;
        for (body.visibleRows()[0..take]) |row| try seen.appendSlice(a, row.text);
        try std.testing.expectEqual(take, try body.commit(take));
    }
    const before_finish = try stripTestCsi(a, seen.items);
    defer a.free(before_finish);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, before_finish, "link (/url)"));
    try std.testing.expect(std.mem.indexOf(u8, before_finish, "tttt") == null);
    try std.testing.expect(body.base > 9000);
    try std.testing.expect(body.references != null);
    try body.finish();
    try drainOneRowAtATime(a, body, &seen, 128, 0);
    const plain = try stripTestCsi(a, seen.items);
    defer a.free(plain);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plain, "link (/url)"));
    try std.testing.expect(std.mem.indexOf(u8, plain, "tttt") == null);
    try std.testing.expectEqual(body.acceptedSourceEnd(), body.base);
    try std.testing.expectEqual(Limit.none, body.limit);
}

test "excess native table containers fail closed" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 80);
    defer body.destroy();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    for ([_][]const u8{ "| A | B |\n", "| --- | --- |\n", "| x | y |\n" }) |line| {
        for (0..17) |_| try source.appendSlice(a, "> ");
        try source.appendSlice(a, line);
    }
    try body.append(source.items);
    try body.finish();
    try body.build();
    try std.testing.expectEqual(Limit.containers, body.limit);
    try std.testing.expectEqual(@as(usize, 0), body.base);
    try std.testing.expectEqual(@as(usize, 0), try body.commit(body.visibleRows().len));
    try std.testing.expectEqual(@as(usize, 0), body.base);
    try std.testing.expect(body.references == null);
    try std.testing.expectEqualSlices(u8, source.items, body.source.items);
}

test "acknowledged table payload followed by empty closing cell makes metadata progress" {
    const a = std.testing.allocator;
    const cases = [_]struct { close: []const u8, eof: bool }{
        .{ .close = "|\n", .eof = false },
        .{ .close = "   |\n", .eof = false },
        .{ .close = "|", .eof = true },
    };
    for (cases) |case| {
        const body = try Body.create(a, 40);
        defer body.destroy();
        var seen: std.ArrayList(u8) = .empty;
        defer seen.deinit(a);
        try body.append("| A | B |\n| --- | --- |\n|");
        const payload: [256]u8 = @splat('x');
        try body.append(&payload);
        var data_rows: usize = 0;
        var steps: usize = 0;
        while (body.base < body.acceptedSourceEnd() and steps < 256) {
            steps += 1;
            try body.build();
            try std.testing.expectEqual(Limit.none, body.limit);
            if (body.hasMetadataProgress()) {
                _ = try body.commit(0);
                continue;
            }
            const take = body.releaseLimit(1);
            try std.testing.expect(take != 0);
            for (body.visibleRows()[0..take]) |display_row| {
                if (display_row.table_kind == .data) data_rows += 1;
                try seen.appendSlice(a, display_row.text);
            }
            try std.testing.expectEqual(take, try body.commit(take));
        }
        try std.testing.expectEqual(body.acceptedSourceEnd(), body.base);
        try std.testing.expect(body.ctx.table_row_had_output);
        const before_close_rows = data_rows;
        try body.append(case.close);
        if (case.eof) {
            try body.finish();
        } else {
            try body.build();
            try std.testing.expectEqual(@as(usize, 0), body.visibleRows().len);
            try std.testing.expect(body.hasMetadataProgress());
            _ = try body.commit(0);
            try body.finish();
        }
        steps = 0;
        while (!body.isDrained() and steps < 256) {
            steps += 1;
            try body.build();
            try std.testing.expectEqual(Limit.none, body.limit);
            if (body.hasMetadataProgress()) {
                _ = try body.commit(0);
                continue;
            }
            const take = body.releaseLimit(1);
            try std.testing.expect(take != 0);
            for (body.visibleRows()[0..take]) |display_row| {
                if (display_row.table_kind == .data) data_rows += 1;
                try seen.appendSlice(a, display_row.text);
            }
            try std.testing.expectEqual(take, try body.commit(take));
        }
        try std.testing.expect(body.isDrained());
        try std.testing.expectEqual(before_close_rows, data_rows);
        try std.testing.expectEqual(@as(usize, 256), std.mem.count(u8, seen.items, "x"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "└"));
        try std.testing.expectEqual(body.acceptedSourceEnd(), body.base);
        try std.testing.expectEqual(body.acceptedSourceEnd(), body.stats.retired_bytes);
    }
}

test "long leading whitespace preserves one completed empty grid row" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    try body.append("| A | B |\n| --- | --- |\n|");
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    var steps: usize = 0;
    while (!body.ctx.table_head_done or !body.ctx.table_sep_done) {
        steps += 1;
        try std.testing.expect(steps < 100);
        try body.build();
        const n = body.releaseLimit(1);
        try std.testing.expectEqual(@as(usize, 1), n);
        try seen.appendSlice(a, body.visibleRows()[0].text);
        _ = try body.commit(n);
    }
    const spaces = try a.alloc(u8, 21000);
    defer a.free(spaces);
    @memset(spaces, ' ');
    try body.append(spaces);
    try body.append("| |\n");
    try body.finish();
    try drainOneRowAtATime(a, body, &seen, 4096, 0);
    // Header plus exactly one empty body row, with three vertical rules each.
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, seen.items, "│"));
    try std.testing.expectEqual(body.acceptedSourceEnd(), body.base);
}

test "large generated table link suffix drains across single row acknowledgements" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "[r]: https://example.org/");
    try source.appendNTimes(a, 'q', 5000);
    try source.appendSlice(a, "\n\n| A | B |\n| --- | --- |\n| [link][r] | TAIL |\n");
    try body.append(source.items);
    try body.finish();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try drainOneRowAtATime(a, body, &seen, 4096, 0);
    try std.testing.expectEqual(@as(usize, 5000), std.mem.count(u8, seen.items, "q"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "TAIL"));
    try std.testing.expectEqual(body.acceptedSourceEnd(), body.base);
    try std.testing.expectEqual(Limit.none, body.limit);
}

test "streamed quote table uses native container context for every row" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 60);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("> aa | bb\n> --- | ---\n> cc | dd\n>\n> after\n");
    try body.finish();
    try body.build();
    try std.testing.expect(body.releaseLimit(1) != 0);
    try seen.appendSlice(a, body.visibleRows()[0].text);
    _ = try body.commit(1);
    body.abort();
    try body.build();
    try std.testing.expect(body.releaseLimit(1) != 0);
    body.abort();
    try drainOneRowAtATime(a, body, &seen, 64, 20);
    try expectContainerTableExactlyOnce(seen.items, &.{ "aa", "bb", "cc", "dd" });
    const after = std.mem.indexOf(u8, seen.items, "after") orelse return error.TestUnexpectedResult;
    const bottom = std.mem.indexOf(u8, seen.items, "└") orelse return error.TestUnexpectedResult;
    try std.testing.expect(after > bottom);
}

test "streamed container table prefix variants keep cells free of markers" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        ">|aa|bb|\n>|---|---|\n>|cc|dd|\n",
        ">\t|aa|bb|\n>\t|---|---|\n>\t|cc|dd|\n",
        ">  aa | bb\n>  --- | ---\n>  cc | dd\n",
        "- aa | bb\n  --- | ---\n  cc | dd\n\n  after\n",
    }) |source| {
        const body = try Body.create(a, 60);
        defer body.destroy();
        var seen: std.ArrayList(u8) = .empty;
        defer seen.deinit(a);
        try body.append(source);
        try body.finish();
        try drainOneRowAtATime(a, body, &seen, 64, 0);
        try expectContainerTableExactlyOnce(seen.items, &.{ "aa", "bb", "cc", "dd" });
        const after = std.mem.indexOf(u8, seen.items, "after");
        const bottom = std.mem.indexOf(u8, seen.items, "└") orelse return error.TestUnexpectedResult;
        if (after) |position| try std.testing.expect(position > bottom);
    }
}

test "dedented nonblank prose ends a streamed quote table before it" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 60);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("> aa | bb\n> --- | ---\n> cc | dd\nafter\n");
    try body.finish();
    try drainOneRowAtATime(a, body, &seen, 64, 0);
    try expectContainerTableExactlyOnce(seen.items, &.{ "aa", "bb", "cc", "dd" });
    const after = std.mem.indexOf(u8, seen.items, "after") orelse return error.TestUnexpectedResult;
    const bottom = std.mem.indexOf(u8, seen.items, "└") orelse return error.TestUnexpectedResult;
    try std.testing.expect(after > bottom);
}

test "streamed quote table survives mid-cell ACK and resize" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 40);
    defer body.destroy();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "> | long | tail |\n> | --- | --- |\n> | ");
    for (0..900) |_| try source.append(a, 'x');
    try source.appendSlice(a, " | end |\n> | coda | delta |\n>\n> after\n");
    try body.append(source.items);
    try body.finish();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try drainOneRowAtATime(a, body, &seen, 512, 200);
    try expectContainerTableExactlyOnce(seen.items, &.{ "long", "tail", "end", "coda", "delta" });
    try std.testing.expectEqual(@as(usize, 900), std.mem.count(u8, seen.items, "x"));
    // The mid-cell continuation never reintroduced the quote marker as content.
    try std.testing.expect(std.mem.indexOf(u8, seen.items, "│ >") == null);
    const after = std.mem.indexOf(u8, seen.items, "after") orelse return error.TestUnexpectedResult;
    const bottom = std.mem.indexOf(u8, seen.items, "└") orelse return error.TestUnexpectedResult;
    try std.testing.expect(after > bottom);
}

test "native adjacent table inputs match static rendering exactly" {
    const a = std.testing.allocator;
    // Static batch and incremental renderers must agree on the same raw input.
    const body = try Body.create(a, 60);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("intro\n| aa | bb |\n| --- | --- |\n| 11 | 22 |\n");
    try body.finish();
    try drainOneRowAtATime(a, body, &seen, 64, 0);
    try std.testing.expectEqual(@as(usize, 1), countVisible(seen.items, "┌"));
    try std.testing.expectEqual(@as(usize, 1), countVisible(seen.items, "└"));
    for ([_][]const u8{ "aa", "bb", "11", "22" }) |cell| {
        try std.testing.expectEqual(@as(usize, 1), countVisible(seen.items, cell));
    }
    try std.testing.expectEqual(@as(usize, 1), countVisible(seen.items, "intro"));
}

test "quote-only closing line ends the streamed table instead of becoming a row" {
    const a = std.testing.allocator;
    const body = try Body.create(a, 60);
    defer body.destroy();
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(a);
    try body.append("> a | b\n> --- | ---\n> c | d\n>\n> after\n");
    try body.finish();
    var steps: usize = 0;
    while (!body.isDrained()) {
        steps += 1;
        try std.testing.expect(steps < 32);
        try body.build();
        if (body.hasMetadataProgress()) {
            _ = try body.commit(0);
            continue;
        }
        const take = body.releaseLimit(1);
        try std.testing.expect(take != 0);
        for (body.visibleRows()[0..take]) |row| try seen.appendSlice(a, row.text);
        _ = try body.commit(take);
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen.items, "└"));
    const after = std.mem.indexOf(u8, seen.items, "after") orelse return error.TestUnexpectedResult;
    const bottom = std.mem.indexOf(u8, seen.items, "└") orelse return error.TestUnexpectedResult;
    // The closing container line ended the table: the following quote paragraph
    // is displayed after the rule, never as a table row.
    try std.testing.expect(after > bottom);
}

test "allocation failure leaves readable state and destroys cleanly" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, Body.create(a, 20));
}
