const openpty = abi.openpty;

fn expectAttributes(a: abi.Termios, b: abi.Termios) !void {
    try std.testing.expectEqual(a.iflag, b.iflag);
    try std.testing.expectEqual(a.oflag, b.oflag);
    try std.testing.expectEqual(a.cflag, b.cflag);
    try std.testing.expectEqual(abi.configuredLocalFlags(a.lflag), abi.configuredLocalFlags(b.lflag));
    try std.testing.expectEqualSlices(c.cc_t, &a.cc, &b.cc);
    try std.testing.expectEqual(a.ispeed, b.ispeed);
    try std.testing.expectEqual(a.ospeed, b.ospeed);
}

fn captureStartup(output: []u8, columns: u16, screen_rows: u16) ![]const u8 {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var dimensions = std.mem.zeroes(c.winsize);
    dimensions.col = columns;
    dimensions.row = screen_rows;
    try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &dimensions));
    try std.testing.expect(c.fcntl(master, c.F.SETFL, c.fcntl(master, c.F.GETFL) | nonblock) >= 0);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    return try drainMaster(master, output);
}

fn drainMaster(master: c_int, output: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < output.len) {
        const n = c.read(master, output[used..].ptr, output.len - used);
        if (n > 0) {
            used += @intCast(n);
            continue;
        }
        // Empty nonblocking queue is EAGAIN; anything else is a real PTY fault.
        if (n < 0) try std.testing.expectEqual(c.E.AGAIN, c.errno(n));
        var descriptor = [_]c.pollfd{.{ .fd = master, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&descriptor, 1, 20) <= 0) break;
    }
    return output[0..used];
}

fn expectEntryOnly(bytes: []const u8) !void {
    try std.testing.expectEqualStrings(enter, bytes);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\r') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\n') == null);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "\x1b[")) |at| {
        i = at + 2;
        while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) i += 1;
        if (i == bytes.len) return error.IncompleteEscape;
        switch (bytes[i]) {
            'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 'L', 'M', 'P', 'S', 'T', 'f' => return error.CursorGeometrySequence,
            else => i += 1,
        }
    }
}
