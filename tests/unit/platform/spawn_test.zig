test "pre-exec restores signal defaults and empty mask without changing parent" {
    // This fixture inspects /proc and a Linux-only stopped pre-exec child.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const t = std.testing;
    const linux = std.os.linux;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");

    // Emulate Guard handlers, an ignored PIPE and a worker's blocked mask.
    // No signal is sent to the test process; all altered state is restored.
    var originals: [reset_signals.len]c.Sigaction = undefined;
    var installed: usize = 0;
    defer while (installed > 0) {
        installed -= 1;
        _ = c.sigaction(reset_signals[installed], &originals[installed], null);
    };
    var action = std.mem.zeroes(c.Sigaction);
    action.handler = .{ .handler = testHandler };
    try t.expectEqual(@as(c_int, 0), c.sigemptyset(&action.mask));
    var blocked: c.sigset_t = undefined;
    try t.expectEqual(@as(c_int, 0), c.sigemptyset(&blocked));
    for (reset_signals) |sig| {
        // CHLD cannot be ignored: auto-reaping would violate ownership.
        action.handler = .{ .handler = if (sig == .PIPE) @ptrFromInt(1) else testHandler };
        try t.expectEqual(@as(c_int, 0), c.sigaction(sig, &action, &originals[installed]));
        installed += 1;
        try t.expectEqual(@as(c_int, 0), c.sigaddset(&blocked, sig));
    }
    var original_mask: c.sigset_t = undefined;
    try t.expectEqual(@as(c_int, 0), c.sigprocmask(linux.SIG.BLOCK, &blocked, &original_mask));
    defer _ = c.sigprocmask(linux.SIG.SETMASK, &original_mask, null);

    const child = try start(t.allocator, ".", tmp.dir, "/bin/bash", "exit 0", &env, .stop_before_exec);
    defer child.close();
    // Retain PID until the final group KILL; bounded exact-PID reap even when
    // an assertion fails. Never recover ownership with kill(pid, 0).
    defer {
        _ = c.kill(-child.pid, .KILL);
        var term: c_int = undefined;
        const since = std.Io.Clock.awake.now(t.io);
        while (true) {
            const rc = c.waitpid(child.pid, &term, linux.W.NOHANG);
            if (rc == child.pid) break;
            if (rc < 0 and c._errno().* != @backingInt(c.E.INTR)) @panic("test child reap failed");
            if (since.untilNow(t.io, .awake).toMilliseconds() >= 1000) @panic("test child reap timed out");
            var fds: [0]c.pollfd = .{};
            _ = c.poll(&fds, 0, 2);
        }
    }
    try t.expect(!child.signal_restore_failed);
    const since = std.Io.Clock.awake.now(t.io);
    while (true) {
        var info = std.mem.zeroes(linux.siginfo_t);
        try t.expectEqual(linux.E.SUCCESS, linux.errno(linux.waitid(.PID, child.pid, &info, linux.W.STOPPED | linux.W.NOHANG | linux.W.NOWAIT, null)));
        if (info.fields.common.first.piduid.pid == child.pid) break;
        if (since.untilNow(t.io, .awake).toMilliseconds() >= 1000) return error.TestStartupTimedOut;
        var fds: [0]c.pollfd = .{};
        _ = c.poll(&fds, 0, 2);
    }
    try t.expectEqual(Status.pending, try status(child.exec_error));
    try t.expectEqual(@as(u64, 0), try testProcField(child.pid, "status", "SigBlk:", 16));
    const caught = try testProcField(child.pid, "status", "SigCgt:", 16);
    const ignored = try testProcField(child.pid, "status", "SigIgn:", 16);
    var parent_mask: c.sigset_t = undefined;
    try t.expectEqual(@as(c_int, 0), c.sigprocmask(linux.SIG.SETMASK, null, &parent_mask));
    for (reset_signals) |sig| {
        const bit = @as(u64, 1) << @as(u6, @intCast(@backingInt(sig) - 1));
        try t.expectEqual(@as(u64, 0), (caught | ignored) & bit);
        try t.expectEqual(@as(c_int, 1), c.sigismember(&parent_mask, sig));
        var parent_action: c.Sigaction = undefined;
        try t.expectEqual(@as(c_int, 0), c.sigaction(sig, null, &parent_action));
        const expected: ?c.Sigaction.handler_fn = if (sig == .PIPE) @ptrFromInt(1) else testHandler;
        try t.expectEqual(expected, parent_action.handler.handler);
    }
    const nonblock: u32 = @bitCast(c.O{ .NONBLOCK = true });
    try t.expectEqual(@as(u64, 0), (try testProcField(child.pid, "fdinfo/1", "flags:", 8)) & nonblock);
    try t.expectEqual(@as(u64, 0), (try testProcField(child.pid, "fdinfo/2", "flags:", 8)) & nonblock);
    try t.expect(c.fcntl(child.exec_error, c.F.GETFL) & @as(c_int, @intCast(nonblock)) != 0);
}
