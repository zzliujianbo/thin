//! 配置层：解析并校验 config.json（严格 JSON，拒绝未知与重复字段），检查 URL、限额与预算，
//! API key 可内联保存或从环境变量读取；解析结果通过 release 擦除后释放。

const std = @import("std");
const protocol = @import("protocol.zig");
const thinking = @import("thinking.zig");
pub const providers = @import("providers.zig");

/// 单一配置文件名；路径构造、交互存储和文件工具保护共用，避免名称漂移。
pub const file_name = "config.json";

/// 提供方连接信息。两种密钥来源最多配置一种，也允许尚未配置密钥。
pub const Provider = struct {
    /// 提供方的基础 URL（仅允许 http/https，见 validateUrl）。
    base_url: []const u8,
    /// 存放 API key 的环境变量名。
    api_key_env: []const u8 = "",
    /// 内联 API key；未配置时必须为 null，不能是空字符串。
    api_key: ?[]const u8 = null,
    /// Chat 兼容选项：DeepSeek 等服务使用 max_tokens；默认仍用 max_completion_tokens。
    chat_max_tokens: bool = false,
    /// Explicit service identity; custom endpoints may opt into its transport
    /// conventions, but saved keys are only resolved for exact official URLs.
    kind: ?providers.Id = null,
};

/// 模型配置。
pub const Model = struct {
    /// 模型名称。
    name: []const u8,
    /// 模型上下文窗口大小（token 数），预算计算的基础。
    context_tokens: u32,
    /// 线协议选择，默认 auto。
    protocol: protocol.Protocol = .auto,
    /// 推理强度（可选），仅在提供方支持时使用。
    reasoning_effort: ?[]const u8 = null,
    /// Explicit capability/wire map for custom endpoints, owned by the parse arena.
    reasoning: ?thinking.Declaration = null,
};

/// Implementation defaults are adjustable; only the agreed timeout, read/output
/// sizes and compaction percentages are product requirements.
/// 中文：下面的默认值是实现层的可调参数；只有超时、读取/输出大小与压缩百分比是产品需求。
/// 所有字段在校验时都不能为 0（见 validate）。
pub const Limits = struct {
    /// 单条命令的默认超时（毫秒）。
    command_timeout_ms: u32 = 300000,
    /// 单条命令允许的最大超时（毫秒），命令超时不能超过它。
    command_max_timeout_ms: u32 = 3600000,
    /// 单次文件读取的字节上限。
    read_bytes: u32 = 65536,
    /// 单次工具输出的字节上限。
    output_bytes: u32 = 32768,
    /// 单次模型响应允许的最大输出 token 数。
    max_output_tokens: u32 = 4096,
    /// 预留的安全余量 token 数，从输入预算中扣除。
    safety_tokens: u32 = 2048,
    /// 单个任务允许的最大模型轮数。
    /// Model turns per user submission. Compaction is not counted.
    max_rounds: u16 = 50,
    /// 单个任务允许的最大工具调用次数。
    max_tool_calls: u16 = 128,
    /// 整个任务的超时（毫秒）。
    task_timeout_ms: u32 = 1800000,
    /// 单次模型请求的超时（毫秒）。
    request_timeout_ms: u32 = 300000,
    /// 取消时先发送 TERM 后等待的宽限时间（毫秒）。
    cleanup_grace_ms: u32 = 1000,
    /// 清理子进程的总超时（毫秒），超过后强制结束。
    cleanup_timeout_ms: u32 = 5000,
    /// 核心记忆文件的大小上限。
    core_bytes: u32 = 2048,
    /// 索引文件的大小上限。
    index_bytes: u32 = 8192,
    /// 单个分片文件的大小上限。
    shard_bytes: u32 = 32768,
    /// 触发压缩的上下文占用百分比。
    compaction_trigger_percent: u8 = 80,
    /// 压缩后希望达到的上下文占用百分比（必须小于触发阈值）。
    compaction_target_percent: u8 = 50,
    /// 摘要输出预留的 token 数（不能超过 max_output_tokens）。
    summary_tokens: u32 = 2048,
    /// 单次模型响应的最大字节数。
    max_response_bytes: u32 = 8388608,
    /// 单个流式事件的最大字节数（不能超过 max_response_bytes）。
    max_event_bytes: u32 = 1048576,
};

