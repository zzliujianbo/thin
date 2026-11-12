test "input budget registry declarations roundtrip without persisting derived price metadata" {
    const prefixes = [_][]const u8{
        "{\"llm\":{\"default\":\"local/m\",\"providers\":{\"local\":{\"base_url\":\"https://fixture.invalid/v1\",\"models\":{\"m\":{\"protocol\":\"chat\",\"context_tokens\":1000000}}}}},\"limits\":",
    };
    for (prefixes) |prefix| {
        const raw = try std.mem.concat(a, u8, &.{ prefix, "{\"low_price_input\":true,\"input_margin_tokens\":5000.0,\"max_input_tokens\":\"100000\",\"safety_tokens\":1,\"max_rounds\":null}}" });
        defer a.free(raw);
        var parsed = try cfg.parse(a, raw);
        defer cfg.release(&parsed);
        try std.testing.expect(parsed.value.limits.low_price_input);
        const empty_cache: @import("../app/model_metadata.zig").Cache = .{};
        try @import("../app/model_resolver.zig").applyDefault(parsed.arena.allocator(), &parsed.value, &empty_cache);
        parsed.value.model.input_price_threshold = 100000;
        parsed.value.model.input_price_flat_limit = 1000000;
        var cloned = try cfg.clone(a, parsed.value);
        defer cfg.release(&cloned);
        try std.testing.expectEqual(@as(?u32, 100000), cloned.value.model.input_price_threshold);
        try std.testing.expectEqual(@as(?u32, 1000000), cloned.value.model.input_price_flat_limit);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try cfg.writeDisk(cloned.value, &out.writer);
        try std.testing.expect(std.mem.find(u8, out.written(), "\"input_price_threshold\"") == null);
        try std.testing.expect(std.mem.find(u8, out.written(), "\"input_price_flat_limit\"") == null);
        const encoded = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
        defer encoded.deinit();
        const limits = encoded.value.object.get("limits").?.object;
        try std.testing.expectEqual(@as(usize, 4), limits.count());
        inline for (@typeInfo(cfg.Limits).@"struct".field_names) |field| try std.testing.expect(limits.get(field) != null);
        inline for (.{ "input_margin_tokens", "max_input_tokens", "safety_tokens", "max_rounds" }) |retired| {
            try std.testing.expect(limits.get(retired) == null);
        }
        var again = try cfg.parse(a, out.written());
        defer cfg.release(&again);
        try std.testing.expectEqualDeep(parsed.value.limits, again.value.limits);
        try std.testing.expect(again.value.model.input_price_threshold == null);
        try std.testing.expect(again.value.model.input_price_flat_limit == null);
    }
    for ([_][]const u8{ "{\"low_price_input\":\"true\"}", "{\"compaction_enabled\":0}", "{\"command_timeout_ms\":1.5}", "{\"request_timeout_ms\":\"1000\"}", "{\"unknown_input_tokens\":\"100000\"}", "{\"low_price_input\":true,\"low_price_input\":false}" }) |limits| {
        const raw = try std.mem.concat(a, u8, &.{ prefixes[0], limits, "}" });
        defer a.free(raw);
        if (cfg.parse(a, raw)) |value| {
            var parsed = value;
            cfg.release(&parsed);
            return error.ExpectedInvalidPolicy;
        } else |_| {}
    }
}
test "input budget known flat pricing is distinct from unknown and stays within its proven range" {
    var config = configuration();
    config.limits.low_price_input = true;
    config.model.input_price_threshold = null;
    config.model.input_price_flat_limit = 1000000;
    try std.testing.expectEqual(@as(usize, 995000), c.inputBudget(config));
    try c.checkInput(config, 995000);
    try std.testing.expectError(error.InputBudgetExceeded, c.checkInput(config, 995001));
    // A larger manual window cannot stretch the documented flat-price range.
    config.model.context_tokens = 2000000;
    try std.testing.expectEqual(@as(usize, 995000), c.inputBudget(config));
    config.model.input_price_threshold = 100000;
    try std.testing.expectEqual(@as(usize, 95000), c.inputBudget(config));
    config.model.input_price_threshold = null;
    config.model.input_price_flat_limit = null;
    try std.testing.expectError(error.UnknownInputPriceThreshold, c.checkInput(config, 1));
    // Explicit opt-out uses the actual physical context window.
    config.limits.low_price_input = false;
    try std.testing.expectEqual(@as(usize, 1995903), c.inputBudget(config));
}
test "input budget opt in min ceilings margin unknown and physical input room" {
    var config = configuration();
    try std.testing.expectEqual(@as(usize, 995903), c.inputBudget(config));
    config.limits.low_price_input = true;
    try std.testing.expectEqual(@as(usize, 95000), c.inputBudget(config));
    // Price policy constrains normal input only, never model output capacity.
    try c.checkInputFor(config, .normal, 95000);
    try std.testing.expectError(error.InputBudgetExceeded, c.checkInputFor(config, .normal, 95001));
    try c.checkInputFor(config, .summary, 95001);
    try std.testing.expectEqual(@as(?u32, 128000), config.model.output_tokens);
    try std.testing.expectEqual(@as(usize, 995903), c.inputBudgetFor(config, .summary));
    config.model.input_price_threshold = null;
    try std.testing.expectError(error.UnknownInputPriceThreshold, c.checkInputFor(config, .normal, 100));
    try c.checkInputFor(config, .summary, 100000);
    config.model.input_price_threshold = 100000;
    config.model.context_tokens = 32768;
    try std.testing.expectEqual(@as(usize, 28671), c.inputBudget(config));
    config.model.input_price_threshold = null;
    try std.testing.expectEqual(@as(usize, 0), c.inputBudget(config));
    try std.testing.expectError(error.UnknownInputPriceThreshold, c.checkInput(config, 1));
    config.model.input_price_threshold = 1000;
    try std.testing.expectError(error.InputBudgetExceeded, c.checkInput(config, 1));
    config.limits.low_price_input = false;
    try std.testing.expectEqual(@as(usize, 28671), c.inputBudget(config));
}
test "input budget cold default DeepSeek runs with protection enabled and no public cache" {
    const Store = @import("../app/auth_store.zig").Store;
    const resolver = @import("../app/model_resolver.zig");
    const metadata = @import("../app/model_metadata.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    var store = try Store.open(a, std.testing.io, home);
    defer store.deinit();
    var parsed = try store.loadOrInitialize();
    defer cfg.release(&parsed);
    const cache: metadata.Cache = .{};
    try resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &cache);
    try std.testing.expect(parsed.value.limits.low_price_input);
    try std.testing.expect(parsed.value.model.input_price_threshold == null);
    try std.testing.expectEqual(@as(?u32, 1000000), parsed.value.model.input_price_flat_limit);
    var fake = Fake{ .config = &parsed.value };
    var runtime = try r.Runtime.init(a, std.testing.io, &parsed.value, fake.model(), fake.executor(), .{}, "");
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const result = try runtime.run("small first request", &cancel);
    try std.testing.expectEqual(r.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.normal);
    try std.testing.expectEqual(@as(usize, 0), fake.summaries + fake.tools);
    const state = try runtime.checkpoint();
    try std.testing.expectEqual(@as(?u32, 1000000), state.input_price_flat_limit);
    const bytes = try checkpoint.encode(a, state);
    defer a.free(bytes);
    const decoded = try checkpoint.decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(state.input_price_flat_limit, decoded.value.input_price_flat_limit);
}
test "input budget unknown and oversized first goal pause before any inference and own the goal" {
    const large: [10000]u8 = @splat('x');
    for ([_]bool{ false, true }) |unknown| {
        var config = configuration();
        config.limits.low_price_input = true;
        config.model.input_price_threshold = if (unknown) null else 7000;
        var fake = Fake{ .config = &config };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        var goal = "fixture goal".*;
        const result = try runtime.run(if (unknown) &goal else &large, &cancel);
        @memset(&goal, 'z');
        try std.testing.expectEqual(r.Status.paused, result.status);
        try std.testing.expectEqual(if (unknown) error.UnknownInputPriceThreshold else error.InputBudgetExceeded, result.detail.?);
        try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.summaries + fake.tools);
        try std.testing.expectEqualStrings(if (unknown) "fixture goal" else &large, runtime.messages()[runtime.protected_index].blocks[0].text);
        try std.testing.expectEqual(@as(u64, 1000000), result.context_snapshot.?.limit);
    }
}
test "input budget full tool output succeeds or pauses with closed canonical group" {
    for ([_]bool{ true, false }) |tight| {
        var config = configuration();
        config.limits.low_price_input = true;
        config.model.input_price_threshold = 12000;
        config.limits.compaction_enabled = false;
        var fake = Fake{ .config = &config, .tool_mode = true };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        if (tight) {
            // Include Runtime's actual system preface, not just the user bytes.
            const prompt = p.Message{ .role = .user, .blocks = &.{.{ .text = "one goal" }} };
            config.model.input_price_threshold = @intCast(c.rawTokens(runtime.system, &.{}, &.{prompt}) + cfg.Policy.input_margin_tokens + 1);
        }
        const result = try runtime.run("one goal", &cancel);
        if (tight) {
            try std.testing.expectEqual(r.Status.paused, result.status);
            try std.testing.expectEqual(error.InputBudgetExceeded, result.detail.?);
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
test "input budget appended summary instruction cannot escape the complete request ceiling" {
    var config = configuration();
    config.limits.low_price_input = true;
    var fake = Fake{ .config = &config };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
    defer runtime.deinit();
    const old: [4000]u8 = @splat('x');
    try seed(&runtime, &old);
    const before = runtime.messages().ptr;
    // The actual pure-text summary view (not native/full history) must fit.
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const selection = try c.planManual(alloc, config, runtime.estimator, runtime.system, &.{}, runtime.messages(), 2);
    const instruction = try c.summaryInstruction(alloc, selection, runtime.messages());
    const view = try c.summaryView(alloc, selection, runtime.messages());
    const message: p.Message = .{ .role = .user, .blocks = &.{.{ .text = view }} };
    const summary_input = c.rawTokens(instruction, &.{}, &.{message});
    // Invert C - min(4096, C/8) - 1 so the complete request misses
    // the actual physical input window by exactly one token.
    config.model.context_tokens = @intCast(@max(2, summary_input + @min(cfg.Policy.safety_tokens, summary_input / 7)));
    try std.testing.expectEqual(summary_input - 1, c.inputBudgetFor(config, .summary));
    try std.testing.expect(c.rawTokens("", &.{}, &.{message}) <= c.inputBudgetFor(config, .summary));
    try std.testing.expectError(error.ContextTooLarge, c.checkInputFor(config, .summary, summary_input));
    const history = try alloc.alloc(p.Message, runtime.messages().len);
    for (runtime.messages(), 0..) |entry, i| history[i] = try p.cloneMessage(alloc, entry);
    const protected_index = runtime.protected_index;
    var cancel: p.Cancellation = .{};
    const result = try runtime.compactContext(&cancel);
    try std.testing.expectEqual(r.Status.failed, result.status);
    try std.testing.expectEqual(error.ContextTooLarge, result.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.summaries + fake.tools);
    try std.testing.expectEqual(before, runtime.messages().ptr);
    try std.testing.expectEqual(@as(usize, 4), runtime.messages().len);
    try std.testing.expectEqualDeep(@as([]const p.Message, history), runtime.messages());
    try std.testing.expectEqual(protected_index, runtime.protected_index);
    try std.testing.expectEqualDeep(r.UsageTotals{}, result.usage);
}
test "automatic summary complete input rejection is zero-attempt and retains accepted history" {
    try automaticSummaryLocalRejection(false);
}
test "automatic summary unknown Anthropic capacity is zero-attempt and retains accepted history" {
    try automaticSummaryLocalRejection(true);
}
test "input budget proactive summary uses policy threshold not one million window and retains failure" {
    const old: [12500]u8 = @splat('x');
    for ([_]bool{ false, true }) |exhausted| {
        var config = configuration();
        config.limits.low_price_input = true;
        config.model.input_price_threshold = 10000;
        var fake = Fake{ .config = &config, .exhausted = exhausted };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        try seed(&runtime, &old);
        var cancel: p.Cancellation = .{};
        const result = try runtime.run("new goal", &cancel);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, if (exhausted) 0 else 1), fake.normal);
        try std.testing.expectEqual(@as(u64, 1000000), result.context_snapshot.?.limit);
        if (exhausted) {
            try std.testing.expectEqual(error.OutputLimitReached, result.detail.?);
            try std.testing.expectEqualStrings(&old, runtime.messages()[1].blocks[0].text);
            try std.testing.expectEqualStrings("new goal", runtime.messages()[runtime.protected_index].blocks[0].text);
        } else {
            try std.testing.expectEqual(r.Status.success, result.status);
            try std.testing.expectEqual(p.Role.context, runtime.messages()[0].role);
            try std.testing.expect(runtime.estimatedTokens() < c.threshold(c.inputBudget(config), 50));
        }
    }
}
test "input budget failed paid summary stops no fallback or automatic repeated attempt and keeps goal" {
    const old: [12500]u8 = @splat('x');
    for ([_]@FieldType(Fake, "summary_fault"){ .server, .transport, .invalid }) |fault| {
        var config = configuration();
        config.limits.low_price_input = true;
        config.model.input_price_threshold = 10000;
        var fake = Fake{ .config = &config, .summary_fault = fault };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        try seed(&runtime, &old);
        var cancel: p.Cancellation = .{};
        const result = try runtime.run("new goal", &cancel);
        try std.testing.expectEqual(r.Status.paused, result.status);
        try std.testing.expectEqual(error.InputBudgetSummaryFailed, result.detail.?);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.tools);
        try std.testing.expectEqualStrings(&old, runtime.messages()[1].blocks[0].text);
        try std.testing.expectEqualStrings("new goal", runtime.messages()[runtime.protected_index].blocks[0].text);
        if (fault == .server) {
            try std.testing.expectEqual(p.FailureKind.server, result.model_failure.?);
            try std.testing.expectEqual(@as(?u16, 503), result.http_status);
        }
    }
}
test "input budget summary crosses 95K price tier while normal remains blocked and unknown price manual remains independent" {
    const old: [300000]u8 = @splat('x');
    for ([_]bool{ false, true }) |unknown| {
        var config = configuration();
        config.limits.low_price_input = true;
        if (unknown) config.model.input_price_threshold = null;
        var fake = Fake{ .config = &config };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        try seed(&runtime, &old);
        try std.testing.expect(runtime.estimatedTokens() > 95000);
        try std.testing.expectError(if (unknown) error.UnknownInputPriceThreshold else error.InputBudgetExceeded, c.checkInput(config, runtime.estimatedTokens()));
        var cancel: p.Cancellation = .{};
        const summary = try runtime.compactContext(&cancel);
        try std.testing.expectEqual(r.Status.success, summary.status);
        try std.testing.expect(fake.last_summary_input > 95000 and fake.last_summary_input < c.inputBudgetFor(config, .summary));
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), fake.normal);
        try std.testing.expect(runtime.estimatedTokens() < 95000);
        try std.testing.expect(config.limits.low_price_input);
        if (unknown) {
            // Commit used physical summary budget, not a fabricated normal proof.
            try std.testing.expectError(error.UnknownInputPriceThreshold, c.checkInput(config, runtime.estimatedTokens()));
            const next = try runtime.run("continue", &cancel);
            try std.testing.expectEqual(r.Status.paused, next.status);
            try std.testing.expectEqual(error.UnknownInputPriceThreshold, next.detail.?);
            try std.testing.expectEqual(@as(usize, 0), fake.normal);
            try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        } else try c.checkInput(config, runtime.estimatedTokens());
    }
}
test "input budget rejects a reducing summary whose resulting history still exceeds normal price budget" {
    var config = configuration();
    config.limits.low_price_input = true;
    config.model.input_price_threshold = 8000;
    const summary = try a.alloc(u8, c.inputBudget(config) * 3);
    defer a.free(summary);
    @memset(summary, 's'); // Text alone fills the budget; retained history adds more.
    var fake = Fake{ .config = &config, .summary_text = summary };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
    defer runtime.deinit();
    const old: [12500]u8 = @splat('x');
    try seed(&runtime, &old);
    const before = runtime.messages();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const selection = try c.planManual(scratch.allocator(), config, runtime.estimator, runtime.system, &.{}, before, 2);
    const candidate = try c.commit(scratch.allocator(), before, selection, summary);
    const after_tokens = c.rawTokens(runtime.system, &.{}, candidate.items);
    const before_tokens = runtime.estimatedTokens();
    try std.testing.expect(after_tokens < before_tokens);
    try std.testing.expect(before_tokens - after_tokens >= @max(@as(usize, 32), before_tokens / 20));
    try std.testing.expect(after_tokens > c.inputBudget(config));
    var cancel: p.Cancellation = .{};
    const result = try runtime.compactContext(&cancel);
    try std.testing.expectEqual(r.Status.failed, result.status);
    try std.testing.expectEqual(error.InsufficientCompaction, result.detail.?);
    try std.testing.expectEqual(@as(usize, 1), fake.summaries);
    try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.tools);
    try std.testing.expectEqual(before.ptr, runtime.messages().ptr);
    try std.testing.expectEqualDeep(before, runtime.messages());
}
test "input budget summary physical window remains enforced" {
    var config = configuration();
    config.limits.low_price_input = true;
    try c.checkInputFor(config, .summary, 100001);
    const physical = config.model.context_tokens - cfg.Policy.safety_tokens;
    try c.checkInputFor(config, .summary, physical - 1);
    try std.testing.expectError(error.ContextTooLarge, c.checkInputFor(config, .summary, physical));
    config.model.input_price_threshold = null;
    config.model.output_tokens = null; // Unknown output capacity cannot block a text-only summary preflight.
    try c.checkInputFor(config, .summary, physical - 1);
    try std.testing.expectError(error.UnknownInputPriceThreshold, c.checkInputFor(config, .normal, physical - 1));
}
test "input budget checkpoint loads history across changed current policies" {
    for ([_]?u32{ null, 100000 }) |price| {
        var config = configuration();
        config.model.input_price_threshold = price;
        var fake = Fake{ .config = &config };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        const state = try runtime.exportCheckpoint();
        try std.testing.expect(state.input_budget_frozen);
        try std.testing.expectEqual(price, state.input_price_threshold);
        const bytes = try checkpoint.encode(a, state);
        defer a.free(bytes);
        var parsed = try checkpoint.decode(a, bytes);
        defer parsed.deinit();
        try checkpoint.validateStructure(parsed.value);
        try checkpoint.validateRequestHistory(a, .{ .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .chat }, .system = parsed.value.system, .messages = parsed.value.messages, .tools = &.{} });
        for (0..3) |change| {
            var other = config;
            switch (change) {
                0 => other.model.context_tokens = 80000,
                1 => other.limits.low_price_input = true,
                else => other.model.input_price_threshold = if (price == null) 100000 else null,
            }
            try checkpoint.validateRequestHistory(a, .{ .scope = .{ .connection = other.provider.base_url, .model = other.model.name, .protocol = .chat }, .system = parsed.value.system, .messages = parsed.value.messages, .tools = &.{} });
        }
        var unfrozen = state;
        unfrozen.input_budget_frozen = false;
        unfrozen.input_price_threshold = null;
        try checkpoint.validateStructure(unfrozen);
        try checkpoint.validateRequestHistory(a, .{ .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .chat }, .system = unfrozen.system, .messages = unfrozen.messages, .tools = &.{} });
    }
}
