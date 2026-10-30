//! Offline preference ownership/atomicity fixtures. Never use the real HOME.
const std = @import("std");
const cfg = @import("../core/config.zig");
const preference = @import("../core/settings.zig");
const profiles = @import("decision_selection.zig");
const Session = @import("session.zig").Session;
const Store = @import("auth_store.zig").Store;
const p = @import("../core/protocol.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const plain =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-owned-only","models":{"first":{"protocol":"chat","context_tokens":65536},"judge":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
;
const reviewed = plain[0 .. plain.len - 1] ++ ",\"decision\":{\"model\":\"route/judge\"}}";
const Edit = struct { key: preference.Key, value: ?u32 };
const main_edits = [_]Edit{
    .{ .key = .memory_auto, .value = 0 },
    .{ .key = .compaction_enabled, .value = 0 },
    .{ .key = .command_timeout_ms, .value = 10000 },
    .{ .key = .request_timeout_ms, .value = 20000 },
    .{ .key = .task_timeout_ms, .value = 40000 },
};
fn set(session: *Session, key: preference.Key, value: ?u32) !void {
    const c = session.connection();
    try c.preference_fn.?(c.context, key, value);
}
fn disk(session: *Session) ![]const u8 {
    return (try session.store.root.read(a, cfg.file_name, 0, cfg.max_config_bytes)).data;
}
fn seed(home: []const u8, bytes: []const u8) !void {
    var store = try Store.open(a, io, home);
    defer store.deinit();
    try store.root.writeMode(cfg.file_name, bytes, false, 0o600);
}

test "memory settings current publishes active pending and global defaults without network" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    // Missing configuration initializes owned defaults, without activating App.
    var pending = try Session.initWithOptions(a, io, &env, home, .{}, .{ .auto_refresh_models = false });
    defer pending.deinit();
    const connection = pending.connection();
    try std.testing.expect(pending.app == null);
    try std.testing.expect(connection.current().memory_auto);
    try std.testing.expect(!connection.current().memory.enabled);
    try std.testing.expect(!connection.poll_models_fn.?(connection.context, false));
    try set(&pending, .memory_auto, 0);
    try std.testing.expect(!pending.pending.?.value.memory.auto);
    try std.testing.expect(!pending.global_config.?.value.memory.auto);
    // Pending presentation must not silently borrow a different global value.
    pending.global_config.?.value.memory.auto = true;
    try std.testing.expect(!connection.current().memory_auto);
    pending.global_config.?.value.memory.auto = false;
    try set(&pending, .memory_auto, 1);
    const bytes = try disk(&pending);
    defer a.free(bytes);
    var tree = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer tree.deinit();
    try std.testing.expect(!tree.value.object.contains("memory"));

    try pending.store.root.writeMode(cfg.file_name, plain, true, 0o600);
    var active = try Session.initWithOptions(a, io, &env, home, .{}, .{ .auto_refresh_models = false });
    defer active.deinit();
    const app = active.app.?;
    try std.testing.expect(active.connection().current().memory_auto);
    try set(&active, .memory_auto, 0);
    active.global_config.?.value.memory.auto = true;
    try std.testing.expect(!active.connection().current().memory_auto);
    active.global_config.?.value.memory.auto = false;
    try std.testing.expect(!active.connection().current().memory.enabled);
    try set(&active, .memory_auto, 1);
    try std.testing.expect(std.meta.eql(app.memoryView(), active.connection().current().memory));
    try std.testing.expect(active.metadata_job == null and pending.metadata_job == null);
}

test "preferences pure edits enforce shared validation without partial mutation" {
    var parsed = try cfg.parse(a, reviewed);
    defer cfg.release(&parsed);
    for (main_edits) |edit| try preference.apply(&parsed.value, edit.key, edit.value);
    try preference.apply(&parsed.value, .request_timeout_ms, 86400000);
    try preference.apply(&parsed.value, .task_timeout_ms, 86400000);
    const invalid = [_]Edit{
        .{ .key = .memory_auto, .value = null },
        .{ .key = .memory_auto, .value = 2 },
        .{ .key = .compaction_enabled, .value = null },
        .{ .key = .compaction_enabled, .value = 2 },
        .{ .key = .command_timeout_ms, .value = null },
        .{ .key = .command_timeout_ms, .value = 0 },
        .{ .key = .command_timeout_ms, .value = 3600001 },
        .{ .key = .request_timeout_ms, .value = null },
        .{ .key = .request_timeout_ms, .value = 0 },
        .{ .key = .request_timeout_ms, .value = 86400001 },
        .{ .key = .task_timeout_ms, .value = null },
        .{ .key = .task_timeout_ms, .value = 0 },
        .{ .key = .task_timeout_ms, .value = 86400001 },
    };
    for (invalid) |edit| {
        const before = parsed.value;
        if (preference.apply(&parsed.value, edit.key, edit.value)) |_| return error.ExpectedInvalidPreference else |_| {}
        try std.testing.expectEqualDeep(before, parsed.value);
    }
    parsed.value.decision = null;
    try preference.apply(&parsed.value, .request_timeout_ms, 500);
    try std.testing.expectEqual(@as(u32, 500), parsed.value.limits.request_timeout_ms);
    try std.testing.expect(parsed.value.decision == null);
}

test "preferences active clone preserves unrelated frozen limits and rejects invalid active budget" {
    var declaration = try cfg.parse(a, plain);
    defer cfg.release(&declaration);
    var active = declaration.value;
    active.limits.max_input_tokens = 12000;
    active.limits.input_margin_tokens = 777;
    active.limits.command_max_timeout_ms = 20000;
    try preference.apply(&declaration.value, .command_timeout_ms, 30000);
    try std.testing.expectError(error.InvalidLimit, profiles.activeClone(a, active, declaration.value));
    try preference.apply(&declaration.value, .command_timeout_ms, 10000);
    // A valid timeout edit must still reject invalid frozen input constraints.
    active.limits.max_input_tokens = active.limits.input_margin_tokens;
    try preference.apply(&declaration.value, .request_timeout_ms, 12345);
    try std.testing.expectError(error.InvalidBudget, profiles.activeClone(a, active, declaration.value));
    active.limits.max_input_tokens = 12000;
    var candidate = try profiles.activeClone(a, active, declaration.value);
    defer cfg.release(&candidate);
    try std.testing.expectEqual(@as(?u32, 12000), candidate.value.limits.max_input_tokens);
    try std.testing.expectEqual(@as(u32, 777), candidate.value.limits.input_margin_tokens);
    try std.testing.expectEqual(@as(u32, 20000), candidate.value.limits.command_max_timeout_ms);
    try std.testing.expectEqual(@as(u32, 12345), candidate.value.limits.request_timeout_ms);
    try std.testing.expect(candidate.value.memory.auto);
    try preference.apply(&declaration.value, .memory_auto, 0);
    var memory_candidate = try profiles.activeClone(a, active, declaration.value);
    defer cfg.release(&memory_candidate);
    try std.testing.expect(!memory_candidate.value.memory.auto);
    try std.testing.expectEqualDeep(active.provider, memory_candidate.value.provider);
    try std.testing.expectEqualDeep(active.model, memory_candidate.value.model);
}

test "preferences preserve frozen primary while only shared request timeout refreshes auxiliary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, reviewed);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    const app = session.app.?;
    const primary = &app.client;
    const auth = app.client.authorization.ptr;
    const id = session.session_id;
    const client_session = app.client.session_id;
    var frozen = try cfg.clone(a, app.config.value);
    defer cfg.release(&frozen);
    const aux = app.decision_client.?;
    // Nonzero offline statistics prove settings do not reset the old reviewer.
    aux.calls = 7;
    aux.last_usage = .{ .input_tokens = 123, .output_tokens = 45 };
    const aux_usage = aux.last_usage;
    const allocator = app.runtime.arena.allocator();
    try app.runtime.history.append(allocator, try p.cloneMessage(allocator, .{ .role = .user, .blocks = &.{.{ .text = "owned history" }} }));
    const history = app.runtime.history.items.ptr;
    app.runtime.last_context_tokens = 1234;
    const estimator = app.runtime.estimator;
    for (main_edits) |edit| {
        // Shared request timeout alone rebuilds the independent reviewer below.
        if (edit.key == .request_timeout_ms) continue;
        try set(&session, edit.key, edit.value);
        try std.testing.expect(&app.client == primary and app.client.authorization.ptr == auth);
        try std.testing.expect(app.decision_client.? == aux and aux.calls == 7);
        try std.testing.expectEqualDeep(aux_usage, aux.last_usage);
        try std.testing.expectEqualDeep(client_session, app.client.session_id);
        try std.testing.expectEqualDeep(frozen.value.provider, app.config.value.provider);
        try std.testing.expectEqualDeep(frozen.value.model, app.config.value.model);
        try std.testing.expectEqualDeep(frozen.value.proxy, app.config.value.proxy);
        try std.testing.expect(app.runtime.history.items.ptr == history);
        try std.testing.expectEqual(@as(?u64, 1234), app.runtime.last_context_tokens);
        try std.testing.expectEqualDeep(estimator, app.runtime.estimator);
        try std.testing.expectEqualDeep(id, session.session_id);
        try std.testing.expectEqualDeep(session.global_config.?.value.limits, session.connection().current().limits);
        try std.testing.expectEqual(session.global_config.?.value.memory.auto, session.connection().current().memory_auto);
    }
    const saved = try disk(&session);
    defer a.free(saved);
    const active_arena = app.config.arena;
    try session.store.root.writeMode(cfg.file_name, "{}", true, 0o600);
    try std.testing.expectError(error.AuthVersionConflict, set(&session, .memory_auto, 1));
    try std.testing.expect(!app.config.value.memory.auto and !session.global_config.?.value.memory.auto);
    try std.testing.expect(!session.connection().current().memory_auto);
    try std.testing.expectError(error.AuthVersionConflict, set(&session, .request_timeout_ms, 45678));
    try std.testing.expect(app.config.arena == active_arena and app.decision_client.? == aux);
    try std.testing.expectEqualDeep(aux_usage, aux.last_usage);
    try std.testing.expectEqual(frozen.value.limits.request_timeout_ms, session.connection().current().limits.request_timeout_ms);
    try session.store.root.writeMode(cfg.file_name, saved, true, 0o600);
    try set(&session, .request_timeout_ms, 45678);
    try std.testing.expect(app.decision_client.? != aux);
    try std.testing.expect(app.decision_client.?.calls == 0);
    try std.testing.expect(&app.client == primary and app.client.authorization.ptr == auth);
    try std.testing.expectEqual(@as(u32, 45678), session.connection().current().limits.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 45678), app.decision_client.?.source.value.limits.request_timeout_ms);
    const connection = session.connection();
    try connection.decision_fn.?(connection.context, .off);
    try set(&session, .request_timeout_ms, 56789);
    try std.testing.expect(app.decision_client == null and !session.connection().current().decision_enabled);
    try std.testing.expectEqual(@as(u32, 56789), session.connection().current().limits.request_timeout_ms);
    var restarted = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer restarted.deinit();
    try std.testing.expectEqualDeep(app.config.value.limits, restarted.app.?.config.value.limits);
    try std.testing.expectEqual(@as(u32, 56789), restarted.connection().current().limits.request_timeout_ms);
}