/// 完整配置的根结构，对应 config.json 的顶层对象。
pub const Config = struct {
    provider: Provider,
    model: Model,
    /// Same-provider profiles; no discovery or credential overrides.
    models: []const Model = &.{},
    /// Private, independently saved credentials. Never session metadata.
    credentials: providers.Credentials = .{},
    /// 未配置时使用 Limits 中的默认值。
    limits: Limits = .{},
};

/// 配置文件的大小上限（64 KiB），超过则直接拒绝，防止占用过多内存。
pub const max_config_bytes = 64 * 1024;

/// Every string is owned by the returned arena, never by `bytes`.
/// 中文：解析后的字符串复制到 allocator 中，因此调用方可以擦除 bytes；结果需调用 release 释放。
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Config) {
    return parseBounded(allocator, bytes, max_config_bytes);
}

/// Clone an already bounded, validated application configuration. Re-encoding
/// default fields may exceed the input-file limit; it does not relax disk reads.
pub fn clone(allocator: std.mem.Allocator, config: Config) !std.json.Parsed(Config) {
    if (config.provider.base_url.len > max_config_bytes) return error.ConfigTooLarge;
    try validate(config);
    var wiping = WipingAllocator{ .backing = allocator };
    const bytes = try std.json.Stringify.valueAlloc(wiping.allocator(), config, .{ .emit_null_optional_fields = false });
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    return parseBounded(allocator, bytes, 512 * 1024);
}

fn parseBounded(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) !std.json.Parsed(Config) {
    if (bytes.len > limit) return error.ConfigTooLarge;

    // 包装底层分配器：即使 JSON 在读完 key 后才失败，也擦除所有中间分配。
    var wiping = WipingAllocator{ .backing = allocator };
    var parsed = try std.json.parseFromSlice(Config, wiping.allocator(), bytes, .{
        // 强制复制所有字符串，使结果与输入缓冲区解耦。
        .allocate = .alloc_always,
        // 严格模式：未知字段直接报错，避免拼写错误被静默忽略。
        .ignore_unknown_fields = false,
        // 重复字段视为错误，而不是取最后一个值。
        .duplicate_field_behavior = .@"error",
    });

    // 语义校验失败时需要释放已解析的内存。
    parsed.arena.child_allocator = allocator;
    errdefer release(&parsed);
    try validate(parsed.value);
    return parsed;
}

/// 擦除所有释放的分配；禁止缩容与 remap，避免分配器内部释放未擦除的旧缓冲区。
const WipingAllocator = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, bytes);
        self.backing.rawFree(bytes, alignment, ra);
    }
};

/// 只用于 parse/load 返回的拥有型结果；先擦除 key，再擦除整个 arena 后释放。
pub fn release(parsed: *std.json.Parsed(Config)) void {
    if (parsed.value.provider.api_key) |key| std.crypto.secureZero(u8, @constCast(key));
    var wiping = WipingAllocator{ .backing = parsed.arena.child_allocator };
    parsed.arena.child_allocator = wiping.allocator();
    parsed.deinit();
    parsed.* = undefined;
}

fn validateKeySource(provider: Provider) !void {
    if (provider.api_key != null and provider.api_key_env.len != 0) return error.AmbiguousApiKey;
    if (provider.api_key) |key| {
        if (!validText(key, 16384)) return error.InvalidApiKey;
    }
    if (provider.api_key_env.len != 0 and !validEnvName(provider.api_key_env)) return error.InvalidApiKeyEnv;
}

/// 检查文本是否非空、长度不超过 max、不全是空白，且不含控制字符（防止 header 注入）。
fn validText(text: []const u8, max: usize) bool {
    if (text.len == 0 or text.len > max or std.mem.trim(u8, text, " \t\r\n").len == 0) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// 检查环境变量名：只允许字母与下划线开头，之后可包含数字，长度不超过 256。
fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or name.len > 256) return false;
    for (name, 0..) |c, i| {
        if (!(std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c)))) return false;
    }
    return true;
}

