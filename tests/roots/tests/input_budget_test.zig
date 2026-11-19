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
    }, .limits = .{ .low_price_input = false } };
}

const Fake = struct {
    config: *const cfg.Config,
    /// The send gate may legitimately admit a request whose raw estimate is
    /// over budget when the provider-reported prompt is smaller; the anchored
    /// test below opts out of this raw-only assertion.
    check_raw_budget: bool = true,
    normal: usize = 0,
    summaries: usize = 0,
    last_summary_input: usize = 0,
    tools: usize = 0,
    tool_mode: bool = false,
    exhausted: bool = false,
    summary_text: ?[]const u8 = null,
    summary_fault: enum { none, server, transport, invalid } = .none,
    output: [8192]u8 = @splat('x'),
    /// A provider that reports no input usage for one call.
    zero_input: bool = false,
    fn model(self: *Fake) p.Model {
        return .{ .context = self, .call_fn = call };
    }
    fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        const estimate = c.rawTokens(req.system, req.tools, req.messages);
        if (self.check_raw_budget) try std.testing.expect(estimate <= c.inputBudgetFor(self.config.*, req.purpose));
        if (req.purpose == .summary) {
            self.summaries += 1;
            self.last_summary_input = estimate;
            try std.testing.expectEqual(@as(usize, 0), self.normal);
            if (self.exhausted) return .{ .failure = .{ .kind = .output_limit, .message = "fixture cap", .usage = .{ .input_tokens = estimate, .output_tokens = 4096 } } };
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
        return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, if (req.purpose == .summary) self.summary_text orelse "Earlier work completed." else "Earlier work completed."), .usage = .{ .input_tokens = if (self.zero_input) 0 else estimate, .output_tokens = 8 } } };
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

