//! CommonMark + GFM terminal rendering through vendored MD4C, not regex toggles.
//! Images/HTML/math have textual fallbacks, never fetch URLs or execute markup.
const std = @import("std");
const text = @import("text.zig");
const md = @import("md4c.zig");
const output = @import("markdown_writer.zig");
const Allocator = std.mem.Allocator;
const Writer = output.Writer;
const Style = output.Style;
pub const Tone = output.Tone;
pub const Options = struct { columns: usize, max_lines: usize, scroll_from_end: usize = 0, ansi: bool = true, markdown: bool = true, tone: Tone = .normal };
pub const Rendered = struct { lines: []const []const u8, total_lines: usize, truncated: bool, degraded: bool = false };
const limit = 256 * 1024;

const Frame = struct { kind: c_int, style: Style, prefix: []const u8, continuation: ?[]const u8, next: usize = 1, children: usize = 0 };
const Cell = struct { lines: []const []const u8, alignment: c_int };
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
};

const Renderer = struct {
    w: Writer,
    blocks: [128]Frame = undefined,
    depth: usize = 0,
    spans: [128]Style = undefined,
    span_depth: usize = 0,
    table: ?Table = null,
    failure: ?anyerror = null,
    pending_text: std.ArrayList(u8) = .empty,

    // Text/entity callbacks are transport chunks, not grapheme boundaries.
    // Buffer a style run so FE0F/combining/ZWJ decode exactly like literal text.
    fn bufferText(self: *Renderer, s: []const u8) !void {
        try self.step(s.len);
        try self.pending_text.appendSlice(self.w.a, s);
    }

    fn flushText(self: *Renderer) !void {
        if (self.pending_text.items.len == 0) return;
        try self.w.emit(self.pending_text.items);
        self.pending_text.clearRetainingCapacity();
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
        if (self.depth == self.blocks.len) return error.MarkdownDepthLimit;
        // Separate sibling text blocks, but do not insert gaps into tight list
        // items or table cells. Empty parent items still need a visible bullet.
        if (self.depth != 0 and (kind == 1 or kind == 2 or kind == 3 or kind == 5 or kind == 6 or kind == 7 or kind == 9 or kind == 10)) {
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
                const columns = detail(md.Table, raw).columns;
                if (columns == 0 or columns > 32 or self.table != null) return error.MarkdownTableLimit;
                const available = self.w.columns -| @min(text.width(self.w.prefix), self.w.columns - 1);
                // Narrow tables degrade to stacked cells rather than losing data.
                const stacked = available < 6 * columns + 1;
                const width = if (stacked) available else (available - 3 * columns - 1) / columns;
                self.table = .{ .main = self.w, .columns = columns, .cell_width = @max(1, width), .stacked = stacked };
            },
            11, 12 => {}, // table head/body
            13 => {
                if (self.table.?.rows.items.len >= 2048) return error.MarkdownTableLimit;
                self.table.?.cells = .empty;
                self.table.?.header = false;
            },
            14, 15 => {
                const table = &self.table.?;
                table.header = kind == 14;
                table.alignment = detail(md.Td, raw).alignment;
                self.w = .{ .a = table.main.a, .columns = table.cell_width, .ansi = table.main.ansi, .base = table.main.base, .style = if (kind == 14) .{ .tone = .table_header, .bold = true } else .{}, .budget = table.main.budget };
            },
            else => return error.InvalidMarkdownBlock,
        }
    }

    fn leaveBlock(self: *Renderer, kind: c_int) !void {
        try self.flushText();
        try self.step(1);
        if (self.depth == 0) return error.InvalidMarkdownBlock;
        self.depth -= 1;
        const frame = self.blocks[self.depth];
        if (frame.kind != kind) return error.InvalidMarkdownBlock;
        switch (kind) {
            0 => {
                try self.w.boundary();
                if (self.w.lines.items.len == 0) try self.w.finish();
            },
            14, 15 => {
                try self.w.boundary();
                if (self.w.lines.items.len == 0) try self.w.finish();
                const table = &self.table.?;
                try table.cells.append(self.w.a, .{ .lines = try self.w.lines.toOwnedSlice(self.w.a), .alignment = table.alignment });
                self.w = table.main;
            },
            13 => {
                const table = &self.table.?;
                try table.rows.append(self.w.a, .{ .cells = try table.cells.toOwnedSlice(self.w.a), .header = table.header });
            },
            10 => try self.flushTable(),
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
    }

    fn flushTable(self: *Renderer) !void {
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
        for (table.rows.items, 0..) |row, row_index| {
            try self.w.setStyle(.{ .tone = .border });
            var height: usize = 1;
            for (row.cells) |cell| height = @max(height, cell.lines.len);
            for (0..height) |line_index| {
                try self.w.emit("│ ");
                for (row.cells, 0..) |cell, col| {
                    const line = if (line_index < cell.lines.len) cell.lines[line_index] else "";
                    const padding = widths[col] - output.displayWidth(line);
                    const before = if (cell.alignment == 3) padding else if (cell.alignment == 2) padding / 2 else 0;
                    for (0..before) |_| try self.w.emit(" ");
                    try self.w.emitStyled(line);
                    for (0..padding - before) |_| try self.w.emit(" ");
                    try self.w.emit(" │");
                    if (col + 1 < row.cells.len) try self.w.emit(" ");
                }
                try self.w.finish();
            }
            // Separate logical rows, not every physical line of a wrapped cell.
            try self.tableRule(widths[0..table.columns], if (row_index + 1 == table.rows.items.len) .bottom else .middle, row.header);
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
        try self.flushText();
        try self.step(1);
        try self.spanAttributeWork(kind, raw);
        if (self.span_depth == self.spans.len) return error.MarkdownDepthLimit;
        self.spans[self.span_depth] = self.w.style;
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
        // MD4C consumes math delimiters; the terminal fallback is literal text,
        // not a TeX engine, so keep both delimiters and the raw formula visible.
        if (kind == 6 or kind == 7) try self.w.emit(if (kind == 6) "$" else "$$");
    }

    fn leaveSpan(self: *Renderer, kind: c_int, raw: ?*anyopaque) !void {
        try self.flushText();
        try self.step(1);
        try self.spanAttributeWork(kind, raw);
        if (self.span_depth == 0) return error.InvalidMarkdownSpan;
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
        self.span_depth -= 1;
        try self.w.setStyle(self.spans[self.span_depth]);
    }

    fn codepoint(self: *Renderer, value: u32, buffered: bool) !void {
        const cp: u21 = if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) 0xfffd else @intCast(value);
        var buffer: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buffer);
        // Entity decoding must not reintroduce ESC, bidi or other controls.
        const safe = try text.sanitize(self.w.a, buffer[0..n], 12);
        if (buffered) try self.bufferText(safe) else try self.w.emit(safe);
    }

    fn entity(self: *Renderer, s: []const u8, buffered: bool) !void {
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

    fn content(self: *Renderer, kind: c_int, s: []const u8) !void {
        try self.step(1);
        switch (kind) {
            1 => try self.bufferText("�"),
            2, 3 => {
                try self.flushText();
                try self.w.finish();
            },
            4 => try self.entity(s, true),
            else => try self.bufferText(s),
        }
    }

    fn selfFrom(raw: ?*anyopaque) *Renderer {
        return @ptrCast(@alignCast(raw.?));
    }
    // Keep native -1 exclusively for parser OOM; callbacks carry their Zig
    // error separately and never allow later callbacks to overwrite it.
    const callback_abort: c_int = -2;
    fn failed(self: *Renderer, err: anyerror) c_int {
        if (self.failure == null) self.failure = err;
        return callback_abort;
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

fn tableCells(line: []const u8, delimiter: bool) ?usize {
    var indent: usize = 0;
    for (line) |byte| {
        if (byte == ' ') indent += 1 else if (byte == '\t') indent += 4 - indent % 4 else break;
        if (indent > 3) return null;
    }
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3 or trimmed[0] != '|' or trimmed[trimmed.len - 1] != '|') return null;
    if (!delimiter) {
        var count: usize = 0;
        var escaped = false;
        for (trimmed) |byte| {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '|') count += 1;
        }
        return if (count >= 2 and count <= 33) count - 1 else null;
    }
    var parts = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], '|');
    var count: usize = 0;
    while (parts.next()) |part| {
        var marks = std.mem.trim(u8, part, " \t");
        if (marks.len != 0 and marks[0] == ':') marks = marks[1..];
        if (marks.len != 0 and marks[marks.len - 1] == ':') marks = marks[0 .. marks.len - 1];
        if (marks.len < 3) return null;
        for (marks) |byte| if (byte != '-') return null;
        count += 1;
        if (count > 32) return null;
    }
    return if (count != 0) count else null;
}

