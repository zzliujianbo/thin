//! Bounded parser for the public models.dev catalog (no credentials).
//! Exact provider/model IDs are retained. Protocol comes from the declared AI SDK
//! adapter (`npm`) or exact native API URL, never from model names;
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
    input_price_threshold: ?u32 = null,
    input_price_flat_limit: ?u32 = null,
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
        .auto, .systemone => null,
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

/// Only an exact model-level api.url has native routing authority. SDK/id
/// annotations do not invalidate a valid native description. Other URLs never
/// replace the declared connection: ordinary protocols retain their SDK source.
/// Null inherits that source; auto revokes it for a malformed/unknown descriptor.
fn parseAPI(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !?protocol.Protocol {
    if (!(try at(scanner, .object_begin))) {
        try scanner.skipValue();
        return .auto;
    }
    try expect(scanner, allocator, .object_begin);
    var api_url: ?[]const u8 = null;
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
                api_url = value;
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
    if (api_url) |value| if (providers.Id.fromSystemOneUrl(value) != null) return .systemone;
    if (npm) |value| return protocolFor(value);
    return null;
}

const Limits = struct { output: ?u32 = null, context: ?u32 = null };
const ModelRow = struct { npm: ?[]const u8 = null, profile: Profile = .{}, override_invalid: bool = false, described_api: ?protocol.Protocol = null, limits: Limits = .{}, input_price_threshold: ?u32 = null, input_price_flat: bool = false };

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

// Pricing is ancillary: malformed values invalidate only this capability. Keep
// duplicate recognized keys strict and bound tier work/storage independently.
/// Borrowed complete-input/arena token bytes, used only during parseCost.
/// No binary floating-point rounding and no per-tier digit buffers.
const ExactPrice = struct {
    digits: []const u8,
    magnitude: i32,

    // Scanner already validated JSON-number syntax; only the bounded numeric
    // domain and canonical comparison view are established here.
    fn parse(text: []const u8) ?ExactPrice {
        if (text.len == 0 or text[0] == '-') return null;
        const exponent_at = std.mem.indexOfAny(u8, text, "eE") orelse text.len;
        const mantissa = text[0..exponent_at];
        const exponent = if (exponent_at < text.len)
            std.fmt.parseInt(i32, text[exponent_at + 1 ..], 10) catch return null
        else
            0;
        // Deliberate ancillary-capability bound, including zero-valued prices.
        if (exponent < -100000 or exponent > 100000) return null;
        var first: ?usize = null;
        var last: usize = 0;
        var leading: i32 = 0;
        var integer_digits: i32 = 0;
        var fraction = false;
        for (mantissa, 0..) |byte, i| {
            if (byte == '.') {
                if (fraction) return null;
                fraction = true;
                continue;
            }
            if (byte < '0' or byte > '9') return null;
            if (!fraction) integer_digits = std.math.add(i32, integer_digits, 1) catch return null;
            if (byte != '0') {
                if (first == null) first = i;
                last = i;
            } else if (first == null) leading = std.math.add(i32, leading, 1) catch return null;
        }
        const start = first orelse return .{ .digits = "", .magnitude = 0 };
        const magnitude = std.math.sub(i32, std.math.add(i32, exponent, integer_digits) catch return null, leading) catch return null;
        return .{ .digits = mantissa[start .. last + 1], .magnitude = magnitude };
    }

    fn order(left: ExactPrice, right: ExactPrice) std.math.Order {
        if (left.digits.len == 0 or right.digits.len == 0)
            return std.math.order(@intFromBool(left.digits.len != 0), @intFromBool(right.digits.len != 0));
        if (left.magnitude != right.magnitude) return std.math.order(left.magnitude, right.magnitude);
        var l: usize = 0;
        var r: usize = 0;
        while (l < left.digits.len or r < right.digits.len) {
            if (l < left.digits.len and left.digits[l] == '.') l += 1;
            if (r < right.digits.len and right.digits[r] == '.') r += 1;
            const a = if (l < left.digits.len) left.digits[l] else '0';
            const b = if (r < right.digits.len) right.digits[r] else '0';
            if (a != b) return std.math.order(a, b);
            if (l < left.digits.len) l += 1;
            if (r < right.digits.len) r += 1;
        }
        return .eq;
    }
};
const PriceTier = struct { input: ?ExactPrice = null, output: ?ExactPrice = null, size: ?u32 = null, flat_eligible: bool = true };
const PriceSchedule = struct { threshold: ?u32 = null, flat: bool = false };

fn priceNumber(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !?ExactPrice {
    if (!(try at(scanner, .number))) {
        try scanner.skipValue();
        return null;
    }
    const token = try scanner.nextAllocMax(allocator, .alloc_if_needed, scanner.input.len);
    const text = switch (token) {
        .number, .allocated_number => |v| v,
        else => unreachable,
    };
    return ExactPrice.parse(text);
}

const TierSize = struct { size: ?u32 = null, flat_eligible: bool = true };
fn tierSize(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !TierSize {
    if (!(try at(scanner, .object_begin))) {
        try scanner.skipValue();
        return .{};
    }
    try expect(scanner, allocator, .object_begin);
    var seen_type = false;
    var seen_size = false;
    var context = false;
    var size: ?u32 = null;
    var flat_eligible = true;
    while (!(try at(scanner, .object_end))) {
        const key = try nextString(scanner, allocator);
        if (equal(key, "type")) {
            if (seen_type) return error.InvalidModelsDev;
            seen_type = true;
            const kind = try optionalString(scanner, allocator);
            context = if (kind) |v| equal(v, "context") else false;
        } else if (equal(key, "size")) {
            if (seen_size) return error.InvalidModelsDev;
            seen_size = true;
            if (try at(scanner, .number)) {
                const token = try scanner.nextAllocMax(allocator, .alloc_if_needed, scanner.input.len);
                const text = switch (token) {
                    .number, .allocated_number => |v| v,
                    else => unreachable,
                };
                const n = std.fmt.parseInt(u32, text, 10) catch 0;
                if (n > 0 and n <= 16777216) size = n;
            } else try scanner.skipValue();
        } else {
            flat_eligible = false;
            try scanner.skipValue();
        }
    }
    try expect(scanner, allocator, .object_end);
    return .{ .size = if (context) size else null, .flat_eligible = flat_eligible };
}

fn parsePriceTier(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !PriceTier {
    if (!(try at(scanner, .object_begin))) {
        try scanner.skipValue();
        return .{};
    }
    try expect(scanner, allocator, .object_begin);
    var result: PriceTier = .{};
    var seen: u8 = 0;
    while (!(try at(scanner, .object_end))) {
        const key = try nextString(scanner, allocator);
        const bit: u8 = if (equal(key, "input")) 1 else if (equal(key, "output")) 2 else if (equal(key, "tier")) 4 else 0;
        if (bit == 0) {
            result.flat_eligible = false;
            try scanner.skipValue();
            continue;
        }
        if (seen & bit != 0) return error.InvalidModelsDev;
        seen |= bit;
        switch (bit) {
            1 => result.input = try priceNumber(scanner, allocator),
            2 => result.output = try priceNumber(scanner, allocator),
            4 => {
                const descriptor = try tierSize(scanner, allocator);
                result.size = descriptor.size;
                result.flat_eligible = result.flat_eligible and descriptor.flat_eligible;
            },
            else => unreachable,
        }
    }
    try expect(scanner, allocator, .object_end);
    return result;
}

fn parseCost(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !PriceSchedule {
    if (!(try at(scanner, .object_begin))) {
        try scanner.skipValue();
        return .{};
    }
    try expect(scanner, allocator, .object_begin);
    var baseline: PriceTier = .{};
    var seen: u8 = 0;
    var tiers: std.ArrayList(PriceTier) = .empty;
    defer tiers.deinit(allocator);
    var invalid = false;
    var flat_eligible = true;
    var seen_scalar: u8 = 0;
    while (!(try at(scanner, .object_end))) {
        const key = try nextString(scanner, allocator);
        const bit: u8 = if (equal(key, "input")) 1 else if (equal(key, "output")) 2 else if (equal(key, "tiers")) 4 else 0;
        if (bit == 0) {
            const scalar: u8 = if (equal(key, "cache_read")) 1 else if (equal(key, "cache_write")) 2 else if (equal(key, "reasoning")) 4 else if (equal(key, "input_audio")) 8 else if (equal(key, "output_audio")) 16 else 0;
            if (scalar == 0) {
                // Legacy context_over_200k and future pricing shapes are not
                // evidence of flat pricing. Keep any independently valid tier.
                flat_eligible = false;
                try scanner.skipValue();
            } else {
                if (seen_scalar & scalar != 0) flat_eligible = false;
                seen_scalar |= scalar;
                if (try priceNumber(scanner, allocator) == null) flat_eligible = false;
            }
            continue;
        }
        if (seen & bit != 0) return error.InvalidModelsDev;
        seen |= bit;
        switch (bit) {
            1 => baseline.input = try priceNumber(scanner, allocator),
            2 => baseline.output = try priceNumber(scanner, allocator),
            4 => {
                if (!(try at(scanner, .array_begin))) {
                    try scanner.skipValue();
                    invalid = true;
                    continue;
                }
                try expect(scanner, allocator, .array_begin);
                while (!(try at(scanner, .array_end))) {
                    const tier = try parsePriceTier(scanner, allocator);
                    try tiers.append(allocator, tier);
                }
                try expect(scanner, allocator, .array_end);
            },
            else => unreachable,
        }
    }
    try expect(scanner, allocator, .object_end);
    if (invalid) return .{};
    const input = baseline.input orelse return .{};
    const output = baseline.output orelse return .{};
    // Sort integer bounds first: exact decimal comparisons then need only
    // adjacent tiers, not quadratic work over long price token prefixes.
    std.mem.sort(PriceTier, tiers.items, {}, struct {
        fn lessThan(_: void, left: PriceTier, right: PriceTier) bool {
            return (left.size orelse 0) < (right.size orelse 0);
        }
    }.lessThan);
    var threshold: ?u32 = null;
    for (tiers.items, 0..) |tier, i| {
        flat_eligible = flat_eligible and tier.flat_eligible;
        const ti = tier.input orelse return .{};
        const to = tier.output orelse return .{};
        const size = tier.size orelse return .{};
        const input_order = ti.order(input);
        const output_order = to.order(output);
        if (input_order == .lt or output_order == .lt) return .{};
        if (i != 0) {
            const previous = tiers.items[i - 1];
            const pi = previous.input.?.order(ti);
            const po = previous.output.?.order(to);
            if (previous.size == size and (pi != .eq or po != .eq)) return .{};
            if (pi == .gt or po == .gt) return .{};
        }
        if (input_order == .gt or output_order == .gt) threshold = if (threshold) |n| @min(n, size) else size;
    }
    return .{ .threshold = threshold, .flat = threshold == null and flat_eligible };
}

fn parseModel(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !ModelRow {
    try expect(scanner, allocator, .object_begin);
    var row: ModelRow = .{};
    var saw_options = false;
    var saw_provider = false;
    var saw_api = false;
    var saw_limit = false;
    var saw_cost = false;
    while (!(try at(scanner, .object_end))) {
        const field = try nextString(scanner, allocator);
        if (equal(field, "api")) {
            if (saw_api) return error.InvalidModelsDev;
            saw_api = true;
            row.described_api = try parseAPI(scanner, allocator);
        } else if (equal(field, "cost")) {
            if (saw_cost) return error.InvalidModelsDev;
            saw_cost = true;
            const schedule = try parseCost(scanner, allocator);
            row.input_price_threshold = schedule.threshold;
            row.input_price_flat = schedule.flat;
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
        try records.append(allocator, .{ .provider = provider, .model = model, .profile = row.profile, .npm = row.npm, .override_invalid = row.override_invalid, .described_api = row.described_api, .output_tokens = row.limits.output, .context_tokens = row.limits.context, .input_price_threshold = row.input_price_threshold, .input_price_flat_limit = if (row.input_price_flat) row.limits.context else null });
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

/// Exact rows for the three supported services. Adapter identity is independent
/// of reasoning availability. All keys and profiles are safe to copy by value.
pub fn parseDirectory(allocator: std.mem.Allocator, body: []const u8) !directory.Directory {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const records = try scan(arena.allocator(), body);
    var result: directory.Directory = .{};
    errdefer result.deinit(allocator);
    for (records) |record| {
        const id = providerId(record.provider) orelse continue;
        const row = try result.upsert(allocator, id, record.model);
        row.dev_present = true;
        row.dev_protocol = record.api;
        if (record.api == .systemone) continue; // Identity only: no generative capabilities.
        row.dev_output_tokens = if (record.api != .auto) record.output_tokens else null;
        row.dev_context_tokens = if (record.api != .auto) record.context_tokens else null;
        row.dev_input_price_threshold = if (record.api != .auto) record.input_price_threshold else null;
        row.dev_input_price_flat_limit = if (record.api != .auto) record.input_price_flat_limit else null;
        if (record.declaration) |declaration| row.dev_reasoning = try directory.Profile.from(declaration);
    }
    return result;
}
