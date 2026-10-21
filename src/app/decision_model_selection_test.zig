//! Generic Decision selection: owned local fixtures, no inference or metadata fetch.
const std = @import("std");
const cfg = @import("../core/config.zig");
const Session = @import("session.zig").Session;
const Store = @import("auth_store.zig").Store;
const profiles = @import("decision_selection.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const fixture =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-main-only","models":{"first":{"protocol":"chat","context_tokens":65536},"second":{"protocol":"chat","context_tokens":131072},"tiny":{"protocol":"chat","context_tokens":2048},"judge/raw":{"protocol":"chat","context_tokens":32768},"auto":{"protocol":"auto","context_tokens":32768}}},"other":{"base_url":"https://other.invalid/v1","api_key_env":"OWN_REVIEW_KEY","models":{"family/judge":{"protocol":"chat","context_tokens":16384}}},"native":{"base_url":"https://native-fixture.invalid/v1","api_key":"fake-native-only","models":{"judge/raw":{"protocol":"systemone"},"jev-1.13-free":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"safety_tokens":100}}
;
fn seed(home: []const u8, bytes: []const u8) !void {
    var store = try Store.open(a, io, home);
    defer store.deinit();
    try store.root.writeMode(cfg.file_name, bytes, false, 0o600);
}
fn disk(home: []const u8) ![]const u8 {
    var store = try Store.openExisting(a, io, home);
    defer store.deinit();
    return (try store.root.read(a, cfg.file_name, 0, cfg.max_config_bytes)).data;
}
fn choose(session: *Session, name: []const u8) !void {
    const connection = session.connection();
    try connection.decision_fn.?(connection.context, .{ .model = name });
}
fn declarationsWithoutDecision(config: cfg.Config) ![]u8 {
    var value = config;
    value.decision = null;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(value, &out.writer);
    return a.dupe(u8, out.written());
}
fn contains(models: []const cfg.Model, name: []const u8) bool {
    for (models) |model| if (std.mem.eql(u8, model.name, name)) return true;
    return false;
}

const metadata = @import("model_metadata.zig");
const resolver = @import("model_resolver.zig");
const zen_fixture =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-main-only","models":{"first":{"protocol":"chat","context_tokens":65536}}},"zen":{"base_url":"https://opencode.ai/zen/v1","api_key_env":"ZEN_OWN_KEY","models":{}},"zen-unlogged":{"base_url":"https://opencode.ai/zen/v1","api_key_env":"ZEN_MISSING_KEY","models":{}},"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key":"fake-go-only","models":{}},"lookalike":{"base_url":"https://opencode.ai.example/zen/v1","api_key":"fake-lookalike-only","models":{"jev-1.13-free":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"safety_tokens":100}}
;
const zen_listing =
    \\{"object":"list","data":[{"id":"jev-1.13","object":"model","created":1,"owned_by":"opencode"},{"id":"jev-1.13-free","object":"model","created":1,"owned_by":"opencode"},{"id":"jev-1.13-free-lookalike"},{"id":"JEV-1.13"}]}
;

/// Exercise the actual bounded parser, generation claim and persisted cache,
/// not a guessed disk DTO or an in-memory candidate injected after startup.
fn publishListing(home: []const u8, provider: cfg.providers.Id, body: []const u8, now: u64) !void {
    var store = try Store.openExisting(a, io, home);
    defer store.deinit();
    const mask = metadata.bit(provider);
    const claim = try metadata.claimAt(&store.root, mask, true, now, .{});
    const listing = try metadata.parseListing(a, body, provider);
    const result = try metadata.commitClaimedAt(&store.root, mask, listing, claim.generations, now + 1);
    try std.testing.expectEqual(mask, result.accepted);
}

