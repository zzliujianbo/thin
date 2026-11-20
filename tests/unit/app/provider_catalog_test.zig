test "provider presets select exact protocols and keep Zen and Go separate" {
    for (entries, 0..) |entry, index| {
        const config: cfg.Config = .{ .provider = connection(entry.provider), .model = entry.model };
        try cfg.validate(config);
        try std.testing.expect(entry.model.protocol != .auto);
        try std.testing.expect(entry.model.reasoning == null); // IDs/protocols are presets, capabilities are not.
        try std.testing.expectEqual(entry.provider, Id.fromUrl(config.provider.base_url).?);
        try std.testing.expectEqual(entry.provider, find(entry.selector).?.provider);
        for (entries[0..index]) |previous| try std.testing.expect(!std.mem.eql(u8, entry.selector, previous.selector));
    }
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", connection(.opencode_go).base_url);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1", connection(.opencode_zen).base_url);
    try std.testing.expect(find("opencode-go/claude-haiku-5-5").?.model.protocol == .anthropic);
    try std.testing.expect(find("opencode-zen/gemini-3-pro") == null);
    var go_count: usize = 0;
    for (entries) |entry| if (entry.provider == .opencode_go) {
        go_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 33), go_count);
    try std.testing.expect(find("opencode-go/minimax-m2.7").?.model.protocol == .anthropic);
    try std.testing.expect(find("opencode-go/qwen3.8-max").?.model.protocol == .anthropic);
    try std.testing.expect(find("opencode-go/muse-spark-1.3-contributor").?.model.protocol == .responses);
    try std.testing.expect(find("opencode-go/kimi-k3").?.model.protocol == .chat);
    try std.testing.expect(find("opencode-go/gpt-6-luna").?.model.reasoning == null); // Dynamic models.dev metadata is loaded through /model.
    try std.testing.expect(find("opencode-go/claude-haiku-5-5").?.model.reasoning == null);
}
