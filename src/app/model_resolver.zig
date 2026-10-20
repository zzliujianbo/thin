//! Pure cache-only registry resolution. Disk declarations and runtime options
//! are separate: discovery never writes a manual model patch or changes default.
const std = @import("std");
const cfg = @import("../core/config.zig");
const metadata = @import("model_metadata.zig");
const catalog = @import("provider_catalog.zig");
const Allocator = std.mem.Allocator;

pub const Selection = struct {
    connection: cfg.Provider,
    model: cfg.Model,
    provider_name: []const u8,
    context_official: bool,
};

fn ownModel(a: Allocator, value: cfg.Model) !cfg.Model {
    var result = value;
    result.name = try a.dupe(u8, value.name);
    if (value.reasoning_effort) |text| result.reasoning_effort = try a.dupe(u8, text);
    if (value.reasoning) |declaration| {
        var owned = declaration;
        inline for (@typeInfo(@TypeOf(declaration.map)).@"struct".field_names) |field| {
            if (@field(declaration.map, field)) |text| @field(owned.map, field) = try a.dupe(u8, text);
        }
        result.reasoning = owned;
    }
    return result;
}

fn ownConnection(a: Allocator, value: cfg.Provider) !cfg.Provider {
    var result = value;
    result.base_url = try a.dupe(u8, value.base_url);
    result.api_key_env = try a.dupe(u8, value.api_key_env);
    if (value.api_key) |key| result.api_key = try a.dupe(u8, key);
    return result;
}

fn officialContext(cache: *const metadata.Cache, entry: catalog.Entry, tokens: u32) bool {
    const official = metadata.capacityFor(cache, entry) orelse return false;
    if (official != tokens) return false;
    const index = cache.directory.find(entry.provider, entry.model.name) orelse return false;
    const row = cache.directory.rows[index];
    return row.available == true and row.tokens == tokens;
}

/// Derived capabilities belong to the exact endpoint, model and concrete wire
/// route. Always clear the preceding selection, including a frozen unknown.
pub fn applyInputThreshold(cache: *const metadata.Cache, config: *cfg.Config) void {
    config.model.input_price_threshold = null;
    config.model.input_price_flat_limit = null;
    const service = cfg.providers.Id.fromUrl(config.provider.base_url) orelse return;
    if (config.provider.kind) |hint| if (hint != service) return;
    if (config.model.protocol == .auto or config.model.protocol == .systemone) return;
    var entry = metadata.restoreEntry(cache, service, config.model.name) orelse return;
    entry.model.protocol = config.model.protocol;
    config.model.input_price_threshold = metadata.inputPriceThresholdFor(cache, entry);
    if (config.model.input_price_threshold == null) {
        config.model.input_price_flat_limit = metadata.inputPriceFlatLimitFor(cache, entry) orelse catalog.flatPriceLimit(entry);
    }
}

const Protocol = @import("../core/protocol.zig").Protocol;

/// Cache-only protocol authority; no context/output capability is required.
/// Native SystemOne endpoints never borrow the generative Zen/Go catalog.
pub fn protocolFor(config: cfg.Config, cache: *const metadata.Cache, provider_name: []const u8, raw_id: []const u8) !Protocol {
    const registry = config.registry orelse return error.DefaultProviderUnavailable;
    const provider = registry.find(provider_name) orelse return error.DefaultProviderUnavailable;
    return protocolForProvider(cache, provider, raw_id);
}

fn protocolForProvider(cache: *const metadata.Cache, provider: cfg.NamedProvider, raw_id: []const u8) !Protocol {
    const patch = provider.patchFor(raw_id);
    const explicit = if (patch) |p| p.protocol else null;
    if (cfg.providers.Id.fromSystemOneUrl(provider.connection.base_url)) |service| {
        if (provider.connection.kind) |hint| if (hint != service) return error.ProviderEndpointMismatch;
        if (explicit) |api| if (api != .systemone) return error.IncompatibleModelProtocol;
        return .systemone;
    }
    var discovered: ?Protocol = null;
    if (cfg.providers.Id.fromUrl(provider.connection.base_url)) |service| {
        if (provider.connection.kind) |hint| if (hint != service) return error.ProviderEndpointMismatch;
        if (metadata.restoreEntry(cache, service, raw_id)) |entry| discovered = entry.model.protocol;
    }
    if (explicit) |api| {
        if (discovered) |known| if (known != .auto and known != api and (known == .systemone or api == .systemone)) return error.IncompatibleModelProtocol;
        return api;
    }
    const api = discovered orelse return error.UnknownModelProtocol;
    if (api == .auto) return error.UnknownModelProtocol;
    return api;
}