fn expectNativeCandidate(session: *Session, name: []const u8) !void {
    for (session.connection().current().decision_models) |model| {
        if (!std.mem.eql(u8, model.name, name)) continue;
        try std.testing.expectEqual(@import("../core/protocol.zig").Protocol.systemone, model.protocol);
        try std.testing.expectEqual(@as(u32, 0), model.context_tokens);
        try std.testing.expect(model.output_tokens == null and model.reasoning == null);
        try std.testing.expect(model.input_price_threshold == null and model.input_price_flat_limit == null);
        return;
    }
    return error.ExpectedNativeCandidate;
}

test "Jev official refresh publishes native Decision candidates with only their own alias credentials" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, zen_fixture);
    try publishListing(home, .opencode_zen, zen_listing, 100);
    try publishListing(home, .opencode_go, zen_listing, 200);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("ZEN_OWN_KEY", "fake-zen-own-only");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const app = session.app.?;
    const primary_auth = app.client.authorization.ptr;
    const before = try declarationsWithoutDecision(session.global_config.?.value);
    defer a.free(before);
    try expectNativeCandidate(&session, "zen/jev-1.13");
    try expectNativeCandidate(&session, "zen/jev-1.13-free");
    const state = session.connection().current();
    for ([_][]const u8{ "zen/jev-1.13-free-lookalike", "zen/JEV-1.13", "zen-unlogged/jev-1.13-free", "go/jev-1.13-free" }) |name|
        try std.testing.expect(!contains(state.decision_models, name));
    try std.testing.expect(contains(state.decision_models, "lookalike/jev-1.13-free"));
    try std.testing.expectError(error.ApiKeyNotFound, choose(&session, "zen-unlogged/jev-1.13-free"));
    const connection = session.connection();
    try std.testing.expectError(error.SystemOneNotChatModel, connection.select_model_fn.?(connection.context, "zen/jev-1.13-free"));
    try std.testing.expect(app.decision_client == null);
    for ([_][]const u8{ "zen/jev-1.13-free", "zen/jev-1.13" }) |name| {
        const ref = try cfg.splitDefault(name);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const selected = try resolver.resolve(arena.allocator(), session.global_config.?.value, &session.metadata_cache, ref.provider, ref.model, false);
        try std.testing.expectEqualStrings(cfg.providers.systemone_base_url, selected.connection.base_url);
        try std.testing.expectEqualStrings("zen", selected.provider_name);
        try choose(&session, name);
        try std.testing.expectEqualStrings(name, session.connection().current().decision_model.?);
        try std.testing.expect(app.decision_client.?.native != null);
        try std.testing.expect(app.decision_client.?.resolved == null and app.decision_client.?.calls == 0);
        try std.testing.expectEqualStrings("fake-zen-own-only", app.decision_client.?.key.?);
        try std.testing.expect(app.client.authorization.ptr == primary_auth);
        try std.testing.expectEqualStrings("route", app.config.value.selected_provider.?);
        try std.testing.expectEqualStrings("first", app.config.value.model.name);
        try std.testing.expectEqualStrings("fake-main-only", app.config.value.provider.api_key.?);
    }
    try std.testing.expectError(error.UnknownModelProtocol, resolver.protocolFor(session.global_config.?.value, &session.metadata_cache, "go", "jev-1.13-free"));
    try std.testing.expectEqual(@import("../core/protocol.zig").Protocol.chat, try resolver.protocolFor(session.global_config.?.value, &session.metadata_cache, "lookalike", "jev-1.13-free"));
    const after = try declarationsWithoutDecision(session.global_config.?.value);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(usize, 0), session.global_config.?.value.registry.?.find("zen").?.models.len);
    // The protocol is derived, not forged into official wire evidence.
    const row = session.metadata_cache.directory.rows[session.metadata_cache.directory.find(.opencode_zen, "jev-1.13-free").?];
    try std.testing.expect(row.available == true and row.protocol == .auto and row.tokens == null);
}

