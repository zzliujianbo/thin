//! Official provider metadata is best-effort and bounded. No credentials or
//! response bodies are persisted. The caller owns cancellation and deadlines.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const providers = @import("../core/providers.zig");
const cfg = @import("../core/config.zig");
const catalog = @import("provider_catalog.zig");
const thinking = @import("../core/thinking.zig");
const activity = @import("../presentation/activity.zig");
const json_bound = @import("json_bound.zig");
const models_dev = @import("models_dev.zig");
const directory = @import("model_directory.zig");
const Protocol = @import("../core/protocol.zig").Protocol;

pub const file_name = "model-metadata.json";
pub const max_body_bytes = 512 * 1024;
pub const max_cache_bytes = 512 * 1024;

fn boundJson(bytes: []const u8, limit: usize) !void {
    return json_bound.bound(bytes, limit, 32768);
}
const max_tokens = 16 * 1024 * 1024;
const Tokens = [catalog.entries.len]?u32;
pub const Listing = struct {
    /// Owned byte offsets, not borrowed model IDs; safe across worker publication.
    directory: directory.Directory = .{},
    directory_mask: u8 = 0,
    tokens: Tokens = @splat(null),
    /// null means never fetched (including legacy caches); false means absent.
    available: [catalog.entries.len]?bool = @splat(null),
    reasoning: [catalog.entries.len]?thinking.Declaration = @splat(null),
    /// models.dev profiles: a usable value or null (unknown). Only meaningful when dev_done.
    dev: [catalog.entries.len]?thinking.Declaration = @splat(null),
    dev_done: bool = false,
};
pub const Cache = struct {
    directory: directory.Directory = .{},
    /// A successful official listing (even empty) supersedes offline presets.
    directory_mask: u8 = 0,
    /// Retained for legacy readers; eligibility is now driven by source timing.
    attempted: u8 = 0,
    refresh: [4]Refresh = @splat(.{}),
    tokens: Tokens = @splat(null),
    available: [catalog.entries.len]?bool = @splat(null),
    /// Official wire capability metadata supersedes models.dev profiles.
    reasoning: [catalog.entries.len]?thinking.Declaration = @splat(null),
    /// Dynamic models.dev profile; never bundled, replaced wholesale on success.
    dev_reasoning: [catalog.entries.len]?thinking.Declaration = @splat(null),
};
/// Shared cache-only resolution for interactive and headless entry. No network,
/// capacity mutation or preset capabilities; explicit user overrides stay local.
pub fn reasoningIndex(config: cfg.Config) ?usize {
    const id = providers.Id.fromUrl(config.provider.base_url) orelse return null;
    if (config.provider.kind) |hint| if (hint != id) return null;
    for (catalog.entries, 0..) |entry, index| {
        if (entry.provider != id) continue;
        if (std.mem.eql(u8, entry.model.name, config.model.name) or std.mem.eql(u8, entry.selector, config.model.name)) return index;
    }
    return null;
}

pub fn reasoningDeclaration(cache: *const Cache, config: cfg.Config, index: usize) ?thinking.Declaration {
    const actual = providers.Id.fromUrl(config.provider.base_url) orelse return null;
    if (config.provider.kind) |hint| if (hint != actual) return null;
    if (index >= catalog.entries.len or catalog.entries[index].provider != actual) return null;
    if (dynamicIndex(cache, config)) |row| return rowDeclaration(cache, config, row);
    const entry = catalog.entries[index];
    const protocol = if (config.model.protocol == .auto and cfg.chatOnly(config.provider.base_url, config.model)) .chat else config.model.protocol;
    if (protocol != entry.model.protocol) return null;
    const format: thinking.Format = if (protocol == .anthropic) .anthropic else if (entry.provider == .deepseek) .deepseek else .standard;
    for ([_]?thinking.Declaration{ cache.reasoning[index], cache.dev_reasoning[index] }) |source| {
        const declaration = source orelse continue;
        if (declaration.format != format) continue;
        declaration.validate() catch continue;
        return declaration;
    }
    return null;
}

pub fn applyReasoning(cache: *const Cache, config: *cfg.Config) void {
    if (config.model.reasoning_source == .explicit and config.model.reasoning != null) return;
    if (config.model.reasoning_source == .metadata) {
        config.model.reasoning = null;
        config.model.reasoning_effort = null;
    }
    const declaration = if (dynamicIndex(cache, config.*)) |row|
        rowDeclaration(cache, config.*, row)
    else if (reasoningIndex(config.*)) |index|
        reasoningDeclaration(cache, config.*, index)
    else
        null;
    if (declaration) |value| {
        config.model.reasoning = value;
        config.model.reasoning_source = .metadata;
    }
}

fn preset(id: providers.Id, name: []const u8) ?catalog.Entry {
    for (catalog.entries) |entry| if (entry.provider == id and std.mem.eql(u8, entry.model.name, name)) return entry;
    return null;
}

pub fn hasDirectory(cache: *const Cache, id: providers.Id) bool {
    return cache.directory_mask & bit(id) != 0;
}

fn resolvedProtocol(cache: *const Cache, index: usize) Protocol {
    const row = cache.directory.rows[index];
    if (row.protocol != .auto) return row.protocol;
    if (row.dev_protocol != .auto) return row.dev_protocol;
    if (preset(row.provider, cache.directory.name(index))) |entry| return entry.model.protocol;
    // This exact service exposes Chat Completions, not a model-name heuristic.
    if (row.provider == .deepseek) return .chat;
    return .auto;
}

fn storedEntry(cache: *const Cache, index: usize) catalog.Entry {
    const row = cache.directory.rows[index];
    const known = preset(row.provider, cache.directory.name(index));
    var entry: catalog.Entry = .{
        .provider = row.provider,
        .selector = cache.directory.selector(index),
        .model = .{
            .name = cache.directory.name(index),
            .context_tokens = if (known) |value| value.model.context_tokens else 32768,
            .protocol = resolvedProtocol(cache, index),
            .output_tokens = rowOutput(row, resolvedProtocol(cache, index)),
            .output_source = .metadata,
        },
    };
    entry.model.context_tokens = contextFor(cache, entry) orelse entry.model.context_tokens;
    return entry;
}

pub fn dynamicEntry(cache: *const Cache, id: providers.Id, name: []const u8) ?catalog.Entry {
    if (!hasDirectory(cache, id)) return null;
    const index = cache.directory.find(id, name) orelse return null;
    if (cache.directory.rows[index].available != true) return null;
    return storedEntry(cache, index);
}

pub fn findEntry(cache: *const Cache, selector: []const u8) ?catalog.Entry {
    const slash = std.mem.findScalar(u8, selector, '/') orelse return null;
    const id = providers.Id.fromSlug(selector[0..slash]) orelse return null;
    if (hasDirectory(cache, id)) return dynamicEntry(cache, id, selector[slash + 1 ..]);
    return catalog.find(selector);
}

/// Cached historical identity remains restorable after delisting. No new request
/// or protocol guessing is performed by selection restoration.
pub fn restoreEntry(cache: *const Cache, id: providers.Id, name: []const u8) ?catalog.Entry {
    if (cache.directory.find(id, name)) |index| return storedEntry(cache, index);
    return preset(id, name);
}

pub fn capacityFor(cache: *const Cache, entry: catalog.Entry) ?u32 {
    if (cache.directory.find(entry.provider, entry.model.name)) |index| {
        const row = cache.directory.rows[index];
        if (row.available == true) return row.tokens;
        // A public-only row is not an official capacity result. Until an
        // official directory succeeds, retain capacities from legacy caches.
        if (row.available != null or hasDirectory(cache, entry.provider)) return null;
    }
    for (catalog.entries, 0..) |known, index| if (known.provider == entry.provider and std.mem.eql(u8, known.model.name, entry.model.name)) return cache.tokens[index];
    return null;
}

fn validContext(n: ?u32) ?u32 {
    const value = n orelse return null;
    return if (value > 0 and value <= max_tokens) value else null;
}

/// Exact provider/raw-ID/protocol resolution. Official windows retain priority;
/// models.dev windows never populate the official capacityFor provenance slot.
/// Callers applying this to configuration must verify the actual endpoint URL;
/// provider kind or a same-name custom endpoint alone is not route identity.
/// Selection-time only: callers own freezing active/resumed model windows.
pub fn contextFor(cache: *const Cache, entry: catalog.Entry) ?u32 {
    const protocol = entry.model.protocol;
    if (protocol == .auto) return null;
    if (cache.directory.find(entry.provider, entry.model.name)) |index| {
        const row = cache.directory.rows[index];
        if (row.protocol != .auto and row.protocol != protocol) return null;
        // Legacy official capacities remain usable before official discovery,
        // but only for their original preset protocol, not a public reroute.
        if (row.available == true) {
            if (validContext(row.tokens)) |n| return n;
        } else if (row.available == null and !hasDirectory(cache, entry.provider)) {
            if (preset(entry.provider, entry.model.name)) |known| {
                if (known.model.protocol == protocol) {
                    if (validContext(capacityFor(cache, entry))) |n| return n;
                }
            }
        }
        if (row.dev_protocol == protocol) return validContext(row.dev_context_tokens);
        return null;
    }
    if (preset(entry.provider, entry.model.name)) |known| {
        if (known.model.protocol == protocol) return validContext(capacityFor(cache, entry));
    }
    return null;
}

