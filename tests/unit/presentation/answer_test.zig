test "shared canonical classification cannot promote truncated tools to final answer" {
    const text = [_]p.Block{.{ .text = "answer" }};
    try std.testing.expectEqual(Kind.final, classify(&text, true));
    try std.testing.expectEqual(Kind.incomplete, classify(&text, false));
    try std.testing.expectEqual(Kind.intermediate, classify(&.{.{ .tool_call = .{ .id = "id", .name = "bash", .arguments = "{}" } }}, true));
}
