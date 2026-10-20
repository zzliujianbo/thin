//! Bounded parser for the public models.dev catalog (no credentials).
//! Exact provider/model IDs are retained. Protocol comes from the declared AI SDK
//! adapter (`npm`) or exact native API URL, never from model names;
//! `reasoning: true` is not a profile.
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

const Source = enum { exact, majority };
const Resolution = struct {
    declaration: ?thinking.Declaration = null,
    source: ?Source = null,
};

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
                const token = try scanner.nextAllocMax(allocator, .alloc_if_needed, max_value_bytes);
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
        if (text.len == 0 or text.len > max_value_bytes or text[0] == '-') return null;
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
            if (!fraction) integer_digits += 1;
            if (byte != '0') {
                if (first == null) first = i;
                last = i;
            } else if (first == null) leading += 1;
        }
        const start = first orelse return .{ .digits = "", .magnitude = 0 };
        return .{ .digits = mantissa[start .. last + 1], .magnitude = exponent + integer_digits - leading };
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
const max_price_tiers = 128;

fn priceNumber(scanner: *std.json.Scanner, allocator: std.mem.Allocator) !?ExactPrice {
    if (!(try at(scanner, .number))) {
        try scanner.skipValue();
        return null;
    }
    const token = try scanner.nextAllocMax(allocator, .alloc_if_needed, max_value_bytes);
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
                const token = try scanner.nextAllocMax(allocator, .alloc_if_needed, max_value_bytes);
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
    var tiers: [max_price_tiers]PriceTier = undefined;
    var count: usize = 0;
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
                    if (count < tiers.len) {
                        tiers[count] = tier;
                        count += 1;
                    } else invalid = true;
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
    std.mem.sort(PriceTier, tiers[0..count], {}, struct {
        fn lessThan(_: void, left: PriceTier, right: PriceTier) bool {
            return (left.size orelse 0) < (right.size orelse 0);
        }
    }.lessThan);
    var threshold: ?u32 = null;
    for (tiers[0..count], 0..) |tier, i| {
        flat_eligible = flat_eligible and tier.flat_eligible;
        const ti = tier.input orelse return .{};
        const to = tier.output orelse return .{};
        const size = tier.size orelse return .{};
        const input_order = ti.order(input);
        const output_order = to.order(output);
        if (input_order == .lt or output_order == .lt) return .{};
        if (i != 0) {
            const previous = tiers[i - 1];
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
        if (record.api == .systemone) continue; // Identity only: no generative capabilities.
        row.dev_output_tokens = if (record.api != .auto) record.output_tokens else null;
        row.dev_context_tokens = if (record.api != .auto) record.context_tokens else null;
        row.dev_input_price_threshold = if (record.api != .auto) record.input_price_threshold else null;
        row.dev_input_price_flat_limit = if (record.api != .auto) record.input_price_flat_limit else null;
        const resolved = resolveIn(records, record.provider, record.model, record.api);
        if (resolved.declaration) |declaration| row.dev_reasoning = try directory.Profile.from(declaration);
    }
    // Missing supported presets may borrow only a complete reasoning profile
    // voted for their exact raw ID and verified preset route. No public listing,
    // window, output or price evidence is manufactured by this fallback.
    for (catalog.entries) |entry| {
        if (result.find(entry.provider, entry.model.name) != null) continue;
        const resolved = resolveIn(records, providerName(entry.provider), entry.model.name, entry.model.protocol);
        const declaration = resolved.declaration orelse continue;
        const row = try result.upsert(entry.provider, entry.model.name);
        row.dev_present = true;
        row.dev_protocol = entry.model.protocol;
        row.dev_reasoning = try directory.Profile.from(declaration);
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

test "model API URLs identify SystemOne without SDK or name inference" {
    const a = std.testing.allocator;
    const result = try parseDirectory(a,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"shared":{"api":{"url":"https://opencode.ai/inference/systemone/v1"},"limit":{"context":100000,"output":32000},"cost":{"input":1,"output":2},"reasoning_options":[{"type":"effort","values":["high"]}]},"no-window":{"api":{"url":"https://opencode.ai/inference/systemone/v1/"}},"jev-name-only":{},"bad-url":{"api":{"url":"https://opencode.ai.example/inference/systemone/v1"}},"bad-shape":{"api":"https://opencode.ai/inference/systemone/v1"},"bad-value":{"api":{"url":false}},"no-url":{"api":{}},"unrecognized":{"api":{"url":"https://opencode.ai/inference/systemone/v1","unknown":true}}}},"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"shared":{}}}}
    );
    for ([_][]const u8{ "shared", "no-window" }) |name| {
        const row = result.rows[result.find(.opencode_zen, name).?];
        try std.testing.expectEqual(protocol.Protocol.systemone, row.dev_protocol);
        try std.testing.expect(row.dev_reasoning == null);
        try std.testing.expect(row.dev_output_tokens == null);
        try std.testing.expect(row.dev_context_tokens == null);
        try std.testing.expect(row.dev_input_price_threshold == null);
        try std.testing.expect(row.dev_input_price_flat_limit == null);
    }
    try std.testing.expectEqual(protocol.Protocol.chat, result.rows[result.find(.opencode_go, "shared").?].dev_protocol);
    try std.testing.expectEqual(protocol.Protocol.chat, result.rows[result.find(.opencode_zen, "jev-name-only").?].dev_protocol);
    for ([_][]const u8{ "bad-shape", "bad-value", "unrecognized" }) |name| {
        try std.testing.expectEqual(protocol.Protocol.auto, result.rows[result.find(.opencode_zen, name).?].dev_protocol);
    }
    // Neither an empty descriptor nor an untrusted URL may override a known
    // SDK with SystemOne or redirect credentials to the metadata URL.
    for ([_][]const u8{ "bad-url", "no-url" }) |name| {
        try std.testing.expectEqual(protocol.Protocol.chat, result.rows[result.find(.opencode_zen, name).?].dev_protocol);
    }
    try std.testing.expectError(error.InvalidModelsDev, parseDirectory(a,
        \\{"opencode":{"models":{"x":{"api":{"url":"https://opencode.ai/inference/systemone/v1","url":"https://opencode.ai/inference/systemone/v1"}}}}}
    ));
    try std.testing.expectError(error.InvalidModelsDev, parseDirectory(a,
        \\{"opencode":{"models":{"x":{"api":{},"api":{}}}}}
    ));
}

test "API SDK and ID annotations preserve native and ordinary protocol sources" {
    const result = try parseDirectory(std.testing.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"native":{"api":{"id":"native","npm":"@ai-sdk/openai-compatible","url":"https://opencode.ai/inference/systemone/v1"}},"ordinary":{"api":{"id":"ordinary","npm":"@ai-sdk/anthropic","url":"https://vendor.invalid/v1"},"limit":{"context":32768}},"inherited":{"api":{"id":"inherited","url":"https://vendor.invalid/v1"},"limit":{"context":32768}},"unknown":{"api":{"npm":"@ai-sdk/unknown"}},"malformed":{"api":{"url":"not-an-absolute-url"}}}}}
    );
    const native = result.rows[result.find(.opencode_zen, "native").?];
    try std.testing.expectEqual(protocol.Protocol.systemone, native.dev_protocol);
    try std.testing.expect(native.dev_context_tokens == null);
    try std.testing.expectEqual(protocol.Protocol.anthropic, result.rows[result.find(.opencode_zen, "ordinary").?].dev_protocol);
    const inherited = result.rows[result.find(.opencode_zen, "inherited").?];
    try std.testing.expectEqual(protocol.Protocol.chat, inherited.dev_protocol);
    try std.testing.expectEqual(@as(?u32, 32768), inherited.dev_context_tokens);
    for ([_][]const u8{ "unknown", "malformed" }) |name| {
        try std.testing.expectEqual(protocol.Protocol.auto, result.rows[result.find(.opencode_zen, name).?].dev_protocol);
    }
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
    const parsed = try parseDirectory(t.allocator, body);
    const luna = parsed.rows[parsed.find(.opencode_go, "gpt-6-luna").?].dev_reasoning.?.declaration();
    try t.expectEqual(thinking.Format.standard, luna.format);
    try t.expectEqualStrings("none", luna.map.off.?);
    const haiku = parsed.rows[parsed.find(.opencode_go, "claude-haiku-5-5").?];
    // The exact Go row has no usable option; the anthropic-provider row is not
    // used because "extreme" makes that whole option set unusable.
    try t.expect(haiku.dev_reasoning == null);
    try t.expectEqual(protocol.Protocol.responses, protocolFor("@ai-sdk/openai"));
    try t.expectEqual(protocol.Protocol.chat, protocolFor("@ai-sdk/openai-compatible"));
    try t.expectEqual(protocol.Protocol.anthropic, protocolFor("@ai-sdk/anthropic"));
    try t.expectEqual(protocol.Protocol.auto, protocolFor("@ai-sdk/google"));
}