const ResolvedModel = struct { connection: cfg.Provider, model: cfg.Model, official: bool };
fn resolveOne(config: cfg.Config, cache: *const metadata.Cache, provider: cfg.NamedProvider, raw_id: []const u8, historical: bool) !ResolvedModel {
    const patch = provider.patchFor(raw_id);
    if (cfg.providers.Id.fromUrl(provider.connection.base_url)) |service| {
        if (provider.connection.kind) |hint| if (hint != service) return error.ProviderEndpointMismatch;
        if (!historical and patch == null and metadata.hasDirectory(cache, service)) {
            const row = cache.directory.find(service, raw_id) orelse return error.DefaultModelUnavailable;
            if (cache.directory.rows[row].available != true) return error.DefaultModelUnavailable;
        }
        if (patch == null and metadata.restoreEntry(cache, service, raw_id) == null) return error.DefaultModelUnavailable;
    } else if (patch == null and cfg.providers.Id.fromSystemOneUrl(provider.connection.base_url) == null) return error.DefaultModelUnavailable;
    const api = try protocolForProvider(cache, provider, raw_id);
    if (api == .systemone) {
        // Neither name nor provider kind can manufacture generative capability.
        var model: cfg.Model = .{ .name = raw_id, .context_tokens = 0, .protocol = .systemone };
        if (patch) |manual| model = manual.apply(model);
        var connection = provider.connection;
        connection.base_url = cfg.providers.systemOneRoute(connection.base_url);
        var candidate = config;
        candidate.provider = connection;
        candidate.model = model;
        candidate.selection_pending = false;
        candidate.selected_provider = provider.name;
        try cfg.validate(candidate);
        return .{ .connection = connection, .model = model, .official = false };
    }
    // A service alias and kind are not authority to borrow another endpoint's
    // catalog. Only actual recognized official URLs authorize those records.
    const id = cfg.providers.Id.fromUrl(provider.connection.base_url);
    var entry: ?catalog.Entry = null;
    if (id) |service| {
        if (provider.connection.kind) |hint| if (hint != service) return error.ProviderEndpointMismatch;
        entry = metadata.restoreEntry(cache, service, raw_id);
    }
    if (entry == null and patch == null) return error.DefaultModelUnavailable;
    var model: cfg.Model = if (entry) |item| item.model else .{ .name = raw_id, .context_tokens = 0 };
    var official = false;
    if (entry) |item| {
        var route = item;
        if (patch) |manual| if (manual.protocol) |protocol| {
            route.model.protocol = protocol;
        };
        model.protocol = route.model.protocol;
        // storedEntry's generic 32768 is for display, not evidence that
        // an arbitrary discovered model has a usable window. Only an exact,
        // compatible offline preset may supply a conservative local fallback.
        model.context_tokens = 0;
        for (catalog.entries) |preset| {
            if (preset.provider == item.provider and preset.model.protocol == model.protocol and
                std.mem.eql(u8, preset.model.name, raw_id))
            {
                model.context_tokens = preset.model.context_tokens;
                break;
            }
        }
        if (metadata.contextFor(cache, route)) |capacity| {
            model.context_tokens = capacity;
            official = officialContext(cache, route, capacity);
        }
        model.reasoning = metadata.entryDeclaration(cache, route);
        model.reasoning_source = .metadata;
        model.reasoning_effort = null;
        model.output_tokens = metadata.outputFor(cache, route);
        model.output_source = .metadata;
    }
    if (patch) |manual| {
        model = manual.apply(model);
        if (manual.context_tokens != null) official = false;
    }
    // Only the current declaration authorizes auto. An archive is history, not
    // authority to probe a protocol or borrow stale request capabilities.
    if (model.protocol == .auto and (patch == null or patch.?.protocol == null)) return error.UnknownModelProtocol;
    if (model.context_tokens == 0) return error.UnknownModelContext;
    var candidate = config;
    candidate.provider = provider.connection;
    candidate.model = model;
    // Current protocol patches must precede exact-route capability lookup.
    applyInputThreshold(cache, &candidate);
    model = candidate.model;
    try cfg.validateModel(model, config.limits);
    candidate.provider = provider.connection;
    candidate.model = model;
    candidate.selection_pending = false;
    candidate.selected_provider = provider.name;
    try cfg.validate(candidate);
    return .{ .connection = provider.connection, .model = model, .official = official };
}

