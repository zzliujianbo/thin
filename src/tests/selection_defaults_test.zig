//! Offline selection/default transactions. Every HOME, credential and project is owned.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const context = @import("../core/context.zig");
const Session = @import("../app/session.zig").Session;
const Store = @import("../app/auth_store.zig").Store;
const resume_codec = @import("../app/resume_codec.zig");
const catalog = @import("../app/provider_catalog.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const target = "opencode-go/claude-haiku-5-5";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    project: []u8,
    env: std.process.Environ.Map,

    fn init(env_key: bool) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for ([_][:0]const u8{ "home", "project" }) |name| {
            if (std.c.mkdirat(tmp.dir.handle, name, 0o700) != 0) return error.FixtureDirectoryFailed;
        }
        var buffer: [4096]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buffer);
        const home = try std.fs.path.join(a, &.{ buffer[0..n], "home" });
        errdefer a.free(home);
        const project = try std.fs.path.join(a, &.{ buffer[0..n], "project" });
        errdefer a.free(project);
        var env = std.process.Environ.Map.init(a);
        errdefer env.deinit();
        try env.put("HOME", home);
        try env.put("THIN_SELECTION_FAKE_KEY", "fake-resolved-env-selection-secret");
        var store = try Store.open(a, io, home);
        defer store.deinit();
        var parsed = try store.loadOrInitialize();
        defer cfg.release(&parsed);
        var config = parsed.value;
        config.provider.api_key_env = if (env_key) "THIN_SELECTION_FAKE_KEY" else "";
        config.provider.api_key = if (env_key) null else "fake-inline-deepseek-selection";
        var go = catalog.connection(.opencode_go);
        go.api_key = "fake-go-selection";
        var zen = catalog.connection(.opencode_zen);
        zen.api_key = "fake-zen-selection";
        config.registry = .{ .default = "deepseek/deepseek-flash", .providers = &.{
            .{ .name = "deepseek", .connection = config.provider, .models = &.{.{ .name = "explicit-profile", .patch = .{ .context_tokens = 65536, .protocol = .responses } }} },
            .{ .name = "opencode-go", .connection = go },
            .{ .name = "opencode-zen", .connection = zen },
        } };
        config.limits.low_price_input = false;
        config.limits.max_rounds = 7;
        config.limits.max_tool_calls = 19;
        config.limits.read_bytes = 12345;
        try store.save(config);
        return .{ .tmp = tmp, .home = home, .project = project, .env = env };
    }

    fn deinit(self: *Fixture) void {
        self.env.deinit();
        a.free(self.home);
        a.free(self.project);
        self.tmp.cleanup();
    }

    fn session(self: *Fixture) !Session {
        return Session.initWithOptions(a, io, &self.env, self.project, .{}, false, .{ .auto_refresh_models = false });
    }

    fn bytes(self: *Fixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(io, "home/.thin/config.json", a, .limited(cfg.max_config_bytes));
    }

    fn noLogs(self: *Fixture) !void {
        try std.testing.expectError(error.FileNotFound, self.tmp.dir.openDir(io, "project/.thin/sessions", .{}));
    }
};

