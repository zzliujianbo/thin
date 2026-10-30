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

test "explicit SystemOne directory identity survives cache without generative capabilities" {
    const a = std.testing.allocator;
    const listing = try parseListing(a,
        \\{"data":[{"id":"reviewer/not-jev","protocol":"systemone"}]}
    , .opencode_zen);
    const cache: Cache = .{ .directory = listing.directory, .directory_mask = listing.directory_mask };
    const entry = dynamicEntry(&cache, .opencode_zen, "reviewer/not-jev").?;
    try std.testing.expectEqual(Protocol.systemone, entry.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), entry.model.context_tokens);
    try std.testing.expect(capacityFor(&cache, entry) == null);
    try std.testing.expect(contextFor(&cache, entry) == null);
    try std.testing.expect(outputFor(&cache, entry) == null);
    try std.testing.expect(entryDeclaration(&cache, entry) == null);
    try std.testing.expect(inputPriceThresholdFor(&cache, entry) == null);
    try std.testing.expect(inputPriceFlatLimitFor(&cache, entry) == null);
    var bytes: std.Io.Writer.Allocating = .init(a);
    defer bytes.deinit();
    try std.json.Stringify.value(Document{ .directory_mask = listing.directory_mask, .models = &.{.{ .provider = .opencode_zen, .id = "reviewer/not-jev", .protocol = entry.model.protocol, .available = true }} }, .{}, &bytes.writer);
    const restored = try parseCache(a, bytes.written());
    const again = dynamicEntry(&restored, .opencode_zen, "reviewer/not-jev").?;
    try std.testing.expectEqual(Protocol.systemone, again.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), again.model.context_tokens);
}

test "models.dev native API identity survives cache roundtrip without generative metadata" {
    const a = std.testing.allocator;
    const source = try parseDev(a,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"reviewer":{"api":{"url":"https://opencode.ai/inference/systemone/v1"},"limit":{"context":100000,"output":32000},"cost":{"input":1,"output":2}}}}}
    );
    var merged: Listing = .{};
    try mergeDev(&merged, &source);
    const row = merged.directory.rows[merged.directory.find(.opencode_zen, "reviewer").?];
    try std.testing.expectEqual(Protocol.systemone, row.dev_protocol);
    var bytes: std.Io.Writer.Allocating = .init(a);
    defer bytes.deinit();
    try std.json.Stringify.value(Document{ .models = &.{.{
        .provider = .opencode_zen,
        .id = "reviewer",
        .dev_protocol = row.dev_protocol,
        .dev_present = row.dev_present,
        .dev_context_tokens = row.dev_context_tokens,
        .dev_output_tokens = row.dev_output_tokens,
        .dev_input_price_threshold = row.dev_input_price_threshold,
        .dev_input_price_flat_limit = row.dev_input_price_flat_limit,
    }} }, .{}, &bytes.writer);
    const cache = try parseCache(a, bytes.written());
    const entry = restoreEntry(&cache, .opencode_zen, "reviewer").?;
    try std.testing.expectEqual(Protocol.systemone, entry.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), entry.model.context_tokens);
    try std.testing.expect(entry.model.output_tokens == null);
    try std.testing.expect(capacityFor(&cache, entry) == null);
    try std.testing.expect(contextFor(&cache, entry) == null);
    try std.testing.expect(outputFor(&cache, entry) == null);
    try std.testing.expect(entryDeclaration(&cache, entry) == null);
    try std.testing.expect(inputPriceThresholdFor(&cache, entry) == null);
    try std.testing.expect(inputPriceFlatLimitFor(&cache, entry) == null);
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

test "documented SystemOne fallback resolves listed Jev without inventing availability or capabilities" {
    var cache: Cache = .{};
    cache.directory_mask = bit(.opencode_zen);
    const name = "jev-1.13-free";
    try std.testing.expect(dynamicEntry(&cache, .opencode_zen, name) == null);
    const row = try cache.directory.upsert(.opencode_zen, name);
    row.available = true;
    row.tokens = 65536;
    row.dev_context_tokens = 65536;
    row.dev_output_tokens = 4096;
    var entry = dynamicEntry(&cache, .opencode_zen, name).?;
    try std.testing.expectEqual(Protocol.systemone, entry.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), entry.model.context_tokens);
    try std.testing.expect(entry.model.output_tokens == null);
    try std.testing.expect(capacityFor(&cache, entry) == null);
    try std.testing.expect(outputFor(&cache, entry) == null);
    try std.testing.expect(entryDeclaration(&cache, entry) == null);
    try std.testing.expect(inputPriceThresholdFor(&cache, entry) == null);
    row.protocol = .responses;
    try std.testing.expectEqual(Protocol.responses, dynamicEntry(&cache, .opencode_zen, name).?.model.protocol);
    row.protocol = .auto;
    row.dev_protocol = .chat;
    entry = dynamicEntry(&cache, .opencode_zen, name).?;
    try std.testing.expectEqual(Protocol.chat, entry.model.protocol);
    row.dev_protocol = .auto;
    row.available = false;
    try std.testing.expect(dynamicEntry(&cache, .opencode_zen, name) == null);
    try std.testing.expect(dynamicEntry(&cache, .opencode_go, name) == null);
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

