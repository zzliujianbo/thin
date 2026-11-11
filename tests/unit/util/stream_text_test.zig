test "all cuts match shared sanitizer, including invalid and controls" {
    const a = std.testing.allocator;
    const input = "xé中文👩‍💻\r\n\rZ\x1b\x18\x7f\xe2\x82A\xf0\x80\x80\x80\xff\t";
    const expected = try display.sanitize(a, input, 4096);
    defer a.free(expected);
    for (0..input.len + 1) |cut| {
        var d: Decoder = .{};
        var sink: TestSink = .{};
        defer sink.deinit();
        try d.feed(input[0..cut], &sink, TestSink.emit);
        try d.feed(input[cut..], &sink, TestSink.emit);
        try d.finish(&sink, TestSink.emit);
        try std.testing.expectEqualStrings(expected, sink.bytes.items);
    }
    var d: Decoder = .{};
    var sink: TestSink = .{};
    defer sink.deinit();
    for (input) |*b| try d.feed(b[0..1], &sink, TestSink.emit);
    try d.finish(&sink, TestSink.emit);
    try std.testing.expectEqualStrings(expected, sink.bytes.items);
}
test "finish clone previews without consuming CR or incomplete UTF8" {
    var d: Decoder = .{};
    var live: TestSink = .{};
    defer live.deinit();
    try d.feed("\r", &live, TestSink.emit);
    var preview = d;
    var p: TestSink = .{};
    defer p.deinit();
    try preview.finish(&p, TestSink.emit);
    try std.testing.expectEqualStrings("�", p.bytes.items);
    try d.feed("\n\xf0\x9f", &live, TestSink.emit);
    preview = d;
    p.bytes.clearRetainingCapacity();
    try preview.finish(&p, TestSink.emit);
    try std.testing.expectEqualStrings("��", p.bytes.items);
    try d.feed("\x98\x80", &live, TestSink.emit);
    try std.testing.expectEqualStrings("\n😀", live.bytes.items);
}
test "failed emit requires clone and staged output; raw remains caller owned" {
    var d: Decoder = .{};
    var sink: TestSink = .{};
    defer sink.deinit();
    try d.feed("\xf0\x9f", &sink, TestSink.emit);
    var trial = d;
    sink.fail = true;
    const raw = "\x98\x80";
    try std.testing.expectError(error.TestFailure, trial.feed(raw, &sink, TestSink.emit));
    try std.testing.expectEqual(@as(usize, 2), d.carry_len);
    sink.fail = false;
    trial = d;
    try trial.feed(raw, &sink, TestSink.emit);
    d = trial;
    try std.testing.expectEqualStrings("😀", sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), d.carry_len);
}
