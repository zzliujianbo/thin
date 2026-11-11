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
