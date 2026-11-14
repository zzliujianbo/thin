//! 配置层：解析并校验 config.json（严格 JSON，拒绝未知与重复字段），检查 URL、限额与预算，
//! API key 可内联保存或从环境变量读取；解析结果通过 release 擦除后释放。

const std = @import("std");
const protocol = @import("protocol.zig");
const thinking = @import("thinking.zig");
pub const providers = @import("providers.zig");

/// 单一配置文件名；路径构造、交互存储和文件工具保护共用，避免名称漂移。
pub const file_name = "config.json";

/// OAuth credentials are declarations in the protected config, not account identity proof.
pub const CodexCredential = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    expires_at_ms: i64,
    refresh_pending: bool = false,
};

/// 提供方连接信息。两种密钥来源最多配置一种，也允许尚未配置密钥。
pub const Provider = struct {
    /// 提供方的基础 URL（仅允许 http/https，见 validateUrl）。
    base_url: []const u8,
    /// 存放 API key 的环境变量名。
    api_key_env: []const u8 = "",
    /// 内联 API key；未配置时必须为 null，不能是空字符串。
    api_key: ?[]const u8 = null,
    codex_oauth: ?CodexCredential = null,
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

pub const Policy = struct {
    pub const input_margin_tokens = 5000;
    pub const safety_tokens = 4096;

    /// Preserve the normal reserve without excluding smaller verified windows.
    pub fn safetyTokens(context_tokens: u32) u32 {
        return @min(safety_tokens, context_tokens / 8);
    }
    pub const model_refresh_ttl_ms = 14400000;
    pub const model_refresh_cooldown_ms = 300000;
    pub const cleanup_grace_ms = 1000;
    pub const cleanup_timeout_ms = 5000;
    pub const compaction_trigger_percent = 80;
    pub const compaction_target_percent = 50;
};

pub const Limits = struct {
    /// 单条命令的默认超时（毫秒）。
    command_timeout_ms: u32 = 300000,
    /// Enabled by default; explicit false opts out of the first known price step.
    /// Unknown metadata fails closed before any inference, never guesses 100K.
    low_price_input: bool = true,
    /// 单次模型请求的超时（毫秒）。
    request_timeout_ms: u32 = 300000,
    /// Disable only automatic compaction; manual /compact and hard preflight remain.
    compaction_enabled: bool = true,
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

/// One settings-editor proxy host/port pair. Bounded so a single declaration line
/// can never grow a config field without limit.
pub const max_proxy_endpoint_bytes: usize = 320;

/// Borrowed host plus numeric port. `address` is never a URL, credentials or a
/// bracketed IPv6 literal; it points into the caller's `raw` input.
pub const ProxyEndpoint = struct { address: []const u8, port: u16 };

/// Parse `host:port` or `[IPv6]:port`. Surrounding ASCII whitespace is ignored
/// and an all-whitespace input means "no proxy". Anything else is rejected:
/// schemes, userinfo, paths, unbracketed IPv6, zone identifiers and controls.
/// Pure function: no I/O, no allocation; the address borrows `raw`.
pub fn parseProxyEndpoint(raw: []const u8) !?ProxyEndpoint {
    // Bound raw bytes before trimming: callers cap the wire/editor payload, so
    // unbounded whitespace must fail rather than masquerade as a clear.
    if (raw.len > max_proxy_endpoint_bytes) return error.InputTooLarge;
    const trimmed = std.mem.trim(u8, raw, " \t\n\r\x0b\x0c");
    if (trimmed.len == 0) return null;
    var address: []const u8 = undefined;
    var port_text: []const u8 = undefined;
    if (trimmed[0] == '[') {
        const close = std.mem.findScalar(u8, trimmed, ']') orelse return error.InvalidProxyAddress;
        if (close < 2 or close + 1 >= trimmed.len or trimmed[close + 1] != ':') return error.InvalidProxyAddress;
        address = trimmed[1..close];
        // Brackets are an IPv6-only form; a bracketed DNS/IPv4 literal is a URL habit.
        if (std.mem.findScalar(u8, address, ':') == null) return error.InvalidProxyAddress;
        port_text = trimmed[close + 2 ..];
    } else {
        const colon = std.mem.findScalar(u8, trimmed, ':') orelse return error.InvalidProxyAddress;
        // A second colon is an unbracketed IPv6 literal, not host:port.
        if (std.mem.findScalar(u8, trimmed[colon + 1 ..], ':') != null) return error.InvalidProxyAddress;
        address = trimmed[0..colon];
        port_text = trimmed[colon + 1 ..];
    }
    if (port_text.len == 0 or port_text.len > 5) return error.InvalidProxyPort;
    for (port_text) |c| if (!std.ascii.isDigit(c)) return error.InvalidProxyPort;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidProxyPort;
    if (port == 0) return error.InvalidProxyPort;
    try validateProxyAddress(address);
    return .{ .address = address, .port = port };
}

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
    /// Shared by generic auxiliary resolution and its local model picker.
    /// Never use primary price policy or command limits to resolve a reviewer.
    pub fn modelLimits(_: DecisionConfig, shared_request_timeout_ms: u32) Limits {
        return .{ .low_price_input = false, .request_timeout_ms = shared_request_timeout_ms };
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

/// Every string is owned by the returned arena, never by `bytes`.
/// 中文：解析后的字符串复制到 allocator 中，因此调用方可以擦除 bytes；结果需调用 release 释放。
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Config) {
    return parseBounded(allocator, bytes, true, false);
}

// No secret is needed to select an image helper; provider credentials are
// resolved separately at use time, never borrowed from decision/primary state.

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
    if (unresolved) try validatePendingSettings(config) else try validate(config);
    var wiping = WipingAllocator{ .backing = allocator };
    const bytes = try std.json.Stringify.valueAlloc(wiping.allocator(), config, .{ .emit_null_optional_fields = false });
    // Allocator.free poisons memory before calling rawFree in safety builds.
    // Keep the wiping wrapper at the final free boundary, just as for the
    // stringify writer's intermediate buffers and the parsed arena's release.
    defer wiping.allocator().free(bytes);
    return parseBounded(allocator, bytes, false, unresolved);
}

fn parseBounded(allocator: std.mem.Allocator, bytes: []const u8, disk: bool, comptime unresolved: bool) !std.json.Parsed(Config) {
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
    // Codex is a Responses variant; normalize only the effective in-memory
    // selection, never rewrite the user's config file.
    if (isCodexProvider(parsed.value.provider) and parsed.value.model.protocol == .auto)
        parsed.value.model.protocol = .responses;
    if (unresolved) try validatePendingSettings(parsed.value) else try validate(parsed.value);
    return parsed;
}

const json_options: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" };

fn decode(comptime T: type, a: std.mem.Allocator, value: std.json.Value) !T {
    if (T == Provider) {
        const fields = try object(value);
        if (fields.get("codex_oauth")) |oauth| if (oauth != .null) {
            const credential = try object(oauth);
            _ = try string(credential.get("access_token") orelse return error.MissingField);
            _ = try string(credential.get("refresh_token") orelse return error.MissingField);
            const expiry = credential.get("expires_at_ms") orelse return error.MissingField;
            if (expiry != .integer) return error.InvalidNumber;
            if (credential.get("refresh_pending")) |pending| {
                if (pending != .bool) return error.InvalidBoolean;
            }
        };
    }
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
                if (!known and !(T == DecisionConfig and (std.mem.eql(u8, entry.key_ptr.*, "max_input_tokens") or std.mem.eql(u8, entry.key_ptr.*, "max_state_bytes")))) return error.UnknownField;
            }
            // Removed policy fields are inert migration input, regardless of
            // their former value. Current fields retain strict type validation.
            if (T == Limits and isRetiredLimit(entry.key_ptr.*)) continue;
            if (T == DecisionConfig and (std.mem.eql(u8, entry.key_ptr.*, "max_input_tokens") or std.mem.eql(u8, entry.key_ptr.*, "max_state_bytes"))) continue;
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
    if (T == Limits or T == DecisionConfig) {
        const original = try object(value);
        var migrated: std.json.ObjectMap = .{};
        var it = original.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const retired = if (T == Limits) isRetiredLimit(key) else std.mem.eql(u8, key, "max_input_tokens") or std.mem.eql(u8, key, "max_state_bytes");
            if (!retired) try migrated.put(a, key, entry.value_ptr.*);
        }
        return std.json.parseFromValueLeaky(T, a, .{ .object = migrated }, json_options);
    }
    return std.json.parseFromValueLeaky(T, a, value, json_options);
}
fn isRetiredLimit(key: []const u8) bool {
    const names = [_][]const u8{ "command_max_timeout_ms", "read_bytes", "output_bytes", "max_input_tokens", "input_margin_tokens", "safety_tokens", "max_rounds", "max_tool_calls", "task_timeout_ms", "model_refresh_ttl_ms", "model_refresh_cooldown_ms", "cleanup_grace_ms", "cleanup_timeout_ms", "core_bytes", "index_bytes", "shard_bytes", "compaction_trigger_percent", "compaction_target_percent", "max_response_bytes", "max_event_bytes" };
    for (names) |name| if (std.mem.eql(u8, key, name)) return true;
    return false;
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
    var result: Config = blk: {
        const llm = try object(llm_value);
        var lk = llm.iterator();
        while (lk.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "default") and !std.mem.eql(u8, entry.key_ptr.*, "providers") and
                !std.mem.eql(u8, entry.key_ptr.*, "reasoning_effort")) return error.UnknownField;
        }
        const default = try string(llm.get("default") orelse return error.MissingField);
        const selection = try splitDefault(default);
        const provider_map = try object(llm.get("providers") orelse return error.MissingField);
        const list = try a.alloc(NamedProvider, provider_map.count());
        var entries = provider_map.iterator();
        var index: usize = 0;
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
        const context: u32 = 32768;
        const decision = if (root.get("decision")) |v| if (v == .null) null else try decode(DecisionConfig, a, v) else null;
        const proxy = if (root.get("proxy")) |v| if (v == .null) null else try decode(ProxyConfig, a, v) else null;
        const image = if (root.get("image")) |v| try decode(ImageConfig, a, v) else ImageConfig{};
        const memory = if (root.get("memory")) |v| try decode(MemoryConfig, a, v) else MemoryConfig{};
        break :blk .{ .proxy = proxy, .decision = decision, .image = image, .memory = memory, .registry = registry, .selected_provider = selection.provider, .selection_pending = true, .provider = chosen.connection, .model = .{ .name = selection.model, .context_tokens = context }, .limits = limits };
    };
    if (isCodexProvider(result.provider) and result.model.protocol == .auto) result.model.protocol = .responses;
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
                if (comptime std.mem.eql(u8, field, "codex_oauth")) {
                    if (p.connection.codex_oauth) |oauth| {
                        try s.objectField(field);
                        try s.write(oauth);
                    }
                } else {
                    try s.objectField(field);
                    try s.write(@field(p.connection, field));
                }
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