test "models.dev Haiku majority is a complete normalized profile, not a union" {
    // Synthetic offline fixture only. Never included in production data.
    const parsed = try parseDirectory(std.testing.allocator, @embedFile("models_dev_fixture.json"));
    const haiku = parsed.rows[parsed.find(.opencode_go, "claude-haiku-5-5").?];
    const declaration = haiku.dev_reasoning.?.declaration();
    try std.testing.expectEqual(thinking.Format.anthropic, declaration.format);
    try std.testing.expectEqualStrings("disabled", declaration.map.off.?);
    try std.testing.expectEqualStrings("low", declaration.map.low.?);
    try std.testing.expectEqualStrings("high", declaration.map.high.?);
    try std.testing.expectEqualStrings("max", declaration.map.max.?);
    try std.testing.expect(declaration.map.medium == null); // Minority profile is not merged.
    const luna = parsed.rows[parsed.find(.opencode_go, "gpt-6-luna").?];
    try std.testing.expectEqualStrings("none", luna.dev_reasoning.?.declaration().map.off.?);
}

test "models.dev absent presets receive reasoning only and exact route conflicts never fallback" {
    const a = std.testing.allocator;
    const absent = try parseDirectory(a,
        \\{"foreign":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"limit":{"context":1000000,"output":8192},"cost":{"input":1,"output":2},"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high"]}]}}}}
    );
    const row = absent.rows[absent.find(.opencode_go, "claude-haiku-5-5").?];
    try std.testing.expectEqual(protocol.Protocol.anthropic, row.dev_protocol);
    try std.testing.expectEqualStrings("high", row.dev_reasoning.?.declaration().map.high.?);
    try std.testing.expect(row.available == null);
    try std.testing.expect(row.tokens == null);
    try std.testing.expect(row.output_tokens == null);
    try std.testing.expect(row.dev_context_tokens == null);
    try std.testing.expect(row.dev_output_tokens == null);
    try std.testing.expect(row.dev_input_price_threshold == null);
    try std.testing.expect(row.dev_input_price_flat_limit == null);
    const conflict = try parseDirectory(a,
        \\{"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"claude-haiku-5-5":{}}},"foreign":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high"]}]}}}}
    );
    const exact = conflict.rows[conflict.find(.opencode_go, "claude-haiku-5-5").?];
    try std.testing.expectEqual(protocol.Protocol.chat, exact.dev_protocol);
    try std.testing.expect(exact.dev_reasoning == null);
}

