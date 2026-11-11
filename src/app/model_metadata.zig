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
pub const Listing = struct {
    /// Owned byte offsets, not borrowed model IDs; safe across worker publication.
    directory: directory.Directory = .{},
    directory_mask: u8 = 0,
    dev_done: bool = false,
};
pub const Cache = struct {
    directory: directory.Directory = .{},
    /// A successful official listing (even empty) supersedes offline presets.
    directory_mask: u8 = 0,
    refresh: [providers.Id.all.len + 1]Refresh = @splat(.{}),
};
/// Shared cache-only resolution for interactive and headless entry. No network,
/// capacity mutation or preset capabilities; explicit user overrides stay local.
pub fn declarationForConfig(cache: *const Cache, config: cfg.Config) ?thinking.Declaration {
    const index = dynamicIndex(cache, config) orelse return null;
    return rowDeclaration(cache, config, index);
}

pub fn applyReasoning(cache: *const Cache, config: *cfg.Config) void {
    if (config.model.reasoning_source == .explicit and config.model.reasoning != null) return;
    if (config.model.reasoning_source == .metadata) {
        config.model.reasoning = null;
        config.model.reasoning_effort = null;
    }
    const declaration = declarationForConfig(cache, config.*);
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
    if (catalog.documentedProtocol(row.provider, cache.directory.name(index))) |api| return api;
    if (preset(row.provider, cache.directory.name(index))) |entry| return entry.model.protocol;
    // This exact service exposes Chat Completions, not a model-name heuristic.
    if (row.provider == .deepseek) return .chat;
    return .auto;
}