/// 校验 base_url：只接受 http/https，拒绝用户信息、查询串、片段，以及可能被中间层误解析的编码字符。
fn validateUrl(url: []const u8) !void {
    if (!validText(url, 8192)) return error.InvalidBaseUrl;

    // Strict HTTP URL subset: no ambiguous authority separators or encoded
    // control characters, even if an intermediary percent-decodes the URL.
    // 中文：只接受严格的 HTTP URL 子集，即使中间代理会进行百分号解码，也不允许出现控制字符。
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        const c = url[i];
        // 拒绝空白、非 ASCII、DEL 以及反斜杠（部分解析器会把它当作路径分隔符）。
        if (c <= 0x20 or c >= 0x7f or c == '\\') return error.InvalidBaseUrl;
        if (c == '%') {
            // 百分号编码必须是完整的 %XX 形式。
            if (url.len - i < 3) return error.InvalidBaseUrl;
            const decoded = std.fmt.parseInt(u8, url[i + 1 ..][0..2], 16) catch return error.InvalidBaseUrl;
            // 解码后若为控制字符同样拒绝。
            if (decoded < 0x20 or decoded == 0x7f) return error.InvalidBaseUrl;
            i += 2;
        }
    }

    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidBaseUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidBaseUrl;

    // 不允许用户信息（user:pass@）、查询串与片段，避免凭据混入 URL。
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidBaseUrl;

    const host = uri.host orelse return error.InvalidBaseUrl;
    // 主机名不能为空，显式端口不能为 0。
    if (host.isEmpty() or uri.port == 0) return error.InvalidBaseUrl;
    const host_text = switch (host) {
        .raw, .percent_encoded => |s| s,
    };

    // Percent-encoded authority can conceal userinfo or other delimiters.
    // 中文：主机部分若含百分号编码，可能隐藏用户信息或其他分隔符，因此直接拒绝。
    if (std.mem.findScalar(u8, host_text, '%') != null) return error.InvalidBaseUrl;
}

/// 校验整个配置：URL、环境变量名、模型名、各项限额以及 token 预算与压缩比例。
/// 任一项不合法都会返回对应的错误。
pub fn validate(config: Config) !void {
    try validateUrl(config.provider.base_url);
    try validateKeySource(config.provider);
    if (config.provider.kind) |declared| if (providers.Id.fromUrl(config.provider.base_url)) |actual| {
        if (declared != actual) return error.ProviderEndpointMismatch;
    };
    try config.credentials.validate();

    const l = config.limits;
    // 编译期遍历 Limits 的所有字段，任何字段为 0 都视为非法。
    inline for (@typeInfo(Limits).@"struct".field_names) |field| {
        if (@field(l, field) == 0) return error.InvalidLimit;
    }

    // Hard ceilings are implementation safeguards, not provider capabilities.
    // 中文：以下上限是实现层的安全保护，与提供方能力无关。
    const mib = 1024 * 1024;
    if (l.read_bytes > 16 * mib or l.output_bytes > 16 * mib or
        l.core_bytes > mib or l.index_bytes > 8 * mib or l.shard_bytes > 16 * mib or
        l.max_response_bytes > 64 * mib or l.max_event_bytes > 16 * mib or
        l.max_event_bytes > l.max_response_bytes) return error.InvalidLimit;

    const day_ms = 24 * 60 * 60 * 1000;

    // 超时之间的大小关系与上限：清理宽限不能超过清理总超时，且总超时不超过 60 秒。
    if (l.command_timeout_ms > l.command_max_timeout_ms or l.command_max_timeout_ms > day_ms or
        l.request_timeout_ms > day_ms or l.task_timeout_ms > day_ms or l.cleanup_grace_ms > l.cleanup_timeout_ms or
        l.cleanup_timeout_ms > 60000 or l.max_rounds > 4096 or l.max_tool_calls > 4096) return error.InvalidLimit;

    // 预算检查：输出与安全余量之和必须小于上下文窗口，否则输入预算为负数；摘要预算也不能超过输出上限。
    try validateModel(config.model, l);
    try validateReasoningProtocol(config.provider.base_url, config.model);
    if (config.models.len > 64) return error.TooManyModels;
    for (config.models, 0..) |model, i| {
        try validateModel(model, l);
        try validateReasoningProtocol(config.provider.base_url, model);
        for (config.models[0..i]) |previous| {
            if (std.mem.eql(u8, previous.name, model.name)) return error.DuplicateModel;
        }
    }

    // 压缩目标必须低于触发阈值，且触发阈值必须小于 100%，否则压缩永远无法生效或立即触发。
    if (!(l.compaction_target_percent < l.compaction_trigger_percent and l.compaction_trigger_percent < 100)) return error.InvalidCompactionRatio;
}