test "models.dev format mismatch cannot turn DeepSeek thinking toggle into standard effort" {
    const standard: thinking.Declaration = .{ .map = .{ .off = "none", .high = "high" } };
    const records = [_]Record{testRecord("fixture", "deepseek-flash", .chat, standard)};
    try std.testing.expect(resolveIn(&records, "deepseek", "deepseek-flash", .chat).declaration == null);
}

test "models.dev malformed toggle values neither authorize exact profiles nor cast votes" {
    const a = std.testing.allocator;

    for ([_][]const u8{ "42", "null", "[]", "[false]", "[\"high\",false]", "[\"high\",\"high\"]" }) |bad_values| {
        const bad = try std.mem.concat(a, u8, &.{
            \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"reasoning_options":[{"type":"toggle","values":
            ,
            bad_values,
            \\},{"type":"effort","values":["high"]}]}}}}
            ,
        });
        defer a.free(bad);
        const bad_directory = try parseDirectory(a, bad);
        try std.testing.expect(bad_directory.rows[bad_directory.find(.opencode_go, "claude-haiku-5-5").?].dev_reasoning == null);
        const fallback = try std.mem.concat(a, u8, &.{
            bad[0 .. bad.len - 1],
            \\,"valid":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high"]}]}}}}
            ,
        });
        defer a.free(fallback);
        const fallback_directory = try parseDirectory(a, fallback);
        const resolved = fallback_directory.rows[fallback_directory.find(.opencode_go, "claude-haiku-5-5").?];
        try std.testing.expectEqualStrings("high", resolved.dev_reasoning.?.declaration().map.high.?);
        const tied = try std.mem.concat(a, u8, &.{
            fallback[0 .. fallback.len - 1],
            \\,"other":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["low"]}]}}}}
            ,
        });
        defer a.free(tied);
        // The malformed high row must not break the valid high/low tie.
        const tied_directory = try parseDirectory(a, tied);
        try std.testing.expect(tied_directory.rows[tied_directory.find(.opencode_go, "claude-haiku-5-5").?].dev_reasoning == null);
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

