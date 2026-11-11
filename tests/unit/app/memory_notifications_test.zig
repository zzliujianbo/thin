test "completion FIFO peeks without consuming and owns full values" {
    const q = try Queue.create(std.testing.allocator);
    defer q.deinit();
    var first: status.Terminal = .{ .id = 4, .result = .saved, .saved_count = 2 };
    first.summary.append("first saved fact");
    q.publish(q.reserve().?, first);
    q.publish(q.reserve().?, .{ .id = 5, .result = .canceled, .failure = .canceled });
    try std.testing.expectEqual(@as(u64, 4), q.peek().?.id);
    try std.testing.expectEqual(@as(u64, 4), q.peek().?.id);
    const taken = q.take().?;
    try std.testing.expectEqual(@as(u32, 2), taken.saved_count);
    try std.testing.expectEqualStrings("first saved fact", taken.summary.text());
    try std.testing.expectEqual(@as(u64, 5), q.take().?.id);
    try std.testing.expect(q.peek() == null);
}
test "reserved emergency nodes survive OOM and can be reused" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const q = try Queue.create(failing.allocator());
    defer q.deinit();
    failing.fail_index = failing.alloc_index;
    for (0..q.emergency.len) |i| q.publish(q.reserve().?, .{ .id = @intCast(i + 1), .result = .failed });
    try std.testing.expect(q.reserve() == null);
    try std.testing.expectEqual(@as(u64, 1), q.take().?.id);
    q.publish(q.reserve().?, .{ .id = 9, .result = .skipped });
    for (2..10) |i| try std.testing.expectEqual(@as(u64, @intCast(i)), q.take().?.id);
    try std.testing.expect(q.take() == null);
}
