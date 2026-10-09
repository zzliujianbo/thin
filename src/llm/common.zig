//! LLM 公共工具：JSON 辅助函数、请求/历史校验、用量归一化以及 Chat / Responses 请求体构造。
//! 这里的上限函数是防御性限制，用来约束输入大小和嵌套深度，防止恶意或异常数据耗尽资源。

const std = @import("std");
const p = @import("../core/protocol.zig");
const j = @import("../util/json.zig");

/// 单次请求/响应中字符串与 JSON 的总字节上限（16 MiB）。
pub const max_bytes = 16 * 1024 * 1024;
/// 单次请求中消息块或历史条目的数量上限。
pub const max_items = 1024;
/// 单次请求可携带的工具数量上限。
pub const max_tools = 64;

/// JSON 值类型别名，来自 util/json.zig。
pub const V = j.Value;
/// 创建空 JSON 对象的辅助函数别名。
pub const object = j.object;
/// 向 JSON 对象写入字段的辅助函数别名。
pub const put = j.put;

/// 判断两个字符串内容是否相等（按字节比较）。
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 检查 v 是否为对象，且所有键都在 allowed 白名单中；用于拒绝未知字段。
pub fn onlyKeys(v: V, allowed: []const []const u8) bool {
    if (v != .object) return false;
    var iter = v.object.iterator();
    while (iter.next()) |entry| {
        var known = false;
        for (allowed) |key| if (eq(key, entry.key_ptr.*)) {
            known = true;
            break;
        };
        if (!known) return false;
    }
    return true;
}

/// 读取 v[key] 的字符串值；缺失或类型不符时返回 InvalidEvent。
pub fn text(v: V, key: []const u8) ![]const u8 {
    return j.string(j.get(v, key)) orelse error.InvalidEvent;
}

/// 把 JSON 数组转换为元素切片；非数组时返回 InvalidEvent。
pub fn list(v: V) ![]const V {
    return if (v == .array) v.array.items else error.InvalidEvent;
}

/// 深拷贝 JSON 值到分配器 a 中，使结果不依赖原输入的生命周期。
pub fn clone(a: std.mem.Allocator, v: V) !V {
    return switch (v) {
        .string => |s| j.str(try a.dupe(u8, s)),
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |items| blk: {
            var out = j.array(a);
            for (items.items) |x| try j.append(&out, try clone(a, x));
            break :blk out;
        },
        .object => |obj| blk: {
            var out = object(a);
            var it = obj.iterator();
            while (it.next()) |kv| try put(a, &out, try a.dupe(u8, kv.key_ptr.*), try clone(a, kv.value_ptr.*));
            break :blk out;
        },
        // 其余标量（null/bool/integer/float）是值类型，直接复用即可。
        else => v,
    };
}

/// Bounded JSON even for unknown/opaque extension fields. Structural counting
/// runs before allocation; the actual parser still validates every byte.
/// 有界 JSON 解析：先做轻量结构扫描（字符串感知），限制嵌套深度与节点数，再交给真正的解析器。
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !V {
    if (bytes.len > max_bytes) return error.InputLimit;
    // 预扫描：跟踪是否在字符串内（处理转义），统计括号深度与对象/数组节点数。
    var quoted = false;
    var escaped = false;
    var depth: usize = 0;
    var nodes: usize = 0;

    for (bytes) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                quoted = false;
            }
        } else switch (byte) {
            '"' => {
                quoted = true;
            },
            '{', '[' => {
                depth += 1;
                nodes += 1;
                if (depth > 128 or nodes > 16384) return error.InputLimit;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }

    // 结构检查通过后，由真正的解析器校验 JSON 语法。
    return j.parse(a, bytes);
}

/// 校验工具参数是否为合法 JSON 对象；不保留解析结果，仅做检查。
pub fn arguments(bytes: []const u8) !void {
    if (bytes.len > max_bytes) return error.InputLimit;
    // 解析结果只用于校验，使用独立 arena 并在函数返回时整体释放。
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const v = parse(arena.allocator(), bytes) catch return error.InvalidToolArguments;
    if (v != .object) return error.InvalidToolArguments;
}

