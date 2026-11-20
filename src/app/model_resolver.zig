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

const Protocol = @import("../core/protocol.zig").Protocol;

/// Reject an unknown or contradictory protocol before any candidate is built.
fn validateProtocol(cache: *const metadata.Cache, provider: cfg.NamedProvider, raw_id: []const u8) !void {
    const patch = provider.patchFor(raw_id);
    const explicit = if (patch) |p| p.protocol else null;
    var discovered: ?Protocol = null;
    if (cfg.providers.Id.fromUrl(provider.connection.base_url)) |service| {
        if (provider.connection.kind) |hint| if (hint != service) return error.ProviderEndpointMismatch;
        if (metadata.restoreEntry(cache, service, raw_id)) |entry| discovered = entry.model.protocol;
    }
    if (explicit) |api| {
        if (discovered) |known| if (known != .auto and known != api) return error.IncompatibleModelProtocol;
        return;
    }
    const api = discovered orelse return error.UnknownModelProtocol;
    if (api == .auto) return error.UnknownModelProtocol;
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
    } else if (patch == null) return error.DefaultModelUnavailable;
    try validateProtocol(cache, provider, raw_id);
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
    // Codex is a Responses variant selected by provider.
    if (cfg.isCodexProvider(provider.connection) and model.protocol == .auto) model.protocol = .responses;
    // Only the current declaration authorizes auto. An archive is history, not
    // authority to probe a protocol or borrow stale request capabilities.
    if (model.protocol == .auto and (patch == null or patch.?.protocol == null)) return error.UnknownModelProtocol;
    if (model.context_tokens == 0) return error.UnknownModelContext;
    var candidate = config;
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
