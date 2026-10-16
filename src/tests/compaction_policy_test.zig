//! Offline policy contracts: automatic budgets, explicit ceilings and disable semantics.
const std = @import("std");
const cfg = @import("../core/config.zig");
const c = @import("../core/context.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const a = std.testing.allocator;

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

test "compaction policy config automatic explicit and disabled survive both disk formats" {
    const prefixes = [_][]const u8{
        "{\"provider\":{\"base_url\":\"https://fixture.invalid/v1\"},\"model\":{\"name\":\"m\",\"context_tokens\":1000000},\"limits\":",
        "{\"llm\":{\"default\":\"local/m\",\"providers\":{\"local\":{\"base_url\":\"https://fixture.invalid/v1\",\"models\":{\"m\":{\"protocol\":\"chat\",\"context_tokens\":1000000}}}}},\"limits\":",
    };
    for (prefixes) |prefix| for ([_][]const u8{ "{}", "{\"summary_tokens\":null}", "{\"max_output_tokens\":16384,\"summary_tokens\":null}", "{\"summary_tokens\":2048,\"compaction_enabled\":false}" }) |limits| {
        const raw = try std.mem.concat(a, u8, &.{ prefix, limits, "}" });
        defer a.free(raw);
        var parsed = try cfg.parse(a, raw);
        defer cfg.release(&parsed);
        const explicit = std.mem.indexOf(u8, limits, "2048") != null;
        try std.testing.expectEqual(@as(?u32, if (explicit) 2048 else null), parsed.value.limits.summary_tokens);
        try std.testing.expectEqual(!explicit, parsed.value.limits.compaction_enabled);
        var cloned = try cfg.clone(a, parsed.value);
        defer cfg.release(&cloned);
        var writer: std.Io.Writer.Allocating = .init(a);
        defer writer.deinit();
        try cfg.writeDisk(cloned.value, &writer.writer);
        var again = try cfg.parse(a, writer.written());
        defer cfg.release(&again);
        try std.testing.expectEqualDeep(parsed.value.limits, again.value.limits);
    };
    var config = configuration();
    config.limits.summary_tokens = 0;
    try std.testing.expectError(error.InvalidLimit, cfg.validate(config));
    config.limits.summary_tokens = 101;
    config.limits.max_output_tokens = 100;
    try std.testing.expectError(error.InvalidBudget, cfg.validate(config));
    config.limits.summary_tokens = null;
    try cfg.validate(config);
    config.limits.model_refresh_ttl_ms = 0;
    try std.testing.expectError(error.InvalidLimit, cfg.validate(config));
    config.limits.model_refresh_ttl_ms = 604800001;
    try std.testing.expectError(error.InvalidLimit, cfg.validate(config));
    config.limits.model_refresh_ttl_ms = 14400000;
    config.limits.model_refresh_cooldown_ms = 604800001;
    try std.testing.expectError(error.InvalidLimit, cfg.validate(config));
}

test "compaction policy automatic summary follows output ceiling and exact room wins" {
    var config = configuration();
    for ([_]u32{ 32768, 131072, 1000000, 16777216 }) |window| {
        config.model.context_tokens = window;
        try std.testing.expectEqual(@as(u32, 65536), c.summaryBudget(config));
        try std.testing.expectEqual(try c.outputBudget(config, .normal, 100), try c.outputBudget(config, .summary, 100));
        config.limits.max_output_tokens = 16384;
        try std.testing.expectEqual(@as(u32, 16384), c.summaryBudget(config));
        try std.testing.expectEqual(@as(u32, 16384), try c.outputBudget(config, .summary, 100));
        config.limits.max_output_tokens = null;
    }
    config.model.output_tokens = null;
    try std.testing.expectEqual(@as(u32, 4096), c.summaryBudget(config));
    try std.testing.expectEqual(@as(u32, 4096), try c.outputBudget(config, .normal, 100));
    try std.testing.expect(config.model.output_tokens == null);
    config.limits.max_output_tokens = 3000;
    try std.testing.expectEqual(@as(u32, 3000), c.summaryBudget(config));
    config.limits.summary_tokens = 37;
    try std.testing.expectEqual(@as(u32, 37), c.summaryBudget(config));
    config.model.output_tokens = 20;
    try std.testing.expectEqual(@as(u32, 20), c.summaryBudget(config));
    const room = config.model.context_tokens - config.limits.safety_tokens;
    try std.testing.expectEqual(@as(u32, 1), try c.outputBudget(config, .summary, room - 1));
    try std.testing.expectError(error.ContextTooLarge, c.outputBudget(config, .summary, room));
    try std.testing.expectError(error.ContextTooLarge, c.outputBudget(config, .summary, std.math.maxInt(usize)));
}

const Fake = struct {
    normal: usize = 0,
    summaries: usize = 0,
    cap: u32 = 0,
    exhausted: bool = false,
    oversized: bool = false,
    fn model(self: *Fake) p.Model {
        return .{ .context = self, .call_fn = call };
    }
    fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        try std.testing.expectEqualStrings("high", req.reasoning_effort.?);
        if (req.purpose == .summary) {
            self.summaries += 1;
            self.cap = req.max_output_tokens;
            if (self.exhausted) return .{ .failure = .{ .kind = .output_limit, .message = "fixture limit" } };
        } else self.normal += 1;
        const oversized: [512]u8 = @splat('s');
        return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, if (self.oversized) &oversized else "Earlier work completed.") } };
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
    const fitting: [10000]u8 = @splat('x');
    const overfull: [13000]u8 = @splat('x');
    for ([_]bool{ false, true }) |too_large| {
        var config = configuration();
        config.model.context_tokens = 4096;
        config.limits.safety_tokens = 100;
        config.limits.max_output_tokens = 100;
        config.limits.compaction_enabled = false;
        var fake: Fake = .{};
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "", true);
        defer runtime.deinit();
        try seed(&runtime, if (too_large) &overfull else &fitting);
        try std.testing.expect(runtime.estimatedTokens() > c.threshold(c.inputBudget(config), 80));
        var cancel: p.Cancellation = .{};
        const result = try runtime.run("new task", &cancel);
        try std.testing.expectEqual(@as(usize, 0), fake.summaries);
        try std.testing.expectEqual(@as(usize, if (too_large) 0 else 1), fake.normal);
        if (too_large) {
            try std.testing.expectEqual(error.ContextTooLarge, result.detail.?);
            try std.testing.expectEqualStrings(&overfull, runtime.messages()[1].blocks[0].text);
        } else try std.testing.expectEqual(r.Status.success, result.status);
    }
}

