test "exact decimal price schedules never round an increase or negative price into flat" {
    const Case = struct { cost: []const u8, threshold: ?u32 = null, flat: ?u32 = null };
    for ([_]Case{
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1.0000000000000001,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .threshold = 100000 },
        .{ .cost = "{\"input\":1.0000000000000001,\"output\":2,\"tiers\":[{\"input\":1,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}" },
        .{ .cost = "{\"input\":1e-999,\"output\":2e-999,\"tiers\":[{\"input\":2e-999,\"output\":2e-999,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .threshold = 100000 },
        .{ .cost = "{\"input\":2e-999,\"output\":2e-999,\"tiers\":[{\"input\":1e-999,\"output\":2e-999,\"tier\":{\"type\":\"context\",\"size\":100000}}]}" },
        .{ .cost = "{\"input\":1,\"output\":1.0,\"tiers\":[{\"input\":10e-1,\"output\":100.00e-2,\"tier\":{\"type\":\"context\",\"size\":100000}},{\"input\":1.0,\"output\":1,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .flat = 1000000 },
        .{ .cost = "{\"input\":0.0010e-996,\"output\":2e-999,\"tiers\":[{\"input\":10e-1000,\"output\":200e-1001,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .flat = 1000000 },
        .{ .cost = "{\"input\":-1e-999,\"output\":2}" },
        .{ .cost = "{\"input\":1,\"output\":-1e-999}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"cache_read\":-1e-999}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"cache_read\":-0}" },
        .{ .cost = "{\"input\":1e100001,\"output\":2}" },
        .{ .cost = "{\"input\":1e-100001,\"output\":2}" },
        .{ .cost = "{\"input\":1e100000,\"output\":2e-100000}", .flat = 1000000 },
        .{ .cost = "{\"input\":0,\"output\":0.0,\"tiers\":[{\"input\":0e999,\"output\":0.000e-999,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .flat = 1000000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1,\"output\":2.0000000000000001,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .threshold = 100000 },
        .{ .cost = "{\"input\":0,\"output\":0,\"tiers\":[{\"input\":1e-999,\"output\":0,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .threshold = 100000 },
        // Old f64 parsing missed the first increase and reported only 200K.
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1.0000000000000001,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}},{\"input\":2,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":200000}}]}", .threshold = 100000 },
        // Same-size conflicts and unordered monotonicity must also use exact comparison.
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}},{\"input\":1.0000000000000001,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":200000}},{\"input\":1.0000000000000001,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000,\"future_schedule\":{}}}]}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1.0000000000000001,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000,\"future_schedule\":{}}}]}", .threshold = 100000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"cache_read\":-1e-999,\"tiers\":[{\"input\":2,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .threshold = 100000 },
    }) |case| {
        var listing = try priceListing(case.cost);
        defer listing.deinit(t.allocator);
        const row = listing.directory.rows[0];
        try t.expectEqual(case.threshold, row.dev_input_price_threshold);
        try t.expectEqual(case.flat, row.dev_input_price_flat_limit);
    }
}
test "verified flat price exact route and conservative threshold precedence" {
    var cache: m.Cache = .{};
    defer cache.deinit(t.allocator);
    const row = try cache.directory.upsert(t.allocator, .opencode_go, "raw/id");
    row.dev_protocol = .anthropic;
    row.dev_present = true;
    row.dev_input_price_flat_limit = 1000000;
    const entry = m.restoreEntry(&cache, .opencode_go, "raw/id").?;
    try t.expectEqual(@as(?u32, 1000000), m.inputPriceFlatLimitFor(&cache, entry));
    var wrong = entry;
    wrong.provider = .opencode_zen;
    try t.expect(m.inputPriceFlatLimitFor(&cache, wrong) == null);
    wrong = entry;
    wrong.model.name = "opencode-go/raw/id";
    try t.expect(m.inputPriceFlatLimitFor(&cache, wrong) == null);
    wrong = entry;
    for ([_]@import("../core/protocol.zig").Protocol{ .auto, .chat, .responses }) |api| {
        wrong.model.protocol = api;
        try t.expect(m.inputPriceFlatLimitFor(&cache, wrong) == null);
    }
    row.protocol = .chat;
    try t.expect(m.inputPriceFlatLimitFor(&cache, entry) == null);
    row.protocol = .auto;
    row.dev_input_price_threshold = 100000;
    try t.expect(m.inputPriceFlatLimitFor(&cache, entry) == null);
    row.dev_input_price_threshold = null;
    for ([_]?u32{ null, 0, 16777217 }) |invalid| {
        row.dev_input_price_flat_limit = invalid;
        try t.expect(m.inputPriceFlatLimitFor(&cache, entry) == null);
    }
    row.dev_input_price_flat_limit = 16777216;
    try t.expectEqual(@as(?u32, 16777216), m.inputPriceFlatLimitFor(&cache, entry));
}
test "verified flat price current roundtrip merge publication clearing and bounds" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var public: m.Listing = .{ .dev_done = true };
    defer public.deinit(t.allocator);
    const row = try public.directory.upsert(t.allocator, .opencode_go, "raw/id");
    row.dev_protocol = .anthropic;
    row.dev_present = true;
    row.dev_input_price_flat_limit = 1000000;
    var joined: m.Listing = .{};
    defer joined.deinit(t.allocator);
    try m.mergeDev(t.allocator, &joined, &public);
    try t.expectEqual(@as(?u32, 1000000), joined.directory.rows[0].dev_input_price_flat_limit);
    var official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"raw/id\",\"protocol\":\"anthropic\",\"context_window\":1000000}]}", .opencode_go);
    defer official.deinit(t.allocator);
    try m.mergeOfficial(t.allocator, &joined, &official, .opencode_go);
    try t.expectEqual(@as(?u32, 1000000), joined.directory.rows[0].dev_input_price_flat_limit);
    var saved = try m.commitAt(&root, m.bit(.opencode_go), joined, 1000);
    defer saved.deinit(t.allocator);
    const entry = m.restoreEntry(&saved, .opencode_go, "raw/id").?;
    var loaded = try m.load(&root);
    defer loaded.deinit(t.allocator);
    try t.expectEqual(saved.directory.count, loaded.directory.count);
    try t.expectEqualDeep(saved.refresh, loaded.refresh);
    try t.expectEqual(@as(?u32, 1000000), m.inputPriceFlatLimitFor(&loaded, entry));
    var invalid = public;
    invalid.directory = try public.directory.clone(t.allocator);
    defer invalid.deinit(t.allocator);
    invalid.directory.rows[0].dev_input_price_flat_limit = 16777217;
    try t.expectError(error.InvalidMetadata, m.commitAt(&root, 0, invalid, 1010));
    var after_invalid = try m.load(&root);
    defer after_invalid.deinit(t.allocator);
    try t.expectEqualDeep(saved.refresh, after_invalid.refresh);
    try t.expectEqual(saved.directory.count, after_invalid.directory.count);
    var cleared = joined;
    cleared.directory = try joined.directory.clone(t.allocator);
    defer cleared.deinit(t.allocator);
    try m.mergeDev(t.allocator, &cleared, &m.Listing{ .dev_done = true });
    try t.expect(cleared.directory.rows[0].dev_input_price_flat_limit == null);
    var removed = try m.commitAt(&root, 0, .{ .dev_done = true }, 1020);
    defer removed.deinit(t.allocator);
    try t.expect(m.inputPriceFlatLimitFor(&removed, entry) == null);
    try t.expectEqual(@as(?u32, 1000000), removed.directory.rows[0].tokens);
    for ([_]u32{m.cache_version}) |version| {
        for ([_][]const u8{ "0", "-1", "16777217", "4294967296", "1.0", "1e5", "\"100000\"", "true", "{}", "[]" }) |token| {
            const body = try std.fmt.allocPrint(t.allocator, "{{\"version\":{d},\"models\":[{{\"provider\":\"opencode_go\",\"id\":\"raw/id\",\"dev_input_price_flat_limit\":{s}}}]}}", .{ version, token });
            defer t.allocator.free(body);
            try root.writeMode(m.file_name, body, true, 0o600);
            if (m.load(&root)) |_| return error.AcceptedInvalidFlatLimit else |_| {}
        }
    }
}
test "flat price current evidence and independent generations preserve post-claim cooldown" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    try root.writeMode(m.file_name,
        \\{"version":16,"models":[{"provider":"opencode_go","id":"raw/id","dev_protocol":"anthropic","dev_present":true,"dev_input_price_threshold":200000,"dev_input_price_flat_limit":1000000}],"refresh":[{"generation":11},{"generation":12},{"generation":13},{},{"generation":14,"last_success_ms":800,"successful":false}]}
    , true, 0o600);
    var migrated = try m.load(&root);
    defer migrated.deinit(t.allocator);
    try t.expectEqual(@as(?u32, 1000000), migrated.directory.rows[0].dev_input_price_flat_limit);
    try t.expectEqual(@as(?u32, 200000), migrated.directory.rows[0].dev_input_price_threshold);
    try t.expectEqual(@as(u64, 14), migrated.refresh[4].generation);
    try t.expectEqual(@as(?u64, 800), migrated.refresh[4].last_success_ms);
    var claimed = try m.claimAt(&root, m.dev_bit, false, 1000, .{});
    defer claimed.cache.deinit(t.allocator);
    try t.expectEqual(m.dev_bit, claimed.mask);
    try t.expectEqual(@as(u64, 15), claimed.generations[4]);
    for (0..3) |index| try t.expectEqual(@as(u64, 11) + index, claimed.generations[index]);
    // No successful publication: the persisted v12 attempt still enforces cooldown.
    try t.expectEqual(@as(u8, 0), try claimMask(&root, m.dev_bit, false, 1001, .{}));
    var public = try priceListing("{\"input\":1,\"output\":2}");
    defer public.deinit(t.allocator);
    var stale = try m.commitClaimedAt(&root, 0, public, .{ 11, 12, 13, 0, 14 }, 1010);
    defer stale.cache.deinit(t.allocator);
    try t.expectEqual(@as(u8, 0), stale.accepted);
    try t.expectEqual(@as(?u32, 1000000), stale.cache.directory.rows[0].dev_input_price_flat_limit);
    var invalid = public;
    invalid.directory = try public.directory.clone(t.allocator);
    defer invalid.deinit(t.allocator);
    invalid.directory.rows[0].dev_input_price_flat_limit = 16777217;
    try t.expectError(error.InvalidMetadata, m.commitClaimedAt(&root, 0, invalid, claimed.generations, 1020));
    var unchanged = try m.load(&root);
    defer unchanged.deinit(t.allocator);
    try t.expectEqualDeep(claimed.cache.refresh, unchanged.refresh);
    var cooldown_again = try m.claimAt(&root, m.dev_bit, false, 1021, .{});
    defer cooldown_again.cache.deinit(t.allocator);
    try t.expectEqual(@as(u8, 0), cooldown_again.mask);
    var published = try m.commitClaimedAt(&root, 0, public, claimed.generations, 1030);
    defer published.cache.deinit(t.allocator);
    try t.expectEqual(m.dev_bit, published.accepted);
    var loaded = try m.load(&root);
    defer loaded.deinit(t.allocator);
    try t.expectEqualDeep(published.cache.refresh, loaded.refresh);
    try t.expectEqual(published.cache.directory.count, loaded.directory.count);
    const entry = m.restoreEntry(&loaded, .opencode_go, "claude-haiku-5-5").?;
    try t.expectEqual(@as(?u32, 1000000), m.inputPriceFlatLimitFor(&loaded, entry));
}
test "price threshold exact fixture independent of official context and output" {
    var listing = try m.parseDev(t.allocator, @embedFile("models_dev_fixture.json"));
    const public_index = listing.directory.find(.opencode_go, "claude-haiku-5-5").?;
    try t.expectEqual(@as(?u32, 100000), listing.directory.rows[public_index].dev_input_price_threshold);
    defer listing.deinit(t.allocator);
    var official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"protocol\":\"anthropic\",\"context_window\":1000000}]}", .opencode_go);
    defer official.deinit(t.allocator);
    try m.mergeOfficial(t.allocator, &listing, &official, .opencode_go);
    var cache: m.Cache = .{ .directory = listing.directory };
    const entry = m.restoreEntry(&cache, .opencode_go, "claude-haiku-5-5").?;
    try t.expectEqual(@as(?u32, 100000), m.inputPriceThresholdFor(&cache, entry));
    try t.expectEqual(@as(?u32, 1000000), m.contextFor(&cache, entry));
    try t.expectEqual(@as(?u32, 16384), m.outputFor(&cache, entry));
    var wrong = entry;
    wrong.provider = .opencode_zen;
    try t.expect(m.inputPriceThresholdFor(&cache, wrong) == null);
    wrong = entry;
    wrong.model.name = "opencode-go/claude-haiku-5-5";
    try t.expect(m.inputPriceThresholdFor(&cache, wrong) == null);
    wrong = entry;
    for ([_]@import("../core/protocol.zig").Protocol{ .auto, .chat, .responses }) |api| {
        wrong.model.protocol = api;
        try t.expect(m.inputPriceThresholdFor(&cache, wrong) == null);
    }
    cache.directory.rows[public_index].protocol = .chat;
    try t.expect(m.inputPriceThresholdFor(&cache, entry) == null);
    var foreign = try m.parseDev(t.allocator,
        \\{"foreign":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"cost":{"input":0.1,"output":0.5,"tiers":[{"input":0.5,"output":2.5,"tier":{"type":"context","size":100000}}]}}}},"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{}}}}
    );
    defer foreign.deinit(t.allocator);
    cache.directory = foreign.directory;
    try t.expect(m.inputPriceThresholdFor(&cache, entry) == null);
}
test "price threshold malformed ancillary retains capabilities and strict duplicates" {
    for ([_][]const u8{
        "null",                                            "[]",                                                                                                                            "42",                               "{}",
        "{\"input\":\"0.1\",\"output\":0.5}",              "{\"input\":-1,\"output\":0.5}",                                                                                                 "{\"input\":1e999,\"output\":0.5}", "{\"input\":0.1,\"output\":0.5,\"tiers\":{}}",
        "{\"input\":0.1,\"output\":0.5,\"tiers\":[null]}", "{\"input\":0.1,\"output\":0.5,\"tiers\":[{\"input\":\"0.5\",\"output\":2.5,\"tier\":{\"type\":\"context\",\"size\":100000}}]}",
    }) |cost| {
        var listing = try priceListing(cost);
        defer listing.deinit(t.allocator);
        const row = listing.directory.rows[0];
        try t.expect(row.dev_input_price_threshold == null);
        try t.expectEqual(@as(?u32, 1000000), row.dev_context_tokens);
        try t.expectEqual(@as(?u32, 16384), row.dev_output_tokens);
    }
    for ([_][]const u8{ "0", "-1", "16777217", "4294967296", "1.0", "1e5", "\"100000\"", "null", "true", "{}", "[]" }) |size| {
        const cost = try std.fmt.allocPrint(t.allocator, "{{\"input\":0.1,\"output\":0.5,\"tiers\":[{{\"input\":0.5,\"output\":2.5,\"tier\":{{\"type\":\"context\",\"size\":{s}}}}}]}}", .{size});
        defer t.allocator.free(cost);
        var listing = try priceListing(cost);
        defer listing.deinit(t.allocator);
        try t.expect(listing.directory.rows[0].dev_input_price_threshold == null);
    }
    for ([_][]const u8{
        "{\"input\":0.1,\"input\":0.2}",
        "{\"tiers\":[],\"tiers\":[]}",
        "{\"tiers\":[{\"input\":1,\"input\":2}]}",
        "{\"tiers\":[{\"tier\":{\"size\":1,\"size\":2}}]}",
        "{\"tiers\":[{\"tier\":{\"type\":\"context\",\"type\":\"context\"}}]}",
    }) |cost| try t.expectError(error.InvalidModelsDev, priceListing(cost));
}
test "price threshold unknown adapter stays unknown while tiers beyond the former limit derive authority" {
    const body = try std.fmt.allocPrint(t.allocator, "{{\"opencode-go\":{{\"models\":{{\"same\":{{\"limit\":{{\"output\":8192}},\"cost\":{s}}}}}}}}}", .{price_cost});
    defer t.allocator.free(body);
    var unknown = try m.parseDev(t.allocator, body);
    defer unknown.deinit(t.allocator);
    try t.expect(unknown.directory.rows[0].dev_input_price_threshold == null);
    var cost: std.ArrayList(u8) = .empty;
    defer cost.deinit(t.allocator);
    try cost.appendSlice(t.allocator, "{\"input\":0,\"output\":0,\"tiers\":[");
    for (0..129) |i| {
        if (i != 0) try cost.append(t.allocator, ',');
        try cost.appendSlice(t.allocator, "{\"input\":1,\"output\":1,\"tier\":{\"type\":\"context\",\"size\":1}}");
    }
    try cost.appendSlice(t.allocator, "]}");
    var bounded = try priceListing(cost.items);
    defer bounded.deinit(t.allocator);
    try t.expectEqual(@as(?u32, 1), bounded.directory.rows[0].dev_input_price_threshold);
    try t.expectEqual(@as(?u32, 16384), bounded.directory.rows[0].dev_output_tokens);
}
test "price threshold current generation success manual refresh and stale isolation" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const legacy =
        \\{"version":16,"directory_mask":4,"models":[{"provider":"opencode_go","id":"claude-haiku-5-5","context_window":1000000,"output_tokens":8192,"dev_output_tokens":16384,"dev_input_price_threshold":123,"protocol":"anthropic","dev_protocol":"anthropic","available":true,"dev_present":true}],"refresh":[{"generation":11,"last_attempt_ms":900,"last_success_ms":900,"successful":true},{"generation":12,"last_attempt_ms":900,"last_success_ms":900,"successful":true},{"generation":13,"last_attempt_ms":900,"last_success_ms":900,"successful":true},{},{"generation":14,"last_attempt_ms":900,"last_success_ms":900,"successful":true}]}
    ;
    try root.writeMode(m.file_name, legacy, true, 0o600);
    var migrated = try m.load(&root);
    defer migrated.deinit(t.allocator);
    try t.expectEqual(@as(?u32, 123), migrated.directory.rows[0].dev_input_price_threshold);
    try t.expectEqual(@as(?u32, 8192), migrated.directory.rows[0].output_tokens);
    try t.expectEqual(@as(?u64, 900), migrated.refresh[4].last_success_ms);
    try t.expectEqual(@as(u64, 14), migrated.refresh[4].generation);
    try t.expectEqual(@as(u8, 0), m.eligible(&migrated, m.bit(.opencode_go), 1000, .{}));
    var first = try m.claimAt(&root, m.dev_bit, true, 1000, .{});
    defer first.cache.deinit(t.allocator);
    try t.expectEqual(m.dev_bit, first.mask);
    try t.expectEqual(@as(u64, 15), first.generations[4]);
    try t.expectEqual(@as(u64, 11), first.generations[0]);
    try t.expectEqual(@as(u64, 12), first.generations[1]);
    try t.expectEqual(@as(u64, 13), first.generations[2]);
    var cooldown = try m.claimAt(&root, m.dev_bit, false, 1001, .{});
    defer cooldown.cache.deinit(t.allocator);
    try t.expectEqual(@as(u8, 0), cooldown.mask);
    var newer = try m.claimAt(&root, m.dev_bit, true, 1000, .{});
    defer newer.cache.deinit(t.allocator);
    var public = try priceListing(price_cost);
    defer public.deinit(t.allocator);
    var accepted = try m.commitClaimedAt(&root, 0, public, newer.generations, 1010);
    defer accepted.cache.deinit(t.allocator);
    try t.expectEqual(m.dev_bit, accepted.accepted);
    const entry = m.restoreEntry(&accepted.cache, .opencode_go, "claude-haiku-5-5").?;
    try t.expectEqual(@as(?u32, 100000), m.inputPriceThresholdFor(&accepted.cache, entry));
    var delayed_listing = try priceListing("{}");
    defer delayed_listing.deinit(t.allocator);
    var delayed = try m.commitClaimedAt(&root, 0, delayed_listing, first.generations, 1020);
    defer delayed.cache.deinit(t.allocator);
    try t.expectEqual(@as(u8, 0), delayed.accepted);
    try t.expectEqual(@as(?u32, 100000), m.inputPriceThresholdFor(&delayed.cache, entry));
    var loaded = try m.load(&root);
    defer loaded.deinit(t.allocator);
    try t.expectEqual(@as(?u32, 100000), m.inputPriceThresholdFor(&loaded, entry));
    try t.expectEqual(@as(?u32, 1000000), loaded.directory.rows[0].tokens);
    var cleared: m.Listing = .{};
    defer cleared.deinit(t.allocator);
    var clear_source = try priceListing("{}");
    defer clear_source.deinit(t.allocator);
    try m.mergeDev(t.allocator, &cleared, &clear_source);
    var removed = try m.commitAt(&root, 0, cleared, 1030);
    defer removed.deinit(t.allocator);
    try t.expect(m.inputPriceThresholdFor(&removed, entry) == null);
    try t.expectEqual(@as(?u32, 8192), m.outputFor(&removed, entry));
}
test "price threshold current strict cache tokens and invalid publication rollback" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    for ([_]u32{m.cache_version}) |version| {
        for ([_][]const u8{ "0", "-1", "16777217", "4294967296", "1.0", "1e5", "\"100000\"", "true", "{}", "[]" }) |token| {
            const body = try std.fmt.allocPrint(t.allocator, "{{\"version\":{d},\"models\":[{{\"provider\":\"opencode_go\",\"id\":\"same\",\"dev_input_price_threshold\":{s}}}]}}", .{ version, token });
            defer t.allocator.free(body);
            try root.writeMode(m.file_name, body, true, 0o600);
            if (m.load(&root)) |_| return error.AcceptedInvalidThreshold else |_| {}
        }
    }
    try root.writeMode(m.file_name, "{\"version\":16}", true, 0o600);
    var public = try priceListing(price_cost);
    defer public.deinit(t.allocator);
    var saved = try m.commitAt(&root, 0, public, 1000);
    defer saved.deinit(t.allocator);
    var invalid = public;
    invalid.directory = try public.directory.clone(t.allocator);
    defer invalid.deinit(t.allocator);
    invalid.directory.rows[0].dev_input_price_threshold = 16777217;
    try t.expectError(error.InvalidMetadata, m.commitAt(&root, 0, invalid, 1100));
    var after = try m.load(&root);
    defer after.deinit(t.allocator);
    try t.expectEqualDeep(saved.refresh, after.refresh);
    try t.expectEqual(saved.directory.count, after.directory.count);
    const saved_index = saved.directory.find(.opencode_go, "claude-haiku-5-5").?;
    const after_index = after.directory.find(.opencode_go, "claude-haiku-5-5").?;
    try t.expectEqualDeep(saved.directory.rows[saved_index], after.directory.rows[after_index]);
}
test "price threshold unordered tiers earliest increase conflicts invalid and boundaries" {
    const Case = struct { tiers: []const u8, expected: ?u32 };
    for ([_]Case{
        .{ .tiers = "[]", .expected = null },
        .{ .tiers = "[{\"input\":0.5,\"output\":2.5,\"tier\":{\"type\":\"context\",\"size\":200000}},{\"input\":0.1,\"output\":1,\"tier\":{\"type\":\"context\",\"size\":100000}}]", .expected = 100000 },
        .{ .tiers = "[{\"input\":0.1,\"output\":0.5,\"tier\":{\"type\":\"context\",\"size\":1}},{\"input\":0.2,\"output\":0.5,\"tier\":{\"type\":\"context\",\"size\":16777216}}]", .expected = 16777216 },
        .{ .tiers = "[{\"input\":0.2,\"output\":0.5,\"tier\":{\"type\":\"context\",\"size\":1}}]", .expected = 1 },
        .{ .tiers = "[{\"input\":0,\"output\":0.5,\"tier\":{\"type\":\"context\",\"size\":100000}}]", .expected = null },
        .{ .tiers = "[{\"input\":0.2,\"output\":0.5,\"tier\":{\"type\":\"other\",\"size\":100000}}]", .expected = null },
        .{ .tiers = "[{\"input\":0.2,\"output\":0.5,\"tier\":{\"type\":\"context\",\"size\":100000}},{\"input\":0.3,\"output\":0.5,\"tier\":{\"type\":\"context\",\"size\":100000}}]", .expected = null },
    }) |case| {
        const cost = try std.fmt.allocPrint(t.allocator, "{{\"input\":0.1,\"output\":0.5,\"tiers\":{s}}}", .{case.tiers});
        defer t.allocator.free(cost);
        var listing = try priceListing(cost);
        defer listing.deinit(t.allocator);
        try t.expectEqual(case.expected, listing.directory.rows[0].dev_input_price_threshold);
    }
}
test "publication generations reject delayed sources independently and distinguish same-ms claims" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const official = m.bit(.deepseek);
    const both = official | m.dev_bit;
    var old = try m.claimAt(&root, both, true, 1000, .{});
    defer old.cache.deinit(t.allocator);
    var newer = try m.claimAt(&root, official, true, 1000, .{});
    defer newer.cache.deinit(t.allocator);
    try t.expectEqual(old.generations[0] + 1, newer.generations[0]);
    var fresh = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"fresh\",\"context_window\":65536}]}", .deepseek);
    defer fresh.deinit(t.allocator);
    var published = try m.commitClaimedAt(&root, official, fresh, newer.generations, 1010);
    defer published.cache.deinit(t.allocator);
    try t.expectEqual(official, published.accepted);
    var delayed = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"obsolete\",\"context_window\":32768}]}", .deepseek);
    defer delayed.deinit(t.allocator);
    var clear_source = try m.parseDev(t.allocator, "{}");
    defer clear_source.deinit(t.allocator);
    try m.mergeDev(t.allocator, &delayed, &clear_source);
    var result = try m.commitClaimedAt(&root, official, delayed, old.generations, 2000);
    defer result.cache.deinit(t.allocator);
    try t.expectEqual(m.dev_bit, result.accepted);
    try t.expect(result.cache.directory.find(.deepseek, "obsolete") == null);
    try t.expect(result.cache.directory.rows[result.cache.directory.find(.deepseek, "fresh").?].available == true);
    try t.expectEqual(@as(?u64, 1010), result.cache.refresh[0].last_success_ms);
    try t.expectEqual(@as(?u64, 2000), result.cache.refresh[4].last_success_ms);
    // The opposite ordering must not let a stale public result block official.
    var a_claim = try m.claimAt(&root, both, true, 3000, .{});
    defer a_claim.cache.deinit(t.allocator);
    var b_claim = try m.claimAt(&root, m.dev_bit, true, 3000, .{});
    defer b_claim.cache.deinit(t.allocator);
    var public_listing = try m.parseDev(t.allocator,
        \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"fresh":{"limit":{"context":262144,"output":8192}}}}}
    );
    defer public_listing.deinit(t.allocator);
    var public_result = try m.commitClaimedAt(&root, 0, public_listing, b_claim.generations, 3010);
    defer public_result.cache.deinit(t.allocator);
    fresh.dev_done = true;
    var independent = try m.commitClaimedAt(&root, official, fresh, a_claim.generations, 4000);
    defer independent.cache.deinit(t.allocator);
    try t.expectEqual(official, independent.accepted);
    const retained_public = independent.cache.directory.rows[independent.cache.directory.find(.deepseek, "fresh").?];
    try t.expectEqual(@as(?u32, 262144), retained_public.dev_context_tokens);
    try t.expectEqual(@as(?u32, 8192), retained_public.dev_output_tokens);
    try t.expectEqual(@as(?u64, 3010), independent.cache.refresh[4].last_success_ms);
    try t.expectEqual(@as(?u64, 4000), independent.cache.refresh[0].last_success_ms);
}
test "publication current generation strict tokens exhaustion and durable timing" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    for ([_][]const u8{ "\"1\"", "1.0", "1e3", "-1", "9223372036854775808", "null" }) |token| {
        const body = try std.fmt.allocPrint(t.allocator, "{{\"version\":16,\"refresh\":[{{\"generation\":{s}}},{{}},{{}},{{}},{{}}]}}", .{token});
        defer t.allocator.free(body);
        try root.writeMode(m.file_name, body, true, 0o600);
        if (m.load(&root)) |_| return error.AcceptedInvalidGeneration else |_| {}
    }
    const exhausted = "{\"version\":16,\"refresh\":[{\"generation\":9223372036854775807},{},{},{},{}]}";
    try root.writeMode(m.file_name, exhausted, true, 0o600);
    var before = try m.load(&root);
    defer before.deinit(t.allocator);
    try t.expectError(error.MetadataGenerationExhausted, m.claimAt(&root, m.bit(.deepseek) | m.dev_bit, true, 1000, .{}));
    var after = try m.load(&root);
    defer after.deinit(t.allocator);
    try t.expectEqualDeep(before.refresh, after.refresh);
    try t.expectEqual(before.directory.count, after.directory.count);
    try root.writeMode(m.file_name, "{\"version\":16,\"models\":[{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":65536,\"available\":true}],\"refresh\":[{\"last_attempt_ms\":100,\"last_success_ms\":110,\"successful\":true},{},{},{},{}]}", true, 0o600);
    var claimed = try m.claimAt(&root, m.bit(.deepseek), true, 120, .{});
    defer claimed.cache.deinit(t.allocator);
    try t.expectEqual(@as(u64, 1), claimed.generations[0]);
    try t.expectEqual(@as(?u64, 110), claimed.cache.refresh[0].last_success_ms);
    try t.expectEqual(@as(?u32, 65536), claimed.cache.directory.rows[0].tokens);
}
test "refresh timing exact TTL cooldown restart independent manual rollback" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const official = m.bit(.deepseek);
    const both = official | m.dev_bit;
    const policy: m.Policy = .{ .ttl_ms = 400, .cooldown_ms = 50 };
    try t.expectEqual(both, try claimMask(&root, both, false, 1000, policy));
    // Reload/second process observes the durable pre-launch claim.
    try t.expectEqual(@as(u8, 0), try claimMask(&root, both, false, 1049, policy));
    var listing = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":131072}]}", .deepseek);
    defer listing.deinit(t.allocator);
    var cache = try m.commitAt(&root, official, listing, 1010);
    defer cache.deinit(t.allocator);
    try t.expectEqual(@as(u8, 0), m.eligible(&cache, both, 1049, policy));
    try t.expectEqual(m.dev_bit, m.eligible(&cache, both, 1050, policy));
    try t.expectEqual(m.dev_bit, try claimMask(&root, both, false, 1050, policy));
    // Failure keeps successful capabilities and last-success time.
    cache.deinit(t.allocator);
    cache = try m.commitAt(&root, 0, .{}, 1051);
    try t.expectEqual(@as(?u32, 131072), cache.directory.rows[0].tokens);
    try t.expectEqual(@as(?u64, 1010), cache.refresh[0].last_success_ms);
    try t.expectEqual(@as(u8, 0), m.eligible(&cache, official, 1409, policy));
    try t.expectEqual(official, m.eligible(&cache, official, 1410, policy));
    try t.expectEqual(official, try claimMask(&root, official, true, 1060, policy));
    try t.expectEqual(@as(u8, 0), try claimMask(&root, official, false, 1109, policy));
    try t.expectEqual(official, try claimMask(&root, official, false, 1110, policy));
    // Clock rollback grants one repair, then observes cooldown even on restart.
    try t.expectEqual(official, try claimMask(&root, official, false, 500, policy));
    cache.deinit(t.allocator);
    cache = try m.load(&root);
    try t.expect(cache.refresh[0].last_success_ms == null);
    try t.expectEqual(@as(u8, 0), try claimMask(&root, official, false, 500, policy));
    try t.expectEqual(@as(u8, 0), try claimMask(&root, official, false, 549, policy));
    try t.expectEqual(official, try claimMask(&root, official, false, 550, policy));
}
test "refresh timing default deadlines and public success are independent" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const official = m.bit(.deepseek);
    const both = official | m.dev_bit;
    _ = try claimMask(&root, both, false, 0, .{});
    var cache = try m.commitAt(&root, 0, .{ .dev_done = true }, 10);
    defer cache.deinit(t.allocator);
    try t.expectEqual(@as(?u64, 10), cache.refresh[4].last_success_ms);
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
        const body = try std.fmt.allocPrint(t.allocator, "{{\"version\":16,\"refresh\":[{{\"last_attempt_ms\":{s}}},{{}},{{}},{{}},{{}}]}}", .{token});
        defer t.allocator.free(body);
        try root.writeMode(m.file_name, body, true, 0o600);
        if (m.load(&root)) |_| return error.AcceptedInvalidTimestamp else |_| {}
    }
    try root.writeMode(m.file_name, "{\"version\":16,\"refresh\":[{\"last_attempt_ms\":0},{\"last_success_ms\":253402300799999},{},{},{}]}", true, 0o600);
    var valid = try m.load(&root);
    defer valid.deinit(t.allocator);
    try t.expectEqual(@as(?u64, 0), valid.refresh[0].last_attempt_ms);
    try t.expectEqual(@as(?u64, m.max_timestamp_ms), valid.refresh[1].last_success_ms);
}
test "Codex cache and independent source generation preserve authenticated listing" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const codex = m.bit(.openai_codex);
    var old = try m.claimAt(&root, codex | m.dev_bit, true, 10, .{});
    defer old.cache.deinit(t.allocator);
    var newer = try m.claimAt(&root, codex, true, 10, .{});
    defer newer.cache.deinit(t.allocator);
    var listing = try m.parseListing(t.allocator,
        \\{"models":[{"slug":"new/id","visibility":"list","supported_in_api":false,"default_reasoning_level":"high","input_modalities":["text","image"],"context_window":0,"max_context_window":64000,"supported_reasoning_levels":[{"effort":"none","description":""},{"effort":"high","description":""},{"effort":"future","description":""}]}]}
    , .openai_codex);
    defer listing.deinit(t.allocator);
    var stale = try m.commitClaimedAt(&root, codex, listing, old.generations, 11);
    defer stale.cache.deinit(t.allocator);
    try t.expectEqual(@as(u8, 0), stale.accepted);
    var saved = try m.commitClaimedAt(&root, codex, listing, newer.generations, 12);
    defer saved.cache.deinit(t.allocator);
    var loaded = try m.load(&root);
    defer loaded.deinit(t.allocator);
    const entry = m.dynamicEntry(&loaded, .openai_codex, "new/id").?;
    try t.expectEqual(@as(?u32, 64000), m.contextFor(&loaded, entry));
    try t.expect(m.outputFor(&loaded, entry) == null);
    try t.expect(m.inputPriceFlatLimitFor(&loaded, entry) == null);
    const row = loaded.directory.rows[loaded.directory.find(.openai_codex, "new/id").?];
    try t.expectEqual(@as(?bool, true), row.input_image);
    try t.expectEqual(@as(?@import("../presentation/activity.zig").ReasoningEffort, .high), row.default_reasoning);
    try t.expectEqualStrings("none", row.reasoning.?.declaration().map.off.?);
    try t.expectEqual(@as(?u64, 12), saved.cache.refresh[3].last_success_ms);
    try t.expectEqual(@as(?u64, null), saved.cache.refresh[4].last_success_ms);
    var empty = try m.parseListing(t.allocator, "{\"models\":[]}", .openai_codex);
    defer empty.deinit(t.allocator);
    var gone = try m.commitAt(&root, codex, empty, 13);
    defer gone.deinit(t.allocator);
    try t.expect(m.dynamicEntry(&gone, .openai_codex, "new/id") == null);
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
    defer dev.deinit(t.allocator);
    var official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"chat\",\"max_tokens\":12345}]}", .deepseek);
    defer official.deinit(t.allocator);
    try t.expect(official.directory.rows[0].output_tokens == null);
    official.directory.rows[0].output_tokens = 4096; // Synthetic verified official capability.
    try m.mergeOfficial(t.allocator, &dev, &official, .deepseek);
    try t.expectEqual(@as(?u32, 8192), dev.directory.rows[0].dev_output_tokens);
    var cache = try m.commit(&root, m.bit(.deepseek), dev);
    defer cache.deinit(t.allocator);
    cache.deinit(t.allocator);
    cache = try m.load(&root);
    for (legacyProviders) |id| {
        const entry = m.restoreEntry(&cache, id, "same").?;
        const expected: u32 = switch (id) {
            .deepseek => 4096,
            .opencode_go => 16384,
            .opencode_zen => 32768,
            .openai_codex => return error.UnexpectedFixtureProvider,
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
    cache.deinit(t.allocator);
    cache = try m.commit(&root, 0, .{}); // Failed refresh keeps both sources.
    try t.expectEqual(@as(?u32, 32768), m.outputFor(&cache, m.restoreEntry(&cache, .opencode_zen, "same").?));
    var replacement = try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"same":{"limit":{"context":99999}}}}}
    );
    defer replacement.deinit(t.allocator);
    try m.mergeDev(t.allocator, &dev, &replacement);
    try t.expect(dev.directory.rows[dev.directory.find(.opencode_zen, "same").?].dev_output_tokens == null);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, 0, replacement);
    try t.expect(m.outputFor(&cache, m.restoreEntry(&cache, .opencode_zen, "same").?) == null);
    replacement.deinit(t.allocator);
    replacement = try m.parseDev(t.allocator, "{}");
    cache.deinit(t.allocator);
    cache = try m.commit(&root, 0, replacement);
    try t.expect(m.outputFor(&cache, m.restoreEntry(&cache, .opencode_zen, "same").?) == null);
    try t.expectEqual(@as(?u32, 4096), m.outputFor(&cache, m.restoreEntry(&cache, .deepseek, "same").?));
    official.deinit(t.allocator);
    official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"chat\"}]}", .deepseek);
    cache.deinit(t.allocator);
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
    var official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"anthropic\"}]}", .opencode_go);
    defer official.deinit(t.allocator);
    defer listing.deinit(t.allocator);
    try m.mergeOfficial(t.allocator, &listing, &official, .opencode_go);
    var cache = try m.commit(&root, m.bit(.opencode_go), listing);
    defer cache.deinit(t.allocator);
    const entry: catalog.Entry = .{ .provider = .opencode_go, .selector = "opencode-go/same", .model = .{ .name = "same", .context_tokens = 131072, .protocol = .chat } };
    try t.expect(m.outputFor(&cache, entry) == null);
    var config: cfg.Config = .{ .provider = catalog.connection(.opencode_go), .model = entry.model };
    m.applyOutput(&cache, &config);
    try t.expect(config.model.output_tokens == null);
}
test "output cache current schema rejects unbounded values transactionally" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var buffer: [1024]u8 = undefined;
    for ([_][]const u8{ "0", "1048577", "4294967296", "1.5", "\"100\"", "-1" }) |invalid_output| {
        const body = try std.fmt.bufPrint(&buffer, "{{\"version\":16,\"models\":[{{\"provider\":\"deepseek\",\"id\":\"same\",\"output_tokens\":{s}}}]}}", .{invalid_output});
        try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = body });
        const before = try root.dir.statFile(root.io, m.file_name, .{});
        if (m.commit(&root, 0, .{})) |value| {
            var unexpected = value;
            unexpected.deinit(t.allocator);
            return error.ExpectedInvalidCache;
        } else |_| {}
        try t.expectEqual(before.inode, (try root.dir.statFile(root.io, m.file_name, .{})).inode);
    }
}
test "public output invalid values unknown and no cross provider votes" {
    const body =
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"zero":{"limit":{"output":0}},"negative":{"limit":{"output":-1}},"float":{"limit":{"output":1.5}},"string":{"limit":{"output":"123"}},"overflow":{"limit":{"output":4294967296}},"large":{"limit":{"output":1048577}},"edge":{"limit":{"output":1048576}},"context":{"limit":{"context":65536},"budget_tokens":1000},"same":{},"unknown":{"provider":{"npm":"unsupported"},"limit":{"output":123}}}},"foreign":{"npm":"@ai-sdk/openai","models":{"same":{"limit":{"output":5000}}}}}
    ;
    var dev = try m.parseDev(t.allocator, body);
    defer dev.deinit(t.allocator);
    for (dev.directory.rows[0..dev.directory.count], 0..) |row, index| {
        if (std.mem.eql(u8, dev.directory.name(index), "edge")) {
            try t.expectEqual(@as(?u32, 1048576), row.dev_output_tokens);
        } else try t.expect(row.dev_output_tokens == null);
    }
}
test "dynamic metadata merges all three directories and exact adapters across cache reload" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var listing = try officialThree();
    defer listing.deinit(t.allocator);
    var cache = try m.commit(&root, m.provider_mask, listing);
    defer cache.deinit(t.allocator);
    try t.expect(m.hasDirectory(&cache, .deepseek));
    try t.expect(m.hasDirectory(&cache, .opencode_go));
    try t.expect(m.hasDirectory(&cache, .opencode_zen));
    try t.expectEqual(.chat, m.findEntry(&cache, "deepseek/fresh-deepseek").?.model.protocol);
    try t.expectEqual(.auto, m.findEntry(&cache, "opencode-zen/fresh-native").?.model.protocol);
    try t.expect(m.findEntry(&cache, "opencode-zen/gpt-5.2") == null);
    var dev = try m.parseDev(t.allocator, public_catalog);
    defer dev.deinit(t.allocator);
    try m.mergeDev(t.allocator, &listing, &dev);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, m.provider_mask, listing);
    cache.deinit(t.allocator);
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
    var cache = try commitOwned(&root, m.provider_mask, try officialThree());
    defer cache.deinit(t.allocator);
    cache.deinit(t.allocator);
    cache = try commitOwned(&root, 0, try m.parseDev(t.allocator, public_catalog));
    var stale = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"stale-id\",\"protocol\":\"responses\"}]}", .opencode_zen);
    defer stale.deinit(t.allocator);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, 0, stale);
    try t.expect(cache.directory.find(.opencode_zen, "stale-id") == null);
    try t.expect(m.findEntry(&cache, "opencode-zen/fresh-native") != null);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, 0, .{});
    try t.expectEqual(.anthropic, m.findEntry(&cache, "opencode-go/fresh-shared").?.model.protocol);
    var empty = try m.parseListing(t.allocator, "{\"data\":[]}", .opencode_zen);
    defer empty.deinit(t.allocator);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, m.bit(.opencode_zen), empty);
    try t.expect(m.findEntry(&cache, "opencode-zen/fresh-native") == null);
    try t.expect(m.restoreEntry(&cache, .opencode_zen, "fresh-native") != null);
    try t.expect(m.findEntry(&cache, "opencode-go/fresh-shared") != null);
    var reloaded = try m.load(&root);
    defer reloaded.deinit(t.allocator);
    try t.expect(m.hasDirectory(&reloaded, .opencode_zen));
    try t.expect(m.findEntry(&reloaded, "opencode-zen/gpt-5.2") == null);
}
test "dynamic metadata official protocol wins while unknown adapter removes derived controls" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"fresh-native\",\"protocol\":\"chat\",\"effort\":{\"supported_levels\":[\"high\"]}}]}", .opencode_zen);
    defer official.deinit(t.allocator);
    var cache = try m.commit(&root, m.bit(.opencode_zen), official);
    defer cache.deinit(t.allocator);
    cache.deinit(t.allocator);
    cache = try commitOwned(&root, 0, try m.parseDev(t.allocator, public_catalog));
    const entry = m.findEntry(&cache, "opencode-zen/fresh-native").?;
    try t.expectEqual(.chat, entry.model.protocol);
    try t.expect(m.entryDeclaration(&cache, entry) == null);
    var entry_owner = cache;
    cache = .{};
    defer entry_owner.deinit(t.allocator);
    cache = try commitOwned(&root, 0, try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"fresh-native":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    ));
    const compatible = m.entryDeclaration(&cache, entry).?;
    try t.expectEqual(.standard, compatible.format);
    try t.expectEqualStrings("low", compatible.map.low.?);
    var unknown = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"fresh-native\"}]}", .opencode_zen);
    defer unknown.deinit(t.allocator);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, m.bit(.opencode_zen), unknown);
    cache.deinit(t.allocator);
    cache = try commitOwned(&root, 0, try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"unrecognized-adapter","models":{"fresh-native":{}}}}
    ));
    const pending = m.findEntry(&cache, "opencode-zen/fresh-native").?;
    try t.expectEqual(.auto, pending.model.protocol);
    try t.expect(m.entryDeclaration(&cache, pending) == null);
    try t.expectEqual(@as(u32, 32768), pending.model.context_tokens);
}
test "dynamic metadata source merges retain all rows beyond the former limit" {
    var target: m.Listing = .{ .dev_done = true };
    defer target.deinit(t.allocator);
    var name: [32]u8 = undefined;
    for (0..1536) |index| {
        _ = try target.directory.upsert(t.allocator, .opencode_go, try std.fmt.bufPrint(&name, "merge-{d}", .{index}));
    }
    var source: m.Listing = .{ .directory_mask = m.bit(.opencode_go), .dev_done = true };
    defer source.deinit(t.allocator);
    for ([_][]const u8{ "merge-0", "overflow-new" }) |id| {
        const row = try source.directory.upsert(t.allocator, .opencode_go, id);
        row.tokens = 222;
        row.dev_context_tokens = 888;
        row.dev_present = true;
    }
    try m.mergeOfficial(t.allocator, &target, &source, .opencode_go);
    try m.mergeDev(t.allocator, &target, &source);
    try t.expectEqual(@as(usize, 1537), target.directory.count);
    try t.expectEqual(@as(?u32, 222), target.directory.rows[target.directory.find(.opencode_go, "merge-0").?].tokens);
    try t.expectEqual(@as(?u32, 888), target.directory.rows[target.directory.find(.opencode_go, "overflow-new").?].dev_context_tokens);
}
test "official row fields survive public-only directory publication" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    // Cached declarations still require the only canonical wire spellings.
    for ([_][]const u8{
        "{\"version\":16,\"models\":[{\"provider\":\"opencode_zen\",\"id\":\"bad-level\",\"reasoning\":{\"map\":{\"high\":\"intensive\"}}}]}",
        "{\"version\":16,\"models\":[{\"provider\":\"opencode_zen\",\"id\":\"bad-off\",\"reasoning\":{\"map\":{\"off\":\"disabled\"}}}]}",
        "{\"version\":16,\"models\":[{\"provider\":\"deepseek\",\"id\":\"bad-off\",\"reasoning\":{\"format\":\"deepseek\",\"map\":{\"off\":\"none\"}}}]}",
    }) |invalid| {
        try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = invalid });
        try t.expectError(error.InvalidMetadata, m.load(&root));
    }
    const legacy = "{\"version\":16,\"models\":[{\"provider\":\"opencode_zen\",\"id\":\"gpt-5.2\",\"protocol\":\"responses\",\"context_window\":100000,\"available\":true,\"reasoning\":{\"map\":{\"high\":\"high\"}}}]}";
    try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = legacy });
    var cache = try commitOwned(&root, 0, try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"gpt-5.2":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    ));
    defer cache.deinit(t.allocator);
    // Public reasoning is selected while the legacy official capacity and raw
    // official declaration remain intact in storage.
    try t.expect(!m.hasDirectory(&cache, .opencode_zen));
    const entry = m.findEntry(&cache, "opencode-zen/gpt-5.2").?;
    try t.expectEqual(@as(?u32, 100000), m.capacityFor(&cache, entry));
    const declaration = m.entryDeclaration(&cache, entry).?;
    try t.expectEqualStrings("low", declaration.map.low.?);
    try t.expect(declaration.map.high == null);
    try t.expectEqualStrings("high", cache.directory.rows[cache.directory.find(.opencode_zen, "gpt-5.2").?].reasoning.?.declaration().map.high.?);
    // Keep the cache alive while its entry's selector and model name are borrowed.
    var entry_owner = cache;
    cache = .{};
    defer entry_owner.deinit(t.allocator);
    // Conflicting public routing cannot authorize reasoning for the official route.
    cache = try commitOwned(&root, 0, try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"gpt-5.2":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    ));
    try t.expect(m.entryDeclaration(&cache, entry) == null);
    try t.expectEqualStrings("high", cache.directory.rows[cache.directory.find(.opencode_zen, "gpt-5.2").?].reasoning.?.declaration().map.high.?);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, 0, .{});
    cache.deinit(t.allocator);
    cache = try m.load(&root);
    try t.expect(!m.hasDirectory(&cache, .opencode_zen));
    try t.expectEqual(@as(?u32, 100000), m.capacityFor(&cache, entry));
    try t.expect(m.entryDeclaration(&cache, entry) == null);
    try t.expectEqualStrings("high", cache.directory.rows[cache.directory.find(.opencode_zen, "gpt-5.2").?].reasoning.?.declaration().map.high.?);
    // A later successful official refresh supersedes those old values, including
    // clearing omitted capacity/effort rather than reviving legacy metadata.
    var fresh = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"gpt-5.2\"}]}", .opencode_zen);
    defer fresh.deinit(t.allocator);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, m.bit(.opencode_zen), fresh);
    const updated = m.findEntry(&cache, "opencode-zen/gpt-5.2").?;
    try t.expect(m.hasDirectory(&cache, .opencode_zen));
    try t.expect(m.capacityFor(&cache, updated) == null);
    try t.expect(cache.directory.rows[cache.directory.find(.opencode_zen, "gpt-5.2").?].reasoning == null);
    try t.expectEqualStrings("low", m.entryDeclaration(&cache, updated).?.map.low.?);
}
test "context public exact SDK routes roundtrip official precedence and frozen entries" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var listing = try m.parseDev(t.allocator,
        \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"same/raw":{"limit":{"context":131072,"output":4096}}}},"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"same/raw":{"limit":{"context":262144}}}},"opencode":{"npm":"@ai-sdk/openai","models":{"same/raw":{"limit":{"context":524288}}}}}
    );
    defer listing.deinit(t.allocator);
    var official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same/raw\",\"protocol\":\"chat\",\"context_window\":65536}]}", .deepseek);
    defer official.deinit(t.allocator);
    try m.mergeOfficial(t.allocator, &listing, &official, .deepseek);
    try t.expectEqual(@as(?u32, 131072), listing.directory.rows[0].dev_context_tokens);
    var cache = try m.commit(&root, m.bit(.deepseek), listing);
    defer cache.deinit(t.allocator);
    cache.deinit(t.allocator);
    cache = try m.load(&root);
    for (legacyProviders) |id| {
        const entry = m.restoreEntry(&cache, id, "same/raw").?;
        const expected: u32 = switch (id) {
            .deepseek => 65536,
            .opencode_go => 262144,
            .opencode_zen => 524288,
            .openai_codex => return error.UnexpectedFixtureProvider,
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
    var frozen_owner = cache;
    cache = .{};
    defer frozen_owner.deinit(t.allocator);
    cache = try m.commit(&root, 0, .{}); // Failure preserves both sources.
    try t.expectEqual(@as(?u32, 262144), m.contextFor(&cache, frozen));
    var replacement = try m.parseDev(t.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"same/raw":{"limit":{"context":1048576}}}}}
    );
    defer replacement.deinit(t.allocator);
    try m.mergeDev(t.allocator, &listing, &replacement);
    try t.expect(listing.directory.rows[listing.directory.find(.opencode_zen, "same/raw").?].dev_context_tokens == null);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, 0, replacement);
    try t.expectEqual(@as(u32, 262144), frozen.model.context_tokens);
    try t.expectEqual(@as(u32, 1048576), m.restoreEntry(&cache, .opencode_go, "same/raw").?.model.context_tokens);
    try t.expectEqual(@as(?u32, 65536), m.contextFor(&cache, m.restoreEntry(&cache, .deepseek, "same/raw").?));
    cache.deinit(t.allocator);
    cache = try commitOwned(&root, 0, try m.parseDev(t.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"same/raw":{"limit":{"output":8192}}}}}
    ));
    try t.expect(m.contextFor(&cache, frozen) == null); // Omitted field clears context, not output.
    try t.expectEqual(@as(?u32, 8192), m.outputFor(&cache, frozen));
    cache.deinit(t.allocator);
    cache = try commitOwned(&root, 0, try m.parseDev(t.allocator, "{}"));
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
    var official = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"anthropic\"}]}", .opencode_go);
    defer official.deinit(t.allocator);
    defer listing.deinit(t.allocator);
    try m.mergeOfficial(t.allocator, &listing, &official, .opencode_go);
    var cache = try m.commit(&root, m.bit(.opencode_go), listing);
    defer cache.deinit(t.allocator);
    var entry = m.restoreEntry(&cache, .opencode_go, "same").?;
    try t.expect(m.contextFor(&cache, entry) == null);
    entry.model.protocol = .chat;
    try t.expect(m.contextFor(&cache, entry) == null);
    entry.provider = .deepseek;
    try t.expect(m.contextFor(&cache, entry) == null);
    var unknown = try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\"}]}", .opencode_go);
    defer unknown.deinit(t.allocator);
    cache.deinit(t.allocator);
    cache = try m.commit(&root, m.bit(.opencode_go), unknown);
    entry = m.restoreEntry(&cache, .opencode_go, "same").?;
    try t.expectEqual(@as(?u32, 262144), m.contextFor(&cache, entry));
    try t.expectEqual(@as(u32, 262144), entry.model.context_tokens);
    try t.expect(m.capacityFor(&cache, entry) == null);
    const row = cache.directory.rows[cache.directory.find(.opencode_go, "same").?];
    try t.expect(row.tokens == null);
    try t.expectEqual(@as(?u32, 262144), row.dev_context_tokens);
    // Valid official window wins even when public routing disagrees.
    cache.deinit(t.allocator);
    cache = try commitOwned(&root, m.bit(.opencode_go), try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"same\",\"protocol\":\"anthropic\",\"context_window\":65536}]}", .opencode_go));
    entry = m.restoreEntry(&cache, .opencode_go, "same").?;
    try t.expectEqual(@as(?u32, 65536), m.contextFor(&cache, entry));
}
test "context public only integer limit context bounds no peer inference or output coupling" {
    const body =
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"zero":{"limit":{"context":0}},"negative":{"limit":{"context":-1}},"float":{"limit":{"context":1.5}},"exponent":{"limit":{"context":1e5}},"string":{"limit":{"context":"123"}},"null":{"limit":{"context":null}},"bool":{"limit":{"context":true}},"object":{"limit":{"context":{}}},"array":{"limit":{"context":[]}},"overflow":{"limit":{"context":4294967296}},"large":{"limit":{"context":16777217}},"edge":{"limit":{"context":16777216,"output":8192}},"one":{"limit":{"context":1}},"wrong-field":{"context_window":100000,"limit":{"input":100000,"output":10000}},"bad-limit":{"limit":100000},"same":{},"unknown":{"provider":{"npm":"unsupported"},"limit":{"context":123}},"invalid":{"provider":{"npm":null},"limit":{"context":123}},"override":{"provider":{"npm":"@ai-sdk/anthropic"},"limit":{"context":65536}}}},"foreign":{"npm":"@ai-sdk/openai","models":{"same":{"limit":{"context":50000}}}}}
    ;
    var dev = try m.parseDev(t.allocator, body);
    defer dev.deinit(t.allocator);
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
test "context public replaces preset fallback but preserves compatible official window" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    const legacy = "{\"version\":16,\"models\":[{\"provider\":\"opencode_zen\",\"id\":\"gpt-5.2\",\"protocol\":\"responses\",\"context_window\":100000,\"available\":true}]}";
    try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = legacy });
    var public = try m.parseDev(t.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai","models":{"gpt-5.2":{"limit":{"context":262144}}}}}
    );
    defer public.deinit(t.allocator);
    var cache = try m.commit(&root, 0, public);
    defer cache.deinit(t.allocator);
    var entry = m.restoreEntry(&cache, .opencode_zen, "gpt-5.2").?;
    try t.expectEqual(@as(?u32, 100000), m.contextFor(&cache, entry));
    try t.expectEqual(@as(u32, 100000), entry.model.context_tokens);
    var wrong = entry;
    wrong.model.protocol = .chat;
    try t.expect(m.contextFor(&cache, wrong) == null);
    // Official success without a window supersedes the old official value.
    cache.deinit(t.allocator);
    cache = try commitOwned(&root, m.bit(.opencode_zen), try m.parseListing(t.allocator, "{\"data\":[{\"id\":\"gpt-5.2\"}]}", .opencode_zen));
    entry = m.restoreEntry(&cache, .opencode_zen, "gpt-5.2").?;
    try t.expectEqual(@as(?u32, 262144), m.contextFor(&cache, entry));
    try t.expectEqual(@as(u32, 262144), entry.model.context_tokens);
    try t.expect(m.capacityFor(&cache, entry) == null);
    var entry_owner = cache;
    cache = .{};
    defer entry_owner.deinit(t.allocator);
    cache = try commitOwned(&root, 0, try m.parseDev(t.allocator, "{}"));
    try t.expect(m.contextFor(&cache, entry) == null);
    const preset = @import("provider_catalog.zig").find("opencode-zen/gpt-5.2").?;
    try t.expectEqual(preset.model.context_tokens, m.restoreEntry(&cache, .opencode_zen, "gpt-5.2").?.model.context_tokens);
}
test "context current invalid cache values and invalid commit roll back durable fields" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var buffer: [1024]u8 = undefined;
    for ([_][]const u8{ "0", "16777217", "4294967296", "1.5", "1e5", "\"100\"", "-1", "true", "{}", "[]" }) |invalid_context| {
        const body = try std.fmt.bufPrint(&buffer, "{{\"version\":16,\"models\":[{{\"provider\":\"deepseek\",\"id\":\"same\",\"dev_context_tokens\":{s}}}]}}", .{invalid_context});
        try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = body });
        const before = try root.dir.statFile(root.io, m.file_name, .{});
        if (m.claim(&root, m.dev_bit, false)) |value| {
            var unexpected = value;
            unexpected.cache.deinit(t.allocator);
            return error.ExpectedInvalidCache;
        } else |_| {}
        if (m.commit(&root, 0, .{})) |value| {
            var unexpected = value;
            unexpected.deinit(t.allocator);
            return error.ExpectedInvalidCache;
        } else |_| {}
        try t.expectEqual(before.inode, (try root.dir.statFile(root.io, m.file_name, .{})).inode);
        const after = try root.read(t.allocator, m.file_name, 0, 1024 * 1024);
        defer t.allocator.free(after.data);
        try t.expectEqualStrings(body, after.data);
    }
    try root.dir.writeFile(root.io, .{ .sub_path = m.file_name, .data = "{\"version\":16}" });
    var listing = try m.parseDev(t.allocator,
        \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"same":{"limit":{"context":65536,"output":4096}}}}}
    );
    defer listing.deinit(t.allocator);
    var saved = try m.commit(&root, 0, listing);
    defer saved.deinit(t.allocator);
    listing.directory.rows[0].dev_context_tokens = 16777217;
    listing.directory.rows[0].dev_output_tokens = 8192;
    try t.expectError(error.InvalidMetadata, m.commit(&root, 0, listing));
    var after = try m.load(&root);
    defer after.deinit(t.allocator);
    try expectLogicalCache(&saved, &after);
}
test "foreign profile cannot manufacture a preset across reload or empty listing" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    var public = try m.parseDev(t.allocator,
        \\{"foreign":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"limit":{"context":1000000,"output":8192},"cost":{"input":1,"output":2},"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high"]}]}}}}
    );
    defer public.deinit(t.allocator);
    var committed = try m.commitAt(&root, 0, public, 1000);
    defer committed.deinit(t.allocator);
    var first = try m.load(&root);
    defer first.deinit(t.allocator);
    const entry = m.restoreEntry(&first, .opencode_go, "claude-haiku-5-5").?;
    var empty = try m.parseListing(t.allocator, "{\"data\":[]}", .opencode_go);
    defer empty.deinit(t.allocator);
    var committed_empty = try m.commitAt(&root, m.bit(.opencode_go), empty, 1100);
    defer committed_empty.deinit(t.allocator);
    var reloaded = try m.load(&root);
    defer reloaded.deinit(t.allocator);
    try t.expect(reloaded.directory.find(.opencode_go, "claude-haiku-5-5") == null);
    try t.expect(m.hasDirectory(&reloaded, .opencode_go));
    try t.expect(m.entryDeclaration(&reloaded, entry) == null);
    try t.expect(m.dynamicEntry(&reloaded, .opencode_go, "claude-haiku-5-5") == null);
    try t.expect(m.contextFor(&reloaded, entry) == null);
    try t.expect(m.outputFor(&reloaded, entry) == null);
    try t.expect(m.inputPriceThresholdFor(&reloaded, entry) == null);
    try t.expect(m.inputPriceFlatLimitFor(&reloaded, entry) == null);
}