test "thinking declarations strict owned config validation and protocol incompatibility" {
    const t = std.testing;
    var parsed = try parse(t.allocator,
        \\{"provider":{"base_url":"https://proxy/v1"},"model":{"name":"custom","context_tokens":32768,"reasoning":{"map":{"off":"disabled","high":"own-wire"}}}}
    );
    defer release(&parsed);
    try t.expectEqualStrings("own-wire", parsed.value.model.reasoning.?.map.high.?);
    try t.expectError(error.MissingField, parse(t.allocator,
        \\{"provider":{"base_url":"https://proxy/v1"},"model":{"name":"custom","context_tokens":32768,"reasoning":{}}}
    ));
    try t.expectError(error.InvalidReasoningMap, parse(t.allocator,
        \\{"provider":{"base_url":"https://proxy/v1"},"model":{"name":"custom","context_tokens":32768,"reasoning":{"map":{}}}}
    ));
    try t.expectError(error.UnknownField, parse(t.allocator,
        \\{"provider":{"base_url":"https://proxy/v1"},"model":{"name":"custom","context_tokens":32768,"reasoning":{"map":{"ultra":"x"}}}}
    ));
    var config = parsed.value;
    config.model.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } };
    config.model.protocol = .responses;
    try t.expectError(error.IncompatibleReasoningProtocol, validate(config));
    config.model.protocol = .auto;
    try validate(config);
    config.provider.base_url = "https://api.deepseek.com";
    config.model = .{ .name = "deepseek-flash", .context_tokens = 32768, .protocol = .responses };
    try t.expectError(error.IncompatibleReasoningProtocol, validate(config));
}

test "Anthropic config is explicit and rejects foreign thinking controls" {
    var parsed = try parse(std.testing.allocator,
        \\{"provider":{"base_url":"https://opencode.ai/inference/go/v1"},"model":{"name":"claude-haiku-5-5","context_tokens":32768,"protocol":"anthropic"}}
    );
    defer release(&parsed);
    try std.testing.expect(parsed.value.model.protocol == .anthropic);
    try validate(parsed.value);
    var config = parsed.value;
    config.model.reasoning_effort = "high";
    try std.testing.expectError(error.UnsupportedAnthropicReasoning, validate(config));
    config.model.reasoning = .{ .format = .anthropic, .map = .{ .off = "disabled", .low = "low", .high = "high" } };
    try validate(config);
    config.model.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } };
    try std.testing.expectError(error.IncompatibleReasoningProtocol, validate(config));
}

fn validateReasoningProtocol(base_url: []const u8, model: Model) !void {
    if ((model.protocol == .responses or model.protocol == .anthropic) and thinking.resolve(base_url, model.name, model.reasoning).format == .deepseek) return error.IncompatibleReasoningProtocol;
}

/// Shared profile validation uses the same limits as the selected model.
pub fn validateModel(model: Model, l: Limits) !void {
    if (!validText(model.name, 1024)) return error.InvalidModel;
    if (model.reasoning_effort) |effort| {
        if (!validText(effort, 128)) return error.InvalidReasoningEffort;
    }
    if (model.reasoning) |declaration| {
        try declaration.validate();
        if ((model.protocol == .responses or model.protocol == .anthropic) and declaration.format == .deepseek) return error.IncompatibleReasoningProtocol;
        if (model.protocol == .anthropic and declaration.format != .anthropic) return error.IncompatibleReasoningProtocol;
        if (model.protocol != .anthropic and declaration.format == .anthropic) return error.IncompatibleReasoningProtocol;
    }
    // An Anthropic effort requires an explicitly verified Anthropic wire map.
    if (model.protocol == .anthropic and model.reasoning_effort != null and model.reasoning == null) return error.UnsupportedAnthropicReasoning;
    const mib = 1024 * 1024;
    if (model.context_tokens == 0 or model.context_tokens > 16 * mib or
        l.max_output_tokens > mib or l.safety_tokens > mib or l.summary_tokens > l.max_output_tokens or
        @as(u64, l.max_output_tokens) + l.safety_tokens >= model.context_tokens) return error.InvalidBudget;
}

