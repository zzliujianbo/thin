//! Owned fixtures for /settings backed only by the global config.json.
const profiles = @import("decision_selection.zig");

fn choose(session: *Session, choice: @import("../ui/tui.zig").Connection.DecisionChoice) !void {
    const connection = session.connection();
    try connection.decision_fn.?(connection.context, choice);
}

test "Decision declared native model roundtrip CAS and primary identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, native_declared, null);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const initial = try read(home, cfg.file_name);
    defer a.free(initial);
    try choose(&session, .off);
    const unchanged = try read(home, cfg.file_name);
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(initial, unchanged);
    const app = session.app.?;
    const auth = app.client.authorization.ptr;
    const arena = app.config.arena;
    const global = session.global_config.?.arena;
    const history = app.runtime.messages().len;
    try session.store.root.writeMode(cfg.file_name, "{}", true, 0o600);
    try std.testing.expectError(error.AuthVersionConflict, choose(&session, .{ .model = "reviewer/arbitrary/raw" }));
    try std.testing.expect(app.config.arena == arena and session.global_config.?.arena == global);
    try std.testing.expect(app.decision_client == null and app.config.value.registry.?.providers.len == 2);
    try std.testing.expectEqual(history, app.runtime.messages().len);
    try session.store.root.writeMode(cfg.file_name, initial, true, 0o600);
    try choose(&session, .{ .model = "reviewer/arbitrary/raw" });
    try std.testing.expectEqualStrings("reviewer/arbitrary/raw", session.connection().current().decision_model.?);
    try std.testing.expect(app.client.authorization.ptr == auth);
    try std.testing.expect(app.client.config == &app.config.value and app.runtime.config == &app.config.value);
    const judge = app.decision_client.?;
    try std.testing.expect(judge.calls == 0 and judge.native != null and judge.resolved == null);
    try std.testing.expectEqualStrings("fake-native-own-key", judge.key.?);
    const provider = app.config.value.registry.?.find("reviewer").?;
    try std.testing.expect(provider.patchFor("arbitrary/raw").?.protocol == .systemone);
    try std.testing.expect(provider.models.len == 1 and provider.connection.kind == null);
    const saved = try read(home, cfg.file_name);
    defer a.free(saved);
    var parsed = try cfg.parse(a, saved);
    defer cfg.release(&parsed);
    try std.testing.expect(parsed.value.decisionActive());
    try std.testing.expectEqualStrings("route/first", parsed.value.registry.?.default);
    try std.testing.expectEqualStrings("fake-owned-only", parsed.value.registry.?.find("route").?.connection.api_key.?);
    var restarted = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer restarted.deinit();
    try std.testing.expectEqualStrings("reviewer/arbitrary/raw", restarted.connection().current().decision_model.?);
    try std.testing.expectEqualStrings("fake-native-own-key", restarted.app.?.decision_client.?.key.?);
    // Explicit reselection loads only the independent reviewer's latest key.
    var credentials = try cfg.clone(a, session.global_config.?.value);
    defer cfg.release(&credentials);
    try cfg.setRegistryCredential(credentials.arena.allocator(), &credentials.value, "reviewer", "fake-native-rotated");
    try session.store.save(credentials.value);
    std.mem.swap(std.json.Parsed(cfg.Config), &session.global_config.?, &credentials);
    try toggle(&session, .low_price_input, false);
    try std.testing.expect(app.decision_client.? == judge);
    try std.testing.expectEqualStrings("fake-native-own-key", judge.key.?);
    try choose(&session, .{ .model = "reviewer/arbitrary/raw" });
    try std.testing.expectEqualStrings("fake-native-rotated", app.decision_client.?.key.?);
    try std.testing.expect(app.decision_client.?.calls == 0 and app.client.authorization.ptr == auth);
    app.decision_client.?.native.?.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, choose(&session, .{ .model = "reviewer/arbitrary/raw" }));
    try std.testing.expectError(error.CleanupFailed, toggle(&session, .low_price_input, true));
    app.decision_client.?.native.?.poisoned = false;
    try choose(&session, .off);
    try std.testing.expect(!session.connection().current().decision_enabled and app.decision_client == null);
}

