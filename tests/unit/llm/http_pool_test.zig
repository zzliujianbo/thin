test "idle expiry has exact boundary regression and overflow safe clock arithmetic" {
    const start: Io.Timestamp = .fromNanoseconds(100 * std.time.ns_per_ms);
    try std.testing.expect(expired(null, start));
    try std.testing.expect(!expired(start, start));
    try std.testing.expect(!expired(start, .fromNanoseconds(start.nanoseconds + (idle_limit_ms - 1) * std.time.ns_per_ms)));
    try std.testing.expect(expired(start, .fromNanoseconds(start.nanoseconds + idle_limit_ms * std.time.ns_per_ms)));
    try std.testing.expect(expired(start, .fromNanoseconds(start.nanoseconds - 1)));
    try std.testing.expect(expired(.fromNanoseconds(std.math.minInt(i96)), .fromNanoseconds(std.math.maxInt(i96))));
}
test "empty idle sweep never visits used nodes and invalid pool bounds fail closed" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var active: std.DoublyLinkedList.Node = .{};
    client.connection_pool.used.append(&active);
    defer client.connection_pool.used.remove(&active);
    try pruneWith(&client, null, .zero, unexpectedPoll);
    try std.testing.expectEqual(&active, client.connection_pool.used.first.?);
    client.connection_pool.free_size = max_idle + 1;
    try std.testing.expectError(error.ConnectionPoolLimit, pruneWith(&client, null, .zero, unexpectedPoll));
}
