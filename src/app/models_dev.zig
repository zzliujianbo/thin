//! Bounded parser for the public models.dev catalog (no credentials).
//! Exact provider/model IDs are retained. Protocol comes from the declared AI SDK
//! adapter (`npm`), never from model names or API URLs;
//! `reasoning: true` is not a profile.
//! Structural JSON errors fail the whole document; malformed recognized options
//! make only that model's profile unusable, while unknown option kinds are ignored.
const std = @import("std");
const thinking = @import("../core/thinking.zig");
const activity = @import("../presentation/activity.zig");
const protocol = @import("../core/protocol.zig");
const catalog = @import("provider_catalog.zig");
const json_bound = @import("json_bound.zig");
const directory = @import("model_directory.zig");
const providers = @import("../core/providers.zig");

pub const url = "https://models.dev/api.json";

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
    /// Null means absent descriptor; explicit unknown/invalid API stays auto.
    described_api: ?protocol.Protocol = null,
    api: protocol.Protocol = .auto,
    output_tokens: ?u32 = null,
    context_tokens: ?u32 = null,
    declaration: ?thinking.Declaration = null,
};

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nextString(scanner: *std.json.Scanner, allocator: std.mem.Allocator) ![]const u8 {
    return switch (try scanner.nextAllocMax(allocator, .alloc_if_needed, scanner.input.len)) {
        .string => |value| value,
        .allocated_string => |value| value,
        else => error.InvalidModelsDev,
    };
}

