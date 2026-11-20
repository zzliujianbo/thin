test "input budget is checked again before a Chat fallback and cancellation wins before retry" {
    const Probe = struct {
        config: *cfg.Config,
        cancel: *p.Cancellation,
        mode: enum { fits, oversized, canceled },
        responses: usize = 0,
        chat: usize = 0,

        fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(p.Purpose.normal, req.purpose);
            const input = c.rawTokens(req.system, req.tools, req.messages);
            if (req.scope.protocol == .responses) {
                self.responses += 1;
                // Change the available room between the probe and its retry.
                setBudget(self.config, if (self.mode == .fits) input else input - 1);
                if (self.mode == .canceled) self.cancel.cancel();
                return .{ .failure = .{ .kind = .unsupported_protocol, .message = "try chat" } };
            }
            try std.testing.expectEqual(p.Protocol.chat, req.scope.protocol);
            self.chat += 1;
            try std.testing.expectEqual(input, c.inputBudget(self.config.*));
            return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, "done") } };
        }
    };
    for ([_]@FieldType(Probe, "mode"){ .fits, .oversized, .canceled }) |mode| {
        var config = configuration();
        config.model.protocol = .auto;
        var cancel: p.Cancellation = .{};
        var probe = Probe{ .config = &config, .cancel = &cancel, .mode = mode };
        var tools = Fake{ .config = &config };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, .{ .context = &probe, .call_fn = Probe.call }, tools.executor(), .{}, "");
        defer runtime.deinit();
        const result = try runtime.run("one goal", &cancel);
        try std.testing.expectEqual(@as(usize, 1), probe.responses);
        try std.testing.expectEqual(@as(usize, if (mode == .fits) 1 else 0), probe.chat);
        try std.testing.expectEqual(@as(usize, 0), tools.tools);
        switch (mode) {
            .fits => try std.testing.expectEqual(r.Status.success, result.status),
            .oversized => {
                try std.testing.expectEqual(r.Status.failed, result.status);
                try std.testing.expectEqual(error.ContextTooLarge, result.detail.?);
            },
            .canceled => {
                try std.testing.expectEqual(r.Status.canceled, result.status);
                try std.testing.expectEqual(error.Canceled, result.detail.?);
            },
        }
    }
}

test "input budget for the next round includes the entire committed tool result" {
    for ([_]bool{ true, false }) |tight| {
        var config = configuration();
        config.limits.compaction_enabled = false;
        var fake = Fake{ .config = &config, .tool_mode = true };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        if (tight) {
            const prompt = p.Message{ .role = .user, .blocks = &.{.{ .text = "one goal" }} };
            setBudget(&config, c.rawTokens(runtime.system, &.{}, &.{prompt}));
        }
        const result = try runtime.run("one goal", &cancel);
        if (tight) {
            try std.testing.expectEqual(r.Status.failed, result.status);
            try std.testing.expectEqual(error.ContextTooLarge, result.detail.?);
            try std.testing.expectEqual(@as(usize, 1), fake.normal);
        } else {
            try std.testing.expectEqual(r.Status.success, result.status);
            try std.testing.expectEqual(@as(usize, 2), fake.normal);
        }
        try std.testing.expectEqual(@as(usize, 1), fake.tools);
        try std.testing.expectEqual(@as(usize, 0), fake.summaries);
        try std.testing.expectEqual(p.Role.tool, runtime.messages()[2].role);
        try std.testing.expectEqualStrings(&fake.output, runtime.messages()[2].blocks[0].tool_result.text);
        const safe = try c.boundaries(a, runtime.messages());
        defer a.free(safe);
        try std.testing.expect(safe[safe.len - 1]);
        try std.testing.expectEqualStrings("one goal", runtime.messages()[runtime.protected_index].blocks[0].text);
    }
}

