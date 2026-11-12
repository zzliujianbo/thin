//! Image settings transactions with owned HOME/projects/keys; zero inference.
const std = @import("std");
const cfg = @import("../core/config.zig");
const Session = @import("session.zig").Session;
const App = @import("app.zig").App;
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
    return try store.root.readBinaryGuarded(a, cfg.file_name, null, null);
}
fn expectPersistedImage(home: []const u8, model: ?[]const u8) !void {
    const bytes = try disk(home);
    defer a.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    if (model) |name| {
        const image = parsed.value.object.get("image").?.object;
        try std.testing.expectEqual(@as(usize, 1), image.count());
        try std.testing.expectEqualStrings(name, image.get("model").?.string);
    } else {
        try std.testing.expect(!parsed.value.object.contains("image"));
    }
}
fn choose(session: *Session, model: []const u8) !void {
    const connection = session.connection();
    try connection.image_fn.?(connection.context, .{ .model = model });
}
fn contains(models: []const cfg.Model, name: []const u8) bool {
    for (models) |model| if (std.mem.eql(u8, model.name, name)) return true;
    return false;
}
fn expectImageSchemas(app: *App, image_on: bool) !void {
    const schemas = app.runtime.executor.schemas;
    try std.testing.expectEqual(@as(usize, 11) + @as(usize, @intFromBool(image_on)), schemas.len);
    try std.testing.expectEqualStrings("edit_file", schemas[schemas.len - 1].name);
    try std.testing.expectEqualStrings("set_session_title", schemas[schemas.len - 2].name);
    try std.testing.expectEqualStrings("background", schemas[schemas.len - 3].name);
    var title_count: usize = 0;
    for (schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "set_session_title")) title_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), title_count);
    if (image_on) {
        try std.testing.expectEqualStrings("read_image", schemas[4].name);
    } else for (schemas) |schema| {
        try std.testing.expect(!std.mem.eql(u8, schema.name, "read_image"));
    }
}

fn contextSurvivesImageSettings(protocol: @import("../core/protocol.zig").Protocol) !void {
    const p = @import("../core/protocol.zig");
    const r = @import("../core/runtime.zig");
    const display = @import("../presentation/state.zig");
    const Reply = struct {
        calls: usize = 0,
        usage: p.Usage,
        fn call(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .success = .{
                .message = .{ .role = .assistant, .blocks = &.{.{ .text = "owned context answer" }} },
                .finish = .stop,
                .usage = self.usage,
            } };
        }
    };
    const source =
        \\{"memory":{"auto":false},"llm":{"default":"main/chat","providers":{"main":{"base_url":"https://main.invalid/v1","api_key":"fake-primary","models":{"chat":{"protocol":"PRIMARY_PROTOCOL","context_tokens":65536,"output_tokens":8192}}},"one":{"base_url":"https://one.invalid/v1","api_key":"fake-image-one","models":{"deepseek-flash":{}}},"two":{"base_url":"https://two.invalid/v1","api_key":"fake-image-two","models":{"deepseek-flash":{}}}}},"limits":{"low_price_input":false,"safety_tokens":100}}
    ;
    const document = try std.mem.replaceOwned(u8, a, source, "PRIMARY_PROTOCOL", @tagName(protocol));
    defer a.free(document);
    for ([_]enum { reported, missing, fresh }{ .reported, .missing, .fresh }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [4096]u8 = undefined;
        const home = buf[0..try tmp.dir.realPath(io, &buf)];
        try seed(home, document);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .auto_refresh_models = false });
        defer session.deinit();
        const app = session.app.?;
        var reply: Reply = .{ .usage = if (mode == .reported) .{ .total_tokens = 1234 } else .{} };
        app.runtime.model = .{ .context = &reply, .call_fn = Reply.call };
        if (mode != .fresh) {
            var cancel: p.Cancellation = .{};
            try std.testing.expectEqual(r.Status.success, (try app.runtime.run("owned offline context", &cancel)).status);
        }
        const before = app.runtime.contextSnapshot();
        try std.testing.expectEqual(mode != .missing, before.known);
        try std.testing.expectEqual(@as(u64, if (mode == .reported) 1234 else 0), before.tokens);
        const primary = app.client.authorization.ptr;
        const estimator = app.runtime.estimator;
        for ([_]?[]const u8{ "one/deepseek-flash", "one/deepseek-flash", "two/deepseek-flash", null }) |selection| {
            if (selection) |name| try choose(&session, name) else {
                const connection = session.connection();
                try connection.image_fn.?(connection.context, .off);
            }
            const state = session.connection().current();
            try std.testing.expectEqualDeep(before, app.runtime.contextSnapshot());
            try std.testing.expectEqualDeep(before, state.initial_context.?);
            try std.testing.expectEqual(display.contextRatio(before), display.contextRatio(state.initial_context.?));
            try std.testing.expect(app.client.authorization.ptr == primary);
            try std.testing.expectEqualDeep(estimator, app.runtime.estimator);
            try std.testing.expectEqual(@as(usize, if (mode == .fresh) 0 else 1), reply.calls);
            try expectImageSchemas(app, selection != null);
            const checkpoint = try app.runtime.checkpoint();
            try std.testing.expectEqual(if (mode == .missing) @as(?u64, null) else before.tokens, checkpoint.last_context_tokens);
        }
    }
}

fn publish(home: []const u8, body: []const u8, now: u64) !void {
    var store = try Store.openExisting(a, io, home);
    defer store.deinit();
    const mask = metadata.bit(.deepseek);
    var claim = try metadata.claimAt(&store.root, mask, true, now, .{});
    defer claim.cache.deinit(a);
    var listing = try metadata.parseListing(a, body, .deepseek);
    defer listing.deinit(a);
    var result = try metadata.commitClaimedAt(&store.root, mask, listing, claim.generations, now + 1);
    defer result.cache.deinit(a);
    try std.testing.expectEqual(mask, result.accepted);
}
