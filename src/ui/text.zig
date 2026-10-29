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
    if (c >= 0x20 and c < 0x7f) return 1;
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
    return cluster(s, start, column, false);
}

/// Renderer-owned SGR is transparent to cluster boundaries and cell widths.
/// This is not an escape interpreter and never accepts cursor movement.
pub fn nextStyledCluster(s: []const u8, start: usize, column: usize) Cluster {
    return cluster(s, start, column, true);
}

fn visibleRune(s: []const u8, start: usize, styled: bool) ?clean.Rune {
    if (start >= s.len) return null;
    var i = start;
    if (styled) {
        while (i + 1 < s.len and s[i] == 0x1b and s[i + 1] == '[') {
            var end = i + 2;
            while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == ';')) : (end += 1) {}
            if (end == s.len or s[end] != 'm') break;
            i = end + 1;
        }
    }
    return if (i < s.len) rune(s, i) else null;
}

/// Incremental conservative cluster state. Renderer SGR must not be fed here.
/// Not UAX #29: joined scalars, modifiers and flags retain constituent SUMs.
pub const ClusterState = struct {
    width: usize,
    regional_pair: bool,
    awaitZWJ: bool = false,

    pub fn init(cp: u21, column: usize) ClusterState {
        return .{
            .width = if (cp == 9) 4 - column % 4 else if (cp == 10) 0 else if (regional(cp)) @max(2, scalarWidth(cp)) else scalarWidth(cp),
            .regional_pair = regional(cp),
        };
    }

    pub fn accept(self: *ClusterState, cp: u21) bool {
        if (cp == 9 or cp == 10) return false;
        // A scalar immediately after ZWJ takes the joined branch even when
        // it is itself an extension. Controls never satisfy the join.
        if (self.awaitZWJ) {
            if (cp < 32 or (cp >= 0x7f and cp <= 0x9f)) return false;
            self.width += scalarWidth(cp);
            self.awaitZWJ = false;
            return true;
        }
        // Printable ASCII cannot extend a cluster except immediately after
        // ZWJ, handled above. Avoid Unicode width queries for ordinary text.
        if (cp >= 0x20 and cp < 0x7f) return false;
        if (extend(cp)) {
            if (cp == 0xfe0f) self.width = @max(self.width, 2);
            if (modifier(cp)) self.width += scalarWidth(cp);
            return true;
        }
        if (self.regional_pair and regional(cp)) {
            self.width = @max(4, self.width + @max(2, scalarWidth(cp)));
            self.regional_pair = false;
            return true;
        }
        if (cp == 0x200d) {
            self.awaitZWJ = true;
            return true;
        }
        return false;
    }
};

fn cluster(s: []const u8, start: usize, column: usize, styled: bool) Cluster {
    const first = visibleRune(s, start, styled) orelse return .{ .end = s.len, .width = 0 };
    // TAB 按到下一个 4 列制表位计算宽度。
    if (first.cp == 9) return .{ .end = first.end, .width = 4 - column % 4 };
    // LF 不占显示列。
    if (first.cp == 10) return .{ .end = first.end, .width = 0 };

    var end = first.end;
    var state = ClusterState.init(first.cp, column);
    while (end < s.len) {
        const r = visibleRune(s, end, styled) orelse {
            end = s.len;
            break;
        };
        if (!state.accept(r.cp)) break;
        end = r.end;
    }
    return .{ .end = end, .width = state.width };
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

test "printable ASCII width and cluster shortcuts retain ZWJ joins" {
    try initLocale();
    for (0x20..0x7f) |value| {
        const cp: u21 = @intCast(value);
        try std.testing.expectEqual(@as(c_int, 1), wcwidth(@intCast(cp)));
        try std.testing.expectEqual(@as(usize, 1), scalarWidth(cp));
        var ordinary = ClusterState.init('a', 0);
        try std.testing.expect(!ordinary.accept(cp));
        var joined = ClusterState.init('a', 0);
        try std.testing.expect(joined.accept(0x200d));
        try std.testing.expect(joined.accept(cp));
        try std.testing.expectEqual(@as(usize, 2), joined.width);
        try std.testing.expect(!joined.accept('z'));
    }
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

test "incremental state matches conservative styled and plain traversal" {
    try initLocale();
    const cases = [_][]const u8{ "❤️", "é", "👍🏽", "👩‍💻", "🇺🇸", "a‍🏽", "a‍️", "a‍‍" };
    for (cases) |s| {
        const first = rune(s, 0);
        var state = ClusterState.init(first.cp, 0);
        var i = first.end;
        while (i < s.len) {
            const r = rune(s, i);
            try std.testing.expect(state.accept(r.cp));
            i = r.end;
        }
        try std.testing.expectEqual(nextCluster(s, 0, 0).width, state.width);
        try std.testing.expect(!state.accept(9));
        try std.testing.expect(!state.accept(10));
    }
    var joined = ClusterState.init('a', 0);
    try std.testing.expect(joined.accept(0x200d));
    try std.testing.expect(!joined.accept(27));
    try std.testing.expect(joined.awaitZWJ);
    try std.testing.expect(joined.accept(0xfe0f));
    // Joined FE0F is a scalar SUM, not ordinary FE0F max(2).
    try std.testing.expectEqual(@as(usize, 1), joined.width);
    const flags = "🇺🇸🇨";
    const pair = nextCluster(flags, 0, 0);
    try std.testing.expectEqual(@as(usize, 8), pair.end);
    try std.testing.expectEqual(@as(usize, 4), pair.width);
    try std.testing.expectEqual(@as(usize, 2), nextCluster(flags, pair.end, pair.width).width);
    const styled = "\x1b[31m❤\x1b[1m️\x1b[0m";
    try std.testing.expectEqual(styled.len, nextStyledCluster(styled, 0, 0).end);
    try std.testing.expectEqual(@as(usize, 2), nextStyledCluster(styled, 0, 0).width);
    const control = "a‍\x1b[31m\n";
    try std.testing.expectEqual(@as(usize, 4), nextStyledCluster(control, 0, 0).end);
}
