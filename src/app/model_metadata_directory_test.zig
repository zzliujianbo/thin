const std = @import("std");
const m = @import("model_metadata.zig");
const fs = @import("../platform/filesystem.zig");
const cfg = @import("../core/config.zig");
const t = std.testing;

test "publication generations reject delayed sources independently and distinguish same-ms claims" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const official = m.bit(.deepseek);
    const both = official | m.dev_bit;
    const old = try m.claimAt(&root, both, true, 1000, .{});
    const newer = try m.claimAt(&root, official, true, 1000, .{});
    try t.expectEqual(old.generations[0] + 1, newer.generations[0]);
    var fresh = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"fresh\",\"context_window\":65536}]}", .deepseek);
    const published = try m.commitClaimedAt(&root, official, fresh, newer.generations, 1010);
    try t.expectEqual(official, published.accepted);
    var delayed = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"obsolete\",\"context_window\":32768}]}", .deepseek);
    try m.mergeDev(&delayed, &try m.parseDev(t.allocator, "{}"));
    const result = try m.commitClaimedAt(&root, official, delayed, old.generations, 2000);
    try t.expectEqual(m.dev_bit, result.accepted);
    try t.expect(result.cache.directory.find(.deepseek, "obsolete") == null);
    try t.expect(result.cache.directory.rows[result.cache.directory.find(.deepseek, "fresh").?].available == true);
    try t.expectEqual(@as(?u64, 1010), result.cache.refresh[0].last_success_ms);
    try t.expectEqual(@as(?u64, 2000), result.cache.refresh[3].last_success_ms);
    // The opposite ordering must not let a stale public result block official.
    const a_claim = try m.claimAt(&root, both, true, 3000, .{});
    const b_claim = try m.claimAt(&root, m.dev_bit, true, 3000, .{});
    _ = try m.commitClaimedAt(&root, 0, try m.parseDev(t.allocator,
        \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"fresh":{"limit":{"context":262144,"output":8192}}}}}
    ), b_claim.generations, 3010);
    fresh.dev_done = true;
    const independent = try m.commitClaimedAt(&root, official, fresh, a_claim.generations, 4000);
    try t.expectEqual(official, independent.accepted);
    const retained_public = independent.cache.directory.rows[independent.cache.directory.find(.deepseek, "fresh").?];
    try t.expectEqual(@as(?u32, 262144), retained_public.dev_context_tokens);
    try t.expectEqual(@as(?u32, 8192), retained_public.dev_output_tokens);
    try t.expectEqual(@as(?u64, 3010), independent.cache.refresh[3].last_success_ms);
    try t.expectEqual(@as(?u64, 4000), independent.cache.refresh[0].last_success_ms);
}

test "publication v9 generation strict tokens exhaustion and v8 timing migration" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    for ([_][]const u8{ "\"1\"", "1.0", "1e3", "-1", "9223372036854775808", "null" }) |token| {
        const body = try std.fmt.allocPrint(t.allocator, "{{\"version\":9,\"attempted\":0,\"records\":[],\"refresh\":[{{\"generation\":{s}}},{{}},{{}},{{}}]}}", .{token});
        defer t.allocator.free(body);
        try root.writeMode(m.file_name, body, true, 0o600);
        if (m.load(&root)) |_| return error.AcceptedInvalidGeneration else |_| {}
    }
    const exhausted = "{\"version\":9,\"attempted\":0,\"records\":[],\"refresh\":[{\"generation\":9223372036854775807},{},{},{}]}";
    try root.writeMode(m.file_name, exhausted, true, 0o600);
    const before = try m.load(&root);
    try t.expectError(error.MetadataGenerationExhausted, m.claimAt(&root, m.bit(.deepseek) | m.dev_bit, true, 1000, .{}));
    try t.expectEqualDeep(before, try m.load(&root));
    try root.writeMode(m.file_name, "{\"version\":8,\"attempted\":1,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":65536}],\"refresh\":[{\"last_attempt_ms\":100,\"last_success_ms\":110,\"successful\":true},{},{},{}]}", true, 0o600);
    const migrated = try m.claimAt(&root, m.bit(.deepseek), true, 120, .{});
    try t.expectEqual(@as(u64, 1), migrated.generations[0]);
    try t.expectEqual(@as(?u64, 110), migrated.cache.refresh[0].last_success_ms);
    try t.expectEqual(@as(?u32, 65536), migrated.cache.tokens[0]);
}

