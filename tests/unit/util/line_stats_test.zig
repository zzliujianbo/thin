test "budget is shared and charged exactly for LCS cells" {
    const a = std.testing.allocator;
    var budget: usize = 8;
    try std.testing.expectEqualDeep(Changes{ .modified = 1 }, (try compareBudgeted(a, "a\n", "b\n", &budget)).?);
    try std.testing.expectEqual(@as(usize, 4), budget);
    try std.testing.expectEqualDeep(Changes{ .modified = 1 }, (try compareBudgeted(a, "x", "y", &budget)).?);
    try std.testing.expectEqual(@as(usize, 0), budget);
    try std.testing.expect((try compareBudgeted(a, "p", "q", &budget)) == null);
    try std.testing.expectEqual(@as(usize, 0), budget);
    // Equal input and pure additions/deletions require no table cells.
    try std.testing.expectEqualDeep(Changes{}, (try compareBudgeted(a, "same", "same", &budget)).?);
    try std.testing.expectEqualDeep(Changes{ .added = 1 }, (try compareBudgeted(a, "", "added\n", &budget)).?);
    try std.testing.expectEqualDeep(Changes{ .removed = 1 }, (try compareBudgeted(a, "removed\n", "", &budget)).?);
    try std.testing.expectEqual(@as(usize, 0), budget);
    budget = 3;
    try std.testing.expect((try compareBudgeted(a, "a", "b", &budget)) == null);
    try std.testing.expectEqual(@as(usize, 3), budget);
}
test "trim complete common lines before applying observation caps" {
    const a = std.testing.allocator;
    const prefix = try a.alloc(u8, 300 * 1024);
    defer a.free(prefix);
    for (prefix, 0..) |*byte, i| byte.* = if (i % 32 == 31) '\n' else 'x';
    const before = try std.mem.concat(a, u8, &.{ prefix, "old\n", prefix });
    defer a.free(before);
    const after = try std.mem.concat(a, u8, &.{ prefix, "new\n", prefix });
    defer a.free(after);
    var budget: usize = 4;
    try std.testing.expectEqualDeep(Changes{ .modified = 1 }, (try compareBudgeted(a, before, after, &budget)).?);
    try std.testing.expectEqual(@as(usize, 0), budget);
}
test "line observations count returned segments and bounded replacement hunks without double counting" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u64, 0), count(""));
    try std.testing.expectEqual(@as(u64, 1), count("\n"));
    try std.testing.expectEqual(@as(u64, 2), count("a\r\n中"));
    try std.testing.expectEqualDeep(Changes{ .added = 2 }, (try compare(a, "", "a\nb\n")).?);
    try std.testing.expectEqualDeep(Changes{ .removed = 2 }, (try compare(a, "a\nb", "")).?);
    try std.testing.expectEqualDeep(Changes{ .modified = 1, .added = 1, .removed = 1 }, (try compare(a, "a\nb\nc\nd\ne\n", "a\nB\nx\nc\ne\n")).?);
    try std.testing.expectEqualDeep(Changes{}, (try compare(a, "same\n", "same\n")).?);
    try std.testing.expectEqualDeep(Changes{ .modified = 1 }, (try compare(a, "last\n", "last")).?);
    try std.testing.expect((try compare(a, "\xff", "valid")) == null);
    const big = try a.alloc(u8, max_bytes + 1);
    defer a.free(big);
    @memset(big, 'a');
    try std.testing.expect((try compare(a, "old", big)) == null);
    const many = try a.alloc(u8, 3000);
    defer a.free(many);
    @memset(many, '\n');
    try std.testing.expect((try compare(a, many, "new")) == null);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, compare(failing.allocator(), "old", "new"));
}
