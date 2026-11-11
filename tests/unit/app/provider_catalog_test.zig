test "documented native protocol is exact service identity not availability or a name heuristic" {
    for ([_][]const u8{ "jev-1.13", "jev-1.13-free" }) |name| {
        try std.testing.expectEqual(@as(?@import("../core/protocol.zig").Protocol, .systemone), documentedProtocol(.opencode_zen, name));
        try std.testing.expect(documentedProtocol(.opencode_go, name) == null);
        try std.testing.expect(documentedProtocol(.deepseek, name) == null);
        try std.testing.expect(find(name) == null);
    }
    for ([_][]const u8{ "jev", "jevfree", "Jev-1.13-free", "jev-1.13-free-extra", "family/jev-1.13-free" }) |name|
        try std.testing.expect(documentedProtocol(.opencode_zen, name) == null);
}
test "documented flat price ranges are limited to exact direct DeepSeek Chat routes" {
    for (entries) |entry| {
        if (entry.provider == .deepseek and entry.model.protocol == .chat) {
            try std.testing.expectEqual(@as(?u32, 1000000), flatPriceLimit(entry));
        } else try std.testing.expect(flatPriceLimit(entry) == null);
    }
    var changed = find("deepseek/deepseek-flash").?;
    changed.model.name = "deepseek-flash-future";
    try std.testing.expect(flatPriceLimit(changed) == null);
    changed = find("deepseek/deepseek-flash").?;
    changed.model.protocol = .responses;
    try std.testing.expect(flatPriceLimit(changed) == null);
    changed = find("deepseek/deepseek-flash").?;
    changed.provider = .opencode_go;
    try std.testing.expect(flatPriceLimit(changed) == null);
}
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
