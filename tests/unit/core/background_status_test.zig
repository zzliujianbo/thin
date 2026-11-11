test "command clips valid UTF-8 and removes controls" {
    const command = Command.from("one\n\x1b[31m\xc2\x85two");
    try std.testing.expectEqualStrings("one  [31m two", command.slice());
    var long: [514]u8 = @splat('a');
    @memcpy(long[511..514], "€");
    const clipped = Command.from(&long);
    try std.testing.expectEqual(@as(usize, 511), clipped.slice().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped.slice()));
}
