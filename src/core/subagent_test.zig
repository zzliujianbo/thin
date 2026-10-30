//! Offline regressions for the in-process subagent seam: request/message
//! validation, bounded reports, the root mutation gate, service wrappers, the
//! ParentChannel, accepted-task hooks and the Runtime child-lifecycle contracts
//! (stop reminder, context-not-user, 3-reminder pause, end-task ordering and
//! cleanup domination). No network, App, UI or filesystem.

const std = @import("std");
const sub = @import("subagent.zig");
const p = @import("protocol.zig");
const runtime = @import("runtime.zig");
const cfg = @import("config.zig");
const knowledge = @import("knowledge.zig");

test "subagent request validation enforces utf8 nul and byte bounds" {
    const valid = sub.Request{ .task = "inspect release paths" };
    try sub.validate(valid);
    try sub.validate(.{ .task = "inspect", .context = "" });
    try std.testing.expectError(error.InvalidSubagentTask, sub.validate(.{ .task = "" }));
    try std.testing.expectError(error.InvalidSubagentTask, sub.validate(.{ .task = "a\x00b" }));
    try std.testing.expectError(error.InvalidSubagentTask, sub.validate(.{ .task = "\xff" }));
    var task: [sub.max_task_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.InvalidSubagentTask, sub.validate(.{ .task = &task }));
    try sub.validate(.{ .task = task[0..sub.max_task_bytes] });
    try std.testing.expectError(error.InvalidSubagentContext, sub.validate(.{ .task = "ok", .context = "a\x00b" }));
    try std.testing.expectError(error.InvalidSubagentContext, sub.validate(.{ .task = "ok", .context = "\xff" }));
    var context: [sub.max_context_bytes + 1]u8 = @splat('b');
    try std.testing.expectError(error.InvalidSubagentContext, sub.validate(.{ .task = "ok", .context = &context }));
    try sub.validate(.{ .task = "ok", .context = context[0..sub.max_context_bytes] });
}

test "job, query, send, cancel and message validation is strict and bounded" {
    try sub.validateQuery(.{ .id = "job-1" });
    try sub.validateQuery(.{ .id = "job-1", .wait = false });
    try std.testing.expectError(error.InvalidSubagentId, sub.validateQuery(.{ .id = "" }));
    try std.testing.expectError(error.InvalidSubagentId, sub.validateQuery(.{ .id = "a\x00b" }));
    try std.testing.expectError(error.InvalidSubagentId, sub.validateQuery(.{ .id = "\xff" }));
    var long_id: [sub.max_id_bytes + 1]u8 = @splat('i');
    try std.testing.expectError(error.InvalidSubagentId, sub.validateQuery(.{ .id = &long_id }));

    try sub.validateSend(.{ .id = "job-1", .message = "check the lock" });
    try std.testing.expectError(error.InvalidSubagentId, sub.validateSend(.{ .id = "", .message = "x" }));
    try std.testing.expectError(error.InvalidSubagentMessage, sub.validateSend(.{ .id = "job-1", .message = "" }));
    try std.testing.expectError(error.InvalidSubagentMessage, sub.validateSend(.{ .id = "job-1", .message = "\xff" }));
    try std.testing.expectError(error.InvalidSubagentMessage, sub.validateSend(.{ .id = "job-1", .message = "a\x00b" }));
    var long_message: [sub.max_message_bytes + 1]u8 = @splat('m');
    try std.testing.expectError(error.InvalidSubagentMessage, sub.validateSend(.{ .id = "job-1", .message = &long_message }));
    try sub.validateSend(.{ .id = "job-1", .message = long_message[0..sub.max_message_bytes] });

    try sub.validateCancel(.{ .id = "job-1" });
    try std.testing.expectError(error.InvalidSubagentId, sub.validateCancel(.{ .id = "" }));

    try sub.validateMessage(.{ .message = "progress", .wait_for_reply = true });
    try std.testing.expectError(error.InvalidSubagentMessage, sub.validateMessage(.{ .message = "" }));
    try std.testing.expectError(error.InvalidSubagentMessage, sub.validateMessage(.{ .message = "ok\x00" }));
}

