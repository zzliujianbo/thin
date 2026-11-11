//! Small local preset list, not live model discovery or an availability claim.
//! IDs, endpoints and windows were checked against the
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
const minimax: cfg.Model = .{ .name = "minimax-m2.7", .context_tokens = 204800, .protocol = .chat };
const luna: cfg.Model = .{ .name = "gpt-5.6-luna", .context_tokens = 1050000, .protocol = .responses };

fn go(comptime name: []const u8, protocol: @import("../core/protocol.zig").Protocol) Entry {
    return .{ .provider = .opencode_go, .selector = "opencode-go/" ++ name, .model = .{ .name = name, .context_tokens = 32768, .protocol = protocol } };
}

pub const entries = [_]Entry{
    .{ .provider = .deepseek, .selector = "deepseek/deepseek-flash", .model = .{ .name = "deepseek-flash", .context_tokens = 1000000, .protocol = .chat } },
    .{ .provider = .deepseek, .selector = "deepseek/deepseek-v4-pro", .model = .{ .name = "deepseek-v4-pro", .context_tokens = 1000000, .protocol = .chat } },
    .{ .provider = .opencode_zen, .selector = "opencode-zen/minimax-m2.7", .model = minimax },
    .{ .provider = .opencode_zen, .selector = "opencode-zen/gpt-5.2", .model = .{ .name = "gpt-5.2", .context_tokens = 400000, .protocol = .responses } },
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

/// Exact model-to-wire bindings published by OpenCode's endpoint table:
/// https://opencode.ai/docs/zen/ . This supplies ONLY a protocol when live
/// metadata omits it, never discovery/availability or generative capabilities.
/// Do not broaden to prefixes, case folding, Go or arbitrary endpoint aliases.
pub fn documentedProtocol(id: Id, raw_id: []const u8) ?@import("../core/protocol.zig").Protocol {
    if (id == .opencode_zen and
        (std.mem.eql(u8, raw_id, "jev-1.13") or std.mem.eql(u8, raw_id, "jev-1.13-free"))) return .systemone;
    return null;
}

/// Official pricing documents a flat context-length schedule within 1M for
/// these two exact direct Chat routes (not reseller routes or name prefixes).
/// Source: https://api-docs.deepseek.com/quick_start/pricing/
/// Peak/off-peak and cache-hit prices still vary: this only covers length.
/// Keep the proven range separate from the first tier surcharge threshold.
/// Exact fetched surcharge thresholds take precedence in model_resolver.
/// Unknown/future IDs deliberately have no fallback.
pub fn flatPriceLimit(entry: Entry) ?u32 {
    if (entry.provider != .deepseek or entry.model.protocol != .chat) return null;
    if (std.mem.eql(u8, entry.model.name, "deepseek-flash") or
        std.mem.eql(u8, entry.model.name, "deepseek-v4-pro")) return 1000000;
    return null;
}

pub fn connection(id: Id) cfg.Provider {
    return .{ .kind = id, .base_url = id.baseUrl(), .chat_max_tokens = true };
}
pub fn find(selector: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, selector, entry.selector)) return entry;
    return null;
}
