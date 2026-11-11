test "usage preserves unknown values and does not double-count reasoning or cache" {
    const t = std.testing;
    try t.expectEqual(@as(?u64, null), (Usage{}).total());
    try t.expectEqual(@as(?u64, 15), (Usage{
        .input_tokens = 10,
        .output_tokens = 5,
        .cached_input_tokens = 8,
        .reasoning_tokens = 3,
    }).total());
}
test "cancellation reads the parent one way and writes locally only" {
    var root: Cancellation = .{};
    var child: Cancellation = .{ .parent = &root };
    try std.testing.expect(!child.isRequested());
    child.cancel();
    try std.testing.expect(child.isRequested());
    try std.testing.expect(!root.isRequested());
    var sibling: Cancellation = .{ .parent = &root };
    try std.testing.expect(!sibling.isRequested());
    root.cancel();
    try std.testing.expect(sibling.isRequested());
    var self_link: Cancellation = .{};
    self_link.parent = &self_link;
    try std.testing.expect(!self_link.isRequested());
}
test "replay compatibility includes connection, model and protocol" {
    const a = ReplayScope{ .connection = "https://a/v1", .model = "model", .protocol = .responses };
    var b = a;
    try std.testing.expect(a.eql(b));
    b.protocol = .chat;
    try std.testing.expect(!a.eql(b));
    b = a;
    b.connection = "https://b/v1";
    try std.testing.expect(!a.eql(b));
}
