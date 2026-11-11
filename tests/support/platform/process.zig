const BothSinkProbe = struct {
    out: std.ArrayList(u8) = .empty,
    err: std.ArrayList(u8) = .empty,
    out_calls: usize = 0,
    err_calls: usize = 0,
    notices: usize = 0,
    notice: ?LaunchNotice = null,
    fail_err: bool = false,
    cancel: ?*p.Cancellation = null,

    fn writeOut(context: *anyopaque, bytes: []const u8) !void {
        const self: *BothSinkProbe = @ptrCast(@alignCast(context));
        self.out_calls += 1;
        try self.out.appendSlice(std.testing.allocator, bytes);
        if (self.cancel) |token| token.cancel();
    }

    fn writeErr(context: *anyopaque, bytes: []const u8) !void {
        const self: *BothSinkProbe = @ptrCast(@alignCast(context));
        self.err_calls += 1;
        try self.err.appendSlice(std.testing.allocator, bytes);
        if (self.fail_err) return error.TestErrSinkFailed;
    }

    fn notify(context: *anyopaque, notice: LaunchNotice) void {
        const self: *BothSinkProbe = @ptrCast(@alignCast(context));
        self.notices += 1;
        self.notice = notice;
    }

    fn deinit(self: *BothSinkProbe) void {
        self.out.deinit(std.testing.allocator);
        self.err.deinit(std.testing.allocator);
    }
};

const TestSink = struct {
    bytes: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    ack_dir: ?std.Io.Dir = null,
    cancel: ?*p.Cancellation = null,
    fail: bool = false,

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        self.calls += 1;
        try self.bytes.appendSlice(std.testing.allocator, bytes);
        if (self.calls == 1) {
            if (self.ack_dir) |dir| try dir.writeFile(std.testing.io, .{ .sub_path = "sink-ack", .data = "seen" });
            if (self.cancel) |token| token.cancel();
        }
        if (self.fail) return error.TestSinkFailed;
    }

    fn sink(self: *TestSink) OutputSink {
        return .{ .context = self, .write_fn = write };
    }

    fn deinit(self: *TestSink) void {
        self.bytes.deinit(std.testing.allocator);
    }
};

const TestContext = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    root: []const u8,

    fn init() !TestContext {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [4096]u8 = undefined;
        const n = try tmp.dir.realPath(std.testing.io, &buf);
        const root = try std.testing.allocator.dupe(u8, buf[0..n]);
        errdefer std.testing.allocator.free(root);

        var env = std.process.Environ.Map.init(std.testing.allocator);
        errdefer env.deinit();
        try env.put("PATH", "/usr/bin:/bin");
        try env.put("LANG", "C");
        return .{ .tmp = tmp, .env = env, .root = root };
    }

    fn deinit(self: *TestContext) void {
        self.tmp.cleanup();
        self.env.deinit();
        std.testing.allocator.free(self.root);
    }
};

fn freeResult(result: Result) void {
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

const test_options: Options = .{ .timeout_ms = 1500, .term_grace_ms = 40, .cleanup_timeout_ms = 500 };

fn ownFdCount() !usize {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const dir = c.opendir("/proc/self/fd") orelse return error.ProcUnavailable;
    defer _ = c.closedir(dir);
    var count: usize = 0;
    while (true) {
        c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            if (c._errno().* != 0) return error.ProcUnavailable;
            break;
        };
        if (entry.name[0] != '.') count += 1;
    }
    return count;
}

fn ownChildren(buf: []u8) ![]const u8 {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fd = c.open("/proc/thread-self/children", .{ .CLOEXEC = true });
    if (fd < 0) return error.ProcUnavailable;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0 or n == buf.len) return error.ProcUnavailable;
    return buf[0..@intCast(n)];
}

fn waitReady(io: std.Io, dir: std.Io.Dir) !void {
    const start = std.Io.Clock.awake.now(io);
    while (elapsed(io, start) < 1000) {
        const file = dir.openFile(io, "ready", .{}) catch |e| switch (e) {
            error.FileNotFound => {
                try std.Io.sleep(io, .fromMilliseconds(2), .awake);
                continue;
            },
            else => return e,
        };
        file.close(io);
        return;
    }
    return error.TestReadyTimeout;
}

fn cancelWhenReady(io: std.Io, dir: std.Io.Dir, cancel: *p.Cancellation) !void {
    try waitReady(io, dir);
    cancel.cancel();
}
