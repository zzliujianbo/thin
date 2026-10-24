//! 协议层：定义 ThinAgent 内部的数据模型（消息、工具调用、用量、请求/响应、流式事件、取消信号）。
//! 这里不处理网络或线协议 JSON 细节，由各 adapter 负责与具体提供方互相转换。

const std = @import("std");

/// auto probes only Responses/Chat. Anthropic Messages is selected explicitly.
pub const Protocol = enum { auto, chat, responses, anthropic, systemone };
/// 请求用途：normal 为普通对话，summary 为上下文压缩时生成滚动摘要。
pub const Purpose = enum { normal, summary };
/// 消息角色；context 为滚动摘要等注入的上下文，不是用户真实输入。
pub const Role = enum { user, assistant, tool, context };

/// Replay is valid only for this connection, model and selected protocol.
/// Never rendered or written to cropped diagnostic logs. Full-session checkpoints
/// preserve it as untrusted history, independently of credentials. Strings are
/// caller-arena-owned. Matching scope is necessary but not sufficient: prefix-bound
/// Anthropic thinking must also be discarded after client-side prefix rewrites.
/// 回放续接数据须同 connection/model/protocol，且此前请求前缀仍满足供应商约束。
pub const ReplayScope = struct {
    /// 提供方连接标识（如 base_url）。
    connection: []const u8,
    /// 模型名称。
    model: []const u8,
    /// 续接数据所依赖的线协议。
    protocol: Protocol,

    /// 判断两个作用域是否相同；不同作用域的续接数据不得互相发送。
    pub fn eql(a: ReplayScope, b: ReplayScope) bool {
        return a.protocol == b.protocol and std.mem.eql(u8, a.connection, b.connection) and
            std.mem.eql(u8, a.model, b.model);
    }
};

/// 上一轮模型输出的原始续接数据（如 reasoning 或 opaque 内容），仅在同一作用域内回放。
pub const Replay = struct {
    /// 产生该续接数据时的作用域，不匹配时必须丢弃 json。
    scope: ReplayScope,
    /// Chat/Anthropic: complete assistant role/content object.
    /// Responses: ordered output item array. Anthropic signed/opaque blocks stay native.
    json: []const u8,
    /// Conservative adapter constraint: reasoning/opaque continuation may require
    /// the entire user turn. Context may remove the closed turn as a whole, but
    /// cannot split its internal tool chain without verified adapter support.
    /// 中文：默认保守保留整个用户回合；除非 adapter 已验证，否则不得拆分其内部工具链。
    retain_turn: bool = true,
};

/// 模型发起的一次工具调用。
pub const ToolCall = struct {
    /// 调用 ID，必须与对应 ToolResult 的 call_id 配对。
    id: []const u8,
    /// 工具名称。
    name: []const u8,
    /// 工具参数的原始 JSON 文本。
    arguments: []const u8,
    /// Responses 协议中的 item id；Chat/Anthropic 协议中为 null。
    item_id: ?[]const u8 = null,
};

/// 工具执行结果，通过 call_id 与 ToolCall 配对。
pub const ToolResult = struct {
    /// 对应的 ToolCall.id。
    call_id: []const u8,
    /// 工具输出文本（可能已被截断）。
    text: []const u8,
    /// 工具是否执行失败。
    is_error: bool = false,
    /// 是否因取消而结束。
    canceled: bool = false,
    /// 输出是否因大小限制被截断。
    truncated: bool = false,
};

/// 消息中的一个内容块。
pub const Block = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    tool_call: ToolCall,
    tool_result: ToolResult,
};

/// 一条对话消息；replay 存在时优先使用其原始续接数据。
pub const Message = struct {
    role: Role,
    blocks: []const Block,
    /// 可选的原始续接数据；为 null 时只使用 blocks。
    replay: ?Replay = null,
};

/// 发送给模型的工具声明。
pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    /// 参数 schema 的 JSON 文本。
    parameters_json: []const u8,
};

/// 一次调用的 token 用量；null 表示提供方未报告该项，不能当作 0。
pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    /// 命中缓存的输入 token 数。
    cached_input_tokens: ?u64 = null,
    /// 写入缓存的 token 数。
    cache_write_tokens: ?u64 = null,
    /// 推理 token 数（已计入 output，不能重复累加）。
    reasoning_tokens: ?u64 = null,
    total_tokens: ?u64 = null,

    /// 优先使用提供方报告的 total；否则用 input+output 求和，溢出或缺失时返回 null。
    pub fn total(self: Usage) ?u64 {
        if (self.total_tokens) |n| return n;
        const a = self.input_tokens orelse return null;
        const b = self.output_tokens orelse return null;
        // 使用溢出检测加法，避免异常大的用量数值导致回绕。
        const sum = @addWithOverflow(a, b);
        return if (sum[1] == 0) sum[0] else null;
    }
};

/// 模型结束原因：stop 为正常结束，tool_calls 表示需要执行工具后继续。
pub const Finish = enum { stop, tool_calls };

