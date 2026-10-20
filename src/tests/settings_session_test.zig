//! Global startup defaults versus conversation-local selections.
//! Owned temporary HOME/projects, explicit Registry capabilities, Fake LLM only.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const Session = @import("../app/session.zig").Session;
const App = @import("../app/app.zig").App;
const Store = @import("../app/auth_store.zig").Store;
const effort = @import("../presentation/activity.zig").ReasoningEffort;
const a = std.testing.allocator;
const io = std.testing.io;

// No catalog/name-based capability fallback. The second model deliberately has
// a different supported set and different wire strings from the first.
const document =
    \\{"llm":{"default":"local/first","providers":{"local":{"base_url":"https://fixture.invalid/v1","api_key_env":"OWNED_SETTINGS_KEY","models":{"first":{"protocol":"chat","context_tokens":65536,"reasoning":{"map":{"off":"none","low":"light","high":"intensive","max":"maximum"}}},"second":{"protocol":"chat","context_tokens":65536,"reasoning_effort":"low","reasoning":{"map":{"low":"second-light","medium":"balanced","high":"second-intensive"}}},"unknown":{"protocol":"chat","context_tokens":65536,"reasoning_effort":"high"}}}}},"limits":{"low_price_input":false}}
;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    project: []u8,
    other: []u8,
    env: std.process.Environ.Map,

    fn init() !Fixture {
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
        var store = try Store.open(a, io, home);
        defer store.deinit();
        var parsed = try cfg.parse(a, document);
        defer cfg.release(&parsed);
        try store.root.writeMode(cfg.file_name, document, false, 0o600);
        return .{ .tmp = tmp, .home = home, .project = project, .other = other, .env = env };
    }

    fn deinit(self: *Fixture) void {
        self.env.deinit();
        a.free(self.home);
        a.free(self.project);
        a.free(self.other);
        self.tmp.cleanup();
    }

    fn session(self: *Fixture, project: []const u8) !Session {
        return Session.initWithOptions(a, io, &self.env, project, .{}, .{ .logging = false, .auto_refresh_models = false });
    }

    fn seed(self: *Fixture, selector: []const u8, preference: ?[]const u8) !void {
        var store = try Store.openExisting(a, io, self.home);
        defer store.deinit();
        var parsed = try store.loadExisting();
        defer cfg.release(&parsed);
        parsed.value.registry.?.default = selector;
        if (preference) |name| try cfg.setRegistryReasoningEffort(parsed.arena.allocator(), &parsed.value, name);
        try store.save(parsed.value);
    }

    fn bytes(self: *Fixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(io, "home/.thin/config.json", a, .limited(cfg.max_config_bytes));
    }

    fn expectDefaults(self: *Fixture, selector: []const u8, preference: ?[]const u8) !void {
        var store = try Store.openExisting(a, io, self.home);
        defer store.deinit();
        var parsed = try store.loadExisting();
        defer cfg.release(&parsed);
        const registry = parsed.value.registry.?;
        try std.testing.expectEqualStrings(selector, registry.default);
        if (preference) |name| {
            try std.testing.expectEqualStrings(name, registry.reasoning_effort.?);
        } else try std.testing.expect(registry.reasoning_effort == null);
        // Persisted logical preference must not replace model declarations.
        const provider = registry.find("local").?;
        try std.testing.expect(provider.patchFor("first").?.reasoning_effort == null);
        try std.testing.expectEqualStrings("low", provider.patchFor("second").?.reasoning_effort.?);
    }

    fn expectNoProjectFiles(self: *Fixture, project: []const u8) !void {
        const path = try std.fs.path.join(a, &.{ project, ".thin/settings.json" });
        defer a.free(path);
        try std.testing.expectError(error.FileNotFound, self.tmp.dir.statFile(io, path, .{}));
        const sessions = try std.fs.path.join(a, &.{ project, ".thin/sessions" });
        defer a.free(sessions);
        try std.testing.expectError(error.FileNotFound, self.tmp.dir.openDir(io, sessions, .{}));
    }
};