fn validOutput(n: ?u32) ?u32 {
    const value = n orelse return null;
    return if (value > 0 and value <= 1024 * 1024) value else null;
}

fn compatibleRoute(row: directory.Record, protocol: Protocol) bool {
    return protocol != .auto and (row.protocol == .auto or row.protocol == protocol);
}

fn rowOutput(row: directory.Record, protocol: Protocol) ?u32 {
    if (!compatibleRoute(row, protocol)) return null;
    if (row.protocol == protocol) {
        if (validOutput(row.output_tokens)) |n| return n;
    }
    if (row.dev_protocol == protocol) return validOutput(row.dev_output_tokens);
    return null;
}

/// Verified exact-route capability; never infers output from context or peers.
pub fn outputFor(cache: *const Cache, entry: catalog.Entry) ?u32 {
    const index = cache.directory.find(entry.provider, entry.model.name) orelse return null;
    return rowOutput(cache.directory.rows[index], entry.model.protocol);
}

/// Independent low-price input policy capability, using the same exact raw ID
/// and concrete-route compatibility checks as outputFor. Never votes or aliases.
pub fn inputPriceThresholdFor(cache: *const Cache, entry: catalog.Entry) ?u32 {
    const index = cache.directory.find(entry.provider, entry.model.name) orelse return null;
    const row = cache.directory.rows[index];
    const api = entry.model.protocol;
    if (!compatibleRoute(row, api)) return null;
    if (row.dev_protocol != api) return null;
    return validContext(row.dev_input_price_threshold);
}

/// Shared cache-only resolver. Session owns freezing an accepted task's budget.
pub fn applyOutput(cache: *const Cache, config: *cfg.Config) void {
    if (config.model.output_source == .explicit and config.model.output_tokens != null) return;
    if (config.model.output_source == .metadata) config.model.output_tokens = null;
    // Unlike a manually selected official catalog entry, a configured route
    // must prove the actual URL identity; kind alone is only a hint.
    const id = providers.Id.fromUrl(config.provider.base_url) orelse return;
    if (config.provider.kind) |hint| if (hint != id) return;
    const index = dynamicIndex(cache, config.*) orelse return;
    const protocol = if (config.model.protocol == .auto and cfg.chatOnly(config.provider.base_url, config.model)) .chat else config.model.protocol;
    if (rowOutput(cache.directory.rows[index], protocol)) |n| {
        config.model.output_tokens = n;
        config.model.output_source = .metadata;
    }
}

fn dynamicIndex(cache: *const Cache, config: cfg.Config) ?usize {
    const id = providers.Id.fromUrl(config.provider.base_url) orelse return null;
    if (config.provider.kind) |hint| if (hint != id) return null;
    if (cache.directory.find(id, config.model.name)) |index| return index;
    const prefix = id.slug();
    if (std.mem.startsWith(u8, config.model.name, prefix) and config.model.name.len > prefix.len and config.model.name[prefix.len] == '/')
        return cache.directory.find(id, config.model.name[prefix.len + 1 ..]);
    return null;
}

fn rowDeclaration(cache: *const Cache, config: cfg.Config, index: usize) ?thinking.Declaration {
    const row = cache.directory.rows[index];
    const protocol = if (config.model.protocol == .auto and cfg.chatOnly(config.provider.base_url, config.model)) .chat else config.model.protocol;
    if (protocol == .auto) return null;
    const format: thinking.Format = if (protocol == .anthropic) .anthropic else if (row.provider == .deepseek) .deepseek else .standard;
    if (row.available == null and !hasDirectory(cache, row.provider)) {
        // Public discovery may arrive before (or without) official discovery.
        // Its row must not shadow a compatible, last-successful official map,
        // even when the public SDK disagrees with the verified legacy route.
        for (catalog.entries, 0..) |entry, legacy| {
            if (entry.provider != row.provider or entry.model.protocol != protocol or !std.mem.eql(u8, entry.model.name, cache.directory.name(index))) continue;
            if (cache.reasoning[legacy]) |declaration| {
                if (declaration.format != format) continue;
                declaration.validate() catch continue;
                return declaration;
            }
        }
    }
    if (protocol != resolvedProtocol(cache, index)) return null;
    if (row.reasoning) |profile| {
        var declaration = profile.declaration();
        // Official supported_levels describe logical levels; wire format can
        // become known later from the independent exact models.dev adapter.
        if (row.protocol == .auto and declaration.format != format) {
            declaration.format = format;
            if (declaration.map.off != null) declaration.map.off = switch (format) {
                .standard => "none",
                .deepseek => "off",
                .anthropic => "disabled",
            };
        }
        if (declaration.format == format) {
            declaration.validate() catch return null;
            return declaration;
        }
    }
    if (row.dev_reasoning) |profile| {
        const declaration = profile.declaration();
        if (declaration.format == format) {
            declaration.validate() catch return null;
            return declaration;
        }
    }
    // Legacy preset resolutions also carry complete-profile fallback when the
    // exact provider row is absent from the public catalog.
    for (catalog.entries, 0..) |entry, legacy| {
        if (entry.provider != row.provider or entry.model.protocol != protocol or !std.mem.eql(u8, entry.model.name, cache.directory.name(index))) continue;
        if (cache.dev_reasoning[legacy]) |declaration| {
            if (declaration.format != format) continue;
            declaration.validate() catch continue;
            return declaration;
        }
    }
    return null;
}

pub fn entryDeclaration(cache: *const Cache, entry: catalog.Entry) ?thinking.Declaration {
    const config: cfg.Config = .{ .provider = catalog.connection(entry.provider), .model = entry.model };
    if (dynamicIndex(cache, config)) |index| return rowDeclaration(cache, config, index);
    if (reasoningIndex(config)) |index| return reasoningDeclaration(cache, config, index);
    return null;
}

/// Merge only a joined provider's owned result. Credential filtering still
/// happens at publication/commit, independently for each provider.
pub fn mergeOfficial(target: *Listing, source: *const Listing, id: providers.Id) !void {
    // A source that overflows the shared pool must not consume its capacity or
    // partially overwrite records belonging to other successful provider jobs.
    var merged = target.directory;
    for (source.directory.rows[0..source.directory.count], 0..) |row, i| {
        if (row.provider != id) continue;
        const old = if (merged.find(id, source.directory.name(i))) |index| merged.rows[index] else null;
        try merged.copyRecord(&source.directory, i);
        if (old) |previous| {
            const dest = &merged.rows[merged.find(id, source.directory.name(i)).?];
            dest.dev_protocol = previous.dev_protocol;
            dest.dev_reasoning = previous.dev_reasoning;
            dest.dev_output_tokens = previous.dev_output_tokens;
            dest.dev_context_tokens = previous.dev_context_tokens;
            dest.dev_input_price_threshold = previous.dev_input_price_threshold;
            dest.dev_present = previous.dev_present;
        }
    }
    target.directory = merged;
    for (catalog.entries, 0..) |entry, i| if (entry.provider == id) {
        target.tokens[i] = source.tokens[i];
        target.available[i] = source.available[i];
        target.reasoning[i] = source.reasoning[i];
    };
    target.directory_mask |= source.directory_mask & bit(id);
}

pub fn mergeDev(target: *Listing, source: *const Listing) !void {
    if (!source.dev_done) return;
    var merged = target.directory;
    for (merged.rows[0..merged.count]) |*row| {
        row.dev_protocol = .auto;
        row.dev_reasoning = null;
        row.dev_output_tokens = null;
        row.dev_context_tokens = null;
        row.dev_input_price_threshold = null;
        row.dev_present = false;
    }
    for (source.directory.rows[0..source.directory.count], 0..) |source_row, index| {
        if (!source_row.dev_present) continue;
        const row = try merged.upsert(source_row.provider, source.directory.name(index));
        row.dev_protocol = source_row.dev_protocol;
        row.dev_reasoning = source_row.dev_reasoning;
        row.dev_output_tokens = source_row.dev_output_tokens;
        row.dev_context_tokens = source_row.dev_context_tokens;
        row.dev_input_price_threshold = source_row.dev_input_price_threshold;
        row.dev_present = true;
    }
    target.directory = merged;
    target.dev = source.dev;
    target.dev_done = true;
}

pub const Generations = [4]u64;
pub const Claim = struct { cache: Cache, mask: u8, generations: Generations };
pub const Commit = struct { cache: Cache, accepted: u8 };
pub const max_generation: u64 = std.math.maxInt(i64);