/// Results borrow no movable config/cache storage; allocate in an owned arena.
pub fn resolve(a: Allocator, config: cfg.Config, cache: *const metadata.Cache, provider_name: []const u8, raw_id: []const u8, historical: bool) !Selection {
    const registry = config.registry orelse return error.DefaultProviderUnavailable;
    const provider = registry.find(provider_name) orelse return error.DefaultProviderUnavailable;
    const selected = try resolveOne(config, cache, provider, raw_id, historical);
    return .{
        .connection = try ownConnection(a, selected.connection),
        .model = try ownModel(a, selected.model),
        .provider_name = try a.dupe(u8, provider_name),
        .context_official = selected.official,
    };
}

pub fn apply(config: *cfg.Config, selection: Selection) void {
    config.provider = selection.connection;
    config.model = selection.model;
    config.selected_provider = selection.provider_name;
    config.selection_pending = false;
}

pub fn applyDefault(a: Allocator, config: *cfg.Config, cache: *const metadata.Cache) !void {
    const registry = config.registry orelse return error.DefaultProviderUnavailable;
    const slash = std.mem.findScalar(u8, registry.default, '/') orelse return error.InvalidDefaultModel;
    const selection = try resolve(a, config.*, cache, registry.default[0..slash], registry.default[slash + 1 ..], false);
    apply(config, selection);
}

pub fn isUnresolved(err: anyerror) bool {
    return switch (err) {
        error.DefaultProviderUnavailable, error.DefaultModelUnavailable, error.UnknownModelProtocol, error.UnknownModelContext => true,
        else => false,
    };
}

test "official context requires an available exact directory row and compatible route" {
    var cache: metadata.Cache = .{};
    const entry = catalog.find("opencode-go/gpt-6-luna").?;
    // A static preset is a useful local fallback, never official evidence.
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens));
    const row = try cache.directory.upsert(.opencode_go, "gpt-6-luna-alias");
    row.available = true;
    row.protocol = .responses;
    row.tokens = entry.model.context_tokens;
    cache.directory_mask = metadata.bit(.opencode_go);
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens));
    const exact = try cache.directory.upsert(.opencode_go, "gpt-6-luna");
    exact.dev_present = true;
    exact.dev_protocol = .responses;
    exact.dev_context_tokens = entry.model.context_tokens;
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens));
    exact.available = true;
    exact.protocol = .responses;
    exact.tokens = entry.model.context_tokens;
    try std.testing.expect(officialContext(&cache, entry, entry.model.context_tokens));
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens - 1));
    var incompatible = entry;
    incompatible.model.protocol = .chat;
    try std.testing.expect(metadata.contextFor(&cache, incompatible) == null);
    exact.available = false;
    try std.testing.expect(!officialContext(&cache, entry, entry.model.context_tokens));
}

test "native SystemOne endpoint conflicts fail closed during declaration validation" {
    try std.testing.expectError(error.IncompatibleModelProtocol, cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"custom/reviewer","providers":{"custom":{"base_url":"http://127.0.0.1:1/v1","models":{"reviewer":{"protocol":"systemone"},"jev-is-only-a-name":{"protocol":"chat","context_tokens":32768},"unknown-jev":{}}},"native":{"base_url":"https://opencode.ai/inference/systemone/v1"},"conflict":{"base_url":"https://opencode.ai/inference/systemone/v1","models":{"reviewer":{"protocol":"responses","context_tokens":32768}}}}}}
    ));
}