test "refresh timing exact TTL cooldown restart independent manual rollback and migration" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const official = m.bit(.deepseek);
    const both = official | m.dev_bit;
    const policy: m.Policy = .{ .ttl_ms = 400, .cooldown_ms = 50 };
    try t.expectEqual(both, (try m.claimAt(&root, both, false, 1000, policy)).mask);
    // Reload/second process observes the durable pre-launch claim.
    try t.expectEqual(@as(u8, 0), (try m.claimAt(&root, both, false, 1049, policy)).mask);
    var listing: m.Listing = .{};
    listing.tokens[0] = 131072;
    var cache = try m.commitAt(&root, official, listing, 1010);
    try t.expectEqual(@as(u8, 0), m.eligible(&cache, both, 1049, policy));
    try t.expectEqual(m.dev_bit, m.eligible(&cache, both, 1050, policy));
    try t.expectEqual(m.dev_bit, (try m.claimAt(&root, both, false, 1050, policy)).mask);
    // Failure keeps successful capabilities and last-success time.
    cache = try m.commitAt(&root, 0, .{}, 1051);
    try t.expectEqual(@as(?u32, 131072), cache.tokens[0]);
    try t.expectEqual(@as(?u64, 1010), cache.refresh[0].last_success_ms);
    try t.expectEqual(@as(u8, 0), m.eligible(&cache, official, 1409, policy));
    try t.expectEqual(official, m.eligible(&cache, official, 1410, policy));
    try t.expectEqual(official, (try m.claimAt(&root, official, true, 1060, policy)).mask);
    try t.expectEqual(@as(u8, 0), (try m.claimAt(&root, official, false, 1109, policy)).mask);
    try t.expectEqual(official, (try m.claimAt(&root, official, false, 1110, policy)).mask);
    // Clock rollback grants one repair, then observes cooldown even on restart.
    try t.expectEqual(official, (try m.claimAt(&root, official, false, 500, policy)).mask);
    cache = try m.load(&root);
    try t.expect(cache.refresh[0].last_success_ms == null);
    try t.expectEqual(@as(u8, 0), (try m.claimAt(&root, official, false, 500, policy)).mask);
    try t.expectEqual(@as(u8, 0), (try m.claimAt(&root, official, false, 549, policy)).mask);
    try t.expectEqual(official, (try m.claimAt(&root, official, false, 550, policy)).mask);
    // v7 has capabilities but no clock: due once, and immediately persisted v8.
    try root.writeMode(m.file_name, "{\"version\":7,\"attempted\":135,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":12345}]}", true, 0o600);
    const migrated = try m.claimAt(&root, both, false, 2000, policy);
    try t.expectEqual(both, migrated.mask);
    try t.expectEqual(@as(?u32, 12345), migrated.cache.tokens[0]);
    try t.expectEqual(@as(u8, 0), (try m.claimAt(&root, both, false, 2049, policy)).mask);
    try t.expectEqual(both, (try m.claimAt(&root, both, false, 2050, policy)).mask);
}

test "refresh timing default deadlines and public success are independent" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const official = m.bit(.deepseek);
    const both = official | m.dev_bit;
    _ = try m.claimAt(&root, both, false, 0, .{});
    const cache = try m.commitAt(&root, 0, .{ .dev_done = true }, 10);
    try t.expectEqual(@as(?u64, 10), cache.refresh[3].last_success_ms);
    try t.expect(cache.refresh[0].last_success_ms == null);
    try t.expectEqual(@as(u8, 0), m.eligible(&cache, both, 299999, .{}));
    try t.expectEqual(official, m.eligible(&cache, both, 300000, .{}));
    try t.expectEqual(official, m.eligible(&cache, both, 14400009, .{}));
    try t.expectEqual(both, m.eligible(&cache, both, 14400010, .{}));
}

test "refresh timing timestamps require bounded nonnegative integer JSON tokens" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    for ([_][]const u8{ "\"123\"", "1.0", "1e3", "-1", "253402300800000" }) |token| {
        const body = try std.fmt.allocPrint(t.allocator, "{{\"version\":8,\"attempted\":0,\"records\":[],\"refresh\":[{{\"last_attempt_ms\":{s}}},{{}},{{}},{{}}]}}", .{token});
        defer t.allocator.free(body);
        try root.writeMode(m.file_name, body, true, 0o600);
        if (m.load(&root)) |_| return error.AcceptedInvalidTimestamp else |_| {}
    }
    try root.writeMode(m.file_name, "{\"version\":8,\"attempted\":0,\"records\":[],\"refresh\":[{\"last_attempt_ms\":0},{\"last_success_ms\":253402300799999},{},{}]}", true, 0o600);
    const valid = try m.load(&root);
    try t.expectEqual(@as(?u64, 0), valid.refresh[0].last_attempt_ms);
    try t.expectEqual(@as(?u64, m.max_timestamp_ms), valid.refresh[1].last_success_ms);
}

fn rootFor(dir: std.Io.Dir) !fs.Root {
    var path: [4096]u8 = undefined;
    const len = try dir.realPath(t.io, &path);
    return fs.Root.open(t.allocator, t.io, path[0..len]);
}

