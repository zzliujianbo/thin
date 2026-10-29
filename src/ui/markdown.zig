//! CommonMark + GFM terminal rendering through vendored MD4C, not regex toggles.
//! Images/HTML/math have textual fallbacks, never fetch URLs or execute markup.
const std = @import("std");
const text = @import("text.zig");
const md = @import("md4c.zig");
const stream_table = @import("stream_table.zig");
const output = @import("markdown_writer.zig");
const Allocator = std.mem.Allocator;
const Writer = output.Writer;
const Style = output.Style;
pub const Tone = output.Tone;
pub const Options = struct { columns: usize, max_lines: usize, ansi: bool = true, markdown: bool = true, tone: Tone = .normal };
pub const Rendered = struct { lines: []const []const u8, total_lines: usize, truncated: bool, degraded: bool = false };
const limit = 256 * 1024;

const Frame = struct { kind: c_int, style: Style, prefix: []const u8, continuation: ?[]const u8, next: usize = 1, children: usize = 0 };
const Cell = struct { lines: []const []const u8, alignment: c_int, origin_start: usize = std.math.maxInt(usize), origin_end: usize = 0 };

/// One rendered row of a streamed window with its own parser-source span.
/// `start`/`end` are offsets into the window's SOURCE region (context bytes are
/// already excluded); `synthetic` rows carry no source byte at all.
pub const TableProgress = struct {
    row_begin: usize,
    row_end: usize,
    delivered: [32]usize = @splat(0),
    output_bytes: [32]usize = @splat(0),
    active_column: usize = 0,
    cell_complete: bool = false,
    row_complete: bool = false,
    /// Columns whose parsed cell is ended AND fully materialized in physical
    /// rows. Only then may the caller treat the remaining cell bytes as
    /// trailing syntax instead of undisplayed text.
    settled: u32 = 0,
};
pub const TableOccurrence = stream_table.Occurrence;
pub const TableRowKind = stream_table.PhysicalRowKind;
pub const WindowRow = struct { text: []const u8, start: usize = std.math.maxInt(usize), end: usize = 0, synthetic: bool = true, leaf: usize = 0, output_start: usize = 0, output_end: usize = 0, output_window: usize = 0, table: ?TableProgress = null, table_kind: ?TableRowKind = null, table_checkpoint: ?TableProgress = null, table_occurrences: []const TableOccurrence = &.{}, prefix: []const u8 = "" };

pub const LeafKind = enum { paragraph, heading, code, table, rule, html, container, document };

/// Resume context at a source position. `prefix`/`continuation` are the exact
/// Writer prefix strings the leaf displayed, so a resumed window reproduces the
/// same container indentation instead of re-parsing retired history.
pub const LeafCtx = struct {
    kind: LeafKind = .document,
    prefix: []const u8 = "",
    continuation: []const u8 = "",
    style: Style = .{},
    fence: u8 = '`',
    fence_length: usize = 3,
    header_open: bool = false,
    header_run: bool = false,
    closing_begin: ?usize = null,
    closing_end: ?usize = null,
    indented: bool = false,
    /// Raw header line(s) including the delimiter row for a table context.
    table_header: []const u8 = "",
    table_header_begin: usize = 0,
    table_body_begin: usize = 0,
    table_header_complete: bool = false,
    table_columns: usize = 0,
    table_align: [32]c_int = @splat(0),
    /// Raw window offsets of the table header cells (0/0 when absent).
    table_head_start: usize = 0,
    table_head_end: usize = 0,
    /// Physical rows (top rule + header rows + middle rule) before body rows.
    table_head_rows: usize = 0,
    /// Native container snapshot of this table (outermost first), arena-owned by
    /// the window/render that produced it. Empty for a top-level table.
    table_containers: []const md.TableContainer = &.{},
};

pub const WindowLeaf = struct {
    kind: LeafKind,
    ctx: LeafCtx,
    row_start: usize,
    row_end: usize = 0,
    /// Writer context in effect when the next block/leaf started (or window end).
    after: LeafCtx = .{},
    after_document: bool = false,
};

/// Native-confirmed delimiters, in absolute sanitized-source coordinates.
/// The opener may be retired, but its exact closer and semantic styles remain.
pub const CodePiece = struct {
    begin: usize,
    end: usize,
    text: []const u8,
    exact: bool,
};

pub const ConfirmedSpan = struct {
    kind: c_int,
    opener_begin: usize,
    opener_end: usize,
    closer_begin: usize,
    closer_end: usize,
    before: Style,
    inside: Style,
    /// Generated suffix has its own cursor: source progress cannot represent a
    /// partially acknowledged URL or image decoration.
    suffix: []const u8 = "",
    suffix_offset: usize = 0,
    suffix_skip: usize = 0,
    suffix_style_split: usize = 0,
    suffix_start: usize = 0,
    suffix_end: usize = 0,
    suffix_pending: bool = false,
    output_window: usize = 0,
    /// Table column owning this span (maxInt outside a table cell). Table output
    /// bytes are cell-relative, so suffix progress needs the column identity.
    column: usize = std.math.maxInt(usize),
    code: []const CodePiece = &.{},
    code_first: usize = 0,
    code_count: usize = 0,

    /// Copy into an owning checkpoint arena; retain no already-retired code text.
    pub fn clone(self: ConfirmedSpan, a: Allocator, cut: usize) !ConfirmedSpan {
        var next = self;
        const skip = @min(self.suffix_skip -| self.suffix_offset, self.suffix.len);
        next.suffix = try a.dupe(u8, self.suffix[skip..]);
        errdefer a.free(next.suffix);
        next.suffix_offset += skip;
        var pieces: std.ArrayList(CodePiece) = .empty;
        errdefer {
            for (pieces.items) |piece| a.free(piece.text);
            pieces.deinit(a);
        }
        for (self.code) |piece| {
            if (piece.end <= cut) continue;
            var copy = piece;
            if (copy.exact and copy.begin < cut) {
                copy.text = copy.text[cut - copy.begin ..];
                copy.begin = cut;
            }
            copy.text = try a.dupe(u8, copy.text);
            errdefer a.free(copy.text);
            try pieces.append(a, copy);
        }
        next.code = try pieces.toOwnedSlice(a);
        next.code_first = 0;
        next.code_count = 0;
        return next;
    }

    pub fn deinit(self: ConfirmedSpan, a: Allocator) void {
        a.free(self.suffix);
        for (self.code) |piece| a.free(piece.text);
        a.free(self.code);
    }
};

pub const CellRange = struct { column: usize, begin: usize, end: usize, row_begin: usize, row_end: usize, raw_begin: usize = 0, raw_end: usize = 0, next_begin: usize = 0, alignment: c_int = 0, cell_complete: bool = true, row_complete: bool = true, header: bool = false, present: bool = true };
/// Bounded container checkpoint depth. A deeper native nesting is an explicit
/// resource failure for the table, never a silently truncated snapshot.
pub const max_table_containers = 16;
pub const TableContinuation = struct {
    columns: usize,
    header: []const u8 = "",
    header_begin: usize = 0,
    body_begin: usize = 0,
    header_complete: bool = false,
    first_column: usize = 0,
    alignments: [32]c_int = @splat(0),
    delivered: [32]usize = @splat(0),
    output_bytes: [32]usize = @splat(0),
    partial_cell: bool = false,
    trim_leading: bool = false,
    /// Native container snapshot of THIS table (outermost first). The fragment
    /// grammar consumes each physical line's real prefix from it.
    containers: []const md.TableContainer = &.{},
    /// The window starts after an already-consumed container prefix, so only
    /// the first physical line skips prefix stripping.
    first_line_partial: bool = false,
    /// Middle separator acknowledged (header finished).
    header_done: bool = true,
    top_done: bool = false,
    separator_pending: bool = false,
    finish_requested: bool = false,
    bottom_done: bool = false,
    row_had_output: bool = false,
    row_begin: ?usize = null,
    prefix: []const u8 = "",
    continuation: []const u8 = "",
};

/// One native reference definition captured for this window. `begin`/`end` are
/// absolute source offsets; `event` owns copies of the raw attribute bytes in
/// the window arena so a later store prepare never references retired input.
pub const Definition = struct { begin: usize, end: usize, event: md.ReferenceDefinition };
/// Native-confirmed ambiguous trailing source that must stay mutable.
pub const Candidate = struct { begin: usize, end: usize, reason: c_uint };

pub const WindowOptions = struct {
    columns: usize,
    ansi: bool = true,
    base: Tone = .normal,
    /// Leading bytes of `input` that belong to synthesized context.
    context_bytes: usize = 0,
    /// Inline fragment mode: preset prefix/style, no document/paragraph gap.
    fragment: ?LeafCtx = null,
    source_base: usize = 0,
    /// Outer-to-inner spans whose openers were acknowledged in an earlier frame.
    confirmed: []const ConfirmedSpan = &.{},
    final: bool = true,
    streaming_tables: bool = false,
    /// Committed reference store; consulted by every document, inline and
    /// table subparse of this window.
    references: ?*const md.ReferenceStore = null,
    table: ?TableContinuation = null,
    /// Parse `input` as continuation rows of an already established table.
    /// Without it `table` is presentation-only proof for a document parse.
    table_fragment: bool = false,
    max_rows: usize = 4096,
};

pub const Window = struct {
    rows: []WindowRow,
    leaves: []WindowLeaf,
    confirmed: []ConfirmedSpan = &.{},
    cells: []CellRange = &.{},
    resume_anchor: ?usize = null,
    end: LeafCtx = .{},
    end_is_document: bool = false,
    leaf_open: bool = false,
    truncated: bool = false,
    degraded: bool = false,
    /// Parser stopped intentionally; input after the checkpoint is not consumed.
    yielded: bool = false,
    table_frontier: ?TableProgress = null,
    /// Definitions discovered in this window (absolute source ranges).
    definitions: []const Definition = &.{},
    table_headers: []const []const u8 = &.{},
    /// Earliest ambiguous partial-input range reported by the native grammar.
    candidate: ?Candidate = null,
    /// Native table-fragment boundary (fragment mode only): the rows end at
    /// `table_end`, and `input[table_end..]` is prose at its original raw line
    /// start. `table_end` excludes synthesized context bytes.
    table_closed: bool = false,
    table_end: usize = 0,
};

const Row = struct { cells: []const Cell, header: bool };
const TableEdge = enum { top, middle, bottom };
const Table = struct {
    main: Writer,
    columns: usize,
    cell_width: usize,
    stacked: bool,
    alignment: c_int = 0,
    header: bool = false,
    cells: std.ArrayList(Cell) = .empty,
    rows: std.ArrayList(Row) = .empty,
    stream: ?*stream_table.Table = null,
    cell_index: usize = 0,
    header_start: usize = std.math.maxInt(usize),
    header_end: usize = 0,
    last_source_end: usize = 0,
    row_begin: usize = 0,
    row_end: usize = 0,
    /// Native container snapshot of this table (outermost first).
    containers: []const md.TableContainer = &.{},
    header_source: []const u8 = "",
    header_begin: usize = 0,
    body_begin: usize = 0,
    header_complete: bool = false,
    /// Physical rows already materialized in THIS render pass.
    emitted_rows: usize = 0,
    checkpoint: TableProgress = .{ .row_begin = std.math.maxInt(usize), .row_end = 0 },
    cell_complete: bool = true,
    row_complete: bool = true,
};