test "SystemOne cache-only selection needs no capacity and imports no generative metadata" {
    var parsed = try cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"custom/reviewer","providers":{"custom":{"base_url":"http://127.0.0.1:1/v1","models":{"reviewer":{"protocol":"systemone"},"jev-is-only-a-name":{"protocol":"chat","context_tokens":32768},"unknown-jev":{}}},"native":{"base_url":"https://opencode.ai/inference/systemone/v1"},"zen":{"base_url":"https://opencode.ai/zen/v1"}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    const row = try cache.directory.upsert(.opencode_zen, "reviewer");
    row.available = true;
    row.protocol = .systemone;
    row.tokens = 200000;
    row.output_tokens = 32000;
    row.dev_protocol = .chat;
    row.dev_context_tokens = 100000;
    row.dev_input_price_threshold = 10000;
    cache.directory_mask = metadata.bit(.opencode_zen);
    for ([_][]const u8{ "custom", "native", "zen" }) |alias| {
        try std.testing.expectEqual(Protocol.systemone, try protocolFor(parsed.value, &cache, alias, "reviewer"));
        const selection = try resolve(parsed.arena.allocator(), parsed.value, &cache, alias, "reviewer", false);
        try std.testing.expectEqual(Protocol.systemone, selection.model.protocol);
        try std.testing.expectEqual(@as(u32, 0), selection.model.context_tokens);
        try std.testing.expect(selection.model.output_tokens == null);
        try std.testing.expect(selection.model.reasoning == null);
        try std.testing.expect(selection.model.input_price_threshold == null);
        try std.testing.expect(selection.model.input_price_flat_limit == null);
        try std.testing.expect(!selection.context_official);
    }
    try std.testing.expectEqual(Protocol.chat, try protocolFor(parsed.value, &cache, "custom", "jev-is-only-a-name"));
    try std.testing.expectError(error.UnknownModelProtocol, protocolFor(parsed.value, &cache, "custom", "unknown-jev"));
    row.available = false;
    try std.testing.expectError(error.DefaultModelUnavailable, resolve(parsed.arena.allocator(), parsed.value, &cache, "zen", "reviewer", false));
    row.available = true;
    const models = [_]cfg.NamedModel{.{ .name = "reviewer", .patch = .{ .protocol = .chat, .context_tokens = 32768 } }};
    const providers = [_]cfg.NamedProvider{.{ .name = "zen", .connection = .{ .base_url = "https://opencode.ai/zen/v1" }, .models = &models }};
    var conflicting = parsed.value;
    conflicting.registry = .{ .default = "zen/reviewer", .providers = &providers };
    try std.testing.expectError(error.IncompatibleModelProtocol, protocolFor(conflicting, &cache, "zen", "reviewer"));
}

test "models.dev SystemOne routes only exact Zen to native retaining alias credentials and proxy scope" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"zen/reviewer","providers":{"zen":{"base_url":"https://opencode.ai/zen/v1","kind":"opencode_zen","api_key":"fake-own-key"},"other":{"base_url":"https://opencode.ai/zen/v1","api_key":"fake-other-key"},"custom":{"base_url":"http://127.0.0.1:1/v1","models":{"reviewer":{"protocol":"systemone"}}},"lookalike":{"base_url":"https://opencode.ai.example/zen/v1","kind":"opencode_zen","models":{"reviewer":{"protocol":"systemone"}}},"go":{"base_url":"https://opencode.ai/zen/go/v1"},"native":{"base_url":"https://opencode.ai/inference/systemone/v1/","api_key_env":"OWN_FIXTURE_KEY"}}},"proxy":{"address":"127.0.0.1","port":7890,"models":["zen/reviewer"]}}
    );
    defer cfg.release(&parsed);
    const listing = try metadata.parseDev(a,
        \\{"opencode":{"models":{"reviewer":{"api":{"url":"https://opencode.ai/inference/systemone/v1"}}}},"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"reviewer":{"limit":{"context":32768}}}}}
    );
    const cache: metadata.Cache = .{ .directory = listing.directory };
    try std.testing.expectEqual(Protocol.systemone, try protocolFor(parsed.value, &cache, "zen", "reviewer"));
    const selection = try resolve(parsed.arena.allocator(), parsed.value, &cache, "zen", "reviewer", false);
    try std.testing.expectEqualStrings(cfg.providers.systemone_base_url, selection.connection.base_url);
    try std.testing.expectEqualStrings("zen", selection.provider_name);
    try std.testing.expectEqualStrings("fake-own-key", selection.connection.api_key.?);
    try std.testing.expectEqual(cfg.providers.Id.opencode_zen, selection.connection.kind.?);
    try std.testing.expectEqual(Protocol.systemone, selection.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), selection.model.context_tokens);
    try std.testing.expect(selection.model.output_tokens == null and selection.model.reasoning == null);
    try std.testing.expect(selection.model.input_price_threshold == null and selection.model.input_price_flat_limit == null);
    var candidate = parsed.value;
    apply(&candidate, selection);
    try cfg.validate(candidate);
    try std.testing.expect(candidate.proxyFor(candidate.selected_provider, candidate.model.name) != null);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1", parsed.value.registry.?.find("zen").?.connection.base_url);
    for ([_][]const u8{ "custom", "lookalike", "native" }) |alias| {
        const own = parsed.value.registry.?.find(alias).?;
        const route = try resolve(parsed.arena.allocator(), parsed.value, &cache, alias, "reviewer", false);
        try std.testing.expectEqualStrings(own.connection.base_url, route.connection.base_url);
        try std.testing.expectEqualStrings(alias, route.provider_name);
        try std.testing.expectEqualStrings(own.connection.api_key_env, route.connection.api_key_env);
        try std.testing.expectEqual(Protocol.systemone, route.model.protocol);
        try std.testing.expectEqual(@as(u32, 0), route.model.context_tokens);
        try std.testing.expect(parsed.value.proxyFor(route.provider_name, route.model.name) == null);
    }
    const other = try resolve(parsed.arena.allocator(), parsed.value, &cache, "other", "reviewer", false);
    try std.testing.expectEqualStrings("fake-other-key", other.connection.api_key.?);
    try std.testing.expectEqualStrings(cfg.providers.systemone_base_url, other.connection.base_url);
    const chat = try resolve(parsed.arena.allocator(), parsed.value, &cache, "go", "reviewer", false);
    try std.testing.expectEqual(Protocol.chat, chat.model.protocol);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", chat.connection.base_url);
    // Even a SystemOne declaration on Go must not rewrite it into Zen.
    var go_config = parsed.value;
    const go_models = [_]cfg.NamedModel{.{ .name = "separate-reviewer", .patch = .{ .protocol = .systemone } }};
    const go_providers = [_]cfg.NamedProvider{.{ .name = "go", .connection = .{ .base_url = "https://opencode.ai/zen/go/v1" }, .models = &go_models }};
    go_config.registry = .{ .default = "go/separate-reviewer", .providers = &go_providers };
    go_config.proxy = null;
    const go_route = try resolve(parsed.arena.allocator(), go_config, &cache, "go", "separate-reviewer", false);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", go_route.connection.base_url);
}