test "Codex listing uses explicit route, visibility and advertised efforts" {
    const listing = try parseListing(std.testing.allocator,
        \\{"models":[{"slug":"sample/raw","visibility":"list","supported_in_api":false,"context_window":12345,"max_context_window":99999,"supported_reasoning_levels":[{"effort":"high","description":""},{"effort":"ultra","description":""}]},{"slug":"hidden","visibility":"hide"}]}
    , .openai_codex);
    const row = listing.directory.rows[listing.directory.find(.openai_codex, "sample/raw").?];
    try std.testing.expectEqual(Protocol.responses, row.protocol);
    try std.testing.expectEqual(@as(?u32, 12345), row.tokens);
    try std.testing.expect(row.available == true);
    try std.testing.expectEqualStrings("high", row.reasoning.?.declaration().map.high.?);
    try std.testing.expect(row.reasoning.?.declaration().map.off == null);
    try std.testing.expect(listing.directory.rows[listing.directory.find(.openai_codex, "hidden").?].available == false);
    const empty = try parseListing(std.testing.allocator, "{\"models\":[]}", .openai_codex);
    try std.testing.expectEqual(bit(.openai_codex), empty.directory_mask);
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
pub const cache_version: u32 = 15;

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
            _ = try parseListing(a, buffer[0..w.end], .deepseek);
        } else {
            // A zero-capacity allocator proves this rejects before JSON allocation.
            var fixed = std.heap.FixedBufferAllocator.init(&.{});
            try std.testing.expectError(error.MetadataTooDeep, parseListing(fixed.allocator(), buffer[0..w.end], .deepseek));
            try std.testing.expectError(error.MetadataTooDeep, parseCache(fixed.allocator(), buffer[0..w.end]));
        }
    }
    const quoted =
        \\{"data":[],"extra":{"text":"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\\\"{}","next":true}}
    ;
    _ = try parseListing(a, quoted, .deepseek);
    try std.testing.expectError(error.DuplicateField, parseListing(a, "{\"data\":[],\"extra\":{\"x\":1,\"x\":2}}", .deepseek));
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
    try std.testing.expectError(error.MetadataTooComplex, parseListing(fixed.allocator(), many, .deepseek));
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

fn serveCodexFixture(io: std.Io, server: *std.Io.net.Server) !void {
    var stream = try server.accept(io);
    defer stream.close(io);
    var buffer: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var reader = stream.reader(io, &buffer);
    var headers: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &headers);
    var count: usize = 0;
    var suffix: u32 = 0;
    while (suffix != 0x0d0a0d0a) {
        if (count == headers.len) return error.TestHeadersTooLarge;
        const byte = try reader.interface.takeByte();
        headers[count] = std.ascii.toLower(byte);
        count += 1;
        suffix = (suffix << 8) | byte;
    }
    try std.testing.expect(std.mem.startsWith(u8, headers[0..count], "get /models?client_version=" ++ @import("version.zig").number ++ " http/1.1\r\n"));
    try std.testing.expect(std.mem.find(u8, headers[0..count], "authorization: bearer fake-token\r\n") != null);
    try std.testing.expect(std.mem.find(u8, headers[0..count], "chatgpt-account-id: fake-account\r\n") != null);
    try std.testing.expect(std.mem.find(u8, headers[0..count], "originator: thin\r\n") != null);
    var out: [1024]u8 = undefined;
    var writer = stream.writer(io, &out);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"models\":[]}");
    try writer.interface.flush();
}