fn storedEntry(cache: *const Cache, index: usize) catalog.Entry {
    const row = cache.directory.rows[index];
    const api = resolvedProtocol(cache, index);
    if (api == .systemone) return .{
        .provider = row.provider,
        .selector = cache.directory.selector(index),
        .model = .{ .name = cache.directory.name(index), .context_tokens = 0, .protocol = .systemone },
    };
    const known = preset(row.provider, cache.directory.name(index));
    var entry: catalog.Entry = .{
        .provider = row.provider,
        .selector = cache.directory.selector(index),
        .model = .{
            .name = cache.directory.name(index),
            .context_tokens = if (known) |value| value.model.context_tokens else if (row.provider == .openai_codex) 0 else 32768,
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
    if (entry.model.protocol == .systemone) return null;
    if (cache.directory.find(entry.provider, entry.model.name)) |index| {
        const row = cache.directory.rows[index];
        if (row.available == true) return row.tokens;
    }
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
    if (protocol == .auto or protocol == .systemone) return null;
    if (cache.directory.find(entry.provider, entry.model.name)) |index| {
        const row = cache.directory.rows[index];
        if (row.protocol != .auto and row.protocol != protocol) return null;
        if (row.available == true) {
            if (validContext(row.tokens)) |n| return n;
        }
        if (row.provider != .openai_codex and row.dev_protocol == protocol) return validContext(row.dev_context_tokens);
        return null;
    }
    return null;
}

fn validOutput(n: ?u32) ?u32 {
    const value = n orelse return null;
    return if (value > 0 and value <= 1024 * 1024) value else null;
}

fn compatibleRoute(row: directory.Record, protocol: Protocol) bool {
    return protocol != .auto and protocol != .systemone and (row.protocol == .auto or row.protocol == protocol);
}

fn rowOutput(row: directory.Record, protocol: Protocol) ?u32 {
    if (row.provider == .openai_codex) return null;
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
    if (entry.provider == .openai_codex) return null;
    const index = cache.directory.find(entry.provider, entry.model.name) orelse return null;
    const row = cache.directory.rows[index];
    const api = entry.model.protocol;
    if (!compatibleRoute(row, api)) return null;
    if (row.dev_protocol != api) return null;
    return validContext(row.dev_input_price_threshold);
}

/// Verified flat span on the exact concrete route. A compatible tier threshold
/// always takes precedence; absence of a threshold is not evidence of flat cost.
pub fn inputPriceFlatLimitFor(cache: *const Cache, entry: catalog.Entry) ?u32 {
    if (entry.provider == .openai_codex) return null;
    const index = cache.directory.find(entry.provider, entry.model.name) orelse return null;
    const row = cache.directory.rows[index];
    const api = entry.model.protocol;
    if (!compatibleRoute(row, api)) return null;
    if (row.dev_protocol != api) return null;
    if (validContext(row.dev_input_price_threshold) != null) return null;
    return validContext(row.dev_input_price_flat_limit);
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
    return cache.directory.find(id, config.model.name);
}

fn rowDeclaration(cache: *const Cache, config: cfg.Config, index: usize) ?thinking.Declaration {
    const row = cache.directory.rows[index];
    const protocol = if (config.model.protocol == .auto and cfg.chatOnly(config.provider.base_url, config.model)) .chat else config.model.protocol;
    if (protocol == .auto or protocol == .systemone) return null;
    const format: thinking.Format = if (protocol == .anthropic) .anthropic else if (row.provider == .deepseek) .deepseek else .standard;
    // Source authority belongs to the verified provider, not fetch success.
    const official = switch (row.provider) {
        .deepseek, .openai_codex => true,
        .opencode_go, .opencode_zen => false,
    };
    const route = if (official) (if (row.protocol != .auto) row.protocol else switch (row.provider) {
        .deepseek => Protocol.chat,
        .openai_codex => Protocol.responses,
        else => unreachable,
    }) else resolvedProtocol(cache, index);
    if (protocol != route) return null;
    if (official) {
        const profile = row.reasoning orelse return null;
        var declaration = profile.declaration();
        // Official supported levels are logical; use the official or verified
        // provider route to determine their concrete wire format.
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
    if (official) return null;
    if (row.dev_protocol != .auto and row.dev_protocol != protocol) return null;
    if (row.dev_reasoning) |profile| {
        const declaration = profile.declaration();
        if (declaration.format == format) {
            declaration.validate() catch return null;
            return declaration;
        }
    }
    return null;
}

pub fn entryDeclaration(cache: *const Cache, entry: catalog.Entry) ?thinking.Declaration {
    if (entry.model.protocol == .systemone) return null;
    const config: cfg.Config = .{ .provider = catalog.connection(entry.provider), .model = entry.model };
    return declarationForConfig(cache, config);
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
            dest.dev_input_price_flat_limit = previous.dev_input_price_flat_limit;
            dest.dev_present = previous.dev_present;
        }
    }
    target.directory = merged;
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
        row.dev_input_price_flat_limit = null;
        row.dev_present = false;
    }
    for (source.directory.rows[0..source.directory.count], 0..) |source_row, index| {
        if (!source_row.dev_present or source_row.provider == .openai_codex) continue;
        const row = try merged.upsert(source_row.provider, source.directory.name(index));
        row.dev_protocol = source_row.dev_protocol;
        row.dev_reasoning = source_row.dev_reasoning;
        row.dev_output_tokens = source_row.dev_output_tokens;
        row.dev_context_tokens = source_row.dev_context_tokens;
        row.dev_input_price_threshold = source_row.dev_input_price_threshold;
        row.dev_input_price_flat_limit = source_row.dev_input_price_flat_limit;
        row.dev_present = true;
    }
    target.directory = merged;
    target.dev_done = true;
}

pub const Generations = [providers.Id.all.len + 1]u64;
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
        // Decode the provider's wire spelling at the metadata boundary only.
        const level: activity.ReasoningEffort = if (std.mem.eql(u8, item.string, "none")) .off else activity.ReasoningEffort.fromName(item.string);
        switch (level) {
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
pub fn parseListing(a: std.mem.Allocator, body: []const u8, id: providers.Id) !Listing {
    if (id == .openai_codex) return parseCodexListing(a, body);
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
        if (protocol == .systemone) {
            row.tokens = null;
            // Non-generative records carry identity/availability, not windows
            // or thinking borrowed from a same-name generative preset.
            continue;
        }
        if (record.object.get("effort")) |effort| {
            if (try parseEffort(effort, id, if (protocol == .auto) .chat else protocol)) |declaration| row.reasoning = try directory.Profile.from(declaration);
        }
    }
    return result;
}

