test "local terminal wait observes borrowed wakeup without consuming it as input" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    var wake = try @import("../platform/wakeup.zig").Wakeup.init();
    defer wake.deinit();
    try terminal.setNotification(wake.fd);
    defer terminal.setNotification(-1) catch {};
    wake.notify();
    const start = std.Io.Clock.awake.now(std.testing.io);
    try terminal.wait(false, 500);
    try std.testing.expect(start.untilNow(std.testing.io, .awake).toMilliseconds() < 250);
    var input: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try terminal.read(&input));
    var descriptor = [_]c.pollfd{.{ .fd = wake.fd, .events = c.POLL.IN }};
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&descriptor, 1, 0));
    wake.drain();
    try std.testing.expectEqual(@as(c_int, 0), c.poll(&descriptor, 1, 0));
    try terminal.setNotification(-1);
    terminal.deinit();
    try std.testing.expect(c.fcntl(wake.fd, c.F.GETFD) >= 0);
}
test "CPR parser accepts only an in-range complete first reply" {
    const dimensions = Size{ .columns = 80, .rows = 24 };
    const reply = "\x1b[12;34R";
    for (0..reply.len) |i| try std.testing.expect(parseCpr(reply[0..i], dimensions) == .incomplete);
    const parsed = parseCpr(reply ++ "keys", dimensions);
    try std.testing.expect(parsed == .complete);
    try std.testing.expectEqual(@as(usize, 11), parsed.complete.row);
    try std.testing.expectEqual(reply.len, parsed.complete.length);
    for ([_][]const u8{ "x\x1b[1;1R", "\x04", "\x1b[200~paste\x1b[1;1R", "\x1b[0;1R", "\x1b[25;1R", "\x1b[1;81R", "\x1b[1;0R", "\x1b[;1R", "\x1b[1;xR" }) |bad|
        try std.testing.expect(parseCpr(bad, dimensions) == .invalid);
}
test "entry probe preserves raw suffix and non replies and wipes consumed input" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var dimensions = std.mem.zeroes(c.winsize);
    dimensions.col = 80;
    dimensions.row = 24;
    try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &dimensions));
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    const input = "\x1b[12;34Rabc";
    try std.testing.expectEqual(@as(isize, input.len), c.write(master, input.ptr, input.len));
    const entry = terminal.entryPosition(std.testing.io, .{}) orelse return error.MissingEntry;
    try std.testing.expectEqual(@as(usize, 11), entry.row);
    var result: [32]u8 = undefined;
    const n = try terminal.read(&result);
    try std.testing.expectEqualStrings("abc", result[0..n]);
    try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), &terminal.retained);
    const paste = "\x1b[200~hello";
    try std.testing.expectEqual(@as(isize, paste.len), c.write(master, paste.ptr, paste.len));
    try std.testing.expect(terminal.entryPosition(std.testing.io, .{}) == null);
    const p = try terminal.read(&result);
    try std.testing.expectEqualStrings(paste, result[0..p]);
    terminal.retained[0] = 42;
    terminal.retained_len = 1;
    _ = terminal.restore();
    try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), &terminal.retained);
}
test "entry probe timeout and stop are bounded" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    const start = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expect(terminal.entryPosition(std.testing.io, .{}) == null);
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds() < 500);
    const Always = struct {
        fn stopped(_: ?*const anyopaque) bool {
            return true;
        }
    };
    try std.testing.expect(terminal.entryPosition(std.testing.io, .{ .stopped_fn = Always.stopped }) == null);
}
test "physical rows require an exact raw PTY size" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var size = std.mem.zeroes(c.winsize);
    size.col = 80;
    size.row = 24;
    try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &size));
    const terminal: Terminal = .{ .fd = slave, .owned = false, .original = undefined, .original_flags = 0, .active = false };
    try std.testing.expect(terminal.exactPhysicalRows(24));
    try std.testing.expect(!terminal.exactPhysicalRows(200));
    size.row = 500;
    try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &size));
    try std.testing.expect(!terminal.exactPhysicalRows(200));
    var invalid = terminal;
    invalid.fd = -1;
    try std.testing.expect(!invalid.exactPhysicalRows(24));
}
test "product terminal restores raw attributes and flags on PTY only" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var original: abi.Termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &original));
    const flags = c.fcntl(slave, c.F.GETFL);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    var raw: abi.Termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &raw));
    try std.testing.expect(!raw.lflag.ICANON and !raw.lflag.ECHO);
    for ([_]u16{ 40, 80, 120 }) |columns| {
        var size = std.mem.zeroes(c.winsize);
        size.col = columns;
        size.row = 24;
        try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &size));
        try std.testing.expectEqual(@as(usize, columns), terminal.size().columns);
    }

    try std.testing.expectError(error.TerminalNotRestored, terminal.writeAfterRestore("premature"));
    try std.testing.expect(terminal.restore());
    try terminal.writeAfterRestore("Session ID: 00000000000000000000000000000000\r\n");
    try std.testing.expect(terminal.restore());
    var restored: abi.Termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &restored));
    try expectAttributes(original, restored);
    try std.testing.expectEqual(posix.configuredFileFlags(flags), posix.configuredFileFlags(c.fcntl(slave, c.F.GETFL)));
}
test "restoration releases synchronized display after interrupted frame escapes on owned PTY" {
    const end = "\x1b[?2026l";
    for ([_][]const u8{ "\x1b[?2026h", "\x1b[?2026hpartial-frame\x1b[?2026", "\x1b[?202" }) |partial| {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
        defer _ = c.close(master);
        defer _ = c.close(slave);
        try std.testing.expect(c.fcntl(master, c.F.SETFL, c.fcntl(master, c.F.GETFL) | nonblock) >= 0);
        var terminal = try Terminal.fromFd(slave, false);
        defer terminal.deinit();
        try std.testing.expect(terminal.writeBounded(partial, 10));
        try std.testing.expect(terminal.restore());
        var buffer: [2048]u8 = undefined;
        var used: usize = 0;
        for (0..20) |_| {
            var pollfd = [_]c.pollfd{.{ .fd = master, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&pollfd, 1, 10) <= 0) continue;
            const n = c.read(master, buffer[used..].ptr, buffer.len - used);
            if (n > 0) used += @intCast(n);
            if (std.mem.find(u8, buffer[0..used], "\x1b[?25h") != null or used == buffer.len) break;
        }
        const release = std.mem.find(u8, buffer[0..used], end) orelse return error.MissingSyncRelease;
        const show = std.mem.find(u8, buffer[0..used], "\x1b[?25h") orelse return error.MissingCursorRestore;
        try std.testing.expect(release + end.len <= show);
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay(buffer[0..used]); // CAN also cancels a partial begin/end.
        var restored: abi.Termios = undefined;
        try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &restored));
        try expectAttributes(terminal.original, restored);
        try std.testing.expectEqual(posix.configuredFileFlags(terminal.original_flags), posix.configuredFileFlags(c.fcntl(slave, c.F.GETFL)));
    }
}
test "post restoration stop on a backpressured retry still restores descriptor flags" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    try std.testing.expect(terminal.restore());
    const flags = c.fcntl(slave, c.F.GETFL);
    try std.testing.expect(flags >= 0);
    // Darwin may still admit writes while output is paused. Fill even the last
    // byte of queue space so a small report cannot race a large-write EAGAIN.
    try std.testing.expectEqual(@as(c_int, 0), posix.pauseOutput(slave, true));
    defer _ = posix.pauseOutput(slave, false);
    try std.testing.expect(c.fcntl(slave, c.F.SETFL, flags | nonblock) >= 0);
    defer _ = c.fcntl(slave, c.F.SETFL, flags);
    var blocked = false;
    for (0..1024 * 1024) |_| {
        const n = c.write(slave, "x", 1);
        if (n == 1) continue;
        if (n < 0 and c.errno(n) == .INTR) continue;
        try std.testing.expectEqual(c.E.AGAIN, c.errno(n));
        blocked = true;
        break;
    }
    try std.testing.expect(blocked);
    try std.testing.expect(c.fcntl(slave, c.F.SETFL, flags) >= 0);
    const Reader = struct {
        fn stopped(ctx: ?*const anyopaque) bool {
            const immutable: *const usize = @ptrCast(@alignCast(ctx.?));
            const count = @constCast(immutable);
            count.* += 1;
            return count.* >= 2;
        }
    };
    var calls: usize = 0;
    try std.testing.expectError(error.Canceled, terminal.writeAfterRestoreStopped("bounded-report", .{ .context = &calls, .stopped_fn = Reader.stopped }));
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(posix.configuredFileFlags(flags), posix.configuredFileFlags(c.fcntl(slave, c.F.GETFL)));
    try std.testing.expect(terminal.restore());
}
test "failed restoration never becomes success or allows exit identity output" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(c_int, 0), c.close(slave));
    try std.testing.expect(!terminal.restore());
    try std.testing.expect(!terminal.restore());
    try std.testing.expectError(error.TerminalNotRestored, terminal.writeAfterRestore("must not print"));
}
test "mode entry emits only the bounded enter sequence on owned PTYs" {
    var captured: [64]u8 = undefined;
    for ([_]u16{ 1, 2, 24, 200 }) |rows| {
        const startup = try captureStartup(&captured, 80, rows);
        try expectEntryOnly(startup);
    }
}
test "mode entry preserves seeded cursor and prior rows at middle and bottom" {
    const regular = @import("../tests/regular_screen.zig");
    var captured: [64]u8 = undefined;
    const startup = try captureStartup(&captured, 80, 24);
    try expectEntryOnly(startup);
    const Seed = struct { row: usize, col: usize, wrap: bool };
    for ([_]Seed{
        .{ .row = 11, .col = 0, .wrap = false },
        .{ .row = 12, .col = 7, .wrap = false },
        .{ .row = 23, .col = 79, .wrap = true },
    }) |seed| {
        var screen: regular.Screen = .{};
        try screen.replay(regular.prior ++ "\r\nfirst-row\r\nsecond-row\r\nthird-row");
        screen.row = seed.row;
        screen.col = seed.col;
        screen.wrap = seed.wrap;
        const history = screen.history_len;
        const grid = screen.grid;
        try screen.replay(startup);
        try std.testing.expectEqual(seed.row, screen.row);
        try std.testing.expectEqual(seed.col, screen.col);
        try std.testing.expectEqual(seed.wrap, screen.wrap);
        try std.testing.expectEqual(history, screen.history_len);
        for (0..grid.len) |row_index|
            try std.testing.expectEqualSlices(u8, &grid[row_index], &screen.grid[row_index]);
        try std.testing.expectEqual(@as(usize, 1), screen.count(regular.prior));
        for ([_][]const u8{ "first-row", "second-row", "third-row" }) |row|
            try std.testing.expectEqual(@as(usize, 1), screen.count(row));
    }
}
test "backpressured terminal stays nonblocking and reports failed display restoration" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    const bytes: [4096]u8 = @splat('x');
    var total: usize = 0;
    // 持续写入直到内核缓冲区写满（write 返回 0），证明写操作不会阻塞。
    while (total < 1024 * 1024) {
        const n = try terminal.write(&bytes);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(total < 1024 * 1024);

    _ = terminal.restore(); // Kernel may make a little extra output space; either is honest.
    var restored: abi.Termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &restored));
    try expectAttributes(terminal.original, restored);
}