test "Codex private fetch seam uses exact headers and fixed production scope" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/models?client_version=" ++ @import("version.zig").number, codex_listing_url);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/models?client_version={s}", .{ server.socket.address.getPort(), @import("version.zig").number });
    defer a.free(url);
    var token = [_]u8{ 'f', 'a', 'k', 'e', '-', 't', 'o', 'k', 'e', 'n' };
    var account = [_]u8{ 'f', 'a', 'k', 'e', '-', 'a', 'c', 'c', 'o', 'u', 'n', 't' };
    const credential: codex_auth.RequestCredential = .{ .access_token = &token, .account_id = &account };
    var server_job = try std.Io.concurrent(io, serveCodexFixture, .{ io, &server });
    defer server_job.cancel(io) catch {};
    const listing = try fetchCodexAt(a, io, &credential, null, 5000, url);
    try server_job.await(io);
    try std.testing.expectEqual(bit(.openai_codex), listing.directory_mask);
    try std.testing.expectEqualStrings("fake-token", &token);
    var canceled: p.Cancellation = .{};
    canceled.cancel();
    try std.testing.expectError(error.Canceled, fetchCodexAt(a, io, &credential, &canceled, 5000, url));
    try std.testing.expectError(error.RequestTimeout, fetchCodexAt(a, io, &credential, null, 0, url));
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
            _ = try parseListing(a, body, .deepseek);
        }
        try worker.await(io);
        try std.testing.expect(cleaned.load(.acquire));
    }
}

fn testRow(listing: *const Listing, id: providers.Id, name: []const u8) directory.Record {
    return listing.directory.rows[listing.directory.find(id, name).?];
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
    const values = try parseListing(a, body, .deepseek);
    try std.testing.expectEqual(@as(?u32, 12345), testRow(&values, .deepseek, "deepseek-flash").tokens);
    try std.testing.expect(testRow(&values, .deepseek, "deepseek-v4-pro").tokens == null);
    const other = try parseListing(a, body, .opencode_go);
    try std.testing.expect(other.directory.find(.deepseek, "deepseek-flash") == null);
    const absent = try parseListing(a, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":null}]}", .deepseek);
    try std.testing.expect(testRow(&absent, .deepseek, "deepseek-flash").tokens == null);
    const shared = "{\"data\":[{\"id\":\"minimax-m2.7\",\"context_window\":204800}]}";
    const zen = try parseListing(a, shared, .opencode_zen);
    try std.testing.expectEqual(@as(?u32, 204800), testRow(&zen, .opencode_zen, "minimax-m2.7").tokens);
    try std.testing.expect(zen.directory.find(.opencode_go, "minimax-m2.7") == null);
}

test "metadata rejects invalid IDs capacities duplicate IDs and shapes" {
    const bad = [_][]const u8{
        "[]",                                                      "{}",                                                 "{\"data\":{}}",                                          "{\"data\":[{}]}",
        "{\"data\":[{\"id\":\"\"}]}",                              "{\"data\":[{\"id\":\"x\"},{\"id\":\"x\"}]}",         "{\"data\":[{\"id\":\"x\",\"context_window\":0}]}",       "{\"data\":[{\"id\":\"x\",\"context_window\":-1}]}",
        "{\"data\":[{\"id\":\"x\",\"context_window\":16777217}]}", "{\"data\":[{\"id\":\"x\",\"context_window\":1.5}]}", "{\"data\":[{\"id\":\"x\",\"context_window\":\"100\"}]}",
    };
    for (bad) |body| try std.testing.expectError(error.InvalidMetadata, parseListing(std.testing.allocator, body, .deepseek));
    try std.testing.expectError(error.DuplicateField, parseListing(std.testing.allocator, "{\"data\":[],\"data\":[]}", .deepseek));
}

test "metadata body list and ID bounds are enforced" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, max_body_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.MetadataTooLarge, parseListing(a, oversized, .deepseek));
    var buffer: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("{\"data\":[");
    for (0..513) |i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("{{\"id\":\"model-{d}\"}}", .{i});
    }
    try writer.writeAll("]}");
    try std.testing.expectError(error.InvalidMetadata, parseListing(a, buffer[0..writer.end], .deepseek));
    writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("{\"data\":[{\"id\":\"");
    for (0..257) |_| try writer.writeByte('a');
    try writer.writeAll("\"}]}");
    try std.testing.expectError(error.InvalidMetadata, parseListing(a, buffer[0..writer.end], .deepseek));
}

