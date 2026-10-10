//! 中文：终端文本工具，包括 UTF-8 解码、控制字符清洗、显示宽度计算与字形簇切分。

const std = @import("std");
const Allocator = std.mem.Allocator;
const clean = @import("../util/display_text.zig");
const rune = clean.decode;
pub const sanitize = clean.sanitize;
pub const exceedsSanitizedLimit = clean.exceedsSanitizedLimit;

// libc 的 setlocale；LC_CTYPE(0) 决定 wcwidth 使用的字符类别与宽度表。
extern "c" fn setlocale(category: c_int, locale: [*:0]const u8) ?[*:0]const u8;
// libc 的 wcwidth：返回码点的列宽，-1 表示不可打印。
extern "c" fn wcwidth(c: c_int) c_int;

/// Linux LC_CTYPE. Call once at startup, before starting threads. Width data
/// comes from the host libc's C.UTF-8 locale, not a pinned Unicode release.
pub fn initLocale() !void {
    if (setlocale(0, "C.UTF-8") == null) return error.LocaleUnavailable;
}

/// 一个显示单元（字形簇）：结束字节偏移与占用的终端列数。
pub const Cluster = struct { end: usize, width: usize };

/// 单个码点的列宽；wcwidth 返回 -1（不可打印）时按 1 列计。
fn scalarWidth(c: u21) usize {
    const w = wcwidth(@intCast(c));
    return if (w < 0) 1 else @intCast(w);
}

/// Fitzpatrick 肤色修饰符 U+1F3FB..U+1F3FF。
fn modifier(c: u21) bool {
    return c >= 0x1f3fb and c <= 0x1f3ff;
}

/// 区域指示符（两个组成一面国旗）。
fn regional(c: u21) bool {
    return c >= 0x1f1e6 and c <= 0x1f1ff;
}

/// 应附着在前一个簇上的码点：变体选择符、肤色修饰符以及其他零宽码点（ZWJ 由 nextCluster 单独处理）。
fn extend(c: u21) bool {
    return c == 0xfe0e or c == 0xfe0f or modifier(c) or (c != 0x200d and scalarWidth(c) == 0);
}

/// Conservative cluster approximation, not full UAX #29. ZWJ sequences keep
/// the SUM of constituent widths (safe on terminals without ligature support).
/// Flags and modifiers likewise budget their unligated display widths.
pub fn nextCluster(s: []const u8, start: usize, column: usize) Cluster {
    if (start >= s.len) return .{ .end = s.len, .width = 0 };
    const first = rune(s, start);
    // TAB 按到下一个 4 列制表位计算宽度。
    if (first.cp == 9) return .{ .end = first.end, .width = 4 - column % 4 };
    // LF 不占显示列。
    if (first.cp == 10) return .{ .end = first.end, .width = 0 };

    var end = first.end;
    // 区域指示符至少按 2 列计，国旗合计至少 4 列。
    var w = if (regional(first.cp)) @max(@as(usize, 2), scalarWidth(first.cp)) else scalarWidth(first.cp);
    // flag 表示下一个区域指示符可以与之配对组成国旗。
    var flag = regional(first.cp);

    // 持续吸收后续码点，直到遇到无法合并的字符。
    while (end < s.len) {
        const r = rune(s, end);
        if (r.cp == 9 or r.cp == 10) break;
        // 扩展字符不增加基础簇的边界，只调整宽度。
        if (extend(r.cp)) {
            // 变体选择符 FE0F（emoji 呈现）至少按 2 列计。
            if (r.cp == 0xfe0f) w = @max(w, 2);
            // 肤色修饰符额外增加其自身宽度。
            if (modifier(r.cp)) w += scalarWidth(r.cp);
            end = r.end;
            // 第二个区域指示符：与前一个组成国旗，合计至少 4 列，之后不再配对。
        } else if (flag and regional(r.cp)) {
            w += @max(@as(usize, 2), scalarWidth(r.cp));
            w = @max(w, 4);
            end = r.end;
            flag = false;
            // ZWJ 连接下一个码点：按各自宽度求和（不假设终端支持连字），宁可高估也不低估。
        } else if (r.cp == 0x200d) {
            end = r.end;
            if (end < s.len) {
                const joined = rune(s, end);
                // ZWJ 之后若是 TAB/LF，则停止，不把控制字符吸进簇。
                if (joined.cp == 9 or joined.cp == 10) break;
                w += scalarWidth(joined.cp);
                end = joined.end;
            }
        } else break;
    }
    return .{ .end = end, .width = w };
}

/// 计算字符串的显示列数。TAB 的宽度依赖当前列位置，因此逐簇累加。
pub fn width(s: []const u8) usize {
    var i: usize = 0;
    var col: usize = 0;
    while (i < s.len) {
        // 逐簇累加列宽；TAB 宽度取决于当前 col。
        const c = nextCluster(s, i, col);
        col += c.width;
        i = c.end;
    }
    return col;
}

// 测试：清洗控制字符、非法 UTF-8 与双向控制符，且截断标记不超过预算。
test "sanitize controls, invalid utf8, backslashes and bounded marker" {
    const a = std.testing.allocator;
    const s = try sanitize(a, "a\\b\x1b[31m\xe2\x80\xae\xff\n\t", 100);
    defer a.free(s);
    try std.testing.expect(std.unicode.utf8ValidateSlice(s));
    try std.testing.expect(std.mem.startsWith(u8, s, "a\\b"));
    try std.testing.expect(std.mem.indexOfScalar(u8, s, 27) == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\xe2\x80\xae") == null);
    for (0..20) |n| {
        const t = try sanitize(a, "你好你好你好你好你好你好", n);
        defer a.free(t);
        try std.testing.expect(t.len <= n);
        try std.testing.expect(std.unicode.utf8ValidateSlice(t));
    }
}

// 测试：CRLF 归一为 LF，孤立 CR 被替换而不是被执行。
test "CRLF is one newline, isolated carriage return is not executed" {
    const a = std.testing.allocator;
    const s = try sanitize(a, "a\r\nb\rc", 20);
    defer a.free(s);
    try std.testing.expectEqualStrings("a\nb�c", s);
    try std.testing.expect(!exceedsSanitizedLimit("a\r\nb", 3));
}

// 测试：libc 宽度与簇边界（宽字符、组合符、TAB、ZWJ、国旗等）符合保守近似。
test "libc widths and conservative cluster edges" {
    try initLocale();
    try std.testing.expectEqual(@as(usize, 2), width("中"));
    try std.testing.expectEqual(@as(usize, 1), width("e\xcc\x81"));
    try std.testing.expectEqual(@as(usize, 5), width("a\tb"));
    for ([_][]const u8{ "👩‍💻", "👍🏽", "🇺🇸", "❤️", "a‍b", "a‍", "\xcc\x81" }) |s| {
        const c = nextCluster(s, 0, 0);
        try std.testing.expectEqual(s.len, c.end);
    }
    try std.testing.expect(width("👩‍💻") >= 4);
    try std.testing.expect(width("🇺🇸") >= 4);
}
