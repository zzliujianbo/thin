test "saved session titles fit cells and empty titles fall back to short ids" {
    try text.initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Title = @import("../core/session_metadata.zig").Title;
    var items = [_]session.SavedSession{
        .{ .id = "0123456789abcdef0123456789abcdef".*, .modified_ms = 1234, .title = Title.fromText("中文长标题和更多内容") },
        .{ .id = "abcdef0123456789abcdef0123456789".*, .modified_ms = 0 },
    };
    var picker = Picker{ .sessions = &items, .epoch = 1, .session_id = null, .launcher = null };
    const shown = try rows(a, &picker, 80, 5);
    try std.testing.expect(shown.can_confirm);
    try std.testing.expect(std.mem.indexOf(u8, shown.lines[0], "中文长标题和更多内容") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.lines[0], "1970-01-01 00:00 UTC") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.lines[1], "abcdef01") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.lines[1], &items[1].id) == null);
    const narrow = try rows(a, &picker, 6, 5);
    try std.testing.expectEqualStrings("> 中文", narrow.lines[0]);
    try std.testing.expect(narrow.can_confirm);
    try std.testing.expect(!(try rows(a, &picker, 3, 5)).can_confirm);
    try std.testing.expect(!(try rows(a, &picker, 2, 5)).can_confirm);
    try std.testing.expect(!(try rows(a, &picker, 80, 0)).can_confirm);
    picker.selected = 1;
    try std.testing.expect((try rows(a, &picker, 3, 5)).can_confirm);
}
test "saved time uses UTC leap years and rejects out of range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2024-02-29 12:34 UTC", try savedTime(a, 1709210040000));
    try std.testing.expectEqualStrings("1969-12-31 23:59 UTC", try savedTime(a, -1));
    try std.testing.expectEqualStrings("time unavailable", try savedTime(a, -62135596800001));
    try std.testing.expectEqualStrings("time unavailable", try savedTime(a, 253402300800000));
}
