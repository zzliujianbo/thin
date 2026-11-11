test "write preview fingerprints line semantics without retaining content" {
    const a = std.testing.allocator;
    var baseline = (try Baseline.fromBytes(a, "a\nb\n")).?;
    var tracker = Tracker.init(a);
    defer tracker.deinit();
    tracker.setBaseline(baseline);
    baseline = undefined;
    for ("a\nB\nnew") |byte| tracker.scalar(byte);
    try std.testing.expectEqualDeep(Progress{ .added = 2, .deleted = 1 }, tracker.progress());
    tracker.finish();
    try std.testing.expectEqualDeep(Progress{ .added = 2, .deleted = 1 }, tracker.progress());
}
test "write preview empty baseline progress is constant work" {
    const t = std.testing;
    var tracker = Tracker.init(t.allocator);
    defer tracker.deinit();
    tracker.setBaseline(try Baseline.fromBytes(t.allocator, ""));
    for (0..max_lines - 1) |_| {
        tracker.scalar('x');
        tracker.scalar('\n');
    }
    for (0..128) |_| {
        tracker.scalar('y');
        try t.expectEqual(@as(?usize, max_lines), tracker.progress().added);
        try t.expectEqual(@as(usize, 0), tracker.cells_spent);
    }
}
test "write preview empty final LF CRLF limits and unknown baseline" {
    const a = std.testing.allocator;
    var tracker = Tracker.init(a);
    defer tracker.deinit();
    try std.testing.expectEqualDeep(Progress.unknown(), tracker.progress());
    tracker.setBaseline(try Baseline.fromBytes(a, "x\r\n"));
    for ("x\r\n") |byte| tracker.scalar(byte);
    try std.testing.expectEqualDeep(Progress{ .added = 0, .deleted = 0 }, tracker.progress());
    tracker.scalar('z');
    try std.testing.expectEqualDeep(Progress{ .added = 1, .deleted = 0 }, tracker.progress());
}
