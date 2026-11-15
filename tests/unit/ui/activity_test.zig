test "terminal spinner retains fixed80ms independent of shared TPS flow" {
    try std.testing.expect(!std.mem.eql(u8, spinner(0), spinner(80)));
    try std.testing.expectEqualStrings(spinner(0), spinner(800));
    try std.testing.expectEqualStrings("⠧", spinner(600));
    try std.testing.expect(labelInterval(1000) < labelInterval(100));
}

test "execution flow head bounces between both row edges" {
    const flow = @import("../presentation/activity.zig");
    const limit = 5;
    var seen: [8]usize = undefined;
    var directions: [8]bool = undefined;
    for (0..8) |i| {
        const head = flow.flowHead(40 * i, limit);
        seen[i] = head.column;
        directions[i] = head.backward;
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 3, 2, 1 }, &seen);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, false, false, true, true, true }, &directions);
    // One full period returns to the first frame; a one-column row stays put.
    try std.testing.expectEqual(flow.flowHead(0, limit).column, flow.flowHead(40 * 8, limit).column);
    try std.testing.expectEqual(flow.flowHead(0, 1), flow.flowHead(400, 1));
}
