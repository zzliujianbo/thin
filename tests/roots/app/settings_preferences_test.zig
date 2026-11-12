//! Offline preference ownership/atomicity fixtures. Never use the real HOME.
const std = @import("std");
const cfg = @import("../core/config.zig");
const preference = @import("../core/settings.zig");
const profiles = @import("decision_selection.zig");
const Session = @import("session.zig").Session;
const Store = @import("auth_store.zig").Store;
const p = @import("../core/protocol.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const plain =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-owned-only","models":{"first":{"protocol":"chat","context_tokens":65536},"judge":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
;
const reviewed = plain[0 .. plain.len - 1] ++ ",\"decision\":{\"model\":\"route/judge\"}}";
const Edit = struct { key: preference.Key, value: ?u32 };
const main_edits = [_]Edit{
    .{ .key = .memory_auto, .value = 0 },
    .{ .key = .compaction_enabled, .value = 0 },
    .{ .key = .command_timeout_ms, .value = 10000 },
    .{ .key = .request_timeout_ms, .value = 20000 },
};
fn set(session: *Session, key: preference.Key, value: ?u32) !void {
    const c = session.connection();
    try c.preference_fn.?(c.context, key, value);
}
fn disk(session: *Session) ![]const u8 {
    return try session.store.root.readBinaryGuarded(a, cfg.file_name, null, null);
}
fn seed(home: []const u8, bytes: []const u8) !void {
    var store = try Store.open(a, io, home);
    defer store.deinit();
    try store.root.writeMode(cfg.file_name, bytes, false, 0o600);
}

fn pendingCloneAllocationCase(allocator: std.mem.Allocator) !void {
    var declaration = try cfg.parse(allocator, reviewed);
    defer cfg.release(&declaration);
    var pending = declaration.value;
    pending.provider = .{ .base_url = "", .api_key_env = "" };
    pending.selection_pending = false;
    try std.testing.expectError(error.InvalidConfig, cfg.clonePendingSettings(allocator, pending));
    pending.selection_pending = true;
    var owned = try profiles.activeClone(allocator, pending, declaration.value);
    defer cfg.release(&owned);
    try std.testing.expect(owned.value.model.name.ptr != pending.model.name.ptr);
    try std.testing.expect(owned.value.registry.?.providers.ptr != declaration.value.registry.?.providers.ptr);
    try std.testing.expectError(error.InvalidBaseUrl, cfg.validate(owned.value));
    try std.testing.expectError(error.InvalidBaseUrl, cfg.clone(allocator, owned.value));
}