test "shared request timeout saves without a decision declaration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, plain);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    const auth = session.app.?.client.authorization.ptr;
    try set(&session, .request_timeout_ms, 54321);
    try std.testing.expect(session.app.?.decision_client == null);
    try std.testing.expect(session.global_config.?.value.decision == null);
    try std.testing.expect(session.app.?.client.authorization.ptr == auth);
    var saved = try session.store.loadExisting();
    defer cfg.release(&saved);
    try std.testing.expect(saved.value.decision == null);
    try std.testing.expectEqual(@as(u32, 54321), saved.value.limits.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 54321), session.connection().current().limits.request_timeout_ms);
}

test "preferences invalid guards CAS and active validation never publish or save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, plain);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    const app = session.app.?;
    const arena = app.config.arena;
    const global = session.global_config.?.arena;
    const auth = app.client.authorization.ptr;
    const initial = try disk(&session);
    defer a.free(initial);
    try std.testing.expect(session.global_config.?.value.decision == null);
    try std.testing.expectError(error.InvalidLimit, set(&session, .request_timeout_ms, 0));
    session.read_only = true;
    try std.testing.expectError(error.ResumeReadOnly, set(&session, .compaction_enabled, 0));
    session.read_only = false;
    app.runtime.busy.store(true, .release);
    try std.testing.expectError(error.Busy, set(&session, .compaction_enabled, 0));
    app.runtime.busy.store(false, .release);
    app.runtime.poisoned = true;
    try std.testing.expectError(error.UnsafeToContinue, set(&session, .compaction_enabled, 0));
    app.runtime.poisoned = false;
    // Declaration passes; invalid frozen input constraints must reject pre-save.
    const input_limit = app.config.value.limits.max_input_tokens;
    app.config.value.limits.max_input_tokens = app.config.value.limits.input_margin_tokens;
    try std.testing.expectError(error.InvalidBudget, set(&session, .request_timeout_ms, 20000));
    try std.testing.expectEqual(@as(u32, 300000), app.config.value.limits.request_timeout_ms);
    app.config.value.limits.max_input_tokens = input_limit;
    const unchanged = try disk(&session);
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(initial, unchanged);
    try session.store.root.writeMode(cfg.file_name, "{}", true, 0o600);
    try std.testing.expectError(error.AuthVersionConflict, set(&session, .compaction_enabled, 0));
    try std.testing.expect(app.config.arena == arena and session.global_config.?.arena == global);
    try std.testing.expect(app.client.authorization.ptr == auth and app.config.value.limits.compaction_enabled);
    const conflict = try disk(&session);
    defer a.free(conflict);
    try std.testing.expectEqualStrings("{}", conflict);
}