/// Codex catalog is authenticated discovery, not a guarantee of entitlement.
fn parseCodexListing(a: std.mem.Allocator, body: []const u8) !Listing {
    try boundJson(body, max_body_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_body_bytes });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMetadata;
    const models = parsed.value.object.get("models") orelse return error.InvalidMetadata;
    if (models != .array or models.array.items.len > 512) return error.InvalidMetadata;
    var result: Listing = .{ .directory_mask = bit(.openai_codex) };
    for (models.array.items) |item| {
        if (item != .object) return error.InvalidMetadata;
        const slug = item.object.get("slug") orelse return error.InvalidMetadata;
        if (slug != .string) return error.InvalidMetadata;
        try directory.validateId(slug.string);
        if (result.directory.find(.openai_codex, slug.string) != null) return error.InvalidMetadata;
        const row = try result.directory.upsert(.openai_codex, slug.string);
        row.protocol = .responses;
        const visibility = item.object.get("visibility") orelse .null;
        row.available = visibility == .string and std.mem.eql(u8, visibility.string, "list");
        if (item.object.get("input_modalities")) |modalities| {
            if (modalities == .array and modalities.array.items.len <= 32) {
                var valid = true;
                var image = false;
                for (modalities.array.items) |modality| {
                    if (modality != .string) {
                        valid = false;
                        break;
                    }
                    if (std.mem.eql(u8, modality.string, "image")) image = true;
                }
                if (valid) row.input_image = image;
            }
        }
        const primary = if (item.object.get("context_window")) |v| codexCapacity(v) else null;
        row.tokens = primary orelse if (item.object.get("max_context_window")) |v| codexCapacity(v) else null;
        if (item.object.get("supported_reasoning_levels")) |levels| {
            if (levels != .array or levels.array.items.len > 16) return error.InvalidMetadata;
            var map: thinking.LevelMap = .{};
            for (levels.array.items) |level| {
                if (level != .object) return error.InvalidMetadata;
                const effort = level.object.get("effort") orelse return error.InvalidMetadata;
                if (effort != .string or effort.string.len == 0 or effort.string.len > 32) return error.InvalidMetadata;
                if (std.mem.eql(u8, effort.string, "none") or std.mem.eql(u8, effort.string, "off")) {
                    if (map.off != null and !std.mem.eql(u8, map.off.?, effort.string)) return error.InvalidMetadata;
                    map.off = if (std.mem.eql(u8, effort.string, "none")) "none" else "off";
                }
                inline for (.{ "minimal", "low", "medium", "high", "xhigh", "max" }) |name| {
                    if (std.mem.eql(u8, effort.string, name)) @field(map, name) = name;
                }
            }
            const declaration: thinking.Declaration = .{ .format = .standard, .map = map };
            if (declaration.validate()) |_| row.reasoning = try directory.Profile.from(declaration) else |_| {}
            if (item.object.get("default_reasoning_level")) |default| {
                if (default == .string) {
                    const name = if (std.mem.eql(u8, default.string, "none")) "off" else default.string;
                    const effort = activity.ReasoningEffort.fromName(name);
                    if (effort != .unknown and effort != .unspecified) {
                        var advertised = if (effort == .off) map.off != null and std.mem.eql(u8, map.off.?, default.string) else false;
                        inline for (.{ "minimal", "low", "medium", "high", "xhigh", "max" }) |field| {
                            if (std.mem.eql(u8, default.string, field) and @field(map, field) != null) advertised = true;
                        }
                        if (advertised) row.default_reasoning = effort;
                    }
                }
            }
        }
    }
    return result;
}

fn codexCapacity(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |n| if (n > 0 and n <= max_tokens) @intCast(n) else null,
        else => null,
    };
}

