//! Bounded parser for the public models.dev catalog (no credentials).
//! Exact provider/model IDs are retained. Protocol comes from the declared AI SDK
//! adapter (`npm`), never from model names; `reasoning: true` is not a profile.
//! Structural JSON errors fail the whole document; an unusable or unknown option
//! only makes that one model's profile unusable.
const std = @import("std");
const thinking = @import("../core/thinking.zig");
const activity = @import("../presentation/activity.zig");
const protocol = @import("../core/protocol.zig");
const catalog = @import("provider_catalog.zig");
const json_bound = @import("json_bound.zig");
const directory = @import("model_directory.zig");
const providers = @import("../core/providers.zig");

pub const url = "https://models.dev/api.json";
pub const max_body_bytes = 16 * 1024 * 1024;
pub const max_structural_nodes = 2_000_000;
pub const max_value_bytes = 2048;
/// Includes third-party rows used for complete-profile majority voting.
/// Separate from the smaller by-value output directory limit.
pub const max_records = 65536;

pub const Source = enum { exact, majority };
pub const Resolution = struct {
    declaration: ?thinking.Declaration = null,
    source: ?Source = null,
};
pub const Listing = [catalog.entries.len]Resolution;

const Profile = struct {
    map: thinking.LevelMap = .{},
    has_effort: bool = false,
    has_toggle: bool = false,
    unsupported: bool = false,
    off_spelling: ?[]const u8 = null,
};

const Record = struct {
    provider: []const u8,
    model: []const u8,
    profile: Profile,
    npm: ?[]const u8 = null,
    override_invalid: bool = false,
    api: protocol.Protocol = .auto,
    declaration: ?thinking.Declaration = null,
};

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nextString(scanner: *std.json.Scanner, allocator: std.mem.Allocator) ![]const u8 {
    return switch (try scanner.nextAllocMax(allocator, .alloc_if_needed, max_value_bytes)) {
        .string => |value| value,
        .allocated_string => |value| value,
        else => error.InvalidModelsDev,
    };
}

fn expect(scanner: *std.json.Scanner, allocator: std.mem.Allocator, expected: std.meta.Tag(std.json.Token)) !void {
    if (std.meta.activeTag(try scanner.nextAllocMax(allocator, .alloc_if_needed, max_value_bytes)) != expected) return error.InvalidModelsDev;
}

fn at(scanner: *std.json.Scanner, expected: std.json.Scanner.TokenType) !bool {
    return (try scanner.peekNextTokenType()) == expected;
}