test "metadata private roundtrip claims once and merges only successful providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try testRoot(tmp.dir);
    defer first.deinit();
    var second = try testRoot(tmp.dir);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try load(&first)).directory.count);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&first, 0, false)).mask);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, file_name, .{}));
    try std.testing.expectEqual(all_mask, (try claim(&first, all_mask, false)).mask);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&second, all_mask, false)).mask);
    try std.testing.expectEqual(bit(.deepseek), (try claim(&second, bit(.deepseek), true)).mask);
    var original: Listing = .{};
    for (providers.Id.all) |id| {
        const source = try parseListing(std.testing.allocator, if (id == .openai_codex) "{\"models\":[{\"slug\":\"raw/id\",\"visibility\":\"list\",\"context_window\":1000}]}" else "{\"data\":[{\"id\":\"raw/id\",\"context_window\":1000}]}", id);
        try mergeOfficial(&original, &source, id);
    }
    _ = try commit(&first, all_mask, original);
    const refreshed = try parseListing(std.testing.allocator, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":2000,\"effort\":{\"supported_levels\":[\"low\",\"high\",\"max\"]}}]}", .deepseek);
    const cache = try commit(&second, bit(.deepseek), refreshed);
    const row = cache.directory.rows[cache.directory.find(.deepseek, "deepseek-flash").?];
    try std.testing.expectEqual(@as(?u32, 2000), row.tokens);
    try std.testing.expectEqualStrings("max", row.reasoning.?.declaration().map.max.?);
    try std.testing.expectEqual(@as(?u32, 1000), cache.directory.rows[cache.directory.find(.opencode_zen, "raw/id").?].tokens);
    try std.testing.expectEqualDeep(cache, try load(&first));
    const stat = try tmp.dir.statFile(std.testing.io, file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    _ = try commit(&first, 0, .{});
    try std.testing.expectEqual(stat.inode, (try tmp.dir.statFile(std.testing.io, file_name, .{})).inode);
}

test "metadata rejects old future unknown and malformed cache without writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const a = std.testing.allocator;
    for (0..17) |version| {
        if (version == cache_version) continue;
        const body = try std.fmt.allocPrint(a, "{{\"version\":{d},\"models\":[]}}", .{version});
        defer a.free(body);
        try root.writeMode(file_name, body, true, 0o600);
        const before = try root.dir.statFile(root.io, file_name, .{});
        if (version < @as(usize, cache_version)) {
            // Older schemas are classified for claims, never migrated here.
            try std.testing.expectError(error.OutdatedMetadataCache, load(&root));
            try std.testing.expectError(error.OutdatedMetadataCache, commitAt(&root, all_mask, .{}, 1000));
        } else {
            try std.testing.expectError(error.InvalidMetadata, load(&root));
            try std.testing.expectError(error.InvalidMetadata, claimAt(&root, all_mask | dev_bit, true, 1000, .{}));
            try std.testing.expectError(error.InvalidMetadata, commitAt(&root, all_mask, .{}, 1000));
        }
        const bytes = try root.read(a, file_name, 0, max_cache_bytes);
        defer a.free(bytes.data);
        try std.testing.expectEqualStrings(body, bytes.data);
        try std.testing.expectEqual(before.inode, (try root.dir.statFile(root.io, file_name, .{})).inode);
    }
    for ([_][]const u8{
        "{\"version\":15,\"attempted\":0}",
        "{\"version\":15,\"records\":[]}",
        "{\"version\":15,\"unknown\":false}",
        "{\"version\":15,\"models\":[{\"provider\":\"deepseek\",\"id\":\"raw/id\",\"unknown\":1}]}",
        "{\"version\":15,\"refresh\":[{\"unknown\":0},{},{},{},{}]}",
    }) |body| {
        try root.writeMode(file_name, body, true, 0o600);
        const before = try root.dir.statFile(root.io, file_name, .{});
        try std.testing.expectError(error.UnknownField, claimAt(&root, all_mask, true, 1000, .{}));
        try std.testing.expectEqual(before.inode, (try root.dir.statFile(root.io, file_name, .{})).inode);
        const bytes = try root.read(a, file_name, 0, max_cache_bytes);
        defer a.free(bytes.data);
        try std.testing.expectEqualStrings(body, bytes.data);
    }
}