const TableCandidate = struct { start: usize, end: usize, protected: bool = false };

/// Use the parser's actual container grammar, not a second fence/list parser.
/// CODE/HTML text and existing TABLE cells protect intersecting candidate lines.
/// Callback source pointers are inspected only when they lie in this input;
/// synthetic spaces/newlines supplied by MD4C are never dereferenced here.
const TableGuard = struct {
    source: []const u8,
    candidates: []TableCandidate,
    budget: *output.Budget,
    candidate_index: usize = 0,
    table_depth: usize = 0,
    failure: ?anyerror = null,

    fn selfFrom(raw: ?*anyopaque) *TableGuard {
        return @ptrCast(@alignCast(raw.?));
    }
    fn failed(self: *TableGuard, err: anyerror) c_int {
        if (self.failure == null) self.failure = err;
        return 1;
    }
    fn enterBlock(kind: c_int, _: ?*anyopaque, raw: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(raw);
        self.budget.step(1) catch |err| return self.failed(err);
        if (kind == 10) self.table_depth += 1;
        return 0;
    }
    fn leaveBlock(kind: c_int, _: ?*anyopaque, raw: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(raw);
        self.budget.step(1) catch |err| return self.failed(err);
        if (kind == 10) self.table_depth -= 1;
        return 0;
    }
    fn span(_: c_int, _: ?*anyopaque, raw: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(raw);
        self.budget.step(1) catch |err| return self.failed(err);
        return 0;
    }
    fn content(kind: c_int, ptr: [*]const u8, size: c_uint, raw: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(raw);
        self.budget.step(@as(usize, size) + 1) catch |err| return self.failed(err);
        if (self.table_depth == 0 and kind != 5 and kind != 6) return 0;
        const base = @intFromPtr(self.source.ptr);
        const address = @intFromPtr(ptr);
        if (address < base or address - base >= self.source.len) return 0;
        const start = address - base;
        if (size == 0 or size > self.source.len - start) return 0;
        const end = start + size;
        // Parser text traverses CODE/HTML/TABLE source in document order.
        while (self.candidate_index < self.candidates.len and self.candidates[self.candidate_index].end <= start) self.candidate_index += 1;
        var i = self.candidate_index;
        while (i < self.candidates.len and self.candidates[i].start < end) : (i += 1) {
            self.budget.step(1) catch |err| return self.failed(err);
            self.candidates[i].protected = true;
        }
        return 0;
    }
};