test "output exact public routes roundtrip precedence omission and identity" {
    const catalog = @import("provider_catalog.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const body =
        \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"same":{"limit":{"context":999999,"output":8192}}}},"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"same":{"limit":{"output":16384}}}},"opencode":{"npm":"@ai-sdk/openai","models":{"same":{"limit":{"output":32768}}}}}
    ;
    var dev = try m.parseDev(t.allocator, body);
    var official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"chat\",\"max_tokens\":12345}]}", .deepseek);
    try t.expect(official.directory.rows[0].output_tokens == null);
    official.directory.rows[0].output_tokens = 4096; // Synthetic verified official capability.
    try m.mergeOfficial(&dev, &official, .deepseek);
    try t.expectEqual(@as(?u32, 8192), dev.directory.rows[0].dev_output_tokens);
    var cache = try m.commit(&root, m.bit(.deepseek), dev);
    cache = try m.load(&root);
    for (cfg.providers.Id.all) |id| {
        const entry = m.restoreEntry(&cache, id, "same").?;
        const expected: u32 = switch (id) {
            .deepseek => 4096,
            .opencode_go => 16384,
            .opencode_zen => 32768,
        };
        try t.expectEqual(@as(?u32, expected), m.outputFor(&cache, entry));
        try t.expectEqual(@as(?u32, expected), entry.model.output_tokens);
        try t.expectEqual(.metadata, entry.model.output_source);
        var incompatible = entry;
        incompatible.model.protocol = if (entry.model.protocol == .chat) .anthropic else .chat;
        try t.expect(m.outputFor(&cache, incompatible) == null);
        var config: cfg.Config = .{ .provider = catalog.connection(id), .model = entry.model };
        m.applyOutput(&cache, &config);
        try t.expectEqual(@as(?u32, expected), config.model.output_tokens);
        config.model.protocol = if (entry.model.protocol == .chat) .anthropic else .chat;
        m.applyOutput(&cache, &config);
        try t.expect(config.model.output_tokens == null);
        config.model = entry.model;
        config.provider = .{ .base_url = "https://custom.invalid/v1" };
        m.applyOutput(&cache, &config);
        try t.expect(config.model.output_tokens == null);
        config.provider.kind = id;
        m.applyOutput(&cache, &config);
        try t.expect(config.model.output_tokens == null);
        config.provider = catalog.connection(id);
        config.provider.kind = if (id == .deepseek) .opencode_go else .deepseek;
        m.applyOutput(&cache, &config);
        try t.expect(config.model.output_tokens == null);
        config.model.output_tokens = 123;
        config.model.output_source = .explicit;
        m.applyOutput(&cache, &config);
        try t.expectEqual(@as(?u32, 123), config.model.output_tokens);
    }
    cache = try m.commit(&root, 0, .{}); // Failed refresh keeps both sources.
    try t.expectEqual(@as(?u32, 32768), m.outputFor(&cache, m.restoreEntry(&cache, .opencode_zen, "same").?));
    var replacement = try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"same":{"limit":{"context":99999}}}}}
    );
    try m.mergeDev(&dev, &replacement);
    try t.expect(dev.directory.rows[dev.directory.find(.opencode_zen, "same").?].dev_output_tokens == null);
    cache = try m.commit(&root, 0, replacement);
    try t.expect(m.outputFor(&cache, m.restoreEntry(&cache, .opencode_zen, "same").?) == null);
    replacement = try m.parseDev(t.allocator, "{}");
    cache = try m.commit(&root, 0, replacement);
    try t.expect(m.outputFor(&cache, m.restoreEntry(&cache, .opencode_zen, "same").?) == null);
    try t.expectEqual(@as(?u32, 4096), m.outputFor(&cache, m.restoreEntry(&cache, .deepseek, "same").?));
    official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"chat\"}]}", .deepseek);
    cache = try m.commit(&root, m.bit(.deepseek), official);
    try t.expect(m.outputFor(&cache, m.restoreEntry(&cache, .deepseek, "same").?) == null);
}

test "output official protocol cannot authorize a conflicting public route" {
    const catalog = @import("provider_catalog.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var listing = try m.parseDev(t.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"same":{"limit":{"output":65536}}}}}
    );
    const official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"anthropic\"}]}", .opencode_go);
    try m.mergeOfficial(&listing, &official, .opencode_go);
    const cache = try m.commit(&root, m.bit(.opencode_go), listing);
    const entry: catalog.Entry = .{ .provider = .opencode_go, .selector = "opencode-go/same", .model = .{ .name = "same", .context_tokens = 131072, .protocol = .chat } };
    try t.expect(m.outputFor(&cache, entry) == null);
    var config: cfg.Config = .{ .provider = catalog.connection(.opencode_go), .model = entry.model };
    m.applyOutput(&cache, &config);
    try t.expect(config.model.output_tokens == null);
}

test "output cache v1-v5 default unknown and v6 rejects unbounded values transactionally" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var buffer: [1024]u8 = undefined;
    for (1..6) |version| {
        const body = try std.fmt.bufPrint(&buffer, "{{\"version\":{d},\"attempted\":0,\"records\":[]}}", .{version});
        try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = body });
        const cache = try m.load(&root);
        try t.expect(m.outputFor(&cache, @import("provider_catalog.zig").entries[0]) == null);
    }
    for ([_][]const u8{ "0", "1048577", "4294967296", "1.5", "\"100\"", "-1" }) |value| {
        const body = try std.fmt.bufPrint(&buffer, "{{\"version\":6,\"attempted\":0,\"records\":[],\"models\":[{{\"provider\":\"deepseek\",\"id\":\"same\",\"output_tokens\":{s}}}]}}", .{value});
        try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = body });
        const before = try root.dir.statFile(root.io, m.file_name, .{});
        if (m.commit(&root, 0, .{})) |_| return error.ExpectedInvalidCache else |_| {}
        try t.expectEqual(before.inode, (try root.dir.statFile(root.io, m.file_name, .{})).inode);
    }
}

