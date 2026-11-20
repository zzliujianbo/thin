test "official context requires an available exact directory row and compatible route" {
    var cache: metadata.Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const entry = catalog.find("opencode-go/gpt-6-luna").?;
    // A static preset is a useful local fallback, never official evidence.
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens));
    const row = try cache.directory.upsert(std.testing.allocator, .opencode_go, "gpt-6-luna-alias");
    row.available = true;
    row.protocol = .responses;
    row.tokens = entry.model.context_tokens;
    cache.directory_mask = metadata.bit(.opencode_go);
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens));
    const exact = try cache.directory.upsert(std.testing.allocator, .opencode_go, "gpt-6-luna");
    exact.dev_present = true;
    exact.dev_protocol = .responses;
    exact.dev_context_tokens = entry.model.context_tokens;
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens));
    exact.available = true;
    exact.protocol = .responses;
    exact.tokens = entry.model.context_tokens;
    try std.testing.expect(officialContext(&cache, entry, entry.model.context_tokens));
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens - 1));
    var incompatible = entry;
    incompatible.model.protocol = .chat;
    try std.testing.expect(metadata.contextFor(&cache, incompatible) == null);
    exact.available = false;
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens));
}
test "provider reasoning source resolver uses official and preserves manual override" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"ds/fixture","providers":{"ds":{"base_url":"https://api.deepseek.com","models":{"fixture":{"protocol":"chat","context_tokens":65536},"manual":{"protocol":"chat","context_tokens":65536,"reasoning":{"format":"deepseek","map":{"off":"off","high":"user-high"}}}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const row = try cache.directory.upsert(std.testing.allocator, .deepseek, "fixture");
    row.protocol = .chat;
    row.dev_protocol = .chat;
    row.dev_reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .low = "low" } });
    var selection = try resolve(parsed.arena.allocator(), parsed.value, &cache, "ds", "fixture", false);
    try std.testing.expect(selection.model.reasoning == null);
    row.reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } });
    selection = try resolve(parsed.arena.allocator(), parsed.value, &cache, "ds", "fixture", false);
    try std.testing.expectEqualStrings("high", selection.model.reasoning.?.map.high.?);
    try std.testing.expect(selection.model.reasoning.?.map.low == null);
    const manual = try cache.directory.upsert(std.testing.allocator, .deepseek, "manual");
    manual.protocol = .chat;
    selection = try resolve(parsed.arena.allocator(), parsed.value, &cache, "ds", "manual", false);
    try std.testing.expectEqualStrings("user-high", selection.model.reasoning.?.map.high.?);
    try std.testing.expectEqual(cfg.ReasoningSource.explicit, selection.model.reasoning_source);
}
test "registry resolution merges fields but never borrows identity from a custom endpoint" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"go/shared","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key_env":"FIXTURE_KEY","models":{"shared":{"context_tokens":200000}}},"custom":{"base_url":"https://custom.invalid/v1","kind":"opencode_go","models":{"shared":{"context_tokens":200000}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const row = try cache.directory.upsert(std.testing.allocator, .opencode_go, "shared");
    row.available = true;
    row.protocol = .responses;
    row.tokens = 1000000;
    row.dev_protocol = .responses;
    row.dev_output_tokens = 128000;
    cache.directory_mask = metadata.bit(.opencode_go);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const selected = try resolve(arena.allocator(), parsed.value, &cache, "go", "shared", false);
    try std.testing.expectEqual(@as(u32, 200000), selected.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 128000), selected.model.output_tokens);
    try std.testing.expectEqual(.responses, selected.model.protocol);
    try std.testing.expect(!selected.context_official);
    try std.testing.expectError(error.UnknownModelProtocol, resolve(arena.allocator(), parsed.value, &cache, "custom", "shared", false));
    // Mutating cache ownership cannot poison an exported candidate.
    @memset(cache.directory.names[0..cache.directory.used], 'X');
    try std.testing.expectEqualStrings("shared", selected.model.name);
}
test "registry unrelated incompatible partial profile cannot poison an independently valid default" {
    var parsed = try cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"go/ready","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","models":{"ready":{"protocol":"chat","context_tokens":65536},"stale":{"reasoning":{"format":"anthropic","map":{"low":"low"}}}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const row = try cache.directory.upsert(std.testing.allocator, .opencode_go, "stale");
    row.available = true;
    row.protocol = .chat;
    row.tokens = 65536;
    cache.directory_mask = metadata.bit(.opencode_go);
    try applyDefault(parsed.arena.allocator(), &parsed.value, &cache);
    try std.testing.expectEqualStrings("ready", parsed.value.model.name);
    try std.testing.expectEqualStrings("ready", parsed.value.model.name);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.registry.?.providers[0].models.len);
}
test "registry dynamic unknown window cannot adopt a display or archived capability" {
    var parsed = try cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"go/never-a-preset","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1"}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const row = try cache.directory.upsert(std.testing.allocator, .opencode_go, "never-a-preset");
    row.available = true;
    row.protocol = .chat;
    cache.directory_mask = metadata.bit(.opencode_go);
    try std.testing.expectError(error.UnknownModelContext, applyDefault(parsed.arena.allocator(), &parsed.value, &cache));
    try std.testing.expect(parsed.value.selection_pending);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.registry.?.providers[0].models.len);
    // Remove the owned rows and their lookup index together; changing count
    // alone would leave a stale hash entry rather than an empty directory.
    cache.directory.deinit(std.testing.allocator);
    try std.testing.expectError(error.DefaultModelUnavailable, applyDefault(parsed.arena.allocator(), &parsed.value, &cache));
}
test "registry default may be discovered without a manual entry and explicit custom entries remain isolated" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"go/org/model","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1"},"custom":{"base_url":"https://custom.invalid/v1","models":{"org/model":{"protocol":"chat","context_tokens":65536,"output_tokens":8192}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const row = try cache.directory.upsert(std.testing.allocator, .opencode_go, "org/model");
    row.available = true;
    row.protocol = .chat;
    row.tokens = 262144;
    cache.directory_mask = metadata.bit(.opencode_go);
    try applyDefault(parsed.arena.allocator(), &parsed.value, &cache);
    try std.testing.expect(!parsed.value.selection_pending);
    try std.testing.expectEqualStrings("org/model", parsed.value.model.name);
    try std.testing.expectEqual(@as(u32, 262144), parsed.value.model.context_tokens);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const custom = try resolve(arena.allocator(), parsed.value, &cache, "custom", "org/model", false);
    try std.testing.expectEqual(@as(u32, 65536), custom.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 8192), custom.model.output_tokens);
    row.available = false;
    try std.testing.expectError(error.DefaultModelUnavailable, resolve(arena.allocator(), parsed.value, &cache, "go", "org/model", false));
    try std.testing.expectError(error.UnknownModelContext, resolve(arena.allocator(), parsed.value, &cache, "go", "org/model", true));
    // Loading an archive is independent; it cannot manufacture current send capability.
}