test "Jev missing own key never borrows main Go or another official Zen alias key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, zen_fixture);
    try publishListing(home, .opencode_zen, zen_listing, 100);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("ZEN_MISSING_KEY", "fake-other-zen-only");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try expectNativeCandidate(&session, "zen-unlogged/jev-1.13-free");
    try std.testing.expect(!contains(session.connection().current().decision_models, "zen/jev-1.13-free"));
    const before = try disk(home);
    defer a.free(before);
    try std.testing.expectError(error.ApiKeyNotFound, choose(&session, "zen/jev-1.13-free"));
    try std.testing.expect(session.app.?.decision_client == null);
    const after = try disk(home);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "Jev documented protocol cannot create absent delisted or empty-list Decision availability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, zen_fixture);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("ZEN_OWN_KEY", "fake-zen-own-only");
    for ([_]?[]const u8{ null, zen_listing, "{\"data\":[{\"id\":\"jev-1.13\"}]}", "{\"data\":[]}" }, 0..) |listing, index| {
        if (listing) |body| try publishListing(home, .opencode_zen, body, 100 * index);
        var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
        defer session.deinit();
        const models = session.connection().current().decision_models;
        try std.testing.expectEqual(index == 1 or index == 2, contains(models, "zen/jev-1.13"));
        try std.testing.expectEqual(index == 1, contains(models, "zen/jev-1.13-free"));
        if (index != 1) {
            const before = try disk(home);
            defer a.free(before);
            try std.testing.expectError(error.UnknownDecisionModel, choose(&session, "zen/jev-1.13-free"));
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            try std.testing.expectError(error.DefaultModelUnavailable, resolver.resolve(arena.allocator(), session.global_config.?.value, &session.metadata_cache, "zen", "jev-1.13-free", false));
            const after = try disk(home);
            defer a.free(after);
            try std.testing.expectEqualStrings(before, after);
        }
    }
}

test "Decision generic selection is declaration-only independent and survives restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, fixture);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("OWN_REVIEW_KEY", "fake-aux-only");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const app = session.app.?;
    const auth = app.client.authorization.ptr;
    const session_id = app.client.session_id;
    const before = try declarationsWithoutDecision(session.global_config.?.value);
    defer a.free(before);
    try choose(&session, "other/family/judge");
    const selected = session.connection().current();
    try std.testing.expect(selected.decision_enabled);
    try std.testing.expectEqualStrings("other/family/judge", selected.decision_model.?);
    try std.testing.expectEqualStrings("first", app.config.value.model.name);
    try std.testing.expectEqualStrings("route", app.config.value.selected_provider.?);
    try std.testing.expect(app.client.authorization.ptr == auth);
    try std.testing.expectEqual(session_id, app.client.session_id);
    try std.testing.expect(app.client.config == &app.config.value and app.runtime.config == &app.config.value);
    const reviewer = app.decision_client.?;
    try std.testing.expect(reviewer.calls == 0 and reviewer.resolved == null and reviewer.native == null);
    try std.testing.expectEqualStrings("fake-aux-only", reviewer.key.?);
    const saved = try disk(home);
    defer a.free(saved);
    var parsed = try cfg.parse(a, saved);
    defer cfg.release(&parsed);
    try std.testing.expectEqualStrings("other/family/judge", parsed.value.decision.?.model);
    const after = try declarationsWithoutDecision(parsed.value);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    // The published picker is not authority after an env credential disappears.
    try std.testing.expect(contains(session.connection().current().decision_models, "other/family/judge"));
    try env.put("OWN_REVIEW_KEY", "");
    try std.testing.expectError(error.ApiKeyNotFound, choose(&session, "other/family/judge"));
    try std.testing.expect(app.decision_client.? == reviewer);
    const failed = try disk(home);
    defer a.free(failed);
    try std.testing.expectEqualStrings(saved, failed);
    try env.put("OWN_REVIEW_KEY", "fake-aux-only");
    var restarted = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer restarted.deinit();
    try std.testing.expectEqualStrings("other/family/judge", restarted.connection().current().decision_model.?);
    try std.testing.expectEqualStrings("first", restarted.app.?.config.value.model.name);
    try std.testing.expectEqual(@as(usize, 0), restarted.app.?.decision_client.?.calls);
}

