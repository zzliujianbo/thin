//! HTTP 客户端集成测试：通过 127.0.0.1 本地固定夹具服务器验证 Chat/Responses 流解析、工具回放、协议回退、错误分类、超时与取消。不访问外部网络。

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const Client = @import("../llm/http.zig").Client;
const Selector = @import("../llm/llm.zig").Selector;
const t = std.testing;
const Io = std.Io;

/// 固定的单工具 schema，用于验证请求体中的 tools 字段。
const tools = [_]p.ToolSchema{.{ .name = "lookup", .description = "Local fixture only", .parameters_json = "{\"type\":\"object\",\"properties\":{}}" }};

/// 固定的初始用户消息。
const initial = [_]p.Message{.{ .role = .user, .blocks = &.{.{ .text = "hello fixture" }} }};

/// 根据 fixture 基础地址与场景名构造配置；场景名拼接在 URL 路径中，由夹具服务器分派。
fn config(a: std.mem.Allocator, scenario: []const u8, protocol: p.Protocol) !cfg.Config {
    const base = std.testing.environ.getPosix("THIN_HTTP_FIXTURE_URL") orelse return error.MissingFixtureEnvironment;

    // Accept only a literal IPv4 loopback authority, never DNS/userinfo/redirects.
    const uri = try std.Uri.parse(base);
    const host = uri.host orelse return error.UnsafeFixtureUrl;
    const host_text = switch (host) {
        .raw, .percent_encoded => |s| s,
    };

    // 拒绝：非 http scheme、非 127.0.0.1 主机、缺端口，以及带 userinfo/query/fragment/路径的 URL。
    if (!std.mem.eql(u8, uri.scheme, "http") or !std.mem.eql(u8, host_text, "127.0.0.1") or
        uri.port == null or uri.port == 0 or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or !uri.path.isEmpty()) return error.UnsafeFixtureUrl;

    return .{ .provider = .{ .base_url = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, scenario }), .api_key_env = "THIN_FAKE_KEY" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = protocol }, .limits = .{ .request_timeout_ms = 10000 } };
}

/// 构造固定内容的请求，使每次调用的 scope 与 system 保持一致，便于对比。
fn request(c: cfg.Config, protocol: p.Protocol) p.Request {
    return .{ .scope = .{ .connection = c.provider.base_url, .model = c.model.name, .protocol = protocol }, .system = "fixed fixture system", .tools = &tools, .messages = &initial, .max_output_tokens = 128 };
}

/// 记录流式事件：文本写入固定 128 字节缓冲（超出则报错），并累计推理与工具参数的字节数及 usage。
const Recorder = struct {
    /// 固定容量的文本缓冲，避免测试中动态分配。
    text: [128]u8 = undefined,
    len: usize = 0,
    /// 推理增量的字节数（只计数，不保存内容）。
    reasoning: usize = 0,
    /// 工具参数增量的字节数。
    tool: usize = 0,
    /// 最近一次收到的 usage。
    usage: p.Usage = .{},

    /// 事件回调：按类型分别处理。
    fn emit(ctx: ?*anyopaque, event: p.ModelEvent) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .text_delta => |s| {
                if (s.len > self.text.len - self.len) return error.TooMuchText;
                @memcpy(self.text[self.len..][0..s.len], s);
                self.len += s.len;
            },
            .reasoning_delta => |s| self.reasoning += s.len,
            .tool_delta => |d| self.tool += d.arguments.len,
            .usage => |u| self.usage = u,
        }
    }

    /// 包装为 p.ModelSink 接口。
    fn sink(self: *Recorder) p.ModelSink {
        return .{ .context = self, .emit_fn = emit };
    }
};

/// 断言调用成功并返回 Response；失败时打印分类与信息，便于定位夹具问题。
fn success(out: p.Outcome) !p.Response {
    if (out == .failure) {
        std.debug.print("unexpected fixture failure: {s}: {s}\n", .{ @tagName(out.failure.kind), out.failure.message });
        return error.ExpectedSuccess;
    }
    return out.success;
}

