//! Run only through tests/product/anthropic_mock.mjs with an owned literal loopback URL.
const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const Client = @import("../llm/http.zig").Client;
const Selector = @import("../llm/llm.zig").Selector;
const t = std.testing;
const Io = std.Io;
const tools = [_]p.ToolSchema{.{ .name = "lookup", .description = "Local fixture only", .parameters_json = "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}},\"required\":[\"q\"],\"additionalProperties\":false}" }};
const initial = [_]p.Message{.{ .role = .user, .blocks = &.{.{ .text = "hello fixture" }} }};

fn config(a: std.mem.Allocator, scenario: []const u8) !cfg.Config {
    const base = t.environ.getPosix("THIN_ANTHROPIC_FIXTURE_URL") orelse return error.MissingFixtureEnvironment;
    const uri = try std.Uri.parse(base);
    const host = uri.host orelse return error.UnsafeFixtureUrl;
    const host_text = switch (host) {
        .raw, .percent_encoded => |s| s,
    };
    if (!std.mem.eql(u8, uri.scheme, "http") or !std.mem.eql(u8, host_text, "127.0.0.1") or uri.port == null or uri.port == 0 or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or !uri.path.isEmpty()) return error.UnsafeFixtureUrl;
    return .{ .provider = .{ .base_url = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, scenario }), .api_key_env = "THIN_FAKE_KEY" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .anthropic, .output_tokens = 128 }, .limits = .{ .low_price_input = false, .request_timeout_ms = 10000 } };
}
fn request(c: cfg.Config) p.Request {
    // The fixture model has a synthetic verified output capacity, not a cap setting.
    return .{ .scope = .{ .connection = c.provider.base_url, .model = c.model.name, .protocol = .anthropic }, .system = "fixed fixture system", .tools = &tools, .messages = &initial, .model_output_tokens = c.model.output_tokens };
}
fn success(out: p.Outcome) !p.Response {
    // Never print failure messages, native replay, assertion operands, or response bodies.
    if (out != .success) return error.ExpectedFixtureSuccess;
    return out.success;
}
const Recorder = struct {
    text: [128]u8 = undefined,
    len: usize = 0,
    reasoning: usize = 0,
    tool: usize = 0,
    usage: p.Usage = .{},
    cancel: ?*p.Cancellation = null,
    fn emit(ctx: ?*anyopaque, event: p.ModelEvent) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .text_delta => |s| {
                if (s.len > self.text.len - self.len) return error.FixtureTextLimit;
                @memcpy(self.text[self.len..][0..s.len], s);
                self.len += s.len;
            },
            .reasoning_delta => |s| self.reasoning += s.len,
            .tool_delta => |d| self.tool += d.arguments.len,
            .usage => |u| {
                self.usage = u;
                if (self.cancel) |c| c.cancel();
            },
        }
    }
    fn sink(self: *Recorder) p.ModelSink {
        return .{ .context = self, .emit_fn = emit };
    }
};
fn usage(u: p.Usage, output: u64) !void {
    try t.expect(u.input_tokens == 15);
    try t.expect(u.cached_input_tokens == 3);
    try t.expect(u.cache_write_tokens == 2);
    try t.expect(u.output_tokens == output);
    try t.expect(u.total() == 15 + output);
}

test "anthropic fixture unknown or invalid model capacity rejects locally before HTTP" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c: cfg.Config = .{ .provider = .{ .base_url = "https://fixture.invalid" }, .model = .{ .name = "unknown-fixture", .context_tokens = 32768, .protocol = .anthropic } };
    var req = request(c);
    try t.expectError(error.UnknownModelOutputCapacity, @import("../llm/anthropic.zig").encode(arena.allocator(), req));
    req.model_output_tokens = 0;
    try t.expectError(error.InvalidModelOutputCapacity, @import("../llm/anthropic.zig").encode(arena.allocator(), req));
}

