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

// 验证：Chat 的 signature 与 Responses 的 encrypted_content 属于不透明推理数据：会限制压缩（retain_turn），但绝不能被当作文本输出。

// 验证：Responses 请求保留可选工具字段（strict=false），且不把运行时字段 cancellation/purpose 序列化进请求体。

// 验证：HTTP 模型在 scope 不匹配时拒绝调用，预取消的请求直接返回 canceled，全程不发起真实连接。

// 验证：部分（累计）usage 合并时不保留过期的显式 total，total 按各分项重新计算。

// 验证：HTTP 错误（如 404 不支持的端点）仍保留响应中报告的 usage 与 cached token，并保留原始 usage JSON。