/// Reads only the explicit file; never consults environment variables.
/// 中文：只读取调用方明确指定的文件，不读取环境变量；输入缓冲区释放前擦除。
/// 读取时多读一个字节，用来判断文件是否超过上限。
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(Config) {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const bytes = try allocator.alloc(u8, max_config_bytes + 1);
    // 字节缓冲区在解析后即可释放，因为 parse 会把字符串复制到独立的内存中。
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    const n = try file.readPositionalAll(io, bytes, 0);
    if (n > max_config_bytes) return error.ConfigTooLarge;
    return parse(allocator, bytes[0..n]);
}

/// Fixed Linux path, without consulting HOME or XDG environment variables.
/// Caller owns the returned allocation.
/// 中文：固定返回 <home>/.thin/config.json，不读取 XDG 等环境变量；home 必须是合法的绝对路径。
pub fn defaultPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(home) or !validText(home, 4096)) return error.InvalidHome;
    return std.fs.path.join(allocator, &.{ home, ".thin", file_name });
}

/// Caller owns the independent key copy. Errors never include key contents.
/// 中文：返回的 key 是独立副本，调用方负责释放；错误信息中不会包含 key 的内容。
pub fn resolveApiKey(allocator: std.mem.Allocator, config: Config, environ: *const std.process.Environ.Map) ![]u8 {
    try validateKeySource(config.provider);
    if (config.provider.api_key) |key| return allocator.dupe(u8, key);
    if (config.provider.api_key_env.len == 0) {
        // Do not infer key authority from a declared kind or a similar hostname.
        // A proxy must supply an explicit key/env source, not borrow saved keys.
        const id = providers.Id.fromUrl(config.provider.base_url) orelse return error.ApiKeyNotFound;
        try config.credentials.validate();
        const saved = config.credentials.get(id) orelse return error.ApiKeyNotFound;
        return allocator.dupe(u8, saved);
    }
    const key = environ.get(config.provider.api_key_env) orelse return error.ApiKeyNotFound;
    // 拒绝空白或含控制字符的 key，防止 header 注入。
    if (!validText(key, 16384)) return error.InvalidApiKey;
    return allocator.dupe(u8, key);
}

test "named credentials are owned separate and never inferred for another endpoint" {
    const a = std.testing.allocator;
    var parsed = try parse(a,
        \\{"provider":{"base_url":"https://opencode.ai/zen/go/v1"},"model":{"name":"minimax-m2.7","context_tokens":204800,"protocol":"chat"},"credentials":{"deepseek":"fake-deepseek","opencode_zen":"fake-zen","opencode_go":"fake-go"}}
    );
    defer release(&parsed);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for (providers.Id.all) |id| {
        parsed.value.provider.base_url = id.baseUrl();
        const key = try resolveApiKey(a, parsed.value, &env);
        defer {
            std.crypto.secureZero(u8, key);
            a.free(key);
        }
        try std.testing.expectEqualStrings(parsed.value.credentials.get(id).?, key);
        try std.testing.expect(key.ptr != parsed.value.credentials.get(id).?.ptr);
    }
    parsed.value.provider.base_url = "https://example.invalid/v1";
    parsed.value.provider.kind = .opencode_go;
    try std.testing.expectError(error.ApiKeyNotFound, resolveApiKey(a, parsed.value, &env));
    parsed.value.provider.base_url = providers.Id.opencode_go.baseUrl();
    parsed.value.provider.api_key_env = "EXPLICIT_MISSING_KEY";
    try std.testing.expectError(error.ApiKeyNotFound, resolveApiKey(a, parsed.value, &env));
    var invalid = parsed.value;
    invalid.provider.kind = .opencode_zen;
    try std.testing.expectError(error.ProviderEndpointMismatch, validate(invalid));
    invalid.provider.kind = .opencode_go;
    invalid.credentials.opencode_zen = "bad\rkey";
    try std.testing.expectError(error.InvalidApiKey, validate(invalid));
}

