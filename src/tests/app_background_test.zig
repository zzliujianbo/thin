//! App-level background ownership regressions: one instance owner, a single
//! deps publication, service republication on settings/connection install, and
//! real executor start/status/stop through the App's own Tools.
//!
//! Owned local processes only: no network, no real credentials, no user
//! configuration directories. The cross-task keep-alive and exit-reclaim proofs
//! live in tests/product/background_mock.py because they need real rounds/PTY.

const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const App = @import("../app/app.zig").App;
const background = @import("../core/background.zig");
const p = @import("../core/protocol.zig");
const model_resolver = @import("../app/model_resolver.zig");

fn hasSchema(schemas: []const p.ToolSchema, name: []const u8) bool {
    for (schemas) |schema| if (std.mem.eql(u8, schema.name, name)) return true;
    return false;
}

fn expectBackgroundSurface(app: *App) !void {
    // The App is the only owner; Tools only sees the service value.
    try std.testing.expect(app.background.deps != null);
    try std.testing.expect(app.executor.background != null);
    try std.testing.expect(app.executor.parent_channel == null);
    const schemas = app.executor.executor().schemas;
    try std.testing.expect(hasSchema(schemas, "background"));
    try std.testing.expect(hasSchema(schemas, "bash"));
    // Appended last, so every earlier tool keeps its index.
    try std.testing.expectEqualStrings("background", schemas[schemas.len - 1].name);
    try std.testing.expectEqualStrings("bash", schemas[2].name);
    try std.testing.expect(hasSchema(app.runtime.executor.schemas, "background"));
}

fn build(app: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, root: *const fs.Root, json: []const u8) !*App {
    var parsed = try cfg.parse(app, json);
    model_resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &.{}) catch |err| {
        cfg.release(&parsed);
        return err;
    };
    return App.initConfiguredAnchoredAuth(app, io, env, root, "/unused/private/config.json", .{}, parsed);
}

/// The start receipt is already-encoded JSON; take the instance id from it
/// without depending on any other field name.
fn receiptId(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.NotAReceipt,
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| switch (entry.value_ptr.*) {
        .string => |value| if (background.validId(value)) return try arena.dupe(u8, value),
        else => {},
    };
    return error.NoInstanceId;
}

const ServiceSnapshot = struct { id: []const u8, state: []const u8, pid: u64 };

/// Read the instance id, real state and launched pid out of a status receipt.
fn serviceSnapshot(arena: std.mem.Allocator, text: []const u8) !ServiceSnapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.NotAStatus,
    };
    const service = switch (object.get("service") orelse return error.NotAStatus) {
        .object => |value| value,
        else => return error.NotAStatus,
    };
    const id_value = switch (service.get("id") orelse return error.NotAStatus) {
        .string => |value| value,
        else => return error.NotAStatus,
    };
    const state_value = switch (service.get("state") orelse return error.NotAStatus) {
        .string => |value| value,
        else => return error.NotAStatus,
    };
    const pid_value = switch (service.get("pid") orelse return error.NotAStatus) {
        .integer => |value| value,
        else => return error.NotAStatus,
    };
    return .{
        .id = try arena.dupe(u8, id_value),
        .state = try arena.dupe(u8, state_value),
        .pid = @intCast(pid_value),
    };
}

