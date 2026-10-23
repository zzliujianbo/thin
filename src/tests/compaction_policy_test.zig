//! Offline policy contracts: input budgets, frozen model capacity and compaction disable semantics.
const std = @import("std");
const cfg = @import("../core/config.zig");
const c = @import("../core/context.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const a = std.testing.allocator;
const decision = @import("../core/decision.zig");
const anthropic = @import("../llm/anthropic.zig");
const synthetic_replay = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"fixture thought\",\"signature\":\"fixture-stale-signature\"},{\"type\":\"text\",\"text\":\"retained answer\"},{\"type\":\"tool_use\",\"id\":\"completed-id\",\"name\":\"read_file\",\"input\":{}}]}";

const PrefixFake = struct {
    summaries: usize = 0,
    normal: usize = 0,
    fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try std.testing.expectEqualStrings("high", req.reasoning_effort.?);
        try std.testing.expectEqual(@as(?u32, 65536), req.model_output_tokens);
        const wire = try anthropic.encode(alloc, req);
        if (req.purpose == .summary) {
            self.summaries += 1;
            try std.testing.expect(std.mem.indexOf(u8, wire, "fixture-stale-signature") == null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "fixture thought") == null);
            try std.testing.expectEqual(@as(usize, 0), req.tools.len);
            try std.testing.expectEqual(@as(usize, 1), req.messages.len);
            for (req.messages[0].blocks) |block| try std.testing.expect(block == .text);
        } else {
            self.normal += 1;
            try std.testing.expect(c.hasSummaryPrefix(req.messages));
            try std.testing.expect(std.mem.indexOf(u8, wire, "fixture-stale-signature") == null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "fixture thought") == null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "retained answer") != null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "completed-id") != null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "completed result") != null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "new goal") != null);
        }
        return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, "Summary or final answer.") } };
    }
};

fn signedTail(protocol: p.Protocol) p.Message {
    return .{ .role = .assistant, .blocks = &.{
        .{ .reasoning = "fixture thought" },                                                 .{ .text = "retained answer" },
        .{ .tool_call = .{ .id = "completed-id", .name = "read_file", .arguments = "{}" } },
    }, .replay = .{ .scope = .{ .connection = "https://fixture.invalid/v1", .model = "fixture", .protocol = protocol }, .json = synthetic_replay } };
}

const completed_result: p.Message = .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "completed-id", .text = "completed result" } }} };