test "report bounding is utf8 aligned and explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const short = try sub.boundReport(a, "small report");
    try std.testing.expectEqualStrings("small report", short.text);
    try std.testing.expect(!short.truncated);
    try std.testing.expectError(error.InvalidSubagentReport, sub.boundReport(a, "\xff"));

    // A 3-byte scalar straddles the cap: keep the prefix, drop the split scalar.
    var buffer: [sub.max_report_bytes + 3]u8 = @splat('a');
    buffer[sub.max_report_bytes - 1] = 0xe4;
    buffer[sub.max_report_bytes] = 0xb8;
    buffer[sub.max_report_bytes + 1] = 0xad;
    const bounded = try sub.boundReport(a, &buffer);
    try std.testing.expect(bounded.truncated);
    try std.testing.expectEqual(sub.max_report_bytes - 1, bounded.text.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bounded.text));
}

test "mutation gate owns exclusivity and cancellation never steals or frees it" {
    const io = std.testing.io;
    var gate: sub.MutationGate = .{};

    // Uncontended acquire then release is visible in the shared flag.
    var token: p.Cancellation = .{};
    try gate.acquire(io, &token);
    try std.testing.expect(gate.held.load(.acquire));
    gate.release();
    try std.testing.expect(!gate.held.load(.acquire));

    // An already-canceled caller returns before taking the gate.
    var canceled: p.Cancellation = .{ .requested = .init(true) };
    try std.testing.expectError(error.Canceled, gate.acquire(io, &canceled));
    try std.testing.expect(!gate.held.load(.acquire));

    // A canceled waiter must not clear another owner's lock.
    gate.held.store(true, .release);
    try std.testing.expectError(error.Canceled, gate.acquire(io, &canceled));
    try std.testing.expect(gate.held.load(.acquire));
    gate.release();
    try std.testing.expect(!gate.held.load(.acquire));
}

const FakeService = struct {
    begins: usize = 0,
    checks: usize = 0,
    runs: usize = 0,
    gets: usize = 0,
    sends: usize = 0,
    cancels: usize = 0,
    before_calls: usize = 0,
    ends: usize = 0,
    running: bool = false,
    fail_get_cleanup: bool = false,
    end_error: ?anyerror = null,

    fn begin(raw: *anyopaque, _: *const p.Cancellation) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.begins += 1;
    }
    fn check(raw: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.checks += 1;
    }
    fn run(raw: *anyopaque, a: std.mem.Allocator, _: sub.Request, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.runs += 1;
        return .{ .text = try a.dupe(u8, "run") };
    }
    fn get(raw: *anyopaque, a: std.mem.Allocator, query: sub.Query, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.gets += 1;
        return .{ .text = try a.dupe(u8, if (query.wait) "get-wait" else "get"), .canceled = true, .cleanup_failed = self.fail_get_cleanup };
    }
    fn send(raw: *anyopaque, a: std.mem.Allocator, message: sub.Send, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.sends += 1;
        return .{ .text = try a.dupe(u8, message.message) };
    }
    fn cancel(raw: *anyopaque, a: std.mem.Allocator, request: sub.Cancel, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.cancels += 1;
        return .{ .text = try a.dupe(u8, request.id) };
    }
    fn active(raw: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.running;
    }
    fn before(raw: *anyopaque, a: std.mem.Allocator, _: *const p.Cancellation) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.before_calls += 1;
        return try a.dupe(u8, "child job hint");
    }
    fn end(raw: *anyopaque, _: *const p.Cancellation) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.ends += 1;
        if (self.end_error) |err| return err;
    }

    fn full(self: *@This()) sub.Service {
        return .{
            .context = self,
            .run_fn = run,
            .begin_task_fn = begin,
            .check_fn = check,
            .get_fn = get,
            .send_fn = send,
            .cancel_fn = cancel,
            .active_fn = active,
            .before_finish_fn = before,
            .end_task_fn = end,
        };
    }
};

const FakeChannel = struct {
    calls: usize = 0,
    reply: bool = false,

    fn message(raw: *anyopaque, a: std.mem.Allocator, request: sub.Message, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.reply = request.wait_for_reply;
        return .{ .text = try a.dupe(u8, "receipt"), .cleanup_failed = false };
    }
};

