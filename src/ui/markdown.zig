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
            if (parent.kind == 4 and kind != 9 and self.w.continuation != null and self.w.col == 0) try self.w.emit(" ");
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
                for (0..self.w.columns -| @min(text.width(self.w.prefix), self.w.columns - 1)) |_| try self.w.emit("-");
            },
            6 => {
                try self.w.boundary();
                try self.w.setStyle(.{ .tone = .heading, .bold = true });
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
                self.w = .{ .a = table.main.a, .columns = table.cell_width, .ansi = table.main.ansi, .base = table.main.base, .style = if (kind == 14) .{ .tone = .heading, .bold = true } else .{}, .budget = table.main.budget };
            },
            else => return error.InvalidMarkdownBlock,
        }
    }

    fn leaveBlock(self: *Renderer, kind: c_int) !void {
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
                if (self.w.continuation != null and self.w.col == 0) try self.w.emit(" ");
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
        for (table.rows.items) |row| {
            var height: usize = 1;
            for (row.cells) |cell| height = @max(height, cell.lines.len);
            for (0..height) |line_index| {
                try self.w.emit("| ");
                for (row.cells, 0..) |cell, col| {
                    const line = if (line_index < cell.lines.len) cell.lines[line_index] else "";
                    const padding = widths[col] - output.displayWidth(line);
                    const before = if (cell.alignment == 3) padding else if (cell.alignment == 2) padding / 2 else 0;
                    for (0..before) |_| try self.w.emit(" ");
                    try self.w.emitStyled(line);
                    for (0..padding - before) |_| try self.w.emit(" ");
                    try self.w.emit(" |");
                    if (col + 1 < row.cells.len) try self.w.emit(" ");
                }
                try self.w.finish();
            }
            if (row.header) {
                try self.w.setStyle(.{ .tone = .quote });
                try self.w.emit("|");
                for (widths[0..table.columns]) |width| {
                    for (0..width + 2) |_| try self.w.emit("-");
                    try self.w.emit("|");
                }
                try self.w.finish();
                try self.w.setStyle(.{});
            }
        }
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
            4, 6, 7 => style.tone = .code,
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
        try self.step(1);
        try self.spanAttributeWork(kind, raw);
        if (self.span_depth == 0) return error.InvalidMarkdownSpan;
        if (kind == 6 or kind == 7) try self.w.emit(if (kind == 6) "$" else "$$");
        if (kind == 3) try self.w.emit("]");
        if ((kind == 2 and detail(md.Link, raw).autolink == 0) or kind == 3) {
            const target = if (kind == 2) detail(md.Link, raw).href else detail(md.Image, raw).src;
            if (target.size != 0) {
                try self.w.emit(" (");
                try self.attribute(target);
                try self.w.emit(")");
            }
        }
        self.span_depth -= 1;
        try self.w.setStyle(self.spans[self.span_depth]);
    }

    fn codepoint(self: *Renderer, value: u32) !void {
        const cp: u21 = if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) 0xfffd else @intCast(value);
        var buffer: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buffer);
        // Entity decoding must not reintroduce ESC, bidi or other controls.
        const safe = try text.sanitize(self.w.a, buffer[0..n], 12);
        try self.w.emit(safe);
    }

    fn entity(self: *Renderer, s: []const u8) !void {
        if (s.len > 3 and s[1] == '#') {
            const hex = s[2] == 'x' or s[2] == 'X';
            const n = std.fmt.parseInt(u32, s[if (hex) @as(usize, 3) else 2 .. s.len - 1], if (hex) 16 else 10) catch 0xfffd;
            try self.codepoint(n);
        } else if (md.entity_lookup(s.ptr, s.len)) |value| {
            try self.codepoint(value.codepoints[0]);
            if (value.codepoints[1] != 0) try self.codepoint(value.codepoints[1]);
        } else try self.w.emit(s);
    }

    fn attribute(self: *Renderer, value: md.Attribute) !void {
        if (value.size == 0) return;
        const s = value.text.?[0..value.size];
        var i: usize = 0;
        while (value.offsets.?[i] < value.size) : (i += 1) {
            const part = s[value.offsets.?[i]..value.offsets.?[i + 1]];
            if (value.types.?[i] == 4) try self.entity(part) else if (value.types.?[i] == 1) try self.w.emit("�") else try self.w.emit(part);
        }
    }

    fn content(self: *Renderer, kind: c_int, s: []const u8) !void {
        try self.step(1);
        switch (kind) {
            1 => try self.w.emit("�"),
            2, 3 => try self.w.finish(),
            4 => try self.entity(s),
            else => try self.w.emit(s),
        }
    }

    fn selfFrom(raw: ?*anyopaque) *Renderer {
        return @ptrCast(@alignCast(raw.?));
    }
    fn enterBlockCb(kind: c_int, raw: ?*anyopaque, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        self.enterBlock(kind, raw) catch |err| {
            self.failure = err;
            return 1;
        };
        return 0;
    }
    fn leaveBlockCb(kind: c_int, _: ?*anyopaque, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        self.leaveBlock(kind) catch |err| {
            self.failure = err;
            return 1;
        };
        return 0;
    }
    fn enterSpanCb(kind: c_int, raw: ?*anyopaque, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        self.enterSpan(kind, raw) catch |err| {
            self.failure = err;
            return 1;
        };
        return 0;
    }
    fn leaveSpanCb(kind: c_int, raw: ?*anyopaque, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        self.leaveSpan(kind, raw) catch |err| {
            self.failure = err;
            return 1;
        };
        return 0;
    }
    fn textCb(kind: c_int, ptr: [*]const u8, size: c_uint, context: ?*anyopaque) callconv(.c) c_int {
        const self = selfFrom(context);
        self.content(kind, ptr[0..size]) catch |err| {
            self.failure = err;
            return 1;
        };
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
        const result = md.md_parse(clean.ptr, @intCast(clean.len), &parser, &renderer);
        if (result != 0) {
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
        w.line = .empty;
        w.col = 0;
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
    var budget: output.Budget = .{ .max_work = 14 };
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
    const r = try render(a, "# Heading\n\n**bold** `inline` [label](https://example.org)\n\n> quote\n\n```\ncode\n```", .{ .columns = 80, .max_lines = 100 });
    defer release(a, r);
    const s = try joined(a, r);
    defer a.free(s);
    for ([_][]const u8{ theme.heading, theme.strong, theme.code, theme.quote, theme.link }) |color| try std.testing.expect(std.mem.indexOf(u8, s, color) != null);
    try @import("../tests/regular_screen.zig").rejectFullscreen(s);
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
