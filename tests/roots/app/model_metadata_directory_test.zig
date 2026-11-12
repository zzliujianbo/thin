const std = @import("std");
const m = @import("model_metadata.zig");
const fs = @import("../platform/filesystem.zig");
const cfg = @import("../core/config.zig");
const t = std.testing;

const price_cost = "{\"input\":0.1,\"output\":0.5,\"tiers\":[{\"input\":0.5,\"output\":2.5,\"tier\":{\"type\":\"context\",\"size\":100000}}]}";

fn priceListing(cost: []const u8) !m.Listing {
    const body = try std.fmt.allocPrint(t.allocator, "{{\"opencode-go\":{{\"npm\":\"@ai-sdk/anthropic\",\"models\":{{\"claude-haiku-5-5\":{{\"limit\":{{\"context\":1000000,\"output\":16384}},\"cost\":{s}}}}}}}}}", .{cost});
    defer t.allocator.free(body);
    return m.parseDev(t.allocator, body);
}

fn rootFor(dir: std.Io.Dir) !fs.Root {
    var path: [4096]u8 = undefined;
    const len = try dir.realPath(t.io, &path);
    return fs.Root.open(t.allocator, t.io, path[0..len]);
}

fn expectLogicalCache(expected: *const m.Cache, actual: *const m.Cache) !void {
    try t.expectEqual(expected.directory_mask, actual.directory_mask);
    try t.expectEqualDeep(expected.refresh, actual.refresh);
    try t.expectEqual(expected.directory.count, actual.directory.count);
    for (expected.directory.rows[0..expected.directory.count], 0..) |expected_row, i| {
        const name = expected.directory.name(i);
        const j = actual.directory.find(expected_row.provider, name) orelse return error.MissingRecord;
        try t.expectEqualStrings(name, actual.directory.name(j));
        var left = expected_row;
        var right = actual.directory.rows[j];
        left.offset = 0;
        right.offset = 0;
        left.next_hash = null;
        right.next_hash = null;
        try t.expectEqualDeep(left, right);
    }
}

fn commitOwned(root: *fs.Root, succeeded: u8, listing: m.Listing) !m.Cache {
    var owned = listing;
    defer owned.deinit(t.allocator);
    return m.commit(root, succeeded, owned);
}

fn claimMask(root: *fs.Root, requested: u8, manual: bool, now: u64, policy: m.Policy) !u8 {
    var claim = try m.claimAt(root, requested, manual, now, policy);
    defer claim.cache.deinit(t.allocator);
    return claim.mask;
}

const public_catalog =
    \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"fresh-deepseek":{}}},"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"fresh-shared":{}}},"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"fresh-shared":{},"fresh-native":{"provider":{"npm":"@ai-sdk/anthropic"},"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["low","high"]}]}}}}
;

const legacyProviders = [_]cfg.providers.Id{ .deepseek, .opencode_go, .opencode_zen };

fn officialThree() !m.Listing {
    var result: m.Listing = .{};
    errdefer result.deinit(t.allocator);
    for (legacyProviders) |id| {
        const body: []const u8 = switch (id) {
            .deepseek => "{\"data\":[{\"id\":\"fresh-deepseek\",\"context_window\":65536}]}",
            .opencode_go => "{\"data\":[{\"id\":\"fresh-shared\"}]}",
            .opencode_zen => "{\"data\":[{\"id\":\"fresh-shared\"},{\"id\":\"fresh-native\",\"context_window\":65536,\"effort\":{\"supported_levels\":[\"off\",\"low\",\"high\"]}}]}",
            .openai_codex => return error.UnexpectedFixtureProvider,
        };
        var listing = try m.parseListing(t.allocator, body, id);
        defer listing.deinit(t.allocator);
        try m.mergeOfficial(t.allocator, &result, &listing, id);
    }
    return result;
}