/// A string or skipped non-string value. Non-string schema drift is treated as
/// absent, so one unrelated field cannot make the whole catalog unusable.
fn optionalString(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !?[]const u8 {
    if (try at(scanner, .string)) return try nextString(scanner, allocator);
    try scanner.skipValue();
    return null;
}

fn providerName(id: catalog.Id) []const u8 {
    return switch (id) {
        .deepseek => "deepseek",
        .opencode_go => "opencode-go",
        .opencode_zen => "opencode",
    };
}

pub fn protocolFor(npm: ?[]const u8) protocol.Protocol {
    const value = npm orelse return .auto;
    if (equal(value, "@ai-sdk/anthropic")) return .anthropic;
    if (equal(value, "@ai-sdk/openai")) return .responses;
    if (equal(value, "@ai-sdk/openai-compatible")) return .chat;
    return .auto;
}

fn formatFor(provider: []const u8, api: protocol.Protocol) ?thinking.Format {
    return switch (api) {
        .anthropic => .anthropic,
        .chat => if (equal(provider, "deepseek")) .deepseek else .standard,
        .responses => .standard,
        .auto => null,
    };
}

fn addLevel(profile: *Profile, value: []const u8) void {
    if (value.len == 0 or value.len > 32) {
        profile.unsupported = true;
        return;
    }
    const level = activity.ReasoningEffort.fromName(value).canonical();
    if (level == .off) {
        const spelling: ?[]const u8 = if (equal(value, "off")) "off" else if (equal(value, "none")) "none" else null;
        if (spelling == null or profile.off_spelling != null) profile.unsupported = true else profile.off_spelling = spelling;
        return;
    }
    const name: []const u8 = switch (level) {
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
        .max => "max",
        else => {
            profile.unsupported = true;
            return;
        },
    };
    inline for (.{ "minimal", "low", "medium", "high", "xhigh", "max" }) |field| {
        if (equal(name, field)) {
            if (@field(profile.map, field) != null) profile.unsupported = true else @field(profile.map, field) = field;
            return;
        }
    }
    profile.unsupported = true;
}

fn parseLevels(scanner: *std.json.Scanner, allocator: std.mem.Allocator, profile: *Profile) !void {
    if (!(try at(scanner, .array_begin))) {
        try scanner.skipValue();
        profile.unsupported = true;
        return;
    }
    try expect(scanner, allocator, .array_begin);
    var count: usize = 0;
    while (!(try at(scanner, .array_end))) : (count += 1) {
        if (try at(scanner, .string)) {
            addLevel(profile, try nextString(scanner, allocator));
        } else {
            try scanner.skipValue();
            profile.unsupported = true;
        }
    }
    try expect(scanner, allocator, .array_end);
    if (count == 0) profile.unsupported = true;
}

fn parseOption(scanner: *std.json.Scanner, allocator: std.mem.Allocator, profile: *Profile) !void {
    try expect(scanner, allocator, .object_begin);
    var kind: ?[]const u8 = null;
    var saw_kind = false;
    var values: ?Profile = null;
    while (!(try at(scanner, .object_end))) {
        const key = try nextString(scanner, allocator);
        if (equal(key, "type")) {
            if (saw_kind) return error.InvalidModelsDev;
            saw_kind = true;
            kind = try optionalString(scanner, allocator);
        } else if (equal(key, "values")) {
            if (values != null) return error.InvalidModelsDev;
            var parsed: Profile = .{};
            try parseLevels(scanner, allocator, &parsed);
            values = parsed;
        } else try scanner.skipValue();
    }
    try expect(scanner, allocator, .object_end);
    const option_type = kind orelse {
        profile.unsupported = true;
        return;
    };
    if (equal(option_type, "toggle")) {
        if (profile.has_toggle) profile.unsupported = true;
        if (values) |parsed| profile.unsupported = profile.unsupported or parsed.unsupported;
        profile.has_toggle = true;
        return;
    }
    // budget_tokens and future option kinds are not translated into effort levels.
    if (!equal(option_type, "effort")) {
        profile.unsupported = true;
        return;
    }
    const effort = values orelse {
        profile.unsupported = true;
        return;
    };
    if (profile.has_effort) {
        profile.unsupported = true;
        return;
    }
    profile.has_effort = true;
    profile.map = effort.map;
    profile.off_spelling = effort.off_spelling;
    profile.unsupported = profile.unsupported or effort.unsupported;
}

fn parseOptions(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !Profile {
    var profile: Profile = .{};
    if (!(try at(scanner, .array_begin))) {
        try scanner.skipValue();
        profile.unsupported = true;
        return profile;
    }
    try expect(scanner, allocator, .array_begin);
    while (!(try at(scanner, .array_end))) {
        if (try at(scanner, .object_begin)) {
            try parseOption(scanner, allocator, &profile);
        } else {
            try scanner.skipValue();
            profile.unsupported = true;
        }
    }
    try expect(scanner, allocator, .array_end);
    return profile;
}

const AdapterOverride = struct { npm: ?[]const u8 = null, invalid: bool = false };

fn overrideNpm(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !AdapterOverride {
    if (!(try at(scanner, .object_begin))) {
        try scanner.skipValue();
        return .{ .invalid = true };
    }
    try expect(scanner, allocator, .object_begin);
    var npm: ?[]const u8 = null;
    var seen = false;
    while (!(try at(scanner, .object_end))) {
        const key = try nextString(scanner, allocator);
        if (equal(key, "npm")) {
            if (seen) return error.InvalidModelsDev;
            seen = true;
            npm = try optionalString(scanner, allocator);
        } else try scanner.skipValue();
    }
    try expect(scanner, allocator, .object_end);
    return .{ .npm = npm, .invalid = seen and npm == null };
}

const ModelRow = struct { npm: ?[]const u8 = null, profile: Profile = .{}, override_invalid: bool = false };

fn parseModel(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !ModelRow {
    try expect(scanner, allocator, .object_begin);
    var row: ModelRow = .{};
    var saw_options = false;
    var saw_provider = false;
    while (!(try at(scanner, .object_end))) {
        const field = try nextString(scanner, allocator);
        if (equal(field, "reasoning_options")) {
            if (saw_options) return error.InvalidModelsDev;
            saw_options = true;
            row.profile = try parseOptions(scanner, allocator);
        } else if (equal(field, "provider")) {
            if (saw_provider) return error.InvalidModelsDev;
            saw_provider = true;
            const override = try overrideNpm(scanner, allocator);
            row.npm = override.npm;
            row.override_invalid = override.invalid;
        } else try scanner.skipValue(); // id is the catalog key; other fields are not used.
    }
    try expect(scanner, allocator, .object_end);
    return row;
}

fn parseModels(scanner: *std.json.Scanner, allocator: std.mem.Allocator, provider: []const u8, records: *std.ArrayList(Record)) !void {
    try expect(scanner, allocator, .object_begin);
    const supported_provider = providerId(provider) != null;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    while (!(try at(scanner, .object_end))) {
        const model = try nextString(scanner, allocator);
        // Foreign rows only vote on exact supported IDs. Our output-key limits
        // must not reject unrelated upstream keys; scanner bounds still apply.
        if (supported_provider) try directory.validateId(model);
        if ((try seen.getOrPut(allocator, model)).found_existing) return error.InvalidModelsDev;
        if (records.items.len >= max_records) return error.MetadataTooLarge;
        const row = try parseModel(scanner, allocator);
        try records.append(allocator, .{ .provider = provider, .model = model, .profile = row.profile, .npm = row.npm, .override_invalid = row.override_invalid });
    }
    try expect(scanner, allocator, .object_end);
}

fn declarationFor(profile: Profile, api: protocol.Protocol, provider: []const u8) ?thinking.Declaration {
    if (!profile.has_effort or profile.unsupported) return null;
    const format = formatFor(provider, api) orelse return null;
    var map = profile.map;
    if (profile.has_toggle or profile.off_spelling != null) {
        map.off = switch (format) {
            .anthropic => "disabled",
            .deepseek => "off",
            // A standard toggle without an explicit off wire value is not a profile.
            .standard => profile.off_spelling orelse return null,
        };
    }
    const declaration: thinking.Declaration = .{ .format = format, .map = map };
    declaration.validate() catch return null;
    return declaration;
}

fn parseProvider(scanner: *std.json.Scanner, allocator: std.mem.Allocator, provider: []const u8, records: *std.ArrayList(Record)) !void {
    try expect(scanner, allocator, .object_begin);
    var provider_npm: ?[]const u8 = null;
    var saw_npm = false;
    var saw_models = false;
    const first = records.items.len;
    while (!(try at(scanner, .object_end))) {
        const field = try nextString(scanner, allocator);
        if (equal(field, "npm")) {
            if (saw_npm) return error.InvalidModelsDev;
            saw_npm = true;
            provider_npm = try optionalString(scanner, allocator);
        } else if (equal(field, "models")) {
            if (saw_models) return error.InvalidModelsDev;
            saw_models = true;
            try parseModels(scanner, allocator, provider, records);
        } else try scanner.skipValue();
    }
    try expect(scanner, allocator, .object_end);
    for (records.items[first..]) |*record| {
        record.api = if (record.override_invalid) .auto else protocolFor(record.npm orelse provider_npm);
        record.declaration = declarationFor(record.profile, record.api, provider);
    }
}

fn matching(record: Record, model: []const u8, api: protocol.Protocol, format: thinking.Format) ?thinking.Declaration {
    if (!equal(record.model, model) or record.api != api) return null;
    const declaration = record.declaration orelse return null;
    if (declaration.format != format) return null;
    return declaration;
}

fn sameProfile(a: thinking.Declaration, b: thinking.Declaration) bool {
    if (a.format != b.format) return false;
    inline for (.{ "off", "minimal", "low", "medium", "high", "xhigh", "max" }) |field| {
        const left = @field(a.map, field);
        const right = @field(b.map, field);
        if (left == null or right == null) {
            if (left != null or right != null) return false;
        } else if (!equal(left.?, right.?)) return false;
    }
    return true;
}

/// Exact usable provider/model profile first. Otherwise the unique most-common
/// complete profile for the exact model ID and protocol; ties remain unknown.
fn resolveIn(records: []const Record, provider: []const u8, model: []const u8, api: protocol.Protocol) Resolution {
    const format = formatFor(provider, api) orelse return .{};
    for (records) |record| {
        if (!equal(record.provider, provider) or !equal(record.model, model)) continue;
        if (record.api != api) return .{};
        if (record.declaration) |declaration| {
            if (declaration.format != format) return .{};
            return .{ .declaration = declaration, .source = .exact };
        }
        break;
    }
    var best: ?thinking.Declaration = null;
    var best_count: usize = 0;
    var tied = false;
    outer: for (records, 0..) |candidate, index| {
        const declaration = matching(candidate, model, api, format) orelse continue;
        for (records[0..index]) |prior| {
            if (matching(prior, model, api, format)) |earlier| if (sameProfile(earlier, declaration)) continue :outer;
        }
        var count: usize = 0;
        for (records) |other| {
            if (matching(other, model, api, format)) |profile| if (sameProfile(profile, declaration)) {
                count += 1;
            };
        }
        if (count > best_count) {
            best = declaration;
            best_count = count;
            tied = false;
        } else if (count == best_count) {
            tied = true;
        }
    }
    if (best == null or tied) return .{};
    return .{ .declaration = best, .source = .majority };
}

/// Returned records borrow the caller's arena, never the scanner's lifetime.
fn scan(a: std.mem.Allocator, body: []const u8) ![]const Record {
    try json_bound.bound(body, max_body_bytes, max_structural_nodes);
    var scanner = std.json.Scanner.initCompleteInput(a, body);
    defer scanner.deinit();
    var records: std.ArrayList(Record) = .empty;
    var providers_seen: std.StringHashMapUnmanaged(void) = .empty;
    try expect(&scanner, a, .object_begin);
    while (!(try at(&scanner, .object_end))) {
        const provider = try nextString(&scanner, a);
        if ((try providers_seen.getOrPut(a, provider)).found_existing) return error.InvalidModelsDev;
        try parseProvider(&scanner, a, provider, &records);
    }
    try expect(&scanner, a, .object_end);
    try expect(&scanner, a, .end_of_document);
    return records.items;
}

/// Compatibility output for existing catalog-indexed callers.
pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Listing {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const records = try scan(arena.allocator(), body);
    var result: Listing = @splat(.{});
    for (catalog.entries, 0..) |entry, index| {
        result[index] = resolveIn(records, providerName(entry.provider), entry.model.name, entry.model.protocol);
    }
    return result;
}

fn providerId(name: []const u8) ?providers.Id {
    for (providers.Id.all) |id| if (equal(name, providerName(id))) return id;
    return null;
}

/// Exact rows for the three supported services. Adapter identity is independent
/// of reasoning availability; only reasoning may use same-ID majority fallback.
/// All keys and profiles are pointer-free and safe to copy by value.
pub fn parseDirectory(allocator: std.mem.Allocator, body: []const u8) !directory.Directory {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const records = try scan(arena.allocator(), body);
    var result: directory.Directory = .{};
    for (records) |record| {
        const id = providerId(record.provider) orelse continue;
        const row = try result.upsert(id, record.model);
        row.dev_present = true;
        row.dev_protocol = record.api;
        const resolved = resolveIn(records, record.provider, record.model, record.api);
        if (resolved.declaration) |declaration| row.dev_reasoning = try directory.Profile.from(declaration);
    }
    return result;
}

fn testRecord(provider: []const u8, model: []const u8, api: protocol.Protocol, declaration: ?thinking.Declaration) Record {
    return .{ .provider = provider, .model = model, .profile = .{}, .api = api, .declaration = declaration };
}

test "models.dev exact usable profile wins and majority votes complete profiles" {
    const t = std.testing;
    const a: thinking.Declaration = .{ .map = .{ .low = "low", .high = "high" } };
    const b: thinking.Declaration = .{ .map = .{ .low = "low", .medium = "medium" } };
    const records = [_]Record{ testRecord("one", "sample", .chat, a), testRecord("two", "sample", .chat, b), testRecord("three", "sample", .chat, b) };
    const exact = resolveIn(&records, "one", "sample", .chat);
    try t.expectEqual(Source.exact, exact.source.?);
    try t.expectEqualStrings("high", exact.declaration.?.map.high.?);
    const majority = resolveIn(&records, "absent", "sample", .chat);
    try t.expectEqual(Source.majority, majority.source.?);
    try t.expectEqualStrings("medium", majority.declaration.?.map.medium.?);
}

test "models.dev ties, protocol mismatch, missing profiles and exact-name boundaries stay unknown" {
    const t = std.testing;
    const left: thinking.Declaration = .{ .map = .{ .low = "low", .high = "high" } };
    const right: thinking.Declaration = .{ .map = .{ .low = "low", .medium = "medium" } };
    const tied = [_]Record{ testRecord("one", "same", .chat, left), testRecord("two", "same", .chat, right) };
    try t.expect(resolveIn(&tied, "missing", "same", .chat).declaration == null);
    const mismatch = [_]Record{testRecord("one", "same", .responses, left)};
    try t.expect(resolveIn(&mismatch, "one", "same", .chat).declaration == null);
    try t.expect(resolveIn(&mismatch, "one", "same", .auto).declaration == null);
    const missing_exact = [_]Record{ testRecord("one", "same", .chat, null), testRecord("two", "same", .chat, right) };
    try t.expectEqual(Source.majority, resolveIn(&missing_exact, "one", "same", .chat).source.?);
    try t.expect(resolveIn(&tied, "missing", "prefix-same", .chat).declaration == null);
}

test "models.dev parser keeps catalog IDs, derives SDK protocols, and isolates bad option values" {
    const t = std.testing;
    const body =
        \\{"opencode-go":{"id":"opencode-go","npm":"@ai-sdk/openai-compatible","models":{"gpt-6-luna":{"id":"gpt-6-luna","reasoning_options":[{"type":"effort","values":["none","low","medium","high","xhigh","max"]}],"provider":{"npm":"@ai-sdk/openai"}},"claude-haiku-5-5":{"id":"claude-haiku-5-5","reasoning_options":[],"provider":{"npm":"@ai-sdk/anthropic"}},"unlisted":{"id":"unlisted","reasoning_options":[{"type":"effort","values":["low"]}]}}},"anthropic":{"id":"anthropic","npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"id":"claude-haiku-5-5","reasoning_options":[{"type":"toggle"},{"type":"effort","values":["low","medium","high","xhigh","max","extreme"]}]}}}}
    ;
    const parsed = try parse(t.allocator, body);
    const luna = for (catalog.entries, 0..) |entry, index| {
        if (equal(entry.selector, "opencode-go/gpt-6-luna")) break index;
    } else unreachable;
    try t.expectEqual(Source.exact, parsed[luna].source.?);
    try t.expectEqual(thinking.Format.standard, parsed[luna].declaration.?.format);
    try t.expectEqualStrings("none", parsed[luna].declaration.?.map.off.?);
    const haiku = for (catalog.entries, 0..) |entry, index| {
        if (equal(entry.selector, "opencode-go/claude-haiku-5-5")) break index;
    } else unreachable;
    // The exact Go row has no usable option; the anthropic-provider row is not
    // used because "extreme" makes that whole option set unusable.
    try t.expect(parsed[haiku].declaration == null);
    try t.expectEqual(protocol.Protocol.responses, protocolFor("@ai-sdk/openai"));
    try t.expectEqual(protocol.Protocol.chat, protocolFor("@ai-sdk/openai-compatible"));
    try t.expectEqual(protocol.Protocol.anthropic, protocolFor("@ai-sdk/anthropic"));
    try t.expectEqual(protocol.Protocol.auto, protocolFor("@ai-sdk/google"));
}

fn fixtureIndex(selector: []const u8) usize {
    for (catalog.entries, 0..) |entry, i| if (equal(entry.selector, selector)) return i;
    unreachable;
}

test "models.dev Haiku majority is a complete normalized profile, not a union" {
    // Synthetic offline fixture only. Never included in production data.
    const parsed = try parse(std.testing.allocator, @embedFile("models_dev_fixture.json"));
    const haiku = parsed[fixtureIndex("opencode-go/claude-haiku-5-5")];
    try std.testing.expectEqual(Source.majority, haiku.source.?);
    const declaration = haiku.declaration.?;
    try std.testing.expectEqual(thinking.Format.anthropic, declaration.format);
    try std.testing.expectEqualStrings("disabled", declaration.map.off.?);
    try std.testing.expectEqualStrings("low", declaration.map.low.?);
    try std.testing.expectEqualStrings("high", declaration.map.high.?);
    try std.testing.expectEqualStrings("max", declaration.map.max.?);
    try std.testing.expect(declaration.map.medium == null); // Minority profile is not merged.
    const luna = parsed[fixtureIndex("opencode-go/gpt-6-luna")];
    try std.testing.expectEqual(Source.exact, luna.source.?);
    try std.testing.expectEqualStrings("none", luna.declaration.?.map.off.?);
}

test "models.dev format mismatch cannot turn DeepSeek thinking toggle into standard effort" {
    const standard: thinking.Declaration = .{ .map = .{ .off = "none", .high = "high" } };
    const records = [_]Record{testRecord("fixture", "deepseek-flash", .chat, standard)};
    try std.testing.expect(resolveIn(&records, "deepseek", "deepseek-flash", .chat).declaration == null);
}

test "models.dev malformed toggle values neither authorize exact profiles nor cast votes" {
    const a = std.testing.allocator;
    const index = fixtureIndex("opencode-go/claude-haiku-5-5");
    for ([_][]const u8{ "42", "null", "[]", "[false]", "[\"high\",false]", "[\"high\",\"high\"]" }) |bad_values| {
        const bad = try std.mem.concat(a, u8, &.{
            \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"reasoning_options":[{"type":"toggle","values":
            ,
            bad_values,
            \\},{"type":"effort","values":["high"]}]}}}}
            ,
        });
        defer a.free(bad);
        try std.testing.expect((try parse(a, bad))[index].declaration == null);
        const fallback = try std.mem.concat(a, u8, &.{
            bad[0 .. bad.len - 1],
            \\,"valid":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high"]}]}}}}
            ,
        });
        defer a.free(fallback);
        const resolved = (try parse(a, fallback))[index];
        try std.testing.expectEqual(Source.majority, resolved.source.?);
        try std.testing.expectEqualStrings("high", resolved.declaration.?.map.high.?);
        const tied = try std.mem.concat(a, u8, &.{
            fallback[0 .. fallback.len - 1],
            \\,"other":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["low"]}]}}}}
            ,
        });
        defer a.free(tied);
        // The malformed high row must not break the valid high/low tie.
        try std.testing.expect((try parse(a, tied))[index].declaration == null);
    }
}

