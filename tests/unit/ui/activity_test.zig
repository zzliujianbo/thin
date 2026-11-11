test "terminal spinner retains fixed80ms independent of shared TPS flow" {
    try std.testing.expect(!std.mem.eql(u8, spinner(0), spinner(80)));
    try std.testing.expectEqualStrings(spinner(0), spinner(800));
    try std.testing.expectEqualStrings("⠧", spinner(600));
    try std.testing.expect(Flow.interval(1000) < Flow.interval(100));
}
