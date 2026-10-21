//! Offline steering lifecycle probes; no shared test-root changes.
const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const cfg = @import("../core/config.zig");
const inbox = @import("../core/inbox.zig");
const Stage = enum { model, prepare, approval, result, stop, none, request, launch, late, execution, modal, modal_empty };
const Fake = struct {
    box: *r.Inbox,
    stage: Stage,
    queued: bool = false,
    calls: usize = 0,
    executions: usize = 0,
    users: usize = 0,
    cleared: usize = 0,
    results: usize = 0,
    submitted: usize = 0,
    payload: []const u8 = "change direction",
    fault: ?*std.testing.FailingAllocator = null,
    entered_modal: std.atomic.Value(bool) = .init(false),
    stop_ready: std.atomic.Value(bool) = .init(false),
    withdraw_permission: bool = false,
    withdraw_skipped: bool = false,
    withdraw_stop: bool = false,
    permissions: usize = 0,
    failed_withdrawals: usize = 0,
    fn queue(self: *Fake, stage: Stage) !void {
        if (self.queued or self.stage != stage) return;
        _ = try self.box.enqueue(std.testing.allocator, .steering, self.payload);
        self.queued = true;
    }
    fn call(raw: *anyopaque, _: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try std.testing.expectEqual(p.Purpose.normal, request.purpose);
        try self.queue(.model);
        if (self.calls > 1 or self.stage == .stop or self.stage == .none) return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} },
            .finish = .stop,
        } };
        return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{
                .{ .tool_call = .{ .id = "one", .name = "probe", .arguments = "{}" } },
                .{ .tool_call = .{ .id = "two", .name = "probe", .arguments = "{}" } },
            } },
            .finish = .tool_calls,
        } };
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        const self: *Fake = @ptrCast(@alignCast(raw));
        try self.queue(.prepare);
        return .{ .payload = raw, .description = "probe", .explicit_denial = if (self.stage == .approval) "ask" else null };
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.executions += 1;
        try self.queue(.execution);
        return .{ .text = "executed" };
    }
    fn authorize(raw: ?*anyopaque, permission: r.Permission, _: *const p.Cancellation) !r.Decision {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        self.permissions += 1;
        if (self.permissions > 1) return .allow_once;
        try self.queue(.approval);
        try std.testing.expect(permission.interrupt.?.hasSteering());
        return error.Steered;
    }
    fn event(raw: ?*anyopaque, ev: r.Event, _: *const p.Cancellation) !void {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        switch (ev) {
            .state => |state| {
                if (state == .calling_model) try self.queue(.request);
                if (state == .executing_tool) {
                    try self.queue(.launch);
                    if ((self.stage == .modal or self.stage == .modal_empty) and !self.entered_modal.load(.acquire)) {
                        try self.queue(.modal);
                        self.box.pauseClaims(true);
                        self.entered_modal.store(true, .release);
                    }
                }
            },
            .finished => try self.queue(.late),
            .tool_result => {
                if (self.withdraw_skipped and self.stage == .model) {
                    // Skip delivery must happen while the input is RESERVED:
                    // it cannot disappear between skipping and user commit.
                    const id = self.box.next_id;
                    if (self.box.withdraw(id)) |value| {
                        var entry = value;
                        entry.deinit();
                        return error.SkippedWithoutReservation;
                    }
                    self.failed_withdrawals += 1;
                }
                self.results += 1;
                try self.queue(.result);
            },
            .assistant_committed => |blocks| if (blocks.len == 1 and blocks[0] == .text) {
                try self.queue(.stop);
                if (self.stage == .stop) self.stop_ready.store(true, .release);
                if (self.withdraw_stop) if (self.box.snapshot().newest_id) |id| {
                    var entry = self.box.withdraw(id).?;
                    entry.deinit();
                };
                if (self.fault) |fault| {
                    fault.fail_index = fault.alloc_index;
                    fault.resize_fail_index = fault.resize_index;
                }
            },
            .user_committed => |user| {
                try std.testing.expectEqualStrings(self.payload, user.text);
                self.users += 1;
            },
            .permission_cleared => {
                self.cleared += 1;
                if (self.withdraw_permission) if (self.box.snapshot().newest_id) |id| {
                    var entry = self.box.withdraw(id).?;
                    entry.deinit();
                };
            },
            else => {},
        }
    }
    fn observe(raw: ?*anyopaque, observation: r.Observation) void {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        if (observation == .submitted) self.submitted += 1;
    }
    fn init(self: *Fake, config: *cfg.Config) !r.Runtime {
        var runtime = try r.Runtime.init(if (self.fault) |fault| fault.allocator() else std.testing.allocator, std.testing.io, config, .{ .context = self, .call_fn = call }, .{ .context = self, .schemas = &.{.{ .name = "probe", .description = "offline", .parameters_json = "{}" }}, .prepare_fn = prepare, .execute_fn = execute }, .{ .context = self, .emit_fn = event, .authorize_fn = authorize }, "");
        runtime.inbox = self.box;
        runtime.observer = .{ .context = self, .notify_fn = observe };
        return runtime;
    }
};
fn configValue() cfg.Config {
    return .{ .provider = .{ .base_url = "http://offline.invalid" }, .model = .{ .name = "fixture", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
}

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

fn enqueueOom(a: std.mem.Allocator) !void {
    var box: inbox.Inbox = .{};
    defer box.deinit();
    _ = box.enqueue(a, .steering, "text") catch |err| {
        try std.testing.expectEqual(@as(usize, 0), box.snapshot().steering);
        return err;
    };
}
test "steering inbox allocation failure is transactional" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, enqueueOom, .{});
}