fn automaticSummaryLocalRejection(unknown_anthropic: bool) !void {
    const Capture = struct {
        runtime: *r.Runtime,
        allocator: std.mem.Allocator,
        failures: usize = 0,
        cause: ?anyerror = null,
        history: std.ArrayList(p.Message) = .empty,
        protected_index: ?usize = null,
        compacting: usize = 0,
        committed: usize = 0,
        usages: usize = 0,

        fn emit(raw: ?*anyopaque, event: r.Event, _: *const p.Cancellation) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            switch (event) {
                .compaction_failed => |failure| {
                    self.failures += 1;
                    self.cause = failure.err;
                    self.protected_index = self.runtime.protected_index;
                    for (self.runtime.messages()) |message|
                        try self.history.append(self.allocator, try p.cloneMessage(self.allocator, message));
                },
                .state => |state| if (state == .compacting) {
                    self.compacting += 1;
                },
                .compacted => self.committed += 1,
                .usage => self.usages += 1,
                else => {},
            }
        }
    };
    var config = configuration();
    if (unknown_anthropic) {
        config.model.protocol = .anthropic;
        config.model.output_tokens = null;
        config.limits.low_price_input = true;
    }
    var fake = Fake{ .config = &config };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
    defer runtime.deinit();
    // Quoting expands the actual summary DATA view beyond the original input.
    const old: [12500]u8 = @splat('"');
    try seed(&runtime, &old);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const goal = "new accepted automatic-summary goal";
    const protected = runtime.messages().len;
    const expected = try alloc.alloc(p.Message, protected + 1);
    for (runtime.messages(), 0..) |message, i| expected[i] = try p.cloneMessage(alloc, message);
    expected[protected] = try p.textMessage(alloc, .user, goal);
    const normal_input = runtime.estimator.tokens(c.rawTokens(runtime.system, &.{}, expected));
    const ceiling: u32 = @intCast(normal_input + cfg.Policy.input_margin_tokens - 1);
    if (unknown_anthropic) {
        config.model.input_price_threshold = ceiling;
    } else {
        // Set the actual physical input budget to normal_input - 1,
        // including the proportional reserve for this small window.
        config.model.context_tokens = @intCast(@max(2, normal_input + @min(cfg.Policy.safety_tokens, normal_input / 7)));
        try std.testing.expectEqual(normal_input - 1, c.inputBudget(config));
    }
    try c.validateInputPolicy(config);
    try std.testing.expect(config.limits.compaction_enabled);
    try std.testing.expect(normal_input > c.inputBudget(config));
    try std.testing.expect(normal_input >= c.threshold(c.inputBudget(config), cfg.Policy.compaction_trigger_percent));
    // Use the AUTOMATIC plan with the accepted input included, not the loaded
    // four-message history or manual compaction's different protected boundary.
    const plan = try c.plan(alloc, config, runtime.estimator, runtime.system, &.{}, expected, protected);
    try std.testing.expect(plan.cut > 0);
    const instruction = try c.summaryInstruction(alloc, plan, expected);
    const view = try c.summaryView(alloc, plan, expected);
    const summary_messages = [_]p.Message{try p.textMessage(alloc, .user, view)};
    const summary_input = runtime.estimator.tokens(c.rawTokens(instruction, &.{}, &summary_messages));
    if (unknown_anthropic) {
        // Isolate protocol validation: the complete summary input really fits.
        try c.checkInputFor(config, .summary, summary_input);
    } else {
        try std.testing.expect(summary_input > c.inputBudgetFor(config, .summary));
        try std.testing.expectError(error.ContextTooLarge, c.checkInputFor(config, .summary, summary_input));
    }
    var capture = Capture{ .runtime = &runtime, .allocator = alloc };
    runtime.host = .{ .context = &capture, .emit_fn = Capture.emit };
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run(goal, &cancel);
    try std.testing.expectEqual(if (unknown_anthropic) r.Status.paused else r.Status.failed, terminal.status);
    try std.testing.expectEqual(if (unknown_anthropic) error.InputBudgetExceeded else error.ContextTooLarge, terminal.detail.?);
    try std.testing.expect(terminal.detail.? != error.SummaryFailed and terminal.detail.? != error.InsufficientCompaction);
    try std.testing.expect(terminal.model_failure == null and terminal.http_status == null);
    try std.testing.expectEqual(@as(usize, 1), capture.failures);
    try std.testing.expectEqual(if (unknown_anthropic) error.UnknownModelOutputCapacity else error.ContextTooLarge, capture.cause.?);
    try std.testing.expectEqual(@as(?usize, protected), capture.protected_index);
    try std.testing.expectEqualDeep(@as([]const p.Message, expected), capture.history.items);
    try std.testing.expectEqualDeep(@as([]const p.Message, if (unknown_anthropic) expected else expected[0..protected]), runtime.messages());
    try std.testing.expectEqual(protected, runtime.protected_index);
    try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.summaries + fake.tools);
    try std.testing.expectEqual(@as(usize, 0), capture.compacting + capture.committed + capture.usages);
    try std.testing.expectEqualDeep(r.UsageTotals{}, terminal.usage);
}

test "reported usage decides sendability, not the conservative raw estimate" {
    var config = configuration();
    config.model.context_tokens = 30000;
    const budget = c.inputBudget(config);
    try std.testing.expectEqual(@as(usize, 26249), budget);
    var fake = Fake{ .config = &config, .check_raw_budget = false };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
    defer runtime.deinit();
    // A prompt around 72% of the window that the character heuristic calls
    // larger than the whole budget: exactly the shape that used to fail.
    const long: [90000]u8 = @splat('x');
    try seed(&runtime, &long);
    const estimated = runtime.estimatedTokens();
    try std.testing.expect(estimated > budget);
    const reported: u64 = 18600; // ~72% of 30000, as the provider counted it
    try std.testing.expect(reported <= budget);
    runtime.last_normal_input_tokens = reported;
    runtime.last_normal_estimated_tokens = estimated;
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("next step", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    // No summary and no rejection: the anchored measurement still fits.
    try std.testing.expectEqual(@as(usize, 1), fake.normal);
    try std.testing.expectEqual(@as(usize, 0), fake.summaries);
}

test "a zero input report never becomes the anchoring baseline" {
    var config = configuration();
    config.model.context_tokens = 30000;
    var fake = Fake{ .config = &config, .zero_input = true };
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), .{}, "");
    defer runtime.deinit();
    try seed(&runtime, "small old work");
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("first step", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    // Without a trustworthy count the measurement falls back to the estimate.
    try std.testing.expectEqual(@as(?u64, null), runtime.last_normal_input_tokens);
    try std.testing.expectEqual(@as(usize, 0), runtime.last_normal_estimated_tokens);
}
