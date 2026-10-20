//! LLM 协议选择与回退：Selector 决定使用 Responses 还是 Chat 协议，
//! 并在 auto 模式下处理一次性的 Chat 回退。选择状态只属于当前 Runtime，不持久化。

const std = @import("std");
const p = @import("../core/protocol.zig");

/// Protocol selection is per Runtime, never persisted as a capability cache.
pub const Selector = struct {
    /// 用户配置的协议；auto 表示由运行时自动选择。
    configured: p.Protocol,
    /// 已确定的协议；null 表示尚未选定（仅 auto 模式会出现）。
    selected: ?p.Protocol,
    /// 首次尝试是否已发生；为真后回退窗口关闭，之后不再回退。
    initial_attempted: bool = false,

    pub const Result = struct {
        /// 最终结果（成功或失败）。
        outcome: p.Outcome,
        /// 本次调用是否发生了 Responses -> Chat 回退。
        fallback: bool = false,
        /// 回退前失败的那次请求的 usage，用于统计计费。
        fallback_usage: ?p.Usage = null,
        /// 实际发出的模型请求次数（0 表示未调用模型，2 表示发生了回退）。
        calls: u8 = 1,
    };

    /// 创建选择器。显式协议会直接固定；auto 从未选定状态开始。
    pub fn init(configured: p.Protocol) Selector {
        return .{ .configured = configured, .selected = if (configured == .auto) null else configured };
    }

    /// 当前应使用的协议：已选定则用其值，否则默认 responses 作为首次尝试。
    pub fn effective(self: *const Selector) p.Protocol {
        return self.selected orelse .responses;
    }

    /// 发起一次模型调用并处理协议选择。
    /// 已选定或显式配置时固定使用该协议。auto 且未选定时先试 Responses；仅当返回
    /// unsupported_protocol、尚未输出任何内容、非摘要请求且无模型历史时，改用 Chat 重试一次。
    /// 回退后无论 Chat 成败，协议都固定为 Chat。
    pub fn call(self: *Selector, model: p.Model, allocator: std.mem.Allocator, original: p.Request, sink: p.ModelSink) !Result {
        // SystemOne is a question/threshold protocol, never a chat probe.
        if (self.configured == .systemone or self.effective() == .systemone or original.scope.protocol == .systemone) return .{
            .outcome = .{ .failure = .{ .kind = .unsupported_protocol, .message = "SystemOne does not support chat generation" } },
            .calls = 0,
        };
        // 调用前已取消：直接返回，不访问模型（calls = 0）。
        if (original.cancellation) |cancel| {
            if (cancel.isRequested()) return .{
                .outcome = .{ .failure = .{ .kind = .canceled, .message = "Execution canceled" } },
                .calls = 0,
            };
        }

        // 摘要请求不能用来探测协议：未选定时报错，避免摘要改变选择状态。
        if (original.purpose == .summary and self.selected == null) return error.ProtocolNotSelected;

        // 回退资格必须在首次尝试前判定：仅 auto、未选定、首次、普通请求且无模型历史时允许。
        const can_fallback = self.configured == .auto and self.selected == null and
            !self.initial_attempted and original.purpose == .normal and !hasModelHistory(original.messages);

        // 标记首次尝试已发生，之后即使失败也不会重新打开回退窗口。
        self.initial_attempted = true;

        var request = original;
        request.scope.protocol = self.effective();

        // Bridge 包装 sink，使流式内容到达时能锁定实际使用的协议。
        var bridge = Bridge{ .selector = self, .chosen = request.scope.protocol, .sink = sink };
        const outcome = try model.call(allocator, request, bridge.modelSink());

        // 成功则固定协议；失败时只有满足条件才进入回退分支，否则原样返回。
        switch (outcome) {
            .success => self.selected = request.scope.protocol,
            .failure => |f| {
                // 已输出过内容说明协议可用，即使失败也固定，禁止之后回退。
                if (f.observed_content) self.selected = request.scope.protocol;

                // 仅当"协议不被支持"且没有任何内容输出时才回退到 Chat。
                if (can_fallback and self.selected == null and f.kind == .unsupported_protocol and !f.observed_content) {
                    // 回退前再次检查取消，避免取消后仍发起第二次请求。
                    if (original.cancellation) |cancel| {
                        if (cancel.isRequested()) return .{ .outcome = .{ .failure = .{
                            .kind = .canceled,
                            .message = "Execution canceled before protocol fallback",
                            .usage = f.usage,
                        } } };
                    }

                    // Re-encode the SAME internal request. No Responses output or
                    // wire history is translated. Selecting Chat is final even if
                    // its first request fails.
                    self.selected = .chat;
                    request.scope.protocol = .chat;
                    bridge.chosen = .chat;
                    return .{
                        .outcome = try model.call(allocator, request, bridge.modelSink()),
                        .fallback = true,
                        .fallback_usage = f.usage,
                        .calls = 2,
                    };
                }
            },
        }

        return .{ .outcome = outcome };
    }

    /// 包装调用方的 sink：收到非 usage 事件即锁定当前协议（usage 不算模型内容）。
    const Bridge = struct {
        /// 所属选择器，内容到达时写入其 selected。
        selector: *Selector,
        /// 本次尝试实际使用的协议。
        chosen: p.Protocol,
        /// 下游 sink，事件最终转发到这里。
        sink: p.ModelSink,
        /// 转发事件；非 usage 事件说明模型已有输出，此时锁定协议。
        fn emit(context: ?*anyopaque, event: p.ModelEvent) !void {
            const self: *Bridge = @ptrCast(@alignCast(context.?));
            switch (event) {
                .usage => {}, // Usage metadata is not model content.
                else => self.selector.selected = self.chosen,
            }
            try self.sink.emit(event);
        }

        /// 生成供模型调用使用的 ModelSink。
        fn modelSink(self: *Bridge) p.ModelSink {
            return .{ .context = self, .emit_fn = emit };
        }
    };
};