// 验证：Chat 与 Responses 在 UTF-8 字符和 CRLF 被切分时仍能正确解析文本、推理增量以及迟到的 usage。
test "integration: Chat and Responses split UTF8 CRLF, reasoning and late usage" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]p.Protocol{ .chat, .responses }) |protocol| {
        var c = try config(a, if (protocol == .chat) "split-chat" else "split-responses", protocol);
        var client = try Client.init(t.allocator, backend.io(), &c, "fake-local-key");
        defer client.deinit();

        var recorder = Recorder{};
        const out = try success(try client.model().call(a, request(c, protocol), recorder.sink()));

        // 第一个字符「你」被切分到多个分片中，拼接后必须完整还原。
        try t.expectEqualStrings("你", recorder.text[0..recorder.len]);
        try t.expect(recorder.reasoning > 0);

        // usage 可能在流末尾才到达，流式回调看到的与最终结果应一致。
        try t.expectEqual(@as(?u64, 14), out.usage.total());
        try t.expectEqual(@as(?u64, 14), recorder.usage.total());
        try t.expectEqual(p.Finish.stop, out.finish);
    }
}

// 验证：工具调用的真实 call id 与 Responses 的 item id 被保留并回放；summary 请求也不会破坏协议状态。
test "integration: native tool replay actual IDs and summary stability" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]p.Protocol{ .chat, .responses }) |protocol| {
        var c = try config(a, if (protocol == .chat) "tools-chat" else "tools-responses", protocol);
        var client = try Client.init(t.allocator, backend.io(), &c, "fake-local-key");
        defer client.deinit();
        var recorder = Recorder{};

        // 可修改的请求副本，追加工具结果后用于第二轮。
        var req = request(c, protocol);
        const first = try success(try client.model().call(a, req, recorder.sink()));
        try t.expectEqual(p.Finish.tool_calls, first.finish);
        try t.expect(recorder.tool > 0);
        try t.expect(first.message.replay != null);
        try t.expectEqual(protocol == .responses, first.message.replay.?.retain_turn);

        // 从第一轮回复中取出工具调用块。
        var call: ?p.ToolCall = null;
        for (first.message.blocks) |b| if (b == .tool_call) {
            call = b.tool_call;
        };

        try t.expect(call != null);
        try t.expectEqualStrings("call_actual", call.?.id);

        // Responses 协议还要求 item_id 原样回放。
        if (protocol == .responses) try t.expectEqualStrings("fc_actual", call.?.item_id.?);

        const results = [_]p.Block{.{ .tool_result = .{ .call_id = call.?.id, .text = "fixture result" } }};
        const history = [_]p.Message{ initial[0], first.message, .{ .role = .tool, .blocks = &results } };
        req.messages = &history;

        // 第二轮携带工具结果，回复应正常结束且不再需要保留回放。
        const second = try success(try client.model().call(a, req, .{}));
        try t.expectEqual(p.Finish.stop, second.finish);
        try t.expect(!second.message.replay.?.retain_turn);

        // summary 用途的请求也必须成功，不应影响前面建立的协议状态。
        req.purpose = .summary;
        _ = try success(try client.model().call(a, req, .{}));
    }
}

// 验证：显式的 unsupported endpoint 错误只回退一次并固定为 Chat，之后的调用不再回退。
test "integration: explicit unsupported endpoint retries exactly once and pins Chat" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try config(a, "auto", .auto);
    var client = try Client.init(t.allocator, backend.io(), &c, "fake-local-key");
    defer client.deinit();
    var selector = Selector.init(.auto);

    // 首次调用：auto 先选 Responses 失败，回退到 Chat，共 2 次请求。
    const first = try selector.call(client.model(), a, request(c, .auto), .{});
    _ = try success(first.outcome);
    try t.expect(first.fallback);
    try t.expectEqual(@as(u8, 2), first.calls);
    try t.expectEqual(@as(?u64, 7), first.fallback_usage.?.input_tokens);
    try t.expectEqual(p.Protocol.chat, selector.selected.?);

    // 再次调用应直接使用已固定的 Chat，只发起 1 次请求。
    const next = try selector.call(client.model(), a, request(c, .auto), .{});
    _ = try success(next.outcome);
    try t.expect(!next.fallback);
    try t.expectEqual(@as(u8, 1), next.calls);
}