test "price proof resolves exact direct flat routes and clears on proxy protocol or raw ID changes" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"ds/deepseek-flash","providers":{"ds":{"base_url":"https://api.deepseek.com","models":{"deepseek-flash":{"protocol":"chat","context_tokens":2000000},"deepseek-flash-future":{"protocol":"chat","context_tokens":2000000}}},"proxy":{"base_url":"https://proxy.invalid/v1","kind":"deepseek","models":{"deepseek-flash":{"protocol":"chat","context_tokens":2000000}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const flat = try resolve(arena.allocator(), parsed.value, &cache, "ds", "deepseek-flash", false);
    try std.testing.expectEqual(@as(u32, 2000000), flat.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 1000000), flat.model.input_price_flat_limit);
    try std.testing.expect(flat.model.input_price_threshold == null);
    const proxy = try resolve(arena.allocator(), parsed.value, &cache, "proxy", "deepseek-flash", false);
    try std.testing.expect(proxy.model.input_price_flat_limit == null);
    const future = try resolve(arena.allocator(), parsed.value, &cache, "ds", "deepseek-flash-future", false);
    try std.testing.expect(future.model.input_price_flat_limit == null);
    var candidate = parsed.value;
    candidate.provider = flat.connection;
    candidate.model = flat.model;
    candidate.model.protocol = .responses;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expect(candidate.model.input_price_flat_limit == null);
    const row = try cache.directory.upsert(.deepseek, "deepseek-flash");
    row.dev_protocol = .chat;
    row.dev_input_price_threshold = 100000;
    candidate.model = flat.model;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, 100000), candidate.model.input_price_threshold);
    try std.testing.expect(candidate.model.input_price_flat_limit == null);
    row.dev_input_price_threshold = null;
    row.dev_input_price_flat_limit = 500000;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, 500000), candidate.model.input_price_flat_limit);
    candidate.provider = proxy.connection;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expect(candidate.model.input_price_flat_limit == null);
    try std.testing.expect(candidate.model.input_price_threshold == null);
}