/// Isolated client, fixed official URL, no redirects or credential discovery.
/// The borrowed caller key is not mutated; the owned header copy is wiped.
pub fn fetch(a: std.mem.Allocator, io: std.Io, id: providers.Id, key: ?[]const u8) !Listing {
    if (id == .openai_codex) return error.CodexCredentialRequired;
    const body = try fetchUrl(a, io, listingUrl(id), listingKey(id, key), max_body_bytes);
    defer a.free(body);
    return parseListing(a, body, id);
}

const codex_auth = @import("../core/codex_auth.zig");
const p = @import("../core/protocol.zig");
const codex_listing_url = providers.Id.openai_codex.baseUrl() ++ "/models?client_version=" ++ @import("version.zig").number;

const CodexJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    credential: *const codex_auth.RequestCredential,
    url: []const u8,
    done: std.atomic.Value(bool) = .init(false),
};

fn performCodex(job: *CodexJob) !Listing {
    defer job.done.store(true, .release);
    const body = try fetchCodexUrl(job.allocator, job.io, job.url, job.credential);
    defer job.allocator.free(body);
    return parseListing(job.allocator, body, .openai_codex);
}

/// Credential is borrowed only until the worker is joined. Fixed official URL;
/// no credential discovery, redirects, persisted tokens, or request retries.
pub fn fetchCodexListing(a: std.mem.Allocator, io: std.Io, credential: *const codex_auth.RequestCredential, cancel: ?*const p.Cancellation, timeout_ms: u32) !Listing {
    return fetchCodexAt(a, io, credential, cancel, timeout_ms, codex_listing_url);
}

// Private transport seam, reachable by tests only; production URL is fixed.
fn fetchCodexAt(a: std.mem.Allocator, io: std.Io, credential: *const codex_auth.RequestCredential, cancel: ?*const p.Cancellation, timeout_ms: u32, url: []const u8) !Listing {
    if (cancel) |c| if (c.isRequested()) return error.Canceled;
    if (timeout_ms == 0) return error.RequestTimeout;
    const start = std.Io.Clock.awake.now(io);
    var job: CodexJob = .{ .allocator = a, .io = io, .credential = credential, .url = url };
    var future = try std.Io.concurrent(io, performCodex, .{&job});
    defer _ = future.cancel(io) catch {};
    while (!job.done.load(.acquire)) {
        if (cancel) |c| if (c.isRequested()) return error.Canceled;
        if (start.untilNow(io, .awake).toMilliseconds() >= timeout_ms) return error.RequestTimeout;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    if (cancel) |c| if (c.isRequested()) return error.Canceled;
    if (start.untilNow(io, .awake).toMilliseconds() >= timeout_ms) return error.RequestTimeout;
    return future.await(io);
}

fn fetchCodexUrl(a: std.mem.Allocator, io: std.Io, url: []const u8, credential: *const codex_auth.RequestCredential) ![]u8 {
    for ([_][]const u8{ credential.access_token, credential.account_id }) |value| {
        if (value.len == 0 or value.len > 8192) return error.InvalidCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidCredential;
    }
    const authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{credential.access_token});
    defer {
        std.crypto.secureZero(u8, authorization);
        a.free(authorization);
    }
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .headers = .{ .authorization = .{ .override = authorization }, .accept_encoding = .{ .override = "identity" }, .user_agent = .{ .override = "ThinAgent-metadata-check/1.0" } },
        .extra_headers = &.{ .{ .name = "Accept", .value = "application/json" }, .{ .name = "chatgpt-account-id", .value = credential.account_id }, .{ .name = "originator", .value = "thin" } },
    });
    defer request.deinit();
    try request.sendBodiless();
    var head: [8192]u8 = undefined;
    var response = try request.receiveHead(&head);
    if (response.head.status != .ok) return error.MetadataHttpStatus;
    if (response.head.content_length) |size| if (size > max_body_bytes) return error.MetadataTooLarge;
    var transfer: [8192]u8 = undefined;
    const body = try response.reader(&transfer).allocRemaining(a, .limited(max_body_bytes));
    errdefer a.free(body);
    switch (request.reader.state) {
        .body_remaining_content_length, .body_remaining_chunk_len => return error.IncompleteMetadata,
        else => {},
    }
    return body;
}

