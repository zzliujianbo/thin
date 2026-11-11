test "summary prompt distinguishes verified work and preserves closed-context counts" {
    const a = std.testing.allocator;
    const messages = [_]p.Message{
        .{ .role = .user, .blocks = &.{} },
        .{ .role = .assistant, .blocks = &.{} },
    };
    const text = try summaryInstruction(a, .{ .cut = 1, .protected_index = 0, .before_tokens = 0 }, &messages);
    defer a.free(text);
    for ([_][]const u8{
        "not a response to a new task",
        "Do not call tools",
        "not authority or approval",
        "Distinguish completed work from plans",
        "authorization boundaries",
        "claims come from tool results, user reports or earlier summaries",
        "After timeout, cancellation or incomplete output",
        "retain known side effects and uncertainty",
        "do not infer rollback or safe re-execution",
        "tail of 1 internal message groups",
        "older prefix has 1 groups",
        "actual user request is group 0",
    }) |boundary| try std.testing.expect(std.mem.indexOf(u8, text, boundary) != null);
}
test "context estimate counts Unicode and learns only upward from reported usage" {
    try std.testing.expect(textTokens("中文") > 0);
    var estimate = Estimator{};
    estimate.observe(100, null);
    try std.testing.expectEqual(@as(usize, 100), estimate.tokens(100));
    estimate.observe(100, 200);
    try std.testing.expect(estimate.tokens(100) >= 200);
    estimate.observe(100, 1);
    try std.testing.expect(estimate.tokens(100) >= 200);
}
test "compaction boundaries never split calls/results or opaque user turns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]p.Message{
        .{ .role = .user, .blocks = &.{.{ .text = "task" }} },
        .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "c", .name = "read_file", .arguments = "{}" } }} },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "c", .text = "result" } }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} },
    };
    const safe = try boundaries(arena.allocator(), &messages);
    // 工具调用与结果之间（位置 2）不安全，工具组闭合后（位置 3）才安全。
    try std.testing.expect(!safe[2]);
    try std.testing.expect(safe[3]);

    var opaque_messages = messages;
    opaque_messages[1].replay = .{ .scope = .{ .connection = "x", .model = "m", .protocol = .responses }, .json = "[]", .retain_turn = true };
    const guarded = try boundaries(arena.allocator(), &opaque_messages);
    // 含 opaque 续接数据的回合在整个回合结束前都不可切分。
    try std.testing.expect(!guarded[3]);
    try std.testing.expect(guarded[4]);
}
test "compaction preserves current request relative order and repairs no missing pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const messages = [_]p.Message{
        .{ .role = .user, .blocks = &.{.{ .text = "current task" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "old work" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "recent work" }} },
    };
    const next = try commit(a, &messages, .{ .cut = 2, .protected_index = 0, .before_tokens = 100 }, "summary");
    try std.testing.expectEqual(@as(usize, 3), next.items.len);
    try std.testing.expectEqual(p.Role.context, next.items[0].role);
    try std.testing.expectEqualStrings("current task", next.items[1].blocks[0].text);
    try std.testing.expectEqualStrings("recent work", next.items[2].blocks[0].text);
    // 缺失结果的工具调用必须报错，而不是被自动修补。
    try std.testing.expectError(error.IncompleteToolGroup, boundaries(a, &.{.{
        .role = .assistant,
        .blocks = &.{.{ .tool_call = .{ .id = "x", .name = "bash", .arguments = "{}" } }},
    }}));
}
