test "subagent tool progress chunked text and ignored events" {
    var v: Projection = .{};
    v.observe(.{ .text = "one\n\xe4" });
    v.observe(.{ .text = "\xb8\xad" });
    v.observe(.{ .reasoning = "secret" });
    v.observe(.{ .assistant_committed = &.{
        .{ .reasoning = "hidden reasoning" },
        .{ .tool_call = .{ .id = "call", .name = "bash", .arguments = "private arguments" } },
        .{ .tool_result = .{ .call_id = "call", .text = "private output" } },
        .{ .text = "中" },
    } });
    try std.testing.expectEqualStrings("中", v.current());
    v.observe(.{ .state = .calling_model });
    try std.testing.expectEqualStrings("中", v.current());
}
test "subagent tool progress split ANSI control sequences" {
    var v: Projection = .{};
    v.feed("中\tA\x1b[");
    v.feed("2J\x1b[31");
    v.feed("mB\x1b]8;;https://private.invalid");
    v.feed("\x1b");
    v.feed("\\C\x1b]title\x07D");
    try std.testing.expectEqualStrings("中 ABCD", v.current());
}
test "subagent tool progress bounded lines and controls" {
    var v: Projection = .{};
    v.feed("old\rnew\x1b[31m\nlast\x00 line");
    try std.testing.expectEqualStrings("last line", v.current());
    v.begin();
    var long: [2048]u8 = undefined;
    @memset(&long, 'x');
    v.feed(&long);
    v.feed("中");
    try std.testing.expectEqual(@as(usize, 2048), v.current().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(v.current()));
    v.observe(.{ .tool_preview = .{ .index = 0, .arguments = "secret" } });
    try std.testing.expectEqual(@as(usize, 2048), v.current().len);
}
