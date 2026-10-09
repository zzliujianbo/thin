//! 中文：终端文本工具，包括 UTF-8 解码、控制字符清洗、显示宽度计算与字形簇切分。

const std = @import("std");
const Allocator = std.mem.Allocator;

// libc 的 setlocale；LC_CTYPE(0) 决定 wcwidth 使用的字符类别与宽度表。
extern "c" fn setlocale(category: c_int, locale: [*:0]const u8) ?[*:0]const u8;
// libc 的 wcwidth：返回码点的列宽，-1 表示不可打印。
extern "c" fn wcwidth(c: c_int) c_int;

/// Linux LC_CTYPE. Call once at startup, before starting threads. Width data
/// comes from the host libc's C.UTF-8 locale, not a pinned Unicode release.
pub fn initLocale() !void {
    if (setlocale(0, "C.UTF-8") == null) return error.LocaleUnavailable;
}

// 解码结果：码点，以及该码点在源字符串中结束的字节偏移（不含）。
const Rune = struct { cp: u21, end: usize };

/// 从 i 处解码一个 UTF-8 码点。非法编码返回 U+FFFD 且只前进 1 字节，保证调用方循环一定前进。
fn rune(s: []const u8, i: usize) Rune {
    // 首字节决定序列长度，非法首字节直接替换。
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xfffd, .end = i + 1 };
    // 序列在末尾被截断时同样替换。
    if (n > s.len - i) return .{ .cp = 0xfffd, .end = i + 1 };
    // 续字节不合法时替换。
    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return .{ .cp = 0xfffd, .end = i + 1 };
    return .{ .cp = cp, .end = i + n };
}

/// 判断码点是否不可安全显示：C0/C1 控制字符、双向控制符、行/段分隔符等。TAB 与 LF 例外。
fn forbidden(c: u21) bool {
    // 禁止双向覆盖/隔离字符，防止文本显示方向被篡改（Trojan Source 类问题）。
    return (c < 32 and c != 10 and c != 9) or (c >= 0x7f and c <= 0x9f) or
        c == 0x061c or c == 0x200e or c == 0x200f or (c >= 0x202a and c <= 0x202e) or
        (c >= 0x2066 and c <= 0x206f) or c == 0x2028 or c == 0x2029;
}

/// Owned UTF-8, capped to max_bytes including the marker. Tiny budgets use dots.
/// Controls become replacement characters, so input can never introduce ANSI.
pub fn sanitize(a: Allocator, input: []const u8, max_bytes: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    // 出错时释放已分配的输出缓冲。
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) {
        const r = rune(input, i);
        // CRLF 视为单个换行：跳过 CR，保留随后的 LF。
        if (r.cp == 13 and r.end < input.len and input[r.end] == 10) {
            i = r.end;
            continue;
        }
        var buf: [4]u8 = undefined;
        // 禁止字符与非法字节统一替换为 U+FFFD，保证输出不含控制序列。
        const n = try std.unicode.utf8Encode(if (forbidden(r.cp)) 0xfffd else r.cp, &buf);
        // 预算检查：先判断是否已超出，避免下方无符号减法下溢；放不下则停止，不截断单个字符。
        if (out.items.len > max_bytes or n > max_bytes - out.items.len) break;
        try out.appendSlice(a, buf[0..n]);
        i = r.end;
    }

    // 输入未处理完说明被截断，需要追加截断标记。
    if (i < input.len) {
        // 标记 "[truncated]" 占 11 字节；预算不足时退化为点号。
        const marker = "[truncated]";
        const m = @min(max_bytes, marker.len);
        // 为标记腾出空间：从末尾删除完整字符，直到剩余空间足够。
        while (out.items.len > max_bytes - m) {
            // 先定位当前末尾字符的首字节。
            var end = out.items.len - 1;
            // 跳过续字节(10xxxxxx)，保证不切断 UTF-8 字符。
            while (end > 0 and out.items[end] & 0xc0 == 0x80) end -= 1;
            out.shrinkRetainingCapacity(end);
        }
        // 预算足够放下完整标记时使用标记，否则用点号。
        if (m == marker.len) try out.appendSlice(a, marker) else {
            for (0..m) |_| try out.append(a, '.');
        }
    }

    // 返回调用方拥有的切片，由调用方负责释放。
    return out.toOwnedSlice(a);
}

/// Checks the encoded, sanitized budget without allocating or scanning beyond it.
pub fn exceedsSanitizedLimit(input: []const u8, max_bytes: usize) bool {
    var i: usize = 0;
    var bytes: usize = 0;
    while (i < input.len) {
        const r = rune(input, i);
        // 与 sanitize 保持一致：CRLF 只计为一个换行。
        if (r.cp == 13 and r.end < input.len and input[r.end] == 10) {
            i = r.end;
            continue;
        }
        // 与 sanitize 使用相同的替换规则，保证计算出的字节数与实际输出一致。
        var buf: [4]u8 = undefined;
        // 替换后的值都是合法码点，编码不会失败。
        const n = std.unicode.utf8Encode(if (forbidden(r.cp)) 0xfffd else r.cp, &buf) catch unreachable;
        // 不变量：bytes <= max_bytes，因此减法不会下溢；超出即返回 true。
        if (n > max_bytes - bytes) return true;
        bytes += n;
        i = r.end;
    }
    return false;
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
