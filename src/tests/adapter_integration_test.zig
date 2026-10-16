//! 适配器集成测试：离线验证 Chat/Responses 两种协议的 SSE 解析、不透明推理数据保留、工具 schema 编码与 HTTP 错误分类。

const std = @import("std");
const p = @import("../core/protocol.zig");
const j = @import("../util/json.zig");
const sse = @import("../llm/sse.zig");
const chat = @import("../llm/chat.zig");
const responses = @import("../llm/responses.zig");
const http = @import("../llm/http.zig");
const cfg = @import("../core/config.zig");
const support = @import("adapter_test_support.zig");

/// 把 SSE 解码器的回调桥接到具体的 Stream 类型 T（通过 *anyopaque 类型擦除传递上下文）。
fn Bridge(comptime T: type) type {
    return struct {
        fn feed(ctx: *anyopaque, event: []const u8, data: []const u8) !void {
            const stream: *T = @ptrCast(@alignCast(ctx));
            try stream.feed(event, data);
        }
    };
}

// 验证：按单字节切分的 SSE 流（含 CRLF、默认事件名、多字节 UTF-8）在两种适配器上都能还原文本与 usage。
test "byte-split SSE composes with both real adapters including default event names" {
    const chat_payload =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好🙂\"},\"finish_reason\":\"stop\"}]}\r\n\r\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}\n\n" ++
        "data: [DONE]\n\n";
    const responses_payload =
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\"}}\r\n\r\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"m\",\"content_index\":0,\"delta\":\"你好🙂\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"你好🙂\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":3}}}\n\n";

    // 对 Chat 与 Responses 使用同一套断言，各自携带对应的 payload 与 scope。
    inline for (.{ chat.Stream, responses.Stream }, .{ chat_payload, responses_payload }, .{ support.chat_scope, support.response_scope }) |T, payload, scope| {
        // 每个协议使用独立 arena，避免两种流的状态互相污染。
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var stream = T.init(arena.allocator(), scope, .{});
        var decoder = sse.Decoder.init(std.testing.allocator, 65536, .{ .context = &stream, .emit_fn = Bridge(T).feed });
        defer decoder.deinit();

        // 逐字节喂入，模拟网络分片切断 UTF-8 字符与 CRLF 的情况。
        for (0..payload.len) |i| try decoder.feed(payload[i..][0..1]);
        try decoder.finish();

        const result = (try stream.finish()).success;
        try std.testing.expectEqualStrings("你好🙂", result.message.blocks[0].text);
        try std.testing.expectEqual(@as(?u64, 13), result.usage.total());

        // 纯文本回合没有不透明推理数据，不应要求保留回放。
        try std.testing.expect(!result.message.replay.?.retain_turn);
    }
}

// 验证：Chat 的 signature 与 Responses 的 encrypted_content 属于不透明推理数据：会限制压缩（retain_turn），但绝不能被当作文本输出。
test "opaque reasoning constrains compaction but is never normalized into text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Chat 流：signature 应标记为需保留，但 blocks 中只有可见文本。
    var chat_stream = chat.Stream.init(a, support.chat_scope, .{});
    try chat_stream.feed("message", "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\",\"signature\":\"OPAQUE\"},\"finish_reason\":\"stop\"}]}");
    try chat_stream.feed("message", "[DONE]");
    const chat_result = (try chat_stream.finish()).success;
    try std.testing.expect(chat_result.message.replay.?.retain_turn);
    try std.testing.expectEqualStrings("ok", chat_result.message.blocks[0].text);
    try std.testing.expectEqual(@as(usize, 1), chat_result.message.blocks.len);

    // Responses 流：reasoning 项应作为回放数据保留，不计入可见 blocks。
    var response_stream = responses.Stream.init(a, support.response_scope, .{});
    try response_stream.feed("message", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"OPAQUE\",\"summary\":[]},{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}}");
    const response_result = (try response_stream.finish()).success;
    try std.testing.expect(response_result.message.replay.?.retain_turn);
    try std.testing.expectEqual(@as(usize, 1), response_result.message.blocks.len);
    try std.testing.expectEqualStrings("ok", response_result.message.blocks[0].text);
}

// 验证：Responses 请求保留可选工具字段（strict=false），且不把运行时字段 cancellation/purpose 序列化进请求体。
test "Responses retains optional tool fields instead of enabling strict schemas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var req = support.request(.responses);
    var cancel = p.Cancellation{};
    req.cancellation = &cancel;

    // 编码后再解析，检查线上 JSON 的实际字段而不是内存结构。
    const value = try j.parse(a, try responses.encode(a, req));
    try std.testing.expect(!j.get(j.get(value, "tools").?.array.items[0], "strict").?.bool);
    try std.testing.expect(j.get(value, "cancellation") == null);
    try std.testing.expect(j.get(value, "purpose") == null);
}

// 验证：HTTP 模型在 scope 不匹配时拒绝调用，预取消的请求直接返回 canceled，全程不发起真实连接。
test "HTTP model validates scope and pre-cancel without entering transport" {
    const configuration = cfg.Config{
        .limits = .{ .low_price_input = false },
        // Intentionally not a URL: even a regression cannot contact a real host.
        .provider = .{ .base_url = "unused-test-connection", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "test-model", .context_tokens = 32768 },
    };

    var client = try http.Client.init(std.testing.allocator, std.testing.io, &configuration, "fake-key");
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 先使用不匹配的 connection，触发 scope 校验失败。
    var req = support.request(.chat);
    try std.testing.expectError(error.ReplayScopeMismatch, client.model().call(arena.allocator(), req, .{}));

    // scope 修正后，再验证预取消：应在进入传输层前返回 canceled。
    req.scope.connection = configuration.provider.base_url;
    var cancel = p.Cancellation{};
    cancel.cancel();
    req.cancellation = &cancel;
    const out = try client.model().call(arena.allocator(), req, .{});
    try std.testing.expectEqual(p.FailureKind.canceled, out.failure.kind);

    // 含 NUL 字节的 API key 必须在构造 Client 时被拒绝，避免被传入底层请求。
    try std.testing.expectError(error.InvalidApiKey, http.Client.init(std.testing.allocator, std.testing.io, &configuration, "fake\x00key"));
}

// 验证：部分（累计）usage 合并时不保留过期的显式 total，total 按各分项重新计算。
test "partial cumulative usage does not retain a stale explicit total" {
    const common = @import("../llm/common.zig");
    var usage = p.Usage{ .input_tokens = 10, .output_tokens = 2, .total_tokens = 12 };
    common.mergeUsage(&usage, .{ .output_tokens = 4 });
    try std.testing.expectEqual(@as(?u64, 14), usage.total());
}

// 验证：HTTP 错误（如 404 不支持的端点）仍保留响应中报告的 usage 与 cached token，并保留原始 usage JSON。
test "failed and fallback HTTP attempts retain reported usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 错误响应体中可能包含已计费的 usage，失败结果也必须保留它。
    const result = http.classifyHttpError(arena.allocator(), 404, "{\"error\":{\"code\":\"unsupported_endpoint\"},\"usage\":{\"input_tokens\":12,\"output_tokens\":0,\"input_tokens_details\":{\"cached_tokens\":8}}}");
    try std.testing.expectEqual(p.FailureKind.unsupported_protocol, result.failure.kind);
    try std.testing.expectEqual(@as(?u64, 12), result.failure.usage.total());
    try std.testing.expectEqual(@as(?u64, 8), result.failure.usage.cached_input_tokens);
    try std.testing.expect(result.failure.raw_usage_json != null);
}
