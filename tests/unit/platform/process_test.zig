test "unlimited capture reports allocation failure without losing retained bytes" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var empty: [0]u8 = .{};
    var capture: Capture = .{ .data = &empty, .allocator = failing.allocator(), .unlimited = true };
    defer capture.dynamic.deinit(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, capture.add("output"));
    try std.testing.expectEqual(@as(usize, 0), capture.dynamic.items.len);
    try std.testing.expectEqual(@as(u64, 0), capture.total);
}
test "default unlimited capture retains both streams beyond old quota" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    var options = test_options;
    options.output_bytes = null;
    options.raw_output = true;
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, "printf '%131072s' ''; printf '%131072s' '' >&2", &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expect(!result.truncated and !result.cleanup_failed);
    try std.testing.expectEqual(@as(usize, 131072), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 131072), result.stderr.len);
}
test "stdout sink observes pre EOF handshake and exact chunks beyond retention" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    // Exercise both render modes, including rawRender's zero-retention trap.
    for ([_]bool{ false, true }) |raw| {
        ctx.tmp.dir.deleteFile(std.testing.io, "sink-ack") catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        var sink: TestSink = .{ .ack_dir = ctx.tmp.dir };
        defer sink.deinit();
        var cancel: p.Cancellation = .{};
        var options = test_options;
        options.stdout_sink = sink.sink();
        options.output_bytes = 2;
        options.raw_output = raw;
        const result = try run(std.testing.allocator, std.testing.io, ctx.root, "printf first; while [[ ! -e sink-ack ]]; do :; done; printf '%131072s' ''; printf '\\000\\377end'", &ctx.env, options, &cancel);
        defer freeResult(result);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term.?);
        try std.testing.expect(!result.truncated and !result.cleanup_failed and !result.timed_out);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expectEqual(@as(u64, 131082), result.stdout_bytes);
        try std.testing.expectEqual(@as(usize, 131082), sink.bytes.items.len);
        try std.testing.expect(sink.calls > 1);
        try std.testing.expectEqualStrings("first", sink.bytes.items[0..5]);
        for (sink.bytes.items[5 .. 5 + 131072]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
        try std.testing.expectEqualStrings("\x00\xffend", sink.bytes.items[5 + 131072 ..]);
    }
}
test "stdout sink leaves stderr bounded and truly truncated" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var sink: TestSink = .{};
    defer sink.deinit();
    var cancel: p.Cancellation = .{};
    var options = test_options;
    options.stdout_sink = sink.sink();
    options.output_bytes = 16;
    options.raw_output = true;
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, "printf ok; printf '%100s' '' >&2", &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expect(result.truncated and !result.cleanup_failed);
    try std.testing.expectEqualStrings("ok", sink.bytes.items);
    try std.testing.expectEqual(@as(u64, 100), result.stderr_bytes);
    try std.testing.expect(result.stderr.len <= 8 and result.stdout.len == 0);
}
test "stdout sink first error cleans and reaps before returning without more callbacks" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var sink: TestSink = .{ .fail = true };
    defer sink.deinit();
    var cancel: p.Cancellation = .{};
    var options = test_options;
    options.stdout_sink = sink.sink();
    var before: [4096]u8 = undefined;
    var after: [4096]u8 = undefined;
    const children = try ownChildren(&before);
    const fds = try ownFdCount();
    try std.testing.expectError(error.TestSinkFailed, run(std.testing.allocator, std.testing.io, ctx.root, "trap 'printf cleanup; printf stderr >&2; exit 0' TERM; printf ready; while :; do :; done", &ctx.env, options, &cancel));
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqualStrings(children, try ownChildren(&after));
    try std.testing.expectEqual(fds, try ownFdCount());
}
test "stdout sink cleanup failure takes precedence over callback error" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var sink: TestSink = .{ .fail = true };
    defer sink.deinit();
    var cancel: p.Cancellation = .{};
    var options = test_options;
    options.stdout_sink = sink.sink();
    options.cleanup_timeout_ms = 0;
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, "trap '' TERM; printf ready; while :; do :; done", &ctx.env, options, &cancel);
    defer freeResult(result);
    // Zero budget deliberately cannot confirm cleanup. The returned Result,
    // rather than TestSinkFailed, lets the caller poison its owning transport.
    // Reap only this test's still-owned child; run has already sent KILL.
    if (result.unreaped_pid) |pid| {
        const start = std.Io.Clock.awake.now(std.testing.io);
        while (true) {
            var status: c_int = 0;
            const rc = reap(pid, &status);
            if (rc == pid or (rc < 0 and std.posix.errno(rc) == .CHILD)) break;
            try std.testing.expect(rc == 0 or std.posix.errno(rc) == .INTR);
            try std.testing.expect(elapsed(std.testing.io, start) < 2500);
            try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
        }
    }
    try std.testing.expect(result.cleanup_failed and result.truncated);
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
}
test "stdout sink cancellation drains cleanup output without further callbacks" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    var sink: TestSink = .{ .cancel = &cancel };
    defer sink.deinit();
    var options = test_options;
    options.stdout_sink = sink.sink();
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, "trap 'printf cleanup; exit 0' TERM; printf ready; while :; do :; done", &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expect(result.canceled and !result.cleanup_failed);
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqualStrings("ready", sink.bytes.items);
    try std.testing.expectEqual(@as(u64, 12), result.stdout_bytes);
    try std.testing.expect(!result.truncated);
}
test "stderr sink retains nothing and launch notice reports owned exec once" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var probe: BothSinkProbe = .{};
    defer probe.deinit();
    var cancel: p.Cancellation = .{};
    var options = test_options;
    options.output_bytes = 16;
    options.stdout_sink = .{ .context = &probe, .write_fn = BothSinkProbe.writeOut };
    options.stderr_sink = .{ .context = &probe, .write_fn = BothSinkProbe.writeErr };
    options.on_launch = .{ .context = &probe, .notify_fn = BothSinkProbe.notify };
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, "printf out; printf '%100s' '' >&2; printf tail", &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term.?);
    try std.testing.expect(!result.cleanup_failed and !result.canceled and !result.timed_out);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u64, 7), result.stdout_bytes);
    try std.testing.expectEqual(@as(u64, 100), result.stderr_bytes);
    try std.testing.expectEqualStrings("outtail", probe.out.items);
    try std.testing.expectEqual(@as(usize, 100), probe.err.items.len);
    try std.testing.expectEqual(@as(usize, 1), probe.notices);
    try std.testing.expect(probe.notice.?.launched and probe.notice.?.group_owned);
    try std.testing.expect(probe.notice.?.pid > 1);
    // 契约是 exec 握手完成后通知一次；通知与两路首次输出之间不存在跨 fd 的绝对顺序。
}
test "launch notice reports failed exec before cleanup and error" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var probe: BothSinkProbe = .{};
    defer probe.deinit();
    var cancel: p.Cancellation = .{};
    const missing = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing-executable", .{ctx.root});
    defer std.testing.allocator.free(missing);
    var options = test_options;
    options.on_launch = .{ .context = &probe, .notify_fn = BothSinkProbe.notify };
    try std.testing.expectError(error.SpawnFailed, runExecutable(std.testing.allocator, std.testing.io, ctx.root, "exit 0", &ctx.env, options, &cancel, .{ .executable = missing }));
    try std.testing.expectEqual(@as(usize, 1), probe.notices);
    try std.testing.expect(!probe.notice.?.launched);
    if (builtin.os.tag == .macos) {
        try std.testing.expectEqual(@as(c.pid_t, 0), probe.notice.?.pid);
        try std.testing.expect(!probe.notice.?.group_owned);
    }
}
test "stderr sink error is sticky and cleanup failure takes precedence" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    {
        var probe: BothSinkProbe = .{ .fail_err = true };
        defer probe.deinit();
        var cancel: p.Cancellation = .{};
        var options = test_options;
        options.stderr_sink = .{ .context = &probe, .write_fn = BothSinkProbe.writeErr };
        try std.testing.expectError(error.TestErrSinkFailed, run(std.testing.allocator, std.testing.io, ctx.root, "printf err >&2; while :; do :; done", &ctx.env, options, &cancel));
        try std.testing.expectEqual(@as(usize, 1), probe.err_calls);
    }
    {
        var probe: BothSinkProbe = .{ .fail_err = true };
        defer probe.deinit();
        var cancel: p.Cancellation = .{};
        var options = test_options;
        options.stderr_sink = .{ .context = &probe, .write_fn = BothSinkProbe.writeErr };
        options.cleanup_timeout_ms = 0;
        options.term_grace_ms = 0;
        const result = try run(std.testing.allocator, std.testing.io, ctx.root, "trap '' TERM; printf err >&2; while :; do :; done", &ctx.env, options, &cancel);
        defer freeResult(result);
        if (result.unreaped_pid) |pid| {
            const start = std.Io.Clock.awake.now(std.testing.io);
            while (true) {
                var status: c_int = 0;
                const rc = reap(pid, &status);
                if (rc == pid or (rc < 0 and std.posix.errno(rc) == .CHILD)) break;
                try std.testing.expect(rc == 0 or std.posix.errno(rc) == .INTR);
                try std.testing.expect(elapsed(std.testing.io, start) < 2500);
                try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
            }
        }
        try std.testing.expect(result.cleanup_failed and result.truncated);
        try std.testing.expectEqual(@as(usize, 1), probe.err_calls);
    }
}
test "both sinks stop delivering after cancellation" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    var probe: BothSinkProbe = .{ .cancel = &cancel };
    defer probe.deinit();
    var options = test_options;
    options.stdout_sink = .{ .context = &probe, .write_fn = BothSinkProbe.writeOut };
    options.stderr_sink = .{ .context = &probe, .write_fn = BothSinkProbe.writeErr };
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, "trap 'printf cleanup; exit 0' TERM; printf ready; : > ready; while :; do :; done", &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expect(result.canceled and !result.cleanup_failed);
    try std.testing.expectEqual(@as(usize, 1), probe.out_calls);
    try std.testing.expectEqualStrings("ready", probe.out.items);
    try std.testing.expectEqual(@as(usize, 0), probe.err_calls);
}
test "safe text helpers reuse capture escaping exactly" {
    const bytes = "a\x1b\x00\xff\r\n\\中\xe2\x80\xae";
    const text = try renderSafeText(std.testing.allocator, bytes);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a\\x1b\\x00\\xff\\x0d\n\\\\\xe4\xb8\xad\\xe2\\x80\\xae", text);
    try std.testing.expectEqual(safeTextWidth(bytes), text.len);
    for (0..text.len + 1) |budget| {
        const fit = safeTextFit(bytes, budget);
        try std.testing.expect(fit.width <= budget);
        try std.testing.expect(fit.raw <= bytes.len);
    }
    const all = safeTextFit(bytes, text.len);
    try std.testing.expectEqual(bytes.len, all.raw);
    try std.testing.expectEqual(text.len, all.width);
}
test "exit7, cwd, ignored stdin and explicit filtered environment" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Construct the pre-filter input locally; never inspect ambient credentials.
    var unfiltered = std.process.Environ.Map.init(std.testing.allocator);
    defer unfiltered.deinit();
    try unfiltered.put("ENVSECRET", "fake-test-secret");
    try unfiltered.put("SAFE", "allowed");
    try ctx.env.put("SAFE", unfiltered.get("SAFE").?);
    var cancel: p.Cancellation = .{};
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "test -z \"${ENVSECRET+x}\" || exit 91; test \"$SAFE\" = allowed || exit 92; read x && exit 93; test \"$PWD\" = \"$EXPECTED_ROOT\" || exit 94; printf ok; exit 7", blk: {
        try ctx.env.put("EXPECTED_ROOT", ctx.root);
        break :blk &ctx.env;
    }, test_options, &cancel);
    defer freeResult(r);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, r.term.?);
    try std.testing.expectEqualStrings("ok", r.stdout);
    try std.testing.expect(!r.cleanup_failed and !r.truncated);
}
test "failed chdir fchdir and exec launches repeatedly leave no fds or children" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const missing = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing", .{ctx.root});
    defer std.testing.allocator.free(missing);
    var before_buf: [4096]u8 = undefined;
    var after_buf: [4096]u8 = undefined;
    const children = try ownChildren(&before_buf);
    // A valid owned fd that is not a directory exercises post-fork fchdir,
    // rather than a pre-fork invalid-descriptor rejection.
    const file = try ctx.tmp.dir.createFile(std.testing.io, "not-a-directory", .{});
    defer file.close(std.testing.io);
    var bad_anchor = test_options;
    bad_anchor.cwd_dir = .{ .handle = file.handle };
    const fds = try ownFdCount();
    for (0..32) |_| {
        try std.testing.expectError(error.SpawnFailed, run(std.testing.allocator, std.testing.io, missing, "exit 0", &ctx.env, test_options, &cancel));
        try std.testing.expectError(error.SpawnFailed, runExecutable(std.testing.allocator, std.testing.io, ctx.root, "exit 0", &ctx.env, test_options, &cancel, .{ .executable = missing }));
        try std.testing.expectError(error.SpawnFailed, run(std.testing.allocator, std.testing.io, ctx.root, "exit 0", &ctx.env, bad_anchor, &cancel));
        try std.testing.expectEqual(fds, try ownFdCount());
        try std.testing.expectEqualStrings(children, try ownChildren(&after_buf));
    }
}
test "pre-exec error pipe wait remains bounded by cancellation and timeout" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const fds = try ownFdCount();
    var before: [4096]u8 = undefined;
    var after: [4096]u8 = undefined;
    const children = try ownChildren(&before);
    for ([_]bool{ false, true }) |cancel_after_fork| {
        var cancel: p.Cancellation = .{};
        const start = std.Io.Clock.awake.now(std.testing.io);
        const r = try runExecutable(std.testing.allocator, std.testing.io, ctx.root, "printf should-not-execute", &ctx.env, .{ .timeout_ms = 80, .term_grace_ms = 20, .cleanup_timeout_ms = 500 }, &cancel, .{
            .test_mode = .stop_before_exec,
            .test_cancel_after_fork = if (cancel_after_fork) &cancel else null,
        });
        defer freeResult(r);
        try std.testing.expectEqual(cancel_after_fork, r.canceled);
        try std.testing.expectEqual(!cancel_after_fork, r.timed_out);
        try std.testing.expect(!r.cleanup_failed and r.unreaped_pid == null);
        try std.testing.expectEqual(@as(u64, 0), r.stdout_bytes);
        if (!cancel_after_fork) try std.testing.expectEqual(std.process.Child.Term{ .signal = .KILL }, r.term.?);
        try std.testing.expect(elapsed(std.testing.io, start) < 1000);
        try std.testing.expectEqual(fds, try ownFdCount());
        try std.testing.expectEqualStrings(children, try ownChildren(&after));
    }
}
test "two large pipes preserve prefix suffix and exact counts" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "printf HEAD; printf '%131072s' ''; printf TAIL; printf ERRH >&2; printf '%131072s' '' >&2; printf ERRT >&2", &ctx.env, .{ .output_bytes = 64, .timeout_ms = 1500, .term_grace_ms = 20, .cleanup_timeout_ms = 500 }, &cancel);
    defer freeResult(r);
    try std.testing.expectEqual(@as(u64, 131080), r.stdout_bytes);
    try std.testing.expectEqual(@as(u64, 131080), r.stderr_bytes);
    try std.testing.expectEqual(@as(usize, 32), r.stdout.len);
    try std.testing.expectEqual(@as(usize, 32), r.stderr.len);
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "HEAD"));
    try std.testing.expect(std.mem.endsWith(u8, r.stdout, "TAIL"));
    try std.testing.expect(std.mem.startsWith(u8, r.stderr, "ERRH"));
    try std.testing.expect(std.mem.endsWith(u8, r.stderr, "ERRT"));
    try std.testing.expect(r.truncated and !r.cleanup_failed);
}
test "precancel does not spawn even with nonexistent cwd" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    cancel.cancel();
    const r = try run(std.testing.allocator, std.testing.io, "/nonexistent-thin-test-root", "exit 91", &ctx.env, test_options, &cancel);
    defer freeResult(r);
    try std.testing.expect(r.canceled and r.term == null and !r.cleanup_failed);
}
test "running cancellation terminates child with finite or no command deadline" {
    for ([_]?u32{ 1500, null }) |deadline| {
        var ctx = try TestContext.init();
        defer ctx.deinit();
        var cancel: p.Cancellation = .{};
        var task = try std.Io.concurrent(std.testing.io, cancelWhenReady, .{ std.testing.io, ctx.tmp.dir, &cancel });
        defer task.cancel(std.testing.io) catch {};
        var options = test_options;
        options.timeout_ms = deadline;
        const r = try run(std.testing.allocator, std.testing.io, ctx.root, "printf ready; : > ready; while (( SECONDS < 2 )); do :; done", &ctx.env, options, &cancel);
        defer freeResult(r);
        try task.await(std.testing.io);
        try std.testing.expect(r.canceled and !r.timed_out and !r.cleanup_failed);
        try std.testing.expectEqualStrings("ready", r.stdout);
        try std.testing.expect(r.term != null);
    }
}
test "timeout and TERM ignoring KILL escalation" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // 两个脚本分别对应普通进程与忽略 TERM 的进程。
    for ([_][]const u8{ "printf ready; while (( SECONDS < 2 )); do :; done", "trap '' TERM; printf ready; while (( SECONDS < 2 )); do :; done" }, 0..) |script, i| {
        var cancel: p.Cancellation = .{};
        const r = try run(std.testing.allocator, std.testing.io, ctx.root, script, &ctx.env, .{ .timeout_ms = 100, .term_grace_ms = 40, .cleanup_timeout_ms = 500 }, &cancel);
        defer freeResult(r);
        try std.testing.expect(r.timed_out and !r.canceled and !r.cleanup_failed);
        try std.testing.expectEqualStrings("ready", r.stdout);
        try std.testing.expectEqual(std.process.Child.Term{ .signal = if (i == 0) .TERM else .KILL }, r.term.?);
    }
}
test "normal shell exit cleans background pipe holders, including TERM ignoring descendants" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const start = std.Io.Clock.awake.now(std.testing.io);
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "(trap '' TERM; while (( SECONDS < 2 )); do :; done) & printf done; exit 7", &ctx.env, test_options, &cancel);
    defer freeResult(r);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, r.term.?);
    try std.testing.expect(!r.timed_out and !r.canceled and !r.cleanup_failed);
    try std.testing.expect(elapsed(std.testing.io, start) < 1200);
}
test "outer Io cancellation still completes bounded cleanup" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    var task = try std.Io.concurrent(std.testing.io, run, .{ std.testing.allocator, std.testing.io, ctx.root, "trap '' TERM; printf ready; : > ready; while (( SECONDS < 2 )); do :; done", &ctx.env, test_options, &cancel });

    // 标记结果是否已被 task.cancel 取走，防止 defer 重复释放。
    var consumed = false;
    defer if (!consumed) {
        if (task.cancel(std.testing.io)) |r| freeResult(r) else |_| {}
    };
    try waitReady(std.testing.io, ctx.tmp.dir);
    const r = try task.cancel(std.testing.io);
    consumed = true;
    defer freeResult(r);
    try std.testing.expect(r.canceled and !r.cleanup_failed);
    try std.testing.expectEqual(std.process.Child.Term{ .signal = .KILL }, r.term.?);
    try std.testing.expectEqualStrings("ready", r.stdout);
}
test "normal exit also cleans descendants that closed both pipes" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "(trap '' TERM; exec >/dev/null 2>&1; while (( SECONDS < 2 )); do :; done) & exit 7", &ctx.env, test_options, &cancel);
    defer freeResult(r);
    try std.testing.expect(!r.cleanup_failed);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, r.term.?);
}
test "exhausted cleanup deadline is explicitly reported, never successful" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "trap '' TERM; printf '%s' \"$$\"; while (( SECONDS < 2 )); do :; done", &ctx.env, .{ .timeout_ms = 100, .cleanup_timeout_ms = 0 }, &cancel);
    defer freeResult(r);
    try std.testing.expect(r.cleanup_failed and r.timed_out);

    // The runner honestly relinquishes cleanup after its zero budget. The test
    // remains responsible for reaping its own child; never signal after reap.
    const pid = r.unreaped_pid orelse 0;
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (r.term == null) {
        try std.testing.expect(pid > 1);
        var status: c_int = 0;
        const rc = reap(pid, &status);
        if (rc == pid or (rc < 0 and std.posix.errno(rc) == .CHILD)) break;
        try std.testing.expect(rc == 0 or std.posix.errno(rc) == .INTR);
        try std.testing.expect(elapsed(std.testing.io, start) < 2500);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
}
test "zero retention still drains both pipes using caller arena" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cancel: p.Cancellation = .{};
    const r = try run(arena.allocator(), std.testing.io, ctx.root, "printf '%131072s' ''; printf '%131072s' '' >&2", &ctx.env, .{ .output_bytes = 0, .timeout_ms = 1500, .cleanup_timeout_ms = 500 }, &cancel);
    try std.testing.expect(r.stdout.len == 0 and r.stderr.len == 0);
    try std.testing.expectEqual(@as(u64, 131072), r.stdout_bytes);
    try std.testing.expectEqual(@as(u64, 131072), r.stderr_bytes);
    try std.testing.expect(r.truncated and !r.cleanup_failed);
}
test "UTF8 and newlines survive arbitrary read splits without terminal escapes" {
    var capture: Capture = .{ .data = try std.testing.allocator.alloc(u8, 128) };
    defer std.testing.allocator.free(capture.data);
    const original = "你好🙂\nline\tend";
    for (0..original.len) |i| try capture.add(original[i..][0..1]);
    const rendered = try capture.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(original, rendered);
    try std.testing.expect(!capture.omitted);

    for (1..40) |cap| {
        var clipped: Capture = .{ .data = try std.testing.allocator.alloc(u8, cap) };
        defer std.testing.allocator.free(clipped.data);
        for (0..5) |_| try clipped.add(original);
        const output = try clipped.render(std.testing.allocator);
        defer std.testing.allocator.free(output);
        try std.testing.expect(output.len <= cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(output));
        try std.testing.expect(clipped.omitted);
    }
}
test "anchored cwd does not follow a replacement path" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    try ctx.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "marker", .data = "anchored" });
    var cancel = p.Cancellation{};
    var options = test_options;
    options.cwd_dir = ctx.tmp.dir;
    const result = try run(std.testing.allocator, std.testing.io, "/nonexistent-replaced-root", "cat marker", &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expectEqualStrings("anchored", result.stdout);
    try std.testing.expect(!result.cleanup_failed);
}
test "borrowed stdin starts at shared offset and raw output roundtrips exact bytes" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const payload = "{\"escaped\":\"\\u4f60\\n\\\\\",\"text\":\"中文\"}\n\x00\xff\x1b";
    try ctx.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input", .data = "skip" ++ payload });
    // Deliberately non-CLOEXEC: spawn must close the original in the child,
    // while leaving the parent's descriptor and descriptor flags untouched.
    const fd = c.openat(ctx.tmp.dir.handle, "input", .{});
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    var prefix: [4]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 4), c.read(fd, &prefix, prefix.len));
    try std.testing.expectEqualStrings("skip", &prefix);
    const flags = c.fcntl(fd, c.F.GETFD);
    var options = test_options;
    options.stdin_file = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    options.raw_output = true;
    var cancel: p.Cancellation = .{};
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, "exec /bin/cat", &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expectEqualStrings(payload, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u64, payload.len), result.stdout_bytes);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term.?);
    try std.testing.expect(!result.truncated and !result.cleanup_failed);
    try std.testing.expectEqual(flags, c.fcntl(fd, c.F.GETFD));
    // dup shares the open-file description: cat consumed to EOF, no rewind.
    try std.testing.expectEqual(@as(isize, 0), c.read(fd, &prefix, prefix.len));
}
test "explicit inherited CLOEXEC fd survives exec without changing parent flags" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    try ctx.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "inherited", .data = "owner-read-end\n" });
    const file = try ctx.tmp.dir.openFile(std.testing.io, "inherited", .{});
    defer file.close(std.testing.io);
    const fd = c.fcntl(file.handle, c.F.DUPFD_CLOEXEC, @as(c_int, 100));
    try std.testing.expect(fd >= 100);
    defer _ = c.close(fd);
    const flags = c.fcntl(fd, c.F.GETFD);
    const command = try std.fmt.allocPrint(std.testing.allocator, "IFS= read -r line <&{d}; printf '%s' \"$line\"", .{fd});
    defer std.testing.allocator.free(command);
    const inherited = [_]c.fd_t{fd};
    var options = test_options;
    options.inherited_fds = &inherited;
    var cancel: p.Cancellation = .{};
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, command, &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expect(!result.cleanup_failed and !result.truncated);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term.?);
    try std.testing.expectEqualStrings("owner-read-end", result.stdout);
    try std.testing.expectEqual(flags, c.fcntl(fd, c.F.GETFD));
}
test "Darwin default-close excludes unrelated non CLOEXEC descriptor" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const file = try ctx.tmp.dir.createFile(std.testing.io, "not-allowlisted", .{});
    defer file.close(std.testing.io);
    const fd = c.fcntl(file.handle, c.F.DUPFD, @as(c_int, 100));
    try std.testing.expect(fd >= 100);
    defer _ = c.close(fd);
    const flags = c.fcntl(fd, c.F.GETFD);
    try std.testing.expectEqual(@as(c_int, 0), flags & c.FD_CLOEXEC);
    const command = try std.fmt.allocPrint(std.testing.allocator, "test ! -e /dev/fd/{d}", .{fd});
    defer std.testing.allocator.free(command);
    var cancel: p.Cancellation = .{};
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, command, &ctx.env, test_options, &cancel);
    defer freeResult(result);
    try std.testing.expect(!result.cleanup_failed);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term.?);
    try std.testing.expectEqual(flags, c.fcntl(fd, c.F.GETFD));
}
test "inherited descriptors reject stdio and duplicates before spawn" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const fd = c.open("/dev/null", .{ .CLOEXEC = true });
    try std.testing.expect(fd > 2);
    defer _ = c.close(fd);
    const duplicate = [_]c.fd_t{ fd, fd };
    const stdio = [_]c.fd_t{1};
    const negative = [_]c.fd_t{-1};
    for ([_][]const c.fd_t{ &duplicate, &stdio, &negative }) |inherited| {
        var options = test_options;
        options.inherited_fds = inherited;
        var cancel: p.Cancellation = .{};
        try std.testing.expectError(error.InvalidInheritedFd, run(std.testing.allocator, std.testing.io, ctx.root, "exit 91", &ctx.env, options, &cancel));
    }
}
test "Darwin process queries fail closed for missing leader and zero deadline" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // No signal, fork, or unrelated PID query: group zero is invalid at our
    // private boundary, and deadline zero must fail before libproc enumeration.
    try std.testing.expectError(error.ProcUnavailable, darwin.groupAlive(0, 100));
    try std.testing.expectError(error.ProcUnavailable, darwin.groupAlive(2, 0));
}
test "Darwin zombie-only signal failure is proven clean instead of cleanup failure" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const child = try spawn.start(std.testing.allocator, ctx.root, null, "/bin/bash", "exit 0", &ctx.env, .none);
    defer child.close();

    // Hold the direct child unreaped until it is an observable zombie.
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (!try observedExit(child.pid)) {
        try std.testing.expect(elapsed(std.testing.io, start) < 1000);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }

    // This kernel quirk is the point of the test. Skip where a group signal to
    // zombies still succeeds, so the post-signal proof would not be exercised.
    const probe = c.kill(-child.pid, @fromBackingInt(@intCast(0)));
    if (probe == 0 or std.posix.errno(probe) != .PERM) return error.SkipZigTest;

    // exited=true takes the short pre-signal proof; exited=false forces the
    // failed-delivery path that must absorb Darwin's EPERM without reporting a
    // cleanup failure. Both must only succeed on a complete dead-group proof.
    const since = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expect(signalOwned(std.testing.io, child.pid, true, true, .TERM, since, 500));
    try std.testing.expect(signalOwned(std.testing.io, child.pid, true, false, .TERM, since, 500));

    // No signal after this point: reap the still-owned child exactly once.
    var status: c_int = 0;
    try std.testing.expectEqual(child.pid, reap(child.pid, &status));
}
test "raw output overflow remains bounded and marks whole response truncated" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    var options = test_options;
    options.raw_output = true;
    options.output_bytes = 32;
    const result = try run(std.testing.allocator, std.testing.io, ctx.root, "printf '%100s' ''; printf '%100s' '' >&2", &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expect(result.truncated and !result.cleanup_failed);
    try std.testing.expectEqual(@as(u64, 100), result.stdout_bytes);
    try std.testing.expectEqual(@as(u64, 100), result.stderr_bytes);
    try std.testing.expect(result.stdout.len + result.stderr.len <= options.output_bytes.?);
}
test "raw capture exact boundary and tiny overflow never sanitize bytes" {
    const bytes = "\\u4f60中文\x00\xff\x1b";
    for (0..bytes.len + 5) |capacity| {
        var capture: Capture = .{ .data = try std.testing.allocator.alloc(u8, capacity) };
        defer std.testing.allocator.free(capture.data);
        for (bytes) |byte| try capture.add(&.{byte});
        const output = try capture.rawRender(std.testing.allocator);
        defer std.testing.allocator.free(output);
        try std.testing.expect(output.len <= capacity);
        try std.testing.expectEqual(bytes.len > capacity, capture.omitted);
        if (!capture.omitted) try std.testing.expectEqualStrings(bytes, output);
    }
}
test "binary output is escaped and rendered byte budget is strict" {
    var capture: Capture = .{ .data = try std.testing.allocator.alloc(u8, 64) };
    defer std.testing.allocator.free(capture.data);
    try capture.add("a\x1b\x00\xff\r\n\\");
    const rendered = try capture.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("a\\x1b\\x00\\xff\\x0d\n\\\\", rendered);

    for (0..17) |cap| {
        var small: Capture = .{ .data = try std.testing.allocator.alloc(u8, cap) };
        defer std.testing.allocator.free(small.data);
        try small.add("AB\x1b\xffCDEF\xff\x1bYZ");
        const text = try small.render(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expect(text.len <= cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
        for (text) |b| try std.testing.expect(b == '\n' or (b >= 32 and b <= 126));
    }
}