/// Public catalog: no credentials and no provider listing key. Parsing is the
/// same bounded models.dev parser used by tests; unusable profiles stay unknown.
pub fn fetchDev(a: std.mem.Allocator, io: std.Io) !Listing {
    const body = try fetchUrl(a, io, models_dev.url, null, models_dev.max_body_bytes);
    defer a.free(body);
    return parseDev(a, body);
}

pub fn parseDev(a: std.mem.Allocator, body: []const u8) !Listing {
    return .{ .dev_done = true, .directory = try models_dev.parseDirectory(a, body) };
}

fn listingUrl(id: providers.Id) []const u8 {
    return switch (id) {
        .deepseek => comptime providers.Id.deepseek.baseUrl() ++ "/models",
        .opencode_go => "https://opencode.ai/inference/go/v1/models",
        .opencode_zen => "https://opencode.ai/inference/v1/models",
        .openai_codex => comptime providers.Id.openai_codex.baseUrl() ++ "/models",
    };
}

fn listingKey(id: providers.Id, key: ?[]const u8) ?[]const u8 {
    // OpenCode's official listing endpoints are public, not inference calls.
    return if (id == .deepseek) key else null;
}

/// Private transport seam for owned loopback tests. Production callers can only
/// reach it through fetch's fixed official endpoint, never through user URLs.
fn fetchUrl(a: std.mem.Allocator, io: std.Io, url: []const u8, key: ?[]const u8, limit: usize) ![]u8 {
    try cfg.validateKeySource(.{ .base_url = url, .api_key = key });
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

const ModelRecord = struct {
    provider: providers.Id,
    id: []const u8,
    context_window: ?u32 = null,
    output_tokens: ?u32 = null,
    dev_output_tokens: ?u32 = null,
    dev_context_tokens: ?u32 = null,
    dev_input_price_threshold: ?u32 = null,
    dev_input_price_flat_limit: ?u32 = null,
    available: ?bool = null,
    input_image: ?bool = null,
    default_reasoning: ?activity.ReasoningEffort = null,
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
const source_bits: [providers.Id.all.len + 1]u8 = blk: {
    var bits: [providers.Id.all.len + 1]u8 = undefined;
    for (providers.Id.all, 0..) |id, i| bits[i] = bit(id);
    bits[providers.Id.all.len] = dev_bit;
    break :blk bits;
};

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

/// Only current-schema data loads; older schemas are rebuilt by a refresh
/// claim, while future and malformed documents stay rejected.
pub const cache_version: u32 = 16;

const Document = struct {
    version: u32 = cache_version,
    directory_mask: u8 = 0,
    models: []const ModelRecord = &.{},
    refresh: [providers.Id.all.len + 1]Refresh = @splat(.{}),
};

fn parseCache(a: std.mem.Allocator, bytes: []const u8) !Cache {
    try json_bound.bound(bytes, max_cache_bytes, 131072);
    // Typed JSON integer parsing also accepts numeric strings. Cache capability
    // fields deliberately require JSON integer tokens, not that coercion. This
    // raw pass also classifies an older integer schema so a claim can rebuild
    // instead of being blocked by the stale document.
    {
        var raw = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_cache_bytes });
        defer raw.deinit();
        if (raw.value == .object) {
            const version = raw.value.object.get("version") orelse return error.InvalidMetadata;
            if (version != .integer) return error.InvalidMetadata;
            if (version.integer < 0) return error.InvalidMetadata;
            if (version.integer < cache_version) return error.OutdatedMetadataCache;
            if (version.integer != cache_version) return error.InvalidMetadata;
            if (raw.value.object.get("directory_mask")) |mask| {
                if (mask != .integer or mask.integer < 0 or mask.integer > all_mask) return error.InvalidMetadata;
            }
            if (raw.value.object.get("refresh")) |timings| {
                if (timings != .array or timings.array.items.len != providers.Id.all.len + 1) return error.InvalidMetadata;
                for (timings.array.items) |timing| {
                    if (timing != .object) return error.InvalidMetadata;
                    if (timing.object.get("generation")) |value| switch (value) {
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
                    for ([_][]const u8{ "context_window", "dev_context_tokens", "dev_input_price_threshold", "dev_input_price_flat_limit" }) |key| {
                        if (model.object.get(key)) |value| switch (value) {
                            .null => {},
                            .integer => |n| if (n <= 0 or n > max_tokens) return error.InvalidMetadata,
                            else => return error.InvalidMetadata,
                        };
                    }
                    for ([_][]const u8{ "output_tokens", "dev_output_tokens" }) |key| {
                        if (model.object.get(key)) |value| switch (value) {
                            .null => {},
                            .integer => |n| if (n <= 0 or n > 1024 * 1024) return error.InvalidMetadata,
                            else => return error.InvalidMetadata,
                        };
                    }
                };
            }
        }
    }
    var parsed = try std.json.parseFromSlice(Document, a, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_cache_bytes });
    defer parsed.deinit();
    const doc = parsed.value;
    if (doc.version != cache_version) return error.InvalidMetadata;
    if (doc.models.len > directory.max_models or doc.directory_mask & ~all_mask != 0) return error.InvalidMetadata;
    var result: Cache = .{ .directory_mask = doc.directory_mask, .refresh = doc.refresh };
    for (doc.models) |record| {
        if (record.context_window) |n| if (n == 0 or n > max_tokens) return error.InvalidMetadata;
        if (result.directory.find(record.provider, record.id) != null) return error.InvalidMetadata;
        const row = try result.directory.upsert(record.provider, record.id);
        row.tokens = record.context_window;
        row.dev_context_tokens = record.dev_context_tokens;
        row.dev_input_price_threshold = record.dev_input_price_threshold;
        row.dev_input_price_flat_limit = record.dev_input_price_flat_limit;
        if (record.output_tokens != null and validOutput(record.output_tokens) == null) return error.InvalidMetadata;
        if (record.dev_output_tokens != null and validOutput(record.dev_output_tokens) == null) return error.InvalidMetadata;
        row.output_tokens = record.output_tokens;
        row.dev_output_tokens = record.dev_output_tokens;
        row.available = record.available;
        row.input_image = record.input_image;
        row.default_reasoning = record.default_reasoning;
        if (row.default_reasoning == .unknown or row.default_reasoning == .unspecified) return error.InvalidMetadata;
        row.protocol = record.protocol;
        row.dev_protocol = record.dev_protocol;
        row.dev_present = record.dev_present;
        if (record.reasoning) |declaration| row.reasoning = try directory.Profile.from(declaration);
        if (record.dev_reasoning) |declaration| row.dev_reasoning = try directory.Profile.from(declaration);
    }
    return result;
}

