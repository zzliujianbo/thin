//! 配置层：解析并校验 config.json（严格 JSON，拒绝未知与重复字段），检查 URL、限额与预算，
//! API key 可内联保存或从环境变量读取；解析结果通过 release 擦除后释放。

const std = @import("std");
const protocol = @import("protocol.zig");
const thinking = @import("thinking.zig");
pub const providers = @import("providers.zig");

/// 单一配置文件名；路径构造、交互存储和文件工具保护共用，避免名称漂移。
pub const file_name = "config.json";
test {
    _ = @import("llm_config_test.zig");
}

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

pub const ReasoningSource = enum { explicit, metadata };

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
    /// Explicit or fetched capability/wire map, owned by the parse arena.
    reasoning: ?thinking.Declaration = null,
    /// Missing in old configs means explicit: do not guess whether a user wrote it.
    reasoning_source: ReasoningSource = .explicit,
    /// Known output capability, not a user request cap. Null means unknown.
    output_tokens: ?u32 = null,
    output_source: ReasoningSource = .explicit,
    /// Exact compatible price-step metadata; never a user declaration or window.
    input_price_threshold: ?u32 = null,
    /// Verified range with no context-length price increase; null is unknown.
    /// This is not a price step or a guarantee about time/cache-based prices.
    input_price_flat_limit: ?u32 = null,

    /// Derived maps/output limits and wire effort live in cache, not config
    /// declarations. The global logical preference is stored separately in Registry.
    /// This prevents a fetched profile becoming an explicit override.
    pub fn persisted(self: Model) Model {
        var result = self;
        result.input_price_threshold = null;
        result.input_price_flat_limit = null;
        if (self.output_source == .metadata) result.output_tokens = null;
        if (self.reasoning_source == .metadata) {
            result.reasoning = null;
            result.reasoning_effort = null;
        }
        return result;
    }
};

/// Implementation defaults are adjustable; only the agreed timeout, read/output
/// sizes and compaction percentages are product requirements.
/// 中文：下面的默认值是实现层的可调参数；只有超时、读取/输出大小与压缩百分比是产品需求。
/// 所有显式数值在校验时都不能为 0（见 validate）；max_rounds 可为 null。
pub const Limits = struct {
    /// 单条命令的默认超时（毫秒）。
    command_timeout_ms: u32 = 300000,
    /// 单条命令允许的最大超时（毫秒），命令超时不能超过它。
    command_max_timeout_ms: u32 = 3600000,
    /// 单次文件读取的字节上限。
    read_bytes: u32 = 65536,
    /// 单次工具输出的字节上限。
    output_bytes: u32 = 32768,
    /// Optional estimated-input ceiling, independent of the real model window.
    max_input_tokens: ?u32 = null,
    /// Enabled by default; explicit false opts out of the first known price step.
    /// Unknown metadata fails closed before any inference, never guesses 100K.
    low_price_input: bool = true,
    /// Additional headroom below an enabled input ceiling. Estimates are NOT
    /// an authoritative tokenizer or a guarantee about provider billing.
    input_margin_tokens: u32 = 5000,
    /// 预留的安全余量 token 数，从输入预算中扣除。
    safety_tokens: u32 = 4096,
    /// Model turns per user submission; missing/null means unlimited.
    /// Explicit positive values retain their limit, including legacy 50.
    /// Compaction is not counted. Independent safety limits still apply.
    max_rounds: ?u16 = null,
    /// 单个任务允许的最大工具调用次数。
    max_tool_calls: u16 = 128,
    /// 整个任务的超时（毫秒）。
    task_timeout_ms: u32 = 1800000,
    /// 单次模型请求的超时（毫秒）。
    request_timeout_ms: u32 = 300000,
    /// Successful model metadata remains fresh for four hours; failures and
    /// in-flight claims wait five minutes before another automatic attempt.
    model_refresh_ttl_ms: u32 = 14400000,
    model_refresh_cooldown_ms: u32 = 300000,
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
    /// Disable only automatic compaction; manual /compact and hard preflight remain.
    compaction_enabled: bool = true,
    /// 触发压缩的上下文占用百分比。
    compaction_trigger_percent: u8 = 80,
    /// 压缩后希望达到的上下文占用百分比（必须小于触发阈值）。
    compaction_target_percent: u8 = 50,
    /// 单次模型响应的最大字节数。
    max_response_bytes: u32 = 8388608,
    /// 单个流式事件的最大字节数（不能超过 max_response_bytes）。
    max_event_bytes: u32 = 1048576,
};