test "Decision owner rejects nonmembers unlogged aliases and auto but routes by protocol" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, fixture);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const before = try disk(home);
    defer a.free(before);
    try std.testing.expectError(error.ApiKeyNotFound, choose(&session, "other/family/judge"));
    try env.put("OWN_REVIEW_KEY", "");
    try std.testing.expectError(error.ApiKeyNotFound, choose(&session, "other/family/judge"));
    try std.testing.expectError(error.UnknownDecisionModel, choose(&session, "route/unknown"));
    try std.testing.expectError(error.UnknownProvider, choose(&session, "Route/first"));
    try std.testing.expectError(error.UnknownDecisionModel, choose(&session, "route/FIRST"));
    try std.testing.expectError(error.UnknownDecisionModel, choose(&session, "route/auto"));
    // A Jev-looking raw ID is ordinary Chat unless its exact patch says otherwise.
    try std.testing.expect(contains(session.connection().current().decision_models, "native/jev-1.13-free"));
    const state = session.connection().current();
    try std.testing.expect(!contains(state.decision_models, "route/auto"));
    try std.testing.expect(contains(state.decision_models, "native/judge/raw"));
    try std.testing.expect(state.model_providers.len == 2); // route/native, never empty-env other.
    const after = try disk(home);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(!session.global_config.?.value.decisionActive());
    try std.testing.expect(session.app.?.decision_client == null);
}

test "SystemOne without context is auxiliary eligible but cannot become primary Chat" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, fixture);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try std.testing.expect(contains(session.connection().current().decision_models, "native/judge/raw"));
    const connection = session.connection();
    const before = try disk(home);
    defer a.free(before);
    try std.testing.expectError(error.SystemOneNotChatModel, connection.select_model_fn.?(connection.context, "native/judge/raw"));
    const after = try disk(home);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    try choose(&session, "native/judge/raw");
    try std.testing.expect(session.app.?.decision_client.?.native != null);
    try std.testing.expectEqualStrings("fake-native-only", session.app.?.decision_client.?.key.?);
    try std.testing.expectEqualStrings("native/judge/raw", session.connection().current().decision_model.?);
    try choose(&session, "route/judge/raw");
    try std.testing.expect(session.app.?.decision_client.?.native == null);
    try std.testing.expectEqualStrings("fake-main-only", session.app.?.decision_client.?.key.?);
    try choose(&session, "native/jev-1.13-free");
    try std.testing.expect(session.app.?.decision_client.?.native == null);
    try std.testing.expectEqualStrings("first", session.app.?.config.value.model.name);
}

test "Decision generic candidates use auxiliary caps even when primary candidate cannot fit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    // Declare the tiny model without a capacity; only the owned cache supplies
    // its 2048-token window. Manual declarations still obey the global 5000
    // safety margin, while a resolved auxiliary candidate uses its own 256.
    var declaration = try cfg.parse(a, fixture);
    defer cfg.release(&declaration);
    const owned = declaration.arena.allocator();
    const providers = try owned.dupe(cfg.NamedProvider, declaration.value.registry.?.providers);
    for (providers) |*provider| if (std.mem.eql(u8, provider.name, "route")) {
        provider.connection.base_url = "https://api.deepseek.com";
        const models = try owned.dupe(cfg.NamedModel, provider.models);
        for (models) |*model| if (std.mem.eql(u8, model.name, "tiny")) {
            model.patch.context_tokens = null;
        };
        provider.models = models;
    };
    declaration.value.registry.?.providers = providers;
    declaration.value.limits.safety_tokens = 5000;
    const bytes = try declarationsWithoutDecision(declaration.value);
    defer a.free(bytes);
    try seed(home, bytes);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const row = try session.metadata_cache.directory.upsert(.deepseek, "tiny");
    row.available = true;
    row.protocol = .chat;
    row.tokens = 2048;
    session.metadata_cache.directory_mask |= metadata.bit(.deepseek);
    // Explicit primary reselection rebuilds both snapshots from this cache;
    // it does not send inference or refresh metadata over the network.
    const connection = session.connection();
    try connection.select_model_fn.?(connection.context, "route/first");
    var primary_unavailable = false;
    for (session.connection().current().models) |model| {
        if (std.mem.eql(u8, model.name, "route/tiny")) primary_unavailable = model.context_tokens == 0;
    }
    try std.testing.expect(primary_unavailable);
    try std.testing.expect(contains(session.connection().current().decision_models, "route/tiny"));
    try choose(&session, "route/tiny");
    try std.testing.expectEqualStrings("route/tiny", session.app.?.decision_client.?.source.value.decision.?.model);
    try std.testing.expectEqual(@as(u32, 65536), session.app.?.config.value.model.context_tokens);
    try std.testing.expect(session.app.?.config.value.limits.low_price_input);
    // Unknown primary price does not exclude a reviewer; its limits are separate.
    const limits = session.global_config.?.value.decision.?.modelLimits(session.global_config.?.value.limits.request_timeout_ms);
    try std.testing.expect(!limits.low_price_input and limits.safety_tokens == 256);
}

