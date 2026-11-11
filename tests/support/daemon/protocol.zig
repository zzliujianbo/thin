const tool_stream = @import("../core/tool_stream.zig");

fn manyBlocksJson(a: std.mem.Allocator, count: usize) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\"t\":\"assistant\",\"blocks\":[");
    for (0..count) |i| {
        if (i != 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"k\":\"text\",\"v\":\"block\"}");
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

fn expectEventRoundTrip(a: std.mem.Allocator, event: r.Event) !void {
    const first = try encodeEvent(a, event);
    defer a.free(first);
    var decoded = try decodeEvent(a, first);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 0), decoded.epoch);
    try std.testing.expect(!decoded.display_truncated);
    try std.testing.expect(decoded.canonical_complete);
    const second = try encodeEvent(a, decoded.event);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
}

fn decodeAssistantOwned(a: std.mem.Allocator, json: []const u8) !void {
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    const blocks = decoded.event.assistant_committed;
    const document_blocks = decoded.doc.value.object.get("blocks").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(blocks.len, document_blocks.len);
    for (blocks, document_blocks) |block, document_block| {
        try std.testing.expectEqualStrings("block", block.text);
        try std.testing.expect(block.text.ptr == document_block.object.get("v").?.string.ptr);
    }
}

fn parseWholeReply(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}
