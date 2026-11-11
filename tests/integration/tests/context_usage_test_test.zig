test "changed checkpoint tool hash preserves server usage while stripping native replay" {
    const adapter = @import("../llm/anthropic.zig");
    var config = configuration();
    config.model.protocol = .anthropic;
    config.model.output_tokens = 4096; // Known fixture capacity, not a production fallback.
    for ([_]?u64{ 77, 0, null }) |saved_total| {
        var fake: FakeContext = .{ .steps = &.{} };
        var runtime = try init(&config, &fake);
        defer runtime.deinit();
        var state = try runtime.exportCheckpoint();
        var different_hash = state.tool_schema_hash.?;
        different_hash[0] ^= 1;
        state.tool_schema_hash = different_hash;
        state.last_context_tokens = saved_total;
        state.messages = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "question" }} },
            .{ .role = .assistant, .blocks = &.{
                .{ .reasoning = "private plan" },
                .{ .tool_call = .{ .id = "original-id", .name = "write_file", .arguments = "{}" } },
            }, .replay = .{
                .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .anthropic },
                .json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"private plan\",\"signature\":\"stale-signature\"},{\"type\":\"redacted_thinking\",\"data\":\"stale-redacted\"},{\"type\":\"tool_use\",\"id\":\"original-id\",\"name\":\"write_file\",\"input\":{}}]}",
            } },
            .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "original-id", .text = "saved result" } }} },
            .{ .role = .assistant, .blocks = &.{.{ .text = "answer" }} },
        };
        try runtime.restoreCheckpoint(state);
        try expectSnapshot(runtime.contextSnapshot(), saved_total, 32768);
        try t.expectEqual(saved_total, runtime.last_context_tokens);
        try t.expect(runtime.messages()[1].replay == null);
        const expected: []const p.Message = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "question" }} },
            .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "original-id", .name = "write_file", .arguments = "{}" } }} },
            .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "original-id", .text = "saved result" } }} },
            .{ .role = .assistant, .blocks = &.{.{ .text = "answer" }} },
        };
        try t.expectEqualDeep(expected, runtime.messages());
        const wire = try adapter.encode(t.allocator, .{
            .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .anthropic },
            .system = runtime.system,
            .messages = runtime.messages(),
            .tools = runtime.executor.schemas,
            .model_output_tokens = config.model.output_tokens,
        });
        defer t.allocator.free(wire);
        for ([_][]const u8{ "stale-signature", "stale-redacted", "private plan", "redacted_thinking" }) |stale|
            try t.expect(std.mem.indexOf(u8, wire, stale) == null);
        try t.expect(std.mem.indexOf(u8, wire, "original-id") != null);
        try t.expectEqual(@as(usize, 0), fake.calls);
        try t.expectEqual(@as(usize, 0), fake.tool_calls);
    }
}
test "context usage fresh runtime is known zero despite nonzero safety estimate" {
    const config = configuration();
    var fake: FakeContext = .{ .steps = &.{} };
    var runtime = try init(&config, &fake);
    defer runtime.deinit();
    fake.owner = &runtime;
    try t.expect(runtime.estimatedTokens() > 0);
    try expectSnapshot(runtime.contextSnapshot(), 0, 32768);
    try t.expectEqual(@as(usize, 0), fake.calls);
}
test "context usage replaces latest request and pending callbacks retain previous total" {
    const config = configuration();
    var fake: FakeContext = .{ .steps = &.{
        .{ .usage = .{ .total_tokens = 1000 } },
        .{ .usage = .{ .total_tokens = 110 }, .previous = 1000 },
    } };
    var runtime = try init(&config, &fake);
    defer runtime.deinit();
    fake.owner = &runtime;
    const first = try run(&runtime, "first");
    try t.expectEqual(r.Status.success, first.status);
    try expectTerminal(&runtime, &fake, first, 1000);
    const second = try run(&runtime, "second");
    try t.expectEqual(r.Status.success, second.status);
    try expectTerminal(&runtime, &fake, second, 110);
    try t.expectEqual(@as(usize, 2), fake.calls);
    try t.expectEqual(@as(usize, 2), fake.pending_count);
    try expectSnapshot(fake.pending[0], 0, 32768);
    try expectSnapshot(fake.pending[1], 1000, 32768);
    try t.expectEqual(@as(usize, 2), fake.usage_count);
    try t.expectEqual(@as(usize, 2), fake.terminals);
    try expectSnapshot(fake.last_snapshot.?, 110, 32768);
    try t.expectEqual(@as(?u64, 110), second.usage.normal.total_tokens);
    try t.expectEqual(@as(u32, 1), second.usage.normal_calls);
}
test "context usage reported total wins and cache reasoning are never added twice" {
    const cases = [_]struct { usage: p.Usage, total: u64 }{
        .{ .usage = .{ .input_tokens = 20, .output_tokens = 10, .total_tokens = 1000, .cached_input_tokens = 18, .cache_write_tokens = 12, .reasoning_tokens = 9 }, .total = 1000 },
        .{ .usage = .{ .input_tokens = 20, .output_tokens = 10, .cached_input_tokens = 18, .cache_write_tokens = 12, .reasoning_tokens = 9 }, .total = 30 },
        .{ .usage = .{ .input_tokens = std.math.maxInt(u64), .output_tokens = 1, .total_tokens = 7 }, .total = 7 },
    };
    for (cases) |case| {
        const config = configuration();
        const steps = [_]Step{.{ .usage = case.usage }};
        var fake: FakeContext = .{ .steps = &steps };
        var runtime = try init(&config, &fake);
        defer runtime.deinit();
        fake.owner = &runtime;
        const terminal = try run(&runtime, "usage");
        try t.expectEqual(r.Status.success, terminal.status);
        try expectTerminal(&runtime, &fake, terminal, case.total);
        try t.expectEqual(@as(usize, 1), fake.calls);
        try t.expectEqual(@as(usize, 1), fake.usage_count);
        try t.expectEqualDeep(case.usage, fake.usage_values[0]);
    }
}
test "context usage missing partial overflow are unknown but explicit zero is known" {
    const cases = [_]struct { usage: p.Usage, total: ?u64 }{
        .{ .usage = .{}, .total = null },
        .{ .usage = .{ .input_tokens = 10 }, .total = null },
        .{ .usage = .{ .output_tokens = 10 }, .total = null },
        .{ .usage = .{ .input_tokens = std.math.maxInt(u64), .output_tokens = 1 }, .total = null },
        .{ .usage = .{ .total_tokens = 0 }, .total = 0 },
    };
    for (cases) |case| {
        const config = configuration();
        const steps = [_]Step{.{ .usage = case.usage }};
        var fake: FakeContext = .{ .steps = &steps };
        var runtime = try init(&config, &fake);
        defer runtime.deinit();
        fake.owner = &runtime;
        const terminal = try run(&runtime, "usage");
        try t.expectEqual(r.Status.success, terminal.status);
        try expectTerminal(&runtime, &fake, terminal, case.total);
        try expectSnapshot(fake.last_snapshot.?, case.total, 32768);
        try t.expectEqual(@as(usize, 1), fake.calls);
        try t.expectEqual(@as(usize, 1), fake.terminals);
    }
}
test "context usage thrown model call invalidates known value in failed terminal" {
    const config = configuration();
    var fake: FakeContext = .{ .steps = &.{
        .{ .usage = .{ .total_tokens = 1000 } },
        .{ .previous = 1000, .throws = true },
    } };
    var runtime = try init(&config, &fake);
    defer runtime.deinit();
    fake.owner = &runtime;
    try expectTerminal(&runtime, &fake, try run(&runtime, "known"), 1000);
    const terminal = try run(&runtime, "throw");
    try t.expectEqual(r.Status.failed, terminal.status);
    try t.expectEqual(error.FixtureCallFailed, terminal.detail.?);
    try expectTerminal(&runtime, &fake, terminal, null);
    try t.expectEqual(@as(u32, 0), terminal.usage.normal_calls);
    try t.expectEqual(@as(usize, 2), fake.calls);
    try t.expectEqual(@as(usize, 2), fake.terminals);
}
test "context usage invalid input and pre cancellation preserve previous request" {
    const config = configuration();
    var fake: FakeContext = .{ .steps = &.{.{ .usage = .{ .total_tokens = 1000 } }} };
    var runtime = try init(&config, &fake);
    defer runtime.deinit();
    fake.owner = &runtime;
    try expectTerminal(&runtime, &fake, try run(&runtime, "known"), 1000);
    const invalid = try run(&runtime, " \t\n");
    try t.expectEqual(r.Status.failed, invalid.status);
    try t.expectEqual(error.InvalidInput, invalid.detail.?);
    try expectTerminal(&runtime, &fake, invalid, 1000);
    var cancel: p.Cancellation = .{};
    cancel.cancel();
    const canceled = try runtime.run("not sent", &cancel);
    try t.expectEqual(r.Status.canceled, canceled.status);
    try expectTerminal(&runtime, &fake, canceled, 1000);
    try t.expectEqual(@as(u32, 0), invalid.usage.normal_calls);
    try t.expectEqual(@as(u32, 0), canceled.usage.normal_calls);
    try t.expectEqual(@as(usize, 1), fake.calls);
    try t.expectEqual(@as(usize, 3), fake.terminals);
}
test "context usage auto fallback displays final request but accounts both attempts" {
    var config = configuration();
    config.model.protocol = .auto;
    var fake: FakeContext = .{ .steps = &.{
        .{ .protocol = .responses, .failure = .unsupported_protocol, .usage = .{ .total_tokens = 12 } },
        .{ .usage = .{ .total_tokens = 1000 } },
    } };
    var runtime = try init(&config, &fake);
    defer runtime.deinit();
    fake.owner = &runtime;
    const terminal = try run(&runtime, "fallback");
    try t.expectEqual(r.Status.success, terminal.status);
    try expectTerminal(&runtime, &fake, terminal, 1000);
    try t.expectEqual(@as(usize, 2), fake.calls);
    try t.expectEqual(@as(usize, 2), fake.usage_count);
    try expectSnapshot(fake.usage_owners[0], 1000, 32768);
    try expectSnapshot(fake.usage_owners[1], 1000, 32768);
    try t.expectEqual(@as(u32, 2), terminal.usage.normal_calls);
    try t.expectEqual(@as(?u64, 1012), terminal.usage.normal.total_tokens);
    try t.expectEqual(p.Protocol.chat, runtime.selector.effective());
}
test "context usage disconnect on usage cannot lose owner final total or terminal" {
    const config = configuration();
    var fake: FakeContext = .{ .steps = &.{.{ .usage = .{ .total_tokens = 1000 } }}, .disconnect_usage = true };
    var runtime = try init(&config, &fake);
    defer runtime.deinit();
    fake.owner = &runtime;
    const terminal = try run(&runtime, "disconnect");
    try t.expectEqual(r.Status.failed, terminal.status);
    try t.expectEqual(error.HostDisconnected, terminal.detail.?);
    try expectTerminal(&runtime, &fake, terminal, 1000);
    try t.expectEqual(@as(usize, 1), fake.usage_count);
    try t.expectEqual(@as(usize, 1), fake.terminals);
    try t.expectEqual(@as(u32, 1), terminal.usage.normal_calls);
    try t.expectEqual(@as(?u64, 1000), terminal.usage.normal.total_tokens);
}
test "context usage interrupted fallback presentation is reconciled with final known or unknown snapshot" {
    for ([_]p.Usage{ .{ .total_tokens = 1000 }, .{} }) |final_usage| {
        var config = configuration();
        config.model.protocol = .auto;
        var display: presentation.State = .{};
        display.seed(.{ .tokens = 0, .limit = 32768 });
        const steps = [_]Step{
            .{ .protocol = .responses, .failure = .unsupported_protocol, .usage = .{ .total_tokens = 12 } },
            .{ .usage = final_usage },
        };
        var fake: FakeContext = .{ .steps = &steps, .disconnect_usage = true, .display = &display };
        var runtime = try init(&config, &fake);
        defer runtime.deinit();
        fake.owner = &runtime;
        const terminal = try run(&runtime, "interrupted fallback");
        try t.expectEqual(r.Status.failed, terminal.status);
        try t.expectEqual(error.HostDisconnected, terminal.detail.?);
        try t.expectEqual(@as(usize, 1), fake.usage_count);
        try expectSnapshot(fake.interrupted_display.?, 12, 32768);
        try expectTerminal(&runtime, &fake, terminal, final_usage.total());
        try t.expectEqualDeep(runtime.contextSnapshot(), display.context.?);
        try t.expectEqual(@as(u32, 2), terminal.usage.normal_calls);
        try t.expectEqual(@as(usize, 2), fake.calls);
        try t.expectEqual(@as(usize, 1), fake.terminals);
    }
}
test "context usage selection preserves effort window and rejects changes atomically" {
    var config = configuration();
    config.model.protocol = .responses;
    var fake: FakeContext = .{ .steps = &.{.{ .protocol = .responses, .usage = .{ .total_tokens = 1000 } }} };
    var runtime = try init(&config, &fake);
    defer runtime.deinit();
    fake.owner = &runtime;
    try expectTerminal(&runtime, &fake, try run(&runtime, "known"), 1000);
    var next = config.model;
    next.reasoning_effort = "high";
    next.context_tokens = 65536;
    try runtime.prepareSelection(next);
    config.model = next; // Host publishes only a validated selection.
    try expectSnapshot(runtime.contextSnapshot(), 1000, 65536);
    const selector = runtime.selector;
    const history_len = runtime.messages().len;
    const estimate = runtime.estimatedTokens();
    next.name = "other";
    runtime.busy.store(true, .release);
    try t.expectError(error.Busy, runtime.prepareSelection(next));
    runtime.busy.store(false, .release);
    try expectSnapshot(runtime.contextSnapshot(), 1000, 65536);
    runtime.poisoned = true;
    try t.expectError(error.UnsafeToContinue, runtime.prepareSelection(next));
    runtime.poisoned = false;
    try expectSnapshot(runtime.contextSnapshot(), 1000, 65536);
    next = config.model;
    next.protocol = .auto;
    next.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } };
    try t.expectError(error.IncompatibleReasoningProtocol, runtime.prepareSelection(next));
    try expectSnapshot(runtime.contextSnapshot(), 1000, 65536);
    try t.expectEqualDeep(selector, runtime.selector);
    try t.expectEqual(history_len, runtime.messages().len);
    try t.expectEqual(estimate, runtime.estimatedTokens());
    try t.expectEqual(@as(usize, 1), fake.calls);
    next = config.model;
    next.name = "other";
    try runtime.prepareSelection(next);
    config.model = next;
    try expectSnapshot(runtime.contextSnapshot(), null, 65536);
}
test "context usage effective protocol change invalidates even when model and declared auto stay unchanged" {
    var config = configuration();
    config.model.protocol = .auto;
    var fake: FakeContext = .{ .steps = &.{.{ .protocol = .responses, .failure = .transport, .usage = .{ .total_tokens = 1000 } }} };
    var runtime = try init(&config, &fake);
    defer runtime.deinit();
    fake.owner = &runtime;
    const terminal = try run(&runtime, "failed request still has real usage");
    try t.expectEqual(r.Status.failed, terminal.status);
    try expectTerminal(&runtime, &fake, terminal, 1000);
    try t.expectEqual(@as(usize, 1), runtime.messages().len);
    try t.expectEqual(p.Role.user, runtime.messages()[0].role);
    try t.expectEqual(p.Protocol.responses, runtime.selector.effective());
    var next = config.model;
    next.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } };
    const estimate = runtime.estimatedTokens();
    try runtime.prepareSelection(next);
    config.model = next;
    try t.expectEqual(p.Protocol.auto, config.model.protocol);
    try t.expectEqual(p.Protocol.chat, runtime.selector.effective());
    try expectSnapshot(runtime.contextSnapshot(), null, 32768);
    try t.expectEqual(estimate, runtime.estimatedTokens());
    try t.expectEqual(@as(usize, 1), fake.calls);
}
test "context usage protocol scope change invalidates retained history but fresh selection stays zero" {
    var config = configuration();
    var fake: FakeContext = .{ .steps = &.{.{ .usage = .{ .total_tokens = 1000 } }} };
    var runtime = try init(&config, &fake);
    defer runtime.deinit();
    fake.owner = &runtime;
    var next = config.model;
    next.name = "fresh-other";
    try runtime.prepareSelection(next);
    config.model = next;
    try expectSnapshot(runtime.contextSnapshot(), 0, 32768);
    try expectTerminal(&runtime, &fake, try run(&runtime, "known"), 1000);
    next.protocol = .auto; // Declared protocol changes, effective Chat stays the same.
    try runtime.prepareSelection(next);
    config.model = next;
    try t.expectEqual(p.Protocol.chat, runtime.selector.effective());
    try expectSnapshot(runtime.contextSnapshot(), null, 32768);
    try t.expect(runtime.messages().len > 0);
    try t.expectEqual(@as(usize, 1), fake.calls);
}