const Reply = struct {
    calls: usize = 0,
    fail: bool = false,
    usage: p.Usage = .{ .total_tokens = 1000 },

    fn call(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail) return .{ .failure = .{ .kind = .transport, .message = "owned offline failure" } };
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} }, .finish = .stop, .usage = self.usage } };
    }

    fn install(self: *Reply, session: *Session) void {
        session.app.?.runtime.model = .{ .context = self, .call_fn = call };
    }
};

fn activate(session: *Session) !void {
    try session.connection().configure("fake-owned-settings-key");
}

fn activeConfig(session: *Session) *cfg.Config {
    return if (session.app) |app| &app.config.value else &session.pending.?.value;
}

fn expectWire(config: cfg.Config, expected: ?[]const u8) !void {
    for ([_]p.Purpose{ .normal, .summary }) |purpose| {
        var request = @import("adapter_test_support.zig").request(.chat);
        request.purpose = purpose;
        const mapped = r.withReasoning(config, request);
        if (expected) |value| {
            try std.testing.expectEqualStrings(value, mapped.reasoning_effort.?);
        } else try std.testing.expect(mapped.reasoning_effort == null and mapped.thinking == null);
    }
}

test "empty no-log selections persist global logical defaults and restart across projects" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var first = try fixture.session(fixture.project);
    defer first.deinit();
    try std.testing.expectEqual(effort.high, first.connection().current().reasoning_effort);
    try std.testing.expectEqual(effort.medium, first.preferred_effort.?);
    // Merely clamping a missing preference must not initialize one on disk.
    try fixture.expectDefaults("local/first", null);
    try first.connection().setEffort(.low);
    try fixture.expectDefaults("local/first", "low");
    try std.testing.expectEqualStrings("low", first.global_config.?.value.registry.?.reasoning_effort.?);
    try std.testing.expectError(error.UnsupportedReasoningEffort, first.connection().setEffort(.medium));
    try std.testing.expectEqual(effort.low, first.connection().current().reasoning_effort);
    try first.connection().selectModel("local/second");
    try fixture.expectDefaults("local/second", "low");
    try first.connection().setEffort(.medium);
    try fixture.expectDefaults("local/second", "medium");
    try activate(&first);
    try std.testing.expect(!first.connection().current().logging_enabled);
    // Credential save must retain the independently updated defaults.
    try fixture.expectDefaults("local/second", "medium");
    for ([_][]const u8{ fixture.project, fixture.other }) |project| {
        var restarted = try fixture.session(project);
        defer restarted.deinit();
        try std.testing.expectEqualStrings("second", activeConfig(&restarted).model.name);
        try std.testing.expectEqual(effort.medium, restarted.connection().current().reasoning_effort);
        try std.testing.expectEqual(effort.medium, restarted.preferred_effort.?);
        try fixture.expectNoProjectFiles(project);
    }
}

test "headless and UI share global preference and capability clamp without rewriting it" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed("local/first", "medium");
    try fixture.env.put("OWNED_SETTINGS_KEY", "fake-headless-key");
    const before = try fixture.bytes();
    defer a.free(before);
    const app = try App.init(a, io, &fixture.env, fixture.project, .{});
    defer app.deinit();
    try std.testing.expectEqualStrings("high", app.config.value.model.reasoning_effort.?);
    try expectWire(app.config.value, "intensive");
    var session = try fixture.session(fixture.other);
    defer session.deinit();
    try std.testing.expectEqual(effort.medium, session.preferred_effort.?);
    try std.testing.expectEqual(effort.high, session.connection().current().reasoning_effort);
    try std.testing.expect(session.connection().current().settings_notice != null);
    const after = try fixture.bytes();
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    try fixture.expectDefaults("local/first", "medium");
    try fixture.expectNoProjectFiles(fixture.project);
    try fixture.expectNoProjectFiles(fixture.other);
}

test "missing global preference uses explicit model option before medium fallback" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed("local/second", null);
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try std.testing.expectEqual(effort.low, session.preferred_effort.?);
    try std.testing.expectEqual(effort.low, session.connection().current().reasoning_effort);
    try expectWire(activeConfig(&session).*, "second-light");
    try fixture.expectDefaults("local/second", null);
}

