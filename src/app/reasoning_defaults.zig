//! Global logical preference is configuration, not evidence of wire capability.
const std = @import("std");
const cfg = @import("../core/config.zig");
const thinking = @import("../core/thinking.zig");
const Effort = @import("../presentation/activity.zig").ReasoningEffort;

pub fn preference(config: cfg.Config) ?Effort {
    if (config.registry) |registry| if (registry.reasoning_effort) |name|
        return Effort.fromName(name);
    const configured = Effort.fromName(config.model.reasoning_effort);
    // A fixed custom wire option is not a logical default to reinterpret.
    if (configured == .unknown) return null;
    return if (configured.name() != null) configured else thinking.default_level;
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
        if (level == .off and !cap.levels.contains(.off)) {
            config.model.reasoning_effort = null;
            return "Thinking off unsupported by this model";
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

test "default off authorized wires and unsupported or unknown capabilities" {
    const t = std.testing;
    var parsed = try cfg.parse(t.allocator,
        \\{"llm":{"default":"local/m","providers":{"local":{"base_url":"https://fixture.invalid/v1","models":{"m":{"protocol":"chat","context_tokens":32768}}}}}}
    );
    defer cfg.release(&parsed);
    const config = &parsed.value;
    config.model = .{ .name = "m", .context_tokens = 32768, .protocol = .chat };
    try t.expectEqual(Effort.off, preference(config.*).?);
    for ([_]thinking.Format{ .standard, .deepseek, .anthropic }) |format| {
        config.model.reasoning = .{ .format = format, .map = .{ .off = "none", .high = "high" } };
        try t.expect(applyConfigured(config) == null);
        try t.expectEqualStrings("off", config.model.reasoning_effort.?);
        const wire = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning).wire(config.model.reasoning_effort);
        if (format == .standard) {
            try t.expectEqualStrings("none", wire.effort.?);
            try t.expect(wire.thinking == null);
        } else {
            try t.expect(wire.effort == null);
            try t.expectEqual(false, wire.thinking.?);
        }
        config.model.reasoning_effort = null;
    }
    config.model.reasoning = .{ .map = .{ .low = "low", .high = "high" } };
    try t.expectEqualStrings("Thinking off unsupported by this model", applyConfigured(config).?);
    try t.expect(config.model.reasoning_effort == null);
    const no_off = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning).wire(config.model.reasoning_effort);
    try t.expect(no_off.effort == null and no_off.thinking == null);
    config.registry.?.reasoning_effort = "off";
    config.model.reasoning = null;
    config.model.reasoning_effort = "high";
    try t.expect(applyConfigured(config) != null);
    try t.expect(config.model.reasoning_effort == null);
    const unknown = thinking.resolve(config.provider.base_url, config.model.name, null).wire(config.model.reasoning_effort);
    try t.expect(unknown.effort == null and unknown.thinking == null);
}

test "default off preserves saved medium high and fixed custom options" {
    const t = std.testing;
    var parsed = try cfg.parse(t.allocator,
        \\{"llm":{"default":"local/m","providers":{"local":{"base_url":"https://fixture.invalid/v1","models":{"m":{"protocol":"chat","context_tokens":32768}}}}}}
    );
    defer cfg.release(&parsed);
    const config = &parsed.value;
    config.model = .{ .name = "m", .context_tokens = 32768, .protocol = .chat, .reasoning = .{ .map = .{ .off = "none", .medium = "medium", .high = "high" } } };
    for ([_][]const u8{ "medium", "high" }) |saved| {
        config.registry.?.reasoning_effort = saved;
        try t.expect(applyConfigured(config) == null);
        try t.expectEqualStrings(saved, config.model.reasoning_effort.?);
    }
    config.registry.?.reasoning_effort = null;
    config.model.reasoning_effort = "provider-custom";
    try t.expect(applyConfigured(config) == null);
    try t.expectEqualStrings("provider-custom", config.model.reasoning_effort.?);
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
    parsed.value.model.reasoning_effort = "none";
    try std.testing.expect(preference(parsed.value) == null);
    _ = applyConfigured(&parsed.value);
    try std.testing.expectEqualStrings("none", parsed.value.model.reasoning_effort.?);
}