const Renderer = struct {
    w: Writer,
    blocks: [128]Frame = undefined,
    depth: usize = 0,
    spans: [128]Style = undefined,
    span_records: [128]?usize = undefined,
    span_depth: usize = 0,
    table: ?Table = null,
    failure: ?anyerror = null,
    yielded: bool = false,
    table_yield_pending: bool = false,
    table_drain_full: bool = false,
    table_frontier: ?TableProgress = null,
    resume_anchor: ?usize = null,
    pending_text: std.ArrayList(u8) = .empty,
    // Pending buffered text source provenance. `valid` is false when the whole
    // run is renderer-synthetic; `exact` means the bytes are a verbatim copy of
    // the contiguous [start,end) parser-source span.
    pending_src_start: usize = 0,
    pending_src_end: usize = 0,
    pending_src_exact: bool = true,
    pending_src_valid: bool = false,
    pending_entity_start: usize = 0,
    pending_entity_end: usize = 0,
    pending_entity_valid: bool = false,
    // Streamed-window state. `window` is the md input used for pointer-range
    // source tests; `context_bytes` are leading synthesized context bytes.
    window: ?[]const u8 = null,
    context_bytes: usize = 0,
    source_base: usize = 0,
    parser_offset: usize = 0,
    pending_span: ?md.InlineSpan = null,
    pending_fence: ?md.FenceSource = null,
    pending_code_close: ?struct { begin: usize, end: usize } = null,
    confirmed: std.ArrayList(ConfirmedSpan) = .empty,
    code_pieces: std.ArrayList(CodePiece) = .empty,
    code_owner: ?usize = null,
    semantic_allocator: ?Allocator = null,
    inline_mode: bool = false,
    fragment_kind: LeafKind = .paragraph,
    leaves: std.ArrayList(WindowLeaf) = .empty,
    collect: ?*std.ArrayList(WindowRow) = null,
    row_limit: usize = 4096,
    final: bool = true,
    streaming_tables: bool = false,
    references: ?*const md.ReferenceStore = null,
    definitions: std.ArrayList(Definition) = .empty,
    candidate: ?Candidate = null,
    /// Borrowed container snapshot native reported for the table that is about
    /// to be entered; copied into the table/leaf context immediately.
    pending_containers: []const md.TableContainer = &.{},
    table_headers: std.ArrayList([]const u8) = .empty,
    pending_table_header: []const u8 = "",
    pending_table_begin: usize = 0,
    pending_table_body: usize = 0,
    pending_table_complete: bool = false,
    table_resume: ?TableContinuation = null,
    deferred_table_resume: ?TableContinuation = null,
    table_fragment: bool = false,
    resume_spans: []const ConfirmedSpan = &.{},
    cells: std.ArrayList(CellRange) = .empty,
    leaf_open: bool = false,
    cell_src_start: usize = std.math.maxInt(usize),
    cell_src_end: usize = 0,
    table_head_rows: usize = 0,

    fn sourceOffset(self: *Renderer, s: []const u8) ?usize {
        const win = self.window orelse return null;
        if (s.len == 0 or win.len == 0) return null;
        const base = @intFromPtr(win.ptr);
        const address = @intFromPtr(s.ptr);
        if (address < base) return null;
        const off = address - base;
        if (off > win.len or s.len > win.len - off) return null;
        return off;
    }

    fn noteCell(self: *Renderer, start: usize, end: usize) void {
        if (self.table == null) return;
        if (start < self.context_bytes) return;
        const s = start - self.context_bytes;
        const e = end - self.context_bytes;
        self.cell_src_start = @min(self.cell_src_start, s);
        self.cell_src_end = @max(self.cell_src_end, e);
    }

    fn bufferSourced(self: *Renderer, s: []const u8, start: usize, end: usize, exact: bool) !void {
        try self.step(s.len);
        if (self.pending_text.items.len != 0) {
            const same_atomic = self.pending_src_valid and !exact and !self.pending_src_exact and
                start == self.pending_src_start and end == self.pending_src_end;
            const linear_contiguous = self.pending_src_valid and exact and self.pending_src_exact and
                start == self.pending_src_end;
            if (!same_atomic and !linear_contiguous) try self.flushText();
        }
        if (self.pending_text.items.len == 0) {
            self.pending_src_start = start;
            self.pending_src_end = end;
            self.pending_src_exact = exact;
            self.pending_src_valid = true;
        } else {
            self.pending_src_end = @max(self.pending_src_end, end);
        }
        try self.pending_text.appendSlice(self.w.a, s);
    }

    fn beginLeaf(self: *Renderer, kind: LeafKind) !void {
        try self.leaves.append(self.w.a, .{ .kind = kind, .ctx = .{ .kind = kind }, .row_start = if (self.collect) |rows| rows.items.len else 0 });
        self.leaf_open = true;
    }

    fn syncLeafCtx(self: *Renderer, kind: c_int, raw: ?*anyopaque) void {
        if (self.leaves.items.len == 0) return;
        const leaf = &self.leaves.items[self.leaves.items.len - 1];
        leaf.ctx.prefix = self.w.prefix;
        leaf.ctx.continuation = self.w.continuation orelse "";
        leaf.ctx.style = self.w.style;
        if (kind == 7) {
            const code = detail(md.Code, raw);
            leaf.ctx.fence = if (code.fence == '~') '~' else '`';
            leaf.ctx.indented = code.fence == 0;
            if (self.pending_fence) |fence| {
                leaf.ctx.fence_length = fence.fence_end - fence.fence_begin;
                const input = self.window.?;
                leaf.ctx.header_open = !self.final and fence.header_end == input.len and (input.len == 0 or input[input.len - 1] != '\n');
                leaf.ctx.header_run = leaf.ctx.header_open and fence.fence_end == fence.header_end;
                if (fence.closing_end > fence.closing_begin) {
                    if (!self.final and fence.closing_end == input.len) {
                        self.pending_code_close = .{ .begin = fence.closing_begin, .end = fence.closing_end };
                    } else {
                        leaf.ctx.closing_begin = (self.nativeOffset(fence.closing_begin) catch null);
                        leaf.ctx.closing_end = (self.nativeOffset(fence.closing_end) catch null);
                    }
                }
            }
            self.pending_fence = null;
        }
        if (kind == 10) {
            const table = detail(md.Table, raw);
            leaf.ctx.table_columns = @min(@as(usize, table.columns), 32);
            if (self.table_resume) |resume_table| {
                leaf.ctx.table_align = resume_table.alignments;
                if (self.table_fragment) {
                    leaf.ctx.table_header = resume_table.header;
                    leaf.ctx.table_header_begin = resume_table.header_begin;
                    leaf.ctx.table_body_begin = resume_table.body_begin;
                    leaf.ctx.table_header_complete = resume_table.header_complete;
                    leaf.ctx.table_containers = resume_table.containers;
                }
            }
            if (self.table) |table_state| {
                if (!self.table_fragment) {
                    leaf.ctx.table_containers = table_state.containers;
                    leaf.ctx.table_header = table_state.header_source;
                    leaf.ctx.table_header_begin = table_state.header_begin;
                    leaf.ctx.table_body_begin = table_state.body_begin;
                    leaf.ctx.table_header_complete = table_state.header_complete;
                }
            }
        }
    }

    /// Track the context that will describe the source position right after the
    /// current leaf. Container closes and blank-line effects arrive after the
    /// leaf's own leave callback, so this is refreshed after every block event.
    fn updateAfter(self: *Renderer) void {
        if (self.leaves.items.len == 0) return;
        const leaf = &self.leaves.items[self.leaves.items.len - 1];
        if (self.leaf_open and leaf.kind == .code and !leaf.ctx.indented and !self.final and leaf.ctx.closing_end == null) {
            leaf.after = leaf.ctx;
            leaf.after_document = false;
            return;
        }
        leaf.after = .{
            .kind = if (self.leaf_open) leaf.kind else if (self.depth > 1) .container else .document,
            .prefix = self.w.prefix,
            .continuation = self.w.continuation orelse "",
            .style = self.w.style,
            .fence = leaf.ctx.fence,
            .fence_length = leaf.ctx.fence_length,
            .header_open = leaf.ctx.header_open,
            .header_run = leaf.ctx.header_run,
            .closing_begin = leaf.ctx.closing_begin,
            .closing_end = leaf.ctx.closing_end,
            .indented = leaf.ctx.indented,
            .table_header = leaf.ctx.table_header,
            .table_header_begin = leaf.ctx.table_header_begin,
            .table_body_begin = leaf.ctx.table_body_begin,
            .table_header_complete = leaf.ctx.table_header_complete,
            .table_columns = leaf.ctx.table_columns,
            .table_align = leaf.ctx.table_align,
            .table_containers = leaf.ctx.table_containers,
        };
        leaf.after_document = leaf.after.kind == .document;
    }

    fn rowSink(context: *anyopaque, row: []const u8, src_start: usize, prefix: []const u8) output.Error!void {
        const self = selfFrom(context);
        // OWNERSHIP: on an error return the Writer still owns `row` and frees it.
        const rows = self.collect orelse return;
        if (rows.items.len >= self.row_limit) return error.MarkdownRenderLimit;
        const synthetic = self.w.origin_synthetic or self.w.origin_start == std.math.maxInt(usize);
        const leaf_index = if (self.leaves.items.len == 0) @as(usize, 0) else self.leaves.items.len - 1;
        try rows.append(self.w.a, .{
            .text = row,
            .start = if (synthetic) std.math.maxInt(usize) else self.w.origin_start,
            .end = if (synthetic) 0 else self.w.origin_end,
            .synthetic = synthetic,
            .leaf = leaf_index,
            .output_start = src_start,
            .output_window = self.source_base,
            .prefix = prefix,
        });
    }

    // Text/entity callbacks are transport chunks, not grapheme boundaries.
    // Buffer a style run so FE0F/combining/ZWJ decode exactly like literal text.
    fn bufferText(self: *Renderer, s: []const u8) !void {
        try self.step(s.len);
        if (self.pending_src_valid) try self.flushText();
        try self.pending_text.appendSlice(self.w.a, s);
    }

    fn flushText(self: *Renderer) !void {
        if (self.pending_text.items.len == 0) return;
        if (self.window != null and self.pending_src_valid and self.context_bytes <= self.pending_src_start) {
            const exact = self.pending_src_exact and self.pending_text.items.len == self.pending_src_end - self.pending_src_start;
            try self.w.emitSourced(self.pending_text.items, self.pending_src_start - self.context_bytes, self.pending_src_end - self.context_bytes, exact);
        } else try self.w.emit(self.pending_text.items);
        self.pending_text.clearRetainingCapacity();
        self.pending_src_valid = false;
        self.pending_src_exact = true;
        self.pending_src_start = 0;
        self.pending_src_end = 0;
    }

    fn detail(comptime T: type, raw: ?*anyopaque) *const T {
        return @ptrCast(@alignCast(raw.?));
    }

    fn step(self: *Renderer, n: usize) !void {
        if (self.w.budget) |budget| try budget.step(n);
    }

    fn containerPrefix(self: *Renderer, extra: []const u8) ![]const u8 {
        try self.step(self.w.prefix.len + extra.len);
        return std.fmt.allocPrint(self.w.a, "{s}{s}", .{ self.w.prefix, extra });
    }

    fn enterBlock(self: *Renderer, kind: c_int, raw: ?*anyopaque) !void {
        try self.flushText();
        try self.step(1);
        if (kind == 7) {
            const code = detail(md.Code, raw);
            try self.step(@as(usize, code.info.size) + code.lang.size);
        }
        switch (kind) {
            5 => try self.beginLeaf(.rule),
            6 => try self.beginLeaf(.heading),
            7 => try self.beginLeaf(.code),
            8 => try self.beginLeaf(.html),
            9 => try self.beginLeaf(if (self.inline_mode) self.fragment_kind else .paragraph),
            10 => try self.beginLeaf(.table),
            else => {},
        }
        if (self.depth == self.blocks.len) return error.MarkdownDepthLimit;
        // Separate sibling text blocks, but do not insert gaps into tight list
        // items or table cells. Empty parent items still need a visible bullet.
        if (!(self.inline_mode and self.depth <= 1) and self.depth != 0 and (kind == 1 or kind == 2 or kind == 3 or kind == 5 or kind == 6 or kind == 7 or kind == 9 or kind == 10)) {
            const parent = &self.blocks[self.depth - 1];
            if (parent.kind == 4 and kind != 9 and self.w.continuation != null and !self.w.hasContent()) try self.w.emit(" ");
            if (parent.kind == 0 or parent.kind == 1 or parent.kind == 4) {
                if (parent.children != 0) {
                    try self.w.boundary();
                    try self.w.finish();
                }
                parent.children += 1;
            }
        }
        const frame = &self.blocks[self.depth];
        frame.* = .{ .kind = kind, .style = self.w.style, .prefix = self.w.prefix, .continuation = self.w.continuation };
        self.depth += 1;
        switch (kind) {
            0 => {}, // document
            1 => { // block quote
                try self.w.boundary();
                self.w.prefix = try self.containerPrefix("> ");
                try self.w.setStyle(.{ .tone = .quote });
            },
            2, 3 => { // unordered / ordered list
                try self.w.boundary();
                if (kind == 3) frame.next = detail(md.Ol, raw).start;
            },
            4 => { // list item; continuation lines use hanging indentation
                try self.w.boundary();
                var marker: []const u8 = "- ";
                var i = self.depth - 1;
                while (i > 0) {
                    i -= 1;
                    if (self.blocks[i].kind == 3) {
                        marker = try std.fmt.allocPrint(self.w.a, "{d}. ", .{self.blocks[i].next});
                        self.blocks[i].next += 1;
                        break;
                    }
                    if (self.blocks[i].kind == 2) break;
                }
                const item = detail(md.Li, raw);
                if (item.task != 0) marker = try std.fmt.allocPrint(self.w.a, "{s}[{c}] ", .{ marker, if (item.mark == ' ') @as(u8, ' ') else @as(u8, 'x') });
                self.w.prefix = try self.containerPrefix(marker);
                const padding = try self.w.a.alloc(u8, text.width(marker));
                @memset(padding, ' ');
                self.w.continuation = try std.fmt.allocPrint(self.w.a, "{s}{s}", .{ frame.prefix, padding });
            },
            5 => { // thematic break
                try self.w.boundary();
                try self.w.setStyle(.{ .tone = .rule });
                for (0..self.w.columns -| @min(text.width(self.w.prefix), self.w.columns - 1)) |_| try self.w.emit("-");
            },
            6 => {
                try self.w.boundary();
                try self.w.setStyle(.{ .tone = .heading, .bold = true, .underline = detail(md.H, raw).level == 1 });
            },
            7 => {
                try self.w.boundary();
                try self.w.setStyle(.{ .tone = .code });
            },
            8 => {}, // HTML is disabled in the parser; literal text if encountered
            9 => {}, // paragraphs preserve soft line breaks in a terminal
            10 => {
                try self.w.boundary();
                if (!self.table_fragment) if (self.table_resume) |resume_table| {
                    if (resume_table.header_begin != self.pending_table_begin or resume_table.body_begin != self.pending_table_body) {
                        self.deferred_table_resume = resume_table;
                        self.table_resume = null;
                    }
                };
                const columns = detail(md.Table, raw).columns;
                if (columns == 0 or columns > 32 or self.table != null) return error.MarkdownTableLimit;
                const available = self.w.columns -| @min(text.width(self.w.prefix), self.w.columns - 1);
                // Narrow tables degrade to stacked cells rather than losing data.
                const stacked = available < 6 * columns + 1;
                const width = if (stacked) available else (available - 3 * columns - 1) / columns;
                self.table = .{ .main = self.w, .columns = columns, .cell_width = @max(1, width), .stacked = stacked, .containers = self.pending_containers, .header_source = self.pending_table_header, .header_begin = self.pending_table_begin, .body_begin = self.pending_table_body, .header_complete = self.pending_table_complete };
                // The snapshot belongs to this exact table; it must never leak
                // into a later table of the same window.
                self.pending_containers = &.{};
                self.pending_table_header = "";
                self.pending_table_begin = 0;
                self.pending_table_body = 0;
                self.pending_table_complete = false;
                if (self.collect != null and self.streaming_tables and !stacked) {
                    const owned = try self.w.a.create(stream_table.Table);
                    errdefer self.w.a.destroy(owned);
                    const widths: [32]usize = @splat(@max(1, width));
                    const alignments: [32]stream_table.Alignment = @splat(.left);
                    owned.* = try stream_table.Table.init(self.w.a, widths[0..columns], alignments[0..columns], .{ .bytes = 256 * 1024 });
                    if (self.table_resume) |resume_table| {
                        owned.resumePresentation(resume_table.alignments[0..columns], .{
                            .top_done = resume_table.top_done,
                            .header_done = resume_table.header_done,
                            .separator_pending = resume_table.separator_pending,
                            .finish_requested = resume_table.finish_requested,
                            .bottom_done = resume_table.bottom_done,
                        });
                    }
                    self.table.?.stream = owned;
                }
            },
            11, 12 => {}, // table head/body
            13 => {
                if (self.table.?.stream == null and self.table.?.rows.items.len >= 2048) return error.MarkdownTableLimit;
                self.table.?.cells = .empty;
                self.table.?.cell_index = 0;
                self.table.?.header = false;
            },
            14, 15 => {
                const table = &self.table.?;
                table.header = kind == 14;
                table.alignment = detail(md.Td, raw).alignment;
                self.cell_src_start = std.math.maxInt(usize);
                self.cell_src_end = 0;
                self.w = .{ .a = table.main.a, .columns = table.cell_width, .ansi = table.main.ansi, .base = table.main.base, .style = if (kind == 14) .{ .tone = .table_header, .bold = true } else .{}, .budget = table.main.budget };
                if (table.stream) |stream| {
                    if (!stream.rowStarted()) {
                        const same_row = if (self.table_resume) |resume_table|
                            resume_table.row_begin != null and resume_table.row_begin.? == table.checkpoint.row_begin
                        else
                            false;
                        if (same_row and !self.table_fragment) {
                            var skip: [32]usize = @splat(0);
                            for (self.table_resume.?.delivered, &skip) |offset, *value| value.* = offset -| self.source_base;
                            stream.restoreDelivered(skip[0..table.columns]);
                        }
                        try stream.beginRow(kind == 14);
                        if (same_row) stream.setRowHadOutput(self.table_resume.?.row_had_output);
                        for (0..table.cell_index) |previous| try stream.endCell(previous);
                    }
                    stream.setAlignment(table.cell_index, switch (table.alignment) {
                        2 => .center,
                        3 => .right,
                        else => .left,
                    });
                    self.w.sink = .{ .context = self, .onRow = cellRowSink };
                }
            },
            else => return error.InvalidMarkdownBlock,
        }
        // Leaf context is captured AFTER the switch so it reflects the same
        // prefix/style the rows will use (heading/code/list indentation).
        if (kind == 5 or kind == 6 or kind == 7 or kind == 8 or kind == 9 or kind == 10) self.syncLeafCtx(kind, raw);
        self.updateAfter();
    }

    fn leaveBlock(self: *Renderer, kind: c_int) !void {
        try self.flushText();
        if (kind == 7) if (self.pending_code_close) |candidate| {
            const input = self.window.?;
            try self.w.emitSourced(input[candidate.begin..candidate.end], candidate.begin -| self.context_bytes, candidate.end -| self.context_bytes, true);
            self.pending_code_close = null;
        };
        try self.step(1);
        if (self.depth == 0) return error.InvalidMarkdownBlock;
        self.depth -= 1;
        const frame = self.blocks[self.depth];
        if (frame.kind != kind) return error.InvalidMarkdownBlock;
        switch (kind) {
            0 => {
                try self.w.boundary();
                // Static rendering preserves the empty-document line. Window
                // rendering must not invent a row for metadata-only input.
                if (self.collect == null and self.w.lines.items.len == 0) try self.w.finish();
            },
            14, 15 => {
                try self.w.boundary();
                const table = &self.table.?;
                if (table.stream) |stream| {
                    // An empty cell is metadata, not a physical cell line.
                    // The compositor emits one row only when the entire logical
                    // row is complete and has never produced data.
                    if (table.cell_complete) try stream.endCell(table.cell_index);
                    table.cell_index += 1;
                    if (self.cell_src_end > self.cell_src_start) {
                        table.last_source_end = @max(table.last_source_end, self.cell_src_end);
                        if (kind == 14) {
                            table.header_start = @min(table.header_start, self.cell_src_start);
                            table.header_end = @max(table.header_end, self.cell_src_end);
                        }
                    }
                } else {
                    if (self.w.lines.items.len == 0) try self.w.finish();
                    try table.cells.append(self.w.a, .{ .lines = try self.w.lines.toOwnedSlice(self.w.a), .alignment = table.alignment, .origin_start = self.cell_src_start, .origin_end = self.cell_src_end });
                }
                self.w = table.main;
            },
            13 => {
                if (self.table.?.stream) |stream| {
                    if (self.table.?.row_complete) try stream.endRow();
                    try self.drainTableRows(64);
                    if (self.table_drain_full) return error.MarkdownDisplayYield;
                } else {
                    const table = &self.table.?;
                    try table.rows.append(self.w.a, .{ .cells = try table.cells.toOwnedSlice(self.w.a), .header = table.header });
                }
            },
            10 => {
                if (self.leaves.items.len != 0) {
                    var start: usize = std.math.maxInt(usize);
                    var end: usize = 0;
                    if (self.table) |table| {
                        if (table.stream != null) {
                            start = table.header_start;
                            end = table.header_end;
                        }
                        for (table.rows.items) |row| {
                            if (!row.header) continue;
                            for (row.cells) |cell| {
                                if (cell.origin_end <= cell.origin_start) continue;
                                start = @min(start, cell.origin_start);
                                end = @max(end, cell.origin_end);
                            }
                        }
                    }
                    if (end > start) {
                        self.leaves.items[self.leaves.items.len - 1].ctx.table_head_start = start;
                        self.leaves.items[self.leaves.items.len - 1].ctx.table_head_end = end;
                    }
                }
                try self.flushTable();
                self.table_resume = self.deferred_table_resume;
                self.deferred_table_resume = null;
                self.table_fragment = false;
                if (self.leaves.items.len != 0) self.leaves.items[self.leaves.items.len - 1].ctx.table_head_rows = self.table_head_rows;
            },
            11, 12 => {},
            4 => {
                if (self.w.continuation != null and !self.w.hasContent()) try self.w.emit(" ");
                try self.w.boundary();
            },
            else => try self.w.boundary(),
        }
        if (kind == 1 or kind == 2 or kind == 3 or kind == 4) {
            self.w.prefix = frame.prefix;
            self.w.continuation = frame.continuation;
        }
        try self.w.setStyle(frame.style);
        if (kind == 5 or kind == 6 or kind == 7 or kind == 8 or kind == 9 or kind == 10) {
            const open_fence = kind == 7 and !self.final and self.leaves.items.len != 0 and
                !self.leaves.items[self.leaves.items.len - 1].ctx.indented and
                self.leaves.items[self.leaves.items.len - 1].ctx.closing_end == null;
            self.leaf_open = open_fence;
        }
        self.updateAfter();
    }

    fn cellRowSink(context: *anyopaque, row: []const u8, _: usize, _: []const u8) output.Error!void {
        const self = selfFrom(context);
        const table = &self.table.?;
        const stream = table.stream.?;
        // A compositor stage is in flight after it has ceded all of its input;
        // release that staged view before accepting more lines.
        if (stream.hasInflight()) self.drainTableRows(64) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.MarkdownRenderLimit;
        var segments: [2]stream_table.Segment = undefined;
        var segment_count: usize = 0;
        if (!self.w.origin_synthetic) {
            segments[segment_count] = .{ .start = self.w.origin_start, .end = self.w.origin_end, .atomic = true };
            segment_count += 1;
        }
        if (self.w.generated_end > self.w.generated_start) {
            segments[segment_count] = .{ .start = self.w.generated_start, .end = self.w.generated_end, .generated = true };
            segment_count += 1;
        }
        const source = segments[0..segment_count];
        const line: stream_table.CellLine = .{ .text = row, .display_width = output.displayWidth(row), .source_segments = source };
        stream.feedCellLine(table.cell_index, line) catch |err| switch (err) {
            error.NeedDrain => {
                self.drainTableRows(64) catch |failure| return if (failure == error.OutOfMemory) error.OutOfMemory else error.MarkdownRenderLimit;
                // The writer still owns this unaccepted row. Abort native parsing
                // successfully and rebuild it from the returned checkpoint.
                self.table_yield_pending = true;
                return error.MarkdownCellOverflow;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MarkdownRenderLimit,
        };
        // The compositor copied the row; sink success takes Writer ownership.
        self.w.a.free(row);
    }

    /// Materialize a bounded scratch stage, including an open logical row when
    /// the input queue is full. Scratch commit is not a terminal ACK: each
    /// copied physical row carries its own checkpoint and occurrences, and the
    /// caller must retain undisplayed source until a fresh frame is ACKed.
    fn drainTableRows(self: *Renderer, budget: usize) !void {
        const stream = self.table.?.stream.?;
        const rows = self.collect.?;
        const capacity = @min(budget, self.row_limit -| rows.items.len);
        if (capacity == 0) {
            self.table_drain_full = true;
            return;
        }
        const stage = try stream.stage(capacity);
        defer stream.abort();
        self.table_drain_full = stage.rows.len == capacity;
        if (stage.rows.len == 0) return;
        for (stage.rows) |row| {
            if (rows.items.len >= self.row_limit) return error.MarkdownRenderLimit;
            var start: usize = std.math.maxInt(usize);
            var end: usize = 0;
            var progress = self.table.?.checkpoint;
            progress.row_begin = self.table.?.row_begin;
            progress.row_end = self.table.?.row_end;
            progress.active_column = self.table.?.cell_index;
            progress.cell_complete = self.table.?.cell_complete;
            progress.row_complete = self.table.?.row_complete;
            for (row.output_bytes, 0..) |bytes, i| progress.output_bytes[i] += bytes;
            for (row.sources) |source| {
                start = @min(start, source.segment.start);
                end = @max(end, source.segment.end);
                if (!source.segment.generated)
                    progress.delivered[source.column] = @max(progress.delivered[source.column], self.source_base + source.segment.end);
            }
            const main = &self.table.?.main;
            const rendered = try std.fmt.allocPrint(main.a, "{s}{s}{s}", .{ main.prefix, row.text, if (main.ansi) @import("theme.zig").reset else "" });
            errdefer main.a.free(rendered);
            const occurrences: []const TableOccurrence = if (row.sources.len == 0) &.{} else try main.a.dupe(TableOccurrence, row.sources);
            errdefer if (occurrences.len != 0) main.a.free(occurrences);
            try rows.append(main.a, .{
                .text = rendered,
                .start = start,
                .end = end,
                .synthetic = start == std.math.maxInt(usize),
                .leaf = self.leaves.items.len - 1,
                .output_start = main.pos,
                .output_window = self.source_base,
                .table = if (row.sources.len != 0) progress else null,
                .table_kind = row.kind,
                .table_checkpoint = progress,
                .table_occurrences = occurrences,
            });
            main.pos += row.text.len;
            self.table.?.checkpoint = progress;
            self.table_frontier = progress;
        }
        const occurrences = try stream.commit(stage.token);
        self.w.a.free(occurrences);
        // Per-column settlement: the cell is ended and every wrapped line it
        // produced is materialized. Only then may the caller retire trailing
        // cell syntax that no displayed text maps to.
        var settled: u32 = 0;
        for (0..self.table.?.columns) |column| {
            if (!stream.cellEnded(column)) continue;
            if ((stream.pendingCount(column) catch 0) != 0) continue;
            settled |= @as(u32, 1) << @intCast(column);
        }
        if (settled != 0) {
            // Persist on the logical row's checkpoint so later stages of the
            // same row inherit it, and publish it on the last physical row of
            // this stage (a border row when the cell produced no new line).
            self.table.?.checkpoint.settled |= settled;
            var index = rows.items.len;
            while (index > 0) {
                index -= 1;
                const candidate = &rows.items[index];
                if (candidate.table_checkpoint == null) continue;
                candidate.table_checkpoint.?.settled |= settled;
                break;
            }
        }
        if (stream.headerDone() and self.table_head_rows == 0 and self.leaves.items.len != 0)
            self.table_head_rows = rows.items.len - self.leaves.items[self.leaves.items.len - 1].row_start;
    }

    /// Native table closure plus a complete following physical line proves this
    /// is a block boundary, rather than temporary transport exhaustion.
    fn tableClosedInWindow(self: *const Renderer) bool {
        const window = self.window orelse return false;
        const table = self.table orelse return false;
        // The fragment grammar consumes rows until it meets a complete closing
        // physical line (blank/container-only or a real dedent); every complete
        // line after the last consumed row is that boundary. With no consumed
        // row at all, the very first line must have been such a boundary, which
        // is only decidable once it is complete.
        var next: usize = 0;
        if (table.row_end != 0) {
            if (table.row_end < self.source_base) return false;
            const offset = std.math.add(usize, table.row_end - self.source_base, self.context_bytes) catch return false;
            if (offset >= window.len) return false;
            const row_lf = std.mem.indexOfScalarPos(u8, window, offset, '\n') orelse return false;
            next = row_lf + 1;
        }
        if (table.header) {
            const delimiter_lf = std.mem.indexOfScalarPos(u8, window, next, '\n') orelse return false;
            next = delimiter_lf + 1;
        }
        return std.mem.indexOfScalarPos(u8, window, next, '\n') != null;
    }

    fn flushTable(self: *Renderer) !void {
        if (self.table.?.stream) |stream| {
            // Native closure at input exhaustion alone is not transport EOF.
            // A complete following physical line also proves a block boundary.
            if (self.final or self.tableClosedInWindow()) {
                if (!stream.rowStarted() or stream.rowEnded()) try stream.finish();
                try self.drainTableRows(64);
                if (self.table_drain_full) return error.MarkdownDisplayYield;
            }
            self.w = self.table.?.main;
            stream.deinit();
            self.w.a.destroy(stream);
            self.table = null;
            return;
        }
        const table = self.table.?;
        self.w = table.main;
        self.table = null;
        var widths: [32]usize = @splat(1);
        for (table.rows.items) |row| for (row.cells, 0..) |cell, col| {
            for (cell.lines) |line| widths[col] = @max(widths[col], output.displayWidth(line));
        };
        var total: usize = 3 * table.columns + 1;
        for (widths[0..table.columns]) |width| total += width;
        const available = self.w.columns -| @min(text.width(self.w.prefix), self.w.columns - 1);
        if (table.stacked or total > available) {
            for (table.rows.items) |row| for (row.cells) |cell| {
                for (cell.lines) |line| {
                    try self.w.emitStyled(line);
                    try self.w.finish();
                }
            };
            return;
        }
        if (table.rows.items.len == 0) return;
        try self.tableRule(widths[0..table.columns], .top, false);
        var emitted: usize = if (table.stacked) 0 else 1;
        for (table.rows.items, 0..) |row, row_index| {
            try self.w.setStyle(.{ .tone = .border });
            var height: usize = 1;
            for (row.cells) |cell| height = @max(height, cell.lines.len);
            for (0..height) |line_index| {
                try self.w.emit("│ ");
                for (row.cells, 0..) |cell, col| {
                    const line = if (line_index < cell.lines.len) cell.lines[line_index] else "";
                    if (cell.origin_end > cell.origin_start) self.w.markSource(cell.origin_start, cell.origin_end);
                    const padding = widths[col] - output.displayWidth(line);
                    const before = if (cell.alignment == 3) padding else if (cell.alignment == 2) padding / 2 else 0;
                    for (0..before) |_| try self.w.emit(" ");
                    try self.w.emitStyled(line);
                    for (0..padding - before) |_| try self.w.emit(" ");
                    try self.w.emit(" │");
                    if (col + 1 < row.cells.len) try self.w.emit(" ");
                }
                try self.w.finish();
                emitted += 1;
            }
            // Separate logical rows, not every physical line of a wrapped cell.
            try self.tableRule(widths[0..table.columns], if (row_index + 1 == table.rows.items.len) .bottom else .middle, row.header);
            if (!table.stacked) emitted += 1;
            if (row.header) self.table_head_rows = emitted;
        }
    }

    fn tableRule(self: *Renderer, widths: []const usize, edge: TableEdge, bold: bool) !void {
        try self.w.setStyle(.{ .tone = .border, .bold = bold });
        try self.w.emit(switch (edge) {
            .top => "┌",
            .middle => "├",
            .bottom => "└",
        });
        for (widths, 0..) |width, col| {
            for (0..width + 2) |_| try self.w.emit("─");
            try self.w.emit(if (col + 1 < widths.len) switch (edge) {
                .top => "┬",
                .middle => "┼",
                .bottom => "┴",
            } else switch (edge) {
                .top => "┐",
                .middle => "┤",
                .bottom => "┘",
            });
        }
        try self.w.finish();
    }

    fn spanAttributeWork(self: *Renderer, kind: c_int, raw: ?*anyopaque) !void {
        // MD4C builds attributes before both span callbacks, even titles which
        // we never display. Charge them too: references can repeat a huge hidden
        // title without generating many terminal bytes. One preparation precedes
        // the check, but stopping here bounds subsequent native attribute work.
        if (kind == 2) {
            const link = detail(md.Link, raw);
            try self.step(@as(usize, link.href.size) + link.title.size);
        } else if (kind == 3) {
            const image = detail(md.Image, raw);
            try self.step(@as(usize, image.src.size) + image.title.size);
        }
    }

    fn enterSpan(self: *Renderer, kind: c_int, raw: ?*anyopaque) !void {
        const native_span = self.pending_span;
        self.pending_span = null;
        const before = self.w.style;
        try self.flushText();
        try self.step(1);
        try self.spanAttributeWork(kind, raw);
        if (self.span_depth == self.spans.len) return error.MarkdownDepthLimit;
        self.spans[self.span_depth] = self.w.style;
        self.span_records[self.span_depth] = null;
        self.span_depth += 1;
        var style = self.w.style;
        switch (kind) {
            0 => style.italic = true,
            1 => {
                style.bold = true;
                if (style.tone == .normal) style.tone = .strong;
            },
            2 => style.tone = .link,
            3 => {
                style.tone = .muted;
                try self.w.emit("[image: ");
            },
            4, 6, 7 => style.tone = .inline_code,
            5 => style.strike = true,
            8 => style.tone = .link,
            9 => style.underline = true,
            else => return error.InvalidMarkdownSpan,
        }
        try self.w.setStyle(style);
        if (native_span) |span| {
            if (span.kind != kind) return error.InvalidMarkdownSpan;
            const opener = try self.nativeOffset(span.opener_begin);
            if (opener) |opener_begin| {
                try self.confirmed.append(self.w.a, .{
                    .kind = kind,
                    .opener_begin = opener_begin,
                    .opener_end = (try self.nativeOffset(span.opener_end)) orelse return error.InvalidMarkdownSpan,
                    .closer_begin = (try self.nativeOffset(span.closer_begin)) orelse return error.InvalidMarkdownSpan,
                    .closer_end = (try self.nativeOffset(span.closer_end)) orelse return error.InvalidMarkdownSpan,
                    .before = before,
                    .inside = style,
                    .suffix = if (kind == 2 or kind == 3) try self.captureSuffix(kind, raw) else if (kind == 6) "$" else if (kind == 7) "$$" else "",
                    .suffix_style_split = if (kind == 3) 1 else 0,
                    .output_window = if (self.table == null) self.source_base else std.math.maxInt(usize),
                    .column = if (self.table) |table| table.cell_index else std.math.maxInt(usize),
                    .code_first = self.code_pieces.items.len,
                });
                self.span_records[self.span_depth - 1] = self.confirmed.items.len - 1;
                if (kind == 4 or kind == 6 or kind == 7) self.code_owner = self.confirmed.items.len - 1;
            }
        }
        // MD4C consumes math delimiters; the terminal fallback is literal text,
        // not a TeX engine, so keep both delimiters and the raw formula visible.
        if (kind == 6 or kind == 7) try self.w.emit(if (kind == 6) "$" else "$$");
    }

    fn leaveSpan(self: *Renderer, kind: c_int, raw: ?*anyopaque) !void {
        if (kind == 4 or kind == 6 or kind == 7) if (self.code_owner) |owner| {
            const span = &self.confirmed.items[owner];
            self.resolveCodeGap(span.code_first, span.closer_begin);
            span.code_count = self.code_pieces.items.len - span.code_first;
            self.code_owner = null;
        };
        try self.flushText();
        try self.step(1);
        try self.spanAttributeWork(kind, raw);
        if (self.span_depth == 0) return error.InvalidMarkdownSpan;
        const record = self.span_records[self.span_depth - 1];
        if (record) |index| self.confirmed.items[index].suffix_start = self.w.pos;
        if ((kind == 2 or kind == 3 or kind == 6 or kind == 7) and record != null) {
            try self.closeKnownSpan(record.?);
        } else {
            if (kind == 6 or kind == 7) try self.w.emit(if (kind == 6) "$" else "$$");
            if (kind == 3) try self.w.emit("]");
            if ((kind == 2 and detail(md.Link, raw).autolink == 0) or kind == 3) {
                const target = if (kind == 2) detail(md.Link, raw).href else detail(md.Image, raw).src;
                if (target.size != 0) {
                    try self.w.setStyle(.{ .tone = .link_url });
                    try self.w.emit(" (");
                    try self.attribute(target);
                    try self.w.emit(")");
                }
            }
        }
        if (record) |index| self.confirmed.items[index].suffix_end = self.w.pos;
        self.span_depth -= 1;
        try self.w.setStyle(self.spans[self.span_depth]);
    }

    fn appendAttributeCodepoint(a: Allocator, out: *std.ArrayList(u8), value: u32) !void {
        const cp: u21 = if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) 0xfffd else @intCast(value);
        var buffer: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buffer);
        const safe = try text.sanitize(a, buffer[0..n], 12);
        defer a.free(safe);
        try out.appendSlice(a, safe);
    }

    fn captureSuffix(self: *Renderer, kind: c_int, raw: ?*anyopaque) ![]const u8 {
        const a = self.semantic_allocator orelse self.w.a;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        if (kind == 2 and detail(md.Link, raw).autolink != 0) return out.toOwnedSlice(a);
        if (kind == 3) try out.append(a, ']');
        const value = if (kind == 2) detail(md.Link, raw).href else detail(md.Image, raw).src;
        if (value.size != 0) {
            try out.appendSlice(a, " (");
            var i: usize = 0;
            const bytes = value.text.?[0..value.size];
            while (value.offsets.?[i] < value.size) : (i += 1) {
                const part = bytes[value.offsets.?[i]..value.offsets.?[i + 1]];
                switch (value.types.?[i]) {
                    1 => try appendAttributeCodepoint(a, &out, 0xfffd),
                    4 => {
                        if (part.len > 3 and part[1] == '#') {
                            const hex = part[2] == 'x' or part[2] == 'X';
                            const cp = std.fmt.parseInt(u32, part[if (hex) @as(usize, 3) else 2 .. part.len - 1], if (hex) 16 else 10) catch 0xfffd;
                            try appendAttributeCodepoint(a, &out, cp);
                        } else if (md.entity_lookup(part.ptr, part.len)) |entity_value| {
                            try appendAttributeCodepoint(a, &out, entity_value.codepoints[0]);
                            if (entity_value.codepoints[1] != 0) try appendAttributeCodepoint(a, &out, entity_value.codepoints[1]);
                        } else try out.appendSlice(a, part);
                    },
                    else => try out.appendSlice(a, part),
                }
            }
            try out.append(a, ')');
        }
        return out.toOwnedSlice(a);
    }

    fn codepoint(self: *Renderer, value: u32, buffered: bool) !void {
        const cp: u21 = if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) 0xfffd else @intCast(value);
        var buffer: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buffer);
        // Entity decoding must not reintroduce ESC, bidi or other controls.
        const safe = try text.sanitize(self.w.a, buffer[0..n], 12);
        if (!buffered) {
            try self.w.emit(safe);
            return;
        }
        if (self.pending_entity_valid and self.window != null) {
            try self.bufferSourced(safe, self.pending_entity_start, self.pending_entity_end, false);
        } else try self.bufferText(safe);
    }

    fn entity(self: *Renderer, s: []const u8, buffered: bool) !void {
        const prior = .{ self.pending_entity_start, self.pending_entity_end, self.pending_entity_valid };
        defer {
            self.pending_entity_start = prior[0];
            self.pending_entity_end = prior[1];
            self.pending_entity_valid = prior[2];
        }
        if (self.sourceOffset(s)) |off| {
            self.pending_entity_start = off;
            self.pending_entity_end = off + s.len;
            self.pending_entity_valid = true;
            self.noteCell(off, off + s.len);
        } else self.pending_entity_valid = false;
        if (s.len > 3 and s[1] == '#') {
            const hex = s[2] == 'x' or s[2] == 'X';
            const n = std.fmt.parseInt(u32, s[if (hex) @as(usize, 3) else 2 .. s.len - 1], if (hex) 16 else 10) catch 0xfffd;
            try self.codepoint(n, buffered);
        } else if (md.entity_lookup(s.ptr, s.len)) |value| {
            try self.codepoint(value.codepoints[0], buffered);
            if (value.codepoints[1] != 0) try self.codepoint(value.codepoints[1], buffered);
        } else if (buffered) try self.bufferText(s) else try self.w.emit(s);
    }

    fn attribute(self: *Renderer, value: md.Attribute) !void {
        if (value.size == 0) return;
        const s = value.text.?[0..value.size];
        var i: usize = 0;
        while (value.offsets.?[i] < value.size) : (i += 1) {
            const part = s[value.offsets.?[i]..value.offsets.?[i + 1]];
            if (value.types.?[i] == 4) try self.entity(part, false) else if (value.types.?[i] == 1) try self.w.emit("�") else try self.w.emit(part);
        }
    }

    fn resolveCodeGap(self: *Renderer, first: usize, end: usize) void {
        var i = self.code_pieces.items.len;
        while (i > first) {
            i -= 1;
            const piece = &self.code_pieces.items[i];
            if (piece.exact or piece.end != piece.begin) break;
            piece.end = end;
            if (end > piece.begin and self.pending_text.items.len != 0 and !self.pending_src_valid) {
                self.pending_src_start = self.context_bytes + piece.begin - self.source_base;
                self.pending_src_end = self.context_bytes + end - self.source_base;
                self.pending_src_exact = false;
                self.pending_src_valid = true;
            }
        }
    }

    fn captureCode(self: *Renderer, s: []const u8) !void {
        const owner = self.code_owner orelse return;
        if (s.len == 0) return;
        const span = self.confirmed.items[owner];
        if (self.sourceOffset(s)) |off| {
            if (off < self.context_bytes) return;
            const begin = self.source_base + off - self.context_bytes;
            self.resolveCodeGap(span.code_first, begin);
            try self.code_pieces.append(self.w.a, .{ .begin = begin, .end = begin + s.len, .text = s, .exact = true });
        } else {
            const begin = if (self.code_pieces.items.len > span.code_first)
                self.code_pieces.items[self.code_pieces.items.len - 1].end
            else
                span.opener_end;
            try self.code_pieces.append(self.w.a, .{ .begin = begin, .end = begin, .text = s, .exact = false });
        }
    }

    fn content(self: *Renderer, kind: c_int, s: []const u8) !void {
        try self.captureCode(s);
        try self.step(1);
        switch (kind) {
            1 => try self.bufferText("\u{fffd}"),
            2, 3 => {
                try self.flushText();
                try self.w.finish();
            },
            4 => try self.entity(s, true),
            else => {
                if (self.window != null) {
                    if (self.sourceOffset(s)) |off| {
                        try self.bufferSourced(s, off, off + s.len, true);
                        self.noteCell(off, off + s.len);
                    } else try self.bufferText(s);
                } else try self.bufferText(s);
            },
        }
    }

    fn selfFrom(raw: ?*anyopaque) *Renderer {
        return @ptrCast(@alignCast(raw.?));
    }
    // Keep native -1 exclusively for parser OOM; callbacks carry their Zig
    // error separately and never allow later callbacks to overwrite it.
    const callback_abort: c_int = -2;
    fn failed(self: *Renderer, err: anyerror) c_int {
        if (err == error.MarkdownDisplayYield or (err == error.MarkdownCellOverflow and self.table_yield_pending)) {
            self.yielded = true;
            return 2;
        }
        if (self.failure == null) self.failure = err;
        return callback_abort;
    }
    fn nativeOffset(self: *Renderer, offset: usize) !?usize {
        const win = self.window orelse return error.InvalidMarkdownSpan;
        const relative = std.math.add(usize, self.parser_offset, offset) catch return error.InvalidMarkdownSpan;
        if (relative > win.len) return error.InvalidMarkdownSpan;
        if (relative < self.context_bytes) return null;
        return std.math.add(usize, self.source_base, relative - self.context_bytes) catch error.InvalidMarkdownSpan;
    }

    fn cellContentCb(begin: c_uint, end: c_uint, handled: *c_int, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        handled.* = 0;
        if (self.failure != null) return callback_abort;
        var seeds: [128]ConfirmedSpan = undefined;
        var count: usize = 0;
        const absolute = self.source_base + @as(usize, begin);
        for (self.resume_spans) |span| {
            if (span.opener_end <= absolute and span.closer_end > absolute and span.closer_begin >= absolute) {
                if (count == seeds.len) return self.failed(error.MarkdownDepthLimit);
                seeds[count] = span;
                count += 1;
            }
        }
        if (count == 0) return 0;
        const offset = self.parser_offset;
        defer self.parser_offset = offset;
        self.noteCell(begin, end);
        self.parseSeededContent(self.window.?, begin, end, seeds[0..count]) catch |err| return self.failed(err);
        handled.* = 1;
        return 0;
    }

    fn cellSourceCb(cell: *const md.CellSource, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.captureCell(cell.*) catch |err| return self.failed(err);
        return 0;
    }

    fn isBorrowedHeaderCell(self: *Renderer, cell: md.CellSource) bool {
        const table = self.table orelse return false;
        const prior = self.table_resume orelse return false;
        if (cell.header == 0 or self.parser_offset != 0 or !table.header_complete or !prior.header_complete or
            table.header_begin != prior.header_begin or table.body_begin != prior.body_begin or
            !std.mem.eql(u8, table.header_source, prior.header) or
            table.header_begin >= self.source_base or table.body_begin <= self.source_base)
            return false;
        const borrowed = self.source_base - table.header_begin;
        return borrowed <= self.context_bytes and cell.row_begin >= self.context_bytes - borrowed and cell.row_begin < self.context_bytes;
    }

    fn captureCell(self: *Renderer, cell: md.CellSource) !void {
        if (self.table) |*table| {
            table.cell_complete = cell.cell_complete != 0;
            table.row_complete = cell.row_complete != 0;
        }
        if ((cell.present != 0 and cell.present != 1) or
            (cell.cell_complete != 0 and cell.cell_complete != 1) or
            (cell.row_complete != 0 and cell.row_complete != 1) or
            (cell.header != 0 and cell.header != 1) or cell.column >= 32 or
            cell.alignment < 0 or cell.alignment > 3 or cell.row_begin > cell.row_end)
            return error.InvalidMarkdownSpan;
        if (self.table_fragment) {
            if (self.table_resume) |resume_table| {
                if (cell.column >= resume_table.columns) return error.InvalidMarkdownSpan;
            }
        }
        const present = cell.present == 1;
        if (present) {
            if (cell.raw_begin < cell.row_begin or cell.raw_begin > cell.begin or cell.begin > cell.end or cell.end > cell.raw_end or
                cell.raw_end > cell.next_begin or (cell.cell_complete == 0 and cell.next_begin != cell.raw_end))
                return error.InvalidMarkdownSpan;
        } else if (cell.begin != 0 or cell.end != 0 or cell.raw_begin != 0 or cell.raw_end != 0 or cell.next_begin != 0) return error.InvalidMarkdownSpan;
        const begin = (try self.nativeOffset(cell.begin)) orelse return;
        const end = (try self.nativeOffset(cell.end)) orelse return;
        const raw_begin = if (present) (try self.nativeOffset(cell.raw_begin)) orelse blk: {
            if (!self.isBorrowedHeaderCell(cell)) return;
            break :blk self.source_base;
        } else 0;
        const raw_end = if (present) (try self.nativeOffset(cell.raw_end)) orelse return else 0;
        const next_begin = if (present) (try self.nativeOffset(cell.next_begin)) orelse return else 0;
        var row_begin = (try self.nativeOffset(cell.row_begin)) orelse blk: {
            if (!self.isBorrowedHeaderCell(cell)) return;
            const distance = self.context_bytes - cell.row_begin;
            if (distance > self.source_base) return error.InvalidMarkdownSpan;
            break :blk self.source_base - distance;
        };
        if (self.table_resume) |resume_table| {
            if (cell.row_begin == 0 and resume_table.partial_cell and resume_table.row_begin != null)
                row_begin = resume_table.row_begin.?;
        }
        const row_end = (try self.nativeOffset(cell.row_end)) orelse return;
        if (row_end < row_begin) return error.InvalidMarkdownSpan;
        try self.cells.append(self.w.a, .{ .column = cell.column, .begin = begin, .end = end, .row_begin = row_begin, .row_end = row_end, .raw_begin = raw_begin, .raw_end = raw_end, .next_begin = next_begin, .alignment = cell.alignment, .cell_complete = cell.cell_complete != 0, .row_complete = cell.row_complete != 0, .header = cell.header != 0, .present = present });
        if (self.table) |*table| {
            table.cell_index = cell.column;
            if (table.checkpoint.row_begin != row_begin) {
                table.checkpoint = .{ .row_begin = row_begin, .row_end = row_end };
                if (self.table_resume) |prior_table| {
                    if (prior_table.row_begin != null and prior_table.row_begin.? == row_begin) {
                        table.checkpoint.delivered = prior_table.delivered;
                        table.checkpoint.output_bytes = prior_table.output_bytes;
                    }
                }
            }
            table.row_begin = row_begin;
            table.row_end = row_end;
            if (cell.header != 0 and end > begin) {
                table.header_start = @min(table.header_start, begin - self.source_base);
                table.header_end = @max(table.header_end, end - self.source_base);
            }
        }
        if (self.leaves.items.len != 0 and cell.column < 32)
            self.leaves.items[self.leaves.items.len - 1].ctx.table_align[cell.column] = cell.alignment;
    }

    fn fenceSourceCb(fence: *const md.FenceSource, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.pending_fence = fence.*;
        return 0;
    }

    fn spanSourceCb(span: *const md.InlineSpan, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.pending_span = switch (span.kind) {
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9 => span.*,
            else => null,
        };
        return 0;
    }

    /// Copy one raw (NO_ESCAPES) native attribute into the window arena. Only
    /// text/size are read by store prepare; types/offsets stay null.
    fn copyAttribute(self: *Renderer, attr: md.Attribute) !md.Attribute {
        if (attr.size == 0) return .{ .text = null, .size = 0, .types = null, .offsets = null };
        const source = attr.text orelse return error.InvalidMarkdownBlock;
        const copy = try self.w.a.dupe(u8, source[0..attr.size]);
        return .{ .text = copy.ptr, .size = @intCast(copy.len), .types = null, .offsets = null };
    }

    fn freeAttribute(a: Allocator, attr: md.Attribute) void {
        if (attr.text) |ptr| a.free(ptr[0..attr.size]);
    }

    fn freeDefinition(a: Allocator, definition: Definition) void {
        freeAttribute(a, definition.event.label);
        freeAttribute(a, definition.event.destination);
        freeAttribute(a, definition.event.title);
    }

    fn captureDefinition(self: *Renderer, raw: md.ReferenceDefinition) !void {
        // Synthetic context bytes are not real source definitions.
        const begin = (try self.nativeOffset(raw.begin)) orelse return;
        const end = (try self.nativeOffset(raw.end)) orelse return;
        if (end <= begin) return;
        const label = try self.copyAttribute(raw.label);
        errdefer freeAttribute(self.w.a, label);
        const destination = try self.copyAttribute(raw.destination);
        errdefer freeAttribute(self.w.a, destination);
        const title = try self.copyAttribute(raw.title);
        errdefer freeAttribute(self.w.a, title);
        const event = md.ReferenceDefinition{
            .begin = raw.begin,
            .end = raw.end,
            .label = label,
            .destination = destination,
            .title = title,
        };
        try self.definitions.append(self.w.a, .{ .begin = begin, .end = end, .event = event });
    }

    fn captureCandidate(self: *Renderer, begin_in: c_uint, end_in: c_uint, reason: c_uint) !void {
        const begin = (try self.nativeOffset(begin_in)) orelse return;
        const end = (try self.nativeOffset(end_in)) orelse return;
        if (end <= begin) return;
        if (self.candidate == null or begin < self.candidate.?.begin or
            (begin == self.candidate.?.begin and reason == md.candidate_reference and self.candidate.?.reason != md.candidate_reference))
            self.candidate = .{ .begin = begin, .end = end, .reason = reason };
    }

    fn definitionCb(definition: *const md.ReferenceDefinition, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.captureDefinition(definition.*) catch |err| return self.failed(err);
        return 0;
    }

    fn candidateCb(begin: c_uint, end: c_uint, reason: c_uint, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.captureCandidate(begin, end, reason) catch |err| return self.failed(err);
        return 0;
    }

    /// Emitted once per document table, before its head/body children and with
    /// borrowed memory only for this callback. The snapshot is copied so it can
    /// never alias a retired native buffer or a later table.
    fn captureTableSource(self: *Renderer, source: md.TableSource) !void {
        const input = self.window orelse return error.InvalidMarkdownSpan;
        if (source.header_complete > 1 or source.body_begin <= source.header_begin or source.body_begin > input.len)
            return error.InvalidMarkdownSpan;
        const end = (try self.nativeOffset(source.body_begin)) orelse return error.InvalidMarkdownSpan;
        const begin = (try self.nativeOffset(source.header_begin)) orelse blk: {
            // The only permitted pre-window header is an exact previously
            // captured native proof whose retired prefix was loaned as context.
            const prior = self.table_resume orelse return error.InvalidMarkdownSpan;
            const raw = input[source.header_begin..source.body_begin];
            if (!prior.header_complete or prior.body_begin != end or
                prior.header_begin > self.source_base or
                self.source_base - prior.header_begin != self.context_bytes - source.header_begin or
                !std.mem.eql(u8, raw, prior.header)) return error.InvalidMarkdownSpan;
            break :blk prior.header_begin;
        };
        const header = try self.w.a.dupe(u8, input[source.header_begin..source.body_begin]);
        self.table_headers.append(self.w.a, header) catch |err| {
            self.w.a.free(header);
            return err;
        };
        self.pending_table_header = header;
        self.pending_table_begin = begin;
        self.pending_table_body = end;
        self.pending_table_complete = source.header_complete != 0;
        const count: usize = source.n_containers;
        if (count > max_table_containers) return error.MarkdownContainerLimit;
        self.pending_containers = if (count == 0) &.{} else blk: {
            const containers = source.containers orelse return error.InvalidMarkdownBlock;
            break :blk try self.w.a.dupe(md.TableContainer, containers[0..count]);
        };
    }

    fn tableSourceCb(source: *const md.TableSource, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.captureTableSource(source.*) catch |err| return self.failed(err);
        return 0;
    }

    fn segmentBlockCb(kind: c_int, _: ?*anyopaque, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        if (kind != 0 and kind != 9) return self.failed(error.InvalidMarkdownBlock);
        return 0;
    }

    fn parseSegment(self: *Renderer, input: []const u8, begin: usize, end: usize) !void {
        if (begin == end) return;
        self.parser_offset = begin;
        const parser: md.Parser = .{
            .enter_block = segmentBlockCb,
            .leave_block = segmentBlockCb,
            .enter_span = enterSpanCb,
            .leave_span = leaveSpanCb,
            .text = textCb,
        };
        // Same committed store as document/table parses: a retired definition
        // must resolve links inside a confirmed-span continuation too.
        const callbacks: md.SourceCallbacks = .{ .span = spanSourceCb, .references = self.references };
        const result = md.md_parse_inline_source(input[begin..end].ptr, @intCast(end - begin), &parser, &callbacks, self);
        if (self.yielded) return error.MarkdownDisplayYield;
        if (self.failure) |failure| return failure;
        if (result == -1) return error.OutOfMemory;
        if (result != 0) return error.MarkdownRenderLimit;
        try self.flushText();
    }

    fn emitKnownContent(self: *Renderer, input: []const u8, begin: usize, end: usize, span: ConfirmedSpan) !void {
        if (span.kind != 4 and span.kind != 6 and span.kind != 7) return self.parseSegment(input, begin, end);
        const absolute_begin = self.source_base + begin;
        const absolute_end = self.source_base + end;
        for (span.code) |piece| {
            if (piece.end <= absolute_begin or piece.begin >= absolute_end) continue;
            var value = piece.text;
            var start = piece.begin;
            var stop = piece.end;
            if (piece.exact) {
                start = @max(start, absolute_begin);
                stop = @min(stop, absolute_end);
                value = value[start - piece.begin .. stop - piece.begin];
            }
            try self.w.emitSourced(value, start -| self.source_base, stop - self.source_base, piece.exact);
        }
    }

    fn closeKnownSpan(self: *Renderer, index: usize) !void {
        const span = self.confirmed.items[index];
        self.confirmed.items[index].suffix_start = self.w.pos;
        const skip = @min(span.suffix_skip -| span.suffix_offset, span.suffix.len);
        const split = @min(span.suffix_style_split -| span.suffix_offset, span.suffix.len);
        // Generated output has an explicit anchor distinct from source-mapped
        // glyphs. Its physical rows may be ACKed independently; the span's
        // output checkpoint, not this anchor, gates source retirement.
        const prior_map = self.w.map;
        if (self.table != null and span.closer_end > span.closer_begin) {
            self.w.map = .{ .start = span.closer_begin -| self.source_base, .end = span.closer_end -| self.source_base, .exact = false, .generated = true };
        }
        defer self.w.map = prior_map;
        var emitted: usize = 0;
        if (skip < split) emitted += try self.w.emitBounded(span.suffix[skip..split], 4096, 64);
        if (skip + emitted >= split and @max(skip, split) < span.suffix.len) {
            if (span.kind == 2 or span.kind == 3) try self.w.setStyle(.{ .tone = .link_url });
            emitted += try self.w.emitBounded(span.suffix[@max(skip, split)..], 4096 -| emitted, 64);
        }
        self.confirmed.items[index].suffix_end = self.w.pos;
        if (skip + emitted < span.suffix.len) {
            self.confirmed.items[index].suffix_pending = true;
            self.resume_anchor = span.closer_begin;
            return error.MarkdownDisplayYield;
        }
        try self.w.setStyle(span.before);
    }

    /// Keep ONE writer/leaf across native inline segments. Known delimiter bytes
    /// are consumed as syntax, never offered to a fresh parser as literal text.
    fn parseContinuation(self: *Renderer, input: []const u8, seeds: []const ConfirmedSpan) !void {
        try self.enterBlock(0, null);
        try self.enterBlock(9, null);
        try self.parseSeededContent(input, 0, input.len, seeds);
        try self.leaveBlock(9);
        try self.leaveBlock(0);
    }

    fn parseSeededContent(self: *Renderer, input: []const u8, begin: usize, end: usize, seeds: []const ConfirmedSpan) !void {
        const seed_base = self.confirmed.items.len;
        try self.confirmed.appendSlice(self.w.a, seeds);
        for (self.confirmed.items[seed_base..]) |*span| {
            span.output_window = self.source_base;
            span.suffix_start = 0;
            span.suffix_end = 0;
            span.suffix_pending = false;
        }
        for (seeds, 0..) |span, i| {
            if (span.opener_end > self.source_base + begin or span.closer_begin < self.source_base + begin or
                span.closer_end < span.closer_begin or (i != 0 and span.closer_end > seeds[i - 1].closer_begin))
                return error.InvalidMarkdownSpan;
        }
        try self.w.setStyle(seeds[seeds.len - 1].inside);
        var pos: usize = begin;
        var active = seeds.len;
        while (active != 0) {
            const span = seeds[active - 1];
            const close_begin = span.closer_begin - self.source_base;
            if (close_begin >= end) break;
            const close_end = span.closer_end - self.source_base;
            if (close_begin < pos or close_end > end) return error.InvalidMarkdownSpan;
            try self.emitKnownContent(input, pos, close_begin, span);
            try self.closeKnownSpan(seed_base + active - 1);
            pos = close_end;
            active -= 1;
        }
        if (active != 0)
            try self.emitKnownContent(input, pos, end, seeds[active - 1])
        else
            try self.parseSegment(input, pos, end);
    }

    fn enterBlockCb(kind: c_int, raw: ?*anyopaque, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.enterBlock(kind, raw) catch |err| return self.failed(err);
        return 0;
    }
    fn leaveBlockCb(kind: c_int, _: ?*anyopaque, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.leaveBlock(kind) catch |err| return self.failed(err);
        return 0;
    }
    fn enterSpanCb(kind: c_int, raw: ?*anyopaque, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.enterSpan(kind, raw) catch |err| return self.failed(err);
        return 0;
    }
    fn leaveSpanCb(kind: c_int, raw: ?*anyopaque, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.leaveSpan(kind, raw) catch |err| return self.failed(err);
        return 0;
    }
    fn textCb(kind: c_int, ptr: [*]const u8, size: c_uint, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        if (self.failure != null) return callback_abort;
        self.content(kind, ptr[0..size]) catch |err| return self.failed(err);
        return 0;
    }
};

