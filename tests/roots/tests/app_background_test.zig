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
    try std.testing.expectEqualStrings("background", schemas[schemas.len - 2].name);
    try std.testing.expectEqualStrings("edit_file", schemas[schemas.len - 1].name);
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