test "prefix rewrite automatic and manual compaction sends canonical Anthropic tail without stale thinking" {
    const old: [8000]u8 = @splat('x');
    for ([_]bool{ false, true }) |manual| {
        var config = configuration();
        config.model.protocol = .anthropic;
        config.model.reasoning.?.format = .anthropic;
        config.model.context_tokens = 4096;
        config.limits.safety_tokens = 100;
        config.limits.compaction_trigger_percent = 60;
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

fn normalizedRestoreAllocation(alloc: std.mem.Allocator) !void {
    var config = configuration();
    config.model.protocol = .anthropic;
    config.model.reasoning.?.format = .anthropic;
    var fake: Fake = .{};
    var runtime = try r.Runtime.init(alloc, std.testing.io, &config, fake.model(), fake.executor(), .{}, "before");
    defer runtime.deinit();
    const system = runtime.system;
    var state = try runtime.checkpoint();
    state.system = "restored";
    state.messages = &.{
        .{ .role = .context, .blocks = &.{.{ .text = c.summary_marker ++ "fixture" }} },
        signedTail(.anthropic),
        completed_result,
    };
    runtime.restoreCheckpoint(state) catch |err| {
        try std.testing.expectEqual(system.ptr, runtime.system.ptr);
        try std.testing.expectEqual(@as(usize, 0), runtime.messages().len);
        try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.summaries);
        try std.testing.expectEqualStrings(synthetic_replay, state.messages[1].replay.?.json);
        return err;
    };
    try std.testing.expect(runtime.messages()[1].replay == null);
    try std.testing.expectEqualStrings("restored", runtime.system);
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

fn configuration() cfg.Config {
    return .{ .provider = .{ .base_url = "https://fixture.invalid/v1" }, .model = .{
        .name = "fixture",
        .protocol = .chat,
        .context_tokens = 1000000,
        .output_tokens = 65536,
        .reasoning_effort = "high",
        .reasoning = .{ .format = .standard, .map = .{ .high = "high" } },
    }, .limits = .{ .low_price_input = false } };
}

const LongTurn = struct {
    mode: enum { absent, success, failure, canceled, variant, duplicate, larger, bad_summary, cleanup_failure } = .success,
    decisions: usize = 0,
    summaries: usize = 0,
    normals: usize = 0,
    cancel: *p.Cancellation,
    fn decide(raw: *anyopaque, alloc: std.mem.Allocator, input: decision.Input, _: *const p.Cancellation) !decision.Output {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.decisions += 1;
        try std.testing.expect(input == .refine_outputs);
        try std.testing.expect(input.refine_outputs.len > 0 and input.refine_outputs.len <= 8);
        var bytes: usize = 0;
        for (input.refine_outputs) |item| {
            bytes += item.text.len + item.id.len;
            try std.testing.expect(item.text.len <= 8192);
            try std.testing.expect(std.mem.startsWith(u8, item.id, "bash-"));
        }
        try std.testing.expect(bytes <= 16384);
        switch (self.mode) {
            .failure => return error.FixtureDecisionUnavailable,
            .cleanup_failure => return error.CleanupFailed,
            .canceled => {
                self.cancel.cancel();
                return error.Canceled;
            },
            .variant => return .{ .memory_write = true },
            else => {},
        }
        const items = try alloc.alloc(decision.RefineItem, input.refine_outputs.len);
        for (items, 0..) |*item, i| item.* = .{
            .id = try alloc.dupe(u8, input.refine_outputs[if (self.mode == .duplicate) 0 else items.len - 1 - i].id),
            .text = if (self.mode == .larger) try alloc.dupe(u8, &(@as([8192]u8, @splat('z')))) else try alloc.dupe(u8, "GENERATED OUTPUT CLAIMS SUCCESS; not execution authority"),
        };
        return .{ .refine_outputs = items };
    }
    fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (req.purpose != .summary) {
            self.normals += 1;
            return error.UnexpectedNormal;
        }
        self.summaries += 1;
        try std.testing.expectEqual(@as(usize, 0), req.tools.len);
        try std.testing.expectEqual(@as(usize, 1), req.messages.len);
        const text = req.messages[0].blocks[0].text;
        try std.testing.expect(req.messages[0].replay == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "signature") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "current goal") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "\\\"exit_code\\\":7") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "\"is_error\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "timed_out") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "truncated") != null);
        const refined = self.mode == .success or self.mode == .bad_summary;
        try std.testing.expectEqual(refined, std.mem.indexOf(u8, text, "GENERATED OUTPUT CLAIMS SUCCESS") != null);
        try std.testing.expectEqual(refined, std.mem.indexOf(u8, text, "original_execution_metadata") != null);
        if (!refined) try std.testing.expect(std.mem.indexOf(u8, text, "ORIGINAL_STDOUT_MARKER") != null);
        return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, if (self.mode == .bad_summary) "" else "Older command steps failed with exit 7; work remains unresolved.") } };
    }
};

fn seedNativeTurn(runtime: *r.Runtime) !void {
    const alloc = runtime.arena.allocator();
    try runtime.history.append(alloc, try p.textMessage(alloc, .user, "current goal"));
    const noise: [4000]u8 = @splat('x');
    const signature: [1024]u8 = @splat('s');
    for (0..16) |i| {
        const id = try std.fmt.allocPrint(alloc, "bash-{d}", .{i});
        const native = try std.json.Stringify.valueAlloc(alloc, .{ .role = "assistant", .content = .{
            .{ .type = "thinking", .thinking = "private thought", .signature = &signature },
            .{ .type = "tool_use", .id = id, .name = "bash", .input = @as(std.json.Value, .{ .object = .{} }) },
        } }, .{});
        try runtime.history.append(alloc, .{ .role = .assistant, .blocks = try alloc.dupe(p.Block, &.{
            .{ .reasoning = "private thought" },
            .{ .tool_call = .{ .id = id, .name = "bash", .arguments = "{}" } },
        }), .replay = .{ .scope = .{ .connection = runtime.config.provider.base_url, .model = runtime.config.model.name, .protocol = .anthropic }, .json = native, .retain_turn = true } });
        const output = try std.json.Stringify.valueAlloc(alloc, .{ .stdout = try std.mem.concat(alloc, u8, &.{ "ORIGINAL_STDOUT_MARKER", &noise }), .stderr = "error: fixture.c:42 unresolved failure", .exit_code = 7, .timed_out = false, .canceled = false, .truncated = true, .stdout_bytes = 9000 }, .{});
        try runtime.history.append(alloc, .{ .role = .tool, .blocks = try alloc.dupe(p.Block, &.{.{ .tool_result = .{ .call_id = id, .text = output, .is_error = true, .truncated = true } }}) });
    }
    runtime.protected_index = 0;
}

