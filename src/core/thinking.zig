//! Explicit logical capabilities and wire mapping. No discovery, credentials,
//! substring model inference, or frontend/terminal dependencies.
const std = @import("std");
const activity = @import("../presentation/activity.zig");
pub const Format = enum { standard, deepseek, anthropic };
pub const LevelMap = struct {
    off: ?[]const u8 = null,
    minimal: ?[]const u8 = null,
    low: ?[]const u8 = null,
    medium: ?[]const u8 = null,
    high: ?[]const u8 = null,
    xhigh: ?[]const u8 = null,
    max: ?[]const u8 = null,

    pub fn get(self: LevelMap, effort: activity.ReasoningEffort) ?[]const u8 {
        return switch (effort) {
            .off => self.off,
            .minimal => self.minimal,
            .low => self.low,
            .medium => self.medium,
            .high => self.high,
            .xhigh => self.xhigh,
            .max => self.max,
            else => null,
        };
    }
    pub fn levels(self: LevelMap) activity.EffortSet {
        var set: activity.EffortSet = .{};
        for (activity.effort_order, 0..) |level, i| {
            if (self.get(level) != null) set.mask |= @as(u8, 1) << @intCast(i);
        }
        return set;
    }
};
pub const Declaration = struct {
    format: Format = .standard,
    map: LevelMap,

    pub fn validate(self: Declaration) !void {
        if (self.map.levels().count() == 0) return error.InvalidReasoningMap;
        for (activity.effort_order) |level| {
            if (self.map.get(level)) |value| {
                if (value.len == 0 or value.len > 128 or std.mem.trim(u8, value, " ").len == 0) return error.InvalidReasoningMap;
                for (value) |c| if (c < 0x20 or c == 0x7f) return error.InvalidReasoningMap;
            }
        }
        if (self.format == .deepseek and self.map.off == null) return error.InvalidReasoningMap;
    }
};
/// New-project default. Only supplied declarations authorize capability clamps.
pub const default_level: activity.ReasoningEffort = .off;

pub const Wire = struct { effort: ?[]const u8, thinking: ?bool = null };
pub const Capabilities = struct {
    known: bool = false,
    levels: activity.EffortSet = .{},
    format: Format = .standard,
    map: LevelMap = .{},

    /// Seed a new project preference from an explicit logical choice, otherwise
    /// off. Unknown capabilities still do not authorize sending this option.
    pub fn defaultEffort(self: Capabilities, configured: ?[]const u8) activity.ReasoningEffort {
        const logical = activity.ReasoningEffort.fromName(configured);
        const requested = if (logical.name() != null) logical else default_level;
        if (requested == .off) return .off;
        return self.levels.clamp(requested) orelse requested;
    }

    pub fn effective(self: Capabilities, configured: ?[]const u8) ?[]const u8 {
        const value = configured orelse return null;
        if (!self.known) return value;
        const logical = activity.ReasoningEffort.fromName(value);
        // Custom wire options are not silently interpreted as logical levels.
        if (logical == .unknown) return value;
        const level = self.levels.clamp(logical) orelse return null;
        return level.name();
    }
    pub fn wire(self: Capabilities, configured: ?[]const u8) Wire {
        const value = self.effective(configured) orelse return .{ .effort = null };
        if (!self.known) return .{ .effort = value };
        const logical = activity.ReasoningEffort.fromName(value);
        if (self.format == .deepseek or self.format == .anthropic) {
            if (logical == .off) return .{ .effort = null, .thinking = false };
            return .{ .effort = if (logical == .unknown) value else self.map.get(logical), .thinking = true };
        }
        return .{ .effort = if (logical == .unknown) value else self.map.get(logical) };
    }
};
fn declared(d: Declaration) Capabilities {
    return .{ .known = true, .levels = d.map.levels(), .format = d.format, .map = d.map };
}
/// Capabilities require an explicit or dynamically supplied declaration.
/// Endpoint and model identity alone never manufacture reasoning capabilities.
pub fn resolve(_: []const u8, _: []const u8, declaration: ?Declaration) Capabilities {
    const d = declaration orelse return .{};
    d.validate() catch return .{};
    return declared(d);
}

test "default off shared fallback preserves explicit logical choices" {
    const t = std.testing;
    const standard = resolve("https://api.openai.com/v1", "gpt-5.2", .{ .map = .{ .off = "none", .low = "low", .medium = "medium", .high = "high" } });
    try t.expectEqual(activity.ReasoningEffort.off, standard.defaultEffort(null));
    try t.expectEqual(activity.ReasoningEffort.low, standard.defaultEffort("low"));
    try t.expectEqual(activity.ReasoningEffort.off, standard.defaultEffort("off"));
    try t.expectEqual(activity.ReasoningEffort.off, resolve("https://api.deepseek.com", "deepseek-flash", .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } }).defaultEffort(null));
    try t.expectEqual(activity.ReasoningEffort.off, resolve("https://fixture.invalid", "no-off", .{ .map = .{ .high = "high" } }).defaultEffort(null));
    try t.expectEqual(activity.ReasoningEffort.off, resolve("https://api.openai.com/v1", "gpt-4o", .{ .map = .{ .off = "none" } }).defaultEffort(null));
    const unknown = resolve("https://proxy.invalid", "custom", null);
    try t.expectEqual(activity.ReasoningEffort.off, unknown.defaultEffort(null));
    try t.expect(unknown.wire(null).effort == null); // A saved default is not a capability declaration.
}