// 验证：401/429/404/400/503 等普通 HTTP 错误被正确分类，且不触发协议回退。
test "integration: ordinary HTTP errors never fallback" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // (夹具场景名, 期望的错误类别) 对照表。
    const cases = .{ .{ "error404", p.FailureKind.invalid_argument }, .{ "error400", p.FailureKind.invalid_argument }, .{ "error401", p.FailureKind.authentication }, .{ "error429", p.FailureKind.rate_limit }, .{ "error503", p.FailureKind.server } };

    inline for (cases) |case| {
        var c = try config(a, case[0], .auto);
        var client = try Client.init(t.allocator, backend.io(), &c, "fake-local-key");
        defer client.deinit();
        var selector = Selector.init(.auto);
        const result = try selector.call(client.model(), a, request(c, .auto), .{});
        try t.expect(result.outcome == .failure);
        try t.expectEqual(case[1], result.outcome.failure.kind);
        try t.expect(!result.fallback);
        try t.expectEqual(@as(u8, 1), result.calls);
    }
}

// 验证：缺少终止事件、截断、非法 JSON、未完成以及重定向等异常都以失败结束（fail closed），不会伪装成成功。
test "integration: missing terminal truncated HTTP invalid args and redirects fail closed" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]p.Protocol{ .chat, .responses }) |protocol| {
        for ([_][]const u8{ "missing", "truncated", "invalid", "incomplete", "redirect" }) |scenario| {
            const name = try std.fmt.allocPrint(a, "{s}-{s}", .{ scenario, @tagName(protocol) });
            var c = try config(a, name, protocol);
            var client = try Client.init(t.allocator, backend.io(), &c, "fake-local-key");
            defer client.deinit();

            // 每个异常场景在两种协议下都必须返回 failure。
            const out = try client.model().call(a, request(c, protocol), .{});
            try t.expect(out == .failure);
            if (std.mem.eql(u8, scenario, "truncated")) try t.expectEqual(p.FailureKind.transport, out.failure.kind);
        }
    }
}

/// 150ms 后触发取消，用于模拟客户端在请求中途被取消。
fn cancelLater(io: Io, cancel: *p.Cancellation) !void {
    try Io.sleep(io, .fromMilliseconds(150), .awake);
    cancel.cancel();
}

// 验证：响应头或响应体停滞时超时返回 timeout，主动取消返回 canceled，且超时/取消后同一 Client 仍能成功完成请求。
test "integration: stalled headers bodies timeout cancel and client recovery" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    const io = backend.io();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{ "stall-header", "stall-body", "cancel-header", "cancel-body" }) |scenario| {
        var c = try config(a, scenario, .chat);

        const cancel_test = std.mem.startsWith(u8, scenario, "cancel");
        c.limits.request_timeout_ms = if (cancel_test) 5000 else 150;

        var client = try Client.init(t.allocator, io, &c, "fake-local-key");
        defer client.deinit();

        var cancellation = p.Cancellation{};
        var req = request(c, .chat);
        req.cancellation = &cancellation;

        // 后台协程在 150ms 后取消请求，仅对 cancel-* 场景有意义。
        var future = try Io.concurrent(io, cancelLater, .{ io, &cancellation });
        defer future.cancel(io) catch {};

        // stall 场景不挂取消句柄，由超时机制结束请求。
        if (!cancel_test) req.cancellation = null;

        // 整个调用必须在 2 秒内结束，证明超时或取消确实生效。
        const start = Io.Clock.awake.now(io);
        const out = try client.model().call(a, req, .{});
        try t.expect(out == .failure);
        try t.expectEqual(if (cancel_test) p.FailureKind.canceled else p.FailureKind.timeout, out.failure.kind);
        try t.expect(start.untilNow(io, .awake).toMilliseconds() < 2000);
        req.cancellation = null;

        // 恢复阶段放宽超时，验证同一 Client 在异常后仍可正常完成请求。
        c.limits.request_timeout_ms = 5000;
        _ = try success(try client.model().call(a, req, .{}));
    }
}