test "public output invalid values unknown and no cross provider votes" {
    const body =
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"zero":{"limit":{"output":0}},"negative":{"limit":{"output":-1}},"float":{"limit":{"output":1.5}},"string":{"limit":{"output":"123"}},"overflow":{"limit":{"output":4294967296}},"large":{"limit":{"output":1048577}},"edge":{"limit":{"output":1048576}},"context":{"limit":{"context":65536},"budget_tokens":1000},"same":{},"unknown":{"provider":{"npm":"unsupported"},"limit":{"output":123}}}},"foreign":{"npm":"@ai-sdk/openai","models":{"same":{"limit":{"output":5000}}}}}
    ;
    const dev = try m.parseDev(t.allocator, body);
    for (dev.directory.rows[0..dev.directory.count], 0..) |row, index| {
        if (std.mem.eql(u8, dev.directory.name(index), "edge")) {
            try t.expectEqual(@as(?u32, 1048576), row.dev_output_tokens);
        } else try t.expect(row.dev_output_tokens == null);
    }
}

const public_catalog =
    \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"fresh-deepseek":{}}},"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"fresh-shared":{}}},"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"fresh-shared":{},"fresh-native":{"provider":{"npm":"@ai-sdk/anthropic"}}}}}
;

fn officialThree() !m.Listing {
    var result: m.Listing = .{};
    for (cfg.providers.Id.all) |id| {
        const body: []const u8 = switch (id) {
            .deepseek => "{\"data\":[{\"id\":\"fresh-deepseek\",\"context_window\":65536}]}",
            .opencode_go => "{\"data\":[{\"id\":\"fresh-shared\"}]}",
            .opencode_zen => "{\"data\":[{\"id\":\"fresh-shared\"},{\"id\":\"fresh-native\",\"context_window\":65536,\"effort\":{\"supported_levels\":[\"off\",\"low\",\"high\"]}}]}",
        };
        const listing = try m.parseListing(t.allocator, body, id);
        try m.mergeOfficial(&result, &listing, id);
    }
    return result;
}

test "dynamic metadata merges all three directories and exact adapters across cache reload" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var listing = try officialThree();
    var cache = try m.commit(&root, m.provider_mask, listing);
    try t.expect(m.hasDirectory(&cache, .deepseek));
    try t.expect(m.hasDirectory(&cache, .opencode_go));
    try t.expect(m.hasDirectory(&cache, .opencode_zen));
    try t.expectEqual(.chat, m.findEntry(&cache, "deepseek/fresh-deepseek").?.model.protocol);
    try t.expectEqual(.auto, m.findEntry(&cache, "opencode-zen/fresh-native").?.model.protocol);
    try t.expect(m.findEntry(&cache, "opencode-zen/gpt-5.2") == null);
    const dev = try m.parseDev(t.allocator, public_catalog);
    try m.mergeDev(&listing, &dev);
    cache = try m.commit(&root, m.provider_mask, listing);
    cache = try m.load(&root);
    try t.expectEqual(.anthropic, m.findEntry(&cache, "opencode-go/fresh-shared").?.model.protocol);
    try t.expectEqual(.chat, m.findEntry(&cache, "opencode-zen/fresh-shared").?.model.protocol);
    const native = m.findEntry(&cache, "opencode-zen/fresh-native").?;
    try t.expectEqual(.anthropic, native.model.protocol);
    try t.expectEqual(@as(?u32, 65536), m.capacityFor(&cache, native));
    const declaration = m.entryDeclaration(&cache, native).?;
    try t.expectEqual(.anthropic, declaration.format);
    try t.expectEqualStrings("disabled", declaration.map.off.?);
    try t.expectEqualStrings("high", declaration.map.high.?);
    var config: cfg.Config = .{ .provider = .{ .base_url = cfg.providers.Id.opencode_zen.baseUrl() }, .model = native.model };
    m.applyReasoning(&cache, &config);
    try t.expectEqual(.metadata, config.model.reasoning_source);
    config.model.reasoning_source = .explicit;
    config.model.reasoning = .{ .format = .anthropic, .map = .{ .high = "user-wire" } };
    m.applyReasoning(&cache, &config);
    try t.expectEqualStrings("user-wire", config.model.reasoning.?.map.high.?);
}

test "dynamic metadata source failures delisting and stale credentials never invent new entries" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var cache = try m.commit(&root, m.provider_mask, try officialThree());
    cache = try m.commit(&root, 0, try m.parseDev(t.allocator, public_catalog));
    const stale = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"stale-id\",\"protocol\":\"responses\"}]}", .opencode_zen);
    cache = try m.commit(&root, 0, stale);
    try t.expect(cache.directory.find(.opencode_zen, "stale-id") == null);
    try t.expect(m.findEntry(&cache, "opencode-zen/fresh-native") != null);
    cache = try m.commit(&root, 0, .{});
    try t.expectEqual(.anthropic, m.findEntry(&cache, "opencode-go/fresh-shared").?.model.protocol);
    const empty = try m.parseListing(t.allocator, "{\"data\":[]}", .opencode_zen);
    cache = try m.commit(&root, m.bit(.opencode_zen), empty);
    try t.expect(m.findEntry(&cache, "opencode-zen/fresh-native") == null);
    try t.expect(m.restoreEntry(&cache, .opencode_zen, "fresh-native") != null);
    try t.expect(m.findEntry(&cache, "opencode-go/fresh-shared") != null);
    const reloaded = try m.load(&root);
    try t.expect(m.hasDirectory(&reloaded, .opencode_zen));
    try t.expect(m.findEntry(&reloaded, "opencode-zen/gpt-5.2") == null);
}

