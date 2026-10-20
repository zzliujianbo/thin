//! Offline latest-request context usage contracts. No transport or terminal access.
const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const r = @import("../core/runtime.zig");
const presentation = @import("../presentation/state.zig");
const t = std.testing;

fn configuration() cfg.Config {
    return .{
        .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat },
        .limits = .{ .low_price_input = false },
    };
}

const Step = struct {
    usage: p.Usage = .{},
    previous: ?u64 = 0,
    protocol: p.Protocol = .chat,
    failure: ?p.FailureKind = null,
    throws: bool = false,
};

const FakeContext = struct {
    steps: []const Step,
    calls: usize = 0,
    owner: ?*r.Runtime = null,
    final_total: ?u64 = null,
    pending_count: usize = 0,
    pending: [4]r.ContextSnapshot = undefined,
    usage_count: usize = 0,
    usage_values: [4]p.Usage = undefined,
    usage_owners: [4]r.ContextSnapshot = undefined,
    snapshots: usize = 0,
    last_snapshot: ?r.ContextSnapshot = null,
    terminals: usize = 0,
    terminal: ?r.Terminal = null,
    disconnect_usage: bool = false,
    display: ?*presentation.State = null,
    interrupted_display: ?r.ContextSnapshot = null,

    fn model(self: *FakeContext) p.Model {
        return .{ .context = self, .call_fn = call };
    }
    fn executor(self: *FakeContext) r.Executor {
        return .{ .context = self, .schemas = &.{}, .prepare_fn = prepare, .execute_fn = execute };
    }
    fn host(self: *FakeContext) r.Host {
        return .{ .context = self, .emit_fn = event, .authorize_fn = authorize };
    }
    fn call(ctx: *anyopaque, _: std.mem.Allocator, req: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *FakeContext = @ptrCast(@alignCast(ctx));
        if (self.calls >= self.steps.len) return error.UnexpectedRequest;
        const step = self.steps[self.calls];
        self.calls += 1;
        try t.expectEqual(p.Purpose.normal, req.purpose);
        try t.expectEqual(step.protocol, req.scope.protocol);
        try t.expectEqual(@as(usize, 0), req.tools.len);
        // Reading here is on the synchronous owner, not a racing UI thread.
        try expectSnapshot(self.owner.?.contextSnapshot(), step.previous, self.owner.?.config.model.context_tokens);
        if (step.throws) return error.FixtureCallFailed;
        // Stream metadata must not overwrite the previous authoritative value.
        try sink.emit(.{ .usage = .{ .total_tokens = 999999 } });
        try expectSnapshot(self.owner.?.contextSnapshot(), step.previous, self.owner.?.config.model.context_tokens);
        self.final_total = step.usage.total();
        if (step.failure) |kind| return .{ .failure = .{ .kind = kind, .message = "offline fixture", .usage = step.usage } };
        return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} },
            .finish = .stop,
            .usage = step.usage,
        } };
    }
    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return error.UnexpectedTool;
    }
    fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        return error.UnexpectedTool;
    }
    fn authorize(_: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        return error.UnexpectedTool;
    }
    fn event(ctx: ?*anyopaque, ev: r.Event, _: *const p.Cancellation) !void {
        const self: *FakeContext = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .state => |state| {
                try t.expectEqual(r.State.calling_model, state);
                try t.expect(self.pending_count < self.pending.len);
                self.pending[self.pending_count] = self.owner.?.contextSnapshot();
                self.pending_count += 1;
            },
            .context_snapshot => |value| {
                self.snapshots += 1;
                self.last_snapshot = value; // Copy values only; never retain borrowed text.
                try t.expectEqualDeep(self.owner.?.contextSnapshot(), value);
            },
            .usage => |value| {
                try t.expect(self.usage_count < self.usage_values.len);
                try t.expectEqual(p.Purpose.normal, value.purpose);
                const snapshot = self.owner.?.contextSnapshot();
                // Even fallback's FIRST notification must see the FINAL attempt.
                try expectSnapshot(snapshot, self.final_total, self.owner.?.config.model.context_tokens);
                self.usage_values[self.usage_count] = value.value;
                self.usage_owners[self.usage_count] = snapshot;
                self.usage_count += 1;
                if (self.display) |display| display.observe(ev, 0);
                if (self.disconnect_usage) {
                    if (self.display) |display| self.interrupted_display = display.context;
                    return error.Disconnected;
                }
            },
            .finished => |terminal| {
                self.terminals += 1;
                self.terminal = terminal;
                try t.expectEqualDeep(self.owner.?.contextSnapshot(), terminal.context_snapshot.?);
                if (self.display) |display| display.finish(terminal, 0);
            },
            else => {},
        }
    }
};

fn init(config: *const cfg.Config, fake: *FakeContext) !r.Runtime {
    return r.Runtime.init(t.allocator, t.io, config, fake.model(), fake.executor(), fake.host(), "");
}
fn expectSnapshot(snapshot: r.ContextSnapshot, total: ?u64, limit: u32) !void {
    try t.expectEqual(total != null, snapshot.known);
    try t.expectEqual(total orelse 0, snapshot.tokens);
    try t.expectEqual(@as(u64, limit), snapshot.limit);
}
fn run(runtime: *r.Runtime, text: []const u8) !r.Terminal {
    var cancel: p.Cancellation = .{};
    return runtime.run(text, &cancel);
}
fn expectTerminal(runtime: *r.Runtime, fake: *const FakeContext, terminal: r.Terminal, total: ?u64) !void {
    try expectSnapshot(runtime.contextSnapshot(), total, runtime.config.model.context_tokens);
    try t.expectEqualDeep(runtime.contextSnapshot(), terminal.context_snapshot.?);
    try t.expectEqualDeep(terminal, fake.terminal.?);
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