test "Decision pending selection owns active and declaration after save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var declaration = try cfg.parse(a, native_declared);
    defer cfg.release(&declaration);
    try cfg.setRegistryCredential(declaration.arena.allocator(), &declaration.value, "route", "fake-unused");
    // Remove the primary key without ever consulting a real HOME.
    const providers = try declaration.arena.allocator().dupe(cfg.NamedProvider, declaration.value.registry.?.providers);
    providers[0].connection.api_key = null;
    declaration.value.registry.?.providers = providers;
    declaration.value.provider.api_key = null;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(declaration.value, &out.writer);
    try seed(home, out.written(), null);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try choose(&session, .{ .model = "reviewer/arbitrary/raw" });
    try std.testing.expect(session.app == null and session.pending.?.value.decisionActive());
    try std.testing.expect(session.pending.?.arena != session.global_config.?.arena);
    try std.testing.expectEqualStrings("first", session.pending.?.value.model.name);
    try choose(&session, .off);
    try std.testing.expect(!session.pending.?.value.decisionActive());
    try std.testing.expectEqualStrings("first", session.pending_base_model.?.name);
}

test "Decision pure editing preserves exact declared provider identity without synthesis" {
    var parsed = try cfg.parse(a, native_declared);
    defer cfg.release(&parsed);
    const arena = parsed.arena.allocator();
    const providers = parsed.value.registry.?.providers;
    try std.testing.expect(try profiles.apply(arena, &parsed.value, .{ .model = "reviewer/arbitrary/raw" }));
    try std.testing.expectEqualStrings("reviewer/arbitrary/raw", parsed.value.decision.?.model);
    try std.testing.expect(parsed.value.registry.?.providers.ptr == providers.ptr);
    try std.testing.expectEqual(@as(usize, 2), providers.len);
    try std.testing.expectError(error.UnknownProvider, profiles.apply(arena, &parsed.value, .{ .model = "Reviewer/arbitrary/raw" }));
    try std.testing.expectEqualStrings("reviewer/arbitrary/raw", parsed.value.decision.?.model);
    try std.testing.expect(try profiles.apply(arena, &parsed.value, .off));
    try std.testing.expect(!parsed.value.decisionActive());
    try std.testing.expectEqualStrings("reviewer/arbitrary/raw", parsed.value.decision.?.model);
}

const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const Session = @import("session.zig").Session;
const App = @import("app.zig").App;
const Store = @import("auth_store.zig").Store;
const a = std.testing.allocator;
const io = std.testing.io;
const plain =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-owned-only","models":{"first":{"protocol":"chat","context_tokens":65536},"second":{"protocol":"chat","context_tokens":131072}}}}}}
;
const native_declared =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-owned-only","models":{"first":{"protocol":"chat","context_tokens":65536}}},"reviewer":{"base_url":"https://opencode.ai/inference/systemone/v1","api_key":"fake-native-own-key","models":{"arbitrary/raw":{"protocol":"systemone"}}}}}}
;
const reviewed =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-owned-only","models":{"first":{"protocol":"anthropic","context_tokens":65536},"judge":{"protocol":"chat","context_tokens":32768}}}}},"decision":{"model":"route/judge"}}
;
fn seed(home: []const u8, config: []const u8, legacy: ?[]const u8) !void {
    var store = try Store.open(a, io, home);
    defer store.deinit();
    try store.root.writeMode(cfg.file_name, config, false, 0o600);
    if (legacy) |bytes| try store.root.writeMode("settings.json", bytes, false, 0o600);
}
fn read(home: []const u8, name: []const u8) ![]const u8 {
    var store = try Store.openExisting(a, io, home);
    defer store.deinit();
    return (try store.root.read(a, name, 0, cfg.max_config_bytes)).data;
}
fn toggle(session: *Session, setting: @import("../ui/tui.zig").Connection.Setting, enabled: bool) !void {
    const connection = session.connection();
    try connection.setting_fn.?(connection.context, setting, enabled);
}

test "global config switches survive selection restart and headless without a settings source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const legacy = "{\"low_price_input\":false}";
    try seed(home, plain, legacy);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    {
        var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
        defer session.deinit();
        // The retired settings file is ignored, even if it disagrees.
        try std.testing.expect(session.connection().current().low_price_input_enabled);
        try toggle(&session, .low_price_input, false);
        try std.testing.expect(!session.connection().current().low_price_input_enabled);
        try std.testing.expect(!session.global_config.?.value.limits.low_price_input);
        const connection = session.connection();
        try connection.select_model_fn.?(connection.context, "route/second");
        try std.testing.expect(!session.app.?.config.value.limits.low_price_input);
        const disk = try read(home, cfg.file_name);
        defer a.free(disk);
        var parsed = try cfg.parse(a, disk);
        defer cfg.release(&parsed);
        try std.testing.expect(!parsed.value.limits.low_price_input);
        try std.testing.expectEqualStrings("route/second", parsed.value.registry.?.default);
        try std.testing.expectEqualStrings("fake-owned-only", parsed.value.registry.?.find("route").?.connection.api_key.?);
        try std.testing.expectEqual(@as(?u32, 65536), parsed.value.registry.?.find("route").?.patchFor("first").?.context_tokens);
        try std.testing.expectError(error.DecisionNotConfigured, toggle(&session, .decision_enabled, true));
        const same = try read(home, cfg.file_name);
        defer a.free(same);
        try std.testing.expectEqualStrings(disk, same);
        const old = try read(home, "settings.json");
        defer a.free(old);
        try std.testing.expectEqualStrings(legacy, old);
    }
    var restarted = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer restarted.deinit();
    try std.testing.expect(!restarted.connection().current().low_price_input_enabled);
    const headless = try App.init(a, io, &env, home, .{});
    defer headless.deinit();
    try std.testing.expect(!headless.config.value.limits.low_price_input);
    try std.testing.expectEqualStrings("second", headless.config.value.model.name);
}