test "models.dev complete flat price schedules differ from missing or malformed pricing" {
    const a = std.testing.allocator;
    const Case = struct { cost: []const u8, flat: ?u32 = null, step: ?u32 = null };
    for ([_]Case{
        .{ .cost = "{\"input\":1,\"output\":2}", .flat = 1000000 },
        .{ .cost = "{\"input\":0,\"output\":0,\"tiers\":[]}", .flat = 1000000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"cache_read\":0.1,\"cache_write\":0.2,\"reasoning\":2,\"input_audio\":3,\"output_audio\":4}", .flat = 1000000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"context_over_200k\":{\"input\":2,\"output\":3}}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"future_price_schedule\":{}}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"cache_read\":{\"input\":3}}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"cache_read\":0.1,\"cache_read\":0.2}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1,\"output\":2,\"cache_read\":0.5,\"tier\":{\"type\":\"context\",\"size\":100000}}]}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"context_over_200k\":{},\"tiers\":[{\"input\":2,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .step = 100000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .flat = 1000000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":2,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .step = 100000 },
        .{ .cost = "null" },
        .{ .cost = "{}" },
        .{ .cost = "{\"input\":1}" },
        .{ .cost = "{\"input\":-1,\"output\":2}" },
        .{ .cost = "{\"input\":1e100001,\"output\":2}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":null}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":2}]}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":2,\"output\":3,\"tier\":{\"type\":\"future\",\"size\":100000}}]}" },
    }) |case| {
        const body = try std.mem.concat(a, u8, &.{ "{\"opencode-go\":{\"npm\":\"@ai-sdk/anthropic\",\"models\":{\"flat\":{\"limit\":{\"context\":1000000},\"cost\":", case.cost, "}}}}" });
        defer a.free(body);
        const result = try parseDirectory(a, body);
        try std.testing.expectEqual(case.step, result.rows[0].dev_input_price_threshold);
        try std.testing.expectEqual(case.flat, result.rows[0].dev_input_price_flat_limit);
    }
    const incomplete = try parseDirectory(a,
        \\{"opencode-go":{"models":{"flat":{"limit":{"context":1000000},"cost":{"input":1,"output":2}}}},"opencode":{"npm":"@ai-sdk/openai","models":{"flat":{"cost":{"input":1,"output":2}}}}}
    );
    for (incomplete.rows[0..incomplete.count]) |row| {
        try std.testing.expect(row.dev_input_price_threshold == null);
        try std.testing.expect(row.dev_input_price_flat_limit == null);
    }
}

test "models.dev malformed options and explicit invalid adapters are model-local unknowns" {
    const body =
        \\{"opencode-go":{"npm":"@ai-sdk/openai","models":{"gpt-6-luna":{"provider":{"npm":42},"reasoning_options":[{"type":"effort","values":["low"]}]},"claude-haiku-5-5":{"provider":{"npm":"@ai-sdk/anthropic"},"reasoning_options":[false,null,12]},"mimo-v2.5":{"reasoning":true}}}}
    ;
    const parsed = try parseDirectory(std.testing.allocator, body);
    for ([_][]const u8{ "gpt-6-luna", "claude-haiku-5-5", "mimo-v2.5" }) |name| {
        try std.testing.expect(parsed.rows[parsed.find(.opencode_go, name).?].dev_reasoning == null);
    }
}
