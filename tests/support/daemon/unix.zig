const test_peer: Credentials = .{ .pid = 0, .uid = 0, .gid = 0 };

fn testWait() Wait {
    return .{ .io = std.testing.io, .timeout_ms = 1000 };
}

fn testPair(allocator: std.mem.Allocator) !struct { a: Connection, b: Connection } {
    const fds = try socketPair();
    return .{
        .a = Connection.init(allocator, fds[0], test_peer),
        .b = Connection.init(allocator, fds[1], test_peer),
    };
}

fn sendAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.send(fd, bytes.ptr + offset, bytes.len - offset, native.send_flags);
        try std.testing.expect(n > 0);
        offset += @intCast(n);
    }
}

fn testPrivateDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !Directory {
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return Directory.resolveUnder(allocator, buf[0..n], "rt", @intCast(c.geteuid()));
}

fn testParent(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..n];
}

fn testPath(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
    defer allocator.free(path);
    return allocator.dupeSentinel(u8, path, 0);
}

const TestProgress = struct {
    ticks: usize = 0,
    cancel_after: usize = std.math.maxInt(usize),
    fail_after: usize = std.math.maxInt(usize),
    token: ?*const protocol.Cancellation = null,

    fn run(ctx: ?*anyopaque) anyerror!void {
        const self: *TestProgress = @ptrCast(@alignCast(ctx orelse return error.UnexpectedSystemError));
        self.ticks += 1;
        if (self.ticks >= self.fail_after) return error.Canceled;
        if (self.ticks >= self.cancel_after) {
            if (self.token) |token| @constCast(token).cancel();
        }
    }
};