/// Parsing/render work is bounded by input AND shared generation budgets, not
/// merely by viewport size. Repeated reference URLs/cells count before storage. C
/// parser callbacks never let a Zig error cross the ABI. Only renderer-owned
/// SGR escapes are generated; decoded entity characters are sanitized again.
pub fn render(a: Allocator, input: []const u8, options: Options) !Rendered {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const clean = try text.sanitize(scratch, input, limit);
    const columns = std.math.clamp(options.columns, 1, 512);
    var budget: output.Budget = .{};
    var fallback_budget: output.Budget = .{};
    var renderer: Renderer = .{ .w = .{ .a = scratch, .columns = columns, .ansi = options.ansi, .base = options.tone, .budget = &budget } };
    var degraded = false;
    var clipped = false;
    if (options.markdown) {
        const parser: md.Parser = .{ .enter_block = Renderer.enterBlockCb, .leave_block = Renderer.leaveBlockCb, .enter_span = Renderer.enterSpanCb, .leave_span = Renderer.leaveSpanCb, .text = Renderer.textCb };
        // Block grammar (including paragraph-adjacent tables) is native and
        // shared with the streaming window; no second preprocessor rewrites
        // the source or its offsets.
        const result = md.md_parse(clean.ptr, @intCast(clean.len), &parser, &renderer);
        if (result != 0 or renderer.failure != null) {
            if (renderer.failure) |failure| {
                if (failure == error.OutOfMemory) return error.OutOfMemory;
            }
            if (result == -1) return error.OutOfMemory;
            degraded = true;
            renderer.w = .{ .a = scratch, .columns = columns, .ansi = options.ansi, .base = options.tone, .budget = &fallback_budget };
            try renderer.w.emit("[Markdown complexity limit; plain text]\n");
            clipped = try emitPlain(&renderer.w, clean);
        }
    } else {
        clipped = try emitPlain(&renderer.w, clean);
    }
    const total = renderer.w.lines.items.len;
    const end = total;
    const start = end - @min(end, @min(options.max_lines, 8192));
    const lines = try a.alloc([]const u8, end - start);
    var allocated: usize = 0;
    errdefer {
        for (lines[0..allocated]) |line| a.free(line);
        a.free(lines);
    }
    for (renderer.w.lines.items[start..end], 0..) |line, i| {
        lines[i] = try a.dupe(u8, line);
        allocated += 1;
    }
    return .{ .lines = lines, .total_lines = total, .truncated = clipped or text.exceedsSanitizedLimit(input, limit), .degraded = degraded };
}