test "models.dev directory retains new IDs and protocols independently of options" {
    const t = std.testing;
    const body =
        \\{"opencode-go":{"models":{"new/plain":{},"new-response":{"provider":{"npm":"@ai-sdk/openai"}},"new-anthropic":{"provider":{"npm":"@ai-sdk/anthropic"},"reasoning":true},"bad-options":{"reasoning_options":[false]},"empty-options":{"reasoning_options":[]},"empty-provider":{"provider":{}},"invalid-provider":{"provider":false},"invalid-npm":{"provider":{"npm":42}},"null-npm":{"provider":{"npm":null}},"empty-npm":{"provider":{"npm":""}},"unknown-npm":{"provider":{"npm":"future-sdk"}}},"npm":"@ai-sdk/openai-compatible"},"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"new/plain":{}}},"opencode":{"npm":"@ai-sdk/anthropic","models":{"new/plain":{}}},"other":{"npm":"@ai-sdk/openai","models":{"third-party":{}}}}
    ;
    const parsed = try parseDirectory(t.allocator, body);
    try t.expectEqual(@as(usize, 13), parsed.count);
    for ([_][]const u8{ "new/plain", "bad-options", "empty-options", "empty-provider" }) |name| {
        const row = parsed.rows[parsed.find(.opencode_go, name).?];
        try t.expectEqual(protocol.Protocol.chat, row.dev_protocol);
        try t.expect(row.dev_present and row.dev_reasoning == null);
        try t.expectEqual(protocol.Protocol.auto, row.protocol);
        try t.expect(row.available == null and row.tokens == null and row.reasoning == null);
    }
    try t.expectEqual(protocol.Protocol.responses, parsed.rows[parsed.find(.opencode_go, "new-response").?].dev_protocol);
    const anthropic = parsed.rows[parsed.find(.opencode_go, "new-anthropic").?];
    try t.expectEqual(protocol.Protocol.anthropic, anthropic.dev_protocol);
    try t.expect(anthropic.dev_reasoning == null);
    for ([_][]const u8{ "invalid-provider", "invalid-npm", "null-npm", "empty-npm", "unknown-npm" }) |name| {
        const row = parsed.rows[parsed.find(.opencode_go, name).?];
        try t.expect(row.dev_present and row.dev_protocol == .auto and row.dev_reasoning == null);
    }
    try t.expectEqual(protocol.Protocol.chat, parsed.rows[parsed.find(.deepseek, "new/plain").?].dev_protocol);
    try t.expectEqual(protocol.Protocol.anthropic, parsed.rows[parsed.find(.opencode_zen, "new/plain").?].dev_protocol);
    try t.expectEqualStrings("opencode-zen/new/plain", parsed.selector(parsed.find(.opencode_zen, "new/plain").?));
    try t.expect(parsed.find(.opencode_go, "new") == null);
    try t.expect(parsed.find(.opencode_go, "NEW/plain") == null);
    try t.expect(parsed.find(.opencode_go, "third-party") == null);
}

test "models.dev new IDs retain exact profiles and safe complete majority fallback" {
    const t = std.testing;
    const body =
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"fresh":{},"exact":{"reasoning_options":[{"type":"effort","values":["low"]}]},"blocked":{"provider":{"npm":null}},"tie":{},"wrong-protocol":{}}},"one":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["low","high","max"]}]},"exact":{"reasoning_options":[{"type":"effort","values":["high"]}]},"blocked":{"reasoning_options":[{"type":"effort","values":["high"]}]},"tie":{"reasoning_options":[{"type":"effort","values":["low"]}]}}},"two":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"effort","values":["max","high","low"]},{"type":"toggle"}]},"exact":{"reasoning_options":[{"type":"effort","values":["high"]}]},"tie":{"reasoning_options":[{"type":"effort","values":["high"]}]}}},"minority":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"effort","values":["medium","high"]}]}}},"wrong":{"npm":"@ai-sdk/openai","models":{"wrong-protocol":{"reasoning_options":[{"type":"effort","values":["medium"]}]}}},"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"format-check":{}}},"standard":{"npm":"@ai-sdk/openai-compatible","models":{"format-check":{"reasoning_options":[{"type":"effort","values":["none","high"]}]}}}}
    ;
    const parsed = try parseDirectory(t.allocator, body);
    const fresh = parsed.rows[parsed.find(.opencode_go, "fresh").?].dev_reasoning.?.declaration();
    try t.expectEqual(thinking.Format.anthropic, fresh.format);
    try t.expectEqualStrings("disabled", fresh.map.off.?);
    try t.expectEqualStrings("max", fresh.map.max.?);
    try t.expect(fresh.map.medium == null);
    const exact = parsed.rows[parsed.find(.opencode_go, "exact").?].dev_reasoning.?.declaration();
    try t.expectEqualStrings("low", exact.map.low.?);
    try t.expect(exact.map.high == null);
    for ([_][]const u8{ "blocked", "tie", "wrong-protocol" }) |name| {
        try t.expect(parsed.rows[parsed.find(.opencode_go, name).?].dev_reasoning == null);
    }
    try t.expect(parsed.rows[parsed.find(.deepseek, "format-check").?].dev_reasoning == null);
    const fixture = try parseDirectory(t.allocator, @embedFile("models_dev_fixture.json"));
    const haiku = fixture.rows[fixture.find(.opencode_go, "claude-haiku-5-5").?];
    try t.expectEqual(protocol.Protocol.anthropic, haiku.dev_protocol);
    try t.expect(haiku.dev_reasoning.?.declaration().map.medium == null);
}

