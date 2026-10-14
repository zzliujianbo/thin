//! Bounded parser for the public models.dev catalog (no credentials). Only
//! Thin's catalog model IDs are retained. Protocol comes from the declared AI SDK
//! adapter (`npm`), never from model names; `reasoning: true` is not a profile.
//! Structural JSON errors fail the whole document; an unusable or unknown option
//! only makes that one model's profile unusable.
const std = @import("std");
const thinking = @import("../core/thinking.zig");
const activity = @import("../presentation/activity.zig");
const protocol = @import("../core/protocol.zig");
const catalog = @import("provider_catalog.zig");
const json_bound = @import("json_bound.zig");

pub const url = "https://models.dev/api.json";
pub const max_body_bytes = 16 * 1024 * 1024;
pub const max_structural_nodes = 2_000_000;
pub const max_value_bytes = 2048;

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

fn catalogName(model: []const u8) bool {
    for (catalog.entries) |entry| if (equal(entry.model.name, model)) return true;
    return false;
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
    var values: ?Profile = null;
    while (!(try at(scanner, .object_end))) {
        const key = try nextString(scanner, allocator);
        if (equal(key, "type")) {
            if (kind != null) return error.InvalidModelsDev;
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
    while (!(try at(scanner, .array_end))) try parseOption(scanner, allocator, &profile);
    try expect(scanner, allocator, .array_end);
    return profile;
}

fn overrideNpm(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !?[]const u8 {
    if (!(try at(scanner, .object_begin))) {
        try scanner.skipValue();
        return null;
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
    return npm;
}

const ModelRow = struct { npm: ?[]const u8 = null, profile: Profile = .{} };

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
            row.npm = try overrideNpm(scanner, allocator);
        } else try scanner.skipValue(); // id is the catalog key; other fields are not used.
    }
    try expect(scanner, allocator, .object_end);
    return row;
}

fn parseModels(scanner: *std.json.Scanner, allocator: std.mem.Allocator, provider: []const u8, records: *std.ArrayList(Record)) !void {
    try expect(scanner, allocator, .object_begin);
    while (!(try at(scanner, .object_end))) {
        const model = try nextString(scanner, allocator);
        if (!catalogName(model)) {
            try scanner.skipValue();
            continue;
        }
        for (records.items) |prior| {
            if (equal(prior.provider, provider) and equal(prior.model, model)) return error.InvalidModelsDev;
        }
        const row = try parseModel(scanner, allocator);
        try records.append(allocator, .{ .provider = provider, .model = model, .profile = row.profile, .npm = row.npm });
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
        record.api = protocolFor(record.npm orelse provider_npm);
        record.declaration = declarationFor(record.profile, record.api, provider);
    }
}

fn matching(record: Record, model: []const u8, api: protocol.Protocol) ?thinking.Declaration {
    if (!equal(record.model, model) or record.api != api) return null;
    return record.declaration;
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
    if (api == .auto) return .{};
    for (records) |record| {
        if (!equal(record.provider, provider) or !equal(record.model, model)) continue;
        if (record.api != api) return .{};
        if (record.declaration) |declaration| return .{ .declaration = declaration, .source = .exact };
        break;
    }
    var best: ?thinking.Declaration = null;
    var best_count: usize = 0;
    var tied = false;
    outer: for (records, 0..) |candidate, index| {
        const declaration = matching(candidate, model, api) orelse continue;
        for (records[0..index]) |prior| {
            if (matching(prior, model, api)) |earlier| if (sameProfile(earlier, declaration)) continue :outer;
        }
        var count: usize = 0;
        for (records) |other| {
            if (matching(other, model, api)) |profile| if (sameProfile(profile, declaration)) {
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

pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Listing {
    try json_bound.bound(body, max_body_bytes, max_structural_nodes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
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
    var result: Listing = @splat(.{});
    for (catalog.entries, 0..) |entry, index| {
        result[index] = resolveIn(records.items, providerName(entry.provider), entry.model.name, entry.model.protocol);
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
