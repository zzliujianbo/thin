//! 前端共享的有界 UTF-8 显示清洗。无 ANSI、libc 宽度、终端状态或资源访问。
//! 输出仍是文本，不是 HTML；Web renderer 必须使用 textContent 或自己的 HTML escaping。
const std = @import("std");

pub const Rune = struct { cp: u21, end: usize };

pub fn decode(s: []const u8, i: usize) Rune {
    if (s[i] < 0x80) return .{ .cp = s[i], .end = i + 1 };
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

/// Shared scalar policy for display copies and raw-input cursor mapping.
pub fn displayCodepoint(cp: u21) u21 {
    return if (forbidden(cp)) 0xfffd else cp;
}

pub const Prefix = struct { text: []u8, truncated: bool };

// Printable ASCII is already sanitized and has a one-byte encoding. Bound the
// scan by remaining output room, not by the size of an untrusted input suffix.
fn printableEnd(input: []const u8, start: usize, room: usize) usize {
    const end = start + @min(input.len - start, room);
    var i = start;
    while (i < end and input[i] >= 0x20 and input[i] < 0x7f) : (i += 1) {}
    return i;
}

/// Complete owned UTF-8 display copy with the same scalar policy as sanitizePrefix.
pub fn sanitizeAll(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    return (try sanitizeImpl(a, input, null)).text;
}

/// Owned bounded safe prefix, without a text marker. The flag is metadata so
/// a renderer can discard a possibly incomplete final cluster before clipping.
pub fn sanitizePrefix(a: std.mem.Allocator, input: []const u8, max_bytes: usize) !Prefix {
    return sanitizeImpl(a, input, max_bytes);
}

fn sanitizeImpl(a: std.mem.Allocator, input: []const u8, max_bytes: ?usize) !Prefix {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) {
        const room = if (max_bytes) |bound| bound - out.items.len else input.len - i;
        const end = printableEnd(input, i, room);
        if (end != i) {
            try out.appendSlice(a, input[i..end]);
            i = end;
            continue;
        }
        const r = decode(input, i);
        if (r.cp == 13 and r.end < input.len and input[r.end] == 10) {
            i = r.end;
            continue;
        }
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(displayCodepoint(r.cp), &buf);
        if (max_bytes) |bound| {
            if (n > bound - out.items.len) break;
        }
        try out.appendSlice(a, buf[0..n]);
        i = r.end;
    }
    return .{ .text = try out.toOwnedSlice(a), .truncated = i < input.len };
}

/// Owned UTF-8, capped including the marker. Invalid/control scalars become
/// replacement characters; LF/TAB remain text. CRLF counts as one LF.
pub fn sanitize(a: std.mem.Allocator, input: []const u8, max_bytes: usize) ![]const u8 {
    const prefix = try sanitizePrefix(a, input, max_bytes);
    var out = std.ArrayList(u8).fromOwnedSlice(prefix.text);
    errdefer out.deinit(a);
    if (prefix.truncated) {
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
        const end = printableEnd(input, i, max_bytes - bytes);
        if (end != i) {
            bytes += end - i;
            i = end;
            continue;
        }
        const r = decode(input, i);
        if (r.cp == 13 and r.end < input.len and input[r.end] == 10) {
            i = r.end;
            continue;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(displayCodepoint(r.cp), &buf) catch unreachable;
        if (n > max_bytes - bytes) return true;
        bytes += n;
        i = r.end;
    }
    return false;
}
