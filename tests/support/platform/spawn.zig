fn testHandler(_: c.SIG) callconv(.c) void {}

fn testProcField(pid: c.pid_t, suffix: []const u8, key: []const u8, base: u8) !u64 {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/{s}", .{ pid, suffix }, 0);
    const fd = c.open(path, .{ .CLOEXEC = true });
    if (fd < 0) return error.TestProcUnavailable;
    defer _ = c.close(fd);
    var buf: [8192]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0 or n == buf.len) return error.TestProcUnavailable;
    var lines = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key))
            return std.fmt.parseInt(u64, std.mem.trim(u8, line[key.len..], " \t"), base);
    }
    return error.TestProcFieldMissing;
}