test "service wrappers are optional and cleanup outranks cancellation" {
    var fake: FakeService = .{};
    const token: p.Cancellation = .{};
    const bare = sub.Service{ .context = &fake, .run_fn = FakeService.run };
    bare.beginTask(&token);
    try bare.checkReady();
    try std.testing.expect(!bare.active());
    try std.testing.expect((try bare.beforeFinish(std.testing.allocator, &token)) == null);
    try bare.endTask(&token);
    const bare_result = try bare.run(std.testing.allocator, .{ .task = "x" }, &token);
    defer std.testing.allocator.free(bare_result.text);
    try std.testing.expectError(error.SubagentUnavailable, bare.get(std.testing.allocator, .{ .id = "j" }, &token));
    try std.testing.expectError(error.SubagentUnavailable, bare.send(std.testing.allocator, .{ .id = "j", .message = "m" }, &token));
    try std.testing.expectError(error.SubagentUnavailable, bare.cancel(std.testing.allocator, .{ .id = "j" }, &token));
    try std.testing.expectEqual(@as(usize, 0), fake.begins);
    try std.testing.expectEqual(@as(usize, 0), fake.checks);
    try std.testing.expectEqual(@as(usize, 1), fake.runs);

    const full = fake.full();
    full.beginTask(&token);
    try full.checkReady();
    fake.running = true;
    try std.testing.expect(full.active());
    fake.running = false;
    try std.testing.expect(!full.active());
    const run_result = try full.run(std.testing.allocator, .{ .task = "x" }, &token);
    defer std.testing.allocator.free(run_result.text);
    const get_result = try full.get(std.testing.allocator, .{ .id = "j", .wait = false }, &token);
    defer std.testing.allocator.free(get_result.text);
    const send_result = try full.send(std.testing.allocator, .{ .id = "j", .message = "hello" }, &token);
    defer std.testing.allocator.free(send_result.text);
    const cancel_result = try full.cancel(std.testing.allocator, .{ .id = "j" }, &token);
    defer std.testing.allocator.free(cancel_result.text);
    const hint = (try full.beforeFinish(std.testing.allocator, &token)).?;
    defer std.testing.allocator.free(hint);
    try full.endTask(&token);
    try std.testing.expectEqual(@as(usize, 1), fake.begins);
    try std.testing.expectEqual(@as(usize, 1), fake.checks);
    try std.testing.expectEqual(@as(usize, 2), fake.runs);
    try std.testing.expectEqual(@as(usize, 1), fake.gets);
    try std.testing.expectEqual(@as(usize, 1), fake.sends);
    try std.testing.expectEqual(@as(usize, 1), fake.cancels);
    try std.testing.expectEqual(@as(usize, 1), fake.before_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.ends);
    try std.testing.expectEqualStrings("get", get_result.text);
    try std.testing.expect(get_result.canceled);
    try std.testing.expect(!get_result.is_error);

    // Cleanup failure dominates a simultaneous parent cancellation.
    fake.fail_get_cleanup = true;
    const cleanup = try full.get(std.testing.allocator, .{ .id = "j" }, &token);
    defer std.testing.allocator.free(cleanup.text);
    try std.testing.expect(cleanup.cleanup_failed);
    try std.testing.expect(cleanup.is_error);

    // Validation precedes callbacks: a bad id is rejected without dispatch.
    const before_gets = fake.gets;
    try std.testing.expectError(error.InvalidSubagentId, full.get(std.testing.allocator, .{ .id = "" }, &token));
    try std.testing.expectEqual(before_gets, fake.gets);

    // Wrapper end errors surface; the caller decides to poison.
    fake.end_error = error.CleanupFailed;
    try std.testing.expectError(error.CleanupFailed, full.endTask(&token));
}

test "parent channel validates bounded messages and dominates cleanup" {
    var fake: FakeChannel = .{};
    const channel = sub.ParentChannel{ .context = &fake, .message_fn = FakeChannel.message };
    const token: p.Cancellation = .{};
    const result = try channel.message(std.testing.allocator, .{ .message = "progress", .wait_for_reply = true }, &token);
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqualStrings("receipt", result.text);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.reply);
    try std.testing.expectError(error.InvalidSubagentMessage, channel.message(std.testing.allocator, .{ .message = "" }, &token));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

