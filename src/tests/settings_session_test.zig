//! Repository preference integration; owned temporary HOME/projects, no calls.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const Session = @import("../app/session.zig").Session;
const App = @import("../app/app.zig").App;
const effort = @import("../presentation/activity.zig").ReasoningEffort;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    project: []u8,
    other: []u8,
    env: std.process.Environ.Map,

    fn init() !Fixture {
        const a = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for ([_][:0]const u8{ "home", "project", "other" }) |name|
            if (std.c.mkdirat(tmp.dir.handle, name, 0o700) != 0) return error.FixtureDirectoryFailed;
        var buffer: [4096]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buffer);
        const home = try std.fs.path.join(a, &.{ buffer[0..n], "home" });
        errdefer a.free(home);
        const project = try std.fs.path.join(a, &.{ buffer[0..n], "project" });
        errdefer a.free(project);
        const other = try std.fs.path.join(a, &.{ buffer[0..n], "other" });
        errdefer a.free(other);
        var env = std.process.Environ.Map.init(a);
        errdefer env.deinit();
        try env.put("HOME", home);
        return .{ .tmp = tmp, .home = home, .project = project, .other = other, .env = env };
    }

    fn deinit(self: *Fixture) void {
        const a = std.testing.allocator;
        self.env.deinit();
        a.free(self.home);
        a.free(self.project);
        a.free(self.other);
        self.tmp.cleanup();
    }

    fn session(self: *Fixture, project: []const u8) !Session {
        // These preference/auth/anchor tests need a known map, not a production
        // name-based fallback. Preserve any test's own explicitly written config.
        var store = try @import("../app/auth_store.zig").Store.open(std.testing.allocator, std.testing.io, self.env.get("HOME").?);
        defer store.deinit();
        if (store.loadExisting()) |value| {
            var existing = value;
            cfg.release(&existing);
        } else |err| {
            if (err != error.ConfigNotFound) return err;
            var initial = try store.loadOrInitialize();
            defer cfg.release(&initial);
            initial.value.model.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high", .max = "max" } };
            try store.save(initial.value);
        }
        return Session.init(std.testing.allocator, std.testing.io, &self.env, project, .{}, true);
    }
};

test "project effort persists without logs and auth saves the untouched global baseline" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var first = try fixture.session(fixture.project);
    defer first.deinit();
    first.setLogging(false);
    const initial = first.connection().current();
    // First entry with no project preference persists a capability-clamped
    // default (the explicit fixture map clamps medium upward to high).
    try std.testing.expectEqual(effort.high, initial.reasoning_effort);
    try std.testing.expect(initial.effort_levels.contains(.off));
    try std.testing.expect(initial.effort_levels.contains(.max));
    try std.testing.expect(!initial.effort_levels.contains(.medium));
    try std.testing.expectEqual(effort.high, (try first.settings.load()).?);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(std.testing.io, "project/.thin/sessions", .{}));
    try first.connection().setEffort(.low);
    try std.testing.expectEqual(effort.low, first.connection().current().reasoning_effort);
    try std.testing.expectEqual(effort.low, (try first.settings.load()).?);
    try std.testing.expectError(error.UnsupportedReasoningEffort, first.connection().setEffort(.medium));
    try std.testing.expectEqual(effort.low, first.connection().current().reasoning_effort);
    try std.testing.expectEqual(effort.low, (try first.settings.load()).?);

    var restarted = try fixture.session(fixture.project);
    defer restarted.deinit();
    try std.testing.expectEqual(effort.low, restarted.connection().current().reasoning_effort);
    try std.testing.expect(restarted.pending_base_model.?.reasoning_effort == null);
    var isolated = try fixture.session(fixture.other);
    defer isolated.deinit();
    // A different project is still a first entry and persists its own default.
    try std.testing.expectEqual(effort.high, isolated.connection().current().reasoning_effort);
    try std.testing.expectEqual(effort.high, (try isolated.settings.load()).?);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(std.testing.io, "other/.thin/sessions", .{}));

    restarted.setLogging(false);
    try restarted.connection().configure("fake-settings-activation-key");
    try std.testing.expectEqual(effort.low, restarted.connection().current().reasoning_effort);
    try std.testing.expect(!restarted.connection().current().logging_enabled);
    var disk = try restarted.store.loadOrInitialize();
    defer cfg.release(&disk);
    try std.testing.expect(disk.value.model.reasoning_effort == null);
    try std.testing.expectEqualStrings("deepseek-flash", disk.value.model.name);
    // Headless entry also reads the project preference, but creates no archive.
    const app = try App.init(std.testing.allocator, std.testing.io, &fixture.env, fixture.project, .{}, false);
    defer app.deinit();
    try std.testing.expectEqualStrings("low", app.config.value.model.reasoning_effort.?);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(std.testing.io, "project/.thin/sessions", .{}));
}