test "preferences no App pending ownership validation and CAS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var parsed = try cfg.parse(a, plain);
    defer cfg.release(&parsed);
    const providers = try parsed.arena.allocator().dupe(cfg.NamedProvider, parsed.value.registry.?.providers);
    providers[0].connection.api_key = null;
    parsed.value.registry.?.providers = providers;
    parsed.value.provider.api_key = null;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(parsed.value, &out.writer);
    try seed(home, out.written());
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    try std.testing.expect(session.app == null);
    for (main_edits) |edit| try set(&session, edit.key, edit.value);
    try set(&session, .request_timeout_ms, 60000);
    try std.testing.expect(session.app == null and session.pending.?.arena != session.global_config.?.arena);
    try std.testing.expectEqualDeep(session.global_config.?.value.limits, session.connection().current().limits);
    const initial = try disk(&session);
    defer a.free(initial);
    session.pending.?.value.limits.command_max_timeout_ms = 15000;
    try std.testing.expectError(error.InvalidLimit, set(&session, .command_timeout_ms, 20000));
    const unchanged = try disk(&session);
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(initial, unchanged);
    const pending_arena = session.pending.?.arena;
    try session.store.root.writeMode(cfg.file_name, "{}", true, 0o600);
    try std.testing.expectError(error.AuthVersionConflict, set(&session, .task_timeout_ms, 50000));
    try std.testing.expect(session.pending.?.arena == pending_arena);
    try std.testing.expectEqual(@as(u32, 40000), session.pending.?.value.limits.task_timeout_ms);
}