fn fixtureConfig() cfg.Config {
    return .{
        .provider = .{ .base_url = "https://fixture.invalid/v1" },
        .model = .{ .name = "fixture", .protocol = .chat, .context_tokens = 32768 },
        .limits = .{ .low_price_input = false },
    };
}

test "begin task hook fires once per accepted run with the accepted token" {
    const Fake = struct {
        calls: usize = 0,
        begins: usize = 0,
        token: ?*const p.Cancellation = null,
        fn call(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .success = .{ .finish = .stop, .message = try p.textMessage(a, .assistant, "answer") } };
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !runtime.Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: runtime.Prepared, _: *const p.Cancellation) !runtime.Execution {
            return error.UnexpectedTool;
        }
        fn begin(raw: *anyopaque, token: *const p.Cancellation) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.begins += 1;
            self.token = token;
        }
    };
    var config = fixtureConfig();
    var fake: Fake = .{};
    var instance = try runtime.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fake, .call_fn = Fake.call }, .{
        .context = &fake,
        .schemas = &.{},
        .prepare_fn = Fake.prepare,
        .execute_fn = Fake.execute,
        .begin_task_fn = Fake.begin,
    }, .{}, "");
    defer instance.deinit();
    var cancel: p.Cancellation = .{};
    _ = try instance.run("first", &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.begins);
    try std.testing.expect(fake.token == &cancel);
    // A rejected Busy run is not an accepted task: owner budgets are untouched.
    instance.busy.store(true, .release);
    try std.testing.expectError(error.Busy, instance.run("busy", &cancel));
    instance.busy.store(false, .release);
    try std.testing.expectEqual(@as(usize, 1), fake.begins);
    _ = try instance.run("second", &cancel);
    try std.testing.expectEqual(@as(usize, 2), fake.begins);
}

const Lifecycle = struct {
    hints: u8 = 0,
    hint_calls: usize = 0,
    begins: usize = 0,
    ends: usize = 0,
    before_calls: usize = 0,
    end_error: ?anyerror = null,
    finalized: usize = 0,
    user_sources: usize = 0,
    tool_sources: usize = 0,
    user_committed_events: usize = 0,
    finished: usize = 0,
    order_violation: bool = false,

    fn begin(raw: *anyopaque, _: *const p.Cancellation) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.begins += 1;
    }
    fn before(raw: *anyopaque, a: std.mem.Allocator, _: *const p.Cancellation) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.before_calls += 1;
        if (self.hints == 0) return null;
        self.hints -= 1;
        self.hint_calls += 1;
        return try a.dupe(u8, "Child job job-1 is still active; collect it with get_subagent_result.");
    }
    fn end(raw: *anyopaque, _: *const p.Cancellation) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.ends += 1;
        if (self.end_error) |err| return err;
    }
    fn retrieve(_: *anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror![]const u8 {
        return try a.dupe(u8, "");
    }
    fn finalize(raw: *anyopaque, capture: *const knowledge.Capture, _: p.Protocol) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.finalized += 1;
        if (self.ends == 0 or self.finished != 0) self.order_violation = true;
        for (capture.sources.items) |source| switch (source.kind) {
            .user => self.user_sources += 1,
            .tool => self.tool_sources += 1,
            .assistant => {},
        };
    }
    fn emit(raw: ?*anyopaque, event: runtime.Event, _: *const p.Cancellation) anyerror!void {
        const self: *Lifecycle = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .user_committed => self.user_committed_events += 1,
            .finished => {
                self.finished += 1;
                if (self.ends == 0) self.order_violation = true;
            },
            else => {},
        }
    }
};

const ModelFake = struct {
    plan: enum { success, failure, tool_once } = .success,
    calls: usize = 0,
    fn call(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        switch (self.plan) {
            .success => return .{ .success = .{ .finish = .stop, .message = try p.textMessage(a, .assistant, "answer") } },
            .failure => return .{ .failure = .{ .kind = .model, .message = "fixture failure" } },
            .tool_once => if (self.calls == 1) {
                const blocks = try a.alloc(p.Block, 1);
                blocks[0] = .{ .tool_call = .{ .id = "call-1", .name = "bash", .arguments = "{\"command\":\"true\"}" } };
                return .{ .success = .{ .finish = .tool_calls, .message = .{ .role = .assistant, .blocks = blocks } } };
            } else return .{ .success = .{ .finish = .stop, .message = try p.textMessage(a, .assistant, "done") } },
        }
    }
};

