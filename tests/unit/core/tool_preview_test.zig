test "all two-chunk splits and byte-by-byte decoded keys scalars nested values" {
    const json = "{\"pa\\u0074h\":\"目录/\\uD83D\\uDE00/\\\\\\\"\\n\",\"content\":\"fake \\\"path\\\":\\\"evil\\\"\",\"other\":[{\"path\":42},true,false,null,-1.25e+3,0],\"command\":\"echo hi\",\"action\":\"\",\"topic\":\"中\"} \r\n";
    for (0..json.len + 1) |split| {
        var e: Extractor = .{};
        e.feed(json[0..split]);
        e.feed(json[split..]);
        try std.testing.expect(e.finish());
        try checkGolden(&e);
    }
    var e: Extractor = .{};
    for (json) |b| e.feed(&.{b});
    try std.testing.expect(e.finish());
    try checkGolden(&e);
}
test "content hook receives decoded scalars close and revocation without storing content" {
    const Hook = struct {
        scalars: usize = 0,
        newlines: usize = 0,
        ended: bool = false,
        revoked: bool = false,
        fn scalar(ctx: *anyopaque, cp: u21) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.scalars += 1;
            self.newlines += @intFromBool(cp == '\n');
        }
        fn end(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ended = true;
        }
        fn revoke(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.revoked = true;
        }
    };
    var hook: Hook = .{};
    var e: Extractor = .{};
    e.attachContent(&hook, Hook.scalar, Hook.end, Hook.revoke);
    const json = "{\"path\":\"x\",\"content\":\"中\\n\\uD83D\\uDE00\"}";
    for (json) |byte| e.feed(&.{byte});
    try std.testing.expect(e.finish());
    try std.testing.expectEqual(@as(usize, 3), hook.scalars);
    try std.testing.expectEqual(@as(usize, 1), hook.newlines);
    try std.testing.expect(hook.ended and !hook.revoked);
    try std.testing.expect(e.snapshot().path != null);

    hook = .{};
    var bad: Extractor = .{};
    bad.attachContent(&hook, Hook.scalar, Hook.end, Hook.revoke);
    bad.feed("{\"content\":\"a\",\"content\":\"b\"}");
    try std.testing.expect(!bad.finish());
    try std.testing.expect(hook.revoked);
}
test "task is previewed while context body is not" {
    const json = "{\"task\":\"inspect release path\",\"context\":\"parent notes with \\\"quotes\\\"\"}";
    for (0..json.len + 1) |split| {
        var e: Extractor = .{};
        e.feed(json[0..split]);
        e.feed(json[split..]);
        try std.testing.expect(e.finish());
        const s = e.snapshot();
        try std.testing.expectEqualStrings("inspect release path", s.task.?.text);
        try std.testing.expect(s.path == null and s.command == null and s.action == null and s.topic == null and s.id == null);
    }
}
test "job id is previewed while message and reply bodies are not" {
    const json = "{\"id\":\"job-7\",\"message\":\"private-body\",\"wait\":true,\"wait_for_reply\":false}";
    for (0..json.len + 1) |split| {
        var e: Extractor = .{};
        e.feed(json[0..split]);
        e.feed(json[split..]);
        try std.testing.expect(e.finish());
        const s = e.snapshot();
        try std.testing.expectEqualStrings("job-7", s.id.?.text);
        try std.testing.expect(s.task == null and s.path == null);
    }
}
test "unknown content and nested names never publish and long keys do not alias" {
    const json = "{\"content\":\"\\\"path\\\":\\\"fake\\\"\",\"expected_version\":\"path\",\"nested\":[{\"path\":\"wrong\",\"command\":\"wrong\"}],\"pathTOOLONG\":\"wrong\",\"commandx\":\"wrong\",\"unknown\":[0,-0,10,-10,1.2,1E2,1e-2,true,false,null,{},[]]}";
    for (0..json.len + 1) |split| {
        var e: Extractor = .{};
        e.feed(json[0..split]);
        e.feed(json[split..]);
        try std.testing.expect(e.finish());
        try expectEmpty(&e);
    }
    var escaped: Extractor = .{};
    const keys = " \t{\"co\\u006dmand\":\"\\b\\f\\n\\r\\t\\/\\u0000\",\"\\u0061ction\":\"😀\",\"to\\u0070ic\":\"\\u4e2d\"}";
    for (keys) |b| escaped.feed(&.{b});
    try std.testing.expect(escaped.finish());
    try std.testing.expectEqualStrings("\x08\x0c\n\r\t/\x00", escaped.snapshot().command.?.text);
    try std.testing.expectEqualStrings("😀", escaped.snapshot().action.?.text);
    try std.testing.expectEqualStrings("中", escaped.snapshot().topic.?.text);
}
test "closed path available during 100KiB content without storing it" {
    var e: Extractor = .{};
    e.feed("{\"path\":\"safe\",\"content\":\"");
    try std.testing.expectEqualStrings("safe", e.snapshot().path.?.text);
    const block: [1024]u8 = @splat('x');
    for (0..100) |_| e.feed(&block);
    e.feed("\\\"path\\\":\\\"evil\\\"\",\"expected_version\":123,\"nested\":{\"path\":\"wrong\"}}");
    try std.testing.expect(e.finish());
    try std.testing.expectEqualStrings("safe", e.snapshot().path.?.text);
    try std.testing.expectEqual(@as(usize, 4), e.lengths[0]);
    try std.testing.expectEqual(@as(usize, 6 * 1024), @sizeOf(@TypeOf(e.buffers)));
}
test "strict invalid cases revoke all fields at every split and stay invalid" {
    const cases = [_][]const u8{
        "[]",                                   "null",                                       "{\"path\":1}",                 "{\"path\":null}",               "{\"path\":{}}",       "{\"path\":[]}",
        "{\"path\":\"ok\",\"path\":\"again\"}", "{\"path\":\"ok\",\"pa\\u0074h\":\"again\"}", "{\"path\":\"ok\"}x",           "{\"path\":\"ok\"}{}",           "{\"path\":\"ok\",}",  "{\"path\":\"ok\",\"x\":[1,]}",
        "{\"path\":\"ok\",\"x\":01}",           "{\"x\":-}",                                  "{\"x\":1.}",                   "{\"x\":1e}",                    "{\"x\":1e+}",         "{\"x\":tru}",
        "{\"x\":truefalse}",                    "{\"x\":NaN}",                                "{\"x\":+1}",                   "{\"x\":1 2}",                   "{\"x\":[}}",          "{\"path\":\"ok\",\"content\":\"\\q\"}",
        "{\"path\":\"\\uDC00\"}",               "{\"path\":\"\\uD800x\"}",                    "{\"path\":\"\\uD800\\n\"}",    "{\"path\":\"\\uD800\\u0041\"}", "{\"x\":\"\\uZZZZ\"}", "{\"x\":\"\n\"}",
        "{\"x\":\"\xc0\xaf\"}",                 "{\"x\":\"\xed\xa0\x80\"}",                   "{\"x\":\"\xf4\x90\x80\x80\"}", "{\"x\":\"\xe0\x80\x80\"}",      "{\"x\":\"\x80\"}",    "{\"x\":\"\xc2x\"}",
        "{\"\xff\":0}",                         "{\"x\":\"\xf5\x80\x80\x80\"}",
    };
    for (cases) |json| {
        for (0..json.len + 1) |split| {
            var e: Extractor = .{};
            e.feed(json[0..split]);
            e.feed(json[split..]);
            try std.testing.expect(!e.finish());
            try expectEmpty(&e);
            e.feed("{}");
            try std.testing.expect(!e.finish());
            try expectEmpty(&e);
        }
        var e: Extractor = .{};
        for (json) |b| e.feed(&.{b});
        try std.testing.expect(!e.finish());
        try expectEmpty(&e);
    }
}
test "unfinished input is not invalid until finish and no unclosed value leaks" {
    const json = "{\"path\":\"safe\",\"topic\":\"中\\uD83D\\uDE00\"}";
    for (0..json.len) |end| {
        var e: Extractor = .{};
        e.feed(json[0..end]);
        try std.testing.expect(!e.invalid);
        try std.testing.expect(!e.finish());
        try expectEmpty(&e);
    }
    var e: Extractor = .{};
    e.feed("{\"path\":\"unclosed");
    try expectEmpty(&e);
    e.feed("\"");
    try std.testing.expectEqualStrings("unclosed", e.snapshot().path.?.text);
    e.feed("}");
    try std.testing.expect(e.finish());
    e.feed(" \n\t\r");
    try std.testing.expect(e.finish());
    e.feed("!");
    try expectEmpty(&e);
}
test "bounded depth valid at limit invalid beyond limit" {
    var e: Extractor = .{};
    e.feed("{\"path\":\"ok\",\"x\":");
    for (1..max_depth) |_| e.feed("[");
    e.feed("0");
    for (1..max_depth) |_| e.feed("]");
    e.feed("}");
    try std.testing.expect(e.finish());
    var bad: Extractor = .{};
    bad.feed("{\"path\":\"ok\",\"x\":");
    for (0..max_depth) |_| bad.feed("[");
    try std.testing.expect(bad.invalid);
    try expectEmpty(&bad);
}
test "UTF8 prefix truncation is scalar aligned and validation continues" {
    for (0..4) |room| {
        var e: Extractor = .{};
        e.feed("{\"path\":\"");
        for (0..capacity - room) |_| e.feed("a");
        for ("😀") |b| e.feed(&.{b});
        e.feed("z\",\"command\":\"done\"}");
        try std.testing.expect(e.finish());
        const f = e.snapshot().path.?;
        try std.testing.expect(f.truncated);
        try std.testing.expectEqual(capacity - room, f.text.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(f.text));
        try std.testing.expectEqualStrings("done", e.snapshot().command.?.text);
    }
    var exact: Extractor = .{};
    exact.feed("{\"path\":\"");
    for (0..capacity / 4) |_| exact.feed("\\uD83D\\uDE00");
    exact.feed("\"}");
    try std.testing.expect(exact.finish());
    try std.testing.expectEqual(capacity, exact.snapshot().path.?.text.len);
    try std.testing.expect(!exact.snapshot().path.?.truncated);
    var bad: Extractor = .{};
    bad.feed("{\"path\":\"");
    for (0..capacity + 1) |_| bad.feed("a");
    bad.feed("\\q\"}");
    try std.testing.expect(!bad.finish());
    try expectEmpty(&bad);
}
