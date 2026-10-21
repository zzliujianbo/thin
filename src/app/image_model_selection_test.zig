//! Image settings transactions with owned HOME/projects/keys; zero inference.
const std = @import("std");
const cfg = @import("../core/config.zig");
const Session = @import("session.zig").Session;
const Store = @import("auth_store.zig").Store;
const metadata = @import("model_metadata.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const fixture =
    \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"https://main.invalid/v1","api_key":"fake-primary","models":{"chat":{"protocol":"chat","context_tokens":65536},"judge":{"protocol":"chat","context_tokens":65536}}},"vision":{"base_url":"https://vision.invalid/v1","api_key_env":"VISION_OWN_KEY","models":{"deepseek-flash":{}}},"unlogged":{"base_url":"https://unlogged.invalid/v1","api_key_env":"MISSING_IMAGE_KEY","models":{"deepseek-flash":{}}},"similar":{"base_url":"https://similar.invalid/v1","api_key":"fake-similar","models":{"DeepSeek-Flash":{},"deepseek-v4-flash":{}}}}},"decision":{"enabled":true,"model":"main/judge"},"limits":{"low_price_input":false,"safety_tokens":100}}
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
fn choose(session: *Session, model: []const u8) !void {
    const connection = session.connection();
    try connection.image_fn.?(connection.context, .{ .model = model });
}
fn contains(models: []const cfg.Model, name: []const u8) bool {
    for (models) |model| if (std.mem.eql(u8, model.name, name)) return true;
    return false;
}

test "image Settings default Off exact logged candidates and independent transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try seed(home, fixture);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("VISION_OWN_KEY", "fake-vision-own");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const app = session.app.?;
    const primary = app.client.authorization.ptr;
    const decision = app.decision_client.?;
    const state = session.connection().current();
    try std.testing.expect(!state.image_enabled and state.image_model == null);
    try std.testing.expectEqual(@as(usize, 1), state.image_models.len);
    try std.testing.expect(contains(state.image_models, "vision/deepseek-flash"));
    try std.testing.expect(app.image_client == null);
    try std.testing.expectEqual(@as(usize, 4), app.runtime.executor.schemas.len);
    try std.testing.expectError(error.UnknownImageModel, choose(&session, "unlogged/deepseek-flash"));
    try std.testing.expectError(error.UnknownImageModel, choose(&session, "similar/DeepSeek-Flash"));
    try std.testing.expectError(error.UnknownImageModel, choose(&session, "vision/deepseek-v4-flash"));
    try choose(&session, "vision/deepseek-flash");
    try std.testing.expect(session.connection().current().image_enabled);
    try std.testing.expectEqualStrings("vision/deepseek-flash", app.config.value.image.model.?);
    try std.testing.expectEqualStrings("fake-vision-own", app.image_client.?.key);
    try std.testing.expectEqualStrings("https://vision.invalid/v1/chat/completions", app.image_client.?.endpoint);
    try std.testing.expectEqual(@as(usize, 5), app.runtime.executor.schemas.len);
    try std.testing.expectEqualStrings("read_image", app.runtime.executor.schemas[4].name);
    try std.testing.expect(app.client.authorization.ptr == primary and app.decision_client.? == decision);
    const selected = app.image_client.?;
    try env.put("VISION_OWN_KEY", "fake-refreshed-vision");
    try std.testing.expectEqualStrings("fake-vision-own", selected.key);
    try choose(&session, "vision/deepseek-flash");
    try std.testing.expect(app.image_client.? != selected);
    try std.testing.expectEqualStrings("fake-refreshed-vision", app.image_client.?.key);
    try std.testing.expect(app.client.authorization.ptr == primary and app.decision_client.? == decision);
    const connection = session.connection();
    try connection.image_fn.?(connection.context, .off);
    try std.testing.expect(app.image_client == null and !app.config.value.imageActive());
    try std.testing.expectEqual(@as(usize, 4), app.runtime.executor.schemas.len);
    try std.testing.expect(app.client.authorization.ptr == primary and app.decision_client.? == decision);
    const bytes = try disk(home);
    defer a.free(bytes);
    var saved = try cfg.parse(a, bytes);
    defer cfg.release(&saved);
    try std.testing.expect(!saved.value.image.enabled);
    try std.testing.expectEqualStrings("vision/deepseek-flash", saved.value.image.model.?);
    try std.testing.expectEqualStrings("main/chat", saved.value.registry.?.default);
}

test "image Settings stale credential OOM and CAS failure publish nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try seed(home, fixture);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("VISION_OWN_KEY", "fake-vision-own");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const app = session.app.?;
    const primary = app.client.authorization.ptr;
    const decision = app.decision_client.?;
    try env.put("VISION_OWN_KEY", "");
    try std.testing.expectError(error.UnknownImageModel, choose(&session, "vision/deepseek-flash"));
    try env.put("VISION_OWN_KEY", "fake-vision-own");
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    session.allocator = failing.allocator();
    const failed = choose(&session, "vision/deepseek-flash");
    session.allocator = a;
    try std.testing.expectError(error.OutOfMemory, failed);
    const changed = try std.fmt.allocPrint(a, "{s}\n", .{fixture});
    defer a.free(changed);
    {
        var external = try Store.openExisting(a, io, home);
        defer external.deinit();
        try external.root.writeMode(cfg.file_name, changed, true, 0o600);
    }
    try std.testing.expectError(error.AuthVersionConflict, choose(&session, "vision/deepseek-flash"));
    try std.testing.expect(app.image_client == null and !app.config.value.imageActive());
    try std.testing.expect(app.client.authorization.ptr == primary and app.decision_client.? == decision);
    try std.testing.expectEqual(@as(usize, 4), app.runtime.executor.schemas.len);
    const after = try disk(home);
    defer a.free(after);
    try std.testing.expectEqualStrings(changed, after);
}