/// Sparse user declarations under llm.providers.<alias>.models.<raw-id>.
pub const ModelPatch = struct {
    protocol: ?protocol.Protocol = null,
    context_tokens: ?u32 = null,
    output_tokens: ?u32 = null,
    reasoning_effort: ?[]const u8 = null,
    reasoning: ?thinking.Declaration = null,

    pub fn apply(self: ModelPatch, base: Model) Model {
        var result = base;
        if (self.protocol) |v| result.protocol = v;
        if (self.context_tokens) |v| result.context_tokens = v;
        if (self.output_tokens) |v| {
            result.output_tokens = v;
            result.output_source = .explicit;
        }
        if (self.reasoning_effort) |v| result.reasoning_effort = v;
        if (self.reasoning) |v| {
            result.reasoning = v;
            result.reasoning_source = .explicit;
        }
        return result;
    }
};
pub const NamedModel = struct { name: []const u8, patch: ModelPatch };
pub const NamedProvider = struct {
    name: []const u8,
    connection: Provider,
    models: []const NamedModel = &.{},
    pub fn patchFor(self: NamedProvider, rawid: []const u8) ?ModelPatch {
        for (self.models) |m| if (std.mem.eql(u8, m.name, rawid)) return m.patch;
        return null;
    }
};
pub const Registry = struct {
    default: []const u8,
    /// Global logical preference for empty sessions, never capability/wire authority.
    /// Null preserves legacy fallback to existing model options or medium.
    reasoning_effort: ?[]const u8 = null,
    providers: []const NamedProvider,
    pub fn find(self: Registry, name: []const u8) ?NamedProvider {
        for (self.providers) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};
pub const DefaultSelection = struct { provider: []const u8, model: []const u8 };
pub fn splitDefault(value: []const u8) !DefaultSelection {
    const slash = std.mem.findScalar(u8, value, '/') orelse return error.InvalidDefault;
    const result: DefaultSelection = .{ .provider = value[0..slash], .model = value[slash + 1 ..] };
    if (!validAlias(result.provider) or !validText(result.model, 1024)) return error.InvalidDefault;
    return result;
}
fn validAlias(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |c| if (c <= 0x20 or c >= 0x7f or c == '/' or c == '\\') return false;
    return true;
}

/// Allocator-owned URL bytes; caller must free with the allocator passed to url.
pub const OwnedURL = []u8;

/// Explicit HTTP forward proxy, independent of provider endpoints and model scope.
/// HTTP only, not SOCKS and not an API URL. Address is an unbracketed DNS/IP
/// host, never a URL or credentials; port is separate.
pub const ProxyConfig = struct {
    address: []const u8,
    port: u16,
    models: []const []const u8 = &.{},

    /// Caller owns the returned URL. Validate even for in-memory callers.
    pub fn url(self: ProxyConfig, a: std.mem.Allocator) !OwnedURL {
        try validateProxyAddress(self.address);
        if (self.port == 0) return error.InvalidProxyPort;
        if (std.mem.findScalar(u8, self.address, ':') != null)
            return std.fmt.allocPrint(a, "http://[{s}]:{d}", .{ self.address, self.port });
        return std.fmt.allocPrint(a, "http://{s}:{d}", .{ self.address, self.port });
    }
};

fn validateProxyAddress(address: []const u8) !void {
    if (address.len == 0 or address.len > 253) return error.InvalidProxyAddress;
    if (std.mem.findScalar(u8, address, ':') != null) {
        // No zone identifiers, brackets, credentials or URI escapes.
        for (address) |c| if (!std.ascii.isHex(c) and c != ':' and c != '.') return error.InvalidProxyAddress;
        _ = std.Io.net.IpAddress.parse(address, 1) catch return error.InvalidProxyAddress;
        return;
    }
    const dns = if (address[address.len - 1] == '.') address[0 .. address.len - 1] else address;
    var labels = std.mem.splitScalar(u8, dns, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return error.InvalidProxyAddress;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidProxyAddress;
    }
}

fn validateProxy(proxy: ProxyConfig, registry: ?Registry) !void {
    try validateProxyAddress(proxy.address);
    if (proxy.port == 0) return error.InvalidProxyPort;
    if (proxy.models.len > 128) return error.TooManyProxyModels;
    for (proxy.models, 0..) |name, i| {
        const selection = splitDefault(name) catch return error.InvalidProxyModel;
        for (name) |c| if (c == '*' or c == '?' or c == '[' or c == ']') return error.InvalidProxyModel;
        for (proxy.models[0..i]) |previous| if (std.mem.eql(u8, name, previous)) return error.DuplicateProxyModel;
        if (registry) |r| if (r.find(selection.provider) == null) return error.UnknownProvider;
    }
}

/// Optional global auxiliary model; never a chat selection or capability source.
pub const DecisionConfig = struct {
    model: []const u8,
    enabled: bool = true,
    /// Generative protocols only; SystemOne has no max_tokens/message context API.
    max_input_tokens: u32 = 8192,
    /// Local SystemOne state bound, not a claim about supplier context capacity.
    max_state_bytes: u32 = 16384,

    /// Shared by generic auxiliary resolution and its local model picker.
    /// Never use primary price policy or command limits to resolve a reviewer.
    pub fn modelLimits(self: DecisionConfig, shared_request_timeout_ms: u32) Limits {
        return .{
            .low_price_input = false,
            .input_margin_tokens = 1,
            .safety_tokens = 256,
            .max_input_tokens = self.max_input_tokens,
            .request_timeout_ms = shared_request_timeout_ms,
            .max_response_bytes = 128 * 1024,
            .max_event_bytes = 64 * 1024,
        };
    }
};

/// Independent text-only image helper selection; no credentials or transport policy.
pub const ImageConfig = struct {
    /// Presence is the only activation state. Off clears the selection.
    model: ?[]const u8 = null,
};

pub const MemoryConfig = struct {
    auto: bool = true,
};

/// Owned application configuration. Disk input requires llm declarations;
/// registry may be absent only for a pure in-memory Runtime snapshot.
pub const Config = struct {
    proxy: ?ProxyConfig = null,
    decision: ?DecisionConfig = null,
    image: ImageConfig = .{},
    memory: MemoryConfig = .{},
    registry: ?Registry = null,
    selected_provider: ?[]const u8 = null,
    selection_pending: bool = false,
    provider: Provider,
    model: Model,
    /// 未配置时使用 Limits 中的默认值。
    limits: Limits = .{},

    pub fn imageActive(self: Config) bool {
        return self.image.model != null;
    }

    pub fn decisionActive(self: Config) bool {
        const decision = self.decision orelse return false;
        return decision.enabled;
    }

    /// Exact alias/raw-ID allowlist; absent identity or an empty list is direct.
    /// Returned slices borrow this Config's lifetime.
    pub fn proxyFor(self: Config, provider_alias: ?[]const u8, raw_id: []const u8) ?ProxyConfig {
        const alias = provider_alias orelse return null;
        const proxy = self.proxy orelse return null;
        for (proxy.models) |name| {
            const selection = splitDefault(name) catch continue;
            if (std.mem.eql(u8, selection.provider, alias) and std.mem.eql(u8, selection.model, raw_id)) return proxy;
        }
        return null;
    }
};

/// 配置文件的大小上限（64 KiB），超过则直接拒绝，防止占用过多内存。
pub const max_config_bytes = 64 * 1024;

/// Every string is owned by the returned arena, never by `bytes`.
/// 中文：解析后的字符串复制到 allocator 中，因此调用方可以擦除 bytes；结果需调用 release 释放。
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Config) {
    return parseBounded(allocator, bytes, max_config_bytes, true, false);
}

// No secret is needed to select an image helper; provider credentials are
// resolved separately at use time, never borrowed from decision/primary state.
const image_test_prefix = "{\"llm\":{\"default\":\"p/main\",\"providers\":{\"p\":{\"base_url\":\"https://fixture.invalid\"}}}";

fn imageAllocationCase(a: std.mem.Allocator) !void {
    inline for (.{ "", ",\"image\":{}", ",\"image\":{\"model\":null}", ",\"image\":{\"model\":\"p/deepseek-flash\"}" }, 0..) |suffix, index| {
        var parsed = try parse(a, image_test_prefix ++ suffix ++ "}");
        defer release(&parsed);
        try std.testing.expectEqual(index == 3, parsed.value.imageActive());
        try std.testing.expect(parsed.value.decision == null);
        try std.testing.expectEqual(index >= 3, parsed.value.image.model != null);
        var copied = try clone(a, parsed.value);
        defer release(&copied);
        if (parsed.value.image.model) |model| {
            try std.testing.expectEqualStrings("p/deepseek-flash", copied.value.image.model.?);
            try std.testing.expect(model.ptr != copied.value.image.model.?.ptr);
        }
        var wiping = WipingAllocator{ .backing = a };
        var out: std.Io.Writer.Allocating = .init(wiping.allocator());
        defer out.deinit();
        writeDisk(copied.value, &out.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        try std.testing.expectEqual(index == 3, std.mem.find(u8, out.written(), "\"image\"") != null);
        var tree = try std.json.parseFromSlice(std.json.Value, wiping.allocator(), out.written(), .{});
        defer tree.deinit();
        if (tree.value.object.get("image")) |value| {
            try std.testing.expectEqual(@as(usize, 1), value.object.count());
            try std.testing.expect(value.object.contains("model"));
        }
        var again = try parse(a, out.written());
        defer release(&again);
        try std.testing.expectEqualDeep(parsed.value.image, again.value.image);
        try std.testing.expectEqualDeep(parsed.value.limits, again.value.limits);
    }
}

fn rejectedImageAllocationCase(a: std.mem.Allocator) !void {
    inline for (.{
        "null",                                   "true",                                 "[]",                                                          "\"Off\"",
        "{\"enabled\":true}",                     "{\"enabled\":true,\"model\":null}",    "{\"model\":\"deepseek-flash\"}",                              "{\"model\":\"/deepseek-flash\"}",
        "{\"model\":\"missing/deepseek-flash\"}", "{\"model\":\"p/\"}",                   "{\"model\":\"p/deepseek-chat\"}",                             "{\"model\":\"p/deepseek-flash-preview\"}",
        "{\"model\":\"p/org/deepseek-flash\"}",   "{\"model\":\"p/DeepSeek-Flash\"}",     "{\"model\":\" p/deepseek-flash\"}",                           "{\"model\":\"p/deepseek-flash \"}",
        "{\"model\":42}",                         "{\"model\":true}",                     "{\"model\":[]}",                                              "{\"model\":{}}",
        "{\"enabled\":null}",                     "{\"enabled\":1}",                      "{\"enabled\":\"false\"}",                                     "{\"enabled\":false,\"enabled\":false}",
        "{\"model\":null,\"model\":null}",        "{\"enabled\":false,\"api_key\":null}", "{\"enabled\":true,\"model\":\"p/deepseek-flash\",\"url\":1}", "{\"request_timeout_ms\":1}",
        "{\"trust\":false}",                      "{\"unknown\":{}}",
    }) |bad| {
        if (parse(a, image_test_prefix ++ ",\"image\":" ++ bad ++ "}")) |value| {
            var parsed = value;
            release(&parsed);
            return error.ExpectedImageRejection;
        } else |err| if (err == error.OutOfMemory) return err;
    }
    if (parse(a, image_test_prefix ++ ",\"image\":{},\"image\":{}}")) |value| {
        var parsed = value;
        release(&parsed);
        return error.ExpectedImageRejection;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.DuplicateField, err);
    }
}