/// Pi recognizes pipe tables directly after prose. Normalize only strict flat
/// pairs outside parser-confirmed code/HTML/existing tables; history is untouched.
/// Candidates and output are bounded by the 256 KiB input, with linear scanning
/// and all parser callbacks charged to the unchanged shared work budget.
fn tableBreaks(a: Allocator, source: []const u8, budget: *output.Budget) ![]const u8 {
    try budget.step(source.len);
    var candidates: std.ArrayList(TableCandidate) = .empty;
    defer candidates.deinit(a);
    var position: usize = 0;
    var previous: []const u8 = "";
    while (position < source.len) {
        const end = if (std.mem.indexOfScalar(u8, source[position..], '\n')) |offset| position + offset else source.len;
        const line = source[position..end];
        const next = end + @intFromBool(end < source.len);
        const next_end = if (std.mem.indexOfScalar(u8, source[next..], '\n')) |offset| next + offset else source.len;
        if (std.mem.trim(u8, previous, " \t").len != 0) {
            if (tableCells(line, false)) |cells| {
                if (tableCells(source[next..next_end], true)) |delimiters| {
                    if (cells == delimiters) try candidates.append(a, .{ .start = position, .end = next_end });
                }
            }
        }
        previous = line;
        position = next;
    }
    if (candidates.items.len == 0) return a.dupe(u8, source);
    var guard = TableGuard{ .source = source, .candidates = candidates.items, .budget = budget };
    const parser: md.Parser = .{ .enter_block = TableGuard.enterBlock, .leave_block = TableGuard.leaveBlock, .enter_span = TableGuard.span, .leave_span = TableGuard.span, .text = TableGuard.content };
    const parsed = md.md_parse(source.ptr, @intCast(source.len), &parser, &guard);
    if (parsed == -1) return error.OutOfMemory;
    if (guard.failure) |failure| return failure;
    if (parsed != 0) return error.MarkdownRenderLimit;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    position = 0;
    for (candidates.items) |candidate| {
        if (candidate.protected) continue;
        try result.appendSlice(a, source[position..candidate.start]);
        try result.append(a, '\n');
        position = candidate.start;
    }
    try result.appendSlice(a, source[position..]);
    return result.toOwnedSlice(a);
}

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
        const normalized = tableBreaks(scratch, clean, &budget) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            renderer.failure = err;
            break :blk clean;
        };
        const result = if (renderer.failure != null) Renderer.callback_abort else md.md_parse(normalized.ptr, @intCast(normalized.len), &parser, &renderer);
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
    const end = total - @min(total, options.scroll_from_end);
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