fn publish(home: []const u8, body: []const u8, now: u64) !void {
    var store = try Store.openExisting(a, io, home);
    defer store.deinit();
    const mask = metadata.bit(.deepseek);
    const claim = try metadata.claimAt(&store.root, mask, true, now, .{});
    const listing = try metadata.parseListing(a, body, .deepseek);
    const result = try metadata.commitClaimedAt(&store.root, mask, listing, claim.generations, now + 1);
    try std.testing.expectEqual(mask, result.accepted);
}

test "image official id-only listing authorizes exact availability not invented main capabilities" {
    const source =
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"https://main.invalid/v1","api_key":"fake-primary","models":{"chat":{"protocol":"chat","context_tokens":65536}}},"official":{"base_url":"https://api.deepseek.com","api_key_env":"VISION_OWN_KEY","models":{}}}},"limits":{"low_price_input":false,"safety_tokens":100}}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try seed(home, source);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("VISION_OWN_KEY", "fake-official-own");
    for ([_][]const u8{ "{\"data\":[{\"id\":\"deepseek-flash\"},{\"id\":\"DeepSeek-Flash\"}]}", "{\"data\":[]}" }, 0..) |body, index| {
        try publish(home, body, 100 + index * 10);
        var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
        defer session.deinit();
        const state = session.connection().current();
        try std.testing.expectEqual(index == 0, contains(state.image_models, "official/deepseek-flash"));
        try std.testing.expect(!state.image_enabled and session.app.?.image_client == null);
        if (index == 0) {
            try choose(&session, "official/deepseek-flash");
            const client = session.app.?.image_client.?;
            try std.testing.expect(client.context_tokens == null and client.output_tokens == null);
            try std.testing.expectEqualStrings("fake-official-own", client.key);
            const connection = session.connection();
            try connection.image_fn.?(connection.context, .off);
        } else try std.testing.expectError(error.UnknownImageModel, choose(&session, "official/deepseek-flash"));
    }
}

test "image official Anthropic base uses the same availability and cached limits as its Chat route" {
    const source =
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"https://main.invalid/v1","api_key":"fake-primary","models":{"chat":{"protocol":"chat","context_tokens":65536}}},"anthropic":{"base_url":"https://api.deepseek.com/anthropic","api_key_env":"VISION_OWN_KEY","models":{}},"manual":{"base_url":"https://api.deepseek.com/anthropic","api_key_env":"VISION_OWN_KEY","models":{"deepseek-flash":{}}}}},"limits":{"low_price_input":false,"safety_tokens":100}}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try seed(home, source);
    try publish(home, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":8192,\"protocol\":\"chat\"}]}", 100);
    {
        var store = try Store.openExisting(a, io, home);
        defer store.deinit();
        const claim = try metadata.claimAt(&store.root, metadata.dev_bit, true, 200, .{});
        const listing = try metadata.parseDev(a,
            \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"deepseek-flash":{"limit":{"context":8192,"output":512}}}}}
        );
        const result = try metadata.commitClaimedAt(&store.root, 0, listing, claim.generations, 201);
        try std.testing.expectEqual(metadata.dev_bit, result.accepted);
    }
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("VISION_OWN_KEY", "fake-anthropic-own");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    for ([_][]const u8{ "anthropic/deepseek-flash", "manual/deepseek-flash" }) |name| {
        try std.testing.expect(contains(session.connection().current().image_models, name));
        try choose(&session, name);
        const client = session.app.?.image_client.?;
        try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", client.endpoint);
        try std.testing.expectEqualStrings("fake-anthropic-own", client.key);
        try std.testing.expectEqual(@as(?u64, 8192), client.context_tokens);
        try std.testing.expectEqual(@as(?u32, 512), client.output_tokens);
        try std.testing.expectEqualStrings("chat", session.app.?.config.value.model.name);
    }
}

test "image unavailable own key preserves main startup and fails before file access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    var parsed = try cfg.parse(a, fixture);
    defer cfg.release(&parsed);
    parsed.value.image = .{ .enabled = true, .model = "vision/deepseek-flash" };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(parsed.value, &out.writer);
    try seed(home, out.written());
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const app = session.app.?;
    try std.testing.expect(app.image_client == null and app.config.value.imageActive());
    try std.testing.expectEqual(@as(usize, 5), app.runtime.executor.schemas.len);
    try std.testing.expectError(error.ImageModelUnavailable, app.executor.image.?.checkReady());
    try std.testing.expectEqualStrings("chat", app.config.value.model.name);
    const connection = session.connection();
    try connection.image_fn.?(connection.context, .off);
    try std.testing.expect(app.executor.image == null and app.image_client == null);
    try std.testing.expectEqual(@as(usize, 4), app.runtime.executor.schemas.len);
}
