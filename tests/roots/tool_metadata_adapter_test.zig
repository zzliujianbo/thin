//! Offline adapter-only tool preview contract; run directly with zig test.
const std = @import("std");
const p = @import("core/protocol.zig");
const chat = @import("llm/chat.zig");
const responses = @import("llm/responses.zig");
const anthropic = @import("llm/anthropic.zig");
const names = [_][]const u8{ "bash", "read_file", "memory", "write_file" };
fn scope(protocol: p.Protocol) p.ReplayScope {
    return .{ .connection = "offline", .model = "metadata", .protocol = protocol };
}
const Capture = struct {
    name: []const u8,
    id: ?[]const u8 = "call",
    count: usize = 0,
    bytes: usize = 0,
    fn emit(ctx: ?*anyopaque, event: p.ModelEvent) !void {
        if (event != .tool_delta) return;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const d = event.tool_delta;
        try std.testing.expectEqualStrings(self.name, d.name);
        if (self.id) |id| try std.testing.expectEqualStrings(id, d.call_id.?) else try std.testing.expect(d.call_id == null);
        try std.testing.expectEqual(@as(usize, 0), d.index);
        try std.testing.expectEqual(std.mem.eql(u8, self.name, "write_file"), d.write_file);
        self.bytes += d.arguments.len;
        try std.testing.expectEqual(@as(?usize, self.bytes), d.argument_bytes);
        self.count += 1;
    }
    fn sink(self: *@This()) p.ModelSink {
        return .{ .context = self, .emit_fn = emit };
    }
};
fn chatDelta(s: *chat.Stream, a: std.mem.Allocator, tool: []const u8) !void {
    try s.feed("", try std.fmt.allocPrint(a, "{{\"choices\":[{{\"index\":0,\"delta\":{{\"tool_calls\":[{s}]}}}}]}}", .{tool}));
}
fn finishChat(s: *chat.Stream) !p.Response {
    try s.feed("", "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}");
    try s.feed("", "[DONE]");
    return (try s.finish()).success;
}
fn canonical(response: p.Response, name: []const u8) !void {
    const call = response.message.blocks[0].tool_call;
    try std.testing.expectEqualStrings(name, call.name);
    try std.testing.expectEqualStrings("call", call.id);
    try std.testing.expectEqualStrings("{}", call.arguments);
}
