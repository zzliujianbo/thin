test "UTF8 width initialization preserves the numeric locale category" {
    const before = posix.numericLocale() orelse return error.LocaleUnavailable;
    const saved = try std.testing.allocator.dupe(u8, std.mem.span(before));
    defer std.testing.allocator.free(saved);
    try initLocale();
    const after = posix.numericLocale() orelse return error.LocaleUnavailable;
    try std.testing.expectEqualStrings(saved, std.mem.span(after));
    try std.testing.expectEqual(@as(usize, 4), width("中文"));
}
test "fitBytes and styledWidth respect cluster boundaries and plain text" {
    try initLocale();
    const cases = [_][]const u8{ "中", "😀", "👩‍💻", "é" };
    for (cases) |s| {
        const w = width(s);
        try std.testing.expect(w > 0);
        try std.testing.expectEqual(@as(usize, 0), fitBytes(s, w - 1));
        try std.testing.expectEqual(s.len, fitBytes(s, w));
    }
    try std.testing.expectEqual("中".len, fitBytes("中x", 2));
    try std.testing.expectEqual(@as(usize, 0), fitBytes("中", 0));
    try std.testing.expectEqual("\n".len, fitBytes("\n中", 0));
    try std.testing.expectEqual(@as(usize, 1), fitBytes("a\tb", 3));
    try std.testing.expectEqual(@as(usize, 2), fitBytes("a\tb", 4));
    const styled = "\x1b[31m中\x1b[0m\té";
    try std.testing.expectEqual(@as(usize, 5), styledWidth(styled));
    try std.testing.expect(width(styled) > styledWidth(styled));
    try std.testing.expectEqual(@as(usize, 1), fitBytes("\x1b[31m", 1));
}
test "printable ASCII width and cluster shortcuts retain ZWJ joins" {
    try initLocale();
    for (0x20..0x7f) |value| {
        const cp: u21 = @intCast(value);
        try std.testing.expectEqual(@as(c_int, 1), wcwidth(@intCast(cp)));
        try std.testing.expectEqual(@as(usize, 1), scalarWidth(cp));
        var ordinary = ClusterState.init('a', 0);
        try std.testing.expect(!ordinary.accept(cp));
        var joined = ClusterState.init('a', 0);
        try std.testing.expect(joined.accept(0x200d));
        try std.testing.expect(joined.accept(cp));
        try std.testing.expectEqual(@as(usize, 2), joined.width);
        try std.testing.expect(!joined.accept('z'));
    }
}
test "sanitize controls, invalid utf8, backslashes and bounded marker" {
    const a = std.testing.allocator;
    const s = try sanitize(a, "a\\b\x1b[31m\xe2\x80\xae\xff\n\t", 100);
    defer a.free(s);
    try std.testing.expect(std.unicode.utf8ValidateSlice(s));
    try std.testing.expect(std.mem.startsWith(u8, s, "a\\b"));
    try std.testing.expect(std.mem.indexOfScalar(u8, s, 27) == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\xe2\x80\xae") == null);
    for (0..20) |n| {
        const t = try sanitize(a, "你好你好你好你好你好你好", n);
        defer a.free(t);
        try std.testing.expect(t.len <= n);
        try std.testing.expect(std.unicode.utf8ValidateSlice(t));
    }
}
test "CRLF is one newline, isolated carriage return is not executed" {
    const a = std.testing.allocator;
    const s = try sanitize(a, "a\r\nb\rc", 20);
    defer a.free(s);
    try std.testing.expectEqualStrings("a\nb�c", s);
    try std.testing.expect(!exceedsSanitizedLimit("a\r\nb", 3));
}
test "libc widths and conservative cluster edges" {
    try initLocale();
    try std.testing.expectEqual(@as(usize, 2), width("中"));
    try std.testing.expectEqual(@as(usize, 1), width("e\xcc\x81"));
    try std.testing.expectEqual(@as(usize, 5), width("a\tb"));
    for ([_][]const u8{ "👩‍💻", "👍🏽", "🇺🇸", "❤️", "a‍b", "a‍", "\xcc\x81" }) |s| {
        const c = nextCluster(s, 0, 0);
        try std.testing.expectEqual(s.len, c.end);
    }
    try std.testing.expect(width("👩‍💻") >= 4);
    try std.testing.expect(width("🇺🇸") >= 4);
}
test "incremental state matches conservative styled and plain traversal" {
    try initLocale();
    const cases = [_][]const u8{ "❤️", "é", "👍🏽", "👩‍💻", "🇺🇸", "a‍🏽", "a‍️", "a‍‍" };
    for (cases) |s| {
        const first = rune(s, 0);
        var state = ClusterState.init(first.cp, 0);
        var i = first.end;
        while (i < s.len) {
            const r = rune(s, i);
            try std.testing.expect(state.accept(r.cp));
            i = r.end;
        }
        try std.testing.expectEqual(nextCluster(s, 0, 0).width, state.width);
        try std.testing.expect(!state.accept(9));
        try std.testing.expect(!state.accept(10));
    }
    var joined = ClusterState.init('a', 0);
    try std.testing.expect(joined.accept(0x200d));
    try std.testing.expect(!joined.accept(27));
    try std.testing.expect(joined.awaitZWJ);
    try std.testing.expect(joined.accept(0xfe0f));
    // Joined FE0F is a scalar SUM, not ordinary FE0F max(2).
    try std.testing.expectEqual(@as(usize, 1), joined.width);
    const flags = "🇺🇸🇨";
    const pair = nextCluster(flags, 0, 0);
    try std.testing.expectEqual(@as(usize, 8), pair.end);
    try std.testing.expectEqual(@as(usize, 4), pair.width);
    try std.testing.expectEqual(@as(usize, 2), nextCluster(flags, pair.end, pair.width).width);
    const styled = "\x1b[31m❤\x1b[1m️\x1b[0m";
    try std.testing.expectEqual(styled.len, nextStyledCluster(styled, 0, 0).end);
    try std.testing.expectEqual(@as(usize, 2), nextStyledCluster(styled, 0, 0).width);
    const control = "a‍\x1b[31m\n";
    try std.testing.expectEqual(@as(usize, 4), nextStyledCluster(control, 0, 0).end);
}