test "dynamic metadata official protocol wins while unknown adapter removes derived controls" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"fresh-native\",\"protocol\":\"chat\",\"effort\":{\"supported_levels\":[\"high\"]}}]}", .opencode_zen);
    var cache = try m.commit(&root, m.bit(.opencode_zen), official);
    cache = try m.commit(&root, 0, try m.parseDev(t.allocator, public_catalog));
    const entry = m.findEntry(&cache, "opencode-zen/fresh-native").?;
    try t.expectEqual(.chat, entry.model.protocol);
    try t.expectEqual(.standard, m.entryDeclaration(&cache, entry).?.format);
    const unknown = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"fresh-native\"}]}", .opencode_zen);
    cache = try m.commit(&root, m.bit(.opencode_zen), unknown);
    cache = try m.commit(&root, 0, try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"unrecognized-adapter","models":{"fresh-native":{}}}}
    ));
    const pending = m.findEntry(&cache, "opencode-zen/fresh-native").?;
    try t.expectEqual(.auto, pending.model.protocol);
    try t.expect(m.entryDeclaration(&cache, pending) == null);
    try t.expectEqual(@as(u32, 32768), pending.model.context_tokens);
}

test "dynamic metadata source merges roll back every field when the shared directory is full" {
    const catalog = @import("provider_catalog.zig");
    const directory = @import("model_directory.zig");
    var target: m.Listing = .{ .dev_done = true };
    var name: [32]u8 = undefined;
    for (0..directory.max_models) |index| {
        _ = try target.directory.upsert(.opencode_go, try std.fmt.bufPrint(&name, "merge-{d}", .{index}));
    }
    target.directory.rows[0].tokens = 111;
    target.directory.rows[0].output_tokens = 333;
    target.directory.rows[0].dev_output_tokens = 444;
    target.directory.rows[0].dev_context_tokens = 777;
    target.directory.rows[0].protocol = .chat;
    target.directory.rows[0].dev_protocol = .chat;
    const legacy = for (catalog.entries, 0..) |entry, index| {
        if (entry.provider == .opencode_go) break index;
    } else unreachable;
    target.tokens[legacy] = 111;
    target.dev[legacy] = .{ .map = .{ .high = "high" } };
    const used = target.directory.used;
    var source: m.Listing = .{ .directory_mask = m.bit(.opencode_go), .dev_done = true };
    for ([_][]const u8{ "merge-0", "overflow-new" }) |id| {
        const row = try source.directory.upsert(.opencode_go, id);
        row.tokens = 222;
        row.output_tokens = 555;
        row.dev_output_tokens = 666;
        row.dev_context_tokens = 888;
        row.protocol = .anthropic;
        row.dev_protocol = .responses;
        row.dev_present = true;
    }
    source.tokens[legacy] = 222;
    source.dev[legacy] = .{ .map = .{ .low = "low" } };
    try t.expectError(error.MetadataTooLarge, m.mergeOfficial(&target, &source, .opencode_go));
    try t.expectEqual(@as(?u32, 111), target.tokens[legacy]);
    try t.expectEqual(@as(?u32, 111), target.directory.rows[0].tokens);
    try t.expectEqual(.chat, target.directory.rows[0].protocol);
    try t.expectEqual(@as(u8, 0), target.directory_mask);
    try t.expectError(error.MetadataTooLarge, m.mergeDev(&target, &source));
    try t.expectEqual(.chat, target.directory.rows[0].dev_protocol);
    try t.expectEqual(@as(?u32, 333), target.directory.rows[0].output_tokens);
    try t.expectEqual(@as(?u32, 444), target.directory.rows[0].dev_output_tokens);
    try t.expectEqual(@as(?u32, 777), target.directory.rows[0].dev_context_tokens);
    try t.expectEqualStrings("high", target.dev[legacy].?.map.high.?);
    try t.expect(target.dev[legacy].?.map.low == null);
    try t.expect(target.dev_done);
    try t.expectEqual(used, target.directory.used);
    try t.expectEqual(@as(usize, directory.max_models), target.directory.count);
}