/// Plain fallback is bounded too: a user card with many blank lines can expand
/// through row padding. Keep only complete safe rows and append a constant-sized
/// notice outside the exhausted budget; never return a partial SGR sequence.
fn emitPlain(w: *Writer, clean: []const u8) !bool {
    const clipped = blk: {
        w.emit(clean) catch |err| {
            if (err == error.MarkdownRenderLimit) break :blk true;
            return err;
        };
        w.finish() catch |err| {
            if (err == error.MarkdownRenderLimit) break :blk true;
            return err;
        };
        break :blk false;
    };
    if (clipped) {
        w.discardLine();
        var notice: Writer = .{ .a = w.a, .columns = w.columns, .ansi = w.ansi, .base = w.base };
        try notice.emit("[Display render limit; remaining text omitted]");
        try notice.finish();
        try w.lines.appendSlice(w.a, notice.lines.items);
    }
    return clipped;
}

/// Render ONLY a bounded continuation window: `input` is the synthesized
/// context prefix (if any) followed by unretired source. Retired source is never
/// part of `input`, so cost is bounded by the mutable window, not by history.
/// Rows carry parser-source provenance; leading synthetic context rows (table
/// border/header, the container-opener sentinel row) are dropped so a resumed
/// window never re-emits frozen content.
pub fn renderWindow(a: Allocator, input: []const u8, options: WindowOptions) !Window {
    const columns = std.math.clamp(options.columns, 1, 512);
    if (options.context_bytes > input.len) return error.InvalidMarkdownBlock;
    var budget: output.Budget = .{};
    var rows: std.ArrayList(WindowRow) = .empty;
    var semantic_arena = std.heap.ArenaAllocator.init(a);
    defer semantic_arena.deinit();
    var renderer: Renderer = .{
        .w = .{ .a = a, .columns = columns, .ansi = options.ansi, .base = options.base, .budget = &budget },
        .window = input,
        .context_bytes = options.context_bytes,
        .source_base = options.source_base,
        .semantic_allocator = semantic_arena.allocator(),
        .inline_mode = options.fragment != null,
        .fragment_kind = if (options.fragment) |fragment| fragment.kind else .paragraph,
        .collect = &rows,
        .row_limit = options.max_rows,
        .final = options.final,
        .streaming_tables = options.streaming_tables,
        .references = options.references,
        .table_resume = options.table,
        .table_fragment = options.table_fragment,
        .resume_spans = options.confirmed,
    };
    defer renderer.pending_text.deinit(a);
    defer renderer.leaves.deinit(a);
    defer renderer.confirmed.deinit(a);
    defer {
        for (renderer.table_headers.items) |header| a.free(header);
        renderer.table_headers.deinit(a);
    }
    defer {
        for (renderer.definitions.items) |definition| Renderer.freeDefinition(a, definition);
        renderer.definitions.deinit(a);
    }
    defer if (renderer.table) |table| {
        if (table.stream) |stream| {
            stream.deinit();
            a.destroy(stream);
        }
    };
    defer renderer.code_pieces.deinit(a);
    defer renderer.cells.deinit(a);
    if (options.fragment) |ctx| {
        renderer.w.prefix = ctx.prefix;
        renderer.w.continuation = ctx.continuation;
        renderer.w.style = ctx.style;
    }
    renderer.w.sink = .{ .context = &renderer, .onRow = Renderer.rowSink };
    const parser: md.Parser = .{ .enter_block = Renderer.enterBlockCb, .leave_block = Renderer.leaveBlockCb, .enter_span = Renderer.enterSpanCb, .leave_span = Renderer.leaveSpanCb, .text = Renderer.textCb };
    const source_callbacks: md.SourceCallbacks = .{ .span = Renderer.spanSourceCb, .fence = Renderer.fenceSourceCb, .cell = Renderer.cellSourceCb, .cell_content = Renderer.cellContentCb, .references = options.references, .definition = Renderer.definitionCb, .candidate = Renderer.candidateCb, .table = Renderer.tableSourceCb, .partial_input = @intFromBool(!options.final) };
    var table_skip: [32]c_uint = @splat(0);
    var table_alignments: [32]c_int = @splat(0);
    var native_table: md.TableResume = undefined;
    var fragment_result: md.TableFragmentResult = .{};
    if (options.table) |table| {
        for (table.delivered, &table_skip) |offset, *skip| skip.* = @intCast(@min(offset -| options.source_base, input.len));
        table_alignments = table.alignments;
        native_table = .{
            .columns = @intCast(table.columns),
            .first_column = @intCast(table.first_column),
            .alignments = &table_alignments,
            .skip = &table_skip,
            .partial_cell = @intFromBool(table.partial_cell),
            .trim_leading = @intFromBool(table.trim_leading),
            .containers = if (table.containers.len == 0) null else table.containers.ptr,
            .n_containers = @intCast(@min(table.containers.len, max_table_containers)),
            .first_line_partial = @intFromBool(table.first_line_partial),
        };
        // Continuation rows start inside the table: they keep the exact writer
        // prefix already displayed. A document parse derives its own prefix
        // from the retained source bytes and must not double it.
        if (options.table_fragment) {
            renderer.w.prefix = table.prefix;
            renderer.w.continuation = table.continuation;
        }
    }
    const result = if (options.table != null and options.table_fragment)
        md.md_parse_table_fragment(input.ptr, @intCast(input.len), &parser, &source_callbacks, &native_table, &fragment_result, &renderer)
    else if (options.table != null)
        // Presentation-only continuation of a document-recognized table: the
        // grammar re-derives header/delimiter; earlier physical rows are proven.
        md.md_parse_source(input.ptr, @intCast(input.len), &parser, &source_callbacks, &renderer)
    else if (options.confirmed.len != 0) blk: {
        if (options.fragment == null or options.context_bytes != 0) return error.InvalidMarkdownSpan;
        renderer.parseContinuation(input, options.confirmed) catch |err| {
            if (err != error.MarkdownDisplayYield) return err;
            renderer.yielded = true;
        };
        break :blk @as(c_int, 0);
    } else if (options.fragment != null) blk: {
        // Inline fragment route still resolves committed references.
        const inline_callbacks: md.SourceCallbacks = .{ .span = Renderer.spanSourceCb, .references = options.references };
        break :blk md.md_parse_inline_source(input.ptr, @intCast(input.len), &parser, &inline_callbacks, &renderer);
    } else md.md_parse_source(input.ptr, @intCast(input.len), &parser, &source_callbacks, &renderer);
    if (result == -1) return error.OutOfMemory;
    if (renderer.failure) |failure| return failure;
    if (result != 0 and !renderer.yielded) return error.MarkdownRenderLimit;
    if (!renderer.yielded) {
        renderer.flushText() catch |err| {
            if (err != error.MarkdownDisplayYield) return err;
            renderer.yielded = true;
        };
        // Inline parsing has no document/leaf callbacks to finish its last
        // partial line. Document, table and confirmed continuations already
        // finish through their block boundaries; boundary is a no-op for them.
        if (!renderer.yielded) renderer.w.boundary() catch |err| {
            if (err != error.MarkdownDisplayYield) return err;
            renderer.yielded = true;
        };
    }
    if (renderer.yielded) {
        // A bounded inline/parser yield can occur before the cell queue reaches
        // NeedDrain. Publish only the already copied complete cell lines; the
        // writer's unfinished line remains owned by the parser checkpoint.
        // NeedDrain and full-stage yields already drained their bounded stage.
        if (!renderer.table_yield_pending and !renderer.table_drain_full) {
            if (renderer.table) |table| {
                if (table.stream != null) try renderer.drainTableRows(64);
            }
        }
        if (renderer.leaves.items.len != 0)
            renderer.leaves.items[renderer.leaves.items.len - 1].row_end = rows.items.len;
    }

    // Every completed physical row ends at the next row's output start. When
    // the parser yields, the writer can still hold an unfinished physical row;
    // its start, not bytes fed into that row, is the last ACKable cursor.
    for (rows.items, 0..) |*row, i| {
        if (row.table_kind != null) continue;
        if (i + 1 < rows.items.len and rows.items[i + 1].table_kind == null) {
            row.output_end = rows.items[i + 1].output_start;
        } else if (renderer.table == null) {
            row.output_end = if (renderer.w.hasContent()) renderer.w.row_src_start else renderer.w.pos;
        } else {
            row.output_end = row.output_start;
        }
    }

    // A table border is synthetic in source coordinates, but is real physical
    // output. Context removal must never discard an unacknowledged border.
    var drop: usize = 0;
    if (options.context_bytes != 0) {
        while (drop < rows.items.len and rows.items[drop].synthetic and rows.items[drop].table_kind == null) drop += 1;
    }
    const first_leaf: usize = if (drop < rows.items.len) rows.items[drop].leaf else renderer.leaves.items.len;
    var leaves: std.ArrayList(WindowLeaf) = .empty;
    if (first_leaf < renderer.leaves.items.len) {
        try leaves.appendSlice(a, renderer.leaves.items[first_leaf..]);
        for (leaves.items) |*leaf| {
            leaf.row_start = rows.items.len;
            leaf.row_end = rows.items.len;
        }
    }
    const kept = try a.alloc(WindowRow, rows.items.len - drop);
    for (rows.items[drop..], 0..) |row, i| {
        var copy = row;
        copy.leaf = if (row.leaf >= first_leaf) row.leaf - first_leaf else 0;
        kept[i] = copy;
        if (copy.leaf < leaves.items.len) {
            const leaf = &leaves.items[copy.leaf];
            leaf.row_start = @min(leaf.row_start, i);
            leaf.row_end = i + 1;
        }
    }
    const end: LeafCtx = if (options.fragment != null and std.mem.indexOfScalar(u8, input, '\n') == null)
        options.fragment.?
    else if (renderer.leaves.items.len != 0)
        renderer.leaves.items[renderer.leaves.items.len - 1].after
    else if (renderer.depth <= 1) .{ .kind = .document } else .{ .kind = .container, .prefix = renderer.w.prefix, .continuation = renderer.w.continuation orelse "", .style = renderer.w.style };
    rows.deinit(a);
    const spans = try a.alloc(ConfirmedSpan, renderer.confirmed.items.len);
    for (renderer.confirmed.items, spans) |value, *destination| {
        var span = value;
        if (span.code_count != 0)
            span.code = renderer.code_pieces.items[span.code_first..][0..span.code_count];
        destination.* = try span.clone(a, options.source_base);
    }
    const cells = try a.dupe(CellRange, renderer.cells.items);
    errdefer a.free(cells);
    const definitions = try renderer.definitions.toOwnedSlice(a);
    errdefer {
        for (definitions) |definition| Renderer.freeDefinition(a, definition);
        a.free(definitions);
    }
    const table_headers = try renderer.table_headers.toOwnedSlice(a);
    return .{
        .rows = kept,
        .leaves = leaves.items,
        .confirmed = spans,
        .cells = cells,
        .resume_anchor = renderer.resume_anchor,
        .end = end,
        .end_is_document = end.kind == .document,
        .leaf_open = if (options.fragment != null and std.mem.indexOfScalar(u8, input, '\n') == null) true else renderer.leaf_open,
        .yielded = renderer.yielded,
        .table_frontier = renderer.table_frontier,
        .definitions = definitions,
        .table_headers = table_headers,
        .candidate = renderer.candidate,
        .table_closed = fragment_result.closed != 0,
        .table_end = if (fragment_result.closed != 0)
            @min(@as(usize, fragment_result.end), input.len) -| options.context_bytes
        else
            input.len -| options.context_bytes,
    };
}