test "App publishes one background owner and keeps it across settings and connection installs" {
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
    const app = try build(a, io, &env, &root,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://127.0.0.1:1/v1","api_key":"fake-app-key","models":{"main":{"context_tokens":32768,"protocol":"chat"},"alternate":{"context_tokens":32768,"protocol":"chat"}}}}}}
    );
    defer app.deinit();
    try expectBackgroundSurface(app);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cancel = p.Cancellation{};

    // An already-running job must survive both installs with the same identity.
    const started = try app.executor.execute(allocator, .{ .bash = .{
        .command = "printf 'BG-KEEP-LOG\n'; exec sleep 30",
        .background = true,
    } }, &cancel);
    try std.testing.expect(!started.is_error);
    const id = try receiptId(allocator, started.text);
    const before = try serviceSnapshot(allocator, (try app.executor.execute(allocator, .{ .background = .{
        .action = .status,
        .id = id,
    } }, &cancel)).text);
    try std.testing.expectEqualStrings(id, before.id);
    try std.testing.expectEqualStrings("running", before.state);
    try std.testing.expect(before.pid > 0);

    // Idle settings replacement republishes the service value, never the owner.
    var declaration = app.config.value;
    declaration.limits.request_timeout_ms += 1;
    var replacement = try app.prepareSettings(declaration, &env);
    defer replacement.deinit();
    app.installSettings(&replacement);
    try expectBackgroundSurface(app);
    const after_settings = try serviceSnapshot(allocator, (try app.executor.execute(allocator, .{ .background = .{
        .action = .status,
        .id = id,
    } }, &cancel)).text);
    try std.testing.expectEqualStrings(before.id, after_settings.id);
    try std.testing.expectEqual(before.pid, after_settings.pid);
    try std.testing.expectEqualStrings("running", after_settings.state);

    // Connection replacement must not reset the registry either.
    var candidate = try cfg.clone(a, app.config.value);
    candidate.value.model.name = "alternate";
    const connection = try app.prepareConnection(candidate, &env);
    app.installConnection(connection);
    try expectBackgroundSurface(app);
    try std.testing.expectEqualStrings("alternate", app.config.value.model.name);
    const after_connection = try serviceSnapshot(allocator, (try app.executor.execute(allocator, .{ .background = .{
        .action = .status,
        .id = id,
    } }, &cancel)).text);
    try std.testing.expectEqualStrings(before.id, after_connection.id);
    try std.testing.expectEqual(before.pid, after_connection.pid);
    try std.testing.expectEqualStrings("running", after_connection.state);

    // Normal stop, still before App.deinit releases root/environment.
    const stopped = try app.executor.execute(allocator, .{ .background = .{ .action = .stop, .id = id } }, &cancel);
    try std.testing.expect(!stopped.is_error);
    try std.testing.expect(!stopped.cleanup_failed);
}

test "App executor starts, queries and stops a real owned background command" {
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
    const app = try build(a, io, &env, &root,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://127.0.0.1:1/v1","api_key":"fake-app-key","models":{"main":{"context_tokens":32768,"protocol":"chat"}}}}}}
    );
    // deinit cancels and joins anything still running before env/root release.
    defer app.deinit();
    try expectBackgroundSurface(app);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cancel = p.Cancellation{};

    // Round 1: a real owned process starts and hands off in this App instance.
    const started = try app.executor.execute(allocator, .{ .bash = .{
        .command = "printf 'BG-UNIT-LOG\\n'; exec sleep 30",
        .background = true,
    } }, &cancel);
    try std.testing.expect(!started.is_error);
    try std.testing.expect(!started.cleanup_failed);
    const id = try receiptId(allocator, started.text);

    // Round 2: the same instance can query and stop exactly that service.
    const status = try app.executor.execute(allocator, .{ .background = .{ .action = .status, .id = id } }, &cancel);
    try std.testing.expect(!status.is_error);
    const logs = try app.executor.execute(allocator, .{ .background = .{ .action = .logs, .id = id } }, &cancel);
    try std.testing.expect(!logs.is_error);
    const stopped = try app.executor.execute(allocator, .{ .background = .{ .action = .stop, .id = id } }, &cancel);
    try std.testing.expect(!stopped.is_error);
    try std.testing.expect(!stopped.cleanup_failed);
    // Stopping one service is not the current Q&A being canceled.
    try std.testing.expect(!stopped.canceled);

    // A forged child Tools carries no registry: start and management stay closed.
    var child = app.executor;
    child.background = null;
    try std.testing.expectError(error.BackgroundDisabled, child.execute(allocator, .{ .bash = .{
        .command = "sleep 30",
        .background = true,
    } }, &cancel));
    try std.testing.expectError(error.BackgroundDisabled, child.execute(allocator, .{ .background = .{
        .action = .list,
    } }, &cancel));
}