test "legacy official fields survive public-only directory publication" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const legacy = "{\"version\":4,\"attempted\":135,\"records\":[{\"selector\":\"opencode-zen/gpt-5.2\",\"context_window\":100000,\"available\":true,\"reasoning\":{\"map\":{\"high\":\"high\"}}}]}";
    try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = legacy });
    var cache = try m.commit(&root, 0, try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"gpt-5.2":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    ));
    // No official directory was successfully refreshed; a public-only row may
    // not shadow previously successful official capacity or wire declarations.
    try t.expect(!m.hasDirectory(&cache, .opencode_zen));
    const entry = m.findEntry(&cache, "opencode-zen/gpt-5.2").?;
    try t.expectEqual(@as(?u32, 100000), m.capacityFor(&cache, entry));
    const declaration = m.entryDeclaration(&cache, entry).?;
    try t.expectEqualStrings("high", declaration.map.high.?);
    try t.expect(declaration.map.low == null);
    // Conflicting public routing also cannot invalidate the compatible official
    // declaration bound to the last verified, still-selected legacy route.
    cache = try m.commit(&root, 0, try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"gpt-5.2":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    ));
    try t.expectEqualStrings("high", m.entryDeclaration(&cache, entry).?.map.high.?);
    cache = try m.commit(&root, 0, .{});
    cache = try m.load(&root);
    try t.expectEqual(@as(?u32, 100000), m.capacityFor(&cache, entry));
    try t.expectEqualStrings("high", m.entryDeclaration(&cache, entry).?.map.high.?);
    // A later successful official refresh supersedes those old values, including
    // clearing omitted capacity/effort rather than reviving legacy metadata.
    const fresh = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"gpt-5.2\"}]}", .opencode_zen);
    cache = try m.commit(&root, m.bit(.opencode_zen), fresh);
    const updated = m.findEntry(&cache, "opencode-zen/gpt-5.2").?;
    try t.expect(m.capacityFor(&cache, updated) == null);
    try t.expectEqualStrings("low", m.entryDeclaration(&cache, updated).?.map.low.?);
}

test "dynamic metadata v4 upgrade preserves data and grants one automatic directory attempt" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const legacy = "{\"version\":4,\"attempted\":135,\"records\":[{\"selector\":\"opencode-zen/gpt-5.2\",\"context_window\":100000,\"available\":true,\"dev_reasoning\":{\"map\":{\"high\":\"high\"}}}]}";
    try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = legacy });
    const requested = m.provider_mask | m.dev_bit;
    const claimed = try m.claim(&root, requested, false);
    try t.expectEqual(requested, claimed.mask);
    const old = m.findEntry(&claimed.cache, "opencode-zen/gpt-5.2").?;
    try t.expectEqual(@as(?u32, 100000), m.capacityFor(&claimed.cache, old));
    try t.expectEqualStrings("high", m.entryDeclaration(&claimed.cache, old).?.map.high.?);
    try t.expectEqual(@as(u8, 0), (try m.claim(&root, requested, false)).mask);
    const cache = try m.load(&root);
    try t.expectEqual(requested, cache.attempted);
    try t.expect(!m.hasDirectory(&cache, .opencode_zen));
}

test "context public exact SDK routes roundtrip official precedence and frozen entries" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var listing = try m.parseDev(t.allocator,
        \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"same/raw":{"limit":{"context":131072,"output":4096}}}},"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"same/raw":{"limit":{"context":262144}}}},"opencode":{"npm":"@ai-sdk/openai","models":{"same/raw":{"limit":{"context":524288}}}}}
    );
    const official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same/raw\",\"protocol\":\"chat\",\"context_window\":65536}]}", .deepseek);
    try m.mergeOfficial(&listing, &official, .deepseek);
    try t.expectEqual(@as(?u32, 131072), listing.directory.rows[0].dev_context_tokens);
    var cache = try m.commit(&root, m.bit(.deepseek), listing);
    cache = try m.load(&root);
    for (cfg.providers.Id.all) |id| {
        const entry = m.restoreEntry(&cache, id, "same/raw").?;
        const expected: u32 = switch (id) {
            .deepseek => 65536,
            .opencode_go => 262144,
            .opencode_zen => 524288,
        };
        try t.expectEqual(@as(?u32, expected), m.contextFor(&cache, entry));
        try t.expectEqual(expected, entry.model.context_tokens);
        try t.expectEqual(if (id == .deepseek) @as(?u32, 65536) else null, m.capacityFor(&cache, entry));
        var mismatch = entry;
        mismatch.model.protocol = .auto;
        try t.expect(m.contextFor(&cache, mismatch) == null);
        mismatch.model.protocol = if (entry.model.protocol == .chat) .anthropic else .chat;
        try t.expect(m.contextFor(&cache, mismatch) == null);
        mismatch = entry;
        mismatch.model.name = "same";
        try t.expect(m.contextFor(&cache, mismatch) == null);
        mismatch.model.name = "SAME/raw";
        try t.expect(m.contextFor(&cache, mismatch) == null);
        mismatch.model.name = entry.selector; // selector is not the exact raw ID.
        try t.expect(m.contextFor(&cache, mismatch) == null);
    }
    const frozen = m.restoreEntry(&cache, .opencode_go, "same/raw").?;
    cache = try m.commit(&root, 0, .{}); // Failure preserves both sources.
    try t.expectEqual(@as(?u32, 262144), m.contextFor(&cache, frozen));
    const replacement = try m.parseDev(t.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"same/raw":{"limit":{"context":1048576}}}}}
    );
    try m.mergeDev(&listing, &replacement);
    try t.expect(listing.directory.rows[listing.directory.find(.opencode_zen, "same/raw").?].dev_context_tokens == null);
    cache = try m.commit(&root, 0, replacement);
    try t.expectEqual(@as(u32, 262144), frozen.model.context_tokens);
    try t.expectEqual(@as(u32, 1048576), m.restoreEntry(&cache, .opencode_go, "same/raw").?.model.context_tokens);
    try t.expectEqual(@as(?u32, 65536), m.contextFor(&cache, m.restoreEntry(&cache, .deepseek, "same/raw").?));
    cache = try m.commit(&root, 0, try m.parseDev(t.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"same/raw":{"limit":{"output":8192}}}}}
    ));
    try t.expect(m.contextFor(&cache, frozen) == null); // Omitted field clears context, not output.
    try t.expectEqual(@as(?u32, 8192), m.outputFor(&cache, frozen));
    cache = try m.commit(&root, 0, try m.parseDev(t.allocator, "{}"));
    try t.expect(m.contextFor(&cache, frozen) == null); // Omitted model also clears it.
    try t.expect(m.outputFor(&cache, frozen) == null);
}

