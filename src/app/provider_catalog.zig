//! Small local preset list, not live model discovery or an availability claim.
//! IDs, endpoints, windows and explicit effort maps were checked against the
//! public Pi 1.2.0 pi-ai providers/data/{deepseek,opencode,opencode-go}.json.
//! Only Thin's Chat/Responses adapters are offered. Anthropic/Google-only models
//! are intentionally absent; never infer their wire format from a model name.
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

pub const entries = [_]Entry{
    .{ .provider = .deepseek, .selector = "deepseek/deepseek-flash", .model = .{ .name = "deepseek-flash", .context_tokens = 1000000, .protocol = .chat } },
    .{ .provider = .deepseek, .selector = "deepseek/deepseek-v4-pro", .model = .{ .name = "deepseek-v4-pro", .context_tokens = 1000000, .protocol = .chat } },
    .{ .provider = .opencode_zen, .selector = "opencode-zen/minimax-m2.7", .model = minimax },
    .{ .provider = .opencode_zen, .selector = "opencode-zen/gpt-5.2", .model = .{ .name = "gpt-5.2", .context_tokens = 400000, .protocol = .responses, .reasoning = standard_high } },
    .{ .provider = .opencode_zen, .selector = "opencode-zen/gpt-5.6-luna", .model = luna },
    .{ .provider = .opencode_go, .selector = "opencode-go/minimax-m2.7", .model = minimax },
    .{ .provider = .opencode_go, .selector = "opencode-go/gpt-5.6-luna", .model = luna },
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
    try std.testing.expect(find("opencode-go/claude-haiku-5-5") == null);
    try std.testing.expect(find("opencode-zen/gemini-3-pro") == null);
}