/// Anchored, no-follow, nonblocking open; reject nonregular files before reading.
pub fn load(root: *fs.Root) !Cache {
    const fd = fs.openAt(root.dir.handle, file_name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
    if (fd < 0) {
        if (fs.errno() == .NOENT) return .{};
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
        if (fs.flock(fd, fs.LOCK.EX | fs.LOCK.NB) == 0) return fd;
        const errno = fs.errno();
        if (errno != .AGAIN and errno != .INTR) return fs.osError();
        try std.Io.sleep(root.io, .fromMilliseconds(2), .awake);
    }
    return error.MetadataStoreBusy;
}

fn save(root: *fs.Root, cache: Cache) !void {
    if (cache.directory_mask & ~all_mask != 0) return error.InvalidMetadata;
    for (cache.refresh) |timing| {
        if (timing.generation > max_generation) return error.InvalidMetadata;
        if (timing.last_attempt_ms) |n| if (n > max_timestamp_ms) return error.InvalidMetadata;
        if (timing.last_success_ms) |n| if (n > max_timestamp_ms) return error.InvalidMetadata;
    }
    for (cache.directory.rows[0..cache.directory.count]) |row| {
        if (row.default_reasoning == .unknown or row.default_reasoning == .unspecified) return error.InvalidMetadata;
        if (row.tokens != null and validContext(row.tokens) == null) return error.InvalidMetadata;
        if (row.dev_context_tokens != null and validContext(row.dev_context_tokens) == null) return error.InvalidMetadata;
        if (row.dev_input_price_threshold != null and validContext(row.dev_input_price_threshold) == null) return error.InvalidMetadata;
        if (row.dev_input_price_flat_limit != null and validContext(row.dev_input_price_flat_limit) == null) return error.InvalidMetadata;
        if (row.output_tokens != null and validOutput(row.output_tokens) == null) return error.InvalidMetadata;
        if (row.dev_output_tokens != null and validOutput(row.dev_output_tokens) == null) return error.InvalidMetadata;
    }
    const models = try root.allocator.alloc(ModelRecord, cache.directory.count);
    defer root.allocator.free(models);
    for (cache.directory.rows[0..cache.directory.count], 0..) |row, index| models[index] = .{
        .provider = row.provider,
        .id = cache.directory.name(index),
        .context_window = row.tokens,
        .output_tokens = row.output_tokens,
        .dev_output_tokens = row.dev_output_tokens,
        .dev_context_tokens = row.dev_context_tokens,
        .dev_input_price_threshold = row.dev_input_price_threshold,
        .dev_input_price_flat_limit = row.dev_input_price_flat_limit,
        .available = row.available,
        .input_image = row.input_image,
        .default_reasoning = row.default_reasoning,
        .protocol = row.protocol,
        .dev_protocol = row.dev_protocol,
        .reasoning = if (row.reasoning) |profile| profile.declaration() else null,
        .dev_reasoning = if (row.dev_reasoning) |profile| profile.declaration() else null,
        .dev_present = row.dev_present,
    };
    const bytes = try root.allocator.alloc(u8, max_cache_bytes);
    defer root.allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try std.json.Stringify.value(Document{ .directory_mask = cache.directory_mask, .models = models, .refresh = cache.refresh }, .{}, &writer);
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
    var cache = load(root) catch |err| switch (err) {
        // Only an older document schema is rebuilt by a claim. Every other load
        // failure stays authoritative, and nothing old is migrated on disk.
        error.OutdatedMetadataCache => blk: {
            // The random baseline invalidates publications still in flight from
            // before the rebuild and leaves headroom for later increments.
            var bytes: [8]u8 = undefined;
            try root.io.randomSecure(&bytes);
            const generation = (std.mem.readInt(u64, &bytes, .little) & ((@as(u64, 1) << 61) - 1)) | (@as(u64, 1) << 61);
            var fresh: Cache = .{};
            for (&fresh.refresh) |*timing| timing.generation = generation;
            break :blk fresh;
        },
        else => return err,
    };
    const mask = if (manual) requested else eligible(&cache, requested, now, policy);
    if (mask != 0) {
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

/// Reload under lock: unsuccessful provider capabilities and timing stay intact.
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
    const refreshed = succeeded & listing.directory_mask;
    for (cache.directory.rows[0..cache.directory.count]) |*row| {
        if (refreshed & bit(row.provider) != 0) {
            row.available = false;
            row.input_image = null;
            row.default_reasoning = null;
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
            row.dev_input_price_flat_limit = null;
            row.dev_present = false;
        }
    }
    for (listing.directory.rows[0..listing.directory.count], 0..) |source, index| {
        const official = refreshed & bit(source.provider) != 0 and source.available != null;
        if (!official and !(listing.dev_done and source.dev_present)) continue;
        const row = try cache.directory.upsert(source.provider, listing.directory.name(index));
        if (official) {
            row.available = source.available;
            row.input_image = source.input_image;
            row.default_reasoning = source.default_reasoning;
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
            row.dev_input_price_flat_limit = source.dev_input_price_flat_limit;
            row.dev_present = true;
        }
    }
    cache.directory_mask |= refreshed;
    for (source_bits, &cache.refresh) |source, *timing| {
        if ((succeeded | (if (listing.dev_done) dev_bit else @as(u8, 0))) & source == 0) continue;
        timing.last_success_ms = now;
        timing.successful = true;
    }
    if (succeeded != 0 or listing.dev_done) try save(root, cache);
    return cache;
}

// One owned loopback connection per fixture. No environment routing or real key.