test "context official protocol conflicts block public fallback and public never impersonates official" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var listing = try m.parseDev(t.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"same":{"limit":{"context":262144}}}}}
    );
    const official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"anthropic\"}]}", .opencode_go);
    try m.mergeOfficial(&listing, &official, .opencode_go);
    var cache = try m.commit(&root, m.bit(.opencode_go), listing);
    var entry = m.restoreEntry(&cache, .opencode_go, "same").?;
    try t.expect(m.contextFor(&cache, entry) == null);
    entry.model.protocol = .chat;
    try t.expect(m.contextFor(&cache, entry) == null);
    entry.provider = .deepseek;
    try t.expect(m.contextFor(&cache, entry) == null);
    const unknown = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\"}]}", .opencode_go);
    cache = try m.commit(&root, m.bit(.opencode_go), unknown);
    entry = m.restoreEntry(&cache, .opencode_go, "same").?;
    try t.expectEqual(@as(?u32, 262144), m.contextFor(&cache, entry));
    try t.expectEqual(@as(u32, 262144), entry.model.context_tokens);
    try t.expect(m.capacityFor(&cache, entry) == null);
    const row = cache.directory.rows[cache.directory.find(.opencode_go, "same").?];
    try t.expect(row.tokens == null);
    try t.expectEqual(@as(?u32, 262144), row.dev_context_tokens);
    // Valid official window wins even when public routing disagrees.
    cache = try m.commit(&root, m.bit(.opencode_go), try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"anthropic\",\"context_window\":65536}]}", .opencode_go));
    entry = m.restoreEntry(&cache, .opencode_go, "same").?;
    try t.expectEqual(@as(?u32, 65536), m.contextFor(&cache, entry));
}

test "context public only integer limit context bounds no peer inference or output coupling" {
    const body =
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"zero":{"limit":{"context":0}},"negative":{"limit":{"context":-1}},"float":{"limit":{"context":1.5}},"exponent":{"limit":{"context":1e5}},"string":{"limit":{"context":"123"}},"null":{"limit":{"context":null}},"bool":{"limit":{"context":true}},"object":{"limit":{"context":{}}},"array":{"limit":{"context":[]}},"overflow":{"limit":{"context":4294967296}},"large":{"limit":{"context":16777217}},"edge":{"limit":{"context":16777216,"output":8192}},"one":{"limit":{"context":1}},"wrong-field":{"context_window":100000,"limit":{"input":100000,"output":10000}},"bad-limit":{"limit":100000},"same":{},"unknown":{"provider":{"npm":"unsupported"},"limit":{"context":123}},"invalid":{"provider":{"npm":null},"limit":{"context":123}},"override":{"provider":{"npm":"@ai-sdk/anthropic"},"limit":{"context":65536}}}},"foreign":{"npm":"@ai-sdk/openai","models":{"same":{"limit":{"context":50000}}}}}
    ;
    const dev = try m.parseDev(t.allocator, body);
    for (dev.directory.rows[0..dev.directory.count], 0..) |row, index| {
        const name = dev.directory.name(index);
        const expected: ?u32 = if (std.mem.eql(u8, name, "edge")) 16777216 else if (std.mem.eql(u8, name, "one")) 1 else if (std.mem.eql(u8, name, "override")) 65536 else null;
        try t.expectEqual(expected, row.dev_context_tokens);
        try t.expect(row.tokens == null);
    }
    const cache: m.Cache = .{ .directory = dev.directory };
    const edge = m.restoreEntry(&cache, .opencode_zen, "edge").?;
    try t.expectEqual(@as(?u32, 16777216), m.contextFor(&cache, edge));
    try t.expectEqual(@as(?u32, 8192), m.outputFor(&cache, edge));
    for ([_][]const u8{
        \\{"opencode":{"models":{"same":{"limit":{"context":1,"context":2}}}}}
        ,
        \\{"opencode":{"models":{"same":{"limit":{},"limit":{}}}}}
        ,
    }) |bad| try t.expectError(error.InvalidModelsDev, m.parseDev(t.allocator, bad));
}

