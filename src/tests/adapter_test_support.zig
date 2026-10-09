//! 适配器测试的共享支持：提供事件记录器、固定的回放作用域、测试工具定义和请求构造函数。

const std = @import("std");
const p = @import("../core/protocol.zig");

/// 记录 ModelSink 收到的事件：usage 快照次数与最新值，以及草稿事件数量。
pub const Recorder = struct {
    /// usage 快照的次数（每次 usage 事件 +1）。
    snapshots: usize = 0,
    /// 最近一次收到的 usage 快照。
    usage: p.Usage = .{},
    /// 草稿事件（文本、推理、工具增量）的数量，用于断言未提交的内容未被当作结果。
    drafts: usize = 0,

    /// 返回指向本 Recorder 的 ModelSink；Recorder 必须比 sink 活得更久。
    pub fn sink(self: *Recorder) p.ModelSink {
        return .{ .context = self, .emit_fn = emit };
    }

    /// ModelSink 回调：usage 覆盖为最新快照，草稿事件只计数。
    fn emit(context: ?*anyopaque, event: p.ModelEvent) !void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        switch (event) {
            .usage => |u| {
                self.snapshots += 1;
                self.usage = u;
            },
            .text_delta, .reasoning_delta, .tool_delta => {
                self.drafts += 1;
            },
        }
    }
};

/// 测试用 Chat 协议的回放作用域。
pub const chat_scope: p.ReplayScope = .{ .connection = "test-connection", .model = "test-model", .protocol = .chat };
/// 测试用 Responses 协议的回放作用域。
pub const response_scope: p.ReplayScope = .{ .connection = "test-connection", .model = "test-model", .protocol = .responses };

/// 测试用工具定义：一个名为 lookup、参数为字符串 q 的工具。
pub const schemas = [_]p.ToolSchema{.{ .name = "lookup", .description = "Look up", .parameters_json = "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}" }};

/// 构造测试请求：按协议选择 scope，system 中包含 memory 快照片段，消息列表初始为空。
pub fn request(proto: p.Protocol) p.Request {
    return .{ .scope = if (proto == .chat) chat_scope else response_scope, .system = "fixed system\nMemory snapshot", .tools = &schemas, .messages = &.{}, .max_output_tokens = 512 };
}

/// 断言 haystack 中包含 needle，否则测试失败。
pub fn contains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