/// 校验请求是否可以用协议 proto 发送：协议必须匹配、数量与大小受限、工具名唯一、回放块的 scope 一致。
/// 所有大小检查都是累计估算，任一超限即返回 InputLimit。
pub fn validateRequest(req: p.Request, proto: p.Protocol) !void {
    if (req.scope.protocol != proto) return error.ReplayScopeMismatch;
    if (req.messages.len > max_items or req.tools.len > max_tools or req.system.len > max_bytes) return error.InputLimit;
    // size 累计 system、模型名、推理强度、工具与消息内容的字节数，共用 max_bytes 上限。
    var size: usize = req.system.len + req.scope.model.len + (if (req.reasoning_effort) |s| s.len else @as(usize, 0));
    if (size > max_bytes) return error.InputLimit;
    var block_count: usize = 0;

    // 工具名必须非空且不重复；参数 schema 必须是合法 JSON 对象。
    for (req.tools, 0..) |tool, index| {
        for (req.tools[0..index]) |previous| if (eq(previous.name, tool.name)) return error.DuplicateToolName;
        if (tool.name.len == 0) return error.InvalidToolName;
        size += tool.name.len + tool.description.len + tool.parameters_json.len;
        if (size > max_bytes) return error.InputLimit;
        try arguments(tool.parameters_json);
    }

    // 回放块只能附着在 assistant 消息上，且其 scope 必须与当前请求一致，否则拒绝复用。
    for (req.messages) |m| {
        block_count += m.blocks.len;
        if (block_count > max_items) return error.InputLimit;
        if (m.replay) |r| {
            if (m.role != .assistant or !req.scope.eql(r.scope)) return error.ReplayScopeMismatch;
            size += r.json.len;
        }
        for (m.blocks) |b| size += switch (b) {
            .text, .reasoning => |s| s.len,
            .tool_call => |c| c.id.len + c.name.len + c.arguments.len,
            .tool_result => |r| r.call_id.len + r.text.len,
        };
        if (size > max_bytes) return error.InputLimit;
    }
}

/// 把 Responses 或 Chat 返回的 usage 对象归一化为 p.Usage；缺失字段为 null。
pub fn usage(v: V, responses: bool) p.Usage {
    // 两种协议的字段名不同（input/prompt、output/completion），这里统一映射。
    const input = if (responses) "input_tokens" else "prompt_tokens";
    const output = if (responses) "output_tokens" else "completion_tokens";
    const id = j.get(v, if (responses) "input_tokens_details" else "prompt_tokens_details") orelse .null;
    const od = j.get(v, if (responses) "output_tokens_details" else "completion_tokens_details") orelse .null;

    return .{
        .input_tokens = j.uint(j.get(v, input)),
        .output_tokens = j.uint(j.get(v, output)),
        .total_tokens = j.uint(j.get(v, "total_tokens")),
        .cached_input_tokens = j.uint(j.get(id, "cached_tokens")) orelse j.uint(j.get(v, "prompt_cache_hit_tokens")),
        .cache_write_tokens = j.uint(j.get(id, "cache_write_tokens")),
        .reasoning_tokens = j.uint(j.get(od, "reasoning_tokens")),
    };
}

/// 将 src 中的非空用量字段合并到 dst（后到的值覆盖旧值）。
pub fn mergeUsage(dst: *p.Usage, src: p.Usage) void {
    // A later partial cumulative snapshot invalidates an older explicit total.
    // The normalized Usage.total() can derive it from known input/output values.
    if (src.total_tokens == null and (src.input_tokens != null or src.output_tokens != null)) dst.total_tokens = null;

    inline for (.{ "input_tokens", "output_tokens", "cached_input_tokens", "cache_write_tokens", "reasoning_tokens", "total_tokens" }) |name| {
        if (@field(src, name)) |n| @field(dst, name) = n;
    }
}

/// 流式文本分段收集器：逐段复制保存，最后一次性拼接，并限制总长度为 max_bytes。
pub const Chunks = struct {
    /// 已复制保存的各段文本，由 Chunks 自己的分配器持有。
    parts: std.ArrayList([]const u8) = .empty,
    /// 所有段的累计字节数，用于上限检查，并在 join 时分配输出缓冲。
    len: usize = 0,
    /// 追加一段文本（复制一份）；超出 max_bytes 时返回 InputLimit。
    pub fn add(self: *Chunks, a: std.mem.Allocator, s: []const u8) !void {
        if (self.len + s.len > max_bytes) return error.InputLimit;
        try self.parts.append(a, try a.dupe(u8, s));
        self.len += s.len;
    }

    /// 把所有段按顺序拼接成一个新分配的缓冲，调用方负责释放。
    pub fn join(self: Chunks, a: std.mem.Allocator) ![]u8 {
        const out = try a.alloc(u8, self.len);
        var n: usize = 0;
        for (self.parts.items) |part| {
            @memcpy(out[n..][0..part.len], part);
            n += part.len;
        }
        return out;
    }
};

/// 构造通用模型失败结果。observed 表示失败前是否已输出内容，用于阻止协议回退。
pub fn failure(observed: bool, token_usage: p.Usage, raw_usage: ?[]const u8) p.Outcome {
    return .{ .failure = .{ .kind = .model, .message = "Model did not complete successfully.", .observed_content = observed, .usage = token_usage, .raw_usage_json = raw_usage } };
}

/// 复制回放作用域的 connection 与 model 字符串到分配器 a 中，使其独立于原始请求。
pub fn scopeCopy(a: std.mem.Allocator, scope: p.ReplayScope) !p.ReplayScope {
    return .{ .connection = try a.dupe(u8, scope.connection), .model = try a.dupe(u8, scope.model), .protocol = scope.protocol };
}

