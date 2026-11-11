const std = @import("std");
const adapter = @import("anthropic.zig");
const p = @import("../core/protocol.zig");
const j = @import("../util/json.zig");
const c = @import("common.zig");
const scope: p.ReplayScope = .{ .connection = "offline", .model = "fixture", .protocol = .anthropic };
const start = "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":5,\"cache_creation_input_tokens\":3,\"cache_read_input_tokens\":7,\"output_tokens\":0}}}";
fn request() p.Request {
    // Synthetic verified capacity for this fixture model, not a request cap.
    return .{ .scope = scope, .system = "system", .tools = &.{}, .messages = &.{}, .model_output_tokens = 100 };
}

fn end(s: *adapter.Stream, reason: []const u8) !void {
    const data = try std.fmt.allocPrint(s.a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":4}}}}", .{reason});
    try s.feed("", data);
    try s.feed("", "{\"type\":\"message_stop\"}");
}
fn block(s: *adapter.Stream, index: usize, native: []const u8) !void {
    try s.feed("", try std.fmt.allocPrint(s.a, "{{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{s}}}", .{ index, native }));
}
fn stop(s: *adapter.Stream, index: usize) !void {
    try s.feed("", try std.fmt.allocPrint(s.a, "{{\"type\":\"content_block_stop\",\"index\":{d}}}", .{index}));
}
fn delta(s: *adapter.Stream, index: usize, native: []const u8) !void {
    try s.feed("", try std.fmt.allocPrint(s.a, "{{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{s}}}", .{ index, native }));
}

fn allocationFixture(a: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    var s = adapter.Stream.init(t, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"text\",\"text\":\"hello\"}");
    try stop(&s, 0);
    try block(&s, 1, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"YW\"}");
    try delta(&s, 1, "{\"type\":\"signature_delta\",\"signature\":\"Jj\"}");
    try delta(&s, 1, "{\"type\":\"signature_delta\",\"signature\":\"ZA==\"}");
    try stop(&s, 1);
    try end(&s, "end_turn");
    var req = request();
    req.messages = &.{(try s.finish()).success.message};
    _ = try adapter.encode(t, req);
}
