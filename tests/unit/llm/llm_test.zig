test "SystemOne is never sent to the generative model or fallback" {
    var selector = Selector.init(.systemone);
    var fake = Fake{};
    const result = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expectEqual(@as(u8, 0), result.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(!result.fallback);
    try std.testing.expectEqual(p.FailureKind.unsupported_protocol, result.outcome.failure.kind);
    selector = Selector.init(.auto);
    var request = testRequest();
    request.scope.protocol = .systemone;
    const automatic = try selector.call(fake.model(), std.testing.allocator, request, .{});
    try std.testing.expectEqual(@as(u8, 0), automatic.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(!selector.initial_attempted);
}
test "auto falls back once and remains pinned even when Chat fails" {
    var selector = Selector.init(.auto);
    var fake = Fake{ .fail_chat = true };
    const first = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expect(first.fallback);
    try std.testing.expectEqual(@as(u8, 2), first.calls);
    try std.testing.expectEqual(@as(?u64, 7), first.fallback_usage.?.input_tokens);
    try std.testing.expectEqual(p.Protocol.responses, fake.protocols[0]);
    try std.testing.expectEqual(p.Protocol.chat, fake.protocols[1]);
    _ = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqual(p.Protocol.chat, fake.protocols[2]);
}
test "explicit protocols and content never permit auto fallback" {
    var explicit = Selector.init(.responses);
    var fake = Fake{};
    _ = try explicit.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    var automatic = Selector.init(.auto);
    fake = .{ .delta = true };
    _ = try automatic.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(p.Protocol.responses, automatic.selected.?);
}
test "ordinary errors cannot reopen the initial selection window" {
    var selector = Selector.init(.auto);
    var fake = Fake{ .kind = .authentication };
    _ = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    fake.kind = .unsupported_protocol;
    const next = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expect(!next.fallback);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}
test "summary and existing model history cannot select a new protocol" {
    var selector = Selector.init(.auto);
    var fake = Fake{};
    var request = testRequest();
    request.purpose = .summary;
    try std.testing.expectError(error.ProtocolNotSelected, selector.call(fake.model(), std.testing.allocator, request, .{}));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    request.purpose = .normal;
    request.messages = &.{.{ .role = .assistant, .blocks = &.{.{ .text = "prior" }} }};
    const result = try selector.call(fake.model(), std.testing.allocator, request, .{});
    try std.testing.expect(!result.fallback);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
test "pre-cancelled calls do not use a model" {
    var selector = Selector.init(.auto);
    var fake = Fake{};
    var cancellation = p.Cancellation{};
    cancellation.cancel();
    var request = testRequest();
    request.cancellation = &cancellation;
    const result = try selector.call(fake.model(), std.testing.allocator, request, .{});
    try std.testing.expectEqual(@as(u8, 0), result.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}
