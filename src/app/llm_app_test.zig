const std = @import("std");
const App = @import("app.zig").App;
const cfg = @import("../core/config.zig");
const auth = @import("auth_store.zig");
const metadata = @import("model_metadata.zig");
const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    env: std.process.Environ.Map,
    fn init(data: []const u8) !Fixture {
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        if (std.c.mkdirat(tmp.dir.handle, ".thin", 0o700) != 0) return error.FixtureDirectoryFailed;
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = data });
        var buffer: [4096]u8 = undefined;
        const home = try a.dupe(u8, buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)]);
        errdefer a.free(home);
        var env = std.process.Environ.Map.init(a);
        errdefer env.deinit();
        try env.put("HOME", home);
        return .{ .tmp = tmp, .home = home, .env = env };
    }
    fn deinit(self: *Fixture) void {
        self.env.deinit();
        std.testing.allocator.free(self.home);
        self.tmp.cleanup();
    }
};

test "registry headless resolves manual declarations without requests and protects every key source" {
    var fixture = try Fixture.init(
        \\{"llm":{"default":"work/org/model","providers":{"work":{"base_url":"https://unused.invalid/v1","api_key":"fake-registry-primary","models":{"org/model":{"protocol":"chat","context_tokens":1000000,"output_tokens":128000}}},"inactive":{"base_url":"https://other.invalid/v1","api_key_env":"PATH"},"third":{"base_url":"https://third.invalid/v1","api_key":"fake-registry-third"}}}}
    );
    defer fixture.deinit();
    try fixture.env.put("PATH", "fake-registry-inactive");
    const app = try App.init(std.testing.allocator, std.testing.io, &fixture.env, fixture.home, .{}, false);
    defer app.deinit();
    try std.testing.expectEqualStrings("work", app.config.value.selected_provider.?);
    try std.testing.expectEqualStrings("org/model", app.config.value.model.name);
    try std.testing.expectEqual(@as(u32, 1000000), app.config.value.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 128000), app.config.value.model.output_tokens);
    try std.testing.expect(!app.config.value.selection_pending);
    try std.testing.expect(app.environment.get("PATH") == null);
    try std.testing.expectEqual(@as(usize, 2), app.journal.known_key_count);
    try std.testing.expectEqual(@as(usize, 0), app.runtime.messages().len);
    var unresolved = app.config.value;
    unresolved.selection_pending = true;
    try std.testing.expectError(error.DefaultModelUnavailable, app.runtime.planSelection(unresolved, true));
    var store = try auth.Store.openExisting(std.testing.allocator, std.testing.io, fixture.home);
    defer store.deinit();
    var disk = try store.loadExisting();
    defer cfg.release(&disk);
    // No startup write, migration, or materialized model is persisted.
    try std.testing.expect(disk.value.selection_pending);
    try std.testing.expectEqualStrings("work/org/model", disk.value.registry.?.default);
}

test "registry headless default resolves exact cached directory with no handwritten model row" {
    var fixture = try Fixture.init(
        \\{"llm":{"default":"go/org/cached","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key_env":"FAKE_GO_KEY"}}}}
    );
    defer fixture.deinit();
    try fixture.env.put("FAKE_GO_KEY", "fake-registry-cached");
    var store = try auth.Store.openExisting(std.testing.allocator, std.testing.io, fixture.home);
    defer store.deinit();
    var cache: metadata.Cache = .{};
    const row = try cache.directory.upsert(.opencode_go, "org/cached");
    row.available = true;
    row.protocol = .responses;
    row.tokens = 1000000;
    row.dev_protocol = .responses;
    row.dev_output_tokens = 128000;
    row.dev_present = true;
    cache.directory_mask = metadata.bit(.opencode_go);
    _ = try metadata.commit(&store.root, metadata.bit(.opencode_go), .{
        .directory = cache.directory,
        .directory_mask = cache.directory_mask,
        .dev_done = true,
    });
    const app = try App.init(std.testing.allocator, std.testing.io, &fixture.env, fixture.home, .{}, false);
    defer app.deinit();
    try std.testing.expectEqual(.responses, app.config.value.model.protocol);
    try std.testing.expectEqual(@as(u32, 1000000), app.config.value.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 128000), app.config.value.model.output_tokens);
    try std.testing.expectEqual(.metadata, app.config.value.model.output_source);
    try std.testing.expectEqual(@as(usize, 0), app.config.value.registry.?.providers[0].models.len);
    try std.testing.expect(app.environment.get("FAKE_GO_KEY") == null);
}

test "registry headless unknown default fails locally without changing settings or selecting another model" {
    var fixture = try Fixture.init(
        \\{"llm":{"default":"go/not-cached","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key":"fake-registry-unknown"}}}}
    );
    defer fixture.deinit();
    try std.testing.expectError(error.DefaultModelUnavailable, App.init(std.testing.allocator, std.testing.io, &fixture.env, fixture.home, .{}, false));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, ".thin/settings.json", .{}));
}