test "selection defaults empty ready cross-provider survives restart without creating logs" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var session = try fixture.session();
    defer session.deinit();
    const app = session.app.?;
    const limits = app.config.value.limits;
    const selected = catalog.find(target).?.model;
    try std.testing.expectEqual(@as(usize, 0), app.runtime.messages().len);
    try session.connection().selectModel(target);
    try std.testing.expect(session.app.? == app);
    try std.testing.expectEqualStrings(selected.name, app.config.value.model.name);
    try std.testing.expectEqual(selected.protocol, app.runtime.selector.effective());
    try std.testing.expectEqualStrings("Bearer fake-go-selection", app.client.authorization);
    var disk = try session.store.loadExisting();
    defer cfg.release(&disk);
    const empty_cache: @import("../app/model_metadata.zig").Cache = .{};
    try @import("../app/model_resolver.zig").applyDefault(disk.arena.allocator(), &disk.value, &empty_cache);
    try std.testing.expectEqualStrings(cfg.providers.Id.opencode_go.baseUrl(), disk.value.provider.base_url);
    try std.testing.expectEqualStrings(selected.name, disk.value.model.name);
    try std.testing.expectEqual(selected.protocol, disk.value.model.protocol);
    try std.testing.expectEqual(selected.context_tokens, disk.value.model.context_tokens);
    try std.testing.expectEqualDeep(limits, disk.value.limits);
    const registry = disk.value.registry.?;
    try std.testing.expectEqualStrings("fake-inline-deepseek-selection", registry.find("deepseek").?.connection.api_key.?);
    try std.testing.expectEqualStrings("fake-go-selection", registry.find("opencode-go").?.connection.api_key.?);
    try std.testing.expectEqualStrings("fake-zen-selection", registry.find("opencode-zen").?.connection.api_key.?);
    try std.testing.expectEqual(@as(usize, 1), registry.find("deepseek").?.models.len);
    try std.testing.expectEqualStrings("fake-go-selection", disk.value.provider.api_key.?);
    try fixture.noLogs();
    var restarted = try fixture.session();
    defer restarted.deinit();
    try std.testing.expectEqualStrings(selected.name, restarted.connection().current().model);
    try std.testing.expectEqual(selected.protocol, restarted.app.?.runtime.selector.effective());
    try std.testing.expectEqual(selected.context_tokens, restarted.connection().current().context_limit);
    try std.testing.expectEqual(context.inputBudget(disk.value), context.inputBudget(restarted.app.?.config.value));
    try std.testing.expectEqualStrings("Bearer fake-go-selection", restarted.app.?.client.authorization);
    try std.testing.expectEqualDeep(limits, restarted.app.?.config.value.limits);
    try std.testing.expect(!app.journal.started and !restarted.app.?.journal.started);
    try fixture.noLogs();
}

test "selection defaults user-only canonical history changes only session selection" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var session = try fixture.session();
    defer session.deinit();
    const before = try fixture.bytes();
    defer a.free(before);
    const app = session.app.?;
    const id = session.session_id;
    const arena = app.runtime.arena.allocator();
    // A failed first model reply still leaves this user message canonical.
    const text = try arena.dupe(u8, "user retained after failed first reply");
    try app.runtime.history.append(arena, .{ .role = .user, .blocks = try arena.dupe(p.Block, &.{.{ .text = text }}) });
    app.journal.observer().notify(.{ .submitted = text });
    app.journal.flush();
    try std.testing.expect(app.journal.failure() == null);
    try session.connection().selectModel(target);
    app.journal.flush();
    try std.testing.expect(app.journal.failure() == null);
    try std.testing.expect(session.app.? == app);
    try std.testing.expectEqualSlices(u8, &id, &session.session_id);
    try std.testing.expectEqualSlices(u8, &id, &app.client.session_id.?);
    try std.testing.expectEqual(@as(usize, 1), app.runtime.messages().len);
    try std.testing.expectEqual(p.Role.user, app.runtime.messages()[0].role);
    try std.testing.expectEqualStrings(text, app.runtime.messages()[0].blocks[0].text);
    const checkpoint_bytes = try session.resume_lease.?.load(&session.project_root);
    defer a.free(checkpoint_bytes);
    const saved = try resume_codec.inspect(a, checkpoint_bytes, id);
    try std.testing.expectEqualStrings(catalog.find(target).?.model.name, saved.selection.model());
    try std.testing.expectEqual(cfg.providers.Id.opencode_go, saved.selection.provider.?);
    try std.testing.expectEqual(p.Protocol.anthropic, saved.selection.protocol);
    const after = try fixture.bytes();
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualStrings("deepseek-flash", session.global_config.?.value.model.name);
    var restarted = try fixture.session();
    defer restarted.deinit();
    try std.testing.expectEqualStrings("deepseek-flash", restarted.connection().current().model);
}

fn rejectWrite(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
    return error.NoSpaceLeft;
}

const Failure = enum { conflict, allocation, write };

