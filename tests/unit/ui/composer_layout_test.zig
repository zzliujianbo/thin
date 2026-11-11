test "composer vertical mapping cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, verticalAllocationScenario, .{});
}
test "composer vertical movement follows visual rows and preserves a goal column" {
    const a = std.testing.allocator;
    const up = try moveVertical(a, "abcdefghijkl", 10, 4, false, null);
    try std.testing.expectEqual(@as(usize, 6), up.cursor);
    const down = try moveVertical(a, "abcdefghijkl", up.cursor, 4, true, up.preferred_column);
    try std.testing.expectEqual(@as(usize, 10), down.cursor);
    const short = try moveVertical(a, "abcd\nx\nabcdef", 11, 8, false, 3);
    try std.testing.expectEqual(@as(usize, 6), short.cursor);
    const restored = try moveVertical(a, "abcd\nx\nabcdef", short.cursor, 8, true, short.preferred_column);
    try std.testing.expectEqual(@as(usize, 10), restored.cursor);
    const top = try moveVertical(a, "abcdef", 2, 4, false, null);
    try std.testing.expectEqual(@as(usize, 2), top.cursor);
}
test "composer vertical mapping respects tabs CJK and joined emoji" {
    try text.initLocale();
    const a = std.testing.allocator;
    const raw = "a\t界\n🙂abc";
    const up = try moveVertical(a, raw, raw.len, 8, false, null);
    try std.testing.expectEqual(@as(usize, "a\t".len), up.cursor);
    const down = try moveVertical(a, raw, up.cursor, 8, true, up.preferred_column);
    try std.testing.expectEqual(raw.len, down.cursor);
    const joined = "👩‍💻x\n👩‍💻y";
    const moved = try moveVertical(a, joined, joined.len, 8, false, null);
    try std.testing.expectEqual(@as(usize, "👩‍💻x".len), moved.cursor);
    const narrow = try moveVertical(a, "a\tb", 2, 1, false, null);
    try std.testing.expectEqual(@as(usize, 1), narrow.cursor);
    const narrow_down = try moveVertical(a, "a\tb", narrow.cursor, 1, true, narrow.preferred_column);
    try std.testing.expectEqual(@as(usize, 2), narrow_down.cursor);
}
test "composer soft wraps and puts exact-width caret on the next row" {
    const a = std.testing.allocator;
    const wrapped = try layout(a, "abcdef", 6, 4, 8);
    defer wrapped.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("abcd", wrapped.lines[0]);
    try std.testing.expectEqualStrings("ef", wrapped.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), wrapped.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), wrapped.cursor_column);
    const exact = try layout(a, "abcd", 4, 4, 8);
    defer exact.deinit(a);
    try std.testing.expectEqualStrings("", exact.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), exact.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), exact.cursor_column);
}
test "composer newline caret and CJK clusters retain raw bytes" {
    try text.initLocale();
    const a = std.testing.allocator;
    const value = try layout(a, "ab\n\ncd\n", 7, 4, 8);
    defer value.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), value.lines.len);
    try std.testing.expectEqualStrings("", value.lines[3]);
    const wide = try layout(a, "世界a", "世界a".len, 4, 8);
    defer wide.deinit(a);
    try std.testing.expectEqualStrings("世界", wide.lines[0]);
    try std.testing.expectEqualStrings("a", wide.lines[1]);
    const narrow = try layout(a, "世a", "世a".len, 1, 8);
    defer narrow.deinit(a);
    try std.testing.expectEqualStrings("?", narrow.lines[0]);
    const boundary = try layout(a, "abcd\nx", 4, 4, 8);
    defer boundary.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), boundary.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), boundary.cursor_column);
}
test "composer emoji clusters and caret boundaries never split a glyph" {
    try text.initLocale();
    const a = std.testing.allocator;
    const emoji = try layout(a, "a🙂b", "a🙂b".len, 3, 8);
    defer emoji.deinit(a);
    try std.testing.expectEqualStrings("a🙂", emoji.lines[0]);
    try std.testing.expectEqualStrings("b", emoji.lines[1]);
    const boundary = try layout(a, "a🙂b", "a🙂".len, 3, 8);
    defer boundary.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), boundary.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), boundary.cursor_column);
    // Preserve text.zig's existing conservative SUM width for ZWJ clusters.
    const joined = try layout(a, "👩‍💻x", "👩‍💻x".len, text.width("👩‍💻"), 8);
    defer joined.deinit(a);
    try std.testing.expectEqualStrings("👩‍💻", joined.lines[0]);
    try std.testing.expectEqualStrings("x", joined.lines[1]);
    const narrow = try layout(a, "👩‍💻x", "👩‍💻x".len, 2, 8);
    defer narrow.deinit(a);
    try std.testing.expectEqualStrings("?x", narrow.lines[0]);
}
test "composer viewport follows a middle cursor and bounds long input allocations" {
    const a = std.testing.allocator;
    const middle = try layout(a, "abcdefghijklmnopqrst", 5, 4, 2);
    defer middle.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), middle.lines.len);
    try std.testing.expect(middle.cursor_row < middle.lines.len and middle.cursor_column < 4);
    const bytes = try a.alloc(u8, 65536);
    defer a.free(bytes);
    @memset(bytes, 'a');
    const long = try layout(a, bytes, bytes.len, 8, 999);
    defer long.deinit(a);
    try std.testing.expectEqual(max_rows, long.lines.len);
    try std.testing.expectEqual(@as(usize, 8193), long.total_rows);
    try std.testing.expectEqual(@as(usize, 7), long.cursor_row);
    try std.testing.expectEqual(@as(usize, 65536), bytes.len);
}
test "composer viewport cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
