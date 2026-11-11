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

fn testRequest() p.Request {
    return .{
        .scope = .{ .connection = "http://localhost", .model = "fixture", .protocol = .auto },
        .system = "fixed",
        .tools = &.{},
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "hello" }} }},
    };
}
