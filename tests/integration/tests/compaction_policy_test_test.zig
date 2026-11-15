test "prefix rewrite automatic and manual compaction sends canonical Anthropic tail without stale thinking" {
    const old: [15000]u8 = @splat('x');
    for ([_]bool{ false, true }) |manual| {
        var config = configuration();
        config.model.protocol = .anthropic;
        config.model.reasoning.?.format = .anthropic;
        config.model.context_tokens = windowForInputBudget(6000);
        try std.testing.expectEqual(@as(usize, 6000), c.inputBudget(config));
        var fake: PrefixFake = .{};
        var unused: Fake = .{};
        var runtime = try r.Runtime.init(a, std.testing.io, &config, .{ .context = &fake, .call_fn = PrefixFake.call }, unused.executor(), .{}, "");
        defer runtime.deinit();
        const alloc = runtime.arena.allocator();
        try runtime.history.append(alloc, try p.textMessage(alloc, .user, "old goal"));
        try runtime.history.append(alloc, try p.textMessage(alloc, .assistant, &old));
        try runtime.history.append(alloc, try p.textMessage(alloc, .user, "retained goal"));
        try runtime.history.append(alloc, try p.cloneMessage(alloc, signedTail(.anthropic)));
        try runtime.history.append(alloc, try p.cloneMessage(alloc, completed_result));
        var cancel: p.Cancellation = .{};
        if (manual) {
            const summary = try runtime.compactContext(&cancel);
            try std.testing.expectEqual(r.Status.success, summary.status);
            try std.testing.expectEqual(@as(usize, 0), fake.normal);
            try std.testing.expectEqualStrings("retained goal", runtime.messages()[1].blocks[0].text);
        }
        const result = try runtime.run("new goal", &cancel);
        try std.testing.expectEqual(r.Status.success, result.status);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 1), fake.normal);
        try std.testing.expectEqualStrings("high", config.model.reasoning_effort.?);
        try std.testing.expectEqual(@as(?u32, 65536), config.model.output_tokens);
    }
}
test "prefix rewrite commit only normalizes Anthropic including protected cloned message" {
    for ([_]p.Protocol{ .anthropic, .responses, .chat }) |protocol| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const source = [_]p.Message{
            .{ .role = .user, .blocks = &.{.{ .text = "goal" }}, .replay = signedTail(protocol).replay },
            .{ .role = .assistant, .blocks = &.{.{ .text = "old" }} },
            signedTail(protocol),
            completed_result,
        };
        const next = try c.commit(arena.allocator(), &source, .{ .cut = 2, .protected_index = 0, .before_tokens = 100 }, "small summary");
        try std.testing.expect(c.hasSummaryPrefix(next.items));
        try std.testing.expectEqual(protocol != .anthropic, next.items[1].replay != null);
        try std.testing.expectEqual(protocol != .anthropic, next.items[2].replay != null);
        try std.testing.expectEqualStrings("goal", next.items[1].blocks[0].text);
        try std.testing.expectEqualStrings("completed-id", next.items[3].blocks[0].tool_result.call_id);
        try std.testing.expect(source[2].replay != null);
        if (protocol != .anthropic) try std.testing.expectEqualStrings(synthetic_replay, next.items[2].replay.?.json);
    }
}
test "prefix rewrite restore clears only summarized Anthropic owned replay and leaves uncompressed signatures" {
    for ([_]bool{ false, true }) |summarized| for ([_]p.Protocol{ .anthropic, .responses, .chat }) |protocol| {
        var config = configuration();
        config.model.protocol = protocol;
        config.model.reasoning.?.format = if (protocol == .anthropic) .anthropic else .standard;
        var fake: Fake = .{};
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "original");
        defer runtime.deinit();
        var state = try runtime.checkpoint();
        const source = [_]p.Message{
            .{ .role = if (summarized) .context else .user, .blocks = &.{.{ .text = c.summary_marker ++ "fixture summary" }} },
            signedTail(protocol),
            completed_result,
        };
        state.messages = &source;
        try runtime.restoreCheckpoint(state);
        const cleared = summarized and protocol == .anthropic;
        try std.testing.expectEqual(!cleared, runtime.messages()[1].replay != null);
        try std.testing.expectEqual(@as(usize, if (cleared) 2 else 3), runtime.messages()[1].blocks.len);
        try std.testing.expectEqualStrings(synthetic_replay, source[1].replay.?.json);
        if (!cleared) try std.testing.expectEqualStrings(synthetic_replay, runtime.messages()[1].replay.?.json);
        try std.testing.expectEqualStrings("completed-id", runtime.messages()[2].blocks[0].tool_result.call_id);
        try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.summaries);
    };
}
test "prefix rewrite normalized checkpoint clone failure is transactional" {
    try std.testing.checkAllAllocationFailures(a, normalizedRestoreAllocation, .{});
}
test "prefix rewrite restored summarized Anthropic history sends without stale protocol state" {
    var config = configuration();
    config.model.protocol = .anthropic;
    config.model.reasoning.?.format = .anthropic;
    var fake: PrefixFake = .{};
    var unused: Fake = .{};
    var runtime = try r.Runtime.init(a, std.testing.io, &config, .{ .context = &fake, .call_fn = PrefixFake.call }, unused.executor(), .{}, "");
    defer runtime.deinit();
    var state = try runtime.checkpoint();
    state.messages = &.{
        .{ .role = .context, .blocks = &.{.{ .text = c.summary_marker ++ "fixture" }} },
        .{ .role = .user, .blocks = &.{.{ .text = "retained goal" }} },
        signedTail(.anthropic),
        completed_result,
    };
    try runtime.restoreCheckpoint(state);
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("new goal", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 1), fake.normal);
    try std.testing.expectEqual(@as(usize, 0), fake.summaries);
    try std.testing.expectEqualStrings(synthetic_replay, state.messages[2].replay.?.json);
}
test "compaction policy registry automatic explicit and disabled survive disk roundtrip" {
    const prefixes = [_][]const u8{
        "{\"llm\":{\"default\":\"local/m\",\"providers\":{\"local\":{\"base_url\":\"https://fixture.invalid/v1\",\"models\":{\"m\":{\"protocol\":\"chat\",\"context_tokens\":1000000}}}}},\"limits\":",
    };
    for (prefixes) |prefix| for ([_][]const u8{ "{}", "{\"compaction_enabled\":true}", "{\"compaction_enabled\":false}" }) |limits| {
        const raw = try std.mem.concat(a, u8, &.{ prefix, limits, "}" });
        defer a.free(raw);
        var parsed = try cfg.parse(a, raw);
        defer cfg.release(&parsed);
        const disabled = std.mem.indexOf(u8, limits, "false") != null;
        try std.testing.expectEqual(!disabled, parsed.value.limits.compaction_enabled);
        var cloned = try cfg.clone(a, parsed.value);
        defer cfg.release(&cloned);
        var writer: std.Io.Writer.Allocating = .init(a);
        defer writer.deinit();
        try cfg.writeDisk(cloned.value, &writer.writer);
        var again = try cfg.parse(a, writer.written());
        defer cfg.release(&again);
        try std.testing.expectEqualDeep(parsed.value.limits, again.value.limits);
    };
    // Latest-only declarations reject removed fields, including former null/valid values.
    for ([_][]const u8{ "{\"summary_tokens\":null}", "{\"summary_tokens\":2048}", "{\"max_output_tokens\":16384}" }) |limits| {
        const raw = try std.mem.concat(a, u8, &.{ prefixes[0], limits, "}" });
        defer a.free(raw);
        try std.testing.expectError(error.UnknownField, cfg.parse(a, raw));
    }
    try cfg.validate(configuration());
}
test "compaction policy summary input room is independent of output capacity" {
    var config = configuration();
    for ([_]u32{ 32768, 131072, 1000000, 16777216 }) |window| {
        config.model.context_tokens = window;
        for ([_]?u32{ null, 20, 65536 }) |capacity| {
            config.model.output_tokens = capacity;
            const room = window - cfg.Policy.safety_tokens;
            try std.testing.expectEqual(@as(usize, room - 1), c.inputBudgetFor(config, .summary));
            try c.checkInputFor(config, .summary, room - 1);
            try std.testing.expectError(error.ContextTooLarge, c.checkInputFor(config, .summary, room));
            try std.testing.expectError(error.ContextTooLarge, c.checkInputFor(config, .summary, std.math.maxInt(usize)));
            try std.testing.expectEqual(capacity, config.model.output_tokens);
        }
    }
}
test "compaction policy disabled skips automatic summaries but enforces hard input budget" {
    for ([_]bool{ false, true }) |too_large| {
        var config = configuration();
        config.model.context_tokens = 8192;
        config.limits.compaction_enabled = false;
        var fake: Fake = .{};
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        // Size synthetic history against actual prompt overhead, not fixed bytes.
        // Keep the real budget and both the >80% and hard-stop assertions intact.
        try seed(&runtime, "");
        const budget = c.inputBudget(config);
        const target = c.threshold(budget, if (too_large) 110 else 90);
        const overhead = runtime.estimatedTokens();
        try std.testing.expect(target > overhead);
        const old = try a.alloc(u8, (target - overhead) * 3); // ASCII: three bytes per estimated token.
        defer a.free(old);
        @memset(old, 'x');
        runtime.history.items[1] = try p.textMessage(runtime.arena.allocator(), .assistant, old);
        try std.testing.expectEqual(target, runtime.estimatedTokens());
        try std.testing.expect(runtime.estimatedTokens() > c.threshold(budget, 80));
        try std.testing.expectEqual(too_large, runtime.estimatedTokens() > budget);
        var cancel: p.Cancellation = .{};
        const result = try runtime.run("new task", &cancel);
        try std.testing.expectEqual(@as(usize, 0), fake.summaries);
        try std.testing.expectEqual(@as(usize, if (too_large) 0 else 1), fake.normal);
        if (too_large) {
            try std.testing.expectEqual(error.ContextTooLarge, result.detail.?);
            try std.testing.expectEqualStrings(old, runtime.messages()[1].blocks[0].text);
        } else try std.testing.expectEqual(r.Status.success, result.status);
    }
}
test "compaction policy disabled still allows manual summary with frozen capacity without normal request" {
    const old: [10000]u8 = @splat('x');
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        var config = configuration();
        config.model.protocol = protocol;
        config.model.reasoning.?.format = if (protocol == .anthropic) .anthropic else .standard;
        config.limits.compaction_enabled = false;
        var fake: Fake = .{};
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        try seed(&runtime, &old);
        var cancel: p.Cancellation = .{};
        const result = try runtime.compactContext(&cancel);
        try std.testing.expectEqual(r.Status.success, result.status);
        try std.testing.expectEqual(config.model.output_tokens, fake.capacity);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), fake.normal);
        try std.testing.expectEqualStrings("recent task", runtime.messages()[1].blocks[0].text);
        try std.testing.expectEqualStrings("recent answer", runtime.messages()[2].blocks[0].text);
    }
}
test "compaction policy rejected summaries preserve canonical history and never retry" {
    const old: [10000]u8 = @splat('x');
    for ([_]bool{ false, true }) |exhausted| {
        var config = configuration();
        config.model.output_tokens = 32;
        // Returning the original text is invalid because it does not compact,
        // not because the model capability happens to be only 32 tokens.
        var fake: Fake = .{ .exhausted = exhausted, .summary_text = if (exhausted) null else &old };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        try seed(&runtime, &old);
        const before = runtime.messages().ptr;
        var cancel: p.Cancellation = .{};
        const result = try runtime.compactContext(&cancel);
        try std.testing.expectEqual(if (exhausted) error.OutputLimitReached else error.InsufficientCompaction, result.detail.?);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), fake.normal);
        try std.testing.expectEqual(@as(?u32, 32), fake.capacity);
        try std.testing.expectEqual(before, runtime.messages().ptr);
        try std.testing.expectEqual(@as(usize, 4), runtime.messages().len);
        try std.testing.expectEqualStrings(&old, runtime.messages()[1].blocks[0].text);
    }
}
test "compaction policy summary must be nonempty stop text and never executes tools or retries" {
    const old: [10000]u8 = @splat('x');
    for ([_]@FieldType(Fake, "summary_fault"){ .empty, .whitespace, .non_stop, .tool }) |fault| {
        var config = configuration();
        var fake: Fake = .{ .summary_fault = fault };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        try seed(&runtime, &old);
        const before = runtime.messages();
        var cancel: p.Cancellation = .{};
        const result = try runtime.compactContext(&cancel);
        try std.testing.expectEqual(r.Status.failed, result.status);
        try std.testing.expectEqual(if (fault == .empty or fault == .whitespace) error.InvalidSummary else error.SummaryRequestedTool, result.detail.?);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), fake.normal);
        try std.testing.expectEqual(before.ptr, runtime.messages().ptr);
        try std.testing.expectEqualDeep(before, runtime.messages());
    }
}
test "compaction policy exhausted automatic summary pauses without followup inference" {
    const old: [10000]u8 = @splat('x');
    var config = configuration();
    config.model.context_tokens = windowForInputBudget(4095);
    try std.testing.expectEqual(@as(usize, 4095), c.inputBudget(config));
    var fake: Fake = .{ .exhausted = true };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
    defer runtime.deinit();
    try seed(&runtime, &old);
    var cancel: p.Cancellation = .{};
    var goal = "new task".*;
    const result = try runtime.run(&goal, &cancel);
    @memset(&goal, 'x');
    try std.testing.expectEqual(r.Status.paused, result.status);
    try std.testing.expectEqual(error.OutputLimitReached, result.detail.?);
    try std.testing.expectEqual(p.FailureKind.output_limit, result.model_failure.?);
    try std.testing.expectEqual(@as(usize, 1), fake.summaries);
    try std.testing.expectEqual(@as(usize, 0), fake.normal);
    try std.testing.expectEqualStrings(&old, runtime.messages()[1].blocks[0].text);
    try std.testing.expectEqual(@as(usize, 5), runtime.messages().len);
    try std.testing.expectEqualStrings("new task", runtime.messages()[4].blocks[0].text);
    try std.testing.expectEqual(@as(u32, 1), result.usage.summary_calls);
}