test "input budget includes the manual summary instruction as well as the DATA view" {
    var config = configuration();
    var fake = Fake{ .config = &config };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
    defer runtime.deinit();
    const old: [12500]u8 = @splat('x');
    try seed(&runtime, &old);
    const before = runtime.messages();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const selection = try c.planManual(alloc, config, runtime.estimator, runtime.system, &.{}, before, 2);
    const instruction = try c.summaryInstruction(alloc, selection, before);
    const view = try c.summaryView(alloc, selection, before);
    const message: p.Message = .{ .role = .user, .blocks = &.{.{ .text = view }} };
    const summary_input = c.rawTokens(instruction, &.{}, &.{message});
    setBudget(&config, summary_input - 1);
    try c.checkInput(config, selection.minimum_tokens.?);
    try c.checkInput(config, c.rawTokens("", &.{}, &.{message}));
    try std.testing.expectError(error.ContextTooLarge, c.checkInput(config, summary_input));
    var cancel: p.Cancellation = .{};
    const result = try runtime.compactContext(&cancel);
    try std.testing.expectEqual(r.Status.failed, result.status);
    try std.testing.expectEqual(error.ContextTooLarge, result.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.summaries + fake.tools);
    try std.testing.expectEqual(before.ptr, runtime.messages().ptr);
    try std.testing.expectEqual(@as(usize, 4), runtime.messages().len);
    try std.testing.expectEqualStrings(&old, runtime.messages()[1].blocks[0].text);
    try std.testing.expectEqual(@as(usize, 2), runtime.protected_index);
    try std.testing.expectEqualDeep(r.UsageTotals{}, result.usage);
}

test "automatic summary complete input rejection is zero-attempt and rolls back the staged goal" {
    try automaticSummaryLocalRejection(false);
}

test "automatic summary with unknown Anthropic capacity makes no attempt and cannot rescue oversized history" {
    try automaticSummaryLocalRejection(true);
}

test "proactive compaction publishes triggering occupancy and resumes only after a successful summary" {
    const Capture = struct {
        last_snapshot: ?u64 = null,
        measured_before_compacting: ?u64 = null,
        fn emit(raw: ?*anyopaque, event: r.Event, _: *const p.Cancellation) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            switch (event) {
                .context_snapshot => |snapshot| self.last_snapshot = snapshot.tokens,
                .state => |phase| if (phase == .compacting) {
                    self.measured_before_compacting = self.last_snapshot;
                },
                else => {},
            }
        }
    };
    const old: [12500]u8 = @splat('x');
    for ([_]bool{ false, true }) |exhausted| {
        var config = configuration();
        var fake = Fake{ .config = &config, .exhausted = exhausted };
        var capture: Capture = .{};
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{ .context = &capture, .emit_fn = Capture.emit }, "");
        defer runtime.deinit();
        try seed(&runtime, &old);
        setBudget(&config, runtime.estimatedTokens() * 118 / 100);
        var cancel: p.Cancellation = .{};
        const result = try runtime.run("new goal", &cancel);
        const measured = capture.measured_before_compacting.?;
        try std.testing.expect(measured >= c.threshold(c.inputBudget(config), cfg.Policy.compaction_trigger_percent));
        try std.testing.expect(measured <= c.inputBudget(config));
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, if (exhausted) 0 else 1), fake.normal);
        try std.testing.expectEqual(@as(u64, config.model.context_tokens), result.context_snapshot.?.limit);
        if (exhausted) {
            try std.testing.expectEqual(r.Status.paused, result.status);
            try std.testing.expectEqual(error.OutputLimitReached, result.detail.?);
            try std.testing.expectEqual(p.FailureKind.output_limit, result.model_failure.?);
            try std.testing.expectEqualStrings("fixture cap", result.failureText());
            try std.testing.expectEqualStrings(&old, runtime.messages()[1].blocks[0].text);
            try std.testing.expectEqualStrings("new goal", runtime.messages()[runtime.protected_index].blocks[0].text);
        } else {
            try std.testing.expectEqual(r.Status.success, result.status);
            try std.testing.expectEqual(p.Role.context, runtime.messages()[0].role);
            try c.checkInput(config, runtime.estimatedTokens());
        }
    }
}