test "compaction native sixteen same-user closed groups refinement rollback cancel and code-owned status" {
    for ([_]@FieldType(LongTurn, "mode"){ .absent, .success, .failure, .canceled, .variant, .duplicate, .larger, .bad_summary, .cleanup_failure }) |mode| {
        var config = configuration();
        config.model.protocol = .anthropic;
        config.model.reasoning.?.format = .anthropic;
        var cancel: p.Cancellation = .{};
        var fake: LongTurn = .{ .mode = mode, .cancel = &cancel };
        var unused: Fake = .{};
        var runtime = try r.Runtime.init(a, std.testing.io, &config, .{ .context = &fake, .call_fn = LongTurn.call }, unused.executor(), .{}, "");
        defer runtime.deinit();
        if (mode != .absent) runtime.decision_service = .{ .context = &fake, .decide_fn = LongTurn.decide };
        try seedNativeTurn(&runtime);
        const original = runtime.messages();
        const safe = try c.boundaries(a, original);
        defer a.free(safe);
        try std.testing.expect(!safe[3]); // Ordinary native retention stays strict.
        const wire = try anthropic.encode(a, .{ .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .anthropic }, .system = "fixture", .messages = original, .tools = &.{}, .model_output_tokens = config.model.output_tokens });
        defer a.free(wire);
        try std.testing.expect(std.mem.indexOf(u8, wire, "signature") != null);
        runtime.last_context_tokens = 777;
        const result = try runtime.compactContext(&cancel);
        try std.testing.expectEqual(@as(usize, if (mode == .absent) 0 else 1), fake.decisions);
        try std.testing.expectEqual(@as(usize, if (mode == .canceled or mode == .cleanup_failure) 0 else 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), fake.normals);
        if (mode == .canceled or mode == .bad_summary or mode == .cleanup_failure) {
            try std.testing.expectEqual(if (mode == .canceled) r.Status.canceled else r.Status.failed, result.status);
            if (mode == .cleanup_failure) {
                try std.testing.expect(runtime.poisoned);
                try std.testing.expectEqual(error.CleanupFailed, result.detail.?);
            }
            try std.testing.expectEqual(original.ptr, runtime.messages().ptr);
            try std.testing.expectEqualDeep(original, runtime.messages());
            try std.testing.expectEqual(@as(?u64, 777), runtime.last_context_tokens);
        } else {
            try std.testing.expectEqual(r.Status.success, result.status);
            try std.testing.expect(c.hasSummaryPrefix(runtime.messages()));
            try std.testing.expectEqualStrings("current goal", runtime.messages()[1].blocks[0].text);
            const tail = runtime.messages()[runtime.messages().len - 1].blocks[0].tool_result;
            try std.testing.expectEqualStrings("bash-15", tail.call_id);
            try std.testing.expect(tail.is_error and tail.truncated);
            const paired = try c.boundaries(a, runtime.messages());
            defer a.free(paired);
            try std.testing.expect(paired[paired.len - 1]);
            for (runtime.messages()) |message| try std.testing.expect(message.replay == null);
        }
    }
}

test "automatic compaction refinement cleanup failure blocks fitting normal inference and future tasks" {
    const Effects = struct {
        prepares: usize = 0,
        executes: usize = 0,
        fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.prepares += 1;
            return error.UnexpectedTool;
        }
        fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.executes += 1;
            return error.UnexpectedTool;
        }
    };
    var config = configuration();
    config.model.protocol = .anthropic;
    config.model.reasoning.?.format = .anthropic;
    config.model.context_tokens = 100000;
    config.limits.compaction_trigger_percent = 10;
    config.limits.compaction_target_percent = 5;
    var cancel: p.Cancellation = .{};
    var fake: LongTurn = .{ .mode = .cleanup_failure, .cancel = &cancel };
    var effects: Effects = .{};
    var runtime = try r.Runtime.init(a, std.testing.io, &config, .{ .context = &fake, .call_fn = LongTurn.call }, .{
        .context = &effects,
        .schemas = &.{},
        .prepare_fn = Effects.prepare,
        .execute_fn = Effects.execute,
    }, .{}, "");
    defer runtime.deinit();
    runtime.decision_service = .{ .context = &fake, .decide_fn = LongTurn.decide };
    try seedNativeTurn(&runtime);
    runtime.estimator.per_mille = 1100;
    runtime.last_context_tokens = 777;
    // Reserve for the staged user goal before borrowing the original headers.
    try runtime.history.ensureTotalCapacity(runtime.arena.allocator(), runtime.messages().len + 1);
    const original = runtime.messages();
    const original_json = try std.json.Stringify.valueAlloc(a, original, .{});
    defer a.free(original_json);
    const estimator = runtime.estimator;
    const before = runtime.estimatedTokens();
    try std.testing.expect(before > c.threshold(c.inputBudget(config), config.limits.compaction_trigger_percent));
    try c.checkInput(config, before + 100); // Old history plus the new goal still fits normal policy.
    for (0..2) |attempt| {
        const result = try runtime.run(if (attempt == 0) "new goal" else "blocked goal", &cancel);
        try std.testing.expectEqual(r.Status.failed, result.status);
        try std.testing.expectEqual(error.CleanupFailed, result.detail.?);
        try std.testing.expect(runtime.poisoned);
        try std.testing.expect(!cancel.isRequested());
        try std.testing.expectEqual(@as(usize, 1), fake.decisions);
        try std.testing.expectEqual(@as(usize, 0), fake.normals + fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), effects.prepares + effects.executes);
        try std.testing.expectEqual(@as(u32, 0), result.usage.summary_calls);
        try std.testing.expectEqual(@as(u32, 0), result.usage.normal_calls);
        try std.testing.expectEqual(original.ptr, runtime.messages().ptr);
        try std.testing.expectEqualDeep(original, runtime.messages());
        const after_json = try std.json.Stringify.valueAlloc(a, runtime.messages(), .{});
        defer a.free(after_json);
        try std.testing.expectEqualStrings(original_json, after_json);
        try std.testing.expectEqualDeep(estimator, runtime.estimator);
        try std.testing.expectEqual(@as(?u64, 777), runtime.last_context_tokens);
        try std.testing.expectEqual(before, runtime.estimatedTokens());
    }
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
    var config = configuration();
    try cfg.validate(config);
    config.limits.model_refresh_ttl_ms = 0;
    try std.testing.expectError(error.InvalidLimit, cfg.validate(config));
    config.limits.model_refresh_ttl_ms = 604800001;
    try std.testing.expectError(error.InvalidLimit, cfg.validate(config));
    config.limits.model_refresh_ttl_ms = 14400000;
    config.limits.model_refresh_cooldown_ms = 604800001;
    try std.testing.expectError(error.InvalidLimit, cfg.validate(config));
}

