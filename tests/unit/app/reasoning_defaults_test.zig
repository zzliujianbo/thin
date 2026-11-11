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
