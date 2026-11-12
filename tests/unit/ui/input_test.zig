test "AltEnter is distinct across split sequences and suppressed in paste and secret modes" {
    var record = Record{};
    var parser = Parser{};
    const sink = Sink{ .context = &record, .emit_fn = Record.event };
    for ("\x1b\r\x1b\n\x1b[13;3u") |byte_| try parser.feed(&.{byte_}, sink);
    try std.testing.expectEqual(@as(usize, 3), record.follow_ups);
    try std.testing.expectEqual(@as(usize, 0), record.enters);
    try parser.feed("\x1b[200~\x1b\r\x1b[13;3u\x1b[201~", sink);
    try std.testing.expectEqual(@as(usize, 3), record.follow_ups);
    try parser.feed("\x1b[13;", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 3), record.follow_ups);
    parser.secretMode(true);
    try parser.feed("\x1b\r\x1b\n\x1b[13;3u", sink);
    try std.testing.expectEqual(@as(usize, 3), record.follow_ups);
}
test "split UTF8 and bracketed paste cannot submit, cancel or authorize" {
    var record = Record{};
    var parser = Parser{};
    const sink = Sink{ .context = &record, .emit_fn = Record.event };

    const sequence = "你好\x1b[200~y\r\ny\x03\x1b[A\x1b[201~\r\x03";
    for (sequence) |b| try parser.feed(&.{b}, sink);

    try std.testing.expectEqualStrings("你好y\ny", record.data[0..record.len]);
    try std.testing.expectEqual(@as(usize, 1), record.enters);
    try std.testing.expectEqual(@as(usize, 1), record.cancels);
    try std.testing.expect(record.pasted > 0);
}
test "pasted CRLF requires immediate byte adjacency across feeds" {
    const cases = .{
        .{ "A\r你\nB", "A\n你\nB" },
        .{ "A\r\nB", "A\nB" },
        .{ "A\r\r\nB", "A\n\nB" },
        .{ "A\r\x1b[A\nB", "A\n\nB" },
        .{ "A\r\xe4\nB", "A\n\nB" },
    };
    inline for (cases) |case| {
        for ([_]bool{ false, true }) |split| {
            var record = Record{};
            var parser = Parser{};
            const sink = Sink{ .context = &record, .emit_fn = Record.event };
            const sequence = "\x1b[200~" ++ case[0] ++ "\x1b[201~";
            if (split) {
                for (sequence) |b| try parser.feed(&.{b}, sink);
            } else try parser.feed(sequence, sink);
            try std.testing.expectEqualStrings(case[1], record.data[0..record.len]);
            try std.testing.expectEqual(@as(usize, 0), record.enters);
            try std.testing.expectEqual(@as(usize, 0), record.cancels);
        }
    }
}
test "split ShiftTab cannot change secret settings and only fresh Escape cancels" {
    var record = Record{};
    var parser = Parser{};
    const sink = Sink{ .context = &record, .emit_fn = Record.event };
    for ("\x1b[Z\x1b[1;2Z\x1b[9;2u") |byte| try parser.feed(&.{byte}, sink);
    try std.testing.expectEqual(@as(usize, 3), record.cycles);
    try parser.feed("\x1b[200~\x1b[Z\x1b[201~", sink);
    try std.testing.expectEqual(@as(usize, 3), record.cycles);
    try parser.feed("\x1b[", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 0), record.escapes);
    try parser.feed("Z", sink);
    try std.testing.expectEqual(@as(usize, 4), record.cycles);
    try parser.feed("\x1b", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 1), record.escapes);
    parser.secretMode(true);
    try parser.feed("\x1b[Z", sink);
    try parser.feed("\x1b", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 4), record.cycles);
    try std.testing.expectEqual(@as(usize, 2), record.escapes);
    try parser.feed("\x1b[200~key\x1b[201~\x1b", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 2), record.escapes);
    parser.secretMode(true);
    try parser.feed("\x1b[200~\x1b", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 2), record.escapes);
    parser.secretMode(true);
    try parser.feed("\x1b[", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 2), record.escapes);
}
test "paste-tail escape provenance survives split CSI and AltEnter without blocking fresh keys" {
    for ([_]bool{ false, true }) |secret| {
        var record: Record = .{};
        var parser: Parser = .{};
        if (secret) parser.secretMode(true);
        const sink: Sink = .{ .context = &record, .emit_fn = Record.event };
        try parser.feed("\x1b[200~\x1b[201~\x1b[", sink);
        try parser.feed("Z", sink);
        try std.testing.expectEqual(@as(usize, 0), record.cycles);
        try parser.feed("\x1b[200~\x1b[201~\x1b", sink);
        try parser.feed("\r", sink);
        try std.testing.expectEqual(@as(usize, 0), record.follow_ups);
        try parser.feed("\x1b[Z", sink);
        try std.testing.expectEqual(@as(usize, if (secret) 0 else 1), record.cycles);
        try parser.feed("\x1b\r", sink);
        try std.testing.expectEqual(@as(usize, if (secret) 0 else 1), record.follow_ups);
    }
}
test "delayed paste framing escapes still parse and tainted timeout is consumed" {
    for ([_]bool{ false, true }) |secret| {
        var record: Record = .{};
        var parser: Parser = .{};
        if (secret) parser.secretMode(true);
        const sink: Sink = .{ .context = &record, .emit_fn = Record.event };
        try parser.feed("\x1b[200~\x1b", sink);
        try parser.expireEscape(sink); // Could still be a split paste terminator.
        try std.testing.expect(parser.pasted and parser.escape_len == 1);
        for ("[201~") |byte_| try parser.feed(&.{byte_}, sink);
        try std.testing.expect(!parser.pasted and parser.escape_len == 0);
        try parser.feed("\x1b[200~\x1b[201~\x1b", sink);
        try parser.feed("", sink); // Reset per-read flags, not escape provenance.
        try parser.expireEscape(sink);
        try std.testing.expectEqual(@as(usize, 0), record.escapes);
        try std.testing.expectEqual(@as(usize, 0), parser.escape_len);
        try parser.feed("", sink);
        try parser.expireEscape(sink);
        try std.testing.expectEqual(@as(usize, 0), record.escapes);
        try parser.feed("\x1b", sink);
        try parser.expireEscape(sink);
        try std.testing.expectEqual(@as(usize, 1), record.escapes);
    }
}
test "editor preserves UTF8 cluster boundaries and accepts large input" {
    try text.initLocale();

    var editor = Editor{ .allocator = std.testing.allocator };
    defer editor.deinit();

    try std.testing.expect(try editor.insert("a你e\u{301}"));
    editor.backspace();
    try std.testing.expectEqualStrings("a你", editor.bytes.items);

    editor.left();
    editor.delete();
    try std.testing.expectEqualStrings("a", editor.bytes.items);

    const huge: [65536]u8 = @splat('x');
    try std.testing.expect(try editor.insert(&huge));
    try std.testing.expectEqual(@as(usize, 65537), editor.bytes.items.len);
    try std.testing.expectEqual(@as(u8, 'a'), editor.bytes.items[0]);
    try std.testing.expectEqual(@as(u8, 'x'), editor.bytes.items[65536]);
}
test "editor allocation failure preserves draft and cursor" {
    var editor = Editor{ .allocator = std.testing.allocator };
    defer editor.deinit();
    try std.testing.expect(try editor.insert("a你"));
    editor.left();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    editor.allocator = failing.allocator();
    defer editor.allocator = std.testing.allocator;
    const large: [65537]u8 = @splat('x');
    try std.testing.expectError(error.OutOfMemory, editor.insert(&large));
    try std.testing.expectEqualStrings("a你", editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
}
test "secret storage erases removed bytes and fails closed on invalid input and overflow" {
    var secret = SecretInput{};
    defer secret.deinit();
    secret.insert("abc");
    secret.erase();
    try std.testing.expectEqualStrings("ab", secret.value().?);
    try std.testing.expectEqual(@as(u8, 0), secret.bytes[2]);
    secret.wipe();
    const full: [16384]u8 = @splat('x');
    secret.insert(&full);
    try std.testing.expectEqual(@as(usize, 16384), secret.len);
    secret.insert("x");
    try std.testing.expect(secret.failed and secret.value() == null);
    for (secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    secret.insert("not-a-recovery");
    try std.testing.expect(secret.value() == null);
    secret.wipe();
    secret.insert("abc\n");
    try std.testing.expect(secret.failed and secret.len == 0);
    secret.wipe();
    secret.insert("abc");
    secret.deinit();
    for (secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
test "secret parser transitions erase scratch and discard the rest of the feed" {
    const State = struct {
        parser: *Parser,
        events: usize = 0,
        fn emit(ctx: *anyopaque, _: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.events += 1;
            self.parser.secretMode(false);
        }
    };
    var parser = Parser{};
    parser.secretMode(true);
    var state = State{ .parser = &parser };
    try parser.feed("\xc3\xa9trailing-secret", .{ .context = &state, .emit_fn = State.emit });
    try std.testing.expectEqual(@as(usize, 1), state.events);
    for (parser.utf8) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (parser.escape) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
test "secret paste control bytes and embedded terminator enter never become save" {
    var record = Record{};
    var parser = Parser{};
    parser.secretMode(true);
    const sink = Sink{ .context = &record, .emit_fn = Record.event };
    try parser.feed("\x1b[200~key\x00\r\n\x1b[201~\r", sink);
    try std.testing.expectEqual(@as(usize, 0), record.enters);
    try std.testing.expect(std.mem.findScalar(u8, record.data[0..record.len], 0) != null);
    try parser.feed("\xff", sink);
    try std.testing.expectEqual(@as(u8, 0), record.data[record.len - 1]);
}