test "image defaults sparse disk exact selection owned clone and roundtrip" {
    try imageAllocationCase(std.testing.allocator);
}

test "image retired enabled is rejected regardless of value" {
    inline for (.{ "true", "false", "null", "0", "\"false\"" }) |value| {
        if (parse(std.testing.allocator, image_test_prefix ++
            ",\"image\":{\"model\":\"p/deepseek-flash\",\"enabled\":" ++ value ++ "}}")) |parsed_value|
        {
            var parsed = parsed_value;
            release(&parsed);
            return error.ExpectedEnabledRejection;
        } else |err| try std.testing.expectEqual(error.UnknownField, err);
    }
}

test "image rejects invalid owner model types duplicates and unknown fields" {
    try rejectedImageAllocationCase(std.testing.allocator);
}

const decision_fixture =
    \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://127.0.0.1:1/v1","api_key":"fake-inline","models":{"main":{"protocol":"chat","context_tokens":32768},"org/reviewer":{"protocol":"systemone"}}}}},"limits":{"request_timeout_ms":123456},"decision":{"model":"p/org/reviewer","enabled":true,"max_input_tokens":8192,"max_state_bytes":16384}}
;

fn decisionAllocationCase(a: std.mem.Allocator) !void {
    var parsed = try parse(a, decision_fixture);
    defer release(&parsed);
    try std.testing.expectEqual(protocol.Protocol.systemone, parsed.value.registry.?.find("p").?.patchFor("org/reviewer").?.protocol.?);
    var copied = try clone(a, parsed.value);
    defer release(&copied);
    copied.value.provider.base_url = "";
    copied.value.selection_pending = true;
    var pending = try clonePendingSettings(a, copied.value);
    defer release(&pending);
    try std.testing.expect(pending.value.selection_pending);
    try std.testing.expectEqualStrings("", pending.value.provider.base_url);
    try std.testing.expectEqual(@as(u32, 123456), pending.value.decision.?.modelLimits(pending.value.limits.request_timeout_ms).request_timeout_ms);
    try std.testing.expectEqual(protocol.Protocol.chat, pending.value.registry.?.find("p").?.patchFor("main").?.protocol.?);
    try std.testing.expectEqualStrings("fake-inline", pending.value.provider.api_key.?);
    var wiping = WipingAllocator{ .backing = a };
    var out: std.Io.Writer.Allocating = .init(wiping.allocator());
    defer out.deinit();
    // This allocating writer maps allocation failures to WriteFailed.
    // Expose OOM to the exhaustive test harness without changing production.
    writeDisk(parsed.value, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    var again = try parse(a, out.written());
    defer release(&again);
    try std.testing.expectEqual(protocol.Protocol.systemone, again.value.registry.?.find("p").?.patchFor("org/reviewer").?.protocol.?);
    try std.testing.expectEqual(@as(u32, 123456), again.value.limits.request_timeout_ms);
}

test "explicit decision protocol round trips with shared timeout" {
    try decisionAllocationCase(std.testing.allocator);
    var parsed = try parse(std.testing.allocator, decision_fixture);
    defer release(&parsed);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeDisk(parsed.value, &out.writer);
    var tree = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer tree.deinit();
    const decision = tree.value.object.get("decision").?.object;
    try std.testing.expect(decision.get("backend") == null);
    try std.testing.expect(decision.get("request_timeout_ms") == null);
    try std.testing.expectEqual(@as(usize, 4), decision.count());
    var again = try parse(std.testing.allocator, out.written());
    defer release(&again);
    try std.testing.expectEqual(protocol.Protocol.systemone, again.value.registry.?.find("p").?.patchFor("org/reviewer").?.protocol.?);
}

test "decision declarations and owned pending clones are allocation failure safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decisionAllocationCase, .{});
}

const decision_test_prefix = "{\"llm\":{\"default\":\"p/m\",\"providers\":{\"p\":{\"base_url\":\"https://fixture.invalid/v1\",\"api_key\":\"fake-inline\",\"models\":{\"m\":{\"protocol\":\"chat\",\"context_tokens\":32768}}}}},\"decision\":";

fn expectUnknownDecisionField(a: std.mem.Allocator, raw: []const u8) !void {
    var parsed = parse(a, raw) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.UnknownField, err);
        return;
    };
    defer release(&parsed);
    return error.TestExpectedError;
}

fn rejectedDecisionAllocationCase(a: std.mem.Allocator) !void {
    for ([_]bool{ true, false }) |enabled| {
        for ([_][]const u8{ "\"model\"", "\"systemone\"", "\"other\"", "null", "17", "1.5" }) |backend| {
            const raw = try std.fmt.allocPrint(std.testing.allocator, "{s}{{\"model\":\"p/m\",\"enabled\":{},\"backend\":{s}}}}}", .{ decision_test_prefix, enabled, backend });
            defer std.testing.allocator.free(raw);
            try expectUnknownDecisionField(a, raw);
        }
        for ([_][]const u8{ "1", "17", "0", "-1", "3600001", "\"1\"", "null", "true", "1.5", "1e100" }) |timeout| {
            const raw = try std.fmt.allocPrint(std.testing.allocator, "{s}{{\"model\":\"p/m\",\"enabled\":{},\"request_timeout_ms\":{s}}}}}", .{ decision_test_prefix, enabled, timeout });
            defer std.testing.allocator.free(raw);
            try expectUnknownDecisionField(a, raw);
        }
    }
}

test "decision rejects removed fields even when disabled without protocol migration" {
    try rejectedDecisionAllocationCase(std.testing.allocator);
    const a = std.testing.allocator;
    const cases = .{
        .{ "{\"model\":\"p/m\",\"unknown\":1}", error.UnknownField },
        .{ "{\"model\":\"p/m\",\"model\":\"p/m\"}", error.DuplicateField },
        .{ "{\"model\":\"p/m\",\"backend\":\"model\",\"backend\":\"systemone\"}", error.DuplicateField },
        .{ "{\"model\":\"p/m\",\"request_timeout_ms\":1,\"request_timeout_ms\":2}", error.DuplicateField },
        .{ "{\"model\":\"p/m\",\"max_state_bytes\":1.5}", error.InvalidNumber },
    };
    inline for (cases) |case| {
        const raw = try std.mem.concat(a, u8, &.{ decision_test_prefix, case[0], "}" });
        defer a.free(raw);
        try std.testing.expectError(case[1], parse(a, raw));
    }
    var parsed = try parse(a, decision_test_prefix ++ "{\"model\":\"p/m\"}}");
    defer release(&parsed);
    try std.testing.expectEqual(protocol.Protocol.chat, parsed.value.registry.?.find("p").?.patchFor("m").?.protocol.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.registry.?.find("p").?.models.len);
}