pub fn release(a: Allocator, rendered: Rendered) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}

fn joined(a: Allocator, rendered: Rendered) ![]const u8 {
    return std.mem.join(a, "\n", rendered.lines);
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
    for ([_][]const u8{ "\x1b[1m\x1b[38;5;220m\x1b[1m\x1b[4mHeading", "\x1b[4m\x1b[38;5;12mlabel", "\x1b[38;5;141minline", "\x1b[38;5;83mcode", "\x1b[38;5;141m-" }) |style| try std.testing.expect(std.mem.indexOf(u8, s, style) != null);
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
    const page = try render(a, source, .{ .columns = 40, .max_lines = 2, .scroll_from_end = 1, .ansi = false });
    defer release(a, page);
    try std.testing.expectEqual(@as(usize, 7), page.total_lines);
    try std.testing.expectEqualStrings(r.lines[4], page.lines[0]);
    try std.testing.expectEqualStrings(r.lines[5], page.lines[1]);
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

test "table compatibility never inserts breaks in mixed space tab code indentation" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "    intro\n \t|a|\n \t|---|\n \t|body|\n", "    intro\n  \t|a|\n  \t|---|\n", "intro\n|a|\n \t|---|\n", "```\nintro\n|a|\n|---|\n```\n" }) |source| {
        var budget: output.Budget = .{};
        const normalized = try tableBreaks(a, source, &budget);
        defer a.free(normalized);
        try std.testing.expectEqualStrings(source, normalized);
    }
}

test "list fenced table shapes remain unchanged and following flat tables normalize" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "-", "*", "+", "1.", "23)" }) |marker| for ([_][]const u8{ "```", "~~~" }) |fence| {
        const padding = try a.alloc(u8, marker.len + 1);
        defer a.free(padding);
        @memset(padding, ' ');
        const source = try std.fmt.allocPrint(a, "{s} {s}\n{s}intro\n{s}|a|\n{s}|---|\n{s}{s}\n\nAfter\n|b|\n|---|\n|c|\n", .{ marker, fence, padding, padding, padding, padding, fence });
        defer a.free(source);
        const expected = try std.fmt.allocPrint(a, "{s} {s}\n{s}intro\n{s}|a|\n{s}|---|\n{s}{s}\n\nAfter\n\n|b|\n|---|\n|c|\n", .{ marker, fence, padding, padding, padding, padding, fence });
        defer a.free(expected);
        var budget: output.Budget = .{};
        const normalized = try tableBreaks(a, source, &budget);
        defer a.free(normalized);
        try std.testing.expectEqualStrings(expected, normalized);
    };
    for ([_][]const u8{ "```\n- ```\n|a|\n|---|\n```\n", "- ```\n\tintro\n  |a|\n  |---|\n  ```\n" }) |source| {
        var budget: output.Budget = .{};
        const normalized = try tableBreaks(a, source, &budget);
        defer a.free(normalized);
        try std.testing.expectEqualStrings(source, normalized);
    }
}