test "failed summary pauses with its cause and does not send the fitting normal request" {
    const old: [12500]u8 = @splat('x');
    for ([_]@FieldType(Fake, "summary_fault"){ .server, .transport, .invalid }) |fault| {
        var config = configuration();
        var fake = Fake{ .config = &config, .summary_fault = fault };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        try seed(&runtime, &old);
        setBudget(&config, runtime.estimatedTokens() * 118 / 100);
        var cancel: p.Cancellation = .{};
        const result = try runtime.run("new goal", &cancel);
        try std.testing.expectEqual(r.Status.paused, result.status);
        try std.testing.expectEqual(if (fault == .invalid) error.InvalidSummary else error.SummaryFailed, result.detail.?);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.tools);
        try std.testing.expectEqualStrings(&old, runtime.messages()[1].blocks[0].text);
        try std.testing.expectEqualStrings("new goal", runtime.messages()[runtime.protected_index].blocks[0].text);
        if (fault == .server) {
            try std.testing.expectEqual(p.FailureKind.server, result.model_failure.?);
            try std.testing.expectEqual(@as(?u16, 503), result.http_status);
            try std.testing.expectEqualStrings("fixture", result.failureText());
        } else try std.testing.expect(result.model_failure == null and result.http_status == null);
    }
}

test "restored history is readable but the next request must fit the current window" {
    var original = configuration();
    var fake = Fake{ .config = &original };
    var source = try r.Runtime.init(a, std.testing.io, &original, fake.model(), fake.executor(), .{}, "");
    defer source.deinit();
    const old: [12500]u8 = @splat('x');
    try seed(&source, &old);
    const bytes = try checkpoint.encode(a, try source.exportCheckpoint());
    defer a.free(bytes);
    const decoded = try checkpoint.decode(a, bytes);
    defer decoded.deinit();
    var current = original;
    current.limits.compaction_enabled = false;
    setBudget(&current, source.estimatedTokens() - 1);
    fake.config = &current;
    var restored = try r.Runtime.init(a, std.testing.io, &current, fake.model(), fake.executor(), .{}, "");
    defer restored.deinit();
    try restored.restoreCheckpoint(decoded.value);
    try std.testing.expectEqualDeep(source.messages(), restored.messages());
    var cancel: p.Cancellation = .{};
    const rejected = try restored.run("continue", &cancel);
    try std.testing.expectEqual(r.Status.failed, rejected.status);
    try std.testing.expectEqual(error.ContextTooLarge, rejected.detail.?);
    try std.testing.expectEqualDeep(source.messages(), restored.messages());
    try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.summaries + fake.tools);
}

test "retained prompt alone exceeding the window prevents automatic and manual summaries" {
    for ([_]bool{ true, false }) |manual| {
        var config = configuration();
        var fake = Fake{ .config = &config };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        try seed(&runtime, "previous work");
        setBudget(&config, c.fixedTokens(runtime.system, &.{}) - 1);
        var cancel: p.Cancellation = .{};
        const result = if (manual) try runtime.compactContext(&cancel) else try runtime.run("new goal", &cancel);
        try std.testing.expectEqual(r.Status.failed, result.status);
        try std.testing.expectEqual(error.ContextTooLarge, result.detail.?);
        try std.testing.expectEqual(@as(usize, 0), fake.summaries + fake.normal + fake.tools);
        try std.testing.expectEqual(@as(usize, 4), runtime.messages().len);
        try std.testing.expectEqualStrings("previous work", runtime.messages()[1].blocks[0].text);
        try std.testing.expectEqualStrings("recent answer", runtime.messages()[3].blocks[0].text);
    }
}