test "SystemOne has no required generative window but retains field and budget safety" {
    var model: Model = .{ .name = "reviewer", .protocol = .systemone, .context_tokens = 0 };
    try validateModel(model, .{});
    model.reasoning_effort = "off";
    try std.testing.expectError(error.IncompatibleReasoningProtocol, validateModel(model, .{}));
    model.reasoning_effort = null;
    model.reasoning = .{ .map = .{ .high = "high" } };
    try std.testing.expectError(error.IncompatibleReasoningProtocol, validateModel(model, .{}));
    model.reasoning = null;
    model.output_tokens = 0;
    try std.testing.expectError(error.InvalidBudget, validateModel(model, .{}));
    model.output_tokens = null;
    model.context_tokens = 16 * 1024 * 1024 + 1;
    try std.testing.expectError(error.InvalidBudget, validateModel(model, .{}));
    model.context_tokens = 0;
    model.protocol = .chat;
    try std.testing.expectError(error.InvalidBudget, validateModel(model, .{}));
}

test "runtime-only config clones retain derived maps but cannot write disk" {
    var active = testConfig();
    active.model.reasoning = .{ .map = .{ .high = "high" } };
    active.model.reasoning_effort = "high";
    active.model.reasoning_source = .metadata;
    active.model.input_price_threshold = 100000;
    var copied = try clone(std.testing.allocator, active);
    defer release(&copied);
    try std.testing.expectEqualStrings("high", copied.value.model.reasoning.?.map.high.?);
    try std.testing.expectEqualStrings("high", copied.value.model.reasoning_effort.?);
    try std.testing.expectEqual(@as(?u32, 100000), copied.value.model.input_price_threshold);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.MissingRegistry, writeDisk(copied.value, &out.writer));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

/// Clone an already bounded, validated application configuration. Re-encoding
/// default fields may exceed the input-file limit; it does not relax disk reads.
pub fn clone(allocator: std.mem.Allocator, config: Config) !std.json.Parsed(Config) {
    return cloneConfig(allocator, config, false);
}

/// Own a display-only missing-route selection while editing global preferences.
/// Never use this instead of clone()/validate() to activate or send a request.
pub fn clonePendingSettings(allocator: std.mem.Allocator, config: Config) !std.json.Parsed(Config) {
    return cloneConfig(allocator, config, true);
}

fn cloneConfig(allocator: std.mem.Allocator, config: Config, comptime unresolved: bool) !std.json.Parsed(Config) {
    if (config.provider.base_url.len > max_config_bytes) return error.ConfigTooLarge;
    if (unresolved) try validatePendingSettings(config) else try validate(config);
    var wiping = WipingAllocator{ .backing = allocator };
    const bytes = try std.json.Stringify.valueAlloc(wiping.allocator(), config, .{ .emit_null_optional_fields = false });
    // Allocator.free poisons memory before calling rawFree in safety builds.
    // Keep the wiping wrapper at the final free boundary, just as for the
    // stringify writer's intermediate buffers and the parsed arena's release.
    defer wiping.allocator().free(bytes);
    return parseBounded(allocator, bytes, 512 * 1024, false, unresolved);
}

fn parseBounded(allocator: std.mem.Allocator, bytes: []const u8, limit: usize, disk: bool, comptime unresolved: bool) !std.json.Parsed(Config) {
    if (bytes.len > limit) return error.ConfigTooLarge;

    if (disk) return parseDisk(allocator, bytes);

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
    if (unresolved) try validatePendingSettings(parsed.value) else try validate(parsed.value);
    return parsed;
}

const json_options: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" };

fn decode(comptime T: type, a: std.mem.Allocator, value: std.json.Value) !T {
    if (T == ModelPatch or T == Limits or T == DecisionConfig or T == ImageConfig or T == ProxyConfig) {
        const fields = try object(value);
        if (T == DecisionConfig) _ = try string(fields.get("model") orelse return error.MissingField);
        if (T == ImageConfig) {
            if (fields.get("model")) |model| if (model != .null) {
                _ = try string(model);
            };
        }
        var it = fields.iterator();
        while (it.next()) |entry| {
            // Reject unknown decision keys regardless of the value's type.
            // No removed field is interpreted or imported into declarations.
            if (T == DecisionConfig or T == ImageConfig) {
                const known = inline for (@typeInfo(T).@"struct".field_names) |field| {
                    if (std.mem.eql(u8, entry.key_ptr.*, field)) break true;
                } else false;
                if (!known) return error.UnknownField;
            }
            if (entry.value_ptr.* == .float or entry.value_ptr.* == .number_string) return error.InvalidNumber;
            inline for (@typeInfo(T).@"struct".field_names) |field| {
                if (std.mem.eql(u8, entry.key_ptr.*, field)) {
                    const F = @FieldType(T, field);
                    const optional = @typeInfo(F) == .optional;
                    const Base = if (optional) @typeInfo(F).optional.child else F;
                    if (comptime @typeInfo(Base) == .int) {
                        if (entry.value_ptr.* != .integer and !(optional and entry.value_ptr.* == .null)) return error.InvalidNumber;
                    } else if (comptime @typeInfo(Base) == .bool) {
                        if (entry.value_ptr.* != .bool and !(optional and entry.value_ptr.* == .null)) return error.UnexpectedToken;
                    }
                }
            }
        }
    }
    return std.json.parseFromValueLeaky(T, a, value, json_options);
}
fn object(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.UnexpectedToken;
    return value.object;
}
fn string(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.UnexpectedToken;
    return value.string;
}

