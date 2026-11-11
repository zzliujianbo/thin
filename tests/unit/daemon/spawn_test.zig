test "worker launch notice requires both exec and owned group" {
    var worker: Worker = undefined;
    worker.launch = .init(0);
    const cases = [_]struct { notice: platform_process.LaunchNotice, expected: u8 }{
        .{ .notice = .{ .pid = 11, .launched = true, .group_owned = true }, .expected = 1 },
        .{ .notice = .{ .pid = 12, .launched = true, .group_owned = false }, .expected = 2 },
        .{ .notice = .{ .pid = 13, .launched = false, .group_owned = true }, .expected = 2 },
        .{ .notice = .{ .pid = 14, .launched = false, .group_owned = false }, .expected = 2 },
    };
    for (cases) |case| {
        worker.launch.store(0, .monotonic);
        launchNotify(&worker, case.notice);
        try testing.expectEqual(case.expected, worker.launch.load(.acquire));
    }
}
test "worker argv quotes paths, selection ids and optional flags" {
    const a = testing.allocator;
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const selection: ids.Id = "fedcba9876543210fedcba9876543210".*;

    const plain = try buildCommand(a, "/usr/bin/thin", "/run/user/1/thin/workers/aaaaaaaaaaaaaaaa.sock", id, .{
        .project = "/tmp/project",
        .owner = .daemon,
    });
    defer a.free(plain);
    try testing.expectEqualStrings(
        "exec /usr/bin/thin --internal-worker /run/user/1/thin/workers/aaaaaaaaaaaaaaaa.sock " ++
            "0123456789abcdef0123456789abcdef daemon --no-model-auto-refresh",
        plain,
    );
    try testing.expect(std.mem.indexOf(u8, plain, "--no-log") == null);

    const quoted = try buildCommand(a, "/opt/thin bin/thin", "/tmp/a b/it's.sock", id, .{
        .project = "/tmp/project",
        .owner = .foreground,
        .@"resume" = id,
        .auto_refresh_models = true,
    });
    defer a.free(quoted);
    try testing.expectEqualStrings(
        "exec '/opt/thin bin/thin' --internal-worker '/tmp/a b/it'\\''s.sock' " ++
            "0123456789abcdef0123456789abcdef foreground --worker-resume",
        quoted,
    );

    const restored = try buildCommand(a, "/bin/thin", "/run/aaaaaaaaaaaaaaaa.sock", id, .{
        .project = "/tmp/project",
        .owner = .daemon,
        .restore_selection = selection,
        .auto_refresh_models = true,
    });
    defer a.free(restored);
    try testing.expectEqualStrings(
        "exec /bin/thin --internal-worker /run/aaaaaaaaaaaaaaaa.sock " ++
            "0123456789abcdef0123456789abcdef daemon --worker-restore-selection fedcba9876543210fedcba9876543210",
        restored,
    );
}
test "worker params reject conflicting resume and selection modes" {
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    try testing.expectError(error.InvalidArguments, validateParams(.{
        .project = "/tmp/project",
        .owner = .foreground,
        .@"resume" = id,
        .restore_selection = id,
    }));
    try testing.expectError(error.InvalidArguments, validateParams(.{
        .project = "",
        .owner = .foreground,
    }));
    try validateParams(.{ .project = "/tmp/project", .owner = .foreground });
}
test "Darwin workers reject daemon ownership" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try testing.expectError(error.UnsupportedPlatform, validateParams(.{ .project = "/tmp/project", .owner = .daemon }));
}
test "Darwin lifetime pipe owns distinct nonblocking CLOEXEC ends" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const fds = try lifetimePipe();
    defer for (fds) |fd| fs.closeFd(fd);
    try testing.expect(fds[0] != fds[1]);
    for (fds) |fd| {
        const descriptor_flags = c.fcntl(fd, c.F.GETFD);
        try testing.expect(descriptor_flags >= 0 and descriptor_flags & c.FD_CLOEXEC != 0);
        const flags = c.fcntl(fd, c.F.GETFL);
        try testing.expect(flags >= 0);
        const status: c.O = @bitCast(@as(u32, @intCast(flags)));
        try testing.expect(status.NONBLOCK);
    }
}
test "cleanup grace covers the reported worker budget and never kills early" {
    // A worker that reports its own grace+timeout gets that budget plus the
    // fixed IPC/teardown margin, so legitimate long cleanups are never cut to
    // the local floor (the earlier fixed 2s + 1s behaviour).
    try testing.expectEqual(@as(u64, 12_000), cleanupGraceMs(.{ .grace_ms = 4_000, .timeout_ms = 6_000 }, 2_000));
    // The local floor stays a floor, never a cap.
    try testing.expectEqual(@as(u64, 2_300), cleanupGraceMs(.{ .grace_ms = 100, .timeout_ms = 200 }, 2_000));
    try testing.expectEqual(@as(u64, 2_000), cleanupGraceMs(.{ .grace_ms = 0, .timeout_ms = 0 }, 2_000));
    // No usable reply: conservative fallback, still above the old floor.
    try testing.expectEqual(@as(u64, 30_000), cleanupGraceMs(null, 2_000));
    try testing.expectEqual(@as(u64, 45_000), cleanupGraceMs(null, 45_000));
    // Saturated addition cannot wrap; the hard ceiling still bounds the wait.
    try testing.expectEqual(@as(u64, cleanup_max_grace_ms), cleanupGraceMs(.{ .grace_ms = 60_000, .timeout_ms = 60_000 }, 2_000));
    try testing.expectEqual(@as(u64, cleanup_max_grace_ms), cleanupGraceMs(.{ .grace_ms = std.math.maxInt(u64), .timeout_ms = std.math.maxInt(u64) }, 2_000));
    try testing.expectEqual(@as(u64, cleanup_max_grace_ms), cleanupGraceMs(null, std.math.maxInt(u64)));
}
test "private startup rejection is classified only from a confirmed mapped exit" {
    const Term = std.process.Child.Term;
    // A clean, mapped normal exit is the only accepted shape.
    try testing.expectEqual(error.SelectionNotFound, classifyStartupOutcome(.{ .term = .{ .exited = 70 } }).?);
    try testing.expectEqual(error.ApiKeyNotFound, classifyStartupOutcome(.{ .term = .{ .exited = 81 } }).?);
    try testing.expectEqual(error.SelectionEndpointUnavailable, classifyStartupOutcome(.{ .term = .{ .exited = 82 } }).?);
    // Unmapped, reserved-but-empty and out-of-band codes stay unclassified, so
    // the caller keeps the ordinary SpawnFailed path.
    for ([_]u8{ 0, 1, 69, 83, 90, 130, 143, 255 }) |code| {
        try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = code } }) == null);
    }
    try testing.expect(classifyStartupOutcome(.{}) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = Term{ .signal = .KILL } }) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = Term{ .signal = .TERM } }) == null);
    // A mapped code is not proof while cleanup is unconfirmed or a pid leaked.
    try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = 70 }, .cleanup_failed = true }) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = 70 }, .unreaped_pid = 1234 }) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = 70 }, .canceled = true }) == null);
    try testing.expect(classifyStartupOutcome(.{ .term = .{ .exited = 70 }, .timed_out = true }) == null);
}
test "only a self-terminated worker counts as a confirmed clean stop" {
    const Term = std.process.Child.Term;
    try testing.expect(termConfirmed(.{ .exited = 0 }));
    // The worker returns 128+signal only after cancelling, saving its final
    // checkpoint and closing its endpoint.
    for ([_]u8{ 129, 130, 131, 143 }) |code| try testing.expect(termConfirmed(.{ .exited = code }));
    try testing.expect(!termConfirmed(null));
    try testing.expect(!termConfirmed(.{ .exited = 1 }));
    try testing.expect(!termConfirmed(.{ .exited = 128 }));
    try testing.expect(!termConfirmed(.{ .exited = 137 }));
    // A reaped leader killed by a real signal proves nothing about the nested
    // services it owned in their own process groups.
    try testing.expect(!termConfirmed(Term{ .signal = .KILL }));
    try testing.expect(!termConfirmed(Term{ .signal = .TERM }));
    try testing.expect(!termConfirmed(Term{ .stopped = .TERM }));
    try testing.expect(!termConfirmed(.{ .unknown = 0x7f }));
}
test "settings reply budgets are read only from a correlated successful reply" {
    const a = testing.allocator;
    const ok_reply = std.fmt.comptimePrint("{{\"v\":{d},\"id\":1,\"ok\":true,\"limits\":{{\"cleanup_grace_ms\":4000,\"cleanup_timeout_ms\":6000}}}}", .{daemon_protocol.version});
    {
        var doc = try parseReply(a, ok_reply, settings_request_id);
        defer doc.deinit();
        const limits = replyCleanupLimits(doc.value) orelse return error.TestExpectedLimits;
        try testing.expectEqual(@as(u64, 4_000), limits.grace_ms);
        try testing.expectEqual(@as(u64, 6_000), limits.timeout_ms);
    }
    // Correlation is mandatory: another request id or a failed reply is not a
    // budget source, so the caller keeps the conservative fallback.
    try testing.expectError(error.BadResponse, parseReply(a, ok_reply, shutdown_request_id));
    try testing.expectError(error.BadResponse, parseReply(
        a,
        std.fmt.comptimePrint("{{\"v\":{d},\"id\":2,\"ok\":false,\"err\":\"rejected\"}}", .{daemon_protocol.version}),
        shutdown_request_id,
    ));
    try testing.expectError(error.BadResponse, parseReply(a, std.fmt.comptimePrint("{{\"v\":{d},\"id\":0,\"ok\":true}}", .{daemon_protocol.version}), shutdown_request_id));
    try testing.expectError(error.BadResponse, parseReply(a, "", settings_request_id));
    try testing.expectError(error.BadResponse, parseReply(a, "[]", settings_request_id));

    // A reply without the two numbers, or with unusable ones, yields no budget.
    const missing = try std.json.parseFromSlice(std.json.Value, a, std.fmt.comptimePrint("{{\"v\":{d},\"id\":1,\"ok\":true,\"limits\":{{\"command_timeout_ms\":10000}}}}", .{daemon_protocol.version}), .{});
    defer missing.deinit();
    try testing.expect(replyCleanupLimits(missing.value) == null);
    const malformed = try std.json.parseFromSlice(std.json.Value, a, std.fmt.comptimePrint("{{\"v\":{d},\"id\":1,\"ok\":true,\"limits\":{{\"cleanup_grace_ms\":-1,\"cleanup_timeout_ms\":6000}}}}", .{daemon_protocol.version}), .{});
    defer malformed.deinit();
    try testing.expect(replyCleanupLimits(malformed.value) == null);
    const too_large = try std.json.parseFromSlice(std.json.Value, a, std.fmt.comptimePrint("{{\"v\":{d},\"id\":1,\"ok\":true,\"limits\":{{\"cleanup_grace_ms\":4000,\"cleanup_timeout_ms\":60000000}}}}", .{daemon_protocol.version}), .{});
    defer too_large.deinit();
    try testing.expect(replyCleanupLimits(too_large.value) == null);
}
test "workers runtime directory is private and endpoints use only owner instance" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const base = buf[0..n];
    try tmp.dir.createDir(testing.io, "runtime", .fromMode(0o700));
    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    try tmp.dir.createDir(testing.io, "home", .default_dir);
    const runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{base});
    defer a.free(runtime);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("XDG_RUNTIME_DIR", runtime);

    var workers = try Workers.init(a, testing.io, &env);
    defer workers.deinit();

    const st = try metadata.statFd(workers.workers_fd);
    try testing.expectEqual(@as(u16, 0o700), @as(u16, @intCast(st.mode & 0o777)));
    try testing.expect(std.mem.endsWith(u8, workers.base_path, "/workers"));

    // Endpoint names are `<16hex>.sock`; the session id is not in the name.
    const endpoint = try std.fmt.allocPrint(a, "{s}/{s}.sock", .{ workers.base_path, "abcdef0123456789" });
    defer a.free(endpoint);
    try testing.expect(std.mem.endsWith(u8, endpoint, "/abcdef0123456789.sock"));
}
test "workers create rejects a missing project without leaving a child" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const base = buf[0..n];
    try tmp.dir.createDir(testing.io, "runtime", .fromMode(0o700));
    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    try tmp.dir.createDir(testing.io, "home", .default_dir);
    const runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{base});
    defer a.free(runtime);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("XDG_RUNTIME_DIR", runtime);

    var workers = try Workers.init(a, testing.io, &env);
    defer workers.deinit();
    try testing.expectError(error.FileNotFound, workers.create(.{
        .project = "/definitely/missing/project",
        .owner = .foreground,
    }));
    try testing.expectEqual(@as(usize, 0), workers.list.items.len);
}