/// 把工具 schema 转为请求体中的 tools 数组。chat 为真时使用 Chat 包装格式，否则使用 Responses 扁平格式。
pub fn tools(a: std.mem.Allocator, schemas: []const p.ToolSchema, chat: bool) !V {
    var out = j.array(a);
    for (schemas) |schema| {
        var f = object(a);
        try put(a, &f, "name", j.str(schema.name));
        try put(a, &f, "description", j.str(schema.description));
        try put(a, &f, "parameters", try parse(a, schema.parameters_json));

        // Chat 格式：{type: function, function: {...}}；Responses 格式：扁平的 function 对象。
        if (chat) {
            var wrapper = object(a);
            try put(a, &wrapper, "type", j.str("function"));
            try put(a, &wrapper, "function", f);
            try j.append(&out, wrapper);
        } else {
            try put(a, &f, "type", j.str("function"));
            // Our schemas deliberately contain optional parameters. Responses
            // must not normalize them into strict/all-required tool arguments.
            try put(a, &f, "strict", .{ .bool = false });
            try j.append(&out, f);
        }
    }

    return out;
}

/// 构造 Chat 或 Responses 请求体的公共部分（模型、流式开关、输出上限、工具与推理强度）。
pub fn base(a: std.mem.Allocator, req: p.Request, chat: bool) !V {
    var v = object(a);
    try put(a, &v, "model", j.str(req.scope.model));
    try put(a, &v, "stream", .{ .bool = true });
    try put(a, &v, if (chat) "max_completion_tokens" else "max_output_tokens", try j.number(req.max_output_tokens));
    try put(a, &v, "tools", try tools(a, req.tools, chat));

    // 摘要请求不允许模型调用工具。
    if (req.purpose == .summary) try put(a, &v, "tool_choice", j.str("none"));

    // Chat 把 reasoning_effort 放在顶层，Responses 则放在 reasoning 对象中。
    if (req.reasoning_effort) |s| {
        if (chat) try put(a, &v, "reasoning_effort", j.str(s)) else {
            var r = object(a);
            try put(a, &r, "effort", j.str(s));
            try put(a, &v, "reasoning", r);
        }
    }
    return v;
}

/// 校验历史条目中的工具调用与结果是否配对：每个结果必须对应且只对应一个已发出的调用 id。
/// chat 为真时按 Chat 格式（tool_calls / tool 角色）解析，否则按 Responses 格式（function_call 系列）解析。
pub fn validateHistory(items: V, chat: bool) !void {
    const array = try list(items);
    if (array.len > max_items) return error.InputLimit;

    // ids 的值：false 表示调用已发出但尚未有结果，true 表示结果已配对。
    var ids = std.StringHashMap(bool).init(std.heap.page_allocator);
    defer ids.deinit();

    for (array) |item| {
        if (chat) {
            const role = try text(item, "role");
            if (eq(role, "assistant")) {
                if (j.get(item, "tool_calls")) |calls| if (calls != .null) {
                    for (try list(calls)) |call| try addHistoryCall(&ids, try text(call, "id"));
                };
            } else if (eq(role, "tool")) try resolveHistoryCall(&ids, try text(item, "tool_call_id"));
        } else {
            const typ = try text(item, "type");
            if (eq(typ, "function_call")) try addHistoryCall(&ids, try text(item, "call_id")) else if (eq(typ, "function_call_output")) try resolveHistoryCall(&ids, try text(item, "call_id"));
        }
    }
}

/// 记录一个新的工具调用 id；空 id 或重复 id 都会报错。
fn addHistoryCall(ids: *std.StringHashMap(bool), id: []const u8) !void {
    if (id.len == 0) return error.InvalidToolId;
    const entry = try ids.getOrPut(id);
    if (entry.found_existing) return error.DuplicateToolId;
    entry.value_ptr.* = false;
}

/// 将已发出的调用标记为已有结果；未知 id 或重复结果都会报错。
fn resolveHistoryCall(ids: *std.StringHashMap(bool), id: []const u8) !void {
    const resolved = ids.getPtr(id) orelse return error.UnmatchedToolResult;
    if (resolved.*) return error.DuplicateToolResult;
    resolved.* = true;
}

/// 检查 id 非空且在 ids 中唯一，并把它加入集合。
pub fn checkUnique(ids: *std.StringHashMap(void), id: []const u8) !void {
    if (id.len == 0) return error.InvalidToolId;
    const entry = try ids.getOrPut(id);
    if (entry.found_existing) return error.DuplicateToolId;
}

/// Enforces full native tool calls before they enter committed history.
pub fn chatCalls(v: V) !void {
    const calls = j.get(v, "tool_calls") orelse return;
    if (calls == .null) return;
    const arr = try list(calls);
    if (arr.len > max_tools) return error.InputLimit;

    // 仅用于本次校验的临时去重集合，使用 page_allocator 并在函数返回时释放。
    var ids = std.StringHashMap(void).init(std.heap.page_allocator);
    defer ids.deinit();

    for (arr) |c| {
        try checkUnique(&ids, try text(c, "id"));
        if (!eq(try text(c, "type"), "function")) return error.InvalidEvent;
        const f = j.get(c, "function") orelse return error.InvalidEvent;
        if ((try text(f, "name")).len == 0) return error.InvalidEvent;
        try arguments(try text(f, "arguments"));
    }
}