test "context public replaces preset fallback but preserves compatible legacy official window" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const legacy = "{\"version\":4,\"attempted\":135,\"records\":[{\"selector\":\"opencode-zen/gpt-5.2\",\"context_window\":100000,\"available\":true}]}";
    try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = legacy });
    const public = try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"gpt-5.2":{"limit":{"context":262144}}}}}
    );
    var cache = try m.commit(&root, 0, public);
    var entry = m.restoreEntry(&cache, .opencode_zen, "gpt-5.2").?;
    try t.expectEqual(@as(?u32, 100000), m.contextFor(&cache, entry));
    try t.expectEqual(@as(u32, 100000), entry.model.context_tokens);
    var wrong = entry;
    wrong.model.protocol = .chat;
    try t.expect(m.contextFor(&cache, wrong) == null);
    // Official success without a window supersedes the old official value.
    cache = try m.commit(&root, m.bit(.opencode_zen), try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"gpt-5.2\"}]}", .opencode_zen));
    entry = m.restoreEntry(&cache, .opencode_zen, "gpt-5.2").?;
    try t.expectEqual(@as(?u32, 262144), m.contextFor(&cache, entry));
    try t.expectEqual(@as(u32, 262144), entry.model.context_tokens);
    try t.expect(m.capacityFor(&cache, entry) == null);
    cache = try m.commit(&root, 0, try m.parseDev(t.allocator, "{}"));
    try t.expect(m.contextFor(&cache, entry) == null);
    const preset = @import("provider_catalog.zig").find("opencode-zen/gpt-5.2").?;
    try t.expectEqual(preset.model.context_tokens, m.restoreEntry(&cache, .opencode_zen, "gpt-5.2").?.model.context_tokens);
}

test "context cache v1-v6 unknown v6 output preserved and v7 migration refresh once" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var buffer: [2048]u8 = undefined;
    for (1..7) |version| {
        const models = if (version >= 5)
            \\,"directory_mask":1,"models":[{"provider":"deepseek","id":"same","context_window":65536,"available":true,"protocol":"chat","dev_protocol":"chat","dev_context_tokens":262144,"output_tokens":8192,"dev_output_tokens":4096}]
        else
            "";
        const body = try std.fmt.bufPrint(&buffer, "{{\"version\":{d},\"attempted\":135,\"records\":[]{s}}}", .{ version, models });
        try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = body });
        const old = try m.load(&root);
        if (version >= 5) {
            try t.expect(old.directory.rows[0].dev_context_tokens == null);
            try t.expectEqual(@as(?u32, 65536), old.directory.rows[0].tokens);
            try t.expectEqual(if (version >= 6) @as(?u32, 8192) else null, old.directory.rows[0].output_tokens);
            try t.expectEqual(if (version >= 6) @as(?u32, 4096) else null, old.directory.rows[0].dev_output_tokens);
            try t.expectEqual(m.provider_mask, old.attempted);
        }
        const first = try m.claim(&root, m.dev_bit, false);
        try t.expectEqual(m.dev_bit, first.mask);
        try t.expectEqual(@as(u8, 0), (try m.claim(&root, m.dev_bit, false)).mask);
        const bytes = try root.read(t.allocator, m.file_name, 0, m.max_cache_bytes);
        defer t.allocator.free(bytes.data);
        var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, bytes.data, .{});
        defer parsed.deinit();
        try t.expectEqual(@as(i64, 9), parsed.value.object.get("version").?.integer);
    }
}

test "context v7 invalid cache values and invalid commit roll back durable fields" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var buffer: [1024]u8 = undefined;
    for ([_][]const u8{ "0", "16777217", "4294967296", "1.5", "1e5", "\"100\"", "-1", "true", "{}", "[]" }) |value| {
        const body = try std.fmt.bufPrint(&buffer, "{{\"version\":7,\"attempted\":0,\"records\":[],\"models\":[{{\"provider\":\"deepseek\",\"id\":\"same\",\"dev_context_tokens\":{s}}}]}}", .{value});
        try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = body });
        const before = try root.dir.statFile(root.io, m.file_name, .{});
        if (m.claim(&root, m.dev_bit, false)) |_| return error.ExpectedInvalidCache else |_| {}
        if (m.commit(&root, 0, .{})) |_| return error.ExpectedInvalidCache else |_| {}
        try t.expectEqual(before.inode, (try root.dir.statFile(root.io, m.file_name, .{})).inode);
        const after = try root.read(t.allocator, m.file_name, 0, m.max_cache_bytes);
        defer t.allocator.free(after.data);
        try t.expectEqualStrings(body, after.data);
    }
    try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = "{\"version\":7,\"attempted\":128,\"records\":[]}" });
    var listing = try m.parseDev(t.allocator,
        \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"same":{"limit":{"context":65536,"output":4096}}}}}
    );
    const saved = try m.commit(&root, 0, listing);
    listing.directory.rows[0].dev_context_tokens = 16777217;
    listing.directory.rows[0].dev_output_tokens = 8192;
    try t.expectError(error.InvalidMetadata, m.commit(&root, 0, listing));
    try t.expectEqualDeep(saved, try m.load(&root));
}