fn lifecycleExecutor(life: *Lifecycle) runtime.Executor {
    return .{
        .context = life,
        .schemas = &.{},
        .prepare_fn = LifecyclePrepare,
        .execute_fn = LifecycleExecute,
        .begin_task_fn = Lifecycle.begin,
        .before_finish_fn = Lifecycle.before,
        .end_task_fn = Lifecycle.end,
    };
}

fn LifecyclePrepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !runtime.Prepared {
    return error.UnexpectedTool;
}
fn LifecycleExecute(_: *anyopaque, a: std.mem.Allocator, _: runtime.Prepared, _: *const p.Cancellation) !runtime.Execution {
    return .{ .text = try a.dupe(u8, "ok") };
}

test "normal stop reminder is a context message and not user or memory evidence" {
    var config = fixtureConfig();
    var model: ModelFake = .{};
    var life: Lifecycle = .{ .hints = 1 };
    var instance = try runtime.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &model, .call_fn = ModelFake.call }, lifecycleExecutor(&life), .{ .context = &life, .emit_fn = Lifecycle.emit }, "");
    defer instance.deinit();
    instance.memory_hooks = .{ .context = &life, .retrieve_fn = Lifecycle.retrieve, .submit_fn = Lifecycle.finalize };
    var cancel: p.Cancellation = .{};
    const terminal = try instance.run("investigate", &cancel);
    try std.testing.expectEqual(runtime.Status.success, terminal.status);
    // The reminder continued the loop instead of sealing the task.
    try std.testing.expectEqual(@as(usize, 2), model.calls);
    try std.testing.expectEqual(@as(usize, 2), life.before_calls);
    try std.testing.expectEqual(@as(usize, 1), life.finalized);
    try std.testing.expect(!life.order_violation);
    try std.testing.expectEqual(@as(usize, 1), life.ends);
    // Original prompt is the only user source; the hint is not user input.
    try std.testing.expectEqual(@as(usize, 1), life.user_sources);
    try std.testing.expectEqual(@as(usize, 0), life.tool_sources);
    try std.testing.expectEqual(@as(usize, 0), life.user_committed_events);
    var hint_contexts: usize = 0;
    var user_messages: usize = 0;
    for (instance.messages()) |message| switch (message.role) {
        .context => if (std.mem.indexOf(u8, message.blocks[0].text, "Child job job-1") != null) {
            hint_contexts += 1;
            try std.testing.expectEqualStrings("Child job job-1 is still active; collect it with get_subagent_result.", message.blocks[0].text);
        },
        .user => user_messages += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), hint_contexts);
    try std.testing.expectEqual(@as(usize, 1), user_messages);
}

test "three stop reminders then SubagentInteractionRequired pauses the root" {
    var config = fixtureConfig();
    var model: ModelFake = .{};
    // One more hint than allowed proves the 4th stop is rejected, not appended.
    var life: Lifecycle = .{ .hints = 4 };
    var instance = try runtime.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &model, .call_fn = ModelFake.call }, lifecycleExecutor(&life), .{ .context = &life, .emit_fn = Lifecycle.emit }, "");
    defer instance.deinit();
    instance.memory_hooks = .{ .context = &life, .retrieve_fn = Lifecycle.retrieve, .submit_fn = Lifecycle.finalize };
    var cancel: p.Cancellation = .{};
    const terminal = try instance.run("wait for child", &cancel);
    try std.testing.expectEqual(runtime.Status.paused, terminal.status);
    try std.testing.expectEqual(error.SubagentInteractionRequired, terminal.detail.?);
    try std.testing.expect(runtime.policyPause(terminal.detail));
    // Initial stop + 3 reminder rounds; the 4th stop returns the pause error.
    try std.testing.expectEqual(@as(usize, 4), model.calls);
    // The 4th hint is generated by the host but rejected before being appended.
    try std.testing.expectEqual(@as(usize, 4), life.hint_calls);
    try std.testing.expectEqual(@as(usize, 1), life.ends);
    try std.testing.expectEqual(@as(usize, 0), life.finalized);
    try std.testing.expectEqual(@as(usize, 0), life.user_committed_events);
    var hint_contexts: usize = 0;
    for (instance.messages()) |message| {
        if (message.role == .context and std.mem.indexOf(u8, message.blocks[0].text, "Child job job-1") != null) hint_contexts += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), hint_contexts);
}