pub const dev_bit: u8 = 0x80;
pub const provider_mask: u8 = all_mask;

pub fn bit(id: providers.Id) u8 {
    return @as(u8, 1) << @intCast(@backingInt(id));
}
const all_mask: u8 = blk: {
    var mask: u8 = 0;
    for (providers.Id.all) |id| mask |= bit(id);
    break :blk mask;
};

fn capacity(value: std.json.Value) !?u32 {
    return switch (value) {
        .null => null,
        .integer => |n| if (n > 0 and n <= max_tokens) @intCast(n) else error.InvalidMetadata,
        else => error.InvalidMetadata,
    };
}

fn parseEffort(value: std.json.Value, provider: providers.Id, protocol: @import("../core/protocol.zig").Protocol) !?thinking.Declaration {
    if (value != .object or protocol == .auto) return error.InvalidMetadata;
    const supported = value.object.get("supported_levels") orelse return error.InvalidMetadata;
    if (supported != .array or supported.array.items.len > 16) return error.InvalidMetadata;
    if (supported.array.items.len == 0) return null;
    const format: thinking.Format = if (protocol == .anthropic) .anthropic else if (provider == .deepseek) .deepseek else .standard;
    var map: thinking.LevelMap = .{};
    if (format == .deepseek) map.off = "off";
    var mapped: usize = 0;
    var seen: [16][]const u8 = undefined;
    var seen_count: usize = 0;
    for (supported.array.items) |item| {
        if (item != .string or item.string.len == 0 or item.string.len > 32) return error.InvalidMetadata;
        for (seen[0..seen_count]) |previous| if (std.mem.eql(u8, previous, item.string)) return error.InvalidMetadata;
        seen[seen_count] = item.string;
        seen_count += 1;
        const level = activity.ReasoningEffort.fromName(item.string);
        switch (level.canonical()) {
            .off => {
                map.off = if (format == .anthropic) "disabled" else if (format == .deepseek) "off" else if (std.mem.eql(u8, item.string, "off")) "off" else "none";
                mapped += 1;
            },
            .minimal => {
                map.minimal = "minimal";
                mapped += 1;
            },
            .low => {
                map.low = "low";
                mapped += 1;
            },
            .medium => {
                map.medium = "medium";
                mapped += 1;
            },
            .high => {
                map.high = "high";
                mapped += 1;
            },
            .xhigh => {
                map.xhigh = "xhigh";
                mapped += 1;
            },
            .max => {
                map.max = "max";
                mapped += 1;
            },
            else => {}, // Unknown provider-specific levels are not exposed as effort choices.
        }
    }
    if (mapped == 0) return null;
    const declaration: thinking.Declaration = .{ .format = format, .map = map };
    try declaration.validate();
    return declaration;
}

/// Only context_window denotes the total context; no input/output heuristic.
/// Legacy capacity-array view; parseListing also retains all discovered IDs.
pub fn parseProvider(a: std.mem.Allocator, body: []const u8, id: providers.Id) !Tokens {
    return (try parseListing(a, body, id)).tokens;
}

pub fn parseListing(a: std.mem.Allocator, body: []const u8, id: providers.Id) !Listing {
    try boundJson(body, max_body_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_body_bytes });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMetadata;
    if (parsed.value.object.get("object")) |kind| {
        if (kind != .string or !std.mem.eql(u8, kind.string, "list")) return error.InvalidMetadata;
    }
    const data = parsed.value.object.get("data") orelse return error.InvalidMetadata;
    if (data != .array or data.array.items.len > 512) return error.InvalidMetadata;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var result: Listing = .{ .directory_mask = bit(id) };
    for (catalog.entries, 0..) |model, i| {
        if (model.provider == id) result.available[i] = false;
    }
    for (data.array.items) |record| {
        if (record != .object) return error.InvalidMetadata;
        const name = record.object.get("id") orelse return error.InvalidMetadata;
        if (name != .string or name.string.len == 0 or name.string.len > 256) return error.InvalidMetadata;
        for (name.string) |c| if (c < 0x20 or c == 0x7f) return error.InvalidMetadata;
        const entry = try seen.getOrPut(a, name.string);
        if (entry.found_existing) return error.InvalidMetadata;
        const n = if (record.object.get("context_window")) |v| try capacity(v) else null;
        const row = try result.directory.upsert(id, name.string);
        row.available = true;
        row.tokens = n;
        if (record.object.get("protocol")) |v| {
            if (v == .string) row.protocol = std.meta.stringToEnum(Protocol, v.string) orelse .auto;
        }
        const known = preset(id, name.string);
        const protocol: Protocol = if (row.protocol != .auto) row.protocol else if (known) |value| value.model.protocol else if (id == .deepseek) .chat else .auto;
        if (record.object.get("effort")) |effort| {
            if (try parseEffort(effort, id, if (protocol == .auto) .chat else protocol)) |declaration| row.reasoning = try directory.Profile.from(declaration);
        }
        for (catalog.entries, 0..) |model, i| {
            if (model.provider == id and std.mem.eql(u8, model.model.name, name.string)) {
                result.tokens[i] = n;
                result.available[i] = true;
                if (record.object.get("effort")) |effort| result.reasoning[i] = try parseEffort(effort, id, model.model.protocol);
            }
        }
    }
    return result;
}

/// Isolated client, fixed official URL, no redirects or credential discovery.
/// The borrowed caller key is not mutated; the owned header copy is wiped.
pub fn fetch(a: std.mem.Allocator, io: std.Io, id: providers.Id, key: ?[]const u8) !Listing {
    const body = try fetchUrl(a, io, listingUrl(id), listingKey(id, key), max_body_bytes);
    defer a.free(body);
    return parseListing(a, body, id);
}

/// Public catalog: no credentials and no provider listing key. Parsing is the
/// same bounded models.dev parser used by tests; unusable profiles stay unknown.
pub fn fetchDev(a: std.mem.Allocator, io: std.Io) !Listing {
    const body = try fetchUrl(a, io, models_dev.url, null, models_dev.max_body_bytes);
    defer a.free(body);
    return parseDev(a, body);
}

pub fn parseDev(a: std.mem.Allocator, body: []const u8) !Listing {
    const resolved = try models_dev.parse(a, body);
    var result: Listing = .{ .dev_done = true, .directory = try models_dev.parseDirectory(a, body) };
    for (resolved, 0..) |value, index| result.dev[index] = value.declaration;
    return result;
}

fn listingUrl(id: providers.Id) []const u8 {
    return switch (id) {
        .deepseek => comptime providers.Id.deepseek.baseUrl() ++ "/models",
        .opencode_go => "https://opencode.ai/inference/go/v1/models",
        .opencode_zen => "https://opencode.ai/inference/v1/models",
    };
}

fn listingKey(id: providers.Id, key: ?[]const u8) ?[]const u8 {
    // OpenCode's official listing endpoints are public, not inference calls.
    return if (id == .deepseek) key else null;
}

/// Private transport seam for owned loopback tests. Production callers can only
/// reach it through fetch's fixed official endpoint, never through user URLs.
fn fetchUrl(a: std.mem.Allocator, io: std.Io, url: []const u8, key: ?[]const u8, limit: usize) ![]u8 {
    var credentials: providers.Credentials = .{};
    if (key) |k| credentials.set(.deepseek, k);
    try credentials.validate();
    const authorization = if (key) |k| try std.fmt.allocPrint(a, "Bearer {s}", .{k}) else null;
    defer if (authorization) |header| {
        std.crypto.secureZero(u8, header);
        a.free(header);
    };
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (authorization) |header| .{ .override = header } else .omit,
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = "ThinAgent-metadata-check/1.0" },
        },
        .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
    });
    defer request.deinit();
    try request.sendBodiless();
    var head: [8192]u8 = undefined;
    var response = try request.receiveHead(&head);
    if (response.head.status != .ok) return error.MetadataHttpStatus;
    if (response.head.content_length) |size| if (size > limit) return error.MetadataTooLarge;
    var transfer: [8192]u8 = undefined;
    const body = try response.reader(&transfer).allocRemaining(a, .limited(limit));
    errdefer a.free(body);
    switch (request.reader.state) {
        .body_remaining_content_length, .body_remaining_chunk_len => return error.IncompleteMetadata,
        else => {},
    }
    return body;
}

