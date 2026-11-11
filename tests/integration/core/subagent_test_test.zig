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
test "service wrappers are optional and cleanup outranks cancellation" {
    var fake: FakeService = .{};
    const token: p.Cancellation = .{};
    const bare = sub.Service{ .context = &fake, .run_fn = FakeService.run };
    bare.beginTask(&token);
    try bare.checkReady();
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
