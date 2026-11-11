//! 中文：终端文本工具，包括 UTF-8 解码、控制字符清洗、显示宽度计算与字形簇切分。

const std = @import("std");

const posix = @import("../platform/posix_terminal.zig");
const clean = @import("../util/display_text.zig");
const rune = clean.decode;
pub const sanitize = clean.sanitize;
pub const exceedsSanitizedLimit = clean.exceedsSanitizedLimit;

// libc 的 wcwidth：返回码点的列宽，-1 表示不可打印。
extern "c" fn wcwidth(c: c_int) c_int;

/// Call once at startup, before producers. Widths come from host libc, not a
/// pinned Unicode release. Only CTYPE changes; Darwin's category is NOT zero.
pub fn initLocale() !void {
    if (posix.setCtype("C.UTF-8")) return;
    if (comptime @import("builtin").os.tag == .macos) {
        for ([_][*:0]const u8{ "en_US.UTF-8", "UTF-8" }) |locale|
            if (posix.setCtype(locale)) return;
    }
    return error.LocaleUnavailable;
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

/// 计算纯文本的显示列数。TAB 的宽度依赖当前列位置。
pub fn width(s: []const u8) usize {
    return accumulateWidth(s, false);
}

/// Renderer-owned SGR sequences are transparent to display width.
pub fn styledWidth(bytes: []const u8) usize {
    return accumulateWidth(bytes, true);
}

fn accumulateWidth(bytes: []const u8, styled: bool) usize {
    var i: usize = 0;
    var col: usize = 0;
    while (i < bytes.len) {
        const c = if (styled) nextStyledCluster(bytes, i, col) else nextCluster(bytes, i, col);
        col += c.width;
        i = c.end;
    }
    return col;
}

/// Byte length of the longest whole-cluster plain-text prefix fitting columns.
/// Zero-width clusters may fit even when columns is zero.
pub fn fitBytes(bytes: []const u8, columns: usize) usize {
    var end: usize = 0;
    var col: usize = 0;
    while (end < bytes.len) {
        const c = nextCluster(bytes, end, col);
        if (c.width > columns - col) break;
        col += c.width;
        end = c.end;
    }
    return end;
}

// 测试：清洗控制字符、非法 UTF-8 与双向控制符，且截断标记不超过预算。

// 测试：CRLF 归一为 LF，孤立 CR 被替换而不是被执行。

// 测试：libc 宽度与簇边界（宽字符、组合符、TAB、ZWJ、国旗等）符合保守近似。