/// The callbacks may grow through realloc, so a fail-index matrix over the raw
/// allocator is not deterministic: a successful remap removes an allocation and
/// the exhaustive pass can then report NondeterministicMemoryUsage. Run the
/// exhaustive matrix behind WipingAllocator (which always allocates anew), then
/// scan the same bound again with the plain allocator to keep the normal
/// growth-then-OOM path under test.
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

/// Codex is selected by provider identity, not by model name or UI protocol.
pub fn isCodexProvider(provider: Provider) bool {
    return provider.kind == .openai_codex and std.mem.eql(u8, provider.base_url, providers.Id.openai_codex.baseUrl());
}

/// Resolve the internal wire driver from the public protocol and provider.
pub fn wireCodec(config: Config, proto: protocol.Protocol) !protocol.WireCodec {
    if (isCodexProvider(config.provider)) return switch (proto) {
        .responses, .auto => .codex_responses,
        else => error.IncompatibleModelProtocol,
    };
    return switch (proto) {
        .chat => .chat,
        .responses => .responses,
        .anthropic => .anthropic,
        .systemone => .systemone,
        .auto => error.UnselectedProtocol,
    };
}

pub fn validateKeySource(provider: Provider) !void {
    const is_codex = provider.kind == .openai_codex;
    const codex_url = std.mem.eql(u8, provider.base_url, providers.Id.openai_codex.baseUrl());
    if (is_codex != codex_url) return error.InvalidCodexProvider;
    if (is_codex and (provider.api_key != null or provider.api_key_env.len != 0)) return error.AmbiguousApiKey;
    if (provider.codex_oauth) |credential| {
        if (!is_codex) return error.InvalidCodexProvider;
        if (provider.api_key != null or provider.api_key_env.len != 0) return error.AmbiguousApiKey;
        if (!validText(credential.access_token, 16384) or !validText(credential.refresh_token, 16384) or credential.expires_at_ms <= 0) return error.InvalidCodexCredential;
    }
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
    if (config.registry) |registry| try validateRegistry(registry);
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
    }

    const l = config.limits;
    if (l.command_timeout_ms == 0 or l.request_timeout_ms == 0) return error.InvalidLimit;
    try validateModel(config.model);
    if (!unresolved) try validateReasoningProtocol(config.provider.base_url, config.model);
}