test "models.dev new model keys and recognized schema duplicates are rejected" {
    const t = std.testing;
    for ([_][]const u8{
        \\{"opencode-go":{"models":{"fresh":{},"fresh":{}}}}
        ,
        \\{"other":{"models":{"fresh":{},"fresh":{}}}}
        ,
        \\{"opencode-go":{},"opencode-go":{}}
        ,
        \\{"opencode-go":{"npm":"a","npm":"b"}}
        ,
        \\{"opencode-go":{"models":{},"models":{}}}
        ,
        \\{"opencode-go":{"models":{"fresh":{"provider":{},"provider":{}}}}}
        ,
        \\{"opencode-go":{"models":{"fresh":{"provider":{"npm":"a","npm":"b"}}}}}
        ,
        \\{"opencode-go":{"models":{"fresh":{"reasoning_options":[],"reasoning_options":[]}}}}
        ,
    }) |body| {
        try t.expectError(error.InvalidModelsDev, parseDirectory(t.allocator, body));
        try t.expectError(error.InvalidModelsDev, parse(t.allocator, body));
    }
    for ([_][]const u8{
        \\{"opencode-go":{"models":{"":{}}}}
        ,
        \\{"opencode-go":{"models":{"   ":{}}}}
        ,
        \\{"opencode-go":{"models":{"bad\n":{}}}}
        ,
    }) |body| try t.expectError(error.InvalidMetadata, parseDirectory(t.allocator, body));
}

