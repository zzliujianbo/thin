test "send maps a sealed run and a published terminal to SubagentFinished" {
    const a = std.testing.allocator;
    const root_token: p.Cancellation = .{};
    // Only the fields `send` actually reads are initialized: no Runtime, no
    // worker and no child session participate in this path.
    var service: SubagentService = .{ .deps = undefined };
    var aggregate: Aggregate = .{ .view = .{ .group_id = 1, .total = 1, .running = 1 } };
    var root: fs.Root = undefined;
    root.io = std.testing.io;
    var deps: Deps = undefined;
    deps.root = &root;
    const job = try a.create(Job);
    defer a.destroy(job);
    job.* = .{ .allocator = a, .deps = deps, .root_cancel = &root_token, .aggregate = &aggregate, .display_id = 1 };
    defer job.inbox.deinit();
    job.id = try a.dupe(u8, "subagent_1");
    defer a.free(job.id);
    service.current = job;

    const live: p.Cancellation = .{};
    // Before `beginRun` the epoch is 0: a pre-spawn message is accepted and the
    // caller owns the receipt. `beginRun` then opens the same run, so the parked
    // message is claimable inside it.
    const early = try SubagentService.send(@ptrCast(&service), a, .{ .id = job.id, .message = "before spawn" }, &live);
    a.free(early.text);
    job.inbox.beginRun();
    const lease = job.inbox.claimSteering().?;
    var consumed = job.inbox.commit(lease).?;
    consumed.deinit();

    // A sealed run refuses delivery: the seal and this send share the Inbox
    // lock, so the accepted message can no longer be reported as delivered. The
    // caller allocator here is the leak-checking test allocator, so a missing
    // error-path receipt release would be reported.
    try std.testing.expect(job.inbox.sealTask());
    try std.testing.expectError(error.SubagentFinished, SubagentService.send(@ptrCast(&service), a, .{ .id = job.id, .message = "after seal" }, &live));

    // A published terminal — even a canceled one — is refused under the same
    // job lock that made it visible, before any receipt exists.
    job.publishTerminal(.{ .status = .canceled, .detail = error.Canceled }, "", false);
    try std.testing.expect(job.isDone());
    try std.testing.expectError(error.SubagentFinished, SubagentService.send(@ptrCast(&service), a, .{ .id = job.id, .message = "after terminal" }, &live));
}

test "cache-copy OOM retains delivered results without pending finish reminders" {
    const a = std.testing.allocator;
    // Fail each cache transaction allocation: ID, encoded text, and list growth.
    for (0..3) |fail_index| for ([_]bool{ false, true }) |cleanup_failed| for ([_]bool{ false, true }) |retry_cache| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const root_token: p.Cancellation = .{};
        var root: fs.Root = undefined;
        root.io = std.testing.io;
        var runtime: r.Runtime = undefined;
        runtime.poisoned = false;
        var deps: Deps = undefined;
        deps.allocator = failing.allocator();
        deps.root = &root;
        deps.runtime = &runtime;
        var service: SubagentService = .{ .deps = deps, .root_cancel = &root_token };
        defer SubagentService.endTask(@ptrCast(&service), &root_token) catch unreachable;
        var aggregate: Aggregate = .{};
        const job = try a.create(Job);
        job.* = .{ .allocator = a, .deps = deps, .root_cancel = &root_token, .aggregate = &aggregate, .display_id = 1 };
        service.current = job;
        job.id = try a.dupe(u8, "subagent_1");
        const report = try a.dupe(u8, "complete retained report");
        job.publishTerminal(.{ .status = .success }, report, false);
        if (cleanup_failed) job.publishCleanup();

        const hint = (try service.service().beforeFinish(a, &root_token)).?;
        defer a.free(hint);
        try std.testing.expect(std.mem.indexOf(u8, hint, "subagent_1") != null);
        const delivered = try service.service().get(a, .{ .id = "subagent_1" }, &root_token);
        defer a.free(delivered.text);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(cleanup_failed, delivered.cleanup_failed);
        try std.testing.expectEqual(cleanup_failed, runtime.poisoned);
        try std.testing.expect(!delivered.canceled);
        try std.testing.expect(job.joined and job.result_delivered);
        try std.testing.expect(service.current == job);
        try std.testing.expectEqual(@as(usize, 0), service.collected.items.len);
        try std.testing.expect((try service.service().beforeFinish(a, &root_token)) == null);
        try std.testing.expectError(error.SubagentFinished, service.service().send(a, .{ .id = "subagent_1", .message = "too late" }, &root_token));

        // Explicit re-reads remain legal. Retry either succeeds transactionally
        // or fails cache allocation again; neither duplicates the stored result.
        failing.fail_index = if (retry_cache) std.math.maxInt(usize) else failing.alloc_index;
        const repeated = try service.service().get(a, .{ .id = "subagent_1", .wait = false }, &root_token);
        defer a.free(repeated.text);
        try std.testing.expectEqualStrings(delivered.text, repeated.text);
        try std.testing.expectEqual(@as(usize, if (retry_cache) 1 else 0), service.collected.items.len);
        try std.testing.expect((service.current == null) == retry_cache);
        try std.testing.expect((try service.service().beforeFinish(a, &root_token)) == null);
        failing.fail_index = failing.alloc_index;
        const canceled = try service.service().cancel(a, .{ .id = "subagent_1" }, &root_token);
        defer a.free(canceled.text);
        try std.testing.expectEqualStrings(delivered.text, canceled.text);
        try std.testing.expectEqual(cleanup_failed, canceled.cleanup_failed);
        try std.testing.expect(!root_token.isRequested());

        try SubagentService.endTask(@ptrCast(&service), &root_token);
        try std.testing.expect(service.current == null);
        try std.testing.expectEqual(@as(usize, 0), service.collected.items.len);
        try std.testing.expect(service.root_cancel == null);
        try std.testing.expectEqual(cleanup_failed, runtime.poisoned);
        try std.testing.expectError(error.UnknownSubagentId, service.service().get(a, .{ .id = "subagent_1" }, &root_token));
    };
}