/// 测试用的最小合法配置 JSON。
const fixture =
    \\{"provider":{"base_url":"https://example.invalid/v1","api_key_env":"TEST_KEY"},"model":{"name":"test-model","context_tokens":32768}}
;

/// 构造与 fixture 等价的 Config 值，供需要直接修改字段的测试使用。
fn testConfig() Config {
    return .{ .provider = .{ .base_url = "https://example.invalid/v1", .api_key_env = "TEST_KEY" }, .model = .{ .name = "test-model", .context_tokens = 32768 } };
}

// 验证：省略的字段使用默认值，且解析结果不依赖输入缓冲区（释放输入后仍可读）。
test "profiles use shared budgets and exact unique names with a bounded catalog" {
    var config: Config = .{ .provider = .{ .base_url = "http://unused.invalid" }, .model = .{ .name = "a", .context_tokens = 32768 } };
    const profile: Model = .{ .name = "a", .context_tokens = 32768 };
    config.models = &.{profile};
    try validate(config); // Selected name may also appear in the catalog.
    config.models = &.{ profile, profile };
    try std.testing.expectError(error.DuplicateModel, validate(config));
    config.models = &.{.{ .name = "small", .context_tokens = 6144 }};
    try std.testing.expectError(error.InvalidBudget, validate(config));
    var too_many: [65]Model = undefined;
    @memset(&too_many, profile);
    config.models = &too_many;
    try std.testing.expectError(error.TooManyModels, validate(config));
    const a = std.testing.allocator;
    const unknown = "{\"provider\":{\"base_url\":\"http://unused.invalid\"},\"model\":{\"name\":\"a\",\"context_tokens\":32768},\"models\":[{\"name\":\"b\",\"context_tokens\":32768,\"api_key\":\"forbidden\"}]}";
    try std.testing.expectError(error.UnknownField, parse(a, unknown));
}

test "minimal JSON uses defaults and owns strings" {
    const a = std.testing.allocator;
    const input = try a.dupe(u8, fixture);
    const parsed = try parse(a, input);
    defer parsed.deinit();

    // 先覆盖并释放输入，若字符串仍指向输入缓冲区，下面的断言会失败。
    @memset(input, 'x');
    a.free(input);

    try std.testing.expectEqualStrings("test-model", parsed.value.model.name);
    try std.testing.expectEqualStrings("TEST_KEY", parsed.value.provider.api_key_env);
    try std.testing.expectEqual(@as(u32, 300000), parsed.value.limits.command_timeout_ms);
    try std.testing.expectEqual(@as(u32, 65536), parsed.value.limits.read_bytes);
    try std.testing.expectEqual(@as(u32, 32768), parsed.value.limits.output_bytes);
    try std.testing.expectEqual(protocol.Protocol.auto, parsed.value.model.protocol);
}

// 验证：显式指定的协议、推理强度与限额会覆盖默认值，且字符串同样被复制。
test "explicit protocol reasoning and limits overrides own their strings" {
    const a = std.testing.allocator;
    const input = try a.dupe(u8,
        \\{"provider":{"base_url":"http://localhost:8080/v1","api_key_env":"KEY"},"model":{"name":"custom","context_tokens":65536,"protocol":"responses","reasoning_effort":"high"},"limits":{"max_rounds":10}}
    );
    const parsed = try parse(a, input);
    defer parsed.deinit();
    @memset(input, 'x');
    a.free(input);

    try std.testing.expectEqual(protocol.Protocol.responses, parsed.value.model.protocol);
    try std.testing.expectEqualStrings("high", parsed.value.model.reasoning_effort.?);
    try std.testing.expectEqual(@as(u16, 10), parsed.value.limits.max_rounds);
}

// 验证：缺失字段、未知字段、重复字段以及 TOML 格式都会被拒绝。
test "strict JSON rejects missing unknown duplicate and TOML fields" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingField, parse(a, "{}"));
    try std.testing.expectError(error.MissingField, parse(a, "{\"provider\":{}}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"unknown\":1}"));

    // 内联 key 合法，但仍不能省略基础 URL 与模型。
    try std.testing.expectError(error.MissingField, parse(a, "{\"provider\":{\"api_key\":\"fake-key\"}}"));
    try std.testing.expectError(error.DuplicateField, parse(a, "{\"provider\":{\"base_url\":\"x\",\"base_url\":\"y\"}}"));
    try std.testing.expectError(error.UnexpectedToken, parse(a, "[provider]\nbase_url = 'https://example.invalid'"));
}

