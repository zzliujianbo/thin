//! 前端共享的有界 UTF-8 显示清洗。无 ANSI、libc 宽度、终端状态或资源访问。
//! 输出仍是文本，不是 HTML；Web renderer 必须使用 textContent 或自己的 HTML escaping。
const std = @import("std");

pub const Rune = struct { cp: u21, end: usize };

pub fn decode(s: []const u8, i: usize) Rune {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xfffd, .end = i + 1 };
    if (n > s.len - i) return .{ .cp = 0xfffd, .end = i + 1 };
    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return .{ .cp = 0xfffd, .end = i + 1 };
    return .{ .cp = cp, .end = i + n };
}

fn forbidden(c: u21) bool {
    return (c < 32 and c != 10 and c != 9) or (c >= 0x7f and c <= 0x9f) or
        c == 0x061c or c == 0x200e or c == 0x200f or (c >= 0x202a and c <= 0x202e) or
        (c >= 0x2066 and c <= 0x206f) or c == 0x2028 or c == 0x2029;
}

/// Owned UTF-8, capped including the marker. Invalid/control scalars become
/// replacement characters; LF/TAB remain text. CRLF counts as one LF.
pub fn sanitize(a: std.mem.Allocator, input: []const u8, max_bytes: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) {
        const r = decode(input, i);
        if (r.cp == 13 and r.end < input.len and input[r.end] == 10) {
            i = r.end;
            continue;
        }
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(if (forbidden(r.cp)) 0xfffd else r.cp, &buf);
        if (out.items.len > max_bytes or n > max_bytes - out.items.len) break;
        try out.appendSlice(a, buf[0..n]);
        i = r.end;
    }
    if (i < input.len) {
        const marker = "[truncated]";
        const m = @min(max_bytes, marker.len);
        while (out.items.len > max_bytes - m) {
            var end = out.items.len - 1;
            while (end > 0 and out.items[end] & 0xc0 == 0x80) end -= 1;
            out.shrinkRetainingCapacity(end);
        }
        if (m == marker.len) try out.appendSlice(a, marker) else {
            for (0..m) |_| try out.append(a, '.');
        }
    }
    return out.toOwnedSlice(a);
}

pub fn exceedsSanitizedLimit(input: []const u8, max_bytes: usize) bool {
    var i: usize = 0;
    var bytes: usize = 0;
    while (i < input.len) {
        const r = decode(input, i);
        if (r.cp == 13 and r.end < input.len and input[r.end] == 10) {
            i = r.end;
            continue;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(if (forbidden(r.cp)) 0xfffd else r.cp, &buf) catch unreachable;
        if (n > max_bytes - bytes) return true;
        bytes += n;
        i = r.end;
    }
    return false;
}
