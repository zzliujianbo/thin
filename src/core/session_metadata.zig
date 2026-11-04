const std = @import("std");

/// A small owned, single-line UTF-8 title. Empty means no title.
pub const Title = struct {
    buf: [256]u8 = @splat(0),
    len: u16 = 0,

    pub fn fromText(input: []const u8) Title {
        var result: Title = .{};
        var iter = (std.unicode.Utf8View.init(input) catch return result).iterator();
        var pending_space = false;
        var count: usize = 0;
        while (iter.nextCodepointSlice()) |bytes| {
            const cp = std.unicode.utf8Decode(bytes) catch unreachable;
            if (cp <= 0x20 or (cp >= 0x7f and cp <= 0x9f) or cp == 0xa0 or cp == 0x1680 or
                (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or
                cp == 0x202f or cp == 0x205f or cp == 0x3000)
            {
                if (result.len != 0) pending_space = true;
                continue;
            }
            if (count == 64) break;
            if (pending_space) {
                if (count + 1 >= 64) break;
                result.buf[result.len] = ' ';
                result.len += 1;
                count += 1;
                pending_space = false;
            }
            @memcpy(result.buf[result.len..][0..bytes.len], bytes);
            result.len += @intCast(bytes.len);
            count += 1;
        }
        return result;
    }

    pub fn text(self: *const Title) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(a: Title, b: Title) bool {
        return std.mem.eql(u8, a.text(), b.text());
    }
};

pub const SavedSession = struct {
    id: [32]u8,
    modified_ms: i64,
    title: Title = .{},
};

test "title normalizes whitespace, control characters and UTF-8 boundaries" {
    const title = Title.fromText(" \n你好\t世界\x1b  test \r\n");
    try std.testing.expectEqualStrings("你好 世界 test", title.text());
    try std.testing.expectEqualStrings("a b c d", Title.fromText("a\u{2028}b\u{2029}c\u{3000}d").text());
    try std.testing.expectEqualStrings("", Title.fromText("\xff").text());
    try std.testing.expectEqualStrings("", Title.fromText(" \n\x01").text());
    var long: [260]u8 = undefined;
    for (0..65) |i| @memcpy(long[i * 4 ..][0..4], "😀");
    const bounded = Title.fromText(&long);
    try std.testing.expectEqual(@as(usize, 256), bounded.text().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bounded.text()));
}