fn parseDisk(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Config) {
    const trimmed = std.mem.trimStart(u8, bytes, " \t\r\n");
    if (trimmed.len != 0 and trimmed[0] != '{') return error.UnexpectedToken;
    var wiping = WipingAllocator{ .backing = allocator };
    var tree = try std.json.parseFromSlice(std.json.Value, wiping.allocator(), bytes, json_options);
    errdefer tree.deinit();
    const a = tree.arena.allocator();
    const root = try object(tree.value);
    var keys = root.iterator();
    while (keys.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "llm") and !std.mem.eql(u8, entry.key_ptr.*, "limits") and !std.mem.eql(u8, entry.key_ptr.*, "decision") and !std.mem.eql(u8, entry.key_ptr.*, "proxy") and !std.mem.eql(u8, entry.key_ptr.*, "image") and !std.mem.eql(u8, entry.key_ptr.*, "memory")) return error.UnknownField;
    }
    const llm_value = root.get("llm") orelse return error.MissingField;
    const result: Config = blk: {
        const llm = try object(llm_value);
        var lk = llm.iterator();
        while (lk.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "default") and !std.mem.eql(u8, entry.key_ptr.*, "providers") and
                !std.mem.eql(u8, entry.key_ptr.*, "reasoning_effort")) return error.UnknownField;
        }
        const default = try string(llm.get("default") orelse return error.MissingField);
        const selection = try splitDefault(default);
        const provider_map = try object(llm.get("providers") orelse return error.MissingField);
        if (provider_map.count() > 16) return error.TooManyProviders;
        const list = try a.alloc(NamedProvider, provider_map.count());
        var entries = provider_map.iterator();
        var index: usize = 0;
        var total: usize = 0;
        while (entries.next()) |entry| : (index += 1) {
            if (!validAlias(entry.key_ptr.*)) return error.InvalidProviderName;
            var fields = try object(entry.value_ptr.*);
            const models_value = fields.get("models");
            // Work on a copy: removing a key must not mutate the JSON object's storage.
            var connection_fields: std.json.ObjectMap = .{};
            var iter = fields.iterator();
            while (iter.next()) |field| {
                if (!std.mem.eql(u8, field.key_ptr.*, "models")) try connection_fields.put(a, field.key_ptr.*, field.value_ptr.*);
            }
            const connection = try decode(Provider, a, .{ .object = connection_fields });
            var models: []const NamedModel = &.{};
            if (models_value) |mv| {
                const mm = try object(mv);
                total += mm.count();
                if (total > 64) return error.TooManyModels;
                const mutable = try a.alloc(NamedModel, mm.count());
                var mi = mm.iterator();
                var n: usize = 0;
                while (mi.next()) |m| : (n += 1) mutable[n] = .{ .name = m.key_ptr.*, .patch = try decode(ModelPatch, a, m.value_ptr.*) };
                models = mutable;
            }
            list[index] = .{ .name = entry.key_ptr.*, .connection = connection, .models = models };
        }
        const effort = if (llm.get("reasoning_effort")) |value| if (value == .null) null else try string(value) else null;
        const registry: Registry = .{ .default = default, .reasoning_effort = effort, .providers = list };
        const chosen = registry.find(selection.provider) orelse return error.UnknownProvider;
        const limits = if (root.get("limits")) |v| try decode(Limits, a, v) else Limits{};
        if (limits.safety_tokens > 1024 * 1024) return error.InvalidBudget;
        const context: u32 = @max(32768, limits.safety_tokens + 2);
        const decision = if (root.get("decision")) |v| if (v == .null) null else try decode(DecisionConfig, a, v) else null;
        const proxy = if (root.get("proxy")) |v| if (v == .null) null else try decode(ProxyConfig, a, v) else null;
        const image = if (root.get("image")) |v| try decode(ImageConfig, a, v) else ImageConfig{};
        const memory = if (root.get("memory")) |v| try decode(MemoryConfig, a, v) else MemoryConfig{};
        break :blk .{ .proxy = proxy, .decision = decision, .image = image, .memory = memory, .registry = registry, .selected_provider = selection.provider, .selection_pending = true, .provider = chosen.connection, .model = .{ .name = selection.model, .context_tokens = context }, .limits = limits };
    };
    try validate(result);
    tree.arena.child_allocator = allocator;
    return .{ .arena = tree.arena, .value = result };
}

/// Writes declarations only; active cache-resolved models are not disk authority.
pub fn writeDisk(config: Config, writer: *std.Io.Writer) !void {
    const registry = config.registry orelse return error.MissingRegistry;
    try validate(config);
    var s: std.json.Stringify = .{ .writer = writer, .options = .{
        .emit_null_optional_fields = false,
        .whitespace = .indent_2,
    } };
    {
        try s.beginObject();
        try s.objectField("llm");
        try s.beginObject();
        try s.objectField("default");
        try s.write(registry.default);
        if (registry.reasoning_effort) |effort| {
            try s.objectField("reasoning_effort");
            try s.write(effort);
        }
        try s.objectField("providers");
        try s.beginObject();
        for (registry.providers) |p| {
            try s.objectField(p.name);
            try s.beginObject();
            inline for (@typeInfo(Provider).@"struct".field_names) |field| {
                try s.objectField(field);
                try s.write(@field(p.connection, field));
            }
            try s.objectField("models");
            try s.beginObject();
            for (p.models) |m| {
                try s.objectField(m.name);
                try s.write(m.patch);
            }
            try s.endObject();
            try s.endObject();
        }
        try s.endObject();
        try s.endObject();
        try s.objectField("limits");
        try s.write(config.limits);
        if (config.proxy) |proxy| {
            try s.objectField("proxy");
            try s.write(proxy);
        }
        if (config.imageActive()) {
            try s.objectField("image");
            try s.write(config.image);
        }
        if (!config.memory.auto) {
            try s.objectField("memory");
            try s.write(config.memory);
        }
        if (config.decision) |decision| {
            try s.objectField("decision");
            try s.write(decision);
        }
        try s.endObject();
    }
}

test "memory auto strict defaults sparse disk and roundtrip" {
    const a = std.testing.allocator;
    inline for (.{ "", ",\"memory\":{}", ",\"memory\":{\"auto\":true}", ",\"memory\":{\"auto\":false}" }, 0..) |suffix, index| {
        var parsed = try parse(a, image_test_prefix ++ suffix ++ "}");
        defer release(&parsed);
        try std.testing.expectEqual(index != 3, parsed.value.memory.auto);
        var copied = try clone(a, parsed.value);
        defer release(&copied);
        try std.testing.expectEqualDeep(parsed.value.memory, copied.value.memory);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try writeDisk(copied.value, &out.writer);
        var tree = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
        defer tree.deinit();
        try std.testing.expectEqual(index == 3, tree.value.object.contains("memory"));
        if (tree.value.object.get("memory")) |memory| {
            try std.testing.expectEqual(@as(usize, 1), memory.object.count());
            try std.testing.expect(!memory.object.get("auto").?.bool);
        }
        var again = try parse(a, out.written());
        defer release(&again);
        try std.testing.expectEqualDeep(parsed.value.memory, again.value.memory);
    }
    inline for (.{ "null", "true", "0", "\"auto\"", "[]", "{\"auto\":null}", "{\"auto\":0}", "{\"auto\":\"true\"}", "{\"auto\":[]}", "{\"auto\":{}}" }) |bad| {
        try std.testing.expectError(error.UnexpectedToken, parse(a, image_test_prefix ++ ",\"memory\":" ++ bad ++ "}"));
    }
    inline for (.{ "enabled", "reviewer", "model", "Auto" }) |field| {
        try std.testing.expectError(error.UnknownField, parse(a, image_test_prefix ++ ",\"memory\":{\"" ++ field ++ "\":true}}"));
    }
    try std.testing.expectError(error.DuplicateField, parse(a, image_test_prefix ++ ",\"memory\":{\"auto\":true,\"auto\":false}}"));
    try std.testing.expectError(error.DuplicateField, parse(a, image_test_prefix ++ ",\"memory\":{},\"memory\":{}}"));
}

fn memoryAllocationCase(a: std.mem.Allocator) !void {
    inline for (.{ "{}", "{\"auto\":false}" }) |memory| {
        var parsed = try parse(a, image_test_prefix ++ ",\"memory\":" ++ memory ++ "}");
        defer release(&parsed);
        var copied = try clone(a, parsed.value);
        defer release(&copied);
        try std.testing.expectEqualDeep(parsed.value.memory, copied.value.memory);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        writeDisk(copied.value, &out.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        var again = try parse(a, out.written());
        defer release(&again);
        try std.testing.expectEqualDeep(copied.value.memory, again.value.memory);
    }
}

test "memory config allocation failures release parse clone and disk candidates" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, memoryAllocationCase, .{});
}