fn validateRegistry(registry: Registry) !void {
    if (registry.reasoning_effort) |effort| try validateRegistryReasoningEffort(effort);
    const selection = try splitDefault(registry.default);
    if (registry.find(selection.provider) == null) return error.UnknownProvider;
    for (registry.providers, 0..) |p, i| {
        if (!validAlias(p.name)) return error.InvalidProviderName;
        for (registry.providers[0..i]) |previous| if (std.mem.eql(u8, previous.name, p.name)) return error.DuplicateProvider;
        try validateUrl(p.connection.base_url);
        try validateKeySource(p.connection);
        if (p.connection.kind) |declared| if (providers.Id.fromUrl(p.connection.base_url) orelse providers.Id.fromSystemOneUrl(p.connection.base_url)) |actual| {
            if (declared != actual) return error.ProviderEndpointMismatch;
        };
        for (p.models, 0..) |m, j| {
            for (p.models[0..j]) |previous| if (std.mem.eql(u8, previous.name, m.name)) return error.DuplicateModel;
            const patch = m.patch;
            var model = patch.apply(.{ .name = m.name, .context_tokens = 32768 });
            // A missing protocol is not explicit auto authority. Validate the
            // declaration now, defer its protocol union until cache resolution.
            if (patch.protocol == null) {
                if (model.reasoning) |r| try r.validate();
                model.reasoning = null;
                model.reasoning_effort = null;
                if (patch.reasoning_effort) |effort| if (!validText(effort, 128)) return error.InvalidReasoningEffort;
            }
            try validateModel(model);
            if (patch.protocol != null) try validateReasoningProtocol(p.connection.base_url, model);
        }
    }
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

/// Validate a model profile independently of request limits.
pub fn validateModel(model: Model) !void {
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
    if (model.output_tokens) |tokens| {
        if (tokens == 0) return error.InvalidBudget;
    }
    if (model.protocol != .systemone and model.context_tokens < 2) return error.InvalidBudget;
    if (model.input_price_threshold) |tokens| if (tokens == 0) return error.InvalidBudget;
    if (model.input_price_flat_limit) |tokens| if (tokens == 0) return error.InvalidBudget;
}

/// Reads only the explicit file; never consults environment variables.
/// 中文：只读取调用方明确指定的文件，不读取环境变量；输入缓冲区释放前擦除。
/// 读取时多读一个字节，用来判断文件是否超过上限。
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(Config) {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const bytes = try allocator.alloc(u8, try std.math.add(usize, size, 1));
    // 字节缓冲区在解析后即可释放，因为 parse 会把字符串复制到独立的内存中。
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    const n = try file.readPositionalAll(io, bytes, 0);
    if (n != size) return error.FileChanged;
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

// 测试用的最小合法配置 JSON。

// 构造与 fixture 等价的 Config 值，供需要直接修改字段的测试使用。

// 验证：显式指定的协议、推理强度与限额会覆盖默认值，且字符串同样被复制。

// Defaults remain unlimited; serialization never guesses whether legacy 50 was explicit.

// 验证：缺失字段、未知字段、重复字段以及 TOML 格式都会被拒绝。

// 验证：各种非法 URL 与含控制字符的 env 名、模型名都会被拒绝。

// 验证：预算、压缩比例与各项限额的边界都会被检查。

// 验证：load 返回的数据不依赖已删除的文件，且严格执行 64 KiB 上限（恰好等于上限可以通过）。

// 验证：使用假的环境变量表时，key 返回独立副本；空白或含控制字符的 key 被拒绝，且错误不泄露内容。

// 验证：默认路径只使用传入的 home，且拒绝空 home。

// 密钥来源独立校验：未配置可加载；内联返回副本；两个来源不能同时出现。

// 包装分配器在语法失败、语义失败、正常 release 三条路径上都负责擦除。
