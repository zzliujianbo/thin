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
test "native SystemOne endpoint conflicts fail closed during declaration validation" {
    try std.testing.expectError(error.IncompatibleModelProtocol, cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"custom/reviewer","providers":{"custom":{"base_url":"http://127.0.0.1:1/v1","models":{"reviewer":{"protocol":"systemone"},"jev-is-only-a-name":{"protocol":"chat","context_tokens":32768},"unknown-jev":{}}},"native":{"base_url":"https://opencode.ai/inference/systemone/v1"},"conflict":{"base_url":"https://opencode.ai/inference/systemone/v1","models":{"reviewer":{"protocol":"responses","context_tokens":32768}}}}}}
    ));
}
test "SystemOne cache-only selection needs no capacity and imports no generative metadata" {
    var parsed = try cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"custom/reviewer","providers":{"custom":{"base_url":"http://127.0.0.1:1/v1","models":{"reviewer":{"protocol":"systemone"},"jev-is-only-a-name":{"protocol":"chat","context_tokens":32768},"unknown-jev":{}}},"native":{"base_url":"https://opencode.ai/inference/systemone/v1"},"zen":{"base_url":"https://opencode.ai/zen/v1"}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    defer cache.deinit(std.testing.allocator);
    const row = try cache.directory.upsert(std.testing.allocator, .opencode_zen, "reviewer");
    row.available = true;
    row.protocol = .systemone;
    row.tokens = 200000;
    row.output_tokens = 32000;
    row.dev_protocol = .chat;
    row.dev_context_tokens = 100000;
    row.dev_input_price_threshold = 10000;
    cache.directory_mask = metadata.bit(.opencode_zen);
    for ([_][]const u8{ "custom", "native", "zen" }) |alias| {
        try std.testing.expectEqual(Protocol.systemone, try protocolFor(parsed.value, &cache, alias, "reviewer"));
        const selection = try resolve(parsed.arena.allocator(), parsed.value, &cache, alias, "reviewer", false);
        try std.testing.expectEqual(Protocol.systemone, selection.model.protocol);
        try std.testing.expectEqual(@as(u32, 0), selection.model.context_tokens);
        try std.testing.expect(selection.model.output_tokens == null);
        try std.testing.expect(selection.model.reasoning == null);
        try std.testing.expect(selection.model.input_price_threshold == null);
        try std.testing.expect(selection.model.input_price_flat_limit == null);
        try std.testing.expect(!selection.context_official);
    }
    try std.testing.expectEqual(Protocol.chat, try protocolFor(parsed.value, &cache, "custom", "jev-is-only-a-name"));
    try std.testing.expectError(error.UnknownModelProtocol, protocolFor(parsed.value, &cache, "custom", "unknown-jev"));
    row.available = false;
    try std.testing.expectError(error.DefaultModelUnavailable, resolve(parsed.arena.allocator(), parsed.value, &cache, "zen", "reviewer", false));
    row.available = true;
    const models = [_]cfg.NamedModel{.{ .name = "reviewer", .patch = .{ .protocol = .chat, .context_tokens = 32768 } }};
    const providers = [_]cfg.NamedProvider{.{ .name = "zen", .connection = .{ .base_url = "https://opencode.ai/zen/v1" }, .models = &models }};
    var conflicting = parsed.value;
    conflicting.registry = .{ .default = "zen/reviewer", .providers = &providers };
    try std.testing.expectError(error.IncompatibleModelProtocol, protocolFor(conflicting, &cache, "zen", "reviewer"));
}
test "models.dev SystemOne routes only exact Zen to native retaining alias credentials and proxy scope" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"zen/reviewer","providers":{"zen":{"base_url":"https://opencode.ai/zen/v1","kind":"opencode_zen","api_key":"fake-own-key"},"other":{"base_url":"https://opencode.ai/zen/v1","api_key":"fake-other-key"},"custom":{"base_url":"http://127.0.0.1:1/v1","models":{"reviewer":{"protocol":"systemone"}}},"lookalike":{"base_url":"https://opencode.ai.example/zen/v1","kind":"opencode_zen","models":{"reviewer":{"protocol":"systemone"}}},"go":{"base_url":"https://opencode.ai/zen/go/v1"},"native":{"base_url":"https://opencode.ai/inference/systemone/v1/","api_key_env":"OWN_FIXTURE_KEY"}}},"proxy":{"address":"127.0.0.1","port":7890,"models":["zen/reviewer"]}}
    );
    defer cfg.release(&parsed);
    var listing = try metadata.parseDev(a,
        \\{"opencode":{"models":{"reviewer":{"api":{"url":"https://opencode.ai/inference/systemone/v1"}}}},"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"reviewer":{"limit":{"context":32768}}}}}
    );
    defer listing.deinit(a);
    // Borrow only; listing owns the directory throughout all resolver calls.
    const cache: metadata.Cache = .{ .directory = listing.directory };
    try std.testing.expectEqual(Protocol.systemone, try protocolFor(parsed.value, &cache, "zen", "reviewer"));
    const selection = try resolve(parsed.arena.allocator(), parsed.value, &cache, "zen", "reviewer", false);
    try std.testing.expectEqualStrings(cfg.providers.systemone_base_url, selection.connection.base_url);
    try std.testing.expectEqualStrings("zen", selection.provider_name);
    try std.testing.expectEqualStrings("fake-own-key", selection.connection.api_key.?);
    try std.testing.expectEqual(cfg.providers.Id.opencode_zen, selection.connection.kind.?);
    try std.testing.expectEqual(Protocol.systemone, selection.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), selection.model.context_tokens);
    try std.testing.expect(selection.model.output_tokens == null and selection.model.reasoning == null);
    try std.testing.expect(selection.model.input_price_threshold == null and selection.model.input_price_flat_limit == null);
    var candidate = parsed.value;
    apply(&candidate, selection);
    try cfg.validate(candidate);
    try std.testing.expect(candidate.proxyFor(candidate.selected_provider, candidate.model.name) != null);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1", parsed.value.registry.?.find("zen").?.connection.base_url);
    for ([_][]const u8{ "custom", "lookalike", "native" }) |alias| {
        const own = parsed.value.registry.?.find(alias).?;
        const route = try resolve(parsed.arena.allocator(), parsed.value, &cache, alias, "reviewer", false);
        try std.testing.expectEqualStrings(own.connection.base_url, route.connection.base_url);
        try std.testing.expectEqualStrings(alias, route.provider_name);
        try std.testing.expectEqualStrings(own.connection.api_key_env, route.connection.api_key_env);
        try std.testing.expectEqual(Protocol.systemone, route.model.protocol);
        try std.testing.expectEqual(@as(u32, 0), route.model.context_tokens);
        try std.testing.expect(parsed.value.proxyFor(route.provider_name, route.model.name) == null);
    }
    const other = try resolve(parsed.arena.allocator(), parsed.value, &cache, "other", "reviewer", false);
    try std.testing.expectEqualStrings("fake-other-key", other.connection.api_key.?);
    try std.testing.expectEqualStrings(cfg.providers.systemone_base_url, other.connection.base_url);
    const chat = try resolve(parsed.arena.allocator(), parsed.value, &cache, "go", "reviewer", false);
    try std.testing.expectEqual(Protocol.chat, chat.model.protocol);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", chat.connection.base_url);
    // Even a SystemOne declaration on Go must not rewrite it into Zen.
    var go_config = parsed.value;
    const go_models = [_]cfg.NamedModel{.{ .name = "separate-reviewer", .patch = .{ .protocol = .systemone } }};
    const go_providers = [_]cfg.NamedProvider{.{ .name = "go", .connection = .{ .base_url = "https://opencode.ai/zen/go/v1" }, .models = &go_models }};
    go_config.registry = .{ .default = "go/separate-reviewer", .providers = &go_providers };
    go_config.proxy = null;
    const go_route = try resolve(parsed.arena.allocator(), go_config, &cache, "go", "separate-reviewer", false);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", go_route.connection.base_url);
}
test "price proof resolves exact direct flat routes and clears on proxy protocol or raw ID changes" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"ds/deepseek-flash","providers":{"ds":{"base_url":"https://api.deepseek.com","models":{"deepseek-flash":{"protocol":"chat","context_tokens":2000000},"deepseek-flash-future":{"protocol":"chat","context_tokens":2000000}}},"proxy":{"base_url":"https://proxy.invalid/v1","kind":"deepseek","models":{"deepseek-flash":{"protocol":"chat","context_tokens":2000000}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    defer cache.deinit(std.testing.allocator);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const flat = try resolve(arena.allocator(), parsed.value, &cache, "ds", "deepseek-flash", false);
    try std.testing.expectEqual(@as(u32, 2000000), flat.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 1000000), flat.model.input_price_flat_limit);
    try std.testing.expect(flat.model.input_price_threshold == null);
    const proxy = try resolve(arena.allocator(), parsed.value, &cache, "proxy", "deepseek-flash", false);
    try std.testing.expect(proxy.model.input_price_flat_limit == null);
    const future = try resolve(arena.allocator(), parsed.value, &cache, "ds", "deepseek-flash-future", false);
    try std.testing.expect(future.model.input_price_flat_limit == null);
    var candidate = parsed.value;
    candidate.provider = flat.connection;
    candidate.model = flat.model;
    candidate.model.protocol = .responses;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expect(candidate.model.input_price_flat_limit == null);
    const row = try cache.directory.upsert(std.testing.allocator, .deepseek, "deepseek-flash");
    row.dev_protocol = .chat;
    row.dev_input_price_threshold = 100000;
    candidate.model = flat.model;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, 100000), candidate.model.input_price_threshold);
    try std.testing.expect(candidate.model.input_price_flat_limit == null);
    row.dev_input_price_threshold = null;
    row.dev_input_price_flat_limit = 500000;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, 500000), candidate.model.input_price_flat_limit);
    candidate.provider = proxy.connection;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expect(candidate.model.input_price_flat_limit == null);
    try std.testing.expect(candidate.model.input_price_threshold == null);
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
    row.dev_input_price_threshold = 200000;
    cache.directory_mask = metadata.bit(.opencode_go);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const selected = try resolve(arena.allocator(), parsed.value, &cache, "go", "shared", false);
    try std.testing.expectEqual(@as(u32, 200000), selected.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 128000), selected.model.output_tokens);
    try std.testing.expectEqual(.responses, selected.model.protocol);
    try std.testing.expectEqual(@as(?u32, 200000), selected.model.input_price_threshold);
    var candidate = parsed.value;
    candidate.provider = selected.connection;
    candidate.model = selected.model;
    candidate.model.protocol = .chat;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, null), candidate.model.input_price_threshold);
    candidate.model = selected.model;
    candidate.model.name = "other";
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, null), candidate.model.input_price_threshold);
    candidate.model = selected.model;
    candidate.provider = parsed.value.registry.?.find("custom").?.connection;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, null), candidate.model.input_price_threshold);
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
