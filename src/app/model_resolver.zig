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
    if (cache.directory.find(entry.provider, entry.model.name)) |index| {
        const row = cache.directory.rows[index];
        if (row.available == true) return row.tokens == tokens;
        if (row.available != null or metadata.hasDirectory(cache, entry.provider)) return false;
    }
    // Old official cache slots belong to the exact original preset route.
    for (catalog.entries) |preset| {
        if (preset.provider == entry.provider and std.mem.eql(u8, preset.model.name, entry.model.name))
            return preset.model.protocol == entry.model.protocol;
    }
    return false;
}

/// Derived capabilities belong to the exact endpoint, model and concrete wire
/// route. Always clear the preceding selection, including a frozen unknown.
pub fn applyInputThreshold(cache: *const metadata.Cache, config: *cfg.Config) void {
    config.model.input_price_threshold = null;
    const service = cfg.providers.Id.fromUrl(config.provider.base_url) orelse return;
    if (config.provider.kind) |hint| if (hint != service) return;
    if (config.model.protocol == .auto) return;
    var entry = metadata.restoreEntry(cache, service, config.model.name) orelse return;
    entry.model.protocol = config.model.protocol;
    config.model.input_price_threshold = metadata.inputPriceThresholdFor(cache, entry);
}

const ResolvedModel = struct { model: cfg.Model, official: bool };
fn resolveOne(config: cfg.Config, cache: *const metadata.Cache, provider: cfg.NamedProvider, raw_id: []const u8, historical: bool) !ResolvedModel {
    const patch = provider.patchFor(raw_id);
    // A service alias and kind are not authority to borrow another endpoint's
    // catalog. Only actual recognized official URLs authorize those records.
    const id = cfg.providers.Id.fromUrl(provider.connection.base_url);
    var entry: ?catalog.Entry = null;
    if (id) |service| {
        if (provider.connection.kind) |hint| if (hint != service) return error.ProviderEndpointMismatch;
        if (!historical and patch == null and metadata.hasDirectory(cache, service)) {
            const row = cache.directory.find(service, raw_id) orelse return error.DefaultModelUnavailable;
            if (cache.directory.rows[row].available != true) return error.DefaultModelUnavailable;
        }
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
    return .{ .model = model, .official = official };
}

/// Results borrow no movable config/cache storage; allocate in an owned arena.
pub fn resolve(a: Allocator, config: cfg.Config, cache: *const metadata.Cache, provider_name: []const u8, raw_id: []const u8, historical: bool) !Selection {
    const registry = config.registry orelse return error.DefaultProviderUnavailable;
    const provider = registry.find(provider_name) orelse return error.DefaultProviderUnavailable;
    const selected = try resolveOne(config, cache, provider, raw_id, historical);
    return .{
        .connection = try ownConnection(a, provider.connection),
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