/// Candidate-only edits. Allocate replacement slices; never mutate shared registry memory.
pub fn setRegistryDefault(a: std.mem.Allocator, config: *Config, provider_name: []const u8, rawid: []const u8) !void {
    const registry = config.registry orelse return error.MissingRegistry;
    if (registry.find(provider_name) == null) return error.UnknownProvider;
    if (!validAlias(provider_name) or !validText(rawid, 1024)) return error.InvalidDefault;
    const value = try std.fmt.allocPrint(a, "{s}/{s}", .{ provider_name, rawid });
    config.registry.?.default = value;
}
/// Edit only the logical preference; capability resolution belongs to the caller.
/// Validate and allocate before publication, leaving config unchanged on failure.
pub fn setRegistryReasoningEffort(a: std.mem.Allocator, config: *Config, name: []const u8) !void {
    if (config.registry == null) return error.MissingRegistry;
    try validateRegistryReasoningEffort(name);
    const owned = try a.dupe(u8, name);
    config.registry.?.reasoning_effort = owned;
}

fn validateRegistryReasoningEffort(name: []const u8) !void {
    for ([_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "max" }) |allowed| {
        if (std.mem.eql(u8, name, allowed)) return;
    }
    return error.InvalidReasoningEffort;
}

pub fn setRegistryCredential(a: std.mem.Allocator, config: *Config, provider_name: []const u8, key: []const u8) !void {
    const registry = config.registry orelse return error.MissingRegistry;
    const provider = registry.find(provider_name) orelse return error.UnknownProvider;
    var connection = provider.connection;
    connection.api_key_env = "";
    connection.api_key = key;
    try validateKeySource(connection);
    const copy = try a.dupe(NamedProvider, registry.providers);
    const owned_key = try a.dupe(u8, key);
    for (copy) |*p| if (std.mem.eql(u8, p.name, provider_name)) {
        p.connection.api_key_env = "";
        p.connection.api_key = owned_key;
    };
    config.registry.?.providers = copy;
    if (config.selected_provider) |selected| if (std.mem.eql(u8, selected, provider_name)) {
        config.provider.api_key_env = "";
        config.provider.api_key = owned_key;
    };
}

/// 擦除所有释放的分配；禁止缩容与 remap，避免分配器内部释放未擦除的旧缓冲区。
pub const WipingAllocator = struct {
    backing: std.mem.Allocator,

    pub fn allocator(self: *WipingAllocator) std.mem.Allocator {
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

pub fn validateKeySource(provider: Provider) !void {
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
    try validateConfig(config, false);
}

/// Preferences may update an unresolved, display-only restored selection.
/// Keep structural/budget checks, but no primary endpoint exists to validate.
/// This is never send authorization: validate() remains mandatory for requests.
pub fn validatePendingSettings(config: Config) !void {
    if (!config.selection_pending or config.provider.base_url.len != 0) return error.InvalidConfig;
    try validateConfig(config, true);
}

fn validateConfig(config: Config, comptime unresolved: bool) !void {
    if (!unresolved) {
        try validateUrl(config.provider.base_url);
        try validateKeySource(config.provider);
        if (config.provider.kind) |declared| if (providers.Id.fromUrl(config.provider.base_url) orelse providers.Id.fromSystemOneUrl(config.provider.base_url)) |actual| {
            if (declared != actual) return error.ProviderEndpointMismatch;
        };
    }
    if (config.registry) |registry| try validateRegistry(registry, config.limits);
    if (config.proxy) |proxy| try validateProxy(proxy, config.registry);
    if (config.image.model) |model| {
        const selection = try splitDefault(model);
        if (!std.mem.eql(u8, selection.model, "deepseek-flash")) return error.InvalidImageModel;
        const registry = config.registry orelse return error.MissingRegistry;
        _ = registry.find(selection.provider) orelse return error.UnknownProvider;
    }
    if (config.decision) |decision| {
        const selection = try splitDefault(decision.model);
        const registry = config.registry orelse return error.MissingRegistry;
        _ = registry.find(selection.provider) orelse return error.UnknownProvider;
        if (decision.max_state_bytes < 2 or decision.max_state_bytes > 65536) return error.InvalidLimit;
        if (decision.max_input_tokens < 2 or decision.max_input_tokens > 16 * 1024 * 1024) return error.InvalidLimit;
    }

    const l = config.limits;
    // Null means unlimited rounds; explicit limits are positive.
    inline for (@typeInfo(Limits).@"struct".field_names) |field| {
        if (comptime std.mem.eql(u8, field, "max_rounds")) {
            if (l.max_rounds) |rounds| {
                if (rounds == 0 or rounds > 4096) return error.InvalidLimit;
            }
        } else if (@TypeOf(@field(l, field)) == bool) {
            // false is an intentional policy, not a zero numeric limit.
        } else if (@field(l, field) == 0) return error.InvalidLimit;
    }

    try validateInputLimits(l);

    // Hard ceilings are implementation safeguards, not provider capabilities.
    // 中文：以下上限是实现层的安全保护，与提供方能力无关。
    const mib = 1024 * 1024;
    if (l.read_bytes > 16 * mib or l.output_bytes > 16 * mib or
        l.core_bytes > mib or l.index_bytes > 8 * mib or l.shard_bytes > 16 * mib or
        l.max_response_bytes > 64 * mib or l.max_event_bytes > 16 * mib or
        l.max_event_bytes > l.max_response_bytes) return error.InvalidLimit;

    const day_ms = 24 * 60 * 60 * 1000;
    if (l.model_refresh_ttl_ms > 7 * day_ms or l.model_refresh_cooldown_ms > 7 * day_ms) return error.InvalidLimit;

    // 超时之间的大小关系与上限：清理宽限不能超过清理总超时，且总超时不超过 60 秒。
    if (l.command_timeout_ms > l.command_max_timeout_ms or l.command_max_timeout_ms > day_ms or
        l.request_timeout_ms > day_ms or l.task_timeout_ms > day_ms or l.cleanup_grace_ms > l.cleanup_timeout_ms or
        l.cleanup_timeout_ms > 60000 or l.max_tool_calls > 4096) return error.InvalidLimit;

    // 窗口须留出输入与至少一个输出 token；输出上限按每次请求剩余空间收缩，摘要仍遵守显式上限。
    try validateModel(config.model, l);
    if (!unresolved) try validateReasoningProtocol(config.provider.base_url, config.model);

    // 压缩目标必须低于触发阈值，且触发阈值必须小于 100%，否则压缩永远无法生效或立即触发。
    if (!(l.compaction_target_percent < l.compaction_trigger_percent and l.compaction_trigger_percent < 100)) return error.InvalidCompactionRatio;
}

fn validateRegistry(registry: Registry, limits: Limits) !void {
    if (registry.reasoning_effort) |effort| try validateRegistryReasoningEffort(effort);
    const selection = try splitDefault(registry.default);
    if (registry.find(selection.provider) == null) return error.UnknownProvider;
    if (registry.providers.len > 16) return error.TooManyProviders;
    var total: usize = 0;
    for (registry.providers, 0..) |p, i| {
        if (!validAlias(p.name)) return error.InvalidProviderName;
        for (registry.providers[0..i]) |previous| if (std.mem.eql(u8, previous.name, p.name)) return error.DuplicateProvider;
        try validateUrl(p.connection.base_url);
        try validateKeySource(p.connection);
        if (p.connection.kind) |declared| if (providers.Id.fromUrl(p.connection.base_url) orelse providers.Id.fromSystemOneUrl(p.connection.base_url)) |actual| {
            if (declared != actual) return error.ProviderEndpointMismatch;
        };
        total += p.models.len;
        if (total > 64) return error.TooManyModels;
        for (p.models, 0..) |m, j| {
            for (p.models[0..j]) |previous| if (std.mem.eql(u8, previous.name, m.name)) return error.DuplicateModel;
            const patch = m.patch;
            var model = patch.apply(.{ .name = m.name, .context_tokens = @max(32768, @min(limits.safety_tokens, 1024 * 1024) + 2) });
            // A missing protocol is not explicit auto authority. Validate the
            // declaration now, defer its protocol union until cache resolution.
            if (patch.protocol == null) {
                if (model.reasoning) |r| try r.validate();
                model.reasoning = null;
                model.reasoning_effort = null;
                if (patch.reasoning_effort) |effort| if (!validText(effort, 128)) return error.InvalidReasoningEffort;
            }
            try validateModel(model, limits);
            if (patch.protocol != null) try validateReasoningProtocol(p.connection.base_url, model);
        }
    }
}

test "low price input defaults enabled and explicit optout survives disk roundtrip" {
    const a = std.testing.allocator;
    const prefixes = [_][]const u8{
        "{\"llm\":{\"default\":\"local/m\",\"providers\":{\"local\":{\"base_url\":\"https://fixture.invalid/v1\",\"models\":{\"m\":{\"protocol\":\"chat\",\"context_tokens\":32768}}}}},\"limits\":",
    };
    for (prefixes) |prefix| for ([_][]const u8{ "{}", "{\"low_price_input\":true}", "{\"low_price_input\":false}" }) |limits| {
        const raw = try std.mem.concat(a, u8, &.{ prefix, limits, "}" });
        defer a.free(raw);
        var parsed = try parse(a, raw);
        defer release(&parsed);
        const enabled = std.mem.find(u8, limits, "false") == null;
        try std.testing.expectEqual(enabled, parsed.value.limits.low_price_input);
        // Unknown price metadata does not prevent parsing or selection.
        try std.testing.expect(parsed.value.model.input_price_threshold == null);
        var cloned = try clone(a, parsed.value);
        defer release(&cloned);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try writeDisk(cloned.value, &out.writer);
        var again = try parse(a, out.written());
        defer release(&again);
        try std.testing.expectEqual(enabled, again.value.limits.low_price_input);
    };
}

test "thinking declarations strict owned config validation and protocol incompatibility" {
    const t = std.testing;
    var parsed = try parse(t.allocator,
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"https://proxy/v1","models":{"custom":{"context_tokens":32768,"reasoning":{"map":{"off":"disabled","high":"own-wire"}}}}}}}}
    );
    defer release(&parsed);
    try t.expectEqualStrings("own-wire", parsed.value.registry.?.find("p").?.patchFor("custom").?.reasoning.?.map.high.?);
    try t.expectError(error.MissingField, parse(t.allocator,
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"https://proxy/v1","models":{"custom":{"reasoning":{}}}}}}}
    ));
    try t.expectError(error.InvalidReasoningMap, parse(t.allocator,
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"https://proxy/v1","models":{"custom":{"reasoning":{"map":{}}}}}}}}
    ));
    try t.expectError(error.UnknownField, parse(t.allocator,
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"https://proxy/v1","models":{"custom":{"reasoning":{"map":{"ultra":"x"}}}}}}}}
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
        \\{"llm":{"default":"p/claude-haiku-5-5","providers":{"p":{"base_url":"https://opencode.ai/inference/go/v1","models":{"claude-haiku-5-5":{"context_tokens":32768,"protocol":"anthropic"}}}}}}
    );
    defer release(&parsed);
    const patch = parsed.value.registry.?.find("p").?.patchFor("claude-haiku-5-5").?;
    try std.testing.expect(patch.protocol.? == .anthropic);
    try validate(parsed.value);
    var config = parsed.value;
    config.model = patch.apply(config.model);
    config.model.reasoning_effort = "high";
    try std.testing.expectError(error.UnsupportedAnthropicReasoning, validate(config));
    config.model.reasoning = .{ .format = .anthropic, .map = .{ .off = "disabled", .low = "low", .high = "high" } };
    try validate(config);
    config.model.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } };
    try std.testing.expectError(error.IncompatibleReasoningProtocol, validate(config));
}