test "a reducing manual summary can commit without authorizing an oversized normal send" {
    const old: [12500]u8 = @splat('x');
    const summary: [9000]u8 = @splat('s');
    const startup: [6000]u8 = @splat('m'); // Part of the normal prompt, not of the summary request.
    var config = configuration();
    var fake = Fake{ .config = &config, .summary_text = &summary, .zero_input = true };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, &startup);
    defer runtime.deinit();
    try seed(&runtime, &old);
    const before = runtime.estimatedTokens();
    setBudget(&config, before - c.textTokens(&old) / 2);
    var cancel: p.Cancellation = .{};
    const compacted = try runtime.compactContext(&cancel);
    try std.testing.expectEqual(r.Status.success, compacted.status);
    try std.testing.expectEqual(@as(usize, 1), fake.summaries);
    try std.testing.expectEqual(p.Role.context, runtime.messages()[0].role);
    try std.testing.expect(runtime.estimatedTokens() < before);
    try std.testing.expectError(error.ContextTooLarge, c.checkInput(config, runtime.estimatedTokens()));
    config.limits.compaction_enabled = false;
    const rejected = try runtime.run("continue", &cancel);
    try std.testing.expectEqual(r.Status.failed, rejected.status);
    try std.testing.expectEqual(error.ContextTooLarge, rejected.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.normal);
    try std.testing.expectEqual(@as(usize, 1), fake.summaries);
}

test "a committed manual summary clears the remembered rejection at the same physical budget" {
    const old: [12500]u8 = @splat('x');
    const long_summary: [25000]u8 = @splat('s');
    var config = configuration();
    var fake = Fake{ .config = &config, .summary_text = &long_summary, .zero_input = true };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
    defer runtime.deinit();
    try seed(&runtime, &old);
    setBudget(&config, runtime.estimatedTokens() * 118 / 100);
    var cancel: p.Cancellation = .{};
    const first = try runtime.run("first goal", &cancel);
    try std.testing.expectEqual(r.Status.paused, first.status);
    try std.testing.expectEqual(error.InsufficientCompaction, first.detail.?);
    try std.testing.expectEqual(@as(usize, 1), fake.summaries);
    const rejected_size = runtime.estimatedTokens();
    fake.summary_text = "condensed background";
    try std.testing.expectEqual(r.Status.success, (try runtime.compactContext(&cancel)).status);
    try std.testing.expectEqual(@as(usize, 2), fake.summaries);
    // At least as much context as the rejected turn, still under the same
    // budget: a stale rejection would skip this third summary.
    const alloc = runtime.arena.allocator();
    try runtime.history.append(alloc, try p.textMessage(alloc, .user, &old));
    try runtime.history.append(alloc, try p.textMessage(alloc, .assistant, "regrown answer"));
    try std.testing.expect(runtime.estimatedTokens() >= rejected_size);
    try c.checkInput(config, runtime.estimatedTokens());
    try std.testing.expectEqual(r.Status.success, (try runtime.run("next goal", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 3), fake.summaries);
    try std.testing.expectEqual(@as(usize, 1), fake.normal);
}

test "remembered rejected summary is not repeated whether the next input fits or fails" {
    const old: [12500]u8 = @splat('x');
    const long_summary: [25000]u8 = @splat('s');
    for ([_]bool{ false, true }) |oversized| {
        var config = configuration();
        var fake = Fake{ .config = &config, .summary_text = &long_summary };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        try seed(&runtime, &old);
        setBudget(&config, runtime.estimatedTokens() * 118 / 100);
        var cancel: p.Cancellation = .{};
        const first = try runtime.run("first goal", &cancel);
        try std.testing.expectEqual(r.Status.paused, first.status);
        try std.testing.expectEqual(error.InsufficientCompaction, first.detail.?);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), fake.normal);
        const next = try runtime.run(if (oversized) &old else "second goal", &cancel);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqualStrings(&old, runtime.messages()[1].blocks[0].text);
        try std.testing.expectEqualStrings("first goal", runtime.messages()[4].blocks[0].text);
        if (oversized) {
            try std.testing.expectEqual(r.Status.failed, next.status);
            try std.testing.expectEqual(error.ContextTooLarge, next.detail.?);
            try std.testing.expectEqual(@as(usize, 0), fake.normal);
            try std.testing.expectEqual(@as(usize, 5), runtime.messages().len);
        } else {
            try std.testing.expectEqual(r.Status.success, next.status);
            try std.testing.expectEqual(@as(usize, 1), fake.normal);
            try std.testing.expectEqualStrings("second goal", runtime.messages()[5].blocks[0].text);
        }
    }
}