pub fn releaseWindow(a: Allocator, window: *Window) void {
    for (window.rows) |row| {
        a.free(row.text);
        if (row.table_occurrences.len != 0) a.free(row.table_occurrences);
    }
    a.free(window.rows);
    a.free(window.leaves);
    for (window.confirmed) |span| span.deinit(a);
    a.free(window.confirmed);
    a.free(window.cells);
    for (window.definitions) |definition| Renderer.freeDefinition(a, definition);
    a.free(window.definitions);
    for (window.table_headers) |header| a.free(header);
    a.free(window.table_headers);
    window.* = .{ .rows = &.{}, .leaves = &.{} };
}

pub fn release(a: Allocator, rendered: Rendered) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}

fn joined(a: Allocator, rendered: Rendered) ![]const u8 {
    return std.mem.join(a, "\n", rendered.lines);
}

test "native table cell presence distinguishes offset zero from missing" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const options: WindowOptions = .{
        .columns = 40,
        .source_base = 100,
        .streaming_tables = true,
        .table_fragment = true,
        .table = .{ .columns = 2, .partial_cell = true, .first_line_partial = true, .trim_leading = true, .header_done = true, .top_done = true },
    };
    const actual = try renderWindow(arena.allocator(), "|x\n", options);
    try std.testing.expectEqual(@as(usize, 2), actual.cells.len);
    try std.testing.expect(actual.cells[0].present);
    try std.testing.expectEqual(@as(usize, 100), actual.cells[0].raw_begin);
    try std.testing.expectEqual(@as(usize, 100), actual.cells[0].raw_end);
    try std.testing.expectEqual(@as(usize, 101), actual.cells[0].next_begin);
    const missing = try renderWindow(arena.allocator(), "x\n", options);
    try std.testing.expectEqual(@as(usize, 2), missing.cells.len);
    try std.testing.expect(missing.cells[0].present);
    try std.testing.expect(!missing.cells[1].present);
    try std.testing.expect(missing.cells[1].row_complete);
    try std.testing.expectEqual(@as(usize, 0), missing.cells[1].raw_begin);
}

