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

test "chat generic metadata cumulative name fragments headers and argument counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (names) |name| {
        var capture = Capture{ .name = name[0..1], .id = null };
        var s = chat.Stream.init(a, scope(.chat), capture.sink());
        try chatDelta(&s, a, try std.fmt.allocPrint(a, "{{\"index\":0,\"function\":{{\"name\":\"{s}\"}}}}", .{name[0..1]}));
        capture.name = name;
        try chatDelta(&s, a, try std.fmt.allocPrint(a, "{{\"index\":0,\"function\":{{\"name\":\"{s}\",\"arguments\":\"\"}}}}", .{name[1..]}));
        capture.id = "call";
        // An id-only header must publish the accumulated name, too.
        try chatDelta(&s, a, "{\"index\":0,\"id\":\"call\"}");
        try std.testing.expectEqual(@as(usize, 3), capture.count);
        try chatDelta(&s, a, "{\"index\":0,\"function\":{\"arguments\":\"{\"}}");
        try chatDelta(&s, a, "{\"index\":0,\"function\":{\"arguments\":\"}\"}}");
        try std.testing.expectEqual(@as(usize, 5), capture.count);
        try canonical(try finishChat(&s), name);
    }
}

test "chat oversized metadata degrades only preview and unrelated fields emit nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = try a.alloc(u8, 1025);
    @memset(name, 'n');
    var capture = Capture{ .name = "" };
    var s = chat.Stream.init(a, scope(.chat), capture.sink());
    try chatDelta(&s, a, "{\"index\":0,\"function\":{},\"extension\":true}");
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    const observed = s.observed;
    try chatDelta(&s, a, try std.fmt.allocPrint(a, "{{\"index\":0,\"id\":\"call\",\"function\":{{\"name\":\"{s}\"}}}}", .{name}));
    // Existing observed semantics are not changed by preview metadata.
    try std.testing.expect(observed and s.observed);
    for (0..32) |_| try chatDelta(&s, a, "{\"index\":0,\"function\":{\"arguments\":\"\"}}");
    try chatDelta(&s, a, "{\"index\":0,\"function\":{\"arguments\":\"{}\"}}");
    try std.testing.expectEqual(@as(usize, 34), capture.count);
    try canonical(try finishChat(&s), name);
}

test "responses generic metadata empty headers and argument counts match canonical call id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (names) |name| {
        var capture = Capture{ .name = name };
        var s = responses.Stream.init(a, scope(.responses), capture.sink());
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"call\",\"name\":\"{s}\",\"arguments\":\"\"}}}}", .{name}));
        try std.testing.expectEqual(@as(usize, 1), capture.count);
        for ([_][]const u8{ "{", "}" }) |arg| try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"item\",\"delta\":\"{s}\"}}", .{arg}));
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"response.completed\",\"response\":{{\"status\":\"completed\",\"output\":[{{\"type\":\"function_call\",\"status\":\"completed\",\"id\":\"item\",\"call_id\":\"call\",\"name\":\"{s}\",\"arguments\":\"{{}}\"}}]}}}}", .{name}));
        try std.testing.expectEqual(@as(usize, 3), capture.count);
        try canonical((try s.finish()).success, name);
    }
}

test "anthropic generic metadata empty headers and argument counts use tool ordinal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (names) |name| {
        var capture = Capture{ .name = name };
        var s = anthropic.Stream.init(a, scope(.anthropic), capture.sink());
        try s.feed("", "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}");
        try s.feed("", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}");
        try s.feed("", "{\"type\":\"content_block_stop\",\"index\":0}");
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"{s}\",\"input\":{{}}}}}}", .{name}));
        try std.testing.expectEqual(@as(usize, 1), capture.count);
        for ([_][]const u8{ "{", "}" }) |arg| try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{s}\"}}}}", .{arg}));
        try s.feed("", "{\"type\":\"content_block_stop\",\"index\":1}");
        try s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}");
        try s.feed("", "{\"type\":\"message_stop\"}");
        try std.testing.expectEqual(@as(usize, 3), capture.count);
        try canonical((try s.finish()).success, name);
    }
}
