//! Offline estimated-input policy: real window, price metadata and intent stay separate.
const std = @import("std");
const cfg = @import("../core/config.zig");
const c = @import("../core/context.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const checkpoint = @import("../core/checkpoint.zig");
const a = std.testing.allocator;

fn configuration() cfg.Config {
    return .{ .provider = .{ .base_url = "https://fixture.invalid/v1" }, .model = .{
        .name = "fixture",
        .protocol = .chat,
        .context_tokens = 1000000,
        .output_tokens = 128000,
        .input_price_threshold = 100000,
    }, .limits = .{ .low_price_input = false, .max_output_tokens = 4096 } };
}

test "input budget registry declarations roundtrip without persisting derived price metadata" {
    const prefixes = [_][]const u8{
        "{\"llm\":{\"default\":\"local/m\",\"providers\":{\"local\":{\"base_url\":\"https://fixture.invalid/v1\",\"models\":{\"m\":{\"protocol\":\"chat\",\"context_tokens\":1000000}}}}},\"limits\":",
    };
    for (prefixes) |prefix| {
        const raw = try std.mem.concat(a, u8, &.{ prefix, "{\"low_price_input\":true,\"max_input_tokens\":90000,\"input_margin_tokens\":5000}}" });
        defer a.free(raw);
        var parsed = try cfg.parse(a, raw);
        defer cfg.release(&parsed);
        try std.testing.expect(parsed.value.limits.low_price_input);
        try std.testing.expectEqual(@as(?u32, 90000), parsed.value.limits.max_input_tokens);
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
        var again = try cfg.parse(a, out.written());
        defer cfg.release(&again);
        try std.testing.expectEqualDeep(parsed.value.limits, again.value.limits);
        try std.testing.expect(again.value.model.input_price_threshold == null);
        try std.testing.expect(again.value.model.input_price_flat_limit == null);
    }
    var config = configuration();
    config.limits.max_input_tokens = 5000;
    try std.testing.expectError(error.InvalidBudget, cfg.validate(config));
    config.limits.max_input_tokens = 16777217;
    try std.testing.expectError(error.InvalidBudget, cfg.validate(config));
    config.limits.max_input_tokens = null;
    config.limits.input_margin_tokens = 16777217;
    try std.testing.expectError(error.InvalidBudget, cfg.validate(config));
    for ([_][]const u8{ "{\"low_price_input\":\"true\"}", "{\"max_input_tokens\":\"100000\"}", "{\"input_margin_tokens\":5000.0}", "{\"low_price_input\":true,\"low_price_input\":false}" }) |limits| {
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
    config.limits.max_input_tokens = 70000;
    try std.testing.expectEqual(@as(usize, 65000), c.inputBudget(config));
    config.limits.max_input_tokens = null;
    config.model.input_price_threshold = 100000;
    try std.testing.expectEqual(@as(usize, 95000), c.inputBudget(config));
    config.model.input_price_threshold = null;
    config.model.input_price_flat_limit = null;
    try std.testing.expectError(error.UnknownInputPriceThreshold, c.checkInput(config, 1));
    // Explicit opt-out remains explicit; a manual input cap still applies.
    config.limits.low_price_input = false;
    config.limits.max_input_tokens = 70000;
    try std.testing.expectEqual(@as(usize, 65000), c.inputBudget(config));
}

test "input budget opt in min ceilings margin unknown and real output room" {
    var config = configuration();
    try std.testing.expectEqual(@as(usize, 995903), c.inputBudget(config));
    config.limits.low_price_input = true;
    try std.testing.expectEqual(@as(usize, 95000), c.inputBudget(config));
    // Price policy constrains input only, not the real window or output room.
    config.limits.max_output_tokens = null;
    try std.testing.expectEqual(@as(u32, 128000), try c.outputBudget(config, .normal, 95000));
    try std.testing.expectEqual(@as(u32, 128000), c.summaryBudget(config));
    try std.testing.expectError(error.InputBudgetExceeded, c.outputBudget(config, .normal, 95001));
    try std.testing.expectEqual(@as(u32, 128000), try c.outputBudget(config, .summary, 95001));
    try std.testing.expectEqual(@as(usize, 995903), c.inputBudgetFor(config, .summary));
    config.model.input_price_threshold = null;
    try std.testing.expectError(error.UnknownInputPriceThreshold, c.outputBudget(config, .normal, 100));
    try std.testing.expectEqual(@as(u32, 128000), try c.outputBudget(config, .summary, 100000));
    config.model.input_price_threshold = 100000;
    config.limits.max_input_tokens = 70000;
    try std.testing.expectEqual(@as(usize, 65000), c.inputBudget(config));
    config.model.context_tokens = 32768;
    try std.testing.expectEqual(@as(usize, 28671), c.inputBudget(config));
    config.model.input_price_threshold = null;
    try std.testing.expectEqual(@as(usize, 0), c.inputBudget(config));
    try std.testing.expectError(error.UnknownInputPriceThreshold, c.checkInput(config, 1));
    config.model.input_price_threshold = 1000;
    try std.testing.expectError(error.InputBudgetExceeded, c.checkInput(config, 1));
    config.limits.low_price_input = false;
    config.limits.max_input_tokens = null;
    try std.testing.expectEqual(@as(usize, 28671), c.inputBudget(config));
}

const Fake = struct {
    config: *const cfg.Config,
    normal: usize = 0,
    summaries: usize = 0,
    last_summary_input: usize = 0,
    tools: usize = 0,
    tool_mode: bool = false,
    exhausted: bool = false,
    summary_fault: enum { none, server, transport, invalid } = .none,
    output: [8192]u8 = @splat('x'),
    fn model(self: *Fake) p.Model {
        return .{ .context = self, .call_fn = call };
    }
    fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        const estimate = c.rawTokens(req.system, req.tools, req.messages);
        try std.testing.expect(estimate <= c.inputBudgetFor(self.config.*, req.purpose));
        if (req.purpose == .summary) {
            self.summaries += 1;
            self.last_summary_input = estimate;
            try std.testing.expectEqual(@as(usize, 0), self.normal);
            if (self.exhausted) return .{ .failure = .{ .kind = .output_limit, .message = "fixture cap", .usage = .{ .input_tokens = estimate, .output_tokens = req.max_output_tokens } } };
            switch (self.summary_fault) {
                .none => {},
                .server => return .{ .failure = .{ .kind = .server, .http_status = 503, .message = "fixture" } },
                .transport => return error.FixtureTransport,
                .invalid => return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, "") } },
            }
        } else {
            self.normal += 1;
            if (self.tool_mode and self.normal == 1) return .{ .success = .{ .finish = .tool_calls, .message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "one", .name = "fixture", .arguments = "{}" } }} } } };
        }
        return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, "Earlier work completed."), .usage = .{ .input_tokens = estimate, .output_tokens = 8 } } };
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return .{ .payload = raw, .description = "fixture" };
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.tools += 1;
        return .{ .text = &self.output };
    }
    fn executor(self: *Fake) r.Executor {
        return .{ .context = self, .schemas = &.{}, .prepare_fn = prepare, .execute_fn = execute };
    }
};