test "parser confirmed continuation and nested containers preserve code and release following tables" {
    try text.initLocale();
    const a = std.testing.allocator;
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
        const expected = try std.fmt.allocPrint(a, "{s}After\n\n|a|\n|---|\n|b|\n", .{prefix});
        defer a.free(expected);
        var budget: output.Budget = .{};
        const normalized = try tableBreaks(a, source, &budget);
        defer a.free(normalized);
        try std.testing.expectEqualStrings(expected, normalized);
        for ([_]bool{ false, true }) |ansi| {
            const rendered = try render(a, source, .{ .columns = 40, .max_lines = 128, .ansi = ansi });
            defer release(a, rendered);
            const visible = try joined(a, rendered);
            defer a.free(visible);
            try std.testing.expect(!rendered.degraded);
            try std.testing.expect(std.mem.indexOf(u8, visible, "┌") != null);
            for (rendered.lines) |line| try std.testing.expect(output.displayWidth(line) <= 40);
        }
    }
}

test "normalization preserves existing tables and inline code while HTML remains literal" {
    try text.initLocale();
    const a = std.testing.allocator;
    for ([_][]const u8{
        "intro\n\n| H |\n| --- |\n| --- |\n| --- |\n",
        "intro `\n|a|\n|---|\n` end\n",
    }) |source| {
        var budget: output.Budget = .{};
        const normalized = try tableBreaks(a, source, &budget);
        defer a.free(normalized);
        try std.testing.expectEqualStrings(source, normalized);
    }
    // NOHTMLBLOCKS/NOHTMLSPANS deliberately make tags ordinary safe text,
    // not opaque browser containers. Markdown inside them remains Markdown.
    const html = "<div>\nintro\n|a|\n|---|\n|b|\n</div>\n";
    var budget: output.Budget = .{};
    const normalized = try tableBreaks(a, html, &budget);
    defer a.free(normalized);
    try std.testing.expectEqualStrings("<div>\nintro\n\n|a|\n|---|\n|b|\n</div>\n", normalized);
    const rendered = try render(a, html, .{ .columns = 40, .max_lines = 128, .ansi = false });
    defer release(a, rendered);
    const visible = try joined(a, rendered);
    defer a.free(visible);
    try std.testing.expect(!rendered.degraded);
    try std.testing.expect(std.mem.indexOf(u8, visible, "<div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "┌") != null);
}

fn normalizationAllocationCheck(a: Allocator) !void {
    var budget: output.Budget = .{};
    const result = try tableBreaks(a, "- item\n  ```\n  |literal|\n  |---|\n\nAfter\n|a|\n|---|\n|b|\n", &budget);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "After\n\n|a|") != null);
}

test "normalization candidate ownership survives every allocator failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, normalizationAllocationCheck, .{});
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
    const r = try render(a, "0\n1\n2\n3\n4", .{ .columns = 0, .max_lines = 2, .scroll_from_end = 1, .ansi = false });
    defer release(a, r);
    try std.testing.expectEqualStrings("2", r.lines[0]);
    try std.testing.expectEqualStrings("3", r.lines[1]);
    const away = try render(a, "one\ntwo", .{ .columns = 40, .max_lines = 10, .scroll_from_end = 999 });
    defer release(a, away);
    try std.testing.expectEqual(@as(usize, 0), away.lines.len);
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