test "config CAS save failure is atomic and decision toggles normalize Anthropic prefix without any call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, reviewed, null);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const app = session.app.?;
    const client = app.decision_client.?;
    const schemas = app.runtime.executor.schemas;
    const allocator = app.runtime.arena.allocator();
    const messages = [_]p.Message{
        .{ .role = .user, .blocks = &.{.{ .text = "fixture goal" }} },
        .{ .role = .assistant, .blocks = &.{ .{ .reasoning = "prefix-bound fixture" }, .{ .tool_call = .{ .id = "keep-id", .name = "read_file", .arguments = "{\"path\":\"fixture\"}" } } }, .replay = .{ .scope = .{ .connection = app.config.value.provider.base_url, .model = app.config.value.model.name, .protocol = .anthropic }, .json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"prefix-bound fixture\",\"signature\":\"c2ln\"},{\"type\":\"tool_use\",\"id\":\"keep-id\",\"name\":\"read_file\",\"input\":{\"path\":\"fixture\"}}]}" } },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "keep-id", .text = "completed fixture" } }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "finished fixture" }} },
    };
    for (messages) |message| try app.runtime.history.append(allocator, try p.cloneMessage(allocator, message));
    app.runtime.last_context_tokens = 1234;
    const history = app.runtime.history.items.ptr;
    const system = app.runtime.system.ptr;
    const estimator = app.runtime.estimator;
    try session.store.root.writeMode(cfg.file_name, "{}", true, 0o600);
    try std.testing.expectError(error.AuthVersionConflict, toggle(&session, .decision_enabled, false));
    try std.testing.expect(app.decision_client.? == client and app.config.value.decisionActive());
    try std.testing.expect(session.global_config.?.value.decisionActive());
    try std.testing.expect(app.runtime.history.items.ptr == history and app.runtime.history.items[1].replay != null);
    try std.testing.expectEqual(@as(?u64, 1234), app.runtime.last_context_tokens);
    // Restore exactly the original CAS baseline, not a reset of the store.
    try session.store.root.writeMode(cfg.file_name, reviewed, true, 0o600);
    try toggle(&session, .decision_enabled, false);
    try std.testing.expect(app.decision_client == null and app.runtime.decision_service == null);
    try std.testing.expect(!session.connection().current().decision_enabled);
    try std.testing.expect(!session.global_config.?.value.decision.?.enabled);
    try std.testing.expect(app.runtime.system.ptr == system);
    try std.testing.expectEqualDeep(estimator, app.runtime.estimator);
    try std.testing.expectEqual(@as(usize, 4), app.runtime.history.items.len);
    try std.testing.expect(app.runtime.history.items[1].replay == null);
    try std.testing.expectEqual(@as(usize, 1), app.runtime.history.items[1].blocks.len);
    try std.testing.expectEqualStrings("keep-id", app.runtime.history.items[1].blocks[0].tool_call.id);
    try std.testing.expectEqualStrings("completed fixture", app.runtime.history.items[2].blocks[0].tool_result.text);
    try std.testing.expect(session.connection().current().initial_context.?.known);
    try std.testing.expectEqual(@as(u64, 1234), session.connection().current().initial_context.?.tokens);
    var description_changed = false;
    for (schemas, app.runtime.executor.schemas) |old, next| {
        try std.testing.expectEqualStrings(old.name, next.name);
        try std.testing.expectEqualStrings(old.parameters_json, next.parameters_json);
        description_changed = description_changed or !std.mem.eql(u8, old.description, next.description);
    }
    try std.testing.expect(description_changed);
    {
        const headless = try App.init(a, io, &env, home, .{});
        defer headless.deinit();
        try std.testing.expect(headless.config.value.decision != null and !headless.config.value.decision.?.enabled);
        try std.testing.expect(headless.decision_client == null and headless.runtime.decision_service == null);
    }
    try toggle(&session, .decision_enabled, true);
    try std.testing.expect(app.runtime.decision_service != null and app.decision_client != null);
    try std.testing.expectEqual(@as(u64, 0), app.decision_client.?.calls);
    for (schemas, app.runtime.executor.schemas) |old, next| try std.testing.expectEqualStrings(old.description, next.description);
    try std.testing.expectError(error.FileNotFound, session.store.root.dir.statFile(io, "settings.json", .{}));
}

