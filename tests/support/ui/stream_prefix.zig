fn allocationScenario(a: std.mem.Allocator) !void {
    var bytes: [16384]u8 = @splat('x');
    var prefix = (try Prefix.capture(a, &.{ "first", &bytes, "last" }, 100)).?;
    defer prefix.deinit();
    try std.testing.expect(prefix.matches(&.{ "first", &bytes, "last", "extra" }, 100));
}

fn extensionScenario(a: std.mem.Allocator) !void {
    var base = (try Prefix.capture(a, &.{ "first", "second" }, 100)) orelse return;
    defer base.deinit();
    var next = (try base.extend(a, &.{ "third", "last" }, 100)) orelse return;
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 4), next.rowCount());
    try std.testing.expect(next.matches(&.{ "first", "second", "third", "last" }, 100));
}