test "registry resolution merges fields but never borrows identity from a custom endpoint" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"go/shared","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key_env":"FIXTURE_KEY","models":{"shared":{"context_tokens":200000}}},"custom":{"base_url":"https://custom.invalid/v1","kind":"opencode_go","models":{"shared":{"context_tokens":200000}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    const row = try cache.directory.upsert(.opencode_go, "shared");
    row.available = true;
    row.protocol = .responses;
    row.tokens = 1000000;
    row.dev_protocol = .responses;
    row.dev_output_tokens = 128000;
    row.dev_input_price_threshold = 200000;
    cache.directory_mask = metadata.bit(.opencode_go);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const selected = try resolve(arena.allocator(), parsed.value, &cache, "go", "shared", false);
    try std.testing.expectEqual(@as(u32, 200000), selected.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 128000), selected.model.output_tokens);
    try std.testing.expectEqual(.responses, selected.model.protocol);
    try std.testing.expectEqual(@as(?u32, 200000), selected.model.input_price_threshold);
    var candidate = parsed.value;
    candidate.provider = selected.connection;
    candidate.model = selected.model;
    candidate.model.protocol = .chat;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, null), candidate.model.input_price_threshold);
    candidate.model = selected.model;
    candidate.model.name = "other";
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, null), candidate.model.input_price_threshold);
    candidate.model = selected.model;
    candidate.provider = parsed.value.registry.?.find("custom").?.connection;
    applyInputThreshold(&cache, &candidate);
    try std.testing.expectEqual(@as(?u32, null), candidate.model.input_price_threshold);
    try std.testing.expect(!selected.context_official);
    try std.testing.expectError(error.UnknownModelProtocol, resolve(arena.allocator(), parsed.value, &cache, "custom", "shared", false));
    // Mutating cache ownership cannot poison an exported candidate.
    @memset(cache.directory.names[0..cache.directory.used], 'X');
    try std.testing.expectEqualStrings("shared", selected.model.name);
}

test "registry unrelated incompatible partial profile cannot poison an independently valid default" {
    var parsed = try cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"go/ready","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","models":{"ready":{"protocol":"chat","context_tokens":65536},"stale":{"reasoning":{"format":"anthropic","map":{"low":"low"}}}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    const row = try cache.directory.upsert(.opencode_go, "stale");
    row.available = true;
    row.protocol = .chat;
    row.tokens = 65536;
    cache.directory_mask = metadata.bit(.opencode_go);
    try applyDefault(parsed.arena.allocator(), &parsed.value, &cache);
    try std.testing.expectEqualStrings("ready", parsed.value.model.name);
    try std.testing.expectEqualStrings("ready", parsed.value.model.name);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.registry.?.providers[0].models.len);
}

test "registry dynamic unknown window cannot adopt a display or archived capability" {
    var parsed = try cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"go/never-a-preset","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1"}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    const row = try cache.directory.upsert(.opencode_go, "never-a-preset");
    row.available = true;
    row.protocol = .chat;
    cache.directory_mask = metadata.bit(.opencode_go);
    try std.testing.expectError(error.UnknownModelContext, applyDefault(parsed.arena.allocator(), &parsed.value, &cache));
    try std.testing.expect(parsed.value.selection_pending);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.registry.?.providers[0].models.len);
    cache.directory.count = 0;
    try std.testing.expectError(error.DefaultModelUnavailable, applyDefault(parsed.arena.allocator(), &parsed.value, &cache));
}

test "registry default may be discovered without a manual entry and explicit custom entries remain isolated" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"go/org/model","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1"},"custom":{"base_url":"https://custom.invalid/v1","models":{"org/model":{"protocol":"chat","context_tokens":65536,"output_tokens":8192}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    const row = try cache.directory.upsert(.opencode_go, "org/model");
    row.available = true;
    row.protocol = .chat;
    row.tokens = 262144;
    cache.directory_mask = metadata.bit(.opencode_go);
    try applyDefault(parsed.arena.allocator(), &parsed.value, &cache);
    try std.testing.expect(!parsed.value.selection_pending);
    try std.testing.expectEqualStrings("org/model", parsed.value.model.name);
    try std.testing.expectEqual(@as(u32, 262144), parsed.value.model.context_tokens);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const custom = try resolve(arena.allocator(), parsed.value, &cache, "custom", "org/model", false);
    try std.testing.expectEqual(@as(u32, 65536), custom.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 8192), custom.model.output_tokens);
    row.available = false;
    try std.testing.expectError(error.DefaultModelUnavailable, resolve(arena.allocator(), parsed.value, &cache, "go", "org/model", false));
    try std.testing.expectError(error.UnknownModelContext, resolve(arena.allocator(), parsed.value, &cache, "go", "org/model", true));
    // Loading an archive is independent; it cannot manufacture current send capability.
}
