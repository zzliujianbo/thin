const std = @import("std");
const m = @import("model_metadata.zig");
const fs = @import("../platform/filesystem.zig");
const cfg = @import("../core/config.zig");
const t = std.testing;

fn rootFor(dir: std.Io.Dir) !fs.Root {
    var path: [4096]u8 = undefined;
    const len = try dir.realPath(t.io, &path);
    return fs.Root.open(t.allocator, t.io, path[0..len]);
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
