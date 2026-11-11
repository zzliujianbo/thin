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
    try std.testing.expectEqual(@as(u32, 1), job.parent_sent);
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
    try std.testing.expectEqual(@as(u32, 1), job.parent_sent);
}
