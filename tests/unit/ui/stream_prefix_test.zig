test "prefix owns row descriptors and styling bytes independently" {
    var text = "\x1b[31mhello\x1b[0m".*;
    var rows = [_][]const u8{ &text, "" };
    var prefix = (try Prefix.capture(std.testing.allocator, &rows, 80)).?;
    defer prefix.deinit();
    @memset(&text, 'x');
    rows[1] = "changed";
    try std.testing.expect(prefix.matches(&.{ "\x1b[31mhello\x1b[0m", "" }, 80));
    try std.testing.expect(prefix.matches(&.{ "\x1b[31mhello\x1b[0m", "", "more" }, 80));
    try std.testing.expectEqual(@as(usize, 2), prefix.rowCount());
    try std.testing.expectEqual(@as(usize, "\x1b[31mhello\x1b[0m".len), prefix.byteCount());
    try std.testing.expectEqual(@as(usize, 80), prefix.columns);
}
test "prefix requires full exact styled prefix and same columns" {
    var prefix = (try Prefix.capture(std.testing.allocator, &.{ "\x1b[31mx", "y" }, 80)).?;
    defer prefix.deinit();
    try std.testing.expect(prefix.matches(&.{ "\x1b[31mx", "y" }, 80));
    try std.testing.expect(!prefix.matches(&.{ "\x1b[34mx", "y" }, 80));
    try std.testing.expect(!prefix.matches(&.{ "\x1b[31mx", "y" }, 81));
    try std.testing.expect(!prefix.matches(&.{"\x1b[31mx"}, 80));
    try std.testing.expect(!prefix.matches(&.{ "y", "\x1b[31mx" }, 80));
    var empty = (try Prefix.capture(std.testing.allocator, &.{}, 0)).?;
    defer empty.deinit();
    try std.testing.expect(empty.matches(&.{"anything"}, 0));
    try std.testing.expect(!empty.matches(&.{}, 1));
}
test "prefix extension shares the former segments and owns only the new suffix" {
    var base = (try Prefix.capture(std.testing.allocator, &.{ "one", "\x1b[32mtwo\x1b[0m" }, 80)).?;
    defer base.deinit();
    const base_node = base.node;
    const base_bytes = base.byteCount();
    var extended = (try base.extend(std.testing.allocator, &.{"three"}, 80)).?;
    defer extended.deinit();
    // Former segment keeps its ownership; the new node holds the suffix only.
    try std.testing.expect(extended.node.parent != null and extended.node.parent.? == base_node);
    try std.testing.expectEqual(@as(usize, 1), extended.node.rows.len);
    try std.testing.expectEqual(@as(usize, 2), extended.node.start);
    try std.testing.expectEqual(@as(usize, 2), base_node.refs);
    try std.testing.expectEqual(base_bytes, base.byteCount());
    try std.testing.expectEqual(@as(usize, 3), extended.rowCount());
    try std.testing.expectEqual(base_bytes + "three".len, extended.byteCount());
    try std.testing.expect(extended.matches(&.{ "one", "\x1b[32mtwo\x1b[0m", "three" }, 80));
    try std.testing.expect(!extended.matches(&.{ "one", "\x1b[32mtwo\x1b[0m", "THREE" }, 80));
    try std.testing.expect(!extended.matches(&.{ "three", "one", "\x1b[32mtwo\x1b[0m" }, 80));
    try std.testing.expect(!extended.matches(&.{ "one", "\x1b[32mtwo\x1b[0m" }, 80));

    var second = (try extended.extend(std.testing.allocator, &.{ "four", "five" }, 80)).?;
    defer second.deinit();
    try std.testing.expect(second.node.parent != null and second.node.parent.? == extended.node);
    try std.testing.expectEqual(@as(usize, 1), extended.node.rows.len);
    try std.testing.expect(second.matches(&.{ "one", "\x1b[32mtwo\x1b[0m", "three", "four", "five" }, 80));
    try std.testing.expect(!second.matches(&.{ "one", "\x1b[32mtwo\x1b[0m", "three", "four" }, 80));
}
test "prefix bounds reject without allocation and accept exact limits" {
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var rows: [max_rows + 1][]const u8 = @splat("");
    try std.testing.expect((try Prefix.capture(fail.allocator(), &rows, 80)) == null);
    const raw = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(raw);
    @memset(raw, 'x');
    try std.testing.expect((try Prefix.capture(fail.allocator(), &.{raw}, 80)) == null);
    try std.testing.expect((try Prefix.capture(fail.allocator(), &.{ raw[0..max_bytes], "x" }, 80)) == null);
    try std.testing.expectEqual(@as(usize, 0), fail.allocations);
    rows[0] = raw[0..max_bytes];
    var prefix = (try Prefix.capture(std.testing.allocator, rows[0..max_rows], 80)).?;
    defer prefix.deinit();
    try std.testing.expectEqual(max_rows, prefix.rowCount());
    try std.testing.expect(prefix.matches(rows[0..max_rows], 80));
    // Row and byte limits reject an extension before touching the allocator.
    try std.testing.expect((try prefix.extend(fail.allocator(), &.{""}, 80)) == null);
    try std.testing.expect((try prefix.extend(fail.allocator(), &.{"x"}, 80)) == null);
    try std.testing.expectEqual(@as(usize, 0), fail.allocations);

    var small = (try Prefix.capture(std.testing.allocator, &.{raw[0..max_bytes]}, 80)).?;
    defer small.deinit();
    try std.testing.expect((try small.extend(fail.allocator(), &.{"x"}, 80)) == null);
    try std.testing.expect((try small.extend(fail.allocator(), &.{}, 81)) == null);
    try std.testing.expectEqual(@as(usize, 0), fail.allocations);

    // A zero-length suffix is a reference clone that never allocates.
    var clone = (try small.extend(fail.allocator(), &.{}, 80)).?;
    defer clone.deinit();
    try std.testing.expectEqual(@as(usize, 0), fail.allocations);
    try std.testing.expect(clone.node == small.node);
    try std.testing.expectEqual(@as(usize, 2), small.node.refs);
    try std.testing.expectEqual(small.rowCount(), clone.rowCount());
    try std.testing.expectEqual(small.byteCount(), clone.byteCount());
}
test "prefix references keep shared segments alive until the last owner" {
    var root = (try Prefix.capture(std.testing.allocator, &.{"root"}, 10)).?;
    var sibling_left = (try root.extend(std.testing.allocator, &.{"l"}, 10)).?;
    var sibling_right = (try root.extend(std.testing.allocator, &.{"r"}, 10)).?;
    try std.testing.expectEqual(@as(usize, 3), root.node.refs);
    var shared = (try sibling_left.extend(std.testing.allocator, &.{}, 10)).?;
    try std.testing.expectEqual(@as(usize, 2), sibling_left.node.refs);
    try std.testing.expectEqual(@as(usize, 3), root.node.refs);
    shared.deinit();
    try std.testing.expectEqual(@as(usize, 1), sibling_left.node.refs);
    try std.testing.expectEqual(@as(usize, 3), root.node.refs);
    try std.testing.expect(sibling_left.matches(&.{ "root", "l" }, 10));
    sibling_left.deinit();
    try std.testing.expectEqual(@as(usize, 2), root.node.refs);
    try std.testing.expect(sibling_right.matches(&.{ "root", "r" }, 10));
    sibling_right.deinit();
    try std.testing.expectEqual(@as(usize, 1), root.node.refs);
    try std.testing.expect(root.matches(&.{"root"}, 10));
    root.deinit();
}
test "deep prefix chains release iteratively and stay exact" {
    var expected_bytes: usize = "row-0".len;
    var chain = (try Prefix.capture(std.testing.allocator, &.{"row-0"}, 80)).?;
    var row_index: usize = 1;
    while (row_index < max_rows) : (row_index += 1) {
        expected_bytes += std.fmt.count("row-{d}", .{row_index});
        var buffer: [16]u8 = undefined;
        const row = try std.fmt.bufPrint(&buffer, "row-{d}", .{row_index});
        const next = (try chain.extend(std.testing.allocator, &.{row}, 80)) orelse return error.Unexpected;
        chain.deinit(); // The new segment keeps the only reference to the old one.
        chain = next;
    }
    try std.testing.expectEqual(max_rows, chain.rowCount());
    try std.testing.expectEqual(expected_bytes, chain.byteCount());
    // Every segment still compares its own absolute source range exactly.
    var expected_index: usize = max_rows;
    var segment: ?*Prefix.Node = chain.node;
    while (segment) |node| {
        for (node.rows) |row| {
            expected_index -= 1;
            var buffer: [16]u8 = undefined;
            const expected = try std.fmt.bufPrint(&buffer, "row-{d}", .{expected_index});
            try std.testing.expectEqualStrings(expected, row);
        }
        segment = node.parent;
    }
    try std.testing.expectEqual(@as(usize, 0), expected_index);
    chain.deinit();
}
test "prefix allocation failures propagate and clean up all owned bytes" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationScenario, .{});
}
test "failed extension frees partial segments and leaves the base valid" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), extensionScenario, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);

    // Every intermediate OOM index keeps the committed base exact and usable.
    var base = (try Prefix.capture(std.testing.allocator, &.{ "first", "second" }, 100)).?;
    defer base.deinit();
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var next = base.extend(fail.allocator(), &.{ "third", "last" }, 100) catch |err| {
            try std.testing.expect(err == error.OutOfMemory);
            try std.testing.expect(base.matches(&.{ "first", "second" }, 100));
            try std.testing.expectEqual(@as(usize, 1), base.node.refs);
            try std.testing.expectEqual(fail.allocations, fail.deallocations);
            continue;
        };
        if (next) |*value| {
            defer value.deinit();
            try std.testing.expectEqual(@as(usize, 4), value.rowCount());
            try std.testing.expect(value.matches(&.{ "first", "second", "third", "last" }, 100));
        } else unreachable;
    }
}