test "headless first entry creates settings and shares the mapped default with the UI" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const io = std.testing.io;
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "home/.thin", 0o700));
    const config =
        \\{"provider":{"base_url":"http://unused.invalid","api_key":"fake-default-key"},"model":{"name":"fixture","context_tokens":32768,"protocol":"chat","reasoning":{"map":{"medium":"balanced"}}}}
    ;
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "home/.thin/config.json", .data = config });
    const app = try App.init(std.testing.allocator, io, &fixture.env, fixture.project, .{}, false);
    defer app.deinit();
    try std.testing.expectEqualStrings("medium", app.config.value.model.reasoning_effort.?);
    const request = @import("../core/runtime.zig").withReasoning(app.config.value, @import("adapter_test_support.zig").request(.chat));
    try std.testing.expectEqualStrings("balanced", request.reasoning_effort.?);
    const bytes = try fixture.tmp.dir.readFileAlloc(io, "project/.thin/settings.json", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"version\":1,\"reasoning_effort\":\"medium\"}\n", bytes);
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try std.testing.expectEqual(effort.medium, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(effort.medium, session.preferred_effort.?);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(io, "project/.thin/sessions", .{}));
}

test "headless uses cached derived maps and preserves unknown after successful cache invalidation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const a = std.testing.allocator;
    const io = std.testing.io;
    const metadata = @import("../app/model_metadata.zig");
    const catalog = @import("../app/provider_catalog.zig");
    var store = try @import("../app/auth_store.zig").Store.open(a, io, fixture.home);
    defer store.deinit();
    var initial = try store.loadOrInitialize();
    defer cfg.release(&initial);
    initial.value.provider = catalog.connection(.opencode_go);
    initial.value.model = catalog.find("opencode-go/gpt-6-luna").?.model;
    initial.value.model.reasoning_source = .metadata;
    initial.value.credentials.opencode_go = "fake-headless-derived-key";
    try store.save(initial.value);
    _ = try metadata.commit(&store.root, 0, try metadata.parseDev(a, @embedFile("../app/models_dev_fixture.json")));
    var settings = try @import("../app/settings_store.zig").Store.open(a, io, fixture.project);
    defer settings.deinit();
    try settings.save(.max);
    const first = try App.init(a, io, &fixture.env, fixture.project, .{}, false);
    defer first.deinit();
    try std.testing.expectEqualStrings("max", first.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(cfg.ReasoningSource.metadata, first.config.value.model.reasoning_source);
    _ = try metadata.commit(&store.root, 0, .{ .dev_done = true });
    const second = try App.init(a, io, &fixture.env, fixture.project, .{}, false);
    defer second.deinit();
    try std.testing.expect(second.config.value.model.reasoning == null and second.config.value.model.reasoning_effort == null);
    try std.testing.expectEqual(effort.max, (try settings.load()).?);
    for ([_]p.Purpose{ .normal, .summary }) |purpose| {
        var base = @import("adapter_test_support.zig").request(.responses);
        base.purpose = purpose;
        const frozen = @import("../core/runtime.zig").withReasoning(first.config.value, base);
        try std.testing.expectEqualStrings("max", frozen.reasoning_effort.?);
        const unknown = @import("../core/runtime.zig").withReasoning(second.config.value, base);
        try std.testing.expect(unknown.reasoning_effort == null and unknown.thinking == null);
    }
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(io, "project/.thin/sessions", .{}));
}

test "unsupported saved effort clamps effectively without rewriting the preference" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "project/.thin", 0o700));
    const saved = "{\"version\":1,\"reasoning_effort\":\"medium\"}\n";
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/.thin/settings.json", .data = saved });
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try std.testing.expectEqual(effort.high, session.connection().current().reasoning_effort);
    try std.testing.expect(session.connection().current().settings_notice != null);
    try std.testing.expectEqual(effort.medium, (try session.settings.load()).?);
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, "project/.thin/settings.json", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(saved, bytes);
    var disk = try session.store.loadOrInitialize();
    defer cfg.release(&disk);
    try std.testing.expect(disk.value.model.reasoning_effort == null);
}

test "invalid preferences never publish a changed option or rewrite malformed state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try session.connection().setEffort(.low);
    const malformed = "{\"version\":2,\"reasoning_effort\":\"max\"}";
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/.thin/settings.json", .data = malformed });
    if (session.connection().setEffort(.max)) |_| return error.ExpectedPreferenceFailure else |_| {}
    try std.testing.expectEqual(effort.low, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(effort.low, session.preferred_effort.?);
    try std.testing.expect(session.settings_error != null);
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, "project/.thin/settings.json", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(malformed, bytes);
    var restarted = try fixture.session(fixture.project);
    defer restarted.deinit();
    try std.testing.expectEqual(effort.unspecified, restarted.connection().current().reasoning_effort);
    try std.testing.expect(restarted.settings_error != null);
    try std.testing.expect(restarted.connection().current().runtime == null);
}