test "unknown capabilities never turn global preference into a wire option" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed("local/unknown", "max");
    try fixture.env.put("OWNED_SETTINGS_KEY", "fake-unknown-key");
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try std.testing.expectEqual(effort.max, session.preferred_effort.?);
    try std.testing.expectEqual(@as(u8, 0), session.connection().current().effort_levels.mask);
    try std.testing.expect(activeConfig(&session).model.reasoning == null);
    try std.testing.expect(activeConfig(&session).model.reasoning_effort == null);
    try std.testing.expectError(error.UnsupportedReasoningEffort, session.connection().setEffort(.high));
    try expectWire(activeConfig(&session).*, null);
    const app = try App.init(a, io, &fixture.env, fixture.other, .{});
    defer app.deinit();
    try expectWire(app.config.value, null);
    try fixture.expectDefaults("local/unknown", "max");
}

test "context-only prefix remains an empty conversation for global selection defaults" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try activate(&session);
    const runtime = &session.app.?.runtime;
    try runtime.history.append(runtime.arena.allocator(), .{ .role = .context, .blocks = &.{.{ .text = "owned environment prefix" }} });
    try session.connection().setEffort(.low);
    try fixture.expectDefaults("local/first", "low");
    try session.connection().selectModel("local/second");
    try fixture.expectDefaults("local/second", "low");
    try std.testing.expectEqual(@as(usize, 1), runtime.messages().len);
    try std.testing.expectEqualStrings("owned environment prefix", runtime.messages()[0].blocks[0].text);
    try fixture.expectNoProjectFiles(fixture.project);
}

test "successful or failed first user turn makes later effort and model choices session-local" {
    for ([_]bool{ false, true }) |fail| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var session = try fixture.session(fixture.project);
        defer session.deinit();
        try session.connection().setEffort(.low);
        try activate(&session);
        var reply: Reply = .{ .fail = fail };
        reply.install(&session);
        var cancel: p.Cancellation = .{};
        const terminal = try session.app.?.runtime.run("owned first user", &cancel);
        try std.testing.expectEqual(if (fail) r.Status.failed else r.Status.success, terminal.status);
        try std.testing.expectEqual(@as(usize, 1), reply.calls);
        var users: usize = 0;
        for (session.app.?.runtime.messages()) |message| {
            if (message.role == .user) {
                users += 1;
                try std.testing.expectEqualStrings("owned first user", message.blocks[0].text);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), users);
        const before = try fixture.bytes();
        defer a.free(before);
        try session.connection().setEffort(.max);
        try std.testing.expectEqual(effort.max, session.preferred_effort.?);
        try session.connection().selectModel("local/second");
        try session.connection().setEffort(.medium);
        try std.testing.expectEqual(effort.medium, session.connection().current().reasoning_effort);
        const after = try fixture.bytes();
        defer a.free(after);
        try std.testing.expectEqualStrings(before, after);
        try std.testing.expectEqualStrings("local/first", session.global_config.?.value.registry.?.default);
        try std.testing.expectEqualStrings("low", session.global_config.?.value.registry.?.reasoning_effort.?);
        // A subsequent credential save must not leak the conversation choices.
        try session.connection().configure("fake-history-credential-change");
        try fixture.expectDefaults("local/first", "low");
        var restarted = try fixture.session(fixture.other);
        defer restarted.deinit();
        try std.testing.expectEqualStrings("first", activeConfig(&restarted).model.name);
        try std.testing.expectEqual(effort.low, restarted.connection().current().reasoning_effort);
        try fixture.expectNoProjectFiles(fixture.project);
    }
}