/// Verified service protocol or an explicit wire format, not a capability table.
pub fn chatOnly(base_url: []const u8, model: Model) bool {
    const native_chat = providers.Id.fromUrl(base_url) == .deepseek and
        (std.mem.eql(u8, model.name, "deepseek-flash") or std.mem.eql(u8, model.name, "deepseek-v4-pro"));
    return native_chat or (model.reasoning != null and model.reasoning.?.format == .deepseek);
}

fn validateReasoningProtocol(base_url: []const u8, model: Model) !void {
    if (providers.Id.fromSystemOneUrl(base_url) != null and model.protocol != .systemone and model.protocol != .auto) return error.IncompatibleModelProtocol;
    if ((model.protocol == .responses or model.protocol == .anthropic) and chatOnly(base_url, model)) return error.IncompatibleReasoningProtocol;
}

/// Validate user input policy without requiring price metadata at parse time.
pub fn validateInputLimits(l: Limits) !void {
    const maximum = 16 * 1024 * 1024;
    if (l.input_margin_tokens == 0 or l.input_margin_tokens > maximum) return error.InvalidBudget;
    if (l.max_input_tokens) |tokens| {
        if (tokens == 0 or tokens > maximum or tokens <= l.input_margin_tokens) return error.InvalidBudget;
    }
}

/// Shared profile validation uses the same limits as the selected model.
pub fn validateModel(model: Model, l: Limits) !void {
    if (!validText(model.name, 1024)) return error.InvalidModel;
    if (model.protocol == .systemone and (model.reasoning_effort != null or model.reasoning != null)) return error.IncompatibleReasoningProtocol;
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
    if (model.output_tokens) |tokens| {
        if (tokens == 0 or tokens > mib) return error.InvalidBudget;
    }
    if (model.context_tokens > 16 * mib or l.safety_tokens > mib) return error.InvalidBudget;
    if (model.protocol != .systemone and
        (model.context_tokens == 0 or @as(u64, l.safety_tokens) + 1 >= model.context_tokens)) return error.InvalidBudget;
    if (model.input_price_threshold) |tokens| if (tokens == 0 or tokens > 16 * mib) return error.InvalidBudget;
    if (model.input_price_flat_limit) |tokens| if (tokens == 0 or tokens > 16 * mib) return error.InvalidBudget;
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
    if (config.provider.api_key_env.len == 0) return error.ApiKeyNotFound;
    const key = environ.get(config.provider.api_key_env) orelse return error.ApiKeyNotFound;
    // 拒绝空白或含控制字符的 key，防止 header 注入。
    if (!validText(key, 16384)) return error.InvalidApiKey;
    return allocator.dupe(u8, key);
}

test "official services without an explicit credential source never borrow keys" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("DEEPSEEK_API_KEY", "fake-unselected");
    var c = testConfig();
    c.provider.api_key_env = "";
    for (providers.Id.all) |id| {
        c.provider.base_url = id.baseUrl();
        try std.testing.expectError(error.ApiKeyNotFound, resolveApiKey(a, c, &env));
    }
    c.provider.kind = .deepseek;
    c.provider.base_url = providers.Id.opencode_go.baseUrl();
    try std.testing.expectError(error.ProviderEndpointMismatch, validate(c));
}

/// 测试用的最小合法配置 JSON。
const fixture =
    \\{"llm":{"default":"local/test-model","providers":{"local":{"base_url":"https://example.invalid/v1","api_key_env":"TEST_KEY"}}}}
;