test "unrelated provider IDs do not inherit the supported directory key limit" {
    const t = std.testing;
    const long_id: [257]u8 = @splat('x');
    for ([_][]const u8{ &long_id, "", "bad\nname" }) |foreign_id| {
        var bytes: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try writer.writeAll("{\"opencode\":{\"npm\":\"@ai-sdk/openai\",\"models\":{\"gpt-5.2\":{\"reasoning_options\":[{\"type\":\"effort\",\"values\":[\"high\"]}]}}},\"other\":{\"models\":{");
        try std.json.Stringify.value(foreign_id, .{}, &writer);
        try writer.writeAll(":{}}}}");
        const body = bytes[0..writer.end];
        const result = try parseDirectory(t.allocator, body);
        try t.expectEqual(@as(usize, 1), result.count);
        const row = result.rows[result.find(.opencode_zen, "gpt-5.2").?];
        try t.expectEqual(protocol.Protocol.responses, row.dev_protocol);
        try t.expectEqualStrings("high", row.dev_reasoning.?.declaration().map.high.?);
        const legacy = try parse(t.allocator, body);
        const index = for (catalog.entries, 0..) |entry, i| {
            if (entry.provider == .opencode_zen and equal(entry.model.name, "gpt-5.2")) break i;
        } else unreachable;
        try t.expectEqualStrings("high", legacy[index].declaration.?.map.high.?);
    }
}