fn pendingCloneAllocationCase(allocator: std.mem.Allocator) !void {
    var declaration = try cfg.parse(allocator, reviewed);
    defer cfg.release(&declaration);
    var pending = declaration.value;
    pending.provider = .{ .base_url = "", .api_key_env = "" };
    pending.selection_pending = false;
    try std.testing.expectError(error.InvalidConfig, cfg.clonePendingSettings(allocator, pending));
    pending.selection_pending = true;
    var owned = try profiles.activeClone(allocator, pending, declaration.value);
    defer cfg.release(&owned);
    try std.testing.expect(owned.value.model.name.ptr != pending.model.name.ptr);
    try std.testing.expect(owned.value.registry.?.providers.ptr != declaration.value.registry.?.providers.ptr);
    try std.testing.expectError(error.InvalidBaseUrl, cfg.validate(owned.value));
    try std.testing.expectError(error.InvalidBaseUrl, cfg.clone(allocator, owned.value));
}

test "preferences missing route clone owns strings and releases partial allocations" {
    try std.testing.checkAllAllocationFailures(a, pendingCloneAllocationCase, .{});
}

test "preferences restored missing provider preserves pending history while saving global settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, reviewed);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var id: @import("session_id.zig").Id = undefined;
    {
        var source = try Session.initWithOptions(a, io, &env, home, .{}, .{});
        defer source.deinit();
        id = source.session_id;
        const app = source.app.?;
        try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .user, .blocks = &.{.{ .text = "retired-route history" }} });
        try std.testing.expect(try source.saveOnExit());
    }
    const replacement =
        \\{"llm":{"default":"other/next","providers":{"other":{"base_url":"https://replacement.invalid/v1","api_key":"fake-replacement-only","models":{"next":{"protocol":"chat","context_tokens":65536},"judge":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false},"decision":{"model":"other/judge"}}
    ;
    {
        var store = try Store.open(a, io, home);
        defer store.deinit();
        try store.root.writeMode(cfg.file_name, replacement, true, 0o600);
    }
    var restored = try Session.initWithOptions(a, io, &env, home, .{}, .{ .resume_session = id });
    defer restored.deinit();
    try std.testing.expect(restored.app == null and !restored.read_only);
    try std.testing.expect(restored.pending.?.value.selection_pending);
    try std.testing.expectEqualStrings("", restored.pending.?.value.provider.base_url);
    const connection = restored.connection();
    const history = connection.initial_history_fn.?(connection.context);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    const selection = try a.dupe(u8, connection.current().selection_name.?);
    defer a.free(selection);
    try std.testing.expectEqualStrings("route/first", selection);
    for (main_edits) |edit| try set(&restored, edit.key, edit.value);
    try set(&restored, .request_timeout_ms, 60000);
    try connection.decision_fn.?(connection.context, .off);
    try connection.setting_fn.?(connection.context, .low_price_input, true);
    try std.testing.expect(restored.app == null and restored.pending.?.value.selection_pending);
    try std.testing.expectEqualStrings("", restored.pending.?.value.provider.base_url);
    try std.testing.expectEqualStrings(selection, connection.current().selection_name.?);
    try std.testing.expect(connection.initial_history_fn.?(connection.context).ptr == history.ptr);
    try std.testing.expectEqualStrings("retired-route history", history[0].blocks[0].text);
    try std.testing.expectError(error.InvalidBaseUrl, cfg.validate(restored.pending.?.value));
    var saved = try restored.store.loadExisting();
    defer cfg.release(&saved);
    try std.testing.expectEqualStrings("other/next", saved.value.registry.?.default);
    try std.testing.expectError(error.InvalidConfig, cfg.validatePendingSettings(saved.value));
    try std.testing.expectEqual(@as(u32, 60000), saved.value.limits.request_timeout_ms);
    try std.testing.expect(saved.value.limits.low_price_input and !saved.value.decision.?.enabled);
    try std.testing.expect(!saved.value.memory.auto and !connection.current().memory_auto);
    try std.testing.expectEqualStrings("other/judge", saved.value.decision.?.model);
    const before = try disk(&restored);
    defer a.free(before);
    // An unresolved route does not excuse invalid frozen input constraints.
    const input_limit = restored.pending.?.value.limits.max_input_tokens;
    restored.pending.?.value.limits.max_input_tokens = restored.pending.?.value.limits.input_margin_tokens;
    try std.testing.expectError(error.InvalidBudget, set(&restored, .request_timeout_ms, 20000));
    try std.testing.expectEqual(@as(u32, 60000), restored.pending.?.value.limits.request_timeout_ms);
    try std.testing.expect(connection.initial_history_fn.?(connection.context).ptr == history.ptr);
    const unchanged = try disk(&restored);
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(before, unchanged);
    restored.pending.?.value.limits.max_input_tokens = input_limit;
    const arena = restored.pending.?.arena;
    try restored.store.root.writeMode(cfg.file_name, "{}", true, 0o600);
    try std.testing.expectError(error.AuthVersionConflict, set(&restored, .request_timeout_ms, 30000));
    try std.testing.expect(restored.pending.?.arena == arena and restored.app == null);
    try std.testing.expectEqual(@as(u32, 60000), restored.pending.?.value.limits.request_timeout_ms);
    try std.testing.expect(connection.initial_history_fn.?(connection.context).ptr == history.ptr);
}