const Record = struct {
    selector: []const u8,
    context_window: ?u32,
    available: ?bool = null,
    reasoning: ?thinking.Declaration = null,
    dev_reasoning: ?thinking.Declaration = null,
};
const DynamicRecord = struct {
    provider: providers.Id,
    id: []const u8,
    context_window: ?u32 = null,
    output_tokens: ?u32 = null,
    dev_output_tokens: ?u32 = null,
    dev_context_tokens: ?u32 = null,
    dev_input_price_threshold: ?u32 = null,
    available: ?bool = null,
    protocol: Protocol = .auto,
    dev_protocol: Protocol = .auto,
    reasoning: ?thinking.Declaration = null,
    dev_reasoning: ?thinking.Declaration = null,
    dev_present: bool = false,
};
pub const max_timestamp_ms: u64 = 253402300799999;
pub const Policy = struct {
    ttl_ms: u32 = 14400000,
    cooldown_ms: u32 = 300000,
};
pub const Refresh = struct {
    generation: u64 = 0,
    last_attempt_ms: ?u64 = null,
    last_success_ms: ?u64 = null,
    successful: bool = false,
};
const source_bits = [_]u8{ 1, 2, 4, dev_bit };

pub fn wallNow(io: std.Io) u64 {
    return @intCast(@max(0, @min(max_timestamp_ms, std.Io.Clock.real.now(io).toMilliseconds())));
}

/// Future timestamps are due for one repair claim. That claim resets the future
/// success and persists the current clock, preventing both storms and starvation.
pub fn eligible(cache: *const Cache, requested: u8, now: u64, policy: Policy) u8 {
    var mask: u8 = 0;
    for (source_bits, cache.refresh) |source, timing| {
        if (requested & source == 0) continue;
        const attempt = timing.last_attempt_ms orelse {
            mask |= source;
            continue;
        };
        const success = timing.last_success_ms;
        if (attempt > now or (success != null and success.? > now)) {
            mask |= source;
            continue;
        }
        const base = if (timing.successful and success != null) success.? else attempt;
        const delay = if (timing.successful and success != null) policy.ttl_ms else policy.cooldown_ms;
        if (now - base >= delay) mask |= source;
    }
    return mask;
}

const Document = struct {
    version: u32,
    attempted: u8,
    records: []const Record,
    directory_mask: u8 = 0,
    models: []const DynamicRecord = &.{},
    refresh: [4]Refresh = @splat(.{}),
};

fn canonicalCacheDeclaration(declaration: thinking.Declaration) !thinking.Declaration {
    try declaration.validate();
    var result = declaration;
    if (declaration.map.off) |value| {
        result.map.off = switch (declaration.format) {
            .deepseek => if (std.mem.eql(u8, value, "off")) "off" else return error.InvalidMetadata,
            .anthropic => if (std.mem.eql(u8, value, "disabled")) "disabled" else return error.InvalidMetadata,
            .standard => if (std.mem.eql(u8, value, "none")) "none" else if (std.mem.eql(u8, value, "off")) "off" else return error.InvalidMetadata,
        };
    }
    inline for (.{ "minimal", "low", "medium", "high", "xhigh", "max" }) |field| {
        if (@field(declaration.map, field)) |value| {
            if (!std.mem.eql(u8, value, field)) return error.InvalidMetadata;
            @field(result.map, field) = field;
        }
    }
    return result;
}

fn parseCache(a: std.mem.Allocator, bytes: []const u8) !Cache {
    try json_bound.bound(bytes, max_cache_bytes, 131072);
    var parsed = try std.json.parseFromSlice(Document, a, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_cache_bytes });
    defer parsed.deinit();
    const doc = parsed.value;
    // Typed JSON integer parsing also accepts numeric strings. Cache capability
    // fields deliberately require JSON integer tokens, not that coercion.
    if (doc.version >= 6) {
        var raw = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_cache_bytes });
        defer raw.deinit();
        if (raw.value == .object) {
            if (raw.value.object.get("refresh")) |timings| {
                if (timings != .array or timings.array.items.len != 4) return error.InvalidMetadata;
                for (timings.array.items) |timing| {
                    if (timing != .object) return error.InvalidMetadata;
                    if (doc.version >= 9) if (timing.object.get("generation")) |value| switch (value) {
                        .integer => |n| if (n < 0 or n > max_generation) return error.InvalidMetadata,
                        else => return error.InvalidMetadata,
                    };
                    for ([_][]const u8{ "last_attempt_ms", "last_success_ms" }) |key| {
                        if (timing.object.get(key)) |value| switch (value) {
                            .null => {},
                            .integer => |n| if (n < 0 or n > max_timestamp_ms) return error.InvalidMetadata,
                            else => return error.InvalidMetadata,
                        };
                    }
                }
            }
            if (raw.value.object.get("models")) |models| {
                if (models == .array) for (models.array.items) |model| {
                    if (model != .object) return error.InvalidMetadata;
                    for ([_][]const u8{ "output_tokens", "dev_output_tokens" }) |key| {
                        if (model.object.get(key)) |value| switch (value) {
                            .null => {},
                            .integer => |n| if (n <= 0 or n > 1024 * 1024) return error.InvalidMetadata,
                            else => return error.InvalidMetadata,
                        };
                    }
                    if (doc.version >= 10) {
                        if (model.object.get("dev_input_price_threshold")) |value| switch (value) {
                            .null => {},
                            .integer => |n| if (n <= 0 or n > max_tokens) return error.InvalidMetadata,
                            else => return error.InvalidMetadata,
                        };
                    }
                    if (doc.version >= 7) {
                        if (model.object.get("dev_context_tokens")) |value| switch (value) {
                            .null => {},
                            .integer => |n| if (n <= 0 or n > max_tokens) return error.InvalidMetadata,
                            else => return error.InvalidMetadata,
                        };
                    }
                };
            }
        }
    }
    if ((doc.version < 1 or doc.version > 10) or doc.attempted & ~(all_mask | dev_bit) != 0 or doc.records.len > catalog.entries.len or doc.models.len > directory.max_models or doc.directory_mask & ~all_mask != 0) return error.InvalidMetadata;
    if (doc.version < 5 and (doc.directory_mask != 0 or doc.models.len != 0)) return error.InvalidMetadata;
    // Legacy caches never attempted dynamic discovery. Retain their successful
    // metadata, but permit one automatic directory/protocol refresh after upgrade.
    var result: Cache = .{ .attempted = if (doc.version < 5) 0 else doc.attempted, .directory_mask = doc.directory_mask };
    if (doc.version >= 8) result.refresh = doc.refresh;
    if (doc.version < 9) for (&result.refresh) |*timing| {
        timing.generation = 0;
    };
    // v8/v9 had refresh timing but lacked input price thresholds. Permit one
    // public claim without resetting ANY existing generation: no ABA.
    if (doc.version >= 8 and doc.version < 10) {
        result.attempted &= ~dev_bit;
        result.refresh[3].last_attempt_ms = null;
    }
    // v5 lacked output and v6 lacked public context. Grant one public refresh
    // for either upgrade, preserving successful official and v6 output metadata.
    // claim persists v10 timing/generations before fetching, so failures observe cooldown.
    if (doc.version == 5 or doc.version == 6) result.attempted &= ~dev_bit;
    for (doc.models) |record| {
        if (record.context_window) |n| if (n == 0 or n > max_tokens) return error.InvalidMetadata;
        if (result.directory.find(record.provider, record.id) != null) return error.InvalidMetadata;
        const row = try result.directory.upsert(record.provider, record.id);
        row.tokens = record.context_window;
        if (doc.version >= 7) row.dev_context_tokens = record.dev_context_tokens;
        if (doc.version >= 10) row.dev_input_price_threshold = record.dev_input_price_threshold;
        if (doc.version >= 6) {
            if (record.output_tokens != null and validOutput(record.output_tokens) == null) return error.InvalidMetadata;
            if (record.dev_output_tokens != null and validOutput(record.dev_output_tokens) == null) return error.InvalidMetadata;
            row.output_tokens = record.output_tokens;
            row.dev_output_tokens = record.dev_output_tokens;
        }
        row.available = record.available;
        row.protocol = record.protocol;
        row.dev_protocol = record.dev_protocol;
        row.dev_present = record.dev_present;
        if (record.reasoning) |declaration| row.reasoning = try directory.Profile.from(try canonicalCacheDeclaration(declaration));
        if (record.dev_reasoning) |declaration| row.dev_reasoning = try directory.Profile.from(try canonicalCacheDeclaration(declaration));
    }
    var seen: [catalog.entries.len]bool = @splat(false);
    for (doc.records) |record| {
        if (record.context_window) |n| if (n == 0 or n > max_tokens) return error.InvalidMetadata;
        const index = for (catalog.entries, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.selector, record.selector)) break i;
        } else return error.InvalidMetadata;
        if (seen[index]) return error.InvalidMetadata;
        seen[index] = true;
        result.tokens[index] = record.context_window;
        if (doc.version >= 2) result.available[index] = record.available;
        if (doc.version >= 3) {
            if (record.reasoning) |declaration| {
                result.reasoning[index] = try canonicalCacheDeclaration(declaration);
            }
        }
        if (doc.version >= 4) {
            if (record.dev_reasoning) |declaration| {
                result.dev_reasoning[index] = try canonicalCacheDeclaration(declaration);
            }
        }
    }
    return result;
}

