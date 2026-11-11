test "cursor position query leaves the screen untouched" {
    var screen: Screen = .{};
    for (0..25) |_| try screen.replay("history\r\n");
    try screen.replay(&(@as([80]u8, @splat('x'))));
    const grid = screen.grid;
    const row = screen.row;
    const col = screen.col;
    const wrap = screen.wrap;
    const history_len = screen.history_len;
    try screen.replay("\x1b[6n");
    try std.testing.expectEqualDeep(grid, screen.grid);
    try std.testing.expectEqual(row, screen.row);
    try std.testing.expectEqual(col, screen.col);
    try std.testing.expectEqual(wrap, screen.wrap);
    try std.testing.expectEqual(history_len, screen.history_len);
    for ([_][]const u8{ "\x1b[n", "\x1b[5n", "\x1b[06n", "\x1b[6R" }) |bad|
        try std.testing.expectError(error.UnsupportedCsi, screen.replay(bad));
    try std.testing.expectError(error.FullscreenSequence, screen.replay("\x1b[H"));
}
test "wide PTY replay does not fabricate wrapped approval ghosts" {
    const body: [120]u8 = @splat('x');
    const bytes = "Approval #4\r\n" ++ body ++ "\r\n> \r\x1b[2A\r\x1b[K\r\n\x1b[K\r\n> ";
    var wide: Screen = .{ .columns = 160 };
    try wide.replay(bytes);
    try std.testing.expect(!wide.visible("Approval #4"));
    try std.testing.expectEqual(@as(usize, 2), wide.row);
    var mismatched: Screen = .{};
    try mismatched.replay(bytes);
    try std.testing.expect(mismatched.visible("Approval #4"));
}
test "regular grid retains prior output and committed answers through tail redraw" {
    var s: Screen = .{};
    try s.replay(prior ++ "\r\nfirst-answer\r\nold tail\r\ninput\r\x1b[1A\x1b[2K\rsecond-answer\r\n\x1b[2K\r> \x1b[2C\x1b[1D\x1b[0m\x1b[?25h\x1b[?2004l");
    try std.testing.expect(s.visible("second-answer"));
    try std.testing.expectEqual(@as(usize, 1), s.count("first-answer"));
    for (0..30) |_| try s.replay("\r\n");
    try std.testing.expect(!s.visible(prior));
    try std.testing.expectEqual(@as(usize, 1), s.count(prior));
    try std.testing.expectEqual(@as(usize, 1), s.count("second-answer"));
}
test "reject fullscreen variants and erased historical-only approval" {
    for ([_][]const u8{ "\x1b[?1049h", "\x1b[?25;47l", "\x1b[?1047h", "\x1b[H", "\x1b[2;3f", "\x1b[0J", "\x1b[1;24r" }) |bad|
        try std.testing.expectError(error.FullscreenSequence, rejectFullscreen(bad));
    var s: Screen = .{};
    try s.replay("Approval #1 date -Ins\r\x1b[2K");
    try std.testing.expect(!s.visible("Approval #"));
    try std.testing.expectError(error.IncompleteCsi, s.replay("\x1b["));
}
test "CAN cancels partial reclaim without hiding later forbidden sequences" {
    var s: Screen = .{};
    try s.replay(prior ++ "\r\x1b[2\x18\x1b[0m\r\nanswer\x1b\x18\r\n");
    try std.testing.expectEqual(@as(usize, 1), s.count(prior));
    try std.testing.expect(s.visible("answer"));
    try std.testing.expectError(error.FullscreenSequence, rejectFullscreen("\x1b[2\x18\x1b[?1049h"));
    try std.testing.expectError(error.FullscreenSequence, rejectFullscreen("\x1b[2\x1b[2J"));
}
test "delete lines preserves history and rows above the owned cursor" {
    var screen: Screen = .{};
    try screen.replay(prior ++ "\r\nabove\r\nfirst\r\nsecond\r\nthird\x1b[2A\r\x1b[1M");
    try std.testing.expectEqual(@as(usize, 0), screen.history_len);
    try std.testing.expectEqual(@as(usize, 2), screen.row);
    try std.testing.expectEqual(@as(usize, 0), screen.col);
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[2], "second"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[3], "third"));
    try std.testing.expect(screen.visible(prior));
    try std.testing.expect(screen.visible("above"));
    try screen.replay("\x1b[999M");
    try std.testing.expectEqual(@as(usize, 0), screen.history_len);
    try std.testing.expect(screen.visible(prior));
    try std.testing.expect(screen.visible("above"));
    try std.testing.expect(!screen.visible("second"));
}
test "cursor movement erase and delayed wrapping" {
    var s: Screen = .{};
    try s.replay("abc\r\x1b[2C\x1b[1KX\x1b[1B\rbelow\x1b[1A\r");
    try std.testing.expect(s.visible("  X"));
    try std.testing.expect(s.visible("below"));
    var wrap: Screen = .{};
    try wrap.replay(&(@as([80]u8, @splat('x'))));
    try std.testing.expectEqual(@as(usize, 0), wrap.row);
    try wrap.replay("y");
    try std.testing.expectEqual(@as(usize, 1), wrap.row);
}