test "history restore adopts current config switches rather than archived budget or tool prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, reviewed, null);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var id: @import("session_id.zig").Id = undefined;
    {
        var source = try Session.initWithOptions(a, io, &env, home, .{}, .{});
        defer source.deinit();
        id = source.session_id;
        const app = source.app.?;
        const allocator = app.runtime.arena.allocator();
        try app.runtime.history.append(allocator, try p.cloneMessage(allocator, .{ .role = .user, .blocks = &.{.{ .text = "owned goal" }} }));
        try app.runtime.history.append(allocator, try p.cloneMessage(allocator, .{
            .role = .assistant,
            .blocks = &.{ .{ .reasoning = "old prefix" }, .{ .text = "owned answer" } },
            .replay = .{ .scope = .{ .connection = app.config.value.provider.base_url, .model = "first", .protocol = .anthropic }, .json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"old prefix\",\"signature\":\"c2ln\"},{\"type\":\"text\",\"text\":\"owned answer\"}]}" },
        }));
        try std.testing.expect(try source.saveOnExit());
    }
    {
        var store = try Store.openExisting(a, io, home);
        defer store.deinit();
        var declaration = try store.loadExisting();
        defer cfg.release(&declaration);
        declaration.value.limits.low_price_input = false;
        declaration.value.decision.?.enabled = false;
        try store.save(declaration.value);
    }
    var restored = try Session.initWithOptions(a, io, &env, home, .{}, .{ .resume_session = id, .logging = false });
    defer restored.deinit();
    const state = restored.connection().current();
    try std.testing.expect(!state.low_price_input_enabled and !state.decision_enabled);
    try std.testing.expect(restored.app.?.runtime.decision_service == null);
    const history = restored.app.?.runtime.messages();
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expect(history[1].replay == null);
    try std.testing.expectEqual(@as(usize, 1), history[1].blocks.len);
    try std.testing.expectEqualStrings("owned answer", history[1].blocks[0].text);
    try std.testing.expect(!state.initial_context.?.known);
}