/// Anchored, no-follow, nonblocking open; reject nonregular files before reading.
pub fn load(root: *fs.Root) !Cache {
    const fd = fs.linux.openat(root.dir.handle, file_name, fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0);
    if (fd < 0) {
        if (std.c._errno().* == 2) return .{};
        return fs.osError();
    }
    defer fs.closeFd(fd);
    const file = fs.fileFromFd(fd);
    const stat = try file.stat(root.io);
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > max_cache_bytes) return error.MetadataTooLarge;
    const buffer = try root.allocator.alloc(u8, max_cache_bytes + 1);
    defer root.allocator.free(buffer);
    const len = try file.readPositionalAll(root.io, buffer, 0);
    if (len > max_cache_bytes) return error.MetadataTooLarge;
    if (len != stat.size) return error.FileChanged;
    return parseCache(root.allocator, buffer[0..len]);
}

fn lock(root: *fs.Root) !c_int {
    const fd = try fs.openDirectory(root.dir.handle, ".");
    errdefer fs.closeFd(fd);
    for (0..100) |_| {
        if (fs.linux.flock(fd, 2 | 4) == 0) return fd;
        const errno = std.c._errno().*;
        if (errno != 11 and errno != 4) return fs.osError();
        try std.Io.sleep(root.io, .fromMilliseconds(2), .awake);
    }
    return error.MetadataStoreBusy;
}

fn save(root: *fs.Root, cache: Cache) !void {
    for (cache.refresh) |timing| if (timing.generation > max_generation) return error.InvalidMetadata;
    for (cache.directory.rows[0..cache.directory.count]) |row| {
        if (row.dev_context_tokens != null and validContext(row.dev_context_tokens) == null) return error.InvalidMetadata;
        if (row.dev_input_price_threshold != null and validContext(row.dev_input_price_threshold) == null) return error.InvalidMetadata;
        if (row.output_tokens != null and validOutput(row.output_tokens) == null) return error.InvalidMetadata;
        if (row.dev_output_tokens != null and validOutput(row.dev_output_tokens) == null) return error.InvalidMetadata;
    }
    var records: [catalog.entries.len]Record = undefined;
    for (catalog.entries, 0..) |entry, i| records[i] = .{
        .selector = entry.selector,
        .context_window = cache.tokens[i],
        .available = cache.available[i],
        .reasoning = cache.reasoning[i],
        .dev_reasoning = cache.dev_reasoning[i],
    };
    const models = try root.allocator.alloc(DynamicRecord, cache.directory.count);
    defer root.allocator.free(models);
    for (cache.directory.rows[0..cache.directory.count], 0..) |row, index| models[index] = .{
        .provider = row.provider,
        .id = cache.directory.name(index),
        .context_window = row.tokens,
        .output_tokens = row.output_tokens,
        .dev_output_tokens = row.dev_output_tokens,
        .dev_context_tokens = row.dev_context_tokens,
        .dev_input_price_threshold = row.dev_input_price_threshold,
        .available = row.available,
        .protocol = row.protocol,
        .dev_protocol = row.dev_protocol,
        .reasoning = if (row.reasoning) |profile| profile.declaration() else null,
        .dev_reasoning = if (row.dev_reasoning) |profile| profile.declaration() else null,
        .dev_present = row.dev_present,
    };
    const bytes = try root.allocator.alloc(u8, max_cache_bytes);
    defer root.allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try std.json.Stringify.value(Document{ .version = 10, .attempted = cache.attempted, .records = &records, .directory_mask = cache.directory_mask, .models = models, .refresh = cache.refresh }, .{}, &writer);
    try writer.writeByte('\n');
    try root.writeMode(file_name, bytes[0..writer.end], true, 0o600);
}

/// Persist the attempt before network work, even if the worker later fails.
pub fn claim(root: *fs.Root, requested: u8, manual: bool) !Claim {
    return claimAt(root, requested, manual, wallNow(root.io), .{});
}

pub fn claimAt(root: *fs.Root, requested: u8, manual: bool, now: u64, policy: Policy) !Claim {
    if (now > max_timestamp_ms) return error.InvalidMetadata;
    if (requested & ~(all_mask | dev_bit) != 0) return error.InvalidMetadata;
    const fd = try lock(root);
    defer fs.closeFd(fd);
    var cache = try load(root);
    const mask = if (manual) requested else eligible(&cache, requested, now, policy);
    if (mask != 0) {
        cache.attempted |= mask;
        for (source_bits, &cache.refresh) |source, *timing| {
            if (mask & source == 0) continue;
            if (timing.last_success_ms) |success| if (success > now) {
                timing.last_success_ms = null;
            };
            if (timing.generation == max_generation) return error.MetadataGenerationExhausted;
            timing.generation += 1;
            timing.last_attempt_ms = now;
            timing.successful = false;
        }
        try save(root, cache);
    }
    var generations: Generations = undefined;
    for (cache.refresh, 0..) |timing, i| generations[i] = timing.generation;
    return .{ .cache = cache, .mask = mask, .generations = generations };
}

/// Reload under lock: unsuccessful providers and attempt flags remain intact.
pub fn commit(root: *fs.Root, succeeded: u8, listing: Listing) !Cache {
    return commitAt(root, succeeded, listing, wallNow(root.io));
}

pub fn commitAt(root: *fs.Root, succeeded: u8, listing: Listing, now: u64) !Cache {
    if (now > max_timestamp_ms) return error.InvalidMetadata;
    if (succeeded & ~all_mask != 0) return error.InvalidMetadata;
    const fd = try lock(root);
    defer fs.closeFd(fd);
    return commitLocked(root, try load(root), succeeded, listing, now);
}

/// Production publication: reject obsolete source results before any mutation.
/// Official and public claims are independent, including same-millisecond claims.
pub fn commitClaimedAt(root: *fs.Root, succeeded: u8, listing: Listing, generations: Generations, now: u64) !Commit {
    if (now > max_timestamp_ms or succeeded & ~all_mask != 0) return error.InvalidMetadata;
    const fd = try lock(root);
    defer fs.closeFd(fd);
    const cache = try load(root);
    var accepted = succeeded | (if (listing.dev_done) dev_bit else @as(u8, 0));
    for (source_bits, cache.refresh, generations) |source, timing, expected| {
        if (expected == 0 or timing.generation != expected) accepted &= ~source;
    }
    var filtered = listing;
    filtered.dev_done = accepted & dev_bit != 0;
    return .{ .cache = try commitLocked(root, cache, accepted & all_mask, filtered, now), .accepted = accepted };
}

fn commitLocked(root: *fs.Root, previous: Cache, succeeded: u8, listing: Listing, now: u64) !Cache {
    var cache = previous;
    for (catalog.entries, 0..) |entry, i| {
        if (succeeded & bit(entry.provider) == 0) continue;
        if (listing.tokens[i]) |n| if (n == 0 or n > max_tokens) return error.InvalidMetadata;
        cache.tokens[i] = listing.tokens[i];
        cache.available[i] = listing.available[i];
        cache.reasoning[i] = listing.reasoning[i];
    }
    const refreshed = succeeded & listing.directory_mask;
    for (cache.directory.rows[0..cache.directory.count]) |*row| {
        if (refreshed & bit(row.provider) != 0) {
            row.available = false;
            row.tokens = null;
            row.output_tokens = null;
            row.protocol = .auto;
            row.reasoning = null;
        }
        if (listing.dev_done) {
            row.dev_protocol = .auto;
            row.dev_reasoning = null;
            row.dev_output_tokens = null;
            row.dev_context_tokens = null;
            row.dev_input_price_threshold = null;
            row.dev_present = false;
        }
    }
    for (listing.directory.rows[0..listing.directory.count], 0..) |source, index| {
        const official = refreshed & bit(source.provider) != 0 and source.available == true;
        if (!official and !(listing.dev_done and source.dev_present)) continue;
        const row = try cache.directory.upsert(source.provider, listing.directory.name(index));
        if (official) {
            row.available = source.available;
            row.tokens = source.tokens;
            row.output_tokens = source.output_tokens;
            row.protocol = source.protocol;
            row.reasoning = source.reasoning;
        }
        if (listing.dev_done and source.dev_present) {
            row.dev_protocol = source.dev_protocol;
            row.dev_reasoning = source.dev_reasoning;
            row.dev_output_tokens = source.dev_output_tokens;
            row.dev_context_tokens = source.dev_context_tokens;
            row.dev_input_price_threshold = source.dev_input_price_threshold;
            row.dev_present = true;
        }
    }
    cache.directory_mask |= refreshed;
    if (listing.dev_done) cache.dev_reasoning = listing.dev;
    for (source_bits, &cache.refresh) |source, *timing| {
        if ((succeeded | (if (listing.dev_done) dev_bit else @as(u8, 0))) & source == 0) continue;
        timing.last_success_ms = now;
        timing.successful = true;
    }
    if (succeeded != 0 or listing.dev_done) try save(root, cache);
    return cache;
}

