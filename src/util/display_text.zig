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

/// Owned bounded safe prefix, without a text marker. The flag is metadata so
/// a renderer can discard a possibly incomplete final cluster before clipping.
pub fn sanitizePrefix(a: std.mem.Allocator, input: []const u8, max_bytes: usize) !Prefix {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) {
        const end = printableEnd(input, i, max_bytes - out.items.len);
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
        if (out.items.len > max_bytes or n > max_bytes - out.items.len) break;
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

test "safe prefixes carry truncation as metadata and preserve literal markers" {
    const a = std.testing.allocator;
    const input = "é[truncated]\r\n\x1b";
    for (0..32) |limit| {
        const prefix = try sanitizePrefix(a, input, limit);
        defer a.free(prefix.text);
        try std.testing.expect(prefix.text.len <= limit);
        try std.testing.expect(std.unicode.utf8ValidateSlice(prefix.text));
        try std.testing.expectEqual(exceedsSanitizedLimit(input, limit), prefix.truncated);
        try std.testing.expect(std.mem.indexOfScalar(u8, prefix.text, '\x1b') == null);
    }
    const prefix = try sanitizePrefix(a, "literal[truncated]file", 512);
    defer a.free(prefix.text);
    try std.testing.expect(!prefix.truncated);
    try std.testing.expectEqualStrings("literal[truncated]file", prefix.text);
}

test "ASCII batching matches scalar decoding and bounded sanitization" {
    const Reference = struct {
        fn rune(s: []const u8, i: usize) Rune {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xfffd, .end = i + 1 };
            if (n > s.len - i) return .{ .cp = 0xfffd, .end = i + 1 };
            const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return .{ .cp = 0xfffd, .end = i + 1 };
            return .{ .cp = cp, .end = i + n };
        }
        fn prefix(a: std.mem.Allocator, input: []const u8, max_bytes: usize) !Prefix {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(a);
            var i: usize = 0;
            while (i < input.len) {
                const r = rune(input, i);
                if (r.cp == 13 and r.end < input.len and input[r.end] == 10) {
                    i = r.end;
                    continue;
                }
                var buf: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(displayCodepoint(r.cp), &buf);
                if (n > max_bytes - out.items.len) break;
                try out.appendSlice(a, buf[0..n]);
                i = r.end;
            }
            return .{ .text = try out.toOwnedSlice(a), .truncated = i < input.len };
        }
    };
    const a = std.testing.allocator;
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @intCast(i);
    const cases = [_][]const u8{ "", "plain ASCII [truncated] \\ text", "ABC\r\nDEF\tG\r", "a中文é❤\u{fe0f}👩\u{200d}🚀z\u{202e}\xff", &bytes };
    for (cases) |input| {
        for (0..input.len) |i| try std.testing.expectEqualDeep(Reference.rune(input, i), decode(input, i));
        for (0..input.len * 3 + 2) |limit| {
            const expected = try Reference.prefix(a, input, limit);
            defer a.free(expected.text);
            const actual = try sanitizePrefix(a, input, limit);
            defer a.free(actual.text);
            try std.testing.expectEqualStrings(expected.text, actual.text);
            try std.testing.expectEqual(expected.truncated, actual.truncated);
            try std.testing.expectEqual(expected.truncated, exceedsSanitizedLimit(input, limit));
        }
    }
    const large: [8192]u8 = @splat('x');
    try std.testing.expectEqual(@as(usize, 0), printableEnd(&large, 0, 0));
    try std.testing.expectEqual(@as(usize, 7), printableEnd(&large, 0, 7));
}

test "ASCII batch allocation failure releases output" {
    const Scenario = struct {
        fn run(a: std.mem.Allocator) !void {
            const value = try sanitize(a, "printable ASCII 中文\r\nmore text\x1b", 28);
            defer a.free(value);
        }
    };
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), Scenario.run, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
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
