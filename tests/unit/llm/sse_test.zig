test "SSE accepts byte-by-byte UTF8 CRLF BOM comments and multiline data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = Capture{ .allocator = arena.allocator() };
    var decoder = Decoder.init(std.testing.allocator, 1024, capture.sink());
    defer decoder.deinit();

    const bytes = "\xef\xbb\xbf: hello\r\nevent: delta\r\ndata: 中文\r\ndata: two\r\n\r\ndata: [DONE]\n\n";
    for (bytes) |byte| try decoder.feed(&.{byte});
    try decoder.finish();

    try std.testing.expectEqual(@as(usize, 2), capture.values.items.len);
    try std.testing.expectEqualStrings("delta", capture.names.items[0]);
    try std.testing.expectEqualStrings("中文\ntwo", capture.values.items[0]);
    try std.testing.expectEqualStrings("message", capture.names.items[1]);
    try std.testing.expectEqualStrings("[DONE]", capture.values.items[1]);
}
test "SSE rejects oversized and truncated events without dispatching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = Capture{ .allocator = arena.allocator() };
    var decoder = Decoder.init(std.testing.allocator, 20, capture.sink());
    defer decoder.deinit();

    try decoder.feed("data: unfinished");
    try std.testing.expectError(error.IncompleteSseEvent, decoder.finish());
    try std.testing.expectEqual(@as(usize, 0), capture.values.items.len);
    try std.testing.expectError(error.EventTooLarge, decoder.feed(" more and more"));
}
test "SSE unlimited decoder accepts an event beyond the old cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = Capture{ .allocator = arena.allocator() };
    var decoder = Decoder.init(std.testing.allocator, null, capture.sink());
    defer decoder.deinit();
    const payload = try arena.allocator().alloc(u8, 1024 * 1024 + 1);
    @memset(payload, 'x');
    try decoder.feed("data: ");
    try decoder.feed(payload);
    try decoder.feed("\n\n");
    try decoder.finish();
    try std.testing.expectEqual(@as(usize, 1), capture.values.items.len);
    try std.testing.expectEqualStrings(payload, capture.values.items[0]);
}
test "SSE empty data and lone CR delimiters are valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = Capture{ .allocator = arena.allocator() };
    var decoder = Decoder.init(std.testing.allocator, 20, capture.sink());
    defer decoder.deinit();

    try decoder.feed("data\r\r");
    try decoder.finish();
    try std.testing.expectEqual(@as(usize, 1), capture.values.items.len);
    try std.testing.expectEqualStrings("", capture.values.items[0]);
}
