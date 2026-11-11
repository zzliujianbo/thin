test "summary is bounded single line and terminal safe" {
    var summary: Summary = .{};
    summary.append("中文\nnext\x1b]0;title\x07\u{009b}m");
    summary.append("second");
    try std.testing.expect(std.unicode.utf8ValidateSlice(summary.text()));
    for (summary.text()) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    try std.testing.expect(std.mem.indexOf(u8, summary.text(), " · second") != null);
    const long: [512]u8 = @splat('x');
    summary.append(&long);
    try std.testing.expect(summary.text().len <= 256);
    try std.testing.expect(std.unicode.utf8ValidateSlice(summary.text()));
}