test "pending auth and preference writes retain the original project directory anchor" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.renameat(fixture.tmp.dir.handle, "project", fixture.tmp.dir.handle, "original"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "project", 0o700));
    try session.connection().setEffort(.max);
    try session.connection().configure("fake-anchored-settings-key");
    try session.app.?.root.write("anchored.txt", "original only", false);
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, "original/anchored.txt", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("original only", bytes);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.readFileAlloc(std.testing.io, "project/anchored.txt", std.testing.allocator, .limited(100)));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(std.testing.io, "project/.thin", .{}));
    const preference = try fixture.tmp.dir.readFileAlloc(std.testing.io, "original/.thin/settings.json", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(preference);
    try std.testing.expect(std.mem.indexOf(u8, preference, "max") != null);
    try std.testing.expectEqual(effort.max, session.connection().current().reasoning_effort);
}

test "same name idle selection republishes latest known or unknown actual context not startup zero" {
    const Reply = struct {
        calls: usize = 0,
        usage: p.Usage = .{ .total_tokens = 1000 },
        fn call(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} }, .finish = .stop, .usage = self.usage } };
        }
    };
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    const connection = session.connection();
    try connection.configure("fake-context-session-key");
    var reply: Reply = .{};
    const runtime = &session.app.?.runtime;
    // Replace the transport before any request: this fixture never uses HTTP.
    runtime.model = .{ .context = &reply, .call_fn = Reply.call };
    try std.testing.expectEqual(@as(u64, 0), connection.current().initial_context.?.tokens);
    for ([_]p.Usage{ .{ .total_tokens = 1000 }, .{} }) |usage| {
        reply.usage = usage;
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.run("owned context fixture", &cancel);
        try std.testing.expectEqual(@import("../core/runtime.zig").Status.success, terminal.status);
        try std.testing.expect(!runtime.busy.load(.acquire));
        try connection.selectModel(connection.current().model);
        try std.testing.expectEqualDeep(runtime.contextSnapshot(), connection.current().initial_context.?);
        try std.testing.expectEqual(usage.total() != null, connection.current().initial_context.?.known);
        try std.testing.expectEqual(usage.total() orelse 0, connection.current().initial_context.?.tokens);
    }
    try std.testing.expectEqual(@as(usize, 2), reply.calls);
}

test "anchored auth keeps credential protection when HOME and project pathname are replaced" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.env.put("HOME", fixture.project);
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try session.connection().setEffort(.low);
    try std.testing.expectEqual(@as(c_int, 0), std.c.renameat(fixture.tmp.dir.handle, "project", fixture.tmp.dir.handle, "original"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "project", 0o700));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "project/.thin", 0o700));
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/decoy.json", .data = "owned unrelated fixture" });
    const foreign = try std.fs.path.join(std.testing.allocator, &.{ fixture.home, "decoy.json" });
    defer std.testing.allocator.free(foreign);
    const foreign_z = try std.testing.allocator.dupeSentinel(u8, foreign, 0);
    defer std.testing.allocator.free(foreign_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat(foreign_z, fixture.tmp.dir.handle, "project/.thin/config.json"));
    try session.connection().configure("fake-anchored-auth-key");
    const app = session.app.?;
    const expected_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.project, ".thin", cfg.file_name });
    defer std.testing.allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, app.auth_path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const executor = app.executor.executor();
    var cancel = p.Cancellation{};
    for ([_][]const u8{ ".thin/config.json", ".thin//./config.json", app.auth_path }) |path| {
        const arguments = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{path});
        if (executor.prepare_fn(executor.context, a, .{ .id = "owned-auth-guard", .name = "read_file", .arguments = arguments })) |_| return error.ExpectedProtectedAuthFile else |err| try std.testing.expectEqual(error.ProtectedAuthFile, err);
        if (app.executor.execute(a, .{ .read_file = .{ .path = path } }, &cancel)) |_| return error.ExpectedProtectedAuthFile else |err| try std.testing.expectEqual(error.ProtectedAuthFile, err);
        if (app.executor.execute(a, .{ .write_file = .{ .path = path, .content = "not written", .overwrite = true } }, &cancel)) |_| return error.ExpectedProtectedAuthFile else |err| try std.testing.expectEqual(error.ProtectedAuthFile, err);
    }
    const original = try fixture.tmp.dir.readFileAlloc(std.testing.io, "original/.thin/config.json", std.testing.allocator, .limited(cfg.max_config_bytes));
    defer std.testing.allocator.free(original);
    try std.testing.expect(std.mem.find(u8, original, "fake-anchored-auth-key") != null);
    const replacement = try fixture.tmp.dir.readFileAlloc(std.testing.io, "home/decoy.json", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqualStrings("owned unrelated fixture", replacement);
}
