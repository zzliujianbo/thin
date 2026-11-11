test "steering safe points complete batch before injected user and preserve original input" {
    for ([_]Stage{ .model, .prepare, .approval, .result, .stop, .launch, .execution }) |stage| {
        var box: r.Inbox = .{};
        defer box.deinit();
        var fake = Fake{ .box = &box, .stage = stage };
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.run("original goal", &cancel);
        try std.testing.expectEqual(r.Status.success, terminal.status);
        try std.testing.expectEqual(@as(usize, 2), fake.calls);
        try std.testing.expectEqual(@as(usize, 1), fake.users);
        try std.testing.expectEqual(@as(usize, 1), fake.submitted);
        try std.testing.expectEqual(@as(usize, if (stage == .result or stage == .execution) 1 else 0), fake.executions);
        try std.testing.expectEqual(@as(usize, if (stage == .approval) 1 else 0), fake.cleared);
        var tools: usize = 0;
        var original = false;
        for (runtime.history.items) |message| {
            for (message.blocks) |block| {
                if (block == .tool_result) tools += 1;
                if (message.role == .user and block == .text) {
                    if (std.mem.eql(u8, block.text, "original goal")) original = true;
                    if (std.mem.eql(u8, block.text, fake.payload) and stage != .stop) try std.testing.expectEqual(@as(usize, 2), tools);
                }
            }
        }
        try std.testing.expect(original);
        try std.testing.expectEqual(@as(usize, if (stage == .stop) 0 else 2), tools);
        try std.testing.expect(!box.snapshot().active);
    }
}
test "steering input limit restores lease and pauses without implicit resume" {
    var box: r.Inbox = .{};
    defer box.deinit();
    var fake = Fake{ .box = &box, .stage = .stop, .payload = "this exceeds limit" };
    var config = configValue();
    config.limits.max_response_bytes = 16;
    config.limits.max_event_bytes = 16;
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("goal", &cancel);
    try std.testing.expectEqual(r.Status.failed, terminal.status);
    try std.testing.expectEqual(error.InputTooLarge, terminal.detail.?);
    try std.testing.expect(box.snapshot().paused);
    try std.testing.expectEqual(@as(usize, 1), box.snapshot().steering);
    fake.stage = .none;
    const next = try runtime.run("new goal", &cancel);
    try std.testing.expectEqual(r.Status.success, next.status);
    try std.testing.expectEqual(@as(usize, 0), fake.users);
    try std.testing.expect(box.snapshot().paused);
    try std.testing.expect(box.claimNext() == null);
}
test "steering round pause preserves queue and original budget" {
    var box: r.Inbox = .{};
    defer box.deinit();
    var fake = Fake{ .box = &box, .stage = .model };
    var config = configValue();
    config.limits.max_rounds = 1;
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("goal", &cancel);
    try std.testing.expectEqual(r.Status.paused, terminal.status);
    try std.testing.expectEqual(error.RoundLimit, terminal.detail.?);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.executions);
    try std.testing.expect(box.snapshot().paused);
}
test "steering pre-send event does not spend a round and late seal stays pending" {
    for ([_]Stage{ .request, .late }) |stage| {
        var box: r.Inbox = .{};
        defer box.deinit();
        var fake = Fake{ .box = &box, .stage = stage };
        var config = configValue();
        config.limits.max_rounds = 2;
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.run("goal", &cancel);
        try std.testing.expectEqual(r.Status.success, terminal.status);
        try std.testing.expectEqual(@as(usize, if (stage == .request) 1 else 0), fake.users);
        if (stage == .late) {
            try std.testing.expectEqual(@as(usize, 1), box.snapshot().steering);
            const lease = box.claimNext().?;
            var entry = box.commit(lease).?;
            entry.deinit();
        }
    }
}
test "steering history clone OOM restores unconsumed reserved text" {
    var box: r.Inbox = .{};
    defer box.deinit();
    var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const large: [64000]u8 = @splat('x');
    var fake = Fake{ .box = &box, .stage = .stop, .payload = &large, .fault = &fault };
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("original", &cancel);
    try std.testing.expectEqual(r.Status.failed, terminal.status);
    try std.testing.expectEqual(error.OutOfMemory, terminal.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.users);
    const snap = box.snapshot();
    try std.testing.expect(snap.paused);
    try std.testing.expectEqual(@as(usize, 1), snap.steering);
    try std.testing.expectEqual(@as(usize, large.len), snap.newest_bytes);
    var entry = box.withdraw(snap.newest_id.?).?;
    defer entry.deinit();
    try std.testing.expectEqualStrings(&large, entry.text);
}
test "steering confirmation blocks new tool launch without skipping empty modal and remains cancelable" {
    const Job = struct {
        runtime: *r.Runtime,
        cancel: *p.Cancellation,
        local: bool,
        fn run(self: *@This()) !r.Terminal {
            return if (self.local) self.runtime.executeCommand("!probe", self.cancel) else self.runtime.run("goal", self.cancel);
        }
    };
    for (0..5) |mode| {
        var box: r.Inbox = .{};
        defer box.deinit();
        var fake = Fake{ .box = &box, .stage = if (mode == 1) .modal_empty else .modal };
        if (mode == 3) {
            _ = try box.enqueue(std.testing.allocator, .steering, fake.payload);
            fake.queued = true;
        }
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        var job = Job{ .runtime = &runtime, .cancel = &cancel, .local = mode >= 3 };
        var future = try std.Io.concurrent(std.testing.io, Job.run, .{&job});
        defer {
            cancel.cancel();
            _ = future.cancel(std.testing.io) catch {};
        }
        var attempts: usize = 0;
        while (!fake.entered_modal.load(.acquire) and attempts < 500) : (attempts += 1)
            try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
        try std.testing.expect(fake.entered_modal.load(.acquire));
        try std.testing.expect(!box.beginTool());
        try std.testing.expectEqual(@as(usize, 0), fake.executions);
        const canceled = mode == 2 or mode == 4;
        if (canceled) cancel.cancel() else box.pauseClaims(false);
        const terminal = try future.await(std.testing.io);
        try std.testing.expectEqual(if (canceled) r.Status.canceled else r.Status.success, terminal.status);
        try std.testing.expectEqual(@as(usize, if (mode == 1) 2 else if (mode == 3) 1 else 0), fake.executions);
        try std.testing.expectEqual(@as(usize, if (mode == 0) 1 else 0), fake.users);
        if (canceled) try std.testing.expect(box.snapshot().paused);
        if (mode >= 3) {
            try std.testing.expectEqual(@as(usize, 0), fake.calls);
            try std.testing.expectEqual(@as(usize, 1), box.snapshot().steering);
        }
    }
}
test "steering withdrawn approval retries original tools and skips require a reservation" {
    for (0..3) |mode| {
        var box: r.Inbox = .{};
        defer box.deinit();
        var fake = Fake{ .box = &box, .stage = if (mode == 0) .approval else if (mode == 1) .model else .stop, .withdraw_permission = mode == 0, .withdraw_skipped = mode == 1, .withdraw_stop = mode == 2 };
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.run("goal", &cancel);
        try std.testing.expectEqual(r.Status.success, terminal.status);
        try std.testing.expectEqual(@as(usize, if (mode == 0) 2 else 0), fake.executions);
        try std.testing.expectEqual(@as(usize, if (mode == 1) 1 else 0), fake.users);
        if (mode == 0) try std.testing.expectEqual(@as(usize, 3), fake.permissions);
        if (mode == 1) try std.testing.expectEqual(@as(usize, 2), fake.failed_withdrawals);
        if (mode == 2) try std.testing.expectEqual(@as(usize, 1), fake.calls);
    }
}
test "steering concurrent final stop withdrawal never buys a round without a committed user" {
    const Withdrawer = struct {
        fake: *Fake,
        ready: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        won: bool = false,
        fn run(self: *@This()) void {
            self.ready.store(true, .release);
            while (!self.fake.stop_ready.load(.acquire)) {
                if (self.done.load(.acquire)) return;
                std.atomic.spinLoopHint();
            }
            if (self.fake.box.withdraw(1)) |value| {
                var entry = value;
                entry.deinit();
                self.won = true;
            }
        }
    };
    var withdrawal_wins: usize = 0;
    for (0..128) |_| {
        var box: r.Inbox = .{};
        defer box.deinit();
        var fake = Fake{ .box = &box, .stage = .stop };
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        var withdrawer = Withdrawer{ .fake = &fake };
        const thread = try std.Thread.spawn(.{}, Withdrawer.run, .{&withdrawer});
        var joined = false;
        defer if (!joined) {
            withdrawer.done.store(true, .release);
            thread.join();
        };
        while (!withdrawer.ready.load(.acquire)) std.atomic.spinLoopHint();
        const terminal = try runtime.run("goal", &cancel);
        withdrawer.done.store(true, .release);
        thread.join();
        joined = true;
        if (withdrawer.won) withdrawal_wins += 1;
        try std.testing.expectEqual(r.Status.success, terminal.status);
        try std.testing.expectEqual(fake.users + 1, fake.calls);
    }
    try std.testing.expect(withdrawal_wins > 0);
}
test "steering inbox allocation failure is transactional" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, enqueueOom, .{});
}
