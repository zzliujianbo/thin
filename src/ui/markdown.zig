//! 中文：终端 Markdown 渲染器。把输入文本按行转换为带 ANSI 样式、已按列宽换行的显示行。

const std = @import("std");
const text = @import("text.zig");
const Allocator = std.mem.Allocator;

/// 渲染选项：列宽、视口最多行数、从末尾向上滚动的行数，以及是否启用 ANSI 样式和 Markdown 解析。
pub const Options = struct { columns: usize, max_lines: usize, scroll_from_end: usize = 0, ansi: bool = true, markdown: bool = true };

/// 渲染结果：lines 为视口内的行（需用 release 释放），total_lines 为文档总行数，truncated 表示输入超过上限。
pub const Rendered = struct { lines: []const []const u8, total_lines: usize, truncated: bool };

/// 单次渲染的输入字节上限（256 KiB），保证工作量与内存有界。
const limit = 256 * 1024;

/// 行写入器：把簇逐个写入当前行，负责列宽换行与 SGR 样式。
const Writer = struct {
    /// 临时分配器（scratch arena）。
    a: Allocator,
    /// 当前行的列宽上限，用于换行判断。
    columns: usize,
    /// 是否输出 ANSI 样式；关闭时只输出纯文本。
    ansi: bool,
    /// 已完成的输出行；line 为正在构建的当前行。
    lines: std.ArrayList([]const u8) = .empty,
    line: std.ArrayList(u8) = .empty,
    col: usize = 0,
    /// 样式位：1=粗体，2=斜体，4=青色（代码与引用）。
    style: u8 = 0,

    /// 输出当前 style 对应的 SGR 序列：先 reset，再逐项叠加，避免残留样式。
    fn sgr(self: *Writer) !void {
        if (!self.ansi) return;
        try self.line.appendSlice(self.a, "\x1b[0m");
        if (self.style & 1 != 0) try self.line.appendSlice(self.a, "\x1b[1m");
        if (self.style & 2 != 0) try self.line.appendSlice(self.a, "\x1b[3m");
        if (self.style & 4 != 0) try self.line.appendSlice(self.a, "\x1b[36m");
    }

    /// 结束当前行：必要时追加 reset，把行加入列表，并将列重置为 0。
    fn finish(self: *Writer) !void {
        if (self.ansi) try self.line.appendSlice(self.a, "\x1b[0m");
        try self.lines.append(self.a, try self.line.toOwnedSlice(self.a));
        self.col = 0;
    }

    /// 把文本按簇写入当前行，超出列宽时自动换行。
    fn emit(self: *Writer, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            var c = text.nextCluster(s, i, self.col);
            // 当前簇放不下时换到下一行，并从第 0 列重新计算宽度。
            if (self.col > 0 and c.width > self.columns - self.col) {
                try self.finish();
                c = text.nextCluster(s, i, 0);
            }
            // 新行开头需要重新输出样式（上一行已被 reset）。
            if (self.line.items.len == 0) try self.sgr();
            // A leading combining mark must not attach to another UI row.
            if (self.col == 0 and c.width == 0) {
                try self.line.appendSlice(self.a, "◌");
                self.col = 1;
            }
            if (c.width > self.columns) {
                // An indivisible cluster cannot fit: visible ASCII replacement,
                // never byte slicing or a wide glyph spilling past the margin.
                try self.line.append(self.a, '?');
                self.col += 1;
            } else if (s[i] == '\t') {
                // 制表符展开为空格，保证列数正确。
                for (0..c.width) |_| try self.line.append(self.a, ' ');
                self.col += c.width;
                // 普通簇原样输出，保持 UTF-8 字节完整。
            } else {
                try self.line.appendSlice(self.a, s[i..c.end]);
                self.col += c.width;
            }
            i = c.end;
        }
    }

    /// 处理行内 Markdown：反引号代码、**粗体** / *斜体*、[文本](链接)。
    fn inlineText(self: *Writer, s: []const u8) !void {
        var i: usize = 0;
        // code 为真时位于反引号内，其中的 * 与 [ 不再解析。
        var code = false;
        while (i < s.len) {
            if (s[i] == '`') {
                code = !code;
                // 切换代码样式（异或青色位，与 emit 中的 style 位对应）。
                self.style ^= 4;
                try self.sgr();
                i += 1;
            } else if (!code and s[i] == '*') {
                const double = i + 1 < s.len and s[i + 1] == '*';
                // ** 为粗体(1)，单个 * 为斜体(2)；同一位异或切换，实现开闭配对。
                self.style ^= if (double) @as(u8, 1) else @as(u8, 2);
                try self.sgr();
                i += if (double) @as(usize, 2) else 1;
                // 尝试解析完整链接 [text](url)；找不到 "](" 或 ")" 时按普通文本处理。
            } else if (!code and s[i] == '[') {
                if (std.mem.indexOf(u8, s[i..], "](")) |close| {
                    const url_start = i + close + 2;
                    if (std.mem.indexOfScalar(u8, s[url_start..], ')')) |url_end| {
                        try self.emit(s[i + 1 .. i + close]);
                        // 渲染为 "文本 (链接)" 形式，使终端中可以看到 URL。
                        try self.emit(" (");
                        try self.emit(s[url_start..][0..url_end]);
                        try self.emit(")");
                        i = url_start + url_end + 1;
                        continue;
                    }
                }
                // No complete link remains: render the unclosed suffix as
                // literal text rather than rescanning it for every '[' (O(n²)).
                try self.emit(s[i..]);
                return;
            } else {
                // Keep combining/ZWJ clusters together even near delimiters.
                const c = text.nextCluster(s, i, self.col);
                try self.emit(s[i..c.end]);
                i = c.end;
            }
        }
    }
};