// 验证：各种非法 URL 与含控制字符的 env 名、模型名都会被拒绝。
test "reject invalid URL and header injection" {
    var c = testConfig();
    for ([_][]const u8{ "", "ftp://host", "https:///v1", "https://u:p@host/v1", "https://host?key=x", "https://host#x", "https://host\r\nX: y", "https://host/%0d%0a", "https://host\\evil", "https://host:0", "https://ho%40st", "https://host/%xx" }) |url| {
        c.provider.base_url = url;
        try std.testing.expectError(error.InvalidBaseUrl, validate(c));
    }

    c = testConfig();
    c.provider.api_key_env = "KEY\r\nX";
    try std.testing.expectError(error.InvalidApiKeyEnv, validate(c));

    c = testConfig();
    c.model.name = "\r\n";
    try std.testing.expectError(error.InvalidModel, validate(c));
    c.model.name = "";
    try std.testing.expectError(error.InvalidModel, validate(c));
}

// 验证：预算、压缩比例与各项限额的边界都会被检查。
test "budget ratios and bounded limits" {
    var c = testConfig();
    // 窗口太小，无法容纳输出与安全余量。
    c.model.context_tokens = 6144;
    try std.testing.expectError(error.InvalidBudget, validate(c));

    c = testConfig();
    // 摘要预算超过输出上限。
    c.limits.summary_tokens = 4097;
    try std.testing.expectError(error.InvalidBudget, validate(c));
    c = testConfig();

    // 压缩目标不能不低于触发阈值。
    c.limits.compaction_target_percent = 80;
    try std.testing.expectError(error.InvalidCompactionRatio, validate(c));
    c = testConfig();
    c.limits.compaction_trigger_percent = 100;
    try std.testing.expectError(error.InvalidCompactionRatio, validate(c));

    // 任何字段设为 0 都必须报错。
    inline for (@typeInfo(Limits).@"struct".field_names) |field| {
        c = testConfig();
        @field(c.limits, field) = 0;
        try std.testing.expectError(error.InvalidLimit, validate(c));
    }

    // 超过硬上限的大小字段必须报错。
    inline for (.{ "core_bytes", "index_bytes", "read_bytes", "shard_bytes", "max_response_bytes" }) |field| {
        c = testConfig();
        @field(c.limits, field) = std.math.maxInt(u32);
        try std.testing.expectError(error.InvalidLimit, validate(c));
    }
    c = testConfig();

    c.limits.command_timeout_ms = c.limits.command_max_timeout_ms + 1;
    try std.testing.expectError(error.InvalidLimit, validate(c));
}

// 验证：load 返回的数据不依赖已删除的文件，且严格执行 64 KiB 上限（恰好等于上限可以通过）。
test "load owns data after file removal and enforces 64 KiB" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = fixture });
    const path = try tmp.dir.realPathFileAlloc(io, file_name, a);
    defer a.free(path);
    const parsed = try load(a, io, path);
    defer parsed.deinit();

    // 删除文件后，已解析的字符串仍然有效，说明数据已被复制。
    try tmp.dir.deleteFile(io, file_name);
    try std.testing.expectEqualStrings("https://example.invalid/v1", parsed.value.provider.base_url);
    try std.testing.expectEqualStrings("test-model", parsed.value.model.name);

    // 超过 64 KiB 一个字节，应当被拒绝。
    const oversized = try a.alloc(u8, max_config_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    @memcpy(oversized[0..fixture.len], fixture);
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = oversized });
    try std.testing.expectError(error.ConfigTooLarge, load(a, io, path));

    // 恰好 64 KiB 的文件应当可以正常加载（前面是合法 JSON，后面用空白补齐）。
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = oversized[0..max_config_bytes] });
    const exact = try load(a, io, path);
    defer exact.deinit();
}