test "no builtin capabilities exist for official endpoints or recognized model names" {
    const t = std.testing;
    for ([_][]const u8{ "http://api.openai.com/v1", "https://api.openai.com/v1//", "https://api.openai.com.evil/v1", "https://proxy/v1" }) |url| {
        const cap = resolve(url, "gpt-5.2", null);
        try t.expect(!cap.known and cap.levels.mask == 0);
        try t.expectEqualStrings("custom", cap.effective("custom").?);
    }
    try t.expect(!resolve("https://api.openai.com/v1", "gpt-5.2-new", null).known);
    for ([_][]const u8{ "https://api.openai.com/v1", "https://api.deepseek.com", "https://opencode.ai/zen/v1", "https://opencode.ai/zen/go/v1" }) |url| {
        for ([_][]const u8{ "gpt-4o", "gpt-5.2", "gpt-5.6-luna", "gpt-6-luna", "deepseek-flash", "deepseek-v4-pro", "claude-haiku-5-5" }) |name| {
            const missing = resolve(url, name, null);
            try t.expect(!missing.known and missing.levels.mask == 0);
        }
    }
    const cap = resolve("https://api.openai.com/v1/", "gpt-5.2", .{ .map = .{ .off = "none", .low = "low", .high = "high", .xhigh = "xhigh" } });
    try t.expectEqualStrings("high", cap.effective("high").?);
    try t.expectEqualStrings("low", cap.effective("minimal").?);
    try t.expectEqualStrings("xhigh", cap.effective("max").?);
    try t.expectEqualStrings("none", cap.wire("none").effort.?);
    try t.expectEqualStrings("none", cap.wire("off").effort.?);
    try t.expectEqual(activity.ReasoningEffort.off, cap.defaultEffort("none"));
    try t.expect(cap.wire(null).effort == null and cap.wire(null).thinking == null);
    const unknown = resolve("https://api.openai.com/v1", "gpt-4o", null);
    try t.expect(!unknown.known);
    try t.expect(unknown.wire(null).effort == null);
    try t.expect(!resolve("https://api.openai.com/v1", "gpt-6-sol", null).levels.contains(.max));
}
test "deepseek wire and custom maps preserve unspecified validate bounded strings" {
    const t = std.testing;
    for ([_][]const u8{ "https://api.deepseek.com", "https://api.deepseek.com/v1/" }) |url| {
        const cap = resolve(url, "deepseek-flash", .{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high", .max = "max" } });
        try t.expectEqual(@as(usize, 4), cap.levels.count());
        try t.expectEqualStrings("high", cap.effective("medium").?);
        try t.expect(cap.wire("off").thinking.? == false and cap.wire("off").effort == null);
        try t.expect(cap.wire("max").thinking.?);
        try t.expectEqualStrings("max", cap.wire("max").effort.?);
        try t.expect(cap.wire(null).thinking == null);
    }
    for ([_][]const u8{ "https://api.deepseek.com.evil", "http://api.deepseek.com", "https://api.deepseek.com/v2", "https://api.deepseek.com/v1//" }) |url| {
        try t.expect(!resolve(url, "deepseek-flash", null).known);
    }
    try t.expect(!resolve("https://api.deepseek.com", "prefix-deepseek-flash", null).known);
    const pro = resolve("https://api.deepseek.com", "deepseek-v4-pro", .{ .format = .deepseek, .map = .{ .off = "off", .high = "high", .max = "max" } });
    try t.expectEqualStrings("high", pro.effective("low").?);
    try t.expectEqual(@as(usize, 3), pro.levels.count());
    try t.expect(!pro.levels.contains(.low));
    const custom = resolve("https://proxy", "custom", .{ .map = .{ .off = "disabled", .high = "intensive" } });
    try t.expectEqualStrings("intensive", custom.wire("low").effort.?);
    try t.expectEqualStrings("disabled", custom.wire("off").effort.?);
    // Raw model wire options are opaque, not logical off aliases.
    try t.expectEqualStrings("none", custom.wire("none").effort.?);
    try t.expectError(error.InvalidReasoningMap, (Declaration{ .map = .{} }).validate());
    try t.expectError(error.InvalidReasoningMap, (Declaration{ .format = .deepseek, .map = .{ .high = "high" } }).validate());
    const too_long: [129]u8 = @splat('x');
    for ([_][]const u8{ "", "   ", "bad\n", "bad\x7f", &too_long }) |bad| {
        try t.expectError(error.InvalidReasoningMap, (Declaration{ .map = .{ .low = bad } }).validate());
    }
}
