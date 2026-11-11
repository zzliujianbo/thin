test "image codec exact wire, MIME, own budget and normalized usage" {
    const a = std.testing.allocator;
    inline for (.{ image.Format.png, image.Format.jpeg, image.Format.gif, image.Format.webp }) |format| {
        var input = fixture;
        input.image.format = format;
        const wire = try encode(a, input, null);
        defer a.free(wire);
        var tree = try std.json.parseFromSlice(std.json.Value, a, wire, .{});
        defer tree.deinit();
        const root = tree.value;
        try std.testing.expect(equal(try field(root, "model"), image.model_id));
        try std.testing.expect(!(try field(root, "stream")).bool);
        for ([_][]const u8{ "max_tokens", "max_completion_tokens", "max_output_tokens" }) |key| try std.testing.expect(!root.object.contains(key));
        try std.testing.expect(!root.object.contains("tools"));
        const messages = (try field(root, "messages")).array.items;
        try std.testing.expectEqual(@as(usize, 2), messages.len);
        const parts = (try field(messages[1], "content")).array.items;
        try std.testing.expectEqual(@as(usize, 2), parts.len);
        try std.testing.expect(equal(try field(parts[0], "text"), input.question));
        const expected = try std.fmt.allocPrint(a, "data:{s};base64,YWJj", .{format.mime()});
        defer a.free(expected);
        try std.testing.expect(equal(try field(try field(parts[1], "image_url"), "url"), expected));
    }
    const out = try decode(a, response);
    defer a.free(out.text);
    try std.testing.expectEqualStrings("visible text", out.text);
    try std.testing.expectEqual(@as(?u64, 100), out.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 10), out.usage.cached_input_tokens);
    try std.testing.expectEqual(@as(?u64, null), out.usage.cache_write_tokens);
    try std.testing.expectError(error.ImageContextTooLarge, encode(a, fixture, 100));
}
test "image codec rejects malformed, tool, limited and nontext responses" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "",                                                                                                                      "{}",                                                                                             "{",                                                                                                "{\"choices\":[]}",                                                                                    "{\"choices\":[{},{}]}",
        "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\"x\",\"tool_calls\":[]}}]}", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"user\",\"content\":\"x\"}}]}", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":[]}}]}", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\" \"}}]}",
    }) |bad| try std.testing.expectError(error.InvalidImageResponse, decode(a, bad));
    try std.testing.expectError(error.ImageOutputLimit, decode(a, "{\"choices\":[{\"finish_reason\":\"length\"}]}"));
}
test "image codec rejects oversized text invalid usage and unsafe input" {
    const a = std.testing.allocator;
    const text = try a.alloc(u8, image.max_result_bytes + 1);
    defer a.free(text);
    @memset(text, 'x');
    const oversized = try std.fmt.allocPrint(a, "{{\"choices\":[{{\"finish_reason\":\"stop\",\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}}}}]}}", .{text});
    defer a.free(oversized);
    try std.testing.expectError(error.InvalidImageResponse, decode(a, oversized));
    for ([_][]const u8{
        "{\"prompt_tokens\":-1}",
        "{\"completion_tokens\":1.5}",
        "{\"total_tokens\":\"3\"}",
        "{\"prompt_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":3}}",
        "{\"completion_tokens\":2,\"completion_tokens_details\":{\"reasoning_tokens\":3}}",
    }) |usage| {
        const bad = try std.fmt.allocPrint(a, "{{\"choices\":[{{\"finish_reason\":\"stop\",\"message\":{{\"role\":\"assistant\",\"content\":\"x\"}}}}],\"usage\":{s}}}", .{usage});
        defer a.free(bad);
        try std.testing.expectError(error.InvalidImageResponse, decode(a, bad));
    }
    var invalid = fixture;
    invalid.question = "\xff";
    try std.testing.expectError(error.InvalidImageQuestion, encode(a, invalid, null));
    invalid = fixture;
    invalid.image.width = image.max_dimension + 1;
    try std.testing.expectError(error.InvalidImageDimensions, encode(a, invalid, null));
}
test "image codec allocation failures release all intermediate buffers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
