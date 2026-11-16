test "input history retains owned chronological entries and prepares transactionally" {
    const a = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(a);
    try std.testing.expect(h.target(false) == null and h.target(true) == null);
    const abandoned = try h.prepare(a, "not submitted");
    History.discard(a, abandoned);
    try std.testing.expectEqual(@as(usize, 0), h.entries.items.len);
    for (0..70) |i| {
        var buf: [32]u8 = undefined;
        h.commit(a, try h.prepare(a, try std.fmt.bufPrint(&buf, "input-{d}", .{i})));
    }
    try std.testing.expectEqual(@as(usize, 70), h.entries.items.len);
    try std.testing.expectEqualStrings("input-0", h.entries.items[0]);
    try std.testing.expectEqualStrings("input-69", h.target(false).?.text);
    h.index = 69;
    try std.testing.expectEqualStrings("", h.target(true).?.text);
    try std.testing.expect(h.target(true).?.index == null);
    h.index = 0;
    try std.testing.expectEqual(@as(?usize, 0), h.target(false).?.index);
    const big = try a.alloc(u8, 65537);
    defer a.free(big);
    @memset(big, 'x');
    for (0..18) |_| h.commit(a, try h.prepare(a, big));
    try std.testing.expectEqual(@as(usize, 88), h.entries.items.len);
    try std.testing.expectEqualStrings("input-0", h.entries.items[0]);
    try std.testing.expectEqualSlices(u8, big, h.entries.items[87]);
}
test "input history keeps the newest bounded window" {
    const a = std.testing.allocator;
    var h: History = .{};
    defer h.deinit(a);
    for (0..300) |i| {
        var buf: [32]u8 = undefined;
        h.commit(a, try h.prepare(a, try std.fmt.bufPrint(&buf, "bounded-{d}", .{i})));
    }
    try std.testing.expectEqual(History.max_entries, h.entries.items.len);
    try std.testing.expectEqualStrings("bounded-44", h.entries.items[0]);
    try std.testing.expectEqualStrings("bounded-299", h.entries.items[h.entries.items.len - 1]);
    try std.testing.expect(h.bytes <= History.max_bytes);
}

test "input history allocation failure preserves existing entries" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