test "settings auxiliary credentials follow login addition rotation and failed save without rebinding primary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home,
        \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key_env":"PRIMARY_FIXTURE_KEY","models":{"first":{"protocol":"chat","context_tokens":65536},"judge":{"protocol":"chat","context_tokens":32768}}}}},"decision":{"model":"route/judge","enabled":false}}
    , null);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("PRIMARY_FIXTURE_KEY", "fake-frozen-primary");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const app = session.app.?;
    const primary_config = app.config.arena;
    const primary_auth = app.client.authorization.ptr;
    const snapshot = app.runtime.contextSnapshot();
    const estimator = app.runtime.estimator;
    try std.testing.expect(app.decision_client == null);
    try std.testing.expect(session.global_config.?.value.registry.?.find("route").?.connection.api_key == null);
    const connection = session.connection();
    // /login adds an inline credential; the active primary keeps its env key.
    try connection.configure_fn(connection.context, "fake-added-login-key");
    const saved = try read(home, cfg.file_name);
    defer a.free(saved);
    try session.store.root.writeMode(cfg.file_name, "{}", true, 0o600);
    try std.testing.expectError(error.AuthVersionConflict, toggle(&session, .decision_enabled, true));
    try std.testing.expect(app.decision_client == null and app.runtime.decision_service == null);
    try std.testing.expect(!app.config.value.decisionActive() and !session.global_config.?.value.decisionActive());
    try std.testing.expectEqualDeep(snapshot, app.runtime.contextSnapshot());
    try std.testing.expect(app.config.arena == primary_config and app.client.authorization.ptr == primary_auth);
    try session.store.root.writeMode(cfg.file_name, saved, true, 0o600);
    try toggle(&session, .decision_enabled, true);
    const first = app.decision_client.?;
    try std.testing.expectEqualStrings("fake-added-login-key", first.key.?);
    const global_key = session.global_config.?.value.registry.?.find("route").?.connection.api_key.?;
    const owned_key = first.source.value.registry.?.find("route").?.connection.api_key.?;
    try std.testing.expectEqualStrings(global_key, owned_key);
    try std.testing.expect(global_key.ptr != owned_key.ptr and first.key.?.ptr != global_key.ptr);
    try std.testing.expect(first.calls == 0 and first.resolved == null);
    // Login releases the previous global arena. The enabled client owns its old
    // source until the next explicit disable/enable rebuilds it from global.
    try connection.configure_fn(connection.context, "fake-rotated-login-key");
    try std.testing.expectEqualStrings("fake-added-login-key", first.key.?);
    try std.testing.expectEqualStrings("fake-added-login-key", first.source.value.registry.?.find("route").?.connection.api_key.?);
    try toggle(&session, .decision_enabled, false);
    try toggle(&session, .decision_enabled, true);
    const rotated = app.decision_client.?;
    try std.testing.expectEqualStrings("fake-rotated-login-key", rotated.key.?);
    try std.testing.expectEqualStrings("fake-rotated-login-key", rotated.source.value.registry.?.find("route").?.connection.api_key.?);
    try std.testing.expect(rotated.calls == 0 and rotated.resolved == null);
    try std.testing.expect(app.client.authorization.ptr == primary_auth);
    try std.testing.expect(app.client.config == &app.config.value and app.runtime.config == &app.config.value);
    try std.testing.expect(app.executor.config == &app.config.value);
    try std.testing.expectEqualStrings("Bearer fake-frozen-primary", app.client.authorization);
    try std.testing.expectEqualStrings("PRIMARY_FIXTURE_KEY", app.config.value.provider.api_key_env);
    try std.testing.expect(app.config.value.provider.api_key == null);
    // Tool schema changes do not rewrite the latest server observation (or
    // fresh-session zero). Failed saves and successful edits both retain it.
    try std.testing.expectEqualDeep(snapshot, app.runtime.contextSnapshot());
    try std.testing.expectEqualDeep(estimator, app.runtime.estimator);
    const disk = try read(home, cfg.file_name);
    defer a.free(disk);
    var parsed = try cfg.parse(a, disk);
    defer cfg.release(&parsed);
    try std.testing.expect(parsed.value.decisionActive());
    try std.testing.expectEqualStrings("fake-rotated-login-key", parsed.value.registry.?.find("route").?.connection.api_key.?);
    try std.testing.expectEqualStrings("route/first", parsed.value.registry.?.default);
}

test "settings prepare owns latest declaration and extends redaction without publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, reviewed, null);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try toggle(&session, .decision_enabled, false);
    const app = session.app.?;
    const config_arena = app.config.arena;
    const schema = app.runtime.executor.schemas.ptr;
    const disk = try read(home, cfg.file_name);
    defer a.free(disk);
    var declaration = try cfg.clone(a, session.global_config.?.value);
    var released = false;
    defer if (!released) cfg.release(&declaration);
    try cfg.setRegistryCredential(declaration.arena.allocator(), &declaration.value, "route", "fake-prepare-only-key");
    declaration.value.decision.?.enabled = true;
    var prepared = try app.prepareSettings(declaration.value, &env);
    defer prepared.deinit();
    cfg.release(&declaration);
    released = true;
    try std.testing.expectEqualStrings("fake-prepare-only-key", prepared.decision.?.key.?);
    try std.testing.expectEqualStrings("fake-prepare-only-key", prepared.decision.?.source.value.registry.?.find("route").?.connection.api_key.?);
    var remembered = false;
    for (app.journal.known_keys[0..app.journal.known_key_count]) |key|
        remembered = remembered or std.mem.eql(u8, key, "fake-prepare-only-key");
    try std.testing.expect(remembered);
    try std.testing.expect(app.config.arena == config_arena and app.runtime.executor.schemas.ptr == schema);
    try std.testing.expect(app.decision_client == null and app.runtime.decision_service == null and !app.config.value.decisionActive());
    try std.testing.expect(prepared.decision.?.calls == 0);
    const unchanged = try read(home, cfg.file_name);
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(disk, unchanged);
}

test "obsolete settings file is ignored and preserved even when malformed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const bad = "{\"decision_enabled\":\"bad\"}";
    try seed(home, reviewed, bad);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const state = session.connection().current();
    try std.testing.expect(state.global_settings_available and state.decision_enabled and state.low_price_input_enabled);
    try std.testing.expect(session.app.?.decision_client != null);
    try toggle(&session, .decision_enabled, false);
    const bytes = try read(home, "settings.json");
    defer a.free(bytes);
    try std.testing.expectEqualStrings(bad, bytes);
    const headless = try App.init(a, io, &env, home, .{});
    defer headless.deinit();
    try std.testing.expect(!headless.config.value.decisionActive());
}