test "streaming long table cell returns bounded successful yield and physical checkpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var input: std.ArrayList(u8) = .empty;
    try input.appendSlice(a, "| A | B | C |\n| --- | --- | --- |\n| ");
    const long = try a.alloc(u8, 12000);
    @memset(long, 'x');
    try input.appendSlice(a, long);
    try input.appendSlice(a, " | TAIL | LAST |");
    const window = try renderWindow(a, input.items, .{ .columns = 40, .streaming_tables = true, .final = true });
    try std.testing.expect(window.yielded);
    try std.testing.expect(window.rows.len > 0 and window.rows.len <= 67);
    const frontier = window.table_frontier orelse return error.TestUnexpectedResult;
    try std.testing.expect(frontier.delivered[0] > 0);
    try std.testing.expectEqual(@as(usize, 0), frontier.delivered[1]);
    try std.testing.expectEqual(@as(usize, 0), frontier.delivered[2]);
    var last: usize = 0;
    for (window.rows) |row| if (row.table_checkpoint) |checkpoint| {
        if (checkpoint.row_begin == frontier.row_begin) {
            try std.testing.expect(checkpoint.delivered[0] >= last);
            last = checkpoint.delivered[0];
        }
    };
    try std.testing.expectEqual(frontier.delivered[0], last);
}

test "incomplete table fragment retains missing columns as incomplete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "| A | B | C |\n| --- | --- | --- |\n| ongoing";
    const window = try renderWindow(a, source, .{ .columns = 40, .streaming_tables = true, .final = false });
    var incomplete: usize = 0;
    for (window.cells) |cell| {
        if (!cell.row_complete and !cell.cell_complete) incomplete += 1;
    }
    try std.testing.expect(incomplete >= 1);
    try std.testing.expect(!window.yielded);
    for (window.rows) |row| try std.testing.expect(row.table_kind != .bottom);
}

test "streaming table nonfinal complete physical boundary closes table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { input: []const u8, bottom: bool, paragraph: bool = false, base: usize = 0, context: usize = 0 }{
        .{ .input = "| a | b |\n| --- | --- |\n", .bottom = false },
        .{ .input = "| a | b |\n| --- | --- |\n| c | d |\npartial", .bottom = false },
        .{ .input = "| a | b |\n| --- | --- |\n| c | d |\n\nstream-final-answer\n", .bottom = true, .paragraph = true },
        .{ .input = "| a | b |\n| --- | --- |\n\n", .bottom = true },
        .{ .input = "| a | b |\r\n| --- | --- |\r\n| c | d |\r\n\r\nstream-final-answer\r\n", .bottom = true, .paragraph = true, .base = 73 },
        .{ .input = "prefix\n\n| a | b |\n| --- | --- |\n| c | d |\n\nstream-final-answer\n", .bottom = true, .paragraph = true, .base = 73, .context = "prefix\n\n".len },
    };
    for (cases) |case| {
        const window = try renderWindow(a, case.input, .{ .columns = 40, .ansi = false, .streaming_tables = true, .final = false, .source_base = case.base, .context_bytes = case.context });
        var bottoms: usize = 0;
        var paragraph_seen = false;
        for (window.rows) |row| {
            if (std.mem.startsWith(u8, row.text, "└")) {
                try std.testing.expect(!paragraph_seen);
                bottoms += 1;
            }
            if (std.mem.indexOf(u8, row.text, "stream-final-answer") != null) {
                paragraph_seen = true;
                try std.testing.expectEqual(@as(usize, 1), bottoms);
            }
        }
        try std.testing.expectEqual(@as(usize, if (case.bottom) 1 else 0), bottoms);
        if (case.paragraph) try std.testing.expect(paragraph_seen);
    }
}

test "streaming table final EOF emits bottom only after row drain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "| a | b |\n| --- | --- |\n| c | d |\n";
    for ([_]bool{ false, true }) |final| {
        const window = try renderWindow(a, input, .{ .columns = 40, .ansi = false, .streaming_tables = true, .final = final });
        var bottoms: usize = 0;
        var body_seen = false;
        for (window.rows) |row| {
            if (std.mem.indexOf(u8, row.text, "c") != null and std.mem.indexOf(u8, row.text, "d") != null) body_seen = true;
            if (std.mem.startsWith(u8, row.text, "└")) {
                try std.testing.expect(body_seen);
                bottoms += 1;
            }
        }
        try std.testing.expect(body_seen);
        try std.testing.expectEqual(@as(usize, if (final) 1 else 0), bottoms);
    }
}

test "Markdown callback OOM and complexity failures stay sticky and abort native parsing" {
    for ([_]bool{ false, true }) |oom| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        const a = failing.allocator();
        var budget: output.Budget = .{ .max_work = if (oom) 1024 else 0 };
        var renderer: Renderer = .{ .w = .{ .a = a, .columns = 80, .ansi = false, .budget = &budget } };
        defer renderer.w.deinit();
        defer renderer.pending_text.deinit(a);
        const parser: md.Parser = .{ .enter_block = Renderer.enterBlockCb, .leave_block = Renderer.leaveBlockCb, .enter_span = Renderer.enterSpanCb, .leave_span = Renderer.leaveSpanCb, .text = Renderer.textCb };
        const source = "hello";
        try std.testing.expectEqual(@as(c_int, -2), md.md_parse(source.ptr, source.len, &parser, &renderer));
        const expected = if (oom) error.OutOfMemory else error.MarkdownRenderLimit;
        try std.testing.expectEqual(expected, renderer.failure.?);
        const depth = renderer.depth;
        const work = budget.work;
        // Invalid details would crash if a callback proceeded past the guard.
        try std.testing.expectEqual(@as(c_int, -2), Renderer.enterBlockCb(7, null, &renderer));
        try std.testing.expectEqual(@as(c_int, -2), Renderer.leaveBlockCb(999, null, &renderer));
        try std.testing.expectEqual(@as(c_int, -2), Renderer.enterSpanCb(2, null, &renderer));
        try std.testing.expectEqual(@as(c_int, -2), Renderer.leaveSpanCb(2, null, &renderer));
        try std.testing.expectEqual(@as(c_int, -2), Renderer.textCb(0, source.ptr, source.len, &renderer));
        try std.testing.expectEqual(expected, renderer.failure.?);
        try std.testing.expectEqual(depth, renderer.depth);
        try std.testing.expectEqual(work, budget.work);
        try std.testing.expectEqual(@as(usize, 0), renderer.pending_text.items.len);
        try std.testing.expectEqual(@as(usize, 0), renderer.w.lines.items.len);
    }
}

test "reference destinations and opaque titles fall back before viewport selection" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |opaque_title| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(a);
        for (0..1024) |_| try source.appendSlice(a, "[a][r] ");
        try source.appendSlice(a, if (opaque_title) "\n\n[r]: https://example.org/ \"" else "\n\n[r]: https://example.org/");
        for (0..8192) |_| try source.append(a, 'a');
        if (opaque_title) try source.append(a, '"');
        const r = try render(a, source.items, .{ .columns = 80, .max_lines = 1, .ansi = false });
        defer release(a, r);
        try std.testing.expect(r.degraded);
        try std.testing.expect(!r.truncated);
        try std.testing.expect(r.total_lines < 1000);
        try std.testing.expectEqual(@as(usize, 1), r.lines.len);
    }
}

test "opaque link titles and code metadata consume the work budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var budget: output.Budget = .{ .max_work = 16 };
    var renderer: Renderer = .{ .w = .{ .a = arena.allocator(), .columns = 80, .ansi = false, .budget = &budget } };
    const chars: [64]u8 = @splat('t');
    const types: [1]c_int = .{0};
    const offsets: [2]c_uint = .{ 0, chars.len };
    const title: md.Attribute = .{ .text = &chars, .size = chars.len, .types = &types, .offsets = &offsets };
    var link: md.Link = .{ .href = std.mem.zeroes(md.Attribute), .title = title, .autolink = 0 };
    try std.testing.expectError(error.MarkdownRenderLimit, renderer.enterSpan(2, &link));
    try std.testing.expectEqual(@as(usize, 0), renderer.w.line.items.len);
    var code: md.Code = .{ .info = title, .lang = title, .fence = '`' };
    try std.testing.expectError(error.MarkdownRenderLimit, renderer.enterBlock(7, &code));
    try std.testing.expectEqual(@as(usize, 0), renderer.w.line.items.len);
}

test "table cells and main writer share one generation budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var budget: output.Budget = .{ .max_work = 20 }; // Decoded buffering + emit are both charged; the second cell still fails.
    var renderer: Renderer = .{ .w = .{ .a = arena.allocator(), .columns = 40, .ansi = false, .budget = &budget } };
    var table: md.Table = .{ .columns = 2, .head_rows = 1, .body_rows = 1 };
    var cell: md.Td = .{ .alignment = 0 };
    try renderer.enterBlock(10, &table);
    try renderer.enterBlock(13, null);
    try renderer.enterBlock(14, &cell);
    try std.testing.expect(renderer.w.budget.? == &budget);
    try renderer.content(0, "first");
    try renderer.leaveBlock(14);
    try renderer.enterBlock(15, &cell);
    try std.testing.expect(renderer.w.budget.? == &budget);
    try std.testing.expectError(error.MarkdownRenderLimit, renderer.content(0, "second"));
}