test "metadata lexical limits precede allocation and respect quoted escapes" {
    const a = std.testing.allocator;
    var buffer: [2048]u8 = undefined;
    for ([_]usize{ 31, 32 }) |levels| {
        var w = std.Io.Writer.fixed(&buffer);
        try w.writeAll("{\"data\":[],\"unknown\":");
        for (0..levels) |_| try w.writeByte('[');
        try w.writeAll("null");
        for (0..levels) |_| try w.writeByte(']');
        try w.writeByte('}');
        if (levels == 31) {
            _ = try parseProvider(a, buffer[0..w.end], .deepseek);
        } else {
            // A zero-capacity allocator proves this rejects before JSON allocation.
            var fixed = std.heap.FixedBufferAllocator.init(&.{});
            try std.testing.expectError(error.MetadataTooDeep, parseProvider(fixed.allocator(), buffer[0..w.end], .deepseek));
            try std.testing.expectError(error.MetadataTooDeep, parseCache(fixed.allocator(), buffer[0..w.end]));
        }
    }
    const quoted =
        \\{"data":[],"extra":{"text":"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\\\"{}","next":true}}
    ;
    _ = try parseProvider(a, quoted, .deepseek);
    try std.testing.expectError(error.DuplicateField, parseProvider(a, "{\"data\":[],\"extra\":{\"x\":1,\"x\":2}}", .deepseek));
    try std.testing.expectError(error.DuplicateField, parseCache(a, "{\"version\":1,\"version\":1,\"attempted\":0,\"records\":[]}"));
    try std.testing.expectError(error.InvalidMetadata, boundJson("{\"x\":\"unterminated", max_body_bytes));
    try std.testing.expectError(error.InvalidMetadata, boundJson("{]", max_body_bytes));
    const many = try a.alloc(u8, 2 * 32768 + 1);
    defer a.free(many);
    many[0] = '[';
    for (0..32768) |i| {
        many[1 + 2 * i] = '0';
        many[2 + 2 * i] = if (i == 32767) ']' else ',';
    }
    many[many.len - 3] = ']';
    try boundJson(many[0 .. many.len - 2], max_body_bytes);
    many[many.len - 3] = ',';
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    try std.testing.expectError(error.MetadataTooComplex, parseProvider(fixed.allocator(), many, .deepseek));
}

test "metadata deep oversized and duplicate caches remain untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const oversized = try std.testing.allocator.alloc(u8, max_cache_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    var deep: [66]u8 = undefined;
    @memset(deep[0..33], '[');
    @memset(deep[33..], ']');
    const cases = [_]struct { body: []const u8, err: anyerror }{
        .{ .body = &deep, .err = error.MetadataTooDeep },
        .{ .body = oversized, .err = error.MetadataTooLarge },
        .{ .body = "{\"version\":1,\"version\":1,\"attempted\":0,\"records\":[]}", .err = error.DuplicateField },
        .{ .body = "{\"version\":", .err = error.InvalidMetadata },
    };
    for (cases) |case| {
        try root.dir.writeFile(root.io, .{ .sub_path = file_name, .data = case.body });
        const before = try root.dir.statFile(root.io, file_name, .{});
        try std.testing.expectError(case.err, claim(&root, all_mask, true));
        try std.testing.expectError(case.err, commit(&root, all_mask, .{}));
        try std.testing.expectEqual(before.inode, (try root.dir.statFile(root.io, file_name, .{})).inode);
        const result = try root.read(std.testing.allocator, file_name, 0, max_cache_bytes + 1);
        defer std.testing.allocator.free(result.data);
        try std.testing.expectEqualStrings(case.body, result.data);
    }
}

// One owned loopback connection per fixture. No environment routing or real key.
fn serveMetadata(io: std.Io, server: *std.Io.net.Server, response: []const u8, cleaned: *std.atomic.Value(bool)) !void {
    return serveMetadataChecked(io, server, response, cleaned, false);
}

fn servePublicMetadata(io: std.Io, server: *std.Io.net.Server, response: []const u8, cleaned: *std.atomic.Value(bool)) !void {
    return serveMetadataChecked(io, server, response, cleaned, true);
}

fn serveMetadataChecked(io: std.Io, server: *std.Io.net.Server, response: []const u8, cleaned: *std.atomic.Value(bool), check_public: bool) !void {
    defer cleaned.store(true, .release);
    var stream = try server.accept(io);
    defer stream.close(io);
    var buffer: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var reader = stream.reader(io, &buffer);
    var suffix: u32 = 0;
    var count: usize = 0;
    var headers: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &headers);
    while (suffix != 0x0d0a0d0a) {
        if (count == buffer.len) return error.TestHeadersTooLarge;
        const byte = try reader.interface.takeByte();
        headers[count] = std.ascii.toLower(byte);
        suffix = (suffix << 8) | byte;
        count += 1;
    }
    if (check_public) {
        try std.testing.expect(std.mem.startsWith(u8, headers[0..count], "get /api.json http/1.1\r\n"));
        try std.testing.expect(std.mem.find(u8, headers[0..count], "authorization:") == null);
        try std.testing.expect(std.mem.find(u8, headers[0..count], "user-agent: thinagent-metadata-check/1.0") != null);
        try std.testing.expect(std.mem.find(u8, headers[0..count], "accept: application/json") != null);
    }
    var output: [1024]u8 = undefined;
    var writer = stream.writer(io, &output);
    try writer.interface.writeAll(response);
    try writer.interface.flush();
}

test "metadata loopback transport success redirects size short body and cleanup" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const close_head = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n";
    const streamed_oversized = try a.alloc(u8, close_head.len + max_body_bytes + 1);
    defer a.free(streamed_oversized);
    @memcpy(streamed_oversized[0..close_head.len], close_head);
    @memset(streamed_oversized[close_head.len..], ' ');
    const cases = [_]struct { response: []const u8, err: ?anyerror }{
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"data\":[]}", .err = null },
        .{ .response = "HTTP/1.1 302 Found\r\nLocation: /not-followed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .err = error.MetadataHttpStatus },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 524289\r\nConnection: close\r\n\r\n", .err = error.MetadataTooLarge },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{}", .err = error.IncompleteMetadata },
        .{ .response = streamed_oversized, .err = error.StreamTooLong },
    };
    for (cases) |case| {
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/models", .{server.socket.address.getPort()});
        defer a.free(url);
        var cleaned = std.atomic.Value(bool).init(false);
        var worker = try std.Io.concurrent(io, serveMetadata, .{ io, &server, case.response, &cleaned });
        defer worker.cancel(io) catch {};
        if (case.err) |err| {
            try std.testing.expectError(err, fetchUrl(a, io, url, "synthetic-test-key", max_body_bytes));
        } else {
            const body = try fetchUrl(a, io, url, null, max_body_bytes);
            defer a.free(body);
            _ = try parseProvider(a, body, .deepseek);
        }
        try worker.await(io);
        try std.testing.expect(cleaned.load(.acquire));
    }
}

fn testIndex(selector: []const u8) usize {
    for (catalog.entries, 0..) |entry, i| {
        if (std.mem.eql(u8, selector, entry.selector)) return i;
    }
    @panic("missing test catalog selector");
}

fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const len = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..len]);
}

test "metadata uses only context_window and exact provider raw names" {
    const a = std.testing.allocator;
    const body =
        \\{"object":"list","data":[{"id":"deepseek-flash","context_window":12345,"max_tokens":2},{"id":"deepseek-v4-pro","max_tokens":8192,"input_tokens":100000,"output_tokens":3}]}
    ;
    const values = try parseProvider(a, body, .deepseek);
    try std.testing.expectEqual(@as(?u32, 12345), values[testIndex("deepseek/deepseek-flash")]);
    try std.testing.expectEqual(@as(?u32, null), values[testIndex("deepseek/deepseek-v4-pro")]);
    for (try parseProvider(a, body, .opencode_go)) |v| try std.testing.expect(v == null);
    const absent = try parseProvider(a, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":null}]}", .deepseek);
    for (absent) |v| try std.testing.expect(v == null);
    const shared = "{\"data\":[{\"id\":\"minimax-m2.7\",\"context_window\":204800}]}";
    const zen = try parseProvider(a, shared, .opencode_zen);
    try std.testing.expectEqual(@as(?u32, 204800), zen[testIndex("opencode-zen/minimax-m2.7")]);
    try std.testing.expect(zen[testIndex("opencode-go/minimax-m2.7")] == null);
}