test "global CAS conflicts roll back effort and model publication including maps" {
    for ([_]bool{ false, true }) |activated| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var session = try fixture.session(fixture.project);
        defer session.deinit();
        try session.connection().setEffort(.low);
        if (activated) try activate(&session);
        const before_model = activeConfig(&session).model;
        // A separate cooperating writer advances disk beyond this Session's CAS.
        try fixture.seed("local/second", "medium");
        const winner = try fixture.bytes();
        defer a.free(winner);
        try std.testing.expectError(error.AuthVersionConflict, session.connection().setEffort(.max));
        try std.testing.expectEqual(effort.low, session.preferred_effort.?);
        try std.testing.expectEqualDeep(before_model, activeConfig(&session).model);
        try std.testing.expectEqualStrings("low", session.global_config.?.value.registry.?.reasoning_effort.?);
        try std.testing.expectError(error.AuthVersionConflict, session.connection().selectModel("local/second"));
        try std.testing.expectEqualDeep(before_model, activeConfig(&session).model);
        try std.testing.expectEqualStrings("local/first", session.global_config.?.value.registry.?.default);
        try expectWire(activeConfig(&session).*, "light");
        const after = try fixture.bytes();
        defer a.free(after);
        try std.testing.expectEqualStrings(winner, after);
    }
}

test "global save read errors cannot publish effort or a new model map" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try session.connection().setEffort(.low);
    const before = activeConfig(&session).model;
    // A directory at the config name produces a deterministic failure even as
    // root; chmod alone would not reliably simulate a denied write here.
    try std.testing.expectEqual(@as(c_int, 0), std.c.renameat(fixture.tmp.dir.handle, "home/.thin/config.json", fixture.tmp.dir.handle, "home/.thin/saved-config"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "home/.thin/config.json", 0o700));
    try std.testing.expectError(error.NotRegularFile, session.connection().setEffort(.max));
    try std.testing.expectEqual(effort.low, session.preferred_effort.?);
    try std.testing.expectEqualDeep(before, activeConfig(&session).model);
    try std.testing.expectError(error.NotRegularFile, session.connection().selectModel("local/second"));
    try std.testing.expectEqualDeep(before, activeConfig(&session).model);
    try std.testing.expectEqualStrings("local/first", session.global_config.?.value.registry.?.default);
    try std.testing.expectEqualStrings("low", session.global_config.?.value.registry.?.reasoning_effort.?);
}

test "legacy project settings malformed oversized and inaccessible are ignored and untouched" {
    const oversized = try a.alloc(u8, 1025); // Retired project settings had a 1024-byte bound.
    defer a.free(oversized);
    @memset(oversized, 'x');
    for ([_][]const u8{ "{broken settings", "{\"version\":1,\"reasoning_effort\":\"max\"}\n", oversized }) |legacy| {
        for ([_]std.c.mode_t{ 0o600, 0o000, 0o644 }) |mode| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            try fixture.seed("local/second", "medium");
            try fixture.env.put("OWNED_SETTINGS_KEY", "fake-legacy-settings-key");
            try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "project/.thin", 0o700));
            try fixture.tmp.dir.writeFile(io, .{ .sub_path = "project/.thin/settings.json", .data = legacy });
            const file = try fixture.tmp.dir.openFile(io, "project/.thin/settings.json", .{ .mode = .read_write });
            defer file.close(io);
            try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(file.handle, mode));
            var session = try fixture.session(fixture.project);
            defer session.deinit();
            try std.testing.expect(session.settings_error == null);
            try std.testing.expectEqual(effort.medium, session.connection().current().reasoning_effort);
            try session.connection().setEffort(.high);
            try session.connection().selectModel("local/first");
            const app = try App.init(a, io, &fixture.env, fixture.project, .{});
            defer app.deinit();
            try std.testing.expectEqualStrings("high", app.config.value.model.reasoning_effort.?);
            const stat = try fixture.tmp.dir.statFile(io, "project/.thin/settings.json", .{});
            try std.testing.expectEqual(@as(u32, @intCast(mode)), stat.permissions.toMode() & 0o777);
            try std.testing.expectEqual(@as(u64, @intCast(legacy.len)), stat.size);
            // Restore permissions for a non-root runner before checking bytes.
            try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(file.handle, 0o600));
            const bytes = try fixture.tmp.dir.readFileAlloc(io, "project/.thin/settings.json", a, .limited(legacy.len + 1));
            defer a.free(bytes);
            try std.testing.expectEqualStrings(legacy, bytes);
            try fixture.expectDefaults("local/first", "high");
        }
    }
}