fn expect(scanner: *std.json.Scanner, allocator: std.mem.Allocator, expected: std.meta.Tag(std.json.Token)) !void {
    if (std.meta.activeTag(try scanner.nextAllocMax(allocator, .alloc_if_needed, scanner.input.len)) != expected) return error.InvalidModelsDev;
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
        .openai => "openai",
        .openai_codex => "\x00unverified-codex-source",
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
    // Provider wire spelling, not a logical Effort alias.
    const level: activity.ReasoningEffort = if (equal(value, "none")) .off else activity.ReasoningEffort.fromName(value);
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
            const token = try scanner.nextAllocMax(allocator, .alloc_if_needed, scanner.input.len);
            const value = switch (token) {
                .string, .allocated_string => |v| v,
                else => unreachable,
            };
            addLevel(profile, value);
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
    var duplicate_values = false;
    while (!(try at(scanner, .object_end))) {
        const key = try nextString(scanner, allocator);
        if (equal(key, "type")) {
            if (saw_kind) return error.InvalidModelsDev;
            saw_kind = true;
            kind = try optionalString(scanner, allocator);
        } else if (equal(key, "values")) {
            if (values != null) {
                duplicate_values = true;
                try scanner.skipValue();
            } else {
                var parsed: Profile = .{};
                try parseLevels(scanner, allocator, &parsed);
                values = parsed;
            }
        } else try scanner.skipValue();
    }
    try expect(scanner, allocator, .object_end);
    const option_type = kind orelse {
        profile.unsupported = true;
        return;
    };
    if (!equal(option_type, "toggle") and !equal(option_type, "effort")) return;
    if (duplicate_values) return error.InvalidModelsDev;
    if (equal(option_type, "toggle")) {
        if (profile.has_toggle) profile.unsupported = true;
        if (values) |parsed| profile.unsupported = profile.unsupported or parsed.unsupported;
        profile.has_toggle = true;
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

/// A model-level api.url must be a valid absolute http(s) URL, but never grants
/// a protocol. SDK/id annotations do not invalidate a valid descriptor. Other
/// URLs never replace the declared connection: ordinary protocols retain their
/// SDK source. Null inherits that source; auto revokes it for a malformed or
/// unknown descriptor.
fn parseAPI(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !?protocol.Protocol {
    if (!(try at(scanner, .object_begin))) {
        try scanner.skipValue();
        return .auto;
    }
    try expect(scanner, allocator, .object_begin);
    var npm: ?[]const u8 = null;
    var seen: u8 = 0;
    var invalid = false;
    while (!(try at(scanner, .object_end))) {
        const field = try nextString(scanner, allocator);
        const bit: u8 = if (equal(field, "url")) 1 else if (equal(field, "npm")) 2 else if (equal(field, "id")) 4 else 0;
        if (bit == 0) {
            invalid = true;
            try scanner.skipValue();
            continue;
        }
        if (seen & bit != 0) return error.InvalidModelsDev;
        seen |= bit;
        const value = try optionalString(scanner, allocator);
        if (value == null or value.?.len == 0) {
            invalid = true;
            continue;
        }
        for (value.?) |byte| if (byte < 0x20 or byte == 0x7f) {
            invalid = true;
        };
        switch (bit) {
            1 => {
                const uri = std.Uri.parse(value.?) catch {
                    invalid = true;
                    continue;
                };
                if ((!equal(uri.scheme, "https") and !equal(uri.scheme, "http")) or uri.host == null) invalid = true;
            },
            2 => npm = value,
            4 => {}, // Annotation only; never rewrite the selected raw model ID.
            else => unreachable,
        }
    }
    try expect(scanner, allocator, .object_end);
    if (invalid) return .auto;
    if (npm) |value| return protocolFor(value);
    return null;
}

const Limits = struct { output: ?u32 = null, context: ?u32 = null };
const ModelRow = struct { npm: ?[]const u8 = null, profile: Profile = .{}, override_invalid: bool = false, described_api: ?protocol.Protocol = null, limits: Limits = .{} };

// Independent public capabilities. Only integer limit.output / limit.context
// count, never input/output sums, reasoning budgets or same-ID majority votes.
fn parseLimits(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !Limits {
    if (!(try at(scanner, .object_begin))) {
        try scanner.skipValue();
        return .{};
    }
    try expect(scanner, allocator, .object_begin);
    var limits: Limits = .{};
    var seen_output = false;
    var seen_context = false;
    while (!(try at(scanner, .object_end))) {
        const key = try nextString(scanner, allocator);
        const is_output = equal(key, "output");
        if (is_output or equal(key, "context")) {
            const seen = if (is_output) &seen_output else &seen_context;
            if (seen.*) return error.InvalidModelsDev;
            seen.* = true;
            if (try at(scanner, .number)) {
                const token = try scanner.nextAllocMax(allocator, .alloc_if_needed, scanner.input.len);
                const text = switch (token) {
                    .number, .allocated_number => |value| value,
                    else => unreachable,
                };
                const n = std.fmt.parseInt(u32, text, 10) catch 0;
                const max: u32 = if (is_output) 1024 * 1024 else 16 * 1024 * 1024;
                if (n > 0 and n <= max) {
                    if (is_output) limits.output = n else limits.context = n;
                }
            } else try scanner.skipValue();
        } else try scanner.skipValue();
    }
    try expect(scanner, allocator, .object_end);
    return limits;
}

fn parseModel(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !ModelRow {
    try expect(scanner, allocator, .object_begin);
    var row: ModelRow = .{};
    var saw_options = false;
    var saw_provider = false;
    var saw_api = false;
    var saw_limit = false;
    while (!(try at(scanner, .object_end))) {
        const field = try nextString(scanner, allocator);
        if (equal(field, "api")) {
            if (saw_api) return error.InvalidModelsDev;
            saw_api = true;
            row.described_api = try parseAPI(scanner, allocator);
        } else if (equal(field, "limit")) {
            if (saw_limit) return error.InvalidModelsDev;
            saw_limit = true;
            row.limits = try parseLimits(scanner, allocator);
        } else if (equal(field, "reasoning_options")) {
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
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    while (!(try at(scanner, .object_end))) {
        const model = try nextString(scanner, allocator);
        try directory.validateId(model);
        if ((try seen.getOrPut(allocator, model)).found_existing) return error.InvalidModelsDev;
        const row = try parseModel(scanner, allocator);
        try records.append(allocator, .{ .provider = provider, .model = model, .profile = row.profile, .npm = row.npm, .override_invalid = row.override_invalid, .described_api = row.described_api, .output_tokens = row.limits.output, .context_tokens = row.limits.context });
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
        record.api = if (record.override_invalid) .auto else record.described_api orelse protocolFor(record.npm orelse provider_npm);
        record.declaration = declarationFor(record.profile, record.api, provider);
    }
}

/// Returned records borrow the caller's arena, never the scanner's lifetime.
fn scan(a: std.mem.Allocator, body: []const u8) ![]const Record {
    try json_bound.validate(a, body);
    var scanner = std.json.Scanner.initCompleteInput(a, body);
    defer scanner.deinit();
    var records: std.ArrayList(Record) = .empty;
    var providers_seen: std.StringHashMapUnmanaged(void) = .empty;
    try expect(&scanner, a, .object_begin);
    while (!(try at(&scanner, .object_end))) {
        const provider = try nextString(&scanner, a);
        if ((try providers_seen.getOrPut(a, provider)).found_existing) return error.InvalidModelsDev;
        if (providerId(provider) != null) {
            try parseProvider(&scanner, a, provider, &records);
        } else {
            try scanner.skipValue();
        }
    }
    try expect(&scanner, a, .object_end);
    try expect(&scanner, a, .end_of_document);
    return records.items;
}

fn providerId(name: []const u8) ?providers.Id {
    for (providers.Id.all) |id| {
        if (id == .openai_codex) continue; // No verified public catalog identity.
        if (equal(name, providerName(id))) return id;
    }
    return null;
}

/// Exact rows for supported services. Adapter identity is independent
/// of reasoning availability. All keys and profiles are safe to copy by value.
pub fn parseDirectory(allocator: std.mem.Allocator, body: []const u8) !directory.Directory {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const records = try scan(arena.allocator(), body);
    var result: directory.Directory = .{};
    errdefer result.deinit(allocator);
    for (records) |record| {
        const id = providerId(record.provider) orelse continue;
        if (id == .openai and (!catalog.openaiText(record.model) or record.api != .responses)) continue;
        const row = try result.upsert(allocator, id, record.model);
        row.dev_present = true;
        row.dev_protocol = record.api;
        row.dev_output_tokens = if (record.api != .auto) record.output_tokens else null;
        row.dev_context_tokens = if (record.api != .auto) record.context_tokens else null;
        if (record.declaration) |declaration| row.dev_reasoning = try directory.Profile.from(declaration);
    }
    return result;
}
