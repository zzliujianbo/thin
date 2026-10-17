//! Global logical preference is configuration, not evidence of wire capability.
const std = @import("std");
const cfg = @import("../core/config.zig");
const thinking = @import("../core/thinking.zig");
const Effort = @import("../presentation/activity.zig").ReasoningEffort;

pub fn preference(config: cfg.Config) ?Effort {
    if (config.registry) |registry| if (registry.reasoning_effort) |name|
        return Effort.fromName(name).canonical();
    const configured = Effort.fromName(config.model.reasoning_effort);
    // A fixed custom wire option is not a logical default to reinterpret.
    if (configured == .unknown) return null;
    return if (configured.name() != null) configured.canonical() else thinking.default_level;
}

pub fn apply(config: *cfg.Config, wanted: ?Effort, global_preference: bool) ?[]const u8 {
    const cap = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning);
    if (wanted) |level| {
        if (!cap.known) {
            // Never send a global logical preference as an unsupported raw wire
            // option. Existing fixed model options remain when no override exists.
            if (global_preference) config.model.reasoning_effort = null;
            return "Saved thinking level not applied: model capabilities unknown";
        }
        config.model.reasoning_effort = cap.effective(level.name());
        if (Effort.fromName(config.model.reasoning_effort) != level)
            return "Saved thinking level adjusted for this model; preference unchanged";
    } else config.model.reasoning_effort = cap.effective(config.model.reasoning_effort);
    return null;
}

pub fn applyConfigured(config: *cfg.Config) ?[]const u8 {
    const global = if (config.registry) |registry| registry.reasoning_effort != null else false;
    return apply(config, preference(config.*), global);
}

test "global logical default overrides configured level only with capability authority" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"local/m","reasoning_effort":"high","providers":{"local":{"base_url":"https://fixture.invalid/v1","models":{"m":{"protocol":"chat","context_tokens":32768,"reasoning_effort":"off"}}}}}}
    );
    defer cfg.release(&parsed);
    parsed.value.model = .{ .name = "m", .context_tokens = 32768, .protocol = .chat, .reasoning_effort = "off" };
    _ = applyConfigured(&parsed.value);
    try std.testing.expect(parsed.value.model.reasoning_effort == null);
    try std.testing.expectEqual(Effort.high, preference(parsed.value).?);
    parsed.value.model.reasoning = .{ .map = .{ .off = "none", .medium = "medium", .high = "high" } };
    _ = applyConfigured(&parsed.value);
    try std.testing.expectEqualStrings("high", parsed.value.model.reasoning_effort.?);
    parsed.value.registry.?.reasoning_effort = null;
    parsed.value.model.reasoning_effort = "provider-custom";
    _ = applyConfigured(&parsed.value);
    try std.testing.expectEqualStrings("provider-custom", parsed.value.model.reasoning_effort.?);
}