test "metadata stale document is rebuilt by manual and automatic claims only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const a = std.testing.allocator;
    // A claim against a missing cache still starts at generation 1.
    const first = try claimAt(&root, all_mask, true, 900, .{});
    try std.testing.expectEqual(@as(u64, 1), first.generations[0]);
    const stale = "{\"version\":12,\"attempted\":1750000000000,\"records\":[{\"id\":\"legacy\",\"context_window\":4096}],\"models\":[{\"provider\":\"deepseek\",\"id\":\"legacy\",\"context_window\":4096}]}";
    var listing: Listing = .{};
    for (providers.Id.all) |id| {
        const source = try parseListing(a, if (id == .openai_codex) "{\"models\":[{\"slug\":\"fresh\",\"visibility\":\"list\",\"context_window\":8192}]}" else "{\"data\":[{\"id\":\"fresh\",\"context_window\":8192}]}", id);
        try mergeOfficial(&listing, &source, id);
    }
    for ([_]bool{ true, false }) |manual| {
        try root.writeMode(file_name, stale, true, 0o600);
        try std.testing.expectError(error.OutdatedMetadataCache, load(&root));
        const bytes = try root.read(a, file_name, 0, max_cache_bytes);
        defer a.free(bytes.data);
        try std.testing.expectEqualStrings(stale, bytes.data);
        const rebuilt = try claimAt(&root, all_mask, manual, 1000, .{});
        try std.testing.expectEqual(all_mask, rebuilt.mask);
        try std.testing.expectEqual(@as(usize, 0), rebuilt.cache.directory.count);
        for (rebuilt.generations) |generation| try std.testing.expect(generation >= (@as(u64, 1) << 61));
        const published = try commitClaimedAt(&root, all_mask, listing, rebuilt.generations, 1010);
        try std.testing.expectEqual(all_mask, published.accepted);
        const reloaded = try load(&root);
        try std.testing.expectEqual(providers.Id.all.len, reloaded.directory.count);
        try std.testing.expectEqual(@as(?u32, 8192), reloaded.directory.rows[reloaded.directory.find(.deepseek, "fresh").?].tokens);
        // A claim taken before the rebuild can no longer publish.
        const delayed = try commitClaimedAt(&root, all_mask, listing, first.generations, 1020);
        try std.testing.expectEqual(@as(u8, 0), delayed.accepted);
        const after = try load(&root);
        try std.testing.expectEqual(providers.Id.all.len, after.directory.count);
        try std.testing.expectEqual(@as(?u32, 8192), after.directory.rows[after.directory.find(.deepseek, "fresh").?].tokens);
    }
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
    const flash = testRow(&deepseek, .deepseek, "deepseek-flash").reasoning.?.declaration();
    try std.testing.expectEqual(thinking.Format.deepseek, flash.format);
    try std.testing.expectEqual(@as(usize, 4), flash.map.levels().count()); // includes protocol off toggle
    try std.testing.expectEqualStrings("max", flash.map.max.?);
    const anthropic = try parseListing(
        a,
        "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"effort\":{\"supported_levels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\"]}}]}",
        .opencode_go,
    );
    const haiku = testRow(&anthropic, .opencode_go, "claude-haiku-5-5").reasoning.?.declaration();
    try std.testing.expectEqual(thinking.Format.anthropic, haiku.format);
    try std.testing.expectEqualStrings("xhigh", haiku.map.xhigh.?);
    var unknown = try std.json.parseFromSlice(std.json.Value, a, "{\"supported_levels\":[\"ultra\"]}", .{});
    defer unknown.deinit();
    try std.testing.expectEqual(@as(?thinking.Declaration, null), try parseEffort(unknown.value, .deepseek, .chat));
    try std.testing.expectError(error.InvalidMetadata, parseEffort(.{ .string = "bad" }, .deepseek, .chat));
}

test "metadata listing tracks exact membership independently of capacity and provider" {
    const a = std.testing.allocator;
    const listing = try parseListing(a, "{\"data\":[{\"id\":\"minimax-m2.7\"},{\"id\":\"deepseek-flash\",\"context_window\":42},{\"id\":\"unknown\",\"context_window\":100}]}", .opencode_go);
    try std.testing.expectEqual(@as(usize, 3), listing.directory.count);
    try std.testing.expectEqual(@as(?bool, true), testRow(&listing, .opencode_go, "minimax-m2.7").available);
    try std.testing.expect(testRow(&listing, .opencode_go, "minimax-m2.7").tokens == null);
    try std.testing.expect(listing.directory.find(.deepseek, "deepseek-flash") == null);
    const absent = try parseListing(a, "{\"data\":[{\"id\":\"opencode-go/minimax-m2.7\"},{\"id\":\"MINIMAX-M2.7\"}]}", .opencode_go);
    try std.testing.expect(absent.directory.find(.opencode_go, "minimax-m2.7") == null);
    const explicit_null = try parseListing(a, "{\"data\":[{\"id\":\"minimax-m2.7\",\"context_window\":null}]}", .opencode_go);
    try std.testing.expectEqual(@as(?bool, true), testRow(&explicit_null, .opencode_go, "minimax-m2.7").available);
    try std.testing.expect(testRow(&explicit_null, .opencode_go, "minimax-m2.7").tokens == null);
}