fn expectAtomicFailure(name: []const u8, failure: Failure) !void {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var session = try fixture.session();
    defer session.deinit();
    const app = session.app.?;
    app.runtime.last_context_tokens = 1234;
    app.runtime.estimator.per_mille = 2300;
    const model = app.runtime.model;
    const selector = app.runtime.selector;
    const snapshot = app.runtime.contextSnapshot();
    const initial_context = session.initial_context;
    const display = session.display_models.ptr;
    const selected_name = session.selected_name;
    const selected_alias = session.selected_alias;
    const global = session.global_config.?.value;
    const expected_version = session.store.expected_version;
    const before = try fixture.bytes();
    defer a.free(before);
    const original_allocator = session.store.root.allocator;
    const original_io = session.store.root.io;
    var empty: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&empty);
    var vtable = io.vtable.*;
    vtable.fileWritePositional = rejectWrite;
    // Only the store fails; all model/client/Runtime preparation can succeed.
    defer session.store.root.allocator = original_allocator;
    defer session.store.root.io = original_io;
    switch (failure) {
        .conflict => try fixture.tmp.dir.writeFile(io, .{ .sub_path = "home/.thin/config.json", .data = "changed externally" }),
        .allocation => session.store.root.allocator = failing.allocator(),
        .write => session.store.root.io = .{ .userdata = io.userdata, .vtable = &vtable },
    }
    const expected_error = switch (failure) {
        .conflict => error.AuthVersionConflict,
        .allocation => error.OutOfMemory,
        .write => error.NoSpaceLeft,
    };
    try std.testing.expectError(expected_error, session.connection().selectModel(name));
    try std.testing.expect(session.app.? == app);
    try std.testing.expectEqualStrings("deepseek-flash", app.config.value.model.name);
    try std.testing.expectEqualStrings("deepseek-flash", app.client.config.model.name);
    try std.testing.expectEqualStrings("Bearer fake-inline-deepseek-selection", app.client.authorization);
    try std.testing.expect(app.runtime.model.context == model.context and app.runtime.model.call_fn == model.call_fn);
    try std.testing.expectEqualDeep(selector, app.runtime.selector);
    try std.testing.expectEqualDeep(snapshot, app.runtime.contextSnapshot());
    try std.testing.expectEqualDeep(initial_context, session.initial_context);
    try std.testing.expectEqual(@as(u64, 2300), app.runtime.estimator.per_mille);
    try std.testing.expectEqualDeep(global, session.global_config.?.value);
    try std.testing.expectEqualDeep(expected_version, session.store.expected_version);
    try std.testing.expect(session.display_models.ptr == display);
    try std.testing.expectEqualDeep(selected_name, session.selected_name);
    try std.testing.expectEqualDeep(selected_alias, session.selected_alias);
    try std.testing.expectEqual(@as(usize, 0), app.runtime.messages().len);
    const after = try fixture.bytes();
    defer a.free(after);
    try std.testing.expectEqualStrings(if (failure == .conflict) "changed externally" else before, after);
    try fixture.noLogs();
}

test "selection defaults empty catalog conflict allocation and write failures publish nothing" {
    inline for (.{ Failure.conflict, Failure.allocation, Failure.write }) |failure| try expectAtomicFailure(target, failure);
}

test "selection defaults empty explicit profile conflict allocation and write failures publish nothing" {
    inline for (.{ Failure.conflict, Failure.allocation, Failure.write }) |failure| try expectAtomicFailure("explicit-profile", failure);
}

test "selection defaults current row no-op never saves even with a stale store version" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var session = try fixture.session();
    defer session.deinit();
    const app = session.app.?;
    const expected_version = session.store.expected_version;
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "home/.thin/config.json", .data = "external writer owns this version" });
    try session.connection().selectModel(session.connection().current().model);
    try std.testing.expect(session.app.? == app);
    try std.testing.expectEqualStrings("deepseek-flash", app.config.value.model.name);
    try std.testing.expectEqualDeep(expected_version, session.store.expected_version);
    const bytes = try fixture.bytes();
    defer a.free(bytes);
    try std.testing.expectEqualStrings("external writer owns this version", bytes);
    try fixture.noLogs();
}

test "selection defaults environment-backed same-provider change persists variable name only" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var session = try fixture.session();
    defer session.deinit();
    try std.testing.expectEqualStrings("Bearer fake-resolved-env-selection-secret", session.app.?.client.authorization);
    try session.connection().selectModel("deepseek/deepseek-v4-pro");
    var disk = try session.store.loadExisting();
    defer cfg.release(&disk);
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-pro", disk.value.registry.?.default);
    const declared = disk.value.registry.?.find("deepseek").?;
    try std.testing.expectEqualStrings("THIN_SELECTION_FAKE_KEY", declared.connection.api_key_env);
    try std.testing.expect(declared.connection.api_key == null);
    try std.testing.expectEqual(@as(usize, 1), declared.models.len);
    const bytes = try fixture.bytes();
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fake-resolved-env-selection-secret") == null);
    try fixture.env.put("THIN_SELECTION_FAKE_KEY", "fake-new-env-selection-secret");
    var restarted = try fixture.session();
    defer restarted.deinit();
    try std.testing.expectEqualStrings("deepseek-v4-pro", restarted.connection().current().model);
    try std.testing.expectEqualStrings("Bearer fake-new-env-selection-secret", restarted.app.?.client.authorization);
    try fixture.noLogs();
}
