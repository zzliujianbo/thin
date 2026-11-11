test "selection projection omits codex credentials" {
    const config: cfg.Config = .{
        .provider = .{ .base_url = cfg.providers.Id.openai_codex.baseUrl(), .kind = .openai_codex, .codex_oauth = .{ .access_token = "access-canary-private", .refresh_token = "refresh-canary-private", .expires_at_ms = 1 } },
        .model = .{ .name = "fixture", .context_tokens = 32768, .protocol = .responses },
    };
    const snapshot = try capture(config);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(&out.writer, &snapshot);
    const bytes = out.written();
    for ([_][]const u8{ "access-canary-private", "refresh-canary-private", "codex_oauth" }) |secret| try std.testing.expect(std.mem.indexOf(u8, bytes, secret) == null);
    const parsed = try parse(std.testing.allocator, bytes);
    try std.testing.expectEqualStrings("fixture", parsed.model());
    try std.testing.expectEqual(p.Protocol.responses, parsed.protocol);
}
test "selection v2 strict schema owns metadata and requires all eight fields" {
    const a = std.testing.allocator;
    var snapshot = try fixtureSnapshot();
    var buffer: [max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encode(&writer, &snapshot);
    const restored = try parse(a, writer.buffered());
    try std.testing.expectEqualStrings(snapshot.model(), restored.model());
    try std.testing.expectEqual(cfg.providers.Id.opencode_go, restored.provider.?);
    try std.testing.expectEqual(activity.ReasoningEffort.high, restored.effort.?);
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "https://") == null);
    const missing = try std.mem.replaceOwned(u8, a, writer.buffered(), "\"provider_name\":null,", "");
    defer a.free(missing);
    try std.testing.expectError(error.InvalidSelection, parse(a, missing));
    for ([_][]const u8{ "{}", "[]", "{\"version\":2,\"version\":2}", "\xff" }) |invalid| {
        if (parse(a, invalid)) |_| return error.AcceptedInvalidSelection else |_| {}
    }
    const tail = writer.buffered()["{\"version\":2".len..];
    for ([_][]const u8{ "{\"version\":1", "{\"version\":\"2\"", "{\"version\":2.0", "{\"extra\":0,\"version\":2" }) |prefix| {
        const invalid = try std.mem.concat(a, u8, &.{ prefix, tail });
        defer a.free(invalid);
        if (parse(a, invalid)) |_| return error.AcceptedInvalidSelection else |_| {}
    }
    @memset(&buffer, 'x');
    try std.testing.expectEqualStrings("gpt-5.6-luna", restored.model());
}
