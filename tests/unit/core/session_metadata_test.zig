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
