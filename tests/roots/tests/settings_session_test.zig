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
    \\{"memory":{"auto":false},"llm":{"default":"local/first","providers":{"local":{"base_url":"https://fixture.invalid/v1","api_key_env":"OWNED_SETTINGS_KEY","models":{"first":{"protocol":"chat","context_tokens":65536,"reasoning":{"map":{"off":"none","low":"light","high":"intensive","max":"maximum"}}},"second":{"protocol":"chat","context_tokens":65536,"reasoning_effort":"low","reasoning":{"map":{"low":"second-light","medium":"balanced","high":"second-intensive"}}},"unknown":{"protocol":"chat","context_tokens":65536,"reasoning_effort":"high"}}}}},"limits":{"low_price_input":false}}
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
        return Session.initWithOptions(a, io, &self.env, project, .{}, .{ .auto_refresh_models = false });
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
        return self.tmp.dir.readFileAlloc(io, "home/.thin/config.json", a, .unlimited);
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

    fn expectNoProjectSettings(self: *Fixture, project: []const u8) !void {
        const path = try std.fs.path.join(a, &.{ project, ".thin/settings.json" });
        defer a.free(path);
        try std.testing.expectError(error.FileNotFound, self.tmp.dir.statFile(io, path, .{}));
    }

    fn expectIdle(self: *Fixture, project: []const u8) !void {
        try self.expectNoProjectSettings(project);
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