test "metadata empty official listing is authoritative and failed refresh preserves other providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var listing: Listing = .{};
    for (providers.Id.all) |id| {
        const source = try parseListing(std.testing.allocator, if (id == .openai_codex) "{\"models\":[{\"slug\":\"raw/id\",\"visibility\":\"list\",\"context_window\":4096}]}" else "{\"data\":[{\"id\":\"raw/id\",\"context_window\":4096}]}", id);
        try mergeOfficial(&listing, &source, id);
    }
    const original = try commit(&root, all_mask, listing);
    try std.testing.expectEqualDeep(original, try commit(&root, 0, .{}));
    const empty = try parseListing(std.testing.allocator, "{\"data\":[]}", .deepseek);
    const removed = try commit(&root, bit(.deepseek), empty);
    for (providers.Id.all) |id| {
        const row = removed.directory.rows[removed.directory.find(id, "raw/id").?];
        try std.testing.expectEqual(@as(?bool, id != .deepseek), row.available);
        try std.testing.expectEqual(if (id == .deepseek) @as(?u32, null) else @as(?u32, 4096), row.tokens);
    }
    try std.testing.expect(hasDirectory(&removed, .deepseek));
    try std.testing.expect(findEntry(&removed, "deepseek/deepseek-flash") == null);
    try std.testing.expectEqualDeep(removed, try load(&root));
    const claimed = try claim(&root, all_mask, true);
    try std.testing.expectEqualDeep(removed.directory, claimed.cache.directory);
    const before = try load(&root);
    var invalid = listing;
    invalid.directory.rows[invalid.directory.find(.deepseek, "raw/id").?].tokens = 0;
    try std.testing.expectError(error.InvalidMetadata, commit(&root, bit(.deepseek), invalid));
    try std.testing.expectEqualDeep(before, try load(&root));
}

test "metadata rejects malformed availability and duplicate cache records without overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const cases = [_]struct { body: []const u8, err: anyerror }{
        .{ .body = "{\"version\":15,\"models\":[{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":1}]}", .err = error.UnexpectedToken },
        .{ .body = "{\"version\":15,\"models\":[{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":\"true\"}]}", .err = error.UnexpectedToken },
        .{ .body = "{\"version\":15,\"models\":[{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":true,\"available\":false}]}", .err = error.DuplicateField },
        .{ .body = "{\"version\":15,\"models\":[{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":true},{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":false}]}", .err = error.InvalidMetadata },
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

test "models.dev profiles persist in current cache and automatic claims observe cooldown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const body =
        \\{"deepseek":{"id":"deepseek","models":{"deepseek-flash":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high","max"]}],"provider":{"npm":"@ai-sdk/openai-compatible"}}}}}
    ;
    const listing = try parseDev(std.testing.allocator, body);
    try std.testing.expect(listing.dev_done);
    try std.testing.expectEqualStrings("off", testRow(&listing, .deepseek, "deepseek-flash").dev_reasoning.?.declaration().map.off.?);
    try std.testing.expectEqual(dev_bit, (try claim(&root, dev_bit, false)).mask);
    _ = try commit(&root, 0, listing);
    const reloaded = try load(&root);
    try std.testing.expectEqualStrings("off", reloaded.directory.rows[reloaded.directory.find(.deepseek, "deepseek-flash").?].dev_reasoning.?.declaration().map.off.?);
    try std.testing.expect(reloaded.directory.rows[reloaded.directory.find(.deepseek, "deepseek-flash").?].reasoning == null);
    try std.testing.expect(reloaded.refresh[providers.Id.all.len].last_attempt_ms != null);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&root, dev_bit, false)).mask);
    // A failed later models.dev fetch does not erase the last successful profile.
    _ = try commit(&root, 0, .{});
    try std.testing.expect((try load(&root)).directory.rows[reloaded.directory.find(.deepseek, "deepseek-flash").?].dev_reasoning != null);
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
    try std.testing.expectEqualStrings("off", testRow(&listing, .deepseek, "deepseek-flash").dev_reasoning.?.declaration().map.off.?);
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