test "anthropic HTTP: fragmented signed native replay and adjacent multiple tool results" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "replay", "multi" }) |scenario| {
        var c = try config(a, scenario);
        var client = try Client.init(t.allocator, backend.io(), &c, "fake-local-key");
        defer client.deinit();
        var selector = Selector.init(.anthropic);
        var rec = Recorder{};
        var req = request(c);
        const selected = try selector.call(client.model(), a, req, rec.sink());
        try t.expect(!selected.fallback and selected.calls == 1);
        const first = try success(selected.outcome);
        try t.expect(first.finish == .tool_calls);
        try t.expect(first.message.replay != null);
        try t.expect(rec.reasoning > 0 and rec.tool > 0);
        try t.expect(std.mem.eql(u8, rec.text[0..rec.len], "你"));
        try usage(first.usage, 4);
        try usage(rec.usage, 4);
        var results: [2]p.Block = undefined;
        var count: usize = 0;
        for (first.message.blocks) |block| if (block == .tool_call) {
            try t.expect(count < results.len);
            try t.expect(std.mem.eql(u8, block.tool_call.id, if (count == 0) "call_actual" else "call_second"));
            try t.expect(std.mem.eql(u8, block.tool_call.name, "lookup"));
            results[count] = .{ .tool_result = .{ .call_id = block.tool_call.id, .text = if (count == 0) "fixture result" else "second result", .is_error = count == 1 } };
            count += 1;
        };
        try t.expect(count == @as(usize, if (std.mem.eql(u8, scenario, "multi")) 2 else 1));
        // Separate canonical tool messages must become one adjacent user result group.
        var history = [_]p.Message{ initial[0], first.message, .{ .role = .tool, .blocks = results[0..1] }, .{ .role = .tool, .blocks = results[1..count] } };
        req.messages = history[0 .. 2 + count];
        const second = try selector.call(client.model(), a, req, .{});
        try t.expect(!second.fallback and second.calls == 1);
        try t.expect((try success(second.outcome)).finish == .stop);
        req.purpose = .summary;
        const summary = try selector.call(client.model(), a, req, .{});
        try t.expect(!summary.fallback and summary.calls == 1);
        try t.expect((try success(summary.outcome)).finish == .stop);
    }
}

test "anthropic HTTP: fixed selector errors incomplete tools and unsupported blocks never retry" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cases = .{
        .{ "error401", p.FailureKind.authentication },
        .{ "error429", p.FailureKind.rate_limit },
        .{ "error500", p.FailureKind.server },
        .{ "error404", p.FailureKind.invalid_argument },
        .{ "error-sse", p.FailureKind.server },
    };
    inline for (cases) |case| {
        var c = try config(arena.allocator(), case[0]);
        var client = try Client.init(t.allocator, backend.io(), &c, "fake-local-key");
        defer client.deinit();
        var selector = Selector.init(.anthropic);
        const result = try selector.call(client.model(), arena.allocator(), request(c), .{});
        try t.expect(!result.fallback and result.calls == 1);
        try t.expect(result.outcome == .failure);
        try t.expect(result.outcome.failure.kind == case[1]);
    }
    for ([_][]const u8{ "max_tokens", "max_tokens_partial", "pause_turn", "context_limit", "missing-stop", "malformed-delta", "invalid-json", "unsupported-block", "server-tool", "redirect" }) |scenario| {
        var c = try config(arena.allocator(), scenario);
        var client = try Client.init(t.allocator, backend.io(), &c, "fake-local-key");
        defer client.deinit();
        var selector = Selector.init(.anthropic);
        const result = try selector.call(client.model(), arena.allocator(), request(c), .{});
        try t.expect(!result.fallback and result.calls == 1);
        // Streamed tool drafts cannot be a successful executable message.
        try t.expect(result.outcome == .failure);
        if (std.mem.startsWith(u8, scenario, "max_tokens")) {
            try t.expectEqual(p.FailureKind.output_limit, result.outcome.failure.kind);
            try usage(result.outcome.failure.usage, 4);
            try t.expect(result.outcome.failure.observed_content and result.outcome.failure.raw_usage_json != null);
        }
        if (std.mem.eql(u8, scenario, "pause_turn")) try t.expectEqual(p.FailureKind.model, result.outcome.failure.kind);
        if (std.mem.eql(u8, scenario, "context_limit")) try t.expectEqual(p.FailureKind.context_limit, result.outcome.failure.kind);
    }
}

test "anthropic HTTP: timeout cancellation preserve observed cache usage" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |cancel_test| {
        var c = try config(arena.allocator(), if (cancel_test) "cancel" else "timeout");
        c.limits.request_timeout_ms = if (cancel_test) 3000 else 700;
        var client = try Client.init(t.allocator, backend.io(), &c, "fake-local-key");
        defer client.deinit();
        var cancellation = p.Cancellation{};
        var rec = Recorder{ .cancel = if (cancel_test) &cancellation else null };
        var req = request(c);
        req.cancellation = &cancellation;
        const start = Io.Clock.awake.now(backend.io());
        const out = try client.model().call(arena.allocator(), req, rec.sink());
        try t.expect(out == .failure);
        try t.expect(out.failure.kind == if (cancel_test) p.FailureKind.canceled else p.FailureKind.timeout);
        try t.expect(start.untilNow(backend.io(), .awake).toMilliseconds() < 5000);
        try usage(out.failure.usage, 0);
    }
}