test "pending activation and global saves keep the original project fd anchor" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.renameat(fixture.tmp.dir.handle, "project", fixture.tmp.dir.handle, "original"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "project", 0o700));
    try session.connection().setEffort(.max);
    try activate(&session);
    try session.app.?.root.write("anchored.txt", "original only", false);
    const bytes = try fixture.tmp.dir.readFileAlloc(io, "original/anchored.txt", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("original only", bytes);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, "project/anchored.txt", .{}));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, "original/.thin/settings.json", .{}));
    try fixture.expectDefaults("local/first", "max");
    try fixture.expectNoProjectFiles(fixture.project);
}

test "same name idle selection republishes latest known or unknown actual context" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try activate(&session);
    var reply: Reply = .{};
    reply.install(&session);
    const runtime = &session.app.?.runtime;
    try std.testing.expectEqual(@as(u64, 0), session.connection().current().initial_context.?.tokens);
    for ([_]p.Usage{ .{ .total_tokens = 1000 }, .{} }) |usage| {
        reply.usage = usage;
        var cancel: p.Cancellation = .{};
        try std.testing.expectEqual(r.Status.success, (try runtime.run("owned context fixture", &cancel)).status);
        try session.connection().selectModel(session.connection().current().model);
        try std.testing.expectEqualDeep(runtime.contextSnapshot(), session.connection().current().initial_context.?);
        try std.testing.expectEqual(usage.total() != null, session.connection().current().initial_context.?.known);
        try std.testing.expectEqual(usage.total() orelse 0, session.connection().current().initial_context.?.tokens);
    }
    try std.testing.expectEqual(@as(usize, 2), reply.calls);
}

test "anchored auth protects original credentials after HOME and project path replacement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.env.put("HOME", fixture.project);
    // This fixture intentionally colocates HOME and project; seed only that
    // owned directory, never consult process HOME or another user's config.
    {
        var store = try Store.open(a, io, fixture.project);
        defer store.deinit();
        try store.root.writeMode(cfg.file_name, document, false, 0o600);
    }
    var session = try fixture.session(fixture.project);
    defer session.deinit();
    try session.connection().setEffort(.low);
    try std.testing.expectEqual(@as(c_int, 0), std.c.renameat(fixture.tmp.dir.handle, "project", fixture.tmp.dir.handle, "original"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "project", 0o700));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fixture.tmp.dir.handle, "project/.thin", 0o700));
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "home/decoy.json", .data = "owned unrelated fixture" });
    const foreign = try std.fs.path.join(a, &.{ fixture.home, "decoy.json" });
    defer a.free(foreign);
    const foreign_z = try a.dupeSentinel(u8, foreign, 0);
    defer a.free(foreign_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat(foreign_z, fixture.tmp.dir.handle, "project/.thin/config.json"));
    try activate(&session);
    const app = session.app.?;
    const expected_path = try std.fs.path.join(a, &.{ fixture.project, ".thin", cfg.file_name });
    defer a.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, app.auth_path);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const executor = app.executor.executor();
    var cancel: p.Cancellation = .{};
    for ([_][]const u8{ ".thin/config.json", ".thin//./config.json", app.auth_path }) |path| {
        const arguments = try std.fmt.allocPrint(arena.allocator(), "{{\"path\":\"{s}\"}}", .{path});
        try std.testing.expectError(error.ProtectedAuthFile, executor.prepare_fn(executor.context, arena.allocator(), .{ .id = "owned-auth-guard", .name = "read_file", .arguments = arguments }));
        try std.testing.expectError(error.ProtectedAuthFile, app.executor.execute(arena.allocator(), .{ .read_file = .{ .path = path } }, &cancel));
        try std.testing.expectError(error.ProtectedAuthFile, app.executor.execute(arena.allocator(), .{ .write_file = .{ .path = path, .content = "not written", .overwrite = true } }, &cancel));
    }
    const original = try fixture.tmp.dir.readFileAlloc(io, "original/.thin/config.json", a, .limited(cfg.max_config_bytes));
    defer a.free(original);
    try std.testing.expect(std.mem.indexOf(u8, original, "fake-owned-settings-key") != null);
    const replacement = try fixture.tmp.dir.readFileAlloc(io, "home/decoy.json", a, .limited(100));
    defer a.free(replacement);
    try std.testing.expectEqualStrings("owned unrelated fixture", replacement);
}