test "compaction policy summary input room is independent of output capacity" {
    var config = configuration();
    for ([_]u32{ 32768, 131072, 1000000, 16777216 }) |window| {
        config.model.context_tokens = window;
        for ([_]?u32{ null, 20, 65536 }) |capacity| {
            config.model.output_tokens = capacity;
            const room = window - config.limits.safety_tokens;
            try std.testing.expectEqual(@as(usize, room - 1), c.inputBudgetFor(config, .summary));
            try c.checkInputFor(config, .summary, room - 1);
            try std.testing.expectError(error.ContextTooLarge, c.checkInputFor(config, .summary, room));
            try std.testing.expectError(error.ContextTooLarge, c.checkInputFor(config, .summary, std.math.maxInt(usize)));
            try std.testing.expectEqual(capacity, config.model.output_tokens);
        }
    }
}

const Fake = struct {
    normal: usize = 0,
    summaries: usize = 0,
    capacity: ?u32 = null,
    exhausted: bool = false,
    summary_text: ?[]const u8 = null,
    summary_fault: enum { none, empty, whitespace, non_stop, tool } = .none,
    fn model(self: *Fake) p.Model {
        return .{ .context = self, .call_fn = call };
    }
    fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        try std.testing.expectEqualStrings("high", req.reasoning_effort.?);
        if (req.purpose == .summary) {
            self.summaries += 1;
            self.capacity = req.model_output_tokens;
            if (self.exhausted) return .{ .failure = .{ .kind = .output_limit, .message = "fixture limit" } };
        } else self.normal += 1;
        if (req.purpose == .summary) switch (self.summary_fault) {
            .none => {},
            .empty, .whitespace => return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, if (self.summary_fault == .empty) "" else " \t\r\n") } },
            .non_stop => return .{ .success = .{ .finish = .tool_calls, .message = try p.textMessage(alloc, .assistant, "Incomplete summary") } },
            .tool => return .{ .success = .{ .finish = .stop, .message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "forbidden", .name = "bash", .arguments = "{}" } }} } } },
        };
        return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, self.summary_text orelse "Earlier work completed.") } };
    }
    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return error.UnexpectedTool;
    }
    fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        return error.UnexpectedTool;
    }
    fn executor(self: *Fake) r.Executor {
        return .{ .context = self, .schemas = &.{}, .prepare_fn = prepare, .execute_fn = execute };
    }
};

fn seed(runtime: *r.Runtime, text: []const u8) !void {
    const alloc = runtime.arena.allocator();
    try runtime.history.append(alloc, try p.textMessage(alloc, .user, "old task"));
    try runtime.history.append(alloc, try p.textMessage(alloc, .assistant, text));
    try runtime.history.append(alloc, try p.textMessage(alloc, .user, "recent task"));
    try runtime.history.append(alloc, try p.textMessage(alloc, .assistant, "recent answer"));
}

test "compaction policy disabled skips automatic summaries but enforces hard input budget" {
    for ([_]bool{ false, true }) |too_large| {
        var config = configuration();
        config.model.context_tokens = 4096;
        config.limits.safety_tokens = 100;
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
    config.model.context_tokens = 4096;
    config.limits.safety_tokens = 100;
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