/// 一次成功的模型响应（已完整提交，可写入历史）。
pub const Response = struct {
    message: Message,
    /// Explicit provider refusal metadata for helper consumers. Still a normal
    /// displayable response; deliberately not part of Message/history/replay.
    refused: bool = false,
    usage: Usage = .{},
    /// 提供方原始用量 JSON，仅用于诊断保留。
    raw_usage_json: ?[]const u8 = null,
    finish: Finish,
};

/// 模型调用失败的分类，供上层决定重试、降级或直接报错。
pub const FailureKind = enum {
    unsupported_protocol,
    authentication,
    rate_limit,
    context_limit,
    invalid_argument,
    model,
    server,
    transport,
    protocol,
    timeout,
    canceled,
    /// Explicit provider token-budget termination, never inferred from usage.
    /// Partial text/tool arguments are NOT a successful response or replay state.
    output_limit,
};

/// 一次失败调用的详情。
pub const Failure = struct {
    kind: FailureKind,
    /// Bounded and credential-free. Never put raw response/replay JSON here.
    /// 中文：长度有界且不含凭据；不得放入原始响应或续接 JSON。
    message: []const u8,
    http_status: ?u16 = null,
    /// 失败前是否已经收到过可见内容（影响上层是否能安全重试）。
    observed_content: bool = false,
    usage: Usage = .{},
    raw_usage_json: ?[]const u8 = null,
};

/// 模型调用的最终结果：成功（完整 Response）或失败（Failure）。
pub const Outcome = union(enum) { success: Response, failure: Failure };

/// A separate control path: a full output queue must never hide cancellation.
/// 中文：独立的取消通道；即使输出队列已满，取消信号也必须能送达。
pub const Cancellation = struct {
    /// 取消标志；使用原子变量，允许跨线程读写。
    requested: std.atomic.Value(bool) = .init(false),
    /// Read-only parent link (e.g. a child task's token). The parent must outlive
    /// this object; chains are short and must not form cycles. Never write
    /// through this pointer: a child-local timeout must not cancel the parent.
    /// 中文：只读父令牌引用；父对象生命周期须更长，禁止成环，也禁止借它写入父取消位。
    parent: ?*const Cancellation = null,
    /// 请求取消。release 写入，与 isRequested 的 acquire 读取配对。只写本地标志。
    pub fn cancel(self: *Cancellation) void {
        self.requested.store(true, .release);
    }

    /// 查询是否已请求取消：本地标志或父令牌之一为真。仅查询，不传播写入。
    pub fn isRequested(self: *const Cancellation) bool {
        if (self.requested.load(.acquire)) return true;
        const up = self.parent orelse return false;
        // Defensive self-link guard: a malformed parent must not recurse.
        if (up == self) return false;
        return up.isRequested();
    }
};

/// 一次模型请求的完整输入。
pub const Request = struct {
    scope: ReplayScope,
    system: []const u8,
    tools: []const ToolSchema,
    messages: []const Message,
    /// Frozen, verified model output capacity, not a configurable request cap.
    /// Chat/Responses omit output limits; Anthropic requires a known positive value.
    model_output_tokens: ?u32 = null,
    /// Already mapped wire string, not the logical UI effort.
    reasoning_effort: ?[]const u8 = null,
    thinking: ?bool = null,
    /// Retained even for unspecified effort so incompatible adapters reject early.
    reasoning_format: @import("thinking.zig").Format = .standard,
    purpose: Purpose = .normal,
    /// Local control only, never a provider request field.
    /// 中文：仅用于本地控制，不会作为字段发送给提供方。
    cancellation: ?*const Cancellation = null,
};

/// Display-only identity, separate from canonical call IDs and approval IDs.
/// A generation identifies one actual normal-model attempt (or local batch).
pub const ToolDisplayKey = struct {
    generation: u64,
    index: usize,

    pub fn eql(self: ToolDisplayKey, other: ToolDisplayKey) bool {
        return self.generation == other.generation and self.index == other.index;
    }
};

/// Model deltas are UI drafts, not executable history. Success commits a complete
/// Response. Event strings are borrowed for the duration of the callback only.
/// 中文：流式增量只用于界面显示，不是可执行历史；只有成功时才会提交完整 Response。
/// 事件中的字符串仅在回调期间有效，回调返回后不得保存。
pub const ModelEvent = union(enum) {
    text_delta: []const u8,
    reasoning_delta: []const u8,
    /// 第 index 个工具调用的参数增量。
    tool_delta: struct {
        index: usize,
        arguments: []const u8,
        /// Accumulated name snapshot, not just a fragment. Empty means unknown
        /// or too large for bounded preview metadata; execution is unaffected.
        name: []const u8 = "",
        /// Canonical provider ID when known. Borrowed only during emit; this
        /// never replaces the Runtime-owned host/approval identity.
        call_id: ?[]const u8 = null,
        /// Presentation-only recognition of a complete streamed tool name.
        /// This grants no execution or file-write authority.
        write_file: bool = false,
        argument_bytes: ?usize = null,
    },
    usage: Usage,
};