test "metadata rejects invalid IDs capacities duplicate IDs and shapes" {
    const bad = [_][]const u8{
        "[]",                                                      "{}",                                                 "{\"data\":{}}",                                          "{\"data\":[{}]}",
        "{\"data\":[{\"id\":\"\"}]}",                              "{\"data\":[{\"id\":\"x\"},{\"id\":\"x\"}]}",         "{\"data\":[{\"id\":\"x\",\"context_window\":0}]}",       "{\"data\":[{\"id\":\"x\",\"context_window\":-1}]}",
        "{\"data\":[{\"id\":\"x\",\"context_window\":16777217}]}", "{\"data\":[{\"id\":\"x\",\"context_window\":1.5}]}", "{\"data\":[{\"id\":\"x\",\"context_window\":\"100\"}]}",
    };
    for (bad) |body| try std.testing.expectError(error.InvalidMetadata, parseProvider(std.testing.allocator, body, .deepseek));
    try std.testing.expectError(error.DuplicateField, parseProvider(std.testing.allocator, "{\"data\":[],\"data\":[]}", .deepseek));
}

test "metadata body list and ID bounds are enforced" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, max_body_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.MetadataTooLarge, parseProvider(a, oversized, .deepseek));
    var buffer: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("{\"data\":[");
    for (0..513) |i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("{{\"id\":\"model-{d}\"}}", .{i});
    }
    try writer.writeAll("]}");
    try std.testing.expectError(error.InvalidMetadata, parseProvider(a, buffer[0..writer.end], .deepseek));
    writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("{\"data\":[{\"id\":\"");
    for (0..257) |_| try writer.writeByte('a');
    try writer.writeAll("\"}]}");
    try std.testing.expectError(error.InvalidMetadata, parseProvider(a, buffer[0..writer.end], .deepseek));
}

test "metadata private roundtrip claims once and merges only successful providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try testRoot(tmp.dir);
    defer first.deinit();
    var second = try testRoot(tmp.dir);
    defer second.deinit();
    try std.testing.expectEqual(@as(u8, 0), (try load(&first)).attempted);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&first, 0, false)).mask);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, file_name, .{}));
    try std.testing.expectEqual(all_mask, (try claim(&first, all_mask, false)).mask);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&second, all_mask, false)).mask);
    try std.testing.expectEqual(bit(.deepseek), (try claim(&second, bit(.deepseek), true)).mask);
    var tokens: Tokens = @splat(1000);
    _ = try commit(&first, all_mask, .{ .tokens = tokens });
    tokens = @splat(null);
    const deepseek_index = testIndex("deepseek/deepseek-flash");
    tokens[deepseek_index] = 2000;
    var refreshed: Listing = .{ .tokens = tokens };
    refreshed.reasoning[deepseek_index] = .{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high", .max = "max" } };
    const cache = try commit(&second, bit(.deepseek), refreshed);
    try std.testing.expectEqual(all_mask, cache.attempted);
    try std.testing.expectEqual(@as(?u32, 2000), cache.tokens[deepseek_index]);
    try std.testing.expectEqualStrings("max", cache.reasoning[deepseek_index].?.map.max.?);
    try std.testing.expectEqualStrings("max", (try load(&first)).reasoning[deepseek_index].?.map.max.?);
    try std.testing.expect(cache.tokens[testIndex("deepseek/deepseek-v4-pro")] == null);
    try std.testing.expectEqual(@as(?u32, 1000), cache.tokens[testIndex("opencode-zen/minimax-m2.7")]);
    try std.testing.expectEqualDeep(cache, try load(&first));
    const stat = try tmp.dir.statFile(std.testing.io, file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    _ = try commit(&first, 0, .{});
    try std.testing.expectEqual(stat.inode, (try tmp.dir.statFile(std.testing.io, file_name, .{})).inode);
}

test "metadata malformed cache is never overwritten and selectors are validated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const bad = [_][]const u8{
        "{\"version\":11,\"attempted\":0,\"records\":[]}",
        "{\"version\":1,\"attempted\":64,\"records\":[]}",
        "{\"version\":1,\"attempted\":0,\"records\":[{\"selector\":\"unknown\",\"context_window\":1}]}",
        "{\"version\":1,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":0}]}",
        "{\"version\":1,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":1},{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":2}]}",
    };
    for (bad) |body| {
        try root.dir.writeFile(root.io, .{ .sub_path = file_name, .data = body });
        try std.testing.expectError(error.InvalidMetadata, claim(&root, all_mask, true));
        try std.testing.expectError(error.InvalidMetadata, commit(&root, all_mask, .{}));
        const result = try root.read(std.testing.allocator, file_name, 0, max_body_bytes);
        defer std.testing.allocator.free(result.data);
        try std.testing.expectEqualStrings(body, result.data);
    }
    const reordered = try parseCache(std.testing.allocator, "{\"version\":1,\"attempted\":0,\"records\":[{\"selector\":\"opencode-go/minimax-m2.7\",\"context_window\":42},{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":99}]}");
    try std.testing.expectEqual(@as(?u32, 42), reordered.tokens[testIndex("opencode-go/minimax-m2.7")]);
    try std.testing.expectEqual(@as(?u32, 99), reordered.tokens[testIndex("deepseek/deepseek-flash")]);
}

test "official effort metadata maps exact model IDs and protocol formats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deepseek = try parseListing(
        a,
        "{\"data\":[{\"id\":\"deepseek-flash\",\"effort\":{\"supported_levels\":[\"low\",\"high\",\"max\"],\"default_level\":\"high\"}}]}",
        .deepseek,
    );
    const flash = deepseek.reasoning[testIndex("deepseek/deepseek-flash")];
    try std.testing.expect(flash != null);
    try std.testing.expectEqual(thinking.Format.deepseek, flash.?.format);
    try std.testing.expectEqual(@as(usize, 4), flash.?.map.levels().count()); // includes protocol off toggle
    try std.testing.expectEqualStrings("max", flash.?.map.max.?);
    const anthropic = try parseListing(
        a,
        "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"effort\":{\"supported_levels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\"]}}]}",
        .opencode_go,
    );
    const haiku = anthropic.reasoning[testIndex("opencode-go/claude-haiku-5-5")];
    try std.testing.expect(haiku != null);
    try std.testing.expectEqual(thinking.Format.anthropic, haiku.?.format);
    try std.testing.expectEqualStrings("xhigh", haiku.?.map.xhigh.?);
    var unknown = try std.json.parseFromSlice(std.json.Value, a, "{\"supported_levels\":[\"ultra\"]}", .{});
    defer unknown.deinit();
    try std.testing.expectEqual(@as(?thinking.Declaration, null), try parseEffort(unknown.value, .deepseek, .chat));
    try std.testing.expectError(error.InvalidMetadata, parseEffort(.{ .string = "bad" }, .deepseek, .chat));
}

test "metadata listing tracks exact membership independently of capacity and provider" {
    const a = std.testing.allocator;
    const listing = try parseListing(a, "{\"data\":[{\"id\":\"minimax-m2.7\"},{\"id\":\"deepseek-flash\",\"context_window\":42},{\"id\":\"unknown\",\"context_window\":100}]}", .opencode_go);
    for (catalog.entries, 0..) |entry, i| {
        const expected: ?bool = if (entry.provider == .opencode_go)
            std.mem.eql(u8, entry.model.name, "minimax-m2.7") or std.mem.eql(u8, entry.model.name, "deepseek-flash")
        else
            null;
        try std.testing.expectEqual(expected, listing.available[i]);
        if (entry.provider != .opencode_go) try std.testing.expect(listing.tokens[i] == null);
    }
    const go = testIndex("opencode-go/minimax-m2.7");
    try std.testing.expectEqual(@as(?bool, true), listing.available[go]);
    try std.testing.expect(listing.tokens[go] == null);
    const absent = try parseListing(a, "{\"data\":[{\"id\":\"opencode-go/minimax-m2.7\"},{\"id\":\"MINIMAX-M2.7\"}]}", .opencode_go);
    try std.testing.expectEqual(@as(?bool, false), absent.available[go]);
    const explicit_null = try parseListing(a, "{\"data\":[{\"id\":\"minimax-m2.7\",\"context_window\":null}]}", .opencode_go);
    try std.testing.expectEqual(@as(?bool, true), explicit_null.available[go]);
    try std.testing.expect(explicit_null.tokens[go] == null);
}

test "metadata availability removal and failed refresh preserve other providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const original = try commit(&root, all_mask, .{ .tokens = @splat(4096), .available = @splat(true) });
    const unchanged = try commit(&root, 0, .{ .tokens = @splat(0), .available = @splat(false) });
    try std.testing.expectEqualDeep(original, unchanged);
    const empty = try parseListing(std.testing.allocator, "{\"data\":[]}", .deepseek);
    const removed = try commit(&root, bit(.deepseek), empty);
    for (catalog.entries, 0..) |entry, i| {
        try std.testing.expectEqual(@as(?bool, entry.provider != .deepseek), removed.available[i]);
        try std.testing.expectEqual(if (entry.provider == .deepseek) @as(?u32, null) else @as(?u32, 4096), removed.tokens[i]);
    }
    try std.testing.expectEqualDeep(removed, try load(&root));
    const claimed = try claim(&root, all_mask, true);
    try std.testing.expectEqualDeep(removed.available, claimed.cache.available);
    const before = try load(&root);
    try std.testing.expectError(error.InvalidMetadata, commit(&root, bit(.deepseek), .{ .tokens = @splat(0), .available = @splat(true) }));
    try std.testing.expectEqualDeep(before, try load(&root));
}