test "models.dev directory capacity is explicit rather than truncated" {
    const a = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, "{\"opencode-go\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{");
    for (0..directory.max_models + 1) |i| {
        if (i != 0) try body.append(a, ',');
        var buf: [64]u8 = undefined;
        try body.appendSlice(a, try std.fmt.bufPrint(&buf, "\"fresh-{d}\":{{}}", .{i}));
    }
    try body.appendSlice(a, "}}}");
    try std.testing.expectError(error.MetadataTooLarge, parseDirectory(a, body.items));
    // Compatibility output does not inherit the by-value directory row limit.
    _ = try parse(a, body.items);
}

test "models.dev scan enforces the all-provider record limit" {
    const a = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, "{\"other\":{\"models\":{");
    for (0..max_records + 1) |i| {
        if (i != 0) try body.append(a, ',');
        var buf: [64]u8 = undefined;
        try body.appendSlice(a, try std.fmt.bufPrint(&buf, "\"fresh-{d}\":{{}}", .{i}));
    }
    try body.appendSlice(a, "}}}");
    try std.testing.expectError(error.MetadataTooLarge, parseDirectory(a, body.items));
    try std.testing.expectError(error.MetadataTooLarge, parse(a, body.items));
}

test "models.dev absent and unknown provider adapters never borrow a protocol" {
    const body =
        \\{"opencode-go":{"models":{"fresh":{}}},"opencode":{"npm":"unknown-sdk","models":{"fresh":{}}},"other":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    ;
    const parsed = try parseDirectory(std.testing.allocator, body);
    for ([_]providers.Id{ .opencode_go, .opencode_zen }) |id| {
        const row = parsed.rows[parsed.find(id, "fresh").?];
        try std.testing.expect(row.dev_present and row.dev_protocol == .auto and row.dev_reasoning == null);
    }
}

fn directoryAllocationCheck(a: std.mem.Allocator) !void {
    const result = try parseDirectory(a,
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"fresh":{}}},"other":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    );
    try std.testing.expect(result.rows[0].dev_reasoning != null);
}

test "models.dev directory allocation failures release parser scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, directoryAllocationCheck, .{});
}

test "models.dev malformed options and explicit invalid adapters are model-local unknowns" {
    const body =
        \\{"opencode-go":{"npm":"@ai-sdk/openai","models":{"gpt-6-luna":{"provider":{"npm":42},"reasoning_options":[{"type":"effort","values":["low"]}]},"claude-haiku-5-5":{"provider":{"npm":"@ai-sdk/anthropic"},"reasoning_options":[false,null,12]},"mimo-v2.5":{"reasoning":true}}}}
    ;
    const parsed = try parse(std.testing.allocator, body);
    try std.testing.expect(parsed[fixtureIndex("opencode-go/gpt-6-luna")].declaration == null);
    try std.testing.expect(parsed[fixtureIndex("opencode-go/claude-haiku-5-5")].declaration == null);
    try std.testing.expect(parsed[fixtureIndex("opencode-go/mimo-v2.5")].declaration == null);
}
