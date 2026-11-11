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
    tool_calls: usize = 0,
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
    fn prepare(ctx: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        const self: *FakeContext = @ptrCast(@alignCast(ctx));
        self.tool_calls += 1;
        return error.UnexpectedTool;
    }
    fn execute(ctx: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        const self: *FakeContext = @ptrCast(@alignCast(ctx));
        self.tool_calls += 1;
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
                if (self.display) |display| display.finish(terminal);
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