test "compaction policy disabled still allows manual auto-budget summary without normal request" {
    const old: [10000]u8 = @splat('x');
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        var config = configuration();
        config.model.protocol = protocol;
        config.model.reasoning.?.format = if (protocol == .anthropic) .anthropic else .standard;
        config.limits.compaction_enabled = false;
        config.limits.max_output_tokens = 16384;
        var fake: Fake = .{};
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "", true);
        defer runtime.deinit();
        try seed(&runtime, &old);
        var cancel: p.Cancellation = .{};
        const result = try runtime.compactContext(&cancel);
        try std.testing.expectEqual(r.Status.success, result.status);
        try std.testing.expectEqual(@as(u32, 16384), fake.cap);
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
        var fake: Fake = .{ .exhausted = exhausted, .oversized = !exhausted };
        var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "", true);
        defer runtime.deinit();
        try seed(&runtime, &old);
        const before = runtime.messages().ptr;
        var cancel: p.Cancellation = .{};
        const result = try runtime.compactContext(&cancel);
        try std.testing.expectEqual(if (exhausted) error.OutputLimitReached else error.InvalidSummary, result.detail.?);
        try std.testing.expectEqual(@as(usize, 1), fake.summaries);
        try std.testing.expectEqual(@as(usize, 0), fake.normal);
        try std.testing.expectEqual(@as(u32, 32), fake.cap);
        try std.testing.expectEqual(before, runtime.messages().ptr);
        try std.testing.expectEqual(@as(usize, 4), runtime.messages().len);
        try std.testing.expectEqualStrings(&old, runtime.messages()[1].blocks[0].text);
    }
}

test "compaction policy exhausted automatic summary pauses without followup inference" {
    const old: [10000]u8 = @splat('x');
    var config = configuration();
    config.model.context_tokens = 4096;
    config.limits.safety_tokens = 100;
    config.limits.max_output_tokens = 100;
    var fake: Fake = .{ .exhausted = true };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "", true);
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