// 验证：使用假的环境变量表时，key 返回独立副本；空白或含控制字符的 key 被拒绝，且错误不泄露内容。
test "fake environment returns independent key and credential-free errors" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const c = testConfig();
    try std.testing.expectError(error.ApiKeyNotFound, resolveApiKey(a, c, &env));

    for ([_][]const u8{ "", "   ", "secret\r\nAuthorization: x", "secret\x00" }) |bad| {
        try env.put("TEST_KEY", bad);
        try std.testing.expectError(error.InvalidApiKey, resolveApiKey(a, c, &env));
    }

    try env.put("TEST_KEY", "fake-secret");
    const key = try resolveApiKey(a, c, &env);
    defer a.free(key);

    // 修改环境变量后，已返回的 key 副本不应受影响。
    try env.put("TEST_KEY", "replacement");
    try std.testing.expectEqualStrings("fake-secret", key);
}

// 验证：默认路径只使用传入的 home，且拒绝空 home。
test "fixed default path uses supplied home only" {
    const path = try defaultPath(std.testing.allocator, "/fake-home");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/fake-home/.thin/config.json", path);
    try std.testing.expectError(error.InvalidHome, defaultPath(std.testing.allocator, ""));
}

// 密钥来源独立校验：未配置可加载；内联返回副本；两个来源不能同时出现。
test "inline missing ambiguous and invalid API key sources" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var c = testConfig();
    c.provider.api_key_env = "";
    try validate(c);
    try std.testing.expectError(error.ApiKeyNotFound, resolveApiKey(a, c, &env));
    c.provider.api_key = "fake-inline";
    try validate(c);
    const key = try resolveApiKey(a, c, &env);
    defer {
        std.crypto.secureZero(u8, key);
        a.free(key);
    }
    try std.testing.expectEqualStrings("fake-inline", key);
    try std.testing.expect(key.ptr != c.provider.api_key.?.ptr);
    c.provider.api_key_env = "TEST_KEY";
    try std.testing.expectError(error.AmbiguousApiKey, validate(c));
    try std.testing.expectError(error.AmbiguousApiKey, resolveApiKey(a, c, &env));
    c.provider.api_key_env = "";
    for ([_][]const u8{ "", " ", "fake\r\n", "fake\x00", "fake\x7f" }) |bad| {
        c.provider.api_key = bad;
        try std.testing.expectError(error.InvalidApiKey, validate(c));
        try std.testing.expectError(error.InvalidApiKey, resolveApiKey(a, c, &env));
    }
    const big = try a.alloc(u8, 16385);
    defer a.free(big);
    @memset(big, 'f');
    c.provider.api_key = big;
    try std.testing.expectError(error.InvalidApiKey, validate(c));
    c.provider.api_key = big[0..16384];
    try validate(c);
}

// 包装分配器在语法失败、语义失败、正常 release 三条路径上都负责擦除。
test "credential parser cleanup and release zero owned allocations" {
    const Observer = struct {
        backing: std.mem.Allocator,
        dirty_free: bool = false,
        frees: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = WipingAllocator.resize, .remap = WipingAllocator.remap, .free = free } };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawAlloc(len, alignment, ra);
        }

        fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (bytes) |byte| if (byte != 0) {
                self.dirty_free = true;
                break;
            };
            self.frees += 1;
            self.backing.rawFree(bytes, alignment, ra);
        }
    };
    var observer = Observer{ .backing = std.testing.allocator };
    const inline_json =
        \\{"provider":{"base_url":"https://example.invalid","api_key":"fake-inline"},"model":{"name":"test","context_tokens":32768}}
    ;
    var parsed = try parse(observer.allocator(), inline_json);
    try std.testing.expectEqualStrings("fake-inline", parsed.value.provider.api_key.?);
    release(&parsed);
    try std.testing.expectError(error.UnknownField, parse(observer.allocator(),
        \\{"provider":{"base_url":"https://example.invalid","api_key":"fake-inline","unknown":1}}
    ));
    try std.testing.expectError(error.InvalidApiKey, parse(observer.allocator(),
        \\{"provider":{"base_url":"https://example.invalid","api_key":"fake\ninline"},"model":{"name":"test","context_tokens":32768}}
    ));
    try std.testing.expect(observer.frees > 0);
    try std.testing.expect(!observer.dirty_free);
}