/// 流式事件的接收端：以函数指针 + 上下文的方式实现回调，避免泛型扩散。
pub const ModelSink = struct {
    context: ?*anyopaque = null,
    emit_fn: *const fn (?*anyopaque, ModelEvent) anyerror!void = discard,

    /// 把事件交给回调；回调返回错误时错误向上传播。
    pub fn emit(self: ModelSink, event: ModelEvent) !void {
        try self.emit_fn(self.context, event);
    }

    /// 默认的空回调：丢弃所有事件。
    fn discard(_: ?*anyopaque, _: ModelEvent) !void {}
};

/// Synchronous from the caller's perspective; implementations may use concurrent
/// I/O. All result allocations belong to result_allocator, never the transport.
/// 中文：对调用方而言是同步的，实现内部可以使用并发 I/O；
/// 所有结果内存都由传入的 allocator 持有，不能依赖传输层的内存。
pub const Model = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque, std.mem.Allocator, Request, ModelSink) anyerror!Outcome,

    /// 通过函数指针分派到具体提供方实现。
    pub fn call(self: Model, allocator: std.mem.Allocator, request: Request, sink: ModelSink) !Outcome {
        return self.call_fn(self.context, allocator, request, sink);
    }
};

/// 深拷贝一条消息（包括 replay），拷贝内存全部由 allocator 持有，与源消息互不依赖。
pub fn cloneMessage(allocator: std.mem.Allocator, message: Message) !Message {
    const blocks = try allocator.alloc(Block, message.blocks.len);

    // 逐块复制；任何一步失败都直接返回错误，由调用方的 arena 统一回收。
    for (message.blocks, blocks) |src, *dst| dst.* = switch (src) {
        .text => |s| .{ .text = try allocator.dupe(u8, s) },
        .reasoning => |s| .{ .reasoning = try allocator.dupe(u8, s) },
        .tool_call => |c| .{ .tool_call = .{
            .id = try allocator.dupe(u8, c.id),
            .name = try allocator.dupe(u8, c.name),
            .arguments = try allocator.dupe(u8, c.arguments),
            .item_id = if (c.item_id) |s| try allocator.dupe(u8, s) else null,
        } },
        .tool_result => |r| .{ .tool_result = .{
            .call_id = try allocator.dupe(u8, r.call_id),
            .text = try allocator.dupe(u8, r.text),
            .is_error = r.is_error,
            .canceled = r.canceled,
            .truncated = r.truncated,
        } },
    };

    return .{
        .role = message.role,
        .blocks = blocks,
        .replay = if (message.replay) |r| .{
            .scope = .{
                .connection = try allocator.dupe(u8, r.scope.connection),
                .model = try allocator.dupe(u8, r.scope.model),
                .protocol = r.scope.protocol,
            },
            .json = try allocator.dupe(u8, r.json),
            .retain_turn = r.retain_turn,
        } else null,
    };
}

/// 创建只含一个文本块的消息；文本会被复制到 allocator 中。
pub fn textMessage(allocator: std.mem.Allocator, role: Role, text: []const u8) !Message {
    const blocks = try allocator.alloc(Block, 1);
    blocks[0] = .{ .text = try allocator.dupe(u8, text) };
    return .{ .role = role, .blocks = blocks };
}

// 验证：未知用量为 null 时 total 返回 null；reasoning 与 cache 不会被重复计入总量。
test "usage preserves unknown values and does not double-count reasoning or cache" {
    const t = std.testing;
    try t.expectEqual(@as(?u64, null), (Usage{}).total());
    try t.expectEqual(@as(?u64, 15), (Usage{
        .input_tokens = 10,
        .output_tokens = 5,
        .cached_input_tokens = 8,
        .reasoning_tokens = 3,
    }).total());
}

// 验证：父取消只向下可见，子取消不会写回父令牌。
test "cancellation reads the parent one way and writes locally only" {
    var root: Cancellation = .{};
    var child: Cancellation = .{ .parent = &root };
    try std.testing.expect(!child.isRequested());
    child.cancel();
    try std.testing.expect(child.isRequested());
    try std.testing.expect(!root.isRequested());
    var sibling: Cancellation = .{ .parent = &root };
    try std.testing.expect(!sibling.isRequested());
    root.cancel();
    try std.testing.expect(sibling.isRequested());
    var self_link: Cancellation = .{};
    self_link.parent = &self_link;
    try std.testing.expect(!self_link.isRequested());
}

// 验证：续接兼容性必须同时检查 connection、model 和 protocol 三者。
test "replay compatibility includes connection, model and protocol" {
    const a = ReplayScope{ .connection = "https://a/v1", .model = "model", .protocol = .responses };
    var b = a;
    try std.testing.expect(a.eql(b));
    b.protocol = .chat;
    try std.testing.expect(!a.eql(b));
    b = a;
    b.connection = "https://b/v1";
    try std.testing.expect(!a.eql(b));
}
