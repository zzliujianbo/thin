//! App-level subagent ownership regressions: the capability is always wired,
//! idle rebinding keeps it installed, and Decision/Image clones stay independent.
//! No network, real credentials or user configuration directories are touched.

const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const App = @import("../app/app.zig").App;
const DecisionClient = @import("../app/decision_client.zig").Client;
const image_client = @import("../app/image_client.zig");
const ImageClient = image_client.Client;
const model_resolver = @import("../app/model_resolver.zig");

const parent_tools = [_][]const u8{ "subagent", "get_subagent_result", "send_subagent_message", "cancel_subagent" };

fn hasSchema(schemas: []const @import("../core/protocol.zig").ToolSchema, name: []const u8) bool {
    for (schemas) |schema| if (std.mem.eql(u8, schema.name, name)) return true;
    return false;
}

fn expectSubagentSurface(app: *App) !void {
    try std.testing.expect(app.executor.subagent != null);
    const schemas = app.executor.executor().schemas;
    for (parent_tools) |name| try std.testing.expect(hasSchema(schemas, name));
    for (parent_tools) |name| try std.testing.expect(hasSchema(app.runtime.executor.schemas, name));
    // The child has no recursive delegation and no memory tool.
    try std.testing.expect(app.executor.parent_channel == null);
    try std.testing.expect(app.executor.allow_memory);
}

test "App installs the subagent capability unconditionally and keeps it across settings" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var root = try fs.Root.open(a, io, path);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path);
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://127.0.0.1:1/v1","api_key":"fake-app-key","models":{"main":{"context_tokens":32768,"protocol":"chat"}}}}}}
    );
    model_resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &.{}) catch |err| {
        cfg.release(&parsed);
        return err;
    };
    const app = try App.initConfiguredAnchoredAuth(a, io, &env, &root, "/unused/private/config.json", .{}, parsed);
    defer app.deinit();

    try expectSubagentSurface(app);
    // The service borrows stable App fields, including the replaceable cwd slice.
    try std.testing.expectEqual(@intFromPtr(app.session_cwd.ptr), @intFromPtr(app.subagent.deps.session_cwd.ptr));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "other", 0o700));
    const other = try std.fs.path.join(a, &.{ path, "other" });
    defer a.free(other);
    try app.setWorkingDirectory(other);
    try std.testing.expectEqual(@intFromPtr(app.session_cwd.ptr), @intFromPtr(app.subagent.deps.session_cwd.ptr));
    try std.testing.expectEqualStrings(app.session_cwd, app.subagent.deps.session_cwd);

    // An ordinary settings replacement must not remove the capability and must
    // not resurrect a persisted enable/disable switch.
    var declaration = app.config.value;
    declaration.limits.request_timeout_ms += 1;
    var replacement = try app.prepareSettings(declaration, &env);
    defer replacement.deinit();
    try std.testing.expect(!replacement.changes_tools);
    app.installSettings(&replacement);
    try expectSubagentSurface(app);
    try std.testing.expectEqual(@intFromPtr(app.subagent.deps.config), @intFromPtr(&app.config.value));
}

test "Decision clone copies frozen declaration key into an independent lazy owner" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CURL_CA_BUNDLE", "/owned/decision-ca.pem");
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"context_tokens":32768,"protocol":"chat"}}},"judge":{"base_url":"http://judge.invalid/v1","api_key":"fake-judge-key","models":{"mini":{"context_tokens":16384,"protocol":"chat"}}}}},"decision":{"model":"judge/mini"}}
    );
    defer cfg.release(&parsed);
    const parent = (try DecisionClient.create(a, std.testing.io, parsed.value, &env)).?;
    defer parent.deinit();
    const unresolved = try parent.clone();
    defer unresolved.deinit();
    try std.testing.expect(unresolved.resolved == null and unresolved.native == null);
    try std.testing.expectEqualStrings("judge/mini", unresolved.source.value.decision.?.model);
    try std.testing.expectEqualStrings("fake-judge-key", unresolved.key.?);
    try std.testing.expectEqualStrings("/owned/decision-ca.pem", unresolved.transport_env.get("CURL_CA_BUNDLE").?);
    try std.testing.expect(unresolved.source.value.decision.?.model.ptr != parent.source.value.decision.?.model.ptr);
    try std.testing.expectEqual(@as(u64, 0), unresolved.calls);
}

test "Image clone owns endpoint key timeout CA and route without sharing poison" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CURL_CA_BUNDLE", "/owned/image-ca.pem");
    const options: image_client.Options = .{
        .base_url = "http://image.invalid/v1///",
        .api_key = "fake-image-key",
        .request_timeout_ms = 4321,
        .proxy_url = "http://owned.invalid:8080",
        .context_tokens = 16384,
    };
    const parent = try ImageClient.create(a, std.testing.io, &env, options);
    defer parent.deinit() catch unreachable;
    const clone = try parent.clone();
    defer clone.deinit() catch unreachable;
    try std.testing.expectEqualStrings("fake-image-key", clone.key);
    try std.testing.expectEqualStrings("http://image.invalid/v1/chat/completions", clone.endpoint);
    try std.testing.expectEqual(@as(u32, 4321), clone.timeout_ms);
    try std.testing.expectEqual(@as(?u64, 16384), clone.context_tokens);
    try std.testing.expectEqualStrings("/owned/image-ca.pem", clone.transport.env.get("CURL_CA_BUNDLE").?);
    try std.testing.expectEqualStrings("http://owned.invalid:8080", clone.transport.proxy_url.?);
    try std.testing.expect(parent.transport.proxy_url.?.ptr != clone.transport.proxy_url.?.ptr);
    parent.transport.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, parent.clone());
}