/// 判断是否为代码围栏行（至少 3 个反引号或波浪号），返回围栏字符；否则返回 null。
fn fence(s: []const u8) ?u8 {
    if (s.len >= 3 and (s[0] == '`' or s[0] == '~') and s[1] == s[0] and s[2] == s[0]) return s[0];
    return null;
}

/// 判断是否为水平分隔线：至少 3 个 -、* 或 _，允许其间有空格。
fn rule(s: []const u8) bool {
    if (s.len < 3) return false;
    const ch = s[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var count: usize = 0;
    for (s) |c| {
        if (c == ch) {
            count += 1;
        } else if (c != ' ') return false;
    }
    return count >= 3;
}

/// Lightweight, line-oriented Markdown, not CommonMark. Caller typically uses
/// an arena. Temporary storage is released even with an ordinary allocator.
/// Input and therefore work/output are bounded independently of viewport size.
/// `truncated` means input was capped, not that scrolling hid document lines.
pub fn render(a: Allocator, input: []const u8, options: Options) !Rendered {
    // Independent backing: freeing nested scratch through a caller arena can
    // otherwise retain every temporary line after result allocations interleave.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // 先清洗输入（去除控制字符并限制大小），之后处理的都是安全的 UTF-8 文本。
    const clean = try text.sanitize(scratch, input, limit);
    // 列宽钳制到 1..512，避免 0 列或异常大的列数。
    var w: Writer = .{ .a = scratch, .columns = std.math.clamp(options.columns, 1, 512), .ansi = options.ansi };
    // 按换行符拆分；CRLF 已在 sanitize 阶段归一为 LF。
    var iter = std.mem.splitScalar(u8, clean, '\n');

    // 代码围栏状态：null 表示不在代码块中，否则保存开始围栏的字符，用于匹配结束围栏。
    var fenced: ?u8 = null;
    while (iter.next()) |raw| {
        // 每行开始时重置样式。
        w.style = 0;
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        var s = raw;

        if (options.markdown) {
            // 代码块：开始与结束围栏行本身不输出，只切换状态。
            if (fence(trimmed)) |ch| {
                if (fenced == null) {
                    fenced = ch;
                    continue;
                }
                // 只有同种字符的围栏才能关闭当前代码块。
                if (fenced.? == ch) {
                    fenced = null;
                    continue;
                }
            }
            // 代码块内容原样输出并使用青色样式，不再解析 Markdown。
            if (fenced != null) {
                w.style = 4;
                try w.emit(raw);
                // 水平线渲染为整行 '-'。
            } else if (rule(trimmed)) {
                for (0..w.columns) |_| try w.emit("-");
            } else {
                var hashes: usize = 0;
                // 1 到 6 个 # 后跟空格才算标题；标题使用粗体。
                while (hashes < s.len and s[hashes] == '#') : (hashes += 1) {}
                if (hashes > 0 and hashes <= 6 and hashes < s.len and s[hashes] == ' ') {
                    s = s[hashes + 1 ..];
                    w.style = 1;
                }
                // Preserve list/quote/table prefixes and indentation. In
                // particular '* ' is a list marker, not an italic delimiter.
                // indent 为 trimmed 之前的前导空白长度，列表与引用前缀保留这段缩进。
                const indent = raw.len - trimmed.len;
                // 无序列表 "* " 转换为 "- " 显示，并跳过标记本身，避免被当作斜体。
                if (std.mem.startsWith(u8, trimmed, "* ")) {
                    try w.emit(raw[0..indent]);
                    try w.emit("- ");
                    s = trimmed[2..];
                }
                // 引用行整体使用青色样式。
                if (std.mem.startsWith(u8, trimmed, ">")) w.style |= 4;
                try w.inlineText(s);
            }
            // 关闭 Markdown 解析时整行原样输出（仍经过清洗与换行）。
        } else try w.emit(raw);

        // 每个输入行结束后必须 finish，形成一个输出行。
        try w.finish();
    }

    // 计算视口：从末尾向上滚动 scroll_from_end 行，再取至多 max_lines 行（上限 8192）。
    const total = w.lines.items.len;
    const end = total - @min(total, options.scroll_from_end);
    // 视口参数可能超出范围，用 @min 钳制，保证 start <= end。
    const start = end - @min(end, @min(options.max_lines, 8192));

    // 只把视口内的行复制到调用方分配器；scratch 随后统一释放。
    const lines = try a.alloc([]const u8, end - start);
    var allocated: usize = 0;
    // 复制中途失败时，释放已复制的行与数组。
    errdefer {
        for (lines[0..allocated]) |line| a.free(line);
        a.free(lines);
    }
    for (w.lines.items[start..end], 0..) |line, j| {
        lines[j] = try a.dupe(u8, line);
        allocated += 1;
    }

    // Sanitization can expand invalid/control bytes, triggering the same cap.
    // 判断输入是否超过上限（与 sanitize 规则一致），用于 truncated 标记。
    const truncated = text.exceedsSanitizedLimit(input, limit);
    return .{ .lines = lines, .total_lines = total, .truncated = truncated };
}

/// 释放 render 返回的 Rendered 中的所有行与行数组。
fn release(a: Allocator, r: Rendered) void {
    for (r.lines) |l| a.free(l);
    a.free(r.lines);
}

// 测试：Markdown 基本语法（标题、粗体、列表、代码块等）在纯文本模式下的输出。
test "features plain mode, partial markdown, code whitespace" {
    try text.initLocale();
    const a = std.testing.allocator;
    const r = try render(a, "# Title\n**bold** *italic*\n* list\n1. numbered\n> quote\n`inline`\n[label](https://example.org)\n---\n| a | b |\n```zig\n  code\n\n  *literal*", .{ .columns = 40, .max_lines = 100, .ansi = false });
    defer release(a, r);
    const expected = [_][]const u8{ "Title", "bold italic", "- list", "1. numbered", "> quote", "inline", "label (https://example.org)", "----------------------------------------", "| a | b |", "  code", "", "  *literal*" };
    try std.testing.expectEqual(expected.len, r.total_lines);
    for (expected, r.lines) |e, l| try std.testing.expectEqualStrings(e, l);
    // 未闭合的链接与代码围栏应按普通文本/代码处理，不崩溃。
    const partial = try render(a, "**unfinished [link](\n~~~\n x", .{ .columns = 40, .max_lines = 20, .ansi = false });
    defer release(a, partial);
    try std.testing.expectEqualStrings("unfinished [link](", partial.lines[0]);
    const plain = try render(a, "# **raw**\\x", .{ .columns = 40, .max_lines = 20, .ansi = false, .markdown = false });
    defer release(a, plain);
    try std.testing.expectEqualStrings("# **raw**\\x", plain.lines[0]);
}

// 测试：任意列宽与 ANSI 开关下，可见宽度不超过列宽，且 ANSI 序列完整。
test "widths hostile input clusters and ANSI ownership" {
    try text.initLocale();
    const a = std.testing.allocator;
    for ([_]usize{ 1, 40, 80, 120 }) |cols| {
        for ([_]bool{ false, true }) |ansi| {
            const r = try render(a, "# 中é 👩‍💻 👍🏽 🇺🇸 ❤️\tend\x1b[2J\xe2\x80\xae\n**bold** `code` *it*", .{ .columns = cols, .max_lines = 100, .ansi = ansi });
            defer release(a, r);
            for (r.lines) |l| {
                var visible: std.ArrayList(u8) = .empty;
                defer visible.deinit(a);
                var i: usize = 0;
                while (i < l.len) {
                    if (l[i] == 27) {
                        try std.testing.expect(ansi);
                        try std.testing.expect(l[i + 1] == '[');
                        i += 2;
                        while (i < l.len and std.ascii.isDigit(l[i])) : (i += 1) {}
                        try std.testing.expect(i < l.len and l[i] == 'm');
                        i += 1;
                    } else {
                        try visible.append(a, l[i]);
                        i += 1;
                    }
                }
                try std.testing.expect(std.unicode.utf8ValidateSlice(visible.items));
                try std.testing.expect(text.width(visible.items) <= cols);
                try std.testing.expect(std.mem.indexOfScalar(u8, l, '\n') == null);
            }
        }
    }
}

// 测试：闭合代码块、空文档以及超出范围的视口。
test "closed fences, empty documents and out of range viewport" {
    const a = std.testing.allocator;
    const r = try render(a, "```\n\t**literal**\n```\n# after", .{ .columns = 40, .max_lines = 20, .ansi = false });
    defer release(a, r);
    try std.testing.expectEqual(@as(usize, 2), r.total_lines);
    try std.testing.expectEqualStrings("    **literal**", r.lines[0]);
    try std.testing.expectEqualStrings("after", r.lines[1]);
    const empty = try render(a, "", .{ .columns = 40, .max_lines = 1, .ansi = false });
    defer release(a, empty);
    try std.testing.expectEqualStrings("", empty.lines[0]);
    const away = try render(a, "one\ntwo", .{ .columns = 40, .max_lines = 10, .scroll_from_end = 999 });
    defer release(a, away);
    try std.testing.expectEqual(@as(usize, 2), away.total_lines);
    try std.testing.expectEqual(@as(usize, 0), away.lines.len);
}

// 测试：大量未闭合的 [ 不会导致 O(n²) 行为；孤立组合符以 ◌ 占位显示。
test "unclosed link runs are bounded and combining starts are visible" {
    try text.initLocale();
    const a = std.testing.allocator;
    const brackets: [65536]u8 = @splat('[');
    const r = try render(a, &brackets, .{ .columns = 80, .max_lines = 20, .ansi = false });
    defer release(a, r);
    try std.testing.expectEqual(@as(usize, 820), r.total_lines);
    // 行首组合符必须可见，因此在前面补一个占位符 ◌。
    const leading = try render(a, "\u{301}", .{ .columns = 1, .max_lines = 1, .ansi = false });
    defer release(a, leading);
    try std.testing.expectEqualStrings("◌\u{301}", leading.lines[0]);
}

// 测试：视口参数与容量上限（超长输入截断、行数上限）。
test "viewport and caps" {
    const a = std.testing.allocator;
    const r = try render(a, "0\n1\n2\n3\n4", .{ .columns = 0, .max_lines = 2, .scroll_from_end = 1, .ansi = false });
    defer release(a, r);
    try std.testing.expectEqual(@as(usize, 5), r.total_lines);
    try std.testing.expectEqualStrings("2", r.lines[0]);
    try std.testing.expectEqualStrings("3", r.lines[1]);
    const empty = try render(a, "abc", .{ .columns = 40, .max_lines = 0 });
    defer release(a, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.lines.len);
    const big = try a.alloc(u8, limit + 1);
    defer a.free(big);
    @memset(big, 'x');
    const bounded = try render(a, big, .{ .columns = 9999, .max_lines = 99999, .ansi = false });
    defer release(a, bounded);
    try std.testing.expect(bounded.truncated);
    try std.testing.expect(bounded.lines.len <= 8192);
    try std.testing.expect(std.mem.endsWith(u8, bounded.lines[bounded.lines.len - 1], "[truncated]"));
    for (bounded.lines) |l| try std.testing.expect(text.width(l) <= 512);
}
