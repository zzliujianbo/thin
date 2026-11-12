//! Owned fixtures for /settings backed only by the global config.json.
const profiles = @import("decision_selection.zig");

fn choose(session: *Session, choice: @import("../ui/tui.zig").Connection.DecisionChoice) !void {
    const connection = session.connection();
    try connection.decision_fn.?(connection.context, choice);
}

fn prepareNativeForTest(client: *@import("decision_client.zig").Client) !void {
    try std.testing.expect(client.native == null and client.resolved == null);
    var cancel: p.Cancellation = .{};
    const output = try client.service().decide(a, .{ .refine_outputs = &.{} }, &cancel);
    defer @import("../core/decision.zig").freeOutput(a, output);
    try std.testing.expect(output == .refine_outputs and output.refine_outputs.len == 0);
    try std.testing.expect(client.native != null and client.resolved != null);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}

const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const Session = @import("session.zig").Session;
const App = @import("app.zig").App;
const Store = @import("auth_store.zig").Store;
const a = std.testing.allocator;
const io = std.testing.io;
const plain =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-owned-only","models":{"first":{"protocol":"chat","context_tokens":65536},"second":{"protocol":"chat","context_tokens":131072}}}}}}
;
const native_declared =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-owned-only","models":{"first":{"protocol":"chat","context_tokens":65536}}},"reviewer":{"base_url":"https://opencode.ai/inference/systemone/v1","api_key":"fake-native-own-key","models":{"arbitrary/raw":{"protocol":"systemone"}}}}}}
;
const reviewed =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-owned-only","models":{"first":{"protocol":"anthropic","context_tokens":65536},"judge":{"protocol":"chat","context_tokens":32768}}}}},"decision":{"model":"route/judge"}}
;
fn seed(home: []const u8, config: []const u8, legacy: ?[]const u8) !void {
    var store = try Store.open(a, io, home);
    defer store.deinit();
    try store.root.writeMode(cfg.file_name, config, false, 0o600);
    if (legacy) |bytes| try store.root.writeMode("settings.json", bytes, false, 0o600);
}
fn read(home: []const u8, name: []const u8) ![]const u8 {
    var store = try Store.openExisting(a, io, home);
    defer store.deinit();
    return try store.root.readBinaryGuarded(a, name, null, null);
}
fn toggle(session: *Session, setting: @import("../ui/tui.zig").Connection.Setting, enabled: bool) !void {
    const connection = session.connection();
    try connection.setting_fn.?(connection.context, setting, enabled);
}
