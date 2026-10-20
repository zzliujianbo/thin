//! Generic Decision selection: owned local fixtures, no inference or metadata fetch.
const std = @import("std");
const cfg = @import("../core/config.zig");
const Session = @import("session.zig").Session;
const Store = @import("auth_store.zig").Store;
const profiles = @import("decision_selection.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const fixture =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-main-only","models":{"first":{"protocol":"chat","context_tokens":65536},"second":{"protocol":"chat","context_tokens":131072},"tiny":{"protocol":"chat","context_tokens":2048},"auto":{"protocol":"auto","context_tokens":32768}}},"other":{"base_url":"https://other.invalid/v1","api_key_env":"OWN_REVIEW_KEY","models":{"family/judge":{"protocol":"chat","context_tokens":16384}}},"native":{"base_url":"https://opencode.ai/inference/systemone/v1","api_key":"fake-native-only","models":{"jev-1.13-free":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"safety_tokens":100}}
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
    try std.testing.expect(selected.decision_enabled and !selected.decision_jev_free);
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
    try std.testing.expect(parsed.value.decision.?.backend == .model);
    const after = try declarationsWithoutDecision(parsed.value);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    var restarted = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer restarted.deinit();
    try std.testing.expectEqualStrings("other/family/judge", restarted.connection().current().decision_model.?);
    try std.testing.expectEqualStrings("first", restarted.app.?.config.value.model.name);
    try std.testing.expectEqual(@as(usize, 0), restarted.app.?.decision_client.?.calls);
}

test "Decision generic owner rejects nonmembers unlogged aliases native routes and auto" {
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
    try std.testing.expectError(error.UnknownDecisionModel, choose(&session, "native/jev-1.13-free"));
    const state = session.connection().current();
    try std.testing.expect(!contains(state.decision_models, "route/auto"));
    try std.testing.expect(!contains(state.decision_models, "native/jev-1.13-free"));
    try std.testing.expect(state.model_providers.?.len == 2); // route/native, never empty-env other.
    const after = try disk(home);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(!session.global_config.?.value.decisionActive());
    try std.testing.expect(session.app.?.decision_client == null);
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
    const metadata = @import("model_metadata.zig");
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
    const limits = session.global_config.?.value.decision.?.modelLimits();
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