test "Decision generic CAS failure and same-model key refresh keep primary frozen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, fixture);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try choose(&session, "route/second");
    const app = session.app.?;
    const previous = app.decision_client.?;
    const auth = app.client.authorization.ptr;
    const arena = app.config.arena;
    const global = session.global_config.?.arena;
    const saved = try disk(home);
    defer a.free(saved);
    try session.store.root.writeMode(cfg.file_name, "{}", true, 0o600);
    try std.testing.expectError(error.AuthVersionConflict, choose(&session, "route/first"));
    try std.testing.expect(app.decision_client.? == previous);
    try std.testing.expect(app.config.arena == arena and session.global_config.?.arena == global);
    try std.testing.expect(app.client.authorization.ptr == auth);
    try session.store.root.writeMode(cfg.file_name, saved, true, 0o600);
    var credentials = try cfg.clone(a, session.global_config.?.value);
    defer cfg.release(&credentials);
    try cfg.setRegistryCredential(credentials.arena.allocator(), &credentials.value, "route", "fake-rotated-aux");
    try session.store.save(credentials.value);
    std.mem.swap(std.json.Parsed(cfg.Config), &session.global_config.?, &credentials);
    try choose(&session, "route/second");
    try std.testing.expectEqualStrings("fake-rotated-aux", app.decision_client.?.key.?);
    try std.testing.expectEqualStrings("fake-main-only", app.config.value.provider.api_key.?);
    try std.testing.expect(app.client.authorization.ptr == auth);
    try std.testing.expectEqual(@as(usize, 0), app.decision_client.?.calls);
    app.runtime.poisoned = true;
    try std.testing.expectError(error.UnsafeToContinue, choose(&session, "route/first"));
    app.runtime.poisoned = false;
}

test "Decision generic pending selection never activates or changes the main model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var declaration = try cfg.parse(a, fixture);
    defer cfg.release(&declaration);
    const providers = try declaration.arena.allocator().dupe(cfg.NamedProvider, declaration.value.registry.?.providers);
    for (providers) |*provider| if (std.mem.eql(u8, provider.name, "route")) {
        provider.connection.api_key = null;
    };
    declaration.value.registry.?.providers = providers;
    declaration.value.provider.api_key = null;
    const bytes = try declarationsWithoutDecision(declaration.value);
    defer a.free(bytes);
    try seed(home, bytes);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("OWN_REVIEW_KEY", "fake-aux-only");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try choose(&session, "other/family/judge");
    try std.testing.expect(session.app == null);
    try std.testing.expectEqualStrings("first", session.pending.?.value.model.name);
    try std.testing.expectEqualStrings("route/first", session.global_config.?.value.registry.?.default);
    try std.testing.expectEqualStrings("other/family/judge", session.pending.?.value.decision.?.model);
    try std.testing.expect(session.pending.?.arena != session.global_config.?.arena);
}