test "plain user padding is bounded with an explicit complete truncation notice" {
    const a = std.testing.allocator;
    const newlines: [10000]u8 = @splat('\n');
    const r = try render(a, &newlines, .{ .columns = 512, .max_lines = 20, .markdown = false, .tone = .user });
    defer release(a, r);
    try std.testing.expect(r.truncated);
    try std.testing.expect(r.total_lines < newlines.len);
    try std.testing.expect(std.mem.indexOf(u8, r.lines[r.lines.len - 1], "Display render limit") != null);
    for (r.lines) |line| {
        try std.testing.expect(output.displayWidth(line) <= 512);
        try std.testing.expect(std.mem.endsWith(u8, line, @import("theme.zig").reset));
    }
}

test "inline and display math fallback preserves delimiters and raw formula" {
    const a = std.testing.allocator;
    const r = try render(a, "$x_1 + \\frac{a}{b}$\n\n$$a_*b*_c + \\frac{x}{y}$$", .{ .columns = 100, .max_lines = 20, .ansi = false });
    defer release(a, r);
    const s = try joined(a, r);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "$x_1 + \\frac{a}{b}$") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "$$a_*b*_c + \\frac{x}{y}$$") != null);
    try std.testing.expect(!r.degraded and !r.truncated);
}

test "CommonMark emphasis escapes references code spans and entities" {
    try text.initLocale();
    const a = std.testing.allocator;
    const r = try render(a, "# Title\n\n**bold _nested_** ~~gone~~ \\*literal\\*\n\n[label][ref] ![alt](image.png) <https://example.org>\n\n[ref]: https://example.org/path\n\n`` a ` b `` &amp; &#x4e2d; &copy;", .{ .columns = 100, .max_lines = 100, .ansi = false });
    defer release(a, r);
    const s = try joined(a, r);
    defer a.free(s);
    for ([_][]const u8{ "Title", "bold nested gone *literal*", "label (https://example.org/path)", "[image: alt] (image.png)", "a ` b", "& 中 ©" }) |part| try std.testing.expect(std.mem.indexOf(u8, s, part) != null);
    try std.testing.expect(!r.degraded);
}

test "CommonMark block nesting task lists setext fenced and indented code" {
    const a = std.testing.allocator;
    const r = try render(a, "Setext\n======\n\n> quote\n> - nested\n\n3. ordered\n   - inner\n\n- [x] done\n- [ ] todo\n\nAfter lists\n\n    indented **literal**\n\n````zig\n```\n*literal*\n````", .{ .columns = 50, .max_lines = 100, .ansi = false });
    defer release(a, r);
    const s = try joined(a, r);
    defer a.free(s);
    for ([_][]const u8{ "Setext", "> quote", "> - nested", "3. ordered", "- inner", "- [x] done", "- [ ] todo", "indented **literal**", "```", "*literal*" }) |part| try std.testing.expect(std.mem.indexOf(u8, s, part) != null);
    try std.testing.expect(!r.degraded);
}

test "GFM tables align and preserve all cells in narrow windows" {
    const a = std.testing.allocator;
    for ([_]usize{ 1, 10, 40, 80 }) |cols| {
        const r = try render(a, "| Name | Amount |\n| :--- | ---: |\n| alpha | 12 |\n| beta | 345 |", .{ .columns = cols, .max_lines = 200, .ansi = true });
        defer release(a, r);
        try std.testing.expect(!r.degraded);
        for (r.lines) |line| try std.testing.expect(output.displayWidth(line) <= cols);
        const plain = try render(a, "| Name | Amount |\n| :--- | ---: |\n| alpha | 12 |\n| beta | 345 |", .{ .columns = cols, .max_lines = 200, .ansi = false });
        defer release(a, plain);
        var compact: std.ArrayList(u8) = .empty;
        defer compact.deinit(a);
        for (plain.lines) |line| for (line) |byte| {
            if (!std.ascii.isWhitespace(byte)) try compact.append(a, byte);
        };
        for ([_][]const u8{ "Name", "Amount", "alpha", "12", "beta", "345" }) |value| try std.testing.expect(std.mem.indexOf(u8, compact.items, value) != null);
    }
}

test "Markdown paragraphs and empty list items remain structurally visible" {
    const a = std.testing.allocator;
    const r = try render(a, "first paragraph\n\nsecond paragraph", .{ .columns = 40, .max_lines = 100, .ansi = false });
    defer release(a, r);
    try std.testing.expectEqual(@as(usize, 3), r.lines.len);
    try std.testing.expectEqualStrings("", r.lines[1]);
    const items = try render(a, "-\n- filled", .{ .columns = 40, .max_lines = 100, .ansi = false });
    defer release(a, items);
    try std.testing.expectEqual(@as(usize, 2), items.lines.len);
    try std.testing.expect(std.mem.startsWith(u8, items.lines[0], "- "));
    try std.testing.expectEqualStrings("- filled", items.lines[1]);
}

test "Markdown uses distinct heading emphasis code quote and link colors" {
    const theme = @import("theme.zig");
    const a = std.testing.allocator;
    const r = try render(a, "# Heading\n\n**bold** `inline` [label](https://example.org)\n\n> quote\n\n- item\n\n```\ncode\n```", .{ .columns = 80, .max_lines = 100 });
    defer release(a, r);
    const s = try joined(a, r);
    defer a.free(s);
    for ([_][]const u8{ theme.heading, theme.strong, theme.inline_code, theme.code, theme.quote, theme.link, theme.bullet }) |color| try std.testing.expect(std.mem.indexOf(u8, s, color) != null);
    // Verify bright yellow/blue/purple/green on actual glyphs, not aliases.
    // H1/link keep underline; code/inline/list markers do not gain extra bold.
    for ([_][]const u8{ "\x1b[1m\x1b[38;5;220m\x1b[1m\x1b[4mHeading", "\x1b[4m\x1b[38;5;12mlabel", "\x1b[38;5;141minline", "\x1b[38;5;77mcode", "\x1b[38;5;141m-" }) |style| try std.testing.expect(std.mem.indexOf(u8, s, style) != null);
    for ([_][]const u8{ "38;2;", "48;" }) |rejected| try std.testing.expect(std.mem.indexOf(u8, s, rejected) == null);
    try @import("../tests/regular_screen.zig").rejectFullscreen(s);
}

test "ordinary and emphasized text stay neutral while inline code is foreground only" {
    const theme = @import("theme.zig");
    const a = std.testing.allocator;
    const r = try render(a, "ordinary **bold** `exit_code=124` after\n\n$literal_math$", .{ .columns = 80, .max_lines = 20 });
    defer release(a, r);
    const s = try joined(a, r);
    defer a.free(s);
    try std.testing.expect(std.mem.startsWith(u8, r.lines[0], theme.reset ++ "ordinary "));
    try std.testing.expect(std.mem.indexOf(u8, s, theme.strong) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, theme.inline_code ++ "exit_code=124") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, theme.inline_code ++ "$literal_math$") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "48;") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, theme.heading) == null);
    try std.testing.expect(output.displayWidth(r.lines[0]) < 80);
    try std.testing.expect(std.mem.indexOf(u8, s, theme.reset ++ " after") != null);
}

test "Pi code colors follow block syntax without Markdown background or row padding" {
    const theme = @import("theme.zig");
    const a = std.testing.allocator;
    const source = "exit_code=124\n/root/thin\nexit_code=0\n\n```text\nexit_code=124\n/root/thin\nexit_code=0\n```\n\nafter";
    const r = try render(a, source, .{ .columns = 40, .max_lines = 30 });
    defer release(a, r);
    var code_rows: usize = 0;
    for (r.lines) |line| {
        if (std.mem.indexOf(u8, line, theme.code) != null) {
            code_rows += 1;
            try std.testing.expect(output.displayWidth(line) < 40);
        }
        try std.testing.expect(std.mem.endsWith(u8, line, theme.reset));
        try std.testing.expect(std.mem.indexOf(u8, line, theme.user_background) == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "48;") == null);
    }
    try std.testing.expectEqual(@as(usize, 3), code_rows);
    try std.testing.expect(std.mem.indexOf(u8, r.lines[0], "48;") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.lines[r.lines.len - 1], "48;") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.lines[r.lines.len - 1], "after") != null);
}

test "tables have outer and per logical row rules with Pi bold neutral headers" {
    try text.initLocale();
    const theme = @import("theme.zig");
    const a = std.testing.allocator;
    const source = "| Name | Amount |\n| :--- | ---: |\n| alpha | 12 |\n| beta | 345 |";
    const r = try render(a, source, .{ .columns = 40, .max_lines = 30, .ansi = false });
    defer release(a, r);
    try std.testing.expectEqual(@as(usize, 7), r.lines.len);
    try std.testing.expectEqualStrings("┌───────┬────────┐", r.lines[0]);
    try std.testing.expectEqualStrings("├───────┼────────┤", r.lines[2]);
    try std.testing.expectEqualStrings(r.lines[2], r.lines[4]);
    try std.testing.expectEqualStrings("└───────┴────────┘", r.lines[6]);
    try std.testing.expectEqualStrings("│ alpha │     12 │", r.lines[3]);
    for (r.lines) |line| try std.testing.expectEqual(@as(usize, 18), output.displayWidth(line));
    const styled = try render(a, source, .{ .columns = 40, .max_lines = 30 });
    defer release(a, styled);
    try std.testing.expect(std.mem.indexOf(u8, styled.lines[1], theme.table_header) != null);
    try std.testing.expect(std.mem.indexOf(u8, styled.lines[3], theme.table_header) == null);
    try std.testing.expect(std.mem.indexOf(u8, styled.lines[3], theme.heading) == null);
    for (styled.lines) |line| {
        try std.testing.expect(std.mem.endsWith(u8, line, theme.reset));
        try std.testing.expect(std.mem.indexOf(u8, line, "48;") == null);
    }
    const page = try render(a, source, .{ .columns = 40, .max_lines = 2, .ansi = false });
    defer release(a, page);
    try std.testing.expectEqual(@as(usize, 7), page.total_lines);
    try std.testing.expectEqual(@as(usize, 2), page.lines.len);
    try std.testing.expectEqualStrings(r.lines[5], page.lines[0]);
    try std.testing.expectEqualStrings(r.lines[6], page.lines[1]);
}

test "wrapped nested and narrow tables retain cells without rules inside a logical row" {
    try text.initLocale();
    const a = std.testing.allocator;
    for ([_]usize{ 20, 32 }) |cols| {
        const r = try render(a, "> | Key | Details |\n> | --- | --- |\n> | a | long wrapped é text 中文 |\n> | b | done |", .{ .columns = cols, .max_lines = 100, .ansi = false });
        defer release(a, r);
        var middle: usize = 0;
        for (r.lines) |line| {
            if (std.mem.indexOf(u8, line, "├") != null) middle += 1;
            try std.testing.expect(output.displayWidth(line) <= cols);
            try std.testing.expect(std.unicode.utf8ValidateSlice(line));
            try std.testing.expect(std.mem.startsWith(u8, line, "> "));
        }
        try std.testing.expectEqual(@as(usize, 2), middle);
        try std.testing.expect(r.lines.len > 7);
        const s = try joined(a, r);
        defer a.free(s);
        try std.testing.expect(std.mem.indexOf(u8, s, "done") != null);
    }
    const narrow = try render(a, "| A | B |\n|---|---|\n| alpha | beta |", .{ .columns = 10, .max_lines = 100, .ansi = false });
    defer release(a, narrow);
    const s = try joined(a, narrow);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "┌") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "alpha") != null and std.mem.indexOf(u8, s, "beta") != null);
}

test "architecture table immediately after paragraph matches Pi table recognition" {
    try text.initLocale();
    const a = std.testing.allocator;
    const source = @embedFile("../tests/architecture_table.md");
    for ([_]usize{ 40, 80, 120 }) |columns| {
        const r = try render(a, source, .{ .columns = columns, .max_lines = 500 });
        defer release(a, r);
        try std.testing.expect(!r.degraded);
        var top: usize = 0;
        var middle: usize = 0;
        var bottom: usize = 0;
        var grid_width: ?usize = null;
        for (r.lines) |line| {
            const width = output.displayWidth(line);
            try std.testing.expect(width <= columns);
            if (std.mem.indexOf(u8, line, "┌") != null) {
                top += 1;
                grid_width = width;
            }
            if (std.mem.indexOf(u8, line, "├") != null) middle += 1;
            if (std.mem.indexOf(u8, line, "└") != null) bottom += 1;
            if (grid_width != null and (std.mem.indexOf(u8, line, "│") != null or std.mem.indexOf(u8, line, "┼") != null or std.mem.indexOf(u8, line, "┴") != null)) try std.testing.expectEqual(grid_width.?, width);
        }
        try std.testing.expectEqual(@as(usize, 1), top);
        try std.testing.expectEqual(@as(usize, 8), middle);
        try std.testing.expectEqual(@as(usize, 1), bottom);
        const s = try joined(a, r);
        defer a.free(s);
        try std.testing.expect(std.mem.indexOf(u8, s, "|---|---|") == null);
    }
    for ([_][]const u8{ "```text\nintro\n| A |\n|---|\n| literal |\n```", "intro\n    | A |\n    |---|\n    | literal |" }) |code| {
        const r = try render(a, code, .{ .columns = 80, .max_lines = 100, .ansi = false });
        defer release(a, r);
        const s = try joined(a, r);
        defer a.free(s);
        try std.testing.expect(std.mem.indexOf(u8, s, "┌") == null);
    }
}

test "static grammar keeps every original code and indented negative literal" {
    try text.initLocale();
    const a = std.testing.allocator;
    // Original unsafe input coverage: mixed space/tab indentation, paragraph
    // followed by an indented delimiter, fenced code and a 4-space indented
    // shape. Native grammar must keep all of them literal (no table).
    for ([_][]const u8{
        "    intro\n \t|a|\n \t|---|\n \t|body|\n",
        "    intro\n  \t|a|\n  \t|---|\n",
        "intro\n|a|\n \t|---|\n",
        "```\nintro\n|a|\n|---|\n```\n",
        "intro\n    | A |\n    |---|\n    | literal |",
        "intro\r\n    | A |\r\n    |---|\r\n",
    }) |source| {
        for ([_]bool{ false, true }) |ansi| {
            const rendered = try render(a, source, .{ .columns = 80, .max_lines = 200, .ansi = ansi });
            defer release(a, rendered);
            try std.testing.expect(!rendered.degraded);
            const visible = try joined(a, rendered);
            defer a.free(visible);
            try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, visible, "┌"));
            // The pipe syntax survives as literal text, not as a rewritten table.
            try std.testing.expect(std.mem.indexOf(u8, visible, "|") != null);
        }
    }
}

test "static grammar keeps multiline inline code spans literal over table shapes" {
    try text.initLocale();
    const a = std.testing.allocator;
    // A backtick opened on the preceding paragraph line makes the pipes part of
    // one native inline-code span, so no header/delimiter promotion may occur.
    for ([_][]const u8{
        "intro `\n|a|\n|---|\n` end\n",
        "intro `\r\n|a|\r\n|---|\r\n` end\r\n",
    }) |source| {
        for ([_]bool{ false, true }) |ansi| {
            const rendered = try render(a, source, .{ .columns = 60, .max_lines = 200, .ansi = ansi });
            defer release(a, rendered);
            try std.testing.expect(!rendered.degraded);
            const visible = try joined(a, rendered);
            defer a.free(visible);
            try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, visible, "┌"));
            try std.testing.expect(std.mem.indexOf(u8, visible, "|a|") != null);
            try std.testing.expect(std.mem.indexOf(u8, visible, "|---|") != null);
            try std.testing.expect(std.mem.indexOf(u8, visible, "end") != null);
        }
    }
    // Backslashes do not escape a closing backtick inside a code span.
    for ([_]bool{ false, true }) |ansi| {
        const rendered = try render(a, "intro `a\\`b\n|a|\n|---|\n` end\n", .{ .columns = 60, .max_lines = 200, .ansi = ansi });
        defer release(a, rendered);
        try std.testing.expect(!rendered.degraded);
        const visible = try joined(a, rendered);
        defer a.free(visible);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, "┌"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, "└"));
        try std.testing.expect(std.mem.indexOf(u8, visible, "end") != null);
    }
    // An escaped backtick does not open a span, so ordinary pipes remain
    // delimiters and a valid adjacent table is still recognized.
    for ([_][]const u8{
        "intro \\`x | y\\`\n| --- | --- |\n",
        "intro\n| a | b |\n| --- | --- |\n| 1 | 2 |\n",
        "intro\r\n| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n",
    }) |source| {
        const rendered = try render(a, source, .{ .columns = 60, .max_lines = 200, .ansi = false });
        defer release(a, rendered);
        const visible = try joined(a, rendered);
        defer a.free(visible);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, "┌"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, "└"));
    }
}