/// 判断历史中是否已有与协议绑定的内容（非用户消息、回放块、工具调用/结果或推理块）。
/// 有则不允许 auto 为这次请求重新选择协议。
pub fn hasModelHistory(messages: []const p.Message) bool {
    for (messages) |message| {
        // 回放块或非用户消息说明会话已与某个协议绑定，不能切换。
        if (message.replay != null or message.role != .user) return true;
        for (message.blocks) |block| switch (block) {
            .tool_call, .tool_result, .reasoning => return true,
            .text => {},
        };
    }
    return false;
}

/// 测试用假模型：记录每次调用的协议，并可按配置返回协议不支持的失败。
const Fake = struct {
    calls: usize = 0,
    kind: p.FailureKind = .unsupported_protocol,
    delta: bool = false,
    fail_chat: bool = false,
    /// 按调用顺序记录每次请求使用的协议。
    protocols: [4]p.Protocol = undefined,

    /// 假调用：protocol 为 responses 或 fail_chat 为真时返回失败，否则返回成功。
    fn call(context: *anyopaque, _: std.mem.Allocator, request: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.protocols[self.calls] = request.scope.protocol;
        self.calls += 1;

        if (self.delta) try sink.emit(.{ .reasoning_delta = "reason" });

        if (request.scope.protocol == .responses or self.fail_chat) return .{ .failure = .{
            .kind = self.kind,
            .message = "fake rejection",
            .usage = .{ .input_tokens = 7 },
        } };

        return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{.{ .text = "ok" }} },
            .finish = .stop,
        } };
    }

    /// 包装成 p.Model 接口供 Selector 调用。
    fn model(self: *Fake) p.Model {
        return .{ .context = self, .call_fn = call };
    }
};

/// 构造最小测试请求：auto 协议、普通用途、无历史消息。
fn testRequest() p.Request {
    return .{
        .scope = .{ .connection = "http://localhost", .model = "fixture", .protocol = .auto },
        .system = "fixed",
        .tools = &.{},
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "hello" }} }},
        .max_output_tokens = 100,
    };
}

test "SystemOne is never sent to the generative model or fallback" {
    var selector = Selector.init(.systemone);
    var fake = Fake{};
    const result = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expectEqual(@as(u8, 0), result.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(!result.fallback);
    try std.testing.expectEqual(p.FailureKind.unsupported_protocol, result.outcome.failure.kind);
    selector = Selector.init(.auto);
    var request = testRequest();
    request.scope.protocol = .systemone;
    const automatic = try selector.call(fake.model(), std.testing.allocator, request, .{});
    try std.testing.expectEqual(@as(u8, 0), automatic.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(!selector.initial_attempted);
}

// 验证：auto 首次 Responses 失败后回退 Chat 一次，且即使 Chat 失败也保持 Chat。
test "auto falls back once and remains pinned even when Chat fails" {
    var selector = Selector.init(.auto);
    var fake = Fake{ .fail_chat = true };
    const first = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expect(first.fallback);
    try std.testing.expectEqual(@as(u8, 2), first.calls);
    try std.testing.expectEqual(@as(?u64, 7), first.fallback_usage.?.input_tokens);
    try std.testing.expectEqual(p.Protocol.responses, fake.protocols[0]);
    try std.testing.expectEqual(p.Protocol.chat, fake.protocols[1]);
    _ = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqual(p.Protocol.chat, fake.protocols[2]);
}

// 验证：显式协议不回退；已输出内容后不回退。
test "explicit protocols and content never permit auto fallback" {
    var explicit = Selector.init(.responses);
    var fake = Fake{};
    _ = try explicit.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    var automatic = Selector.init(.auto);
    fake = .{ .delta = true };
    _ = try automatic.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(p.Protocol.responses, automatic.selected.?);
}

// 验证：普通错误（非协议不支持）会关闭首次选择窗口，之后不再回退。
test "ordinary errors cannot reopen the initial selection window" {
    var selector = Selector.init(.auto);
    var fake = Fake{ .kind = .authentication };
    _ = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    fake.kind = .unsupported_protocol;
    const next = try selector.call(fake.model(), std.testing.allocator, testRequest(), .{});
    try std.testing.expect(!next.fallback);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

// 验证：摘要请求在未选定时报错；已有模型历史时不改变协议选择。
test "summary and existing model history cannot select a new protocol" {
    var selector = Selector.init(.auto);
    var fake = Fake{};
    var request = testRequest();
    request.purpose = .summary;
    try std.testing.expectError(error.ProtocolNotSelected, selector.call(fake.model(), std.testing.allocator, request, .{}));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    request.purpose = .normal;
    request.messages = &.{.{ .role = .assistant, .blocks = &.{.{ .text = "prior" }} }};
    const result = try selector.call(fake.model(), std.testing.allocator, request, .{});
    try std.testing.expect(!result.fallback);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

// 验证：调用前已取消时不访问模型。
test "pre-cancelled calls do not use a model" {
    var selector = Selector.init(.auto);
    var fake = Fake{};
    var cancellation = p.Cancellation{};
    cancellation.cancel();
    var request = testRequest();
    request.cancellation = &cancellation;
    const result = try selector.call(fake.model(), std.testing.allocator, request, .{});
    try std.testing.expectEqual(@as(u8, 0), result.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}
