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
        return Session.initWithOptions(a, io, &self.env, self.project, .{}, .{ .auto_refresh_models = false });
    }

    fn bytes(self: *Fixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(io, "home/.thin/config.json", a, .limited(cfg.max_config_bytes));
    }

    fn noLogs(self: *Fixture) !void {
        try std.testing.expectError(error.FileNotFound, self.tmp.dir.openDir(io, "project/.thin/sessions", .{}));
    }
};

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
    const selected_alias = session.selected_alias;
    const published = session.connection().current();
    const published_effort = published.reasoning_effort;
    const published_count = published.models.len;
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", published.selection_name.?);
    var explicit_index: ?usize = null;
    for (published.models, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.name, "deepseek/explicit-profile")) {
            explicit_index = index;
            break;
        }
    }
    try std.testing.expect(explicit_index != null);
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
    try std.testing.expectEqualDeep(selected_alias, session.selected_alias);
    const current = session.connection().current();
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", current.selection_name.?);
    try std.testing.expectEqualStrings("deepseek-flash", current.model);
    try std.testing.expectEqual(published_effort, current.reasoning_effort);
    try std.testing.expectEqual(published_count, current.models.len);
    const explicit = current.models[explicit_index.?];
    try std.testing.expectEqualStrings("deepseek/explicit-profile", explicit.name);
    try std.testing.expectEqual(@as(u32, 65536), explicit.context_tokens);
    try std.testing.expectEqual(p.Protocol.responses, explicit.protocol);
    try std.testing.expectEqual(@as(usize, 0), app.runtime.messages().len);
    const after = try fixture.bytes();
    defer a.free(after);
    try std.testing.expectEqualStrings(if (failure == .conflict) "changed externally" else before, after);
    try fixture.noLogs();
}