test "metadata legacy cache upgrades to v10 with unknown directory availability and reasoning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const legacy = "{\"version\":1,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":99}]}";
    try root.dir.writeFile(root.io, .{ .sub_path = file_name, .data = legacy });
    const old = try load(&root);
    for (old.available) |v| try std.testing.expect(v == null);
    try std.testing.expectEqual(@as(?u32, 99), old.tokens[testIndex("deepseek/deepseek-flash")]);
    const upgraded = try claim(&root, bit(.deepseek), false);
    try std.testing.expectEqualDeep(old.tokens, upgraded.cache.tokens);
    try std.testing.expectEqualDeep(old.available, upgraded.cache.available);
    const bytes = try root.read(std.testing.allocator, file_name, 0, max_cache_bytes);
    defer std.testing.allocator.free(bytes.data);
    var parsed = try std.json.parseFromSlice(Document, std.testing.allocator, bytes.data, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 10), parsed.value.version);
    try std.testing.expectEqualDeep(upgraded.cache, try load(&root));
    const nullable = try parseCache(std.testing.allocator, "{\"version\":2,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":null,\"available\":null}]}");
    for (nullable.available) |v| try std.testing.expect(v == null);
    const omitted = try parseCache(std.testing.allocator, "{\"version\":2,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":99}]}");
    try std.testing.expectEqualDeep(old, omitted);
}

test "metadata rejects malformed availability and duplicate cache records without overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const cases = [_]struct { body: []const u8, err: anyerror }{
        .{ .body = "{\"version\":2,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":null,\"available\":1}]}", .err = error.UnexpectedToken },
        .{ .body = "{\"version\":2,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":null,\"available\":\"true\"}]}", .err = error.UnexpectedToken },
        .{ .body = "{\"version\":2,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":null,\"available\":true,\"available\":false}]}", .err = error.DuplicateField },
        .{ .body = "{\"version\":2,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":null,\"available\":true},{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":null,\"available\":false}]}", .err = error.InvalidMetadata },
    };
    for (cases) |case| {
        try root.dir.writeFile(root.io, .{ .sub_path = file_name, .data = case.body });
        const before = try root.dir.statFile(root.io, file_name, .{});
        try std.testing.expectError(case.err, claim(&root, all_mask, true));
        try std.testing.expectError(case.err, commit(&root, all_mask, .{}));
        try std.testing.expectEqual(before.inode, (try root.dir.statFile(root.io, file_name, .{})).inode);
        const bytes = try root.read(std.testing.allocator, file_name, 0, max_cache_bytes);
        defer std.testing.allocator.free(bytes.data);
        try std.testing.expectEqualStrings(case.body, bytes.data);
    }
}

test "metadata official listing routes only DeepSeek credentials" {
    try std.testing.expectEqualStrings("https://api.deepseek.com/models", listingUrl(.deepseek));
    try std.testing.expectEqualStrings("https://opencode.ai/inference/go/v1/models", listingUrl(.opencode_go));
    try std.testing.expectEqualStrings("https://opencode.ai/inference/v1/models", listingUrl(.opencode_zen));
    try std.testing.expectEqualStrings("synthetic-test-key", listingKey(.deepseek, "synthetic-test-key").?);
    try std.testing.expect(listingKey(.deepseek, null) == null);
    for ([_]providers.Id{ .opencode_go, .opencode_zen }) |id| {
        try std.testing.expect(listingKey(id, "synthetic-test-key") == null);
        try std.testing.expect(listingKey(id, "invalid\r\nkey") == null);
    }
}

test "version 5 upgrades output discovery once while retaining official directory" {
    const a = std.testing.allocator;
    const old: Document = .{ .version = 5, .attempted = provider_mask | dev_bit, .records = &.{}, .directory_mask = bit(.deepseek), .models = &.{.{ .provider = .deepseek, .id = "deepseek-flash", .context_window = 131072, .available = true, .protocol = .chat }} };
    const bytes = try std.json.Stringify.valueAlloc(a, old, .{});
    defer a.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = bytes });
    var path: [4096]u8 = undefined;
    const name = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var root = try fs.Root.open(a, std.testing.io, name);
    defer root.deinit();
    const migrated = try load(&root);
    try std.testing.expectEqual(provider_mask, migrated.attempted);
    try std.testing.expect(hasDirectory(&migrated, .deepseek));
    try std.testing.expectEqual(@as(?u32, 131072), migrated.directory.rows[0].tokens);
    try std.testing.expect(migrated.directory.rows[0].dev_output_tokens == null);
    const first = try claim(&root, dev_bit, false);
    try std.testing.expectEqual(dev_bit, first.mask);
    const reloaded = try load(&root);
    try std.testing.expectEqual(@as(u8, provider_mask | dev_bit), reloaded.attempted);
    try std.testing.expect(hasDirectory(&reloaded, .deepseek));
    try std.testing.expectEqual(@as(u8, 0), (try claim(&root, dev_bit, false)).mask);
}

test "models.dev profiles persist in version 8 cache and automatic claims observe cooldown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const body =
        \\{"deepseek":{"id":"deepseek","models":{"deepseek-flash":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high","max"]}],"provider":{"npm":"@ai-sdk/openai-compatible"}}}}}
    ;
    const listing = try parseDev(std.testing.allocator, body);
    const index = for (catalog.entries, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.selector, "deepseek/deepseek-flash")) break i;
    } else unreachable;
    try std.testing.expect(listing.dev_done);
    try std.testing.expectEqualStrings("off", listing.dev[index].?.map.off.?);
    try std.testing.expectEqual(dev_bit, (try claim(&root, dev_bit, false)).mask);
    _ = try commit(&root, 0, listing);
    const reloaded = try load(&root);
    try std.testing.expectEqualStrings("off", reloaded.dev_reasoning[index].?.map.off.?);
    try std.testing.expect(reloaded.reasoning[index] == null);
    try std.testing.expectEqual(dev_bit, reloaded.attempted & dev_bit);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&root, dev_bit, false)).mask);
    // A failed later models.dev fetch does not erase the last successful profile.
    _ = try commit(&root, 0, .{});
    try std.testing.expect((try load(&root)).dev_reasoning[index] != null);
}

test "models.dev loopback transport parses public catalog and enforces its own size limit" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const document =
        \\{"deepseek":{"id":"deepseek","models":{"deepseek-flash":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high","max"]}],"provider":{"npm":"@ai-sdk/openai-compatible"}}}}}
    ;
    // A valid catalog body larger than the official provider's 512 KiB limit.
    const body = try a.alloc(u8, max_body_bytes + document.len + 1);
    defer a.free(body);
    @memset(body, ' ');
    @memcpy(body[body.len - document.len ..], document);
    const response = try std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
    defer a.free(response);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/api.json", .{server.socket.address.getPort()});
    defer a.free(url);
    var cleaned = std.atomic.Value(bool).init(false);
    var worker = try std.Io.concurrent(io, servePublicMetadata, .{ io, &server, response, &cleaned });
    defer worker.cancel(io) catch {};
    const fetched = try fetchUrl(a, io, url, null, models_dev.max_body_bytes);
    defer a.free(fetched);
    const listing = try parseDev(a, fetched);
    try worker.await(io);
    try std.testing.expect(cleaned.load(.acquire));
    try std.testing.expect(listing.dev_done);
    const index = testIndex("deepseek/deepseek-flash");
    try std.testing.expectEqualStrings("off", listing.dev[index].?.map.off.?);
    // The provider limit (512 KiB) is not used for the public catalog, and a
    // smaller explicit limit fails before any parser sees a partial document.
    var tiny = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var second = try tiny.listen(io, .{});
    defer second.deinit(io);
    const second_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/api.json", .{second.socket.address.getPort()});
    defer a.free(second_url);
    var second_cleaned = std.atomic.Value(bool).init(false);
    const oversized_head = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n";
    var second_worker = try std.Io.concurrent(io, servePublicMetadata, .{ io, &second, oversized_head, &second_cleaned });
    defer second_worker.cancel(io) catch {};
    try std.testing.expectError(error.MetadataTooLarge, fetchUrl(a, io, second_url, null, 8));
    try second_worker.await(io);
    try std.testing.expect(second_cleaned.load(.acquire));
}

test {
    _ = @import("model_metadata_directory_test.zig");
}