fn cacheAllocationCheck(a: std.mem.Allocator) !void {
    const cache = try parseCache(a,
        \\{"version":15,"directory_mask":1,"models":[{"provider":"deepseek","id":"deepseek/raw/id","context_window":131072,"available":true,"protocol":"chat","reasoning":{"format":"deepseek","map":{"off":"off","high":"high"}},"dev_protocol":"chat","dev_present":true,"dev_output_tokens":8192,"dev_context_tokens":262144,"dev_input_price_flat_limit":262144}],"refresh":[{"generation":7,"last_attempt_ms":10,"last_success_ms":11,"successful":true},{},{},{},{}]}
    );
    try std.testing.expectEqualStrings("deepseek/raw/id", cache.directory.name(0));
    try std.testing.expectEqual(@as(u64, 7), cache.refresh[0].generation);
}

test "metadata current cache allocation failures release all parser scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cacheAllocationCheck, .{});
}

test "metadata declaration identity never strips a provider prefix inside raw IDs" {
    var listing = try parseDev(std.testing.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"raw/id":{"reasoning_options":[{"type":"effort","values":["low"]}]},"opencode-go/raw/id":{"reasoning_options":[{"type":"effort","values":["high"]}]}}}}
    );
    const official = try parseListing(std.testing.allocator, "{\"data\":[{\"id\":\"raw/id\"},{\"id\":\"opencode-go/raw/id\"}]}", .opencode_go);
    try mergeOfficial(&listing, &official, .opencode_go);
    const cache: Cache = .{ .directory = listing.directory, .directory_mask = bit(.opencode_go) };
    var config: cfg.Config = .{ .provider = catalog.connection(.opencode_go), .model = .{ .name = "opencode-go/raw/id", .protocol = .chat, .context_tokens = 32768 } };
    try std.testing.expectEqualStrings("high", declarationForConfig(&cache, config).?.map.high.?);
    config.model.name = "raw/id";
    try std.testing.expectEqualStrings("low", declarationForConfig(&cache, config).?.map.low.?);
    config.model.name = "opencode-go/opencode-go/raw/id";
    try std.testing.expect(declarationForConfig(&cache, config) == null);
    config.provider.kind = .deepseek;
    config.model.name = "raw/id";
    try std.testing.expect(declarationForConfig(&cache, config) == null);
    const exact = restoreEntry(&cache, .opencode_go, "opencode-go/raw/id").?;
    try std.testing.expectEqualStrings("opencode-go/raw/id", exact.model.name);
    try std.testing.expectEqualStrings("opencode-go/raw/id", findEntry(&cache, "opencode-go/opencode-go/raw/id").?.model.name);
}

test "provider reasoning source is fixed by verified provider" {
    const t = std.testing;
    for (providers.Id.all) |id| {
        var cache: Cache = .{};
        const row = try cache.directory.upsert(id, "source-test");
        row.available = true;
        const protocol: Protocol = if (id == .deepseek) .chat else .responses;
        const format: thinking.Format = if (id == .deepseek) .deepseek else .standard;
        row.protocol = protocol;
        row.dev_protocol = protocol;
        row.dev_present = true;
        row.reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .high = "high" } });
        row.dev_reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .low = "low" } });
        row.dev_context_tokens = 123456;
        row.dev_output_tokens = 8192;
        row.dev_input_price_flat_limit = 123456;
        const entry = restoreEntry(&cache, id, "source-test").?;
        var config: cfg.Config = .{ .provider = catalog.connection(id), .model = entry.model };
        const official = id == .deepseek or id == .openai_codex;
        const selected = declarationForConfig(&cache, config).?;
        const selected_entry = entryDeclaration(&cache, entry).?;
        if (official) {
            try t.expectEqualStrings("high", selected.map.high.?);
            try t.expectEqualStrings("high", selected_entry.map.high.?);
            try t.expect(selected.map.low == null);
            row.dev_reasoning = null;
            try t.expectEqualStrings("high", declarationForConfig(&cache, config).?.map.high.?);
            row.dev_reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .low = "low" } });
            row.reasoning = null;
        } else {
            try t.expectEqualStrings("low", selected.map.low.?);
            try t.expectEqualStrings("low", selected_entry.map.low.?);
            try t.expect(selected.map.high == null);
            row.dev_reasoning = null;
        }
        try t.expect(declarationForConfig(&cache, config) == null);
        try t.expect(entryDeclaration(&cache, entry) == null);
        config.model.reasoning = .{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .high = "user-high" } };
        config.model.reasoning_source = .explicit;
        applyReasoning(&cache, &config);
        try t.expectEqualStrings("user-high", config.model.reasoning.?.map.high.?);
        row.reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .high = "high" } });
        row.dev_reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .low = "low" } });
        try t.expect(declarationForConfig(&cache, config) != null);
        config.model.name = "wrong-id";
        try t.expect(declarationForConfig(&cache, config) == null);
        config.model.name = "source-test";
        config.provider.base_url = "https://invalid.example/v1";
        try t.expect(declarationForConfig(&cache, config) == null);
        config.provider = catalog.connection(id);
        config.provider.kind = if (id == .deepseek) .opencode_go else .deepseek;
        try t.expect(declarationForConfig(&cache, config) == null);
        config.provider = catalog.connection(id);
        config.model.protocol = if (protocol == .chat) .responses else .chat;
        try t.expect(declarationForConfig(&cache, config) == null);
        if (id == .deepseek) {
            try t.expectEqual(@as(?u32, 123456), contextFor(&cache, entry));
            try t.expectEqual(@as(?u32, 8192), outputFor(&cache, entry));
            try t.expectEqual(@as(?u32, 123456), inputPriceFlatLimitFor(&cache, entry));
        }
    }
}