/// 构造与 fixture 等价的 Config 值，供需要直接修改字段的测试使用。
fn testConfig() Config {
    return .{ .provider = .{ .base_url = "https://example.invalid/v1", .api_key_env = "TEST_KEY" }, .model = .{ .name = "test-model", .context_tokens = 32768 } };
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
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"http://localhost:8080/v1","api_key_env":"KEY","models":{"custom":{"context_tokens":65536,"protocol":"responses","reasoning_effort":"high"}}}}},"limits":{"max_rounds":10}}
    );
    const parsed = try parse(a, input);
    defer parsed.deinit();
    @memset(input, 'x');
    a.free(input);

    const patch = parsed.value.registry.?.find("p").?.patchFor("custom").?;
    try std.testing.expectEqual(protocol.Protocol.responses, patch.protocol.?);
    try std.testing.expectEqualStrings("high", patch.reasoning_effort.?);
    try std.testing.expectEqual(@as(?u16, 10), parsed.value.limits.max_rounds);
}

// Defaults remain unlimited; serialization never guesses whether legacy 50 was explicit.
test "round limits missing null and legacy numbers survive config serialization" {
    const a = std.testing.allocator;
    const prefix = "{\"llm\":{\"default\":\"local/fake\",\"providers\":{\"local\":{\"base_url\":\"http://localhost\"}}},\"limits\":";
    const cases = [_]struct { json: []const u8, expected: ?u16 }{
        .{ .json = "{}", .expected = null },
        .{ .json = "{\"max_rounds\":null}", .expected = null },
        .{ .json = "{\"max_rounds\":1}", .expected = 1 },
        .{ .json = "{\"max_rounds\":50}", .expected = 50 },
        .{ .json = "{\"max_rounds\":4096}", .expected = 4096 },
    };
    try std.testing.expectEqual(@as(?u16, null), testConfig().limits.max_rounds);
    for (cases) |case| {
        const input = try std.mem.concat(a, u8, &.{ prefix, case.json, "}" });
        defer a.free(input);
        var parsed = try parse(a, input);
        defer release(&parsed);
        try std.testing.expectEqual(case.expected, parsed.value.limits.max_rounds);
        var copied = try clone(a, parsed.value);
        defer release(&copied);
        try std.testing.expectEqual(case.expected, copied.value.limits.max_rounds);
        var disk: std.Io.Writer.Allocating = .init(a);
        defer disk.deinit();
        try writeDisk(parsed.value, &disk.writer);
        var restored = try parse(a, disk.written());
        defer release(&restored);
        try std.testing.expectEqual(case.expected, restored.value.limits.max_rounds);
    }
    for ([_][]const u8{ "{\"max_rounds\":0}", "{\"max_rounds\":4097}" }) |limits| {
        const input = try std.mem.concat(a, u8, &.{ prefix, limits, "}" });
        defer a.free(input);
        try std.testing.expectError(error.InvalidLimit, parse(a, input));
    }
}

// 验证：缺失字段、未知字段、重复字段以及 TOML 格式都会被拒绝。
test "strict JSON rejects missing unknown duplicate and TOML fields" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingField, parse(a, "{}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"provider\":{}}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"unknown\":1}"));

    // Former root fields are rejected even when they contain a plausible key.
    try std.testing.expectError(error.UnknownField, parse(a, "{\"provider\":{\"api_key\":\"fake-key\"}}"));
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
    // Input preflight retains physical context safety without an output policy.
    c.model.context_tokens = 6144;
    try validate(c);
    c.model.context_tokens = c.limits.safety_tokens + 1;
    try std.testing.expectError(error.InvalidBudget, validate(c));

    c = testConfig();
    // A declared model output capability remains positive, independently of context.
    c.model.output_tokens = 0;
    try std.testing.expectError(error.InvalidBudget, validate(c));
    c = testConfig();

    // 压缩目标不能不低于触发阈值。
    c.limits.compaction_target_percent = 80;
    try std.testing.expectError(error.InvalidCompactionRatio, validate(c));
    c = testConfig();
    c.limits.compaction_trigger_percent = 100;
    try std.testing.expectError(error.InvalidCompactionRatio, validate(c));

    // Numeric zero is invalid; false intentionally disables automatic compaction.
    inline for (@typeInfo(Limits).@"struct".field_names) |field| {
        c = testConfig();
        if (@TypeOf(@field(c.limits, field)) == bool) {
            @field(c.limits, field) = false;
            try validate(c);
        } else {
            @field(c.limits, field) = 0;
            try std.testing.expectError(error.InvalidLimit, validate(c));
        }
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
test "credential and image parser cleanup and release zero owned allocations" {
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
        \\{"llm":{"default":"p/test","providers":{"p":{"base_url":"https://example.invalid","api_key":"fake-inline"}}}}
    ;
    var parsed = try parse(observer.allocator(), inline_json);
    try std.testing.expectEqualStrings("fake-inline", parsed.value.provider.api_key.?);
    var copied = try clone(observer.allocator(), parsed.value);
    try std.testing.expectEqualStrings("fake-inline", copied.value.provider.api_key.?);
    release(&copied);
    release(&parsed);
    try std.testing.expectError(error.UnknownField, parse(observer.allocator(),
        \\{"provider":{"base_url":"https://example.invalid","api_key":"fake-inline","unknown":1}}
    ));
    try std.testing.expectError(error.InvalidApiKey, parse(observer.allocator(),
        \\{"llm":{"default":"p/test","providers":{"p":{"base_url":"https://example.invalid","api_key":"fake\ninline"}}}}
    ));
    var registry_parsed = try parse(observer.allocator(),
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://example.invalid"},"backup":{"base_url":"https://backup.invalid","api_key":"fake-backup"}}}}
    );
    release(&registry_parsed);
    try std.testing.expectError(error.InvalidApiKey, parse(observer.allocator(),
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://example.invalid"},"backup":{"base_url":"https://backup.invalid","api_key":"fake\nbackup"}}}}
    ));
    // Observe production allocations inside each OOM attempt, not the testing
    // harness's own non-secret allocation bookkeeping.
    const FailureCase = struct {
        fn run(a: std.mem.Allocator) !void {
            var watched = Observer{ .backing = a };
            decisionAllocationCase(watched.allocator()) catch |err| {
                try std.testing.expect(!watched.dirty_free);
                return err;
            };
            try std.testing.expect(!watched.dirty_free);
        }

        fn image(a: std.mem.Allocator) !void {
            var watched = Observer{ .backing = a };
            imageAllocationCase(watched.allocator()) catch |err| {
                try std.testing.expect(!watched.dirty_free);
                return err;
            };
            try std.testing.expect(watched.frees > 0);
            try std.testing.expect(!watched.dirty_free);
        }

        fn rejectImage(a: std.mem.Allocator) !void {
            var watched = Observer{ .backing = a };
            rejectedImageAllocationCase(watched.allocator()) catch |err| {
                try std.testing.expect(!watched.dirty_free);
                return err;
            };
            try std.testing.expect(watched.frees > 0);
            try std.testing.expect(!watched.dirty_free);
        }

        fn reject(a: std.mem.Allocator) !void {
            var watched = Observer{ .backing = a };
            // Test-input construction bypasses the observer; only production
            // parse allocations belong to the final rawFree wiping contract.
            rejectedDecisionAllocationCase(watched.allocator()) catch |err| {
                try std.testing.expect(!watched.dirty_free);
                return err;
            };
            try std.testing.expect(watched.frees > 0);
            try std.testing.expect(!watched.dirty_free);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.image, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.rejectImage, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.run, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.reject, .{});
    try std.testing.expect(observer.frees > 0);
    try std.testing.expect(!observer.dirty_free);
}
