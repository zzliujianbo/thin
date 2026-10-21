//! Exact, opt-in image auxiliary selection. No inference, borrowed credentials
//! or model-name heuristics. Public metadata alone never invents availability.
const std = @import("std");
const cfg = @import("../core/config.zig");
const image = @import("../core/image.zig");
const metadata = @import("model_metadata.zig");
pub const Choice = @import("decision_selection.zig").Choice;

/// Only this documented official Anthropic base has a proven Chat equivalent.
/// Custom endpoints are never rewritten to a different host or provider.
pub fn baseUrl(provider: cfg.NamedProvider) ![]const u8 {
    const base = std.mem.trimEnd(u8, provider.connection.base_url, "/");
    if (cfg.providers.Id.fromSystemOneUrl(base) != null) return error.UnsupportedImageEndpoint;
    if (provider.patchFor(image.model_id)) |patch| {
        if (patch.protocol == .systemone) return error.UnsupportedImageEndpoint;
    }
    const normalized = if (std.mem.eql(u8, base, "https://api.deepseek.com/anthropic"))
        "https://api.deepseek.com"
    else
        provider.connection.base_url;
    if (cfg.providers.Id.fromUrl(normalized)) |service| {
        if (provider.connection.kind) |hint| if (hint != service) return error.ProviderEndpointMismatch;
    }
    // A custom gateway's main protocol does not establish its image protocol.
    // Explicit image selection uses Chat at the unchanged configured base.
    return normalized;
}

/// A manual declaration is explicit availability, as in the normal resolver;
/// otherwise require an actually observed official row, not a public vote.
pub fn available(config: cfg.Config, cache: *const metadata.Cache, provider_name: []const u8) bool {
    const registry = config.registry orelse return false;
    const provider = registry.find(provider_name) orelse return false;
    const base = baseUrl(provider) catch return false;
    if (provider.patchFor(image.model_id) != null) return true;
    const service = cfg.providers.Id.fromUrl(base) orelse return false;
    if (provider.connection.kind) |hint| if (hint != service) return false;
    const index = cache.directory.find(service, image.model_id) orelse return false;
    return cache.directory.rows[index].available == true;
}

/// Edits only an arena-owned clone; the Session rechecks membership and key.
pub fn apply(a: std.mem.Allocator, config: *cfg.Config, choice: Choice) !bool {
    switch (choice) {
        .off => {
            if (!config.image.enabled) return false;
            config.image.enabled = false;
            return true;
        },
        .model => |name| {
            const ref = try cfg.splitDefault(name);
            if (!std.mem.eql(u8, ref.model, image.model_id)) return error.InvalidImageModel;
            const provider = (config.registry orelse return error.MissingRegistry).find(ref.provider) orelse return error.UnknownProvider;
            _ = try baseUrl(provider);
            config.image.enabled = true;
            config.image.model = try a.dupe(u8, name);
            return true;
        },
    }
}

test "image selector accepts only exact Flash declarations and never changes primary" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","models":{"chat":{"context_tokens":32768,"protocol":"chat"}}},"vision":{"base_url":"http://vision.invalid/v1","models":{"deepseek-flash":{"protocol":"anthropic"}}},"similar":{"base_url":"http://similar.invalid/v1","models":{"deepseek-v4-flash":{}}}}}}
    );
    defer cfg.release(&parsed);
    const cache = try a.create(metadata.Cache);
    defer a.destroy(cache);
    cache.* = .{};
    try std.testing.expect(available(parsed.value, cache, "vision"));
    try std.testing.expect(!available(parsed.value, cache, "similar"));
    try std.testing.expect(!available(parsed.value, cache, "main"));
    const before = parsed.value.provider.base_url;
    try std.testing.expect(try apply(parsed.arena.allocator(), &parsed.value, .{ .model = "vision/deepseek-flash" }));
    try std.testing.expect(parsed.value.imageActive());
    try std.testing.expectEqualStrings(before, parsed.value.provider.base_url);
    try std.testing.expectError(error.InvalidImageModel, apply(parsed.arena.allocator(), &parsed.value, .{ .model = "vision/deepseek-v4-flash" }));
    try std.testing.expect(try apply(parsed.arena.allocator(), &parsed.value, .off));
    try std.testing.expect(!parsed.value.imageActive());
    try std.testing.expectEqualStrings("vision/deepseek-flash", parsed.value.image.model.?);
}