test "provider reasoning source official route ignores public protocol" {
    const t = std.testing;
    for ([_]providers.Id{ .deepseek, .openai_codex }) |id| {
        var cache: Cache = .{};
        const row = try cache.directory.upsert(id, "route-test");
        const protocol: Protocol = if (id == .deepseek) .chat else .responses;
        const format: thinking.Format = if (id == .deepseek) .deepseek else .standard;
        const official = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .high = "high" } });
        row.reasoning = official;
        row.dev_protocol = .anthropic;
        row.dev_reasoning = try directory.Profile.from(.{ .format = .anthropic, .map = .{ .off = "disabled", .low = "low" } });
        var config: cfg.Config = .{ .provider = catalog.connection(id), .model = .{ .name = "route-test", .protocol = protocol, .context_tokens = 65536 } };
        var selected = declarationForConfig(&cache, config).?;
        try t.expectEqual(format, selected.format);
        try t.expectEqualStrings("high", selected.map.high.?);
        try t.expect(selected.map.low == null);
        row.dev_protocol = .auto;
        row.dev_reasoning = null;
        selected = declarationForConfig(&cache, config).?;
        try t.expectEqual(format, selected.format);
        try t.expectEqualStrings("high", selected.map.high.?);
        row.dev_protocol = .chat;
        row.dev_reasoning = try directory.Profile.from(.{ .format = if (id == .deepseek) .deepseek else .standard, .map = .{ .off = if (id == .deepseek) "off" else "none", .low = "low" } });
        row.reasoning = null;
        try t.expect(declarationForConfig(&cache, config) == null);
        row.reasoning = official;
        selected = declarationForConfig(&cache, config).?;
        try t.expectEqual(format, selected.format);
        try t.expectEqualStrings("high", selected.map.high.?);
        config.model.protocol = if (id == .deepseek) .responses else .chat;
        try t.expect(declarationForConfig(&cache, config) == null);
    }
}

test "provider reasoning source ignores stale public cache and public refresh for DeepSeek" {
    const t = std.testing;
    const cache = try parseCache(t.allocator,
        \\{"version":15,"models":[{"provider":"deepseek","id":"refresh-test","protocol":"chat","dev_protocol":"chat","dev_present":true,"dev_reasoning":{"format":"deepseek","map":{"off":"off","low":"low"}}}]}
    );
    var listing: Listing = .{ .directory = cache.directory };
    const entry = restoreEntry(&cache, .deepseek, "refresh-test").?;
    try t.expect(entryDeclaration(&cache, entry) == null);
    const row = &listing.directory.rows[listing.directory.find(.deepseek, "refresh-test").?];
    row.reasoning = try directory.Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } });
    var public: Listing = .{ .dev_done = true };
    const fresh = try public.directory.upsert(.deepseek, "refresh-test");
    fresh.dev_present = true;
    fresh.dev_protocol = .chat;
    fresh.dev_reasoning = try directory.Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .max = "max" } });
    try mergeDev(&listing, &public);
    const refreshed: Cache = .{ .directory = listing.directory };
    const declaration = entryDeclaration(&refreshed, entry).?;
    try t.expectEqualStrings("high", declaration.map.high.?);
    try t.expect(declaration.map.low == null and declaration.map.max == null);
}

test {
    _ = @import("model_metadata_directory_test.zig");
}