fn seed(runtime: *r.Runtime, old: []const u8) !void {
    const alloc = runtime.arena.allocator();
    try runtime.history.append(alloc, try p.textMessage(alloc, .user, "old task"));
    try runtime.history.append(alloc, try p.textMessage(alloc, .assistant, old));
    try runtime.history.append(alloc, try p.textMessage(alloc, .user, "recent task"));
    try runtime.history.append(alloc, try p.textMessage(alloc, .assistant, "recent answer"));
    runtime.protected_index = 2;
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
        config.limits.low_price_input = unknown;
        config.model.input_price_threshold = null;
        config.limits.max_input_tokens = 2000;
        config.limits.input_margin_tokens = 100;
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

test "input budget large tool output is bounded or pauses with closed canonical group" {
    for ([_]bool{ true, false }) |tight| {
        var config = configuration();
        config.limits.low_price_input = true;
        config.limits.max_input_tokens = 2000;
        config.limits.input_margin_tokens = 100;
        var fake = Fake{ .config = &config, .tool_mode = true };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        if (tight) {
            // Include Runtime's actual system preface, not just the user bytes.
            const prompt = p.Message{ .role = .user, .blocks = &.{.{ .text = "one goal" }} };
            config.limits.max_input_tokens = @intCast(c.rawTokens(runtime.system, &.{}, &.{prompt}) + config.limits.input_margin_tokens + 1);
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
        try std.testing.expect(std.mem.find(u8, runtime.messages()[2].blocks[0].tool_result.text, "truncated") != null);
        const safe = try c.boundaries(a, runtime.messages());
        defer a.free(safe);
        try std.testing.expect(safe[safe.len - 1]);
        try std.testing.expectEqualStrings("one goal", runtime.messages()[runtime.protected_index].blocks[0].text);
    }
}

test "input budget appended summary instruction cannot escape the complete request ceiling" {
    var config = configuration();
    config.limits.low_price_input = true;
    config.limits.max_input_tokens = 5000;
    config.limits.input_margin_tokens = 100;
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
    config.limits.max_input_tokens = @intCast(c.rawTokens(instruction, &.{}, &.{message}) + config.limits.input_margin_tokens - 1);
    var cancel: p.Cancellation = .{};
    const result = try runtime.compactContext(&cancel);
    try std.testing.expectEqual(r.Status.paused, result.status);
    try std.testing.expectEqual(error.InputBudgetExceeded, result.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.summaries);
    try std.testing.expectEqual(before, runtime.messages().ptr);
    try std.testing.expectEqual(@as(usize, 4), runtime.messages().len);
}

test "input budget proactive summary uses policy threshold not one million window and retains failure" {
    const old: [12500]u8 = @splat('x');
    for ([_]bool{ false, true }) |exhausted| {
        var config = configuration();
        config.limits.low_price_input = true;
        config.limits.max_input_tokens = 5000;
        config.limits.input_margin_tokens = 100;
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
        config.limits.max_input_tokens = 5000;
        config.limits.input_margin_tokens = 100;
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

test "input budget summary explicit caps physical window and nonzero output remain enforced" {
    var config = configuration();
    config.limits.max_output_tokens = null;
    config.limits.low_price_input = true;
    try std.testing.expectEqual(@as(u32, 128000), try c.outputBudget(config, .summary, 100001));
    config.limits.max_input_tokens = 100000;
    try std.testing.expectError(error.InputBudgetExceeded, c.outputBudget(config, .summary, 95001));
    config.limits.max_input_tokens = null;
    const physical = config.model.context_tokens - config.limits.safety_tokens;
    try std.testing.expectEqual(@as(u32, 1), try c.outputBudget(config, .summary, physical - 1));
    try std.testing.expectError(error.InputBudgetExceeded, c.outputBudget(config, .summary, physical));
    config.model.input_price_threshold = null;
    try std.testing.expectEqual(@as(u32, 1), try c.outputBudget(config, .summary, physical - 1));
    try std.testing.expectError(error.UnknownInputPriceThreshold, c.outputBudget(config, .normal, physical - 1));
}

test "input budget checkpoint loads history across changed current policies" {
    for ([_]?u32{ null, 100000 }) |price| {
        var config = configuration();
        config.model.input_price_threshold = price;
        config.limits.max_input_tokens = 90000;
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
        try checkpoint.validate(a, parsed.value, config, &.{});
        for (0..4) |change| {
            var other = config;
            switch (change) {
                0 => other.limits.max_input_tokens = 80000,
                1 => other.limits.low_price_input = true,
                2 => other.limits.input_margin_tokens = 1000,
                else => other.model.input_price_threshold = if (price == null) 100000 else null,
            }
            try checkpoint.validate(a, parsed.value, other, &.{});
        }
        var legacy = state;
        legacy.input_budget_frozen = false;
        legacy.input_price_threshold = null;
        legacy.max_input_tokens = null;
        legacy.input_margin_tokens = 5000;
        try checkpoint.validate(a, legacy, config, &.{});
    }
}