test "static grammar keeps list quote and fence negatives while releasing a following table" {
    try text.initLocale();
    const a = std.testing.allocator;
    // Original input coverage: a fenced block inside a list/quote must stay
    // literal, while the dedented paragraph and its immediately following table
    // are ordinary block content of the enclosing document.
    for ([_][]const u8{
        "- item\n  ```\n  intro\n  |literal|\n  |---|\n\n",
        "- item\n  ~~~\n  intro\n  |literal|\n  |---|\n  ~~~\n\n",
        "- outer\n  - inner\n    ```\n    intro\n    |literal|\n    |---|\n\n",
        "1. item\n   ```\n   intro\n   |literal|\n   |---|\n\n",
        "> ```\n> intro\n> |literal|\n> |---|\n\n",
        "- item\nlazy continuation\n  ```\n  intro\n  |literal|\n  |---|\n\n",
    }) |prefix| {
        const source = try std.fmt.allocPrint(a, "{s}After\n|a|\n|---|\n|b|\n", .{prefix});
        defer a.free(source);
        for ([_]bool{ false, true }) |ansi| {
            const rendered = try render(a, source, .{ .columns = 40, .max_lines = 128, .ansi = ansi });
            defer release(a, rendered);
            try std.testing.expect(!rendered.degraded);
            const visible = try joined(a, rendered);
            defer a.free(visible);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, "┌"));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, visible, "└"));
            try std.testing.expect(std.mem.indexOf(u8, visible, "|literal|") != null);
            try std.testing.expect(std.mem.indexOf(u8, visible, "|a|") == null);
            try std.testing.expect(std.mem.indexOf(u8, visible, "After") != null);
            try std.testing.expect(std.mem.indexOf(u8, visible, "literal") != null);
            for (rendered.lines) |line| try std.testing.expect(output.displayWidth(line) <= 40);
        }
    }
    // Escaped pipes stay inside one cell instead of creating a column.
    const escaped = try render(a, "| a \\| b | c |\n| --- | --- |\n| d | e |\n", .{ .columns = 40, .max_lines = 64, .ansi = false });
    defer release(a, escaped);
    try std.testing.expect(!escaped.degraded);
    const escaped_visible = try joined(a, escaped);
    defer a.free(escaped_visible);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, escaped_visible, "┌"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, escaped_visible, "┬"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, escaped_visible, "┴"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, escaped_visible, "└"));
    try std.testing.expect(std.mem.indexOf(u8, escaped_visible, "a | b") != null);
    for (escaped.lines) |line| try std.testing.expect(output.displayWidth(line) <= 40);
}

test "static grammar keeps existing tables inline code and HTML literal" {
    try text.initLocale();
    const a = std.testing.allocator;
    const existing = try render(a, "intro\n\n| H |\n| --- |\n| --- |\n| --- |\n", .{ .columns = 40, .max_lines = 128, .ansi = false });
    defer release(a, existing);
    const existing_visible = try joined(a, existing);
    defer a.free(existing_visible);
    try std.testing.expect(!existing.degraded);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, existing_visible, "┌"));
    try std.testing.expect(std.mem.indexOf(u8, existing_visible, "H") != null);
    // Original multiline inline-code negative, kept as actual input coverage.
    const code = try render(a, "intro `\n|a|\n|---|\n` end\n", .{ .columns = 40, .max_lines = 128, .ansi = false });
    defer release(a, code);
    const code_visible = try joined(a, code);
    defer a.free(code_visible);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, code_visible, "┌"));
    // NOHTMLBLOCKS/NOHTMLSPANS deliberately make tags ordinary safe text, not
    // opaque browser containers. Markdown inside them remains Markdown.
    const html = try render(a, "<div>\nintro\n|a|\n|---|\n|b|\n</div>\n", .{ .columns = 40, .max_lines = 128, .ansi = false });
    defer release(a, html);
    const html_visible = try joined(a, html);
    defer a.free(html_visible);
    try std.testing.expect(!html.degraded);
    try std.testing.expect(std.mem.indexOf(u8, html_visible, "<div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_visible, "</div>") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html_visible, "┌"));
    try std.testing.expect(std.mem.indexOf(u8, html_visible, "a") != null and std.mem.indexOf(u8, html_visible, "b") != null);
}

test "style and entity boundaries preserve conservative cluster wrapping widths" {
    try text.initLocale();
    const a = std.testing.allocator;
    for ([_][]const u8{ "x❤**&#xfe0f;**", "x❤**&#xfe0f;**y", "x👩**&#x200d;**💻", "x👍**&#x1f3fd;**", "x🇨**🇳**🇯", "xe**&#x301;**", "&#xfe0f;", "&#x200d;A", "> ❤**&#xfe0f;**", "- ❤**&#xfe0f;**", "| H |\n|---|\n| x❤**&#xfe0f;** |" }) |source| {
        for ([_]usize{ 1, 2, 3, 4, 8, 20 }) |columns| for ([_]bool{ false, true }) |ansi| {
            const rendered = try render(a, source, .{ .columns = columns, .max_lines = 100, .ansi = ansi });
            defer release(a, rendered);
            try std.testing.expect(!rendered.degraded);
            for (rendered.lines) |line| try std.testing.expect(output.displayWidth(line) <= columns);
        };
    }
    for ([_]bool{ false, true }) |ansi| {
        const rendered = try render(a, "x❤**&#xfe0f;**", .{ .columns = 2, .max_lines = 100, .ansi = ansi });
        defer release(a, rendered);
        try std.testing.expectEqual(@as(usize, 2), rendered.lines.len);
        const visible = try joined(a, rendered);
        defer a.free(visible);
        try std.testing.expect(std.mem.indexOf(u8, visible, "❤") != null and std.mem.indexOf(u8, visible, "️") != null);
    }
}

test "table geometry is unchanged by SGR trailing ZWJ and decoded variation entities" {
    try text.initLocale();
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), output.displayWidth("a‍\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 2), output.displayWidth("❤\x1b[1m️\x1b[0m"));
    for ([_]bool{ false, true }) |ansi| {
        const r = try render(a, "| H |\n|---|\n| a‍ |", .{ .columns = 12, .max_lines = 100, .ansi = ansi });
        defer release(a, r);
        try std.testing.expect(!r.degraded);
        for (r.lines) |line| try std.testing.expectEqual(@as(usize, 5), output.displayWidth(line));
        const one = try render(a, "| H |\n|---|\n| ❤️xyz |", .{ .columns = 8, .max_lines = 100, .ansi = ansi });
        defer release(a, one);
        const two = try render(a, "| H |\n|---|\n| ❤&#xfe0f;xyz |", .{ .columns = 8, .max_lines = 100, .ansi = ansi });
        defer release(a, two);
        try std.testing.expect(!one.degraded and !two.degraded);
        try std.testing.expectEqual(one.lines.len, two.lines.len);
        for (one.lines, two.lines) |literal, decoded| try std.testing.expectEqualStrings(literal, decoded);
    }
}

test "Markdown depth limit degrades visibly without exposing entity controls" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    for (0..140) |_| try source.appendSlice(a, "> ");
    try source.appendSlice(a, "payload &#27;[2J");
    const r = try render(a, source.items, .{ .columns = 40, .max_lines = 100 });
    defer release(a, r);
    try std.testing.expect(r.degraded);
    const s = try joined(a, r);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Markdown complexity limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[2J") == null);
}

test "partial Markdown keeps unmatched delimiters and fences visible" {
    const a = std.testing.allocator;
    const r = try render(a, "**unfinished [link](\n~~~\n x", .{ .columns = 40, .max_lines = 20, .ansi = false });
    defer release(a, r);
    try std.testing.expectEqualStrings("**unfinished [link](", r.lines[0]);
    try std.testing.expectEqualStrings(" x", r.lines[r.lines.len - 1]);
    const plain = try render(a, "# **raw**\\x", .{ .columns = 40, .max_lines = 20, .ansi = false, .markdown = false });
    defer release(a, plain);
    try std.testing.expectEqualStrings("# **raw**\\x", plain.lines[0]);
}

test "Markdown widths hostile entities clusters and renderer owned colors" {
    try text.initLocale();
    const a = std.testing.allocator;
    for ([_]usize{ 1, 40, 80, 120 }) |cols| for ([_]bool{ false, true }) |ansi| {
        const r = try render(a, "# 中é 👩‍💻\n\n**bold** `code` *it* [link](https://example.org)\n\n&#27;[2J &#x202e; &lrm;\n\n<script>bad</script>\n\n```\ncode\n```", .{ .columns = cols, .max_lines = 500, .ansi = ansi });
        defer release(a, r);
        try std.testing.expect(!r.degraded);
        for (r.lines) |line| {
            try std.testing.expect(std.unicode.utf8ValidateSlice(line));
            try std.testing.expect(output.displayWidth(line) <= cols);
            try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[2J") == null);
            try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\x80\xae") == null);
            if (!ansi) try std.testing.expect(std.mem.indexOfScalar(u8, line, 27) == null);
        }
    };
}

test "Markdown viewport caps empty documents and pathological brackets" {
    const a = std.testing.allocator;
    const empty = try render(a, "", .{ .columns = 40, .max_lines = 1, .ansi = false });
    defer release(a, empty);
    try std.testing.expectEqualStrings("", empty.lines[0]);
    const r = try render(a, "0\n1\n2\n3\n4", .{ .columns = 0, .max_lines = 2, .ansi = false });
    defer release(a, r);
    try std.testing.expectEqualStrings("3", r.lines[0]);
    try std.testing.expectEqualStrings("4", r.lines[1]);
    const away = try render(a, "one\ntwo", .{ .columns = 40, .max_lines = 0 });
    defer release(a, away);
    try std.testing.expectEqual(@as(usize, 0), away.lines.len);
    try std.testing.expect(away.total_lines > 0);
    const brackets: [65536]u8 = @splat('[');
    const b = try render(a, &brackets, .{ .columns = 80, .max_lines = 20, .ansi = false });
    defer release(a, b);
    try std.testing.expectEqual(@as(usize, 820), b.total_lines);
    const big = try a.alloc(u8, limit + 1);
    defer a.free(big);
    @memset(big, 'x');
    const bounded = try render(a, big, .{ .columns = 9999, .max_lines = 99999, .ansi = false });
    defer release(a, bounded);
    try std.testing.expect(bounded.truncated and bounded.lines.len <= 8192);
}

// Unfrozen-window oracle: while nothing has been released, a streamed window
// must be byte-identical to the batch renderer. This is the compatibility
// check for the resume/context machinery; after a freeze, divergence is
// explicitly allowed (the frozen rows are never regenerated).
test "streamed window matches the batch renderer inside an unfrozen window" {
    try text.initLocale();
    const a = std.testing.allocator;
    const docs = [_][]const u8{
        "plain paragraph\nwrapped line\n\nsecond paragraph",
        "# Heading\n\n**bold** _em_ `code` ~~gone~~ [l](https://e.org)\n",
        "> quote\n> - nested item\n>   lazy\n\n1. one\n2. two\n",
        "```zig\nlet x = 1; // *literal*\n```\n\nafter",
        "\n| Name | Value |\n| :--- | ---: |\n| alpha | 12 |\n",
        "see [r]\n\n[r]: https://example.org/path\n\n&amp; &#x4e2d;",
        "| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n",
    };
    for (docs) |doc| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const window = try renderWindow(aa, doc, .{ .columns = 40, .ansi = false, .max_rows = 4096 });
        const batch = try render(aa, doc, .{ .columns = 40, .max_lines = 4096, .ansi = false });
        try std.testing.expectEqual(batch.lines.len, window.rows.len);
        for (batch.lines, window.rows) |expected, row| try std.testing.expectEqualStrings(expected, row.text);
        // Provenance never points outside the parsed source and never marks a
        // synthetic row with a fabricated source span.
        for (window.rows) |row| {
            if (row.synthetic) {
                try std.testing.expectEqual(std.math.maxInt(usize), row.start);
            } else {
                try std.testing.expect(row.end > row.start);
                try std.testing.expect(row.end <= doc.len);
            }
        }
    }
}

test "container table fragment keeps a mid-cell literal marker and strips later row prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const containers = [_]md.TableContainer{.{ .mark = '>', .mark_indent = 0, .contents_indent = 2 }};
    // The window starts mid-cell of column 0: the container prefix was already
    // consumed by an earlier ACK, so the very first byte (a literal '>') belongs
    // to the cell and must never be treated as container syntax. Every later
    // physical row still strips its own real prefix.
    const window = try renderWindow(a, "> literal | tail |\n> | next | row |\n", .{
        .columns = 40,
        .ansi = false,
        .streaming_tables = true,
        .final = true,
        .table = .{
            .columns = 2,
            .alignments = @splat(0),
            .partial_cell = true,
            .first_line_partial = true,
            .containers = &containers,
            .header_done = true,
            .top_done = true,
        },
        .table_fragment = true,
    });
    var joined_window: std.ArrayList(u8) = .empty;
    defer joined_window.deinit(a);
    for (window.rows) |row| {
        try joined_window.appendSlice(a, row.text);
        try joined_window.append(a, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, joined_window.items, "> literal") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined_window.items, "tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined_window.items, "next") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined_window.items, "row") != null);
    // No cell contains the container marker and no row was closed early.
    try std.testing.expect(std.mem.indexOf(u8, joined_window.items, "│ > literal") != null);
    try std.testing.expect(!window.table_closed);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, joined_window.items, "┌"));
    // True EOF closes the already-established table with exactly one bottom rule.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, joined_window.items, "└"));
}

test "inline fragments keep block markers literal and preserve inline styling" {
    try text.initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { fragment: []const u8, batch: []const u8, plain: []const u8 }{
        .{ .fragment = "# literal **bold**", .batch = "\\# literal **bold**", .plain = "# literal bold" },
        .{ .fragment = "- literal **bold**", .batch = "\\- literal **bold**", .plain = "- literal bold" },
        .{ .fragment = "``` literal **bold**", .batch = "\\`\\`\\` literal **bold**", .plain = "``` literal bold" },
        .{ .fragment = "| a | **bold**", .batch = "| a | **bold**", .plain = "| a | bold" },
    };
    for (cases) |case| {
        const plain = try renderWindow(a, case.fragment, .{ .columns = 80, .ansi = false, .fragment = .{ .kind = .heading } });
        try std.testing.expectEqual(@as(usize, 1), plain.rows.len);
        try std.testing.expectEqualStrings(case.plain, plain.rows[0].text);
        try std.testing.expectEqual(LeafKind.heading, plain.leaves[0].kind);
        try std.testing.expectEqual(LeafKind.heading, plain.end.kind);
        try std.testing.expect(plain.leaf_open);
        const styled = try renderWindow(a, case.fragment, .{ .columns = 80, .ansi = true, .fragment = .{ .kind = .paragraph } });
        const expected = try renderWindow(a, case.batch, .{ .columns = 80, .ansi = true });
        try std.testing.expectEqual(expected.rows.len, styled.rows.len);
        try std.testing.expectEqualStrings(expected.rows[0].text, styled.rows[0].text);
    }
}

test "inline fragment line breaks match native paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "one\ntwo", "one  \ntwo", "one\\\ntwo" }) |source| {
        const fragment = try renderWindow(a, source, .{ .columns = 80, .ansi = true, .fragment = .{ .kind = .paragraph } });
        const batch = try renderWindow(a, source, .{ .columns = 80, .ansi = true });
        try std.testing.expectEqual(batch.rows.len, fragment.rows.len);
        for (batch.rows, fragment.rows) |expected, actual| try std.testing.expectEqualStrings(expected.text, actual.text);
    }
}

test "window context replay restores containers without re-emitting frozen rows" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // A resumed paragraph inside a list item: context line opens the item, and
    // the sentinel row itself must not appear in the output.
    const ctx = LeafCtx{ .kind = .paragraph, .prefix = "- ", .continuation = "  " };
    const input = "- \x01\ncontinuation text\n  indented still item\n";
    const window = try renderWindow(arena.allocator(), input, .{ .columns = 40, .ansi = false, .context_bytes = "- \x01\n".len, .max_rows = 64 });
    try std.testing.expect(window.rows.len >= 2);
    var joined_window: std.ArrayList(u8) = .empty;
    defer joined_window.deinit(a);
    for (window.rows) |row| {
        try joined_window.appendSlice(a, row.text);
        try joined_window.append(a, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, joined_window.items, "\x01") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined_window.items, "continuation text") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined_window.items, "indented still item") != null);
    _ = ctx;
}