const LifecyclePlan = enum { success, failure, canceled, paused };

test "end task runs once on success failure cancel and paused before memory and finished" {
    for ([_]LifecyclePlan{ .success, .failure, .canceled, .paused }) |plan| {
        var config = fixtureConfig();
        var model: ModelFake = .{ .plan = if (plan == .failure) .failure else .success };
        // A paused root keeps its accepted goal without a model-output failure:
        // the host's fourth stop hint returns SubagentInteractionRequired.
        var life: Lifecycle = if (plan == .paused) .{ .hints = 4 } else .{};
        var instance = try runtime.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &model, .call_fn = ModelFake.call }, lifecycleExecutor(&life), .{ .context = &life, .emit_fn = Lifecycle.emit }, "");
        defer instance.deinit();
        instance.memory_hooks = .{ .context = &life, .retrieve_fn = Lifecycle.retrieve, .submit_fn = Lifecycle.finalize };
        var cancel: p.Cancellation = .{};
        if (plan == .canceled) cancel.cancel();
        const terminal = try instance.run("task", &cancel);
        const expected: runtime.Status = switch (plan) {
            .success => .success,
            .failure => .failed,
            .canceled => .canceled,
            .paused => .paused,
        };
        try std.testing.expectEqual(expected, terminal.status);
        try std.testing.expectEqual(@as(usize, 1), life.begins);
        try std.testing.expectEqual(@as(usize, 1), life.ends);
        try std.testing.expectEqual(@as(usize, 1), life.finished);
        try std.testing.expect(!life.order_violation);
        const finalized: usize = if (plan == .success) 1 else 0;
        try std.testing.expectEqual(finalized, life.finalized);
        try std.testing.expectEqual(finalized, life.user_sources);
    }
}

test "end task cleanup failure poisons and outranks success and cancellation" {
    for ([_]bool{ false, true }) |pre_canceled| {
        var config = fixtureConfig();
        var model: ModelFake = .{};
        var life: Lifecycle = .{ .end_error = error.CleanupFailed };
        var instance = try runtime.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &model, .call_fn = ModelFake.call }, lifecycleExecutor(&life), .{ .context = &life, .emit_fn = Lifecycle.emit }, "");
        defer instance.deinit();
        instance.memory_hooks = .{ .context = &life, .retrieve_fn = Lifecycle.retrieve, .submit_fn = Lifecycle.finalize };
        var cancel: p.Cancellation = .{};
        if (pre_canceled) cancel.cancel();
        const terminal = try instance.run("task", &cancel);
        try std.testing.expectEqual(runtime.Status.failed, terminal.status);
        try std.testing.expectEqual(error.CleanupFailed, terminal.detail.?);
        try std.testing.expect(instance.poisoned);
        // No Memory evidence is finalized after an unconfirmed cleanup.
        try std.testing.expectEqual(@as(usize, 0), life.finalized);
        try std.testing.expectEqual(@as(usize, 1), life.ends);
        try std.testing.expectEqual(@as(usize, 1), life.finished);
    }
}

test "tool progress does not extend the stop reminder budget" {
    var config = fixtureConfig();
    var model: ModelFake = .{ .plan = .tool_once };
    var life: Lifecycle = .{ .hints = 99 };
    var instance = try runtime.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &model, .call_fn = ModelFake.call }, lifecycleExecutor(&life), .{ .context = &life, .emit_fn = Lifecycle.emit }, "");
    defer instance.deinit();
    var cancel: p.Cancellation = .{};
    const terminal = try instance.run("work", &cancel);
    try std.testing.expectEqual(runtime.Status.paused, terminal.status);
    try std.testing.expectEqual(error.SubagentInteractionRequired, terminal.detail.?);
    // The tool round is not a reminder reset: exactly three context hints exist.
    var hint_contexts: usize = 0;
    for (instance.messages()) |message| {
        if (message.role == .context and std.mem.indexOf(u8, message.blocks[0].text, "Child job job-1") != null) hint_contexts += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), hint_contexts);
    try std.testing.expectEqual(@as(usize, 1), life.ends);
}
