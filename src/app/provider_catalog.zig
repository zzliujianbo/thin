//! Small local preset list, not live model discovery or an availability claim.
//! IDs, endpoints, windows and explicit effort maps were checked against the
//! public Pi 1.2.0 pi-ai providers/data/{deepseek,opencode,opencode-go}.json.
//! Go IDs/protocols follow the official endpoint table at opencode.ai/docs/go.
//! Newly added capacities are conservative LOCAL defaults, not official limits.
//! Official /models refresh controls availability of these verified mappings.
//! Never infer a model's protocol or thinking controls from its name.
const std = @import("std");
const cfg = @import("../core/config.zig");
pub const Id = cfg.providers.Id;

pub const Entry = struct {
    provider: Id,
    selector: []const u8,
    model: cfg.Model,
};
const standard_high: @import("../core/thinking.zig").Declaration = .{ .map = .{
    .low = "low",
    .medium = "medium",
    .high = "high",
    .xhigh = "xhigh",
} };
const standard_max: @import("../core/thinking.zig").Declaration = .{ .map = .{
    .low = "low",
    .medium = "medium",
    .high = "high",
    .xhigh = "xhigh",
    .max = "max",
} };
const minimax: cfg.Model = .{ .name = "minimax-m2.7", .context_tokens = 204800, .protocol = .chat };
const luna: cfg.Model = .{ .name = "gpt-5.6-luna", .context_tokens = 1050000, .protocol = .responses, .reasoning = standard_max };

fn go(comptime name: []const u8, protocol: @import("../core/protocol.zig").Protocol) Entry {
    return .{ .provider = .opencode_go, .selector = "opencode-go/" ++ name, .model = .{ .name = name, .context_tokens = 32768, .protocol = protocol } };
}

pub const entries = [_]Entry{
    .{ .provider = .deepseek, .selector = "deepseek/deepseek-flash", .model = .{ .name = "deepseek-flash", .context_tokens = 1000000, .protocol = .chat } },
    .{ .provider = .deepseek, .selector = "deepseek/deepseek-v4-pro", .model = .{ .name = "deepseek-v4-pro", .context_tokens = 1000000, .protocol = .chat } },
    .{ .provider = .opencode_zen, .selector = "opencode-zen/minimax-m2.7", .model = minimax },
    .{ .provider = .opencode_zen, .selector = "opencode-zen/gpt-5.2", .model = .{ .name = "gpt-5.2", .context_tokens = 400000, .protocol = .responses, .reasoning = standard_high } },
    .{ .provider = .opencode_zen, .selector = "opencode-zen/gpt-5.6-luna", .model = luna },
    .{ .provider = .opencode_go, .selector = "opencode-go/minimax-m2.7", .model = .{ .name = "minimax-m2.7", .context_tokens = 204800, .protocol = .anthropic } },
    .{ .provider = .opencode_go, .selector = "opencode-go/gpt-5.6-luna", .model = luna },
    go("claude-haiku-5-5", .anthropic),
    go("grok-4.7", .responses),
    go("grok-4.6", .responses),
    go("gpt-6-luna", .responses),
    go("glm-5.3-flash", .chat),
    go("glm-5.3", .chat),
    go("glm-5.2", .chat),
    go("kimi-k3", .chat),
    go("kimi-k2.7-code", .chat),
    go("kimi-k2.6", .chat),
    go("longcat-2.0", .chat),
    go("deepseek-v4.1-flash", .chat),
    go("deepseek-v4-pro", .chat),
    go("deepseek-v4-flash", .chat),
    go("deepseek-v4-flash-vision-exp", .chat),
    go("mimo-v2.6-flash", .chat),
    go("mimo-v2.6-pro", .chat),
    go("mimo-v2.5", .chat),
    go("mimo-v2.5-pro", .chat),
    go("minimax-m3", .anthropic),
    go("muse-spark-1.3-contributor", .responses),
    go("muse-spark-1.2-contributor", .responses),
    go("qwen3.8-max", .anthropic),
    go("qwen3.8-flash", .anthropic),
    go("qwen3.7-plus", .anthropic),
    go("hy4-preview", .chat),
    go("hy3", .chat),
    go("space-bunny", .chat),
    go("longcat-2.5-preview-free", .chat),
    go("step-5-preview-free", .chat),
    go("cat-jam-free", .chat),
};

pub fn connection(id: Id) cfg.Provider {
    return .{ .kind = id, .base_url = id.baseUrl(), .chat_max_tokens = true };
}
pub fn first(id: Id) Entry {
    for (entries) |entry| if (entry.provider == id) return entry;
    unreachable;
}
pub fn find(selector: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, selector, entry.selector)) return entry;
    return null;
}

test "provider presets select exact protocols and keep Zen and Go separate" {
    for (entries, 0..) |entry, index| {
        const config: cfg.Config = .{ .provider = connection(entry.provider), .model = entry.model };
        try cfg.validate(config);
        try std.testing.expect(entry.model.protocol != .auto);
        try std.testing.expectEqual(entry.provider, Id.fromUrl(config.provider.base_url).?);
        try std.testing.expectEqual(entry.provider, find(entry.selector).?.provider);
        for (entries[0..index]) |previous| try std.testing.expect(!std.mem.eql(u8, entry.selector, previous.selector));
    }
    for (Id.all) |id| try std.testing.expectEqual(id, first(id).provider);
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
