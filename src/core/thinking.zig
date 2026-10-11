//! Explicit logical capabilities and wire mapping. No discovery, credentials,
//! substring model inference, or frontend/terminal dependencies.
const std = @import("std");
const activity = @import("../presentation/activity.zig");
pub const Format = enum { standard, deepseek };
pub const LevelMap = struct {
    off: ?[]const u8 = null,
    minimal: ?[]const u8 = null,
    low: ?[]const u8 = null,
    medium: ?[]const u8 = null,
    high: ?[]const u8 = null,
    xhigh: ?[]const u8 = null,
    max: ?[]const u8 = null,

    pub fn get(self: LevelMap, effort: activity.ReasoningEffort) ?[]const u8 {
        return switch (effort.canonical()) {
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
pub const Wire = struct { effort: ?[]const u8, thinking: ?bool = null };
pub const Capabilities = struct {
    known: bool = false,
    levels: activity.EffortSet = .{},
    format: Format = .standard,
    map: LevelMap = .{},

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
        if (self.format == .deepseek) {
            if (logical == .off) return .{ .effort = null, .thinking = false };
            return .{ .effort = if (logical == .unknown) value else self.map.get(logical), .thinking = true };
        }
        return .{ .effort = if (logical == .unknown) value else self.map.get(logical) };
    }
};
fn declared(d: Declaration) Capabilities {
    return .{ .known = true, .levels = d.map.levels(), .format = d.format, .map = d.map };
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn oneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |value| if (eq(name, value)) return true;
    return false;
}
/// Bounded exact official endpoint/model table from bundled public Pi metadata.
/// A proxy or future model requires an explicit declaration, never a name guess.
pub fn resolve(base_url: []const u8, name: []const u8, declaration: ?Declaration) Capabilities {
    if (declaration) |d| {
        d.validate() catch return .{};
        return declared(d);
    }
    if (oneOf(base_url, &.{ "https://api.deepseek.com", "https://api.deepseek.com/", "https://api.deepseek.com/v1", "https://api.deepseek.com/v1/" })) {
        if (eq(name, "deepseek-flash")) return declared(.{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high", .max = "max" } });
        if (eq(name, "deepseek-v4-pro")) return declared(.{ .format = .deepseek, .map = .{ .off = "off", .high = "high", .max = "max" } });
    }
    if (!oneOf(base_url, &.{ "https://api.openai.com/v1", "https://api.openai.com/v1/" })) return .{};
    if (oneOf(name, &.{ "gpt-4", "gpt-4-turbo", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini", "gpt-5-chat-latest" })) {
        // Disabled reasoning is selectable off, but has no wire parameter.
        return .{ .known = true, .levels = .{ .mask = 1 } };
    }
    if (oneOf(name, &.{ "o1", "o1-pro", "o3", "o3-mini", "o3-pro", "o4-mini" })) return declared(.{ .map = .{ .low = "low", .medium = "medium", .high = "high" } });
    if (oneOf(name, &.{ "gpt-5", "gpt-5-mini", "gpt-5-nano" })) return declared(.{ .map = .{ .minimal = "minimal", .low = "low", .medium = "medium", .high = "high" } });
    if (eq(name, "gpt-5-pro")) return declared(.{ .map = .{ .high = "high" } });
    if (eq(name, "gpt-5.1")) return declared(.{ .map = .{ .off = "none", .low = "low", .medium = "medium", .high = "high" } });
    if (oneOf(name, &.{ "gpt-5.2", "gpt-5.3-codex", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.5" })) return declared(.{ .map = .{ .off = "none", .low = "low", .medium = "medium", .high = "high", .xhigh = "xhigh" } });
    if (oneOf(name, &.{ "gpt-5.2-pro", "gpt-5.4-pro", "gpt-5.5-pro" })) return declared(.{ .map = .{ .medium = "medium", .high = "high", .xhigh = "xhigh" } });
    if (eq(name, "gpt-5.2-chat-latest")) return declared(.{ .map = .{ .medium = "medium", .xhigh = "xhigh" } });
    if (eq(name, "gpt-5.3-codex-spark")) return declared(.{ .map = .{ .low = "low", .medium = "medium", .high = "high", .xhigh = "xhigh" } });
    if (oneOf(name, &.{ "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-luna", "gpt-6-sol" })) return declared(.{ .map = .{ .off = "none", .low = "low", .medium = "medium", .high = "high", .xhigh = "xhigh", .max = "max" } });
    if (oneOf(name, &.{ "gpt-6-astra", "gpt-6.1-sol" })) return declared(.{ .map = .{ .low = "low", .medium = "medium", .high = "high", .xhigh = "xhigh", .max = "max" } });
    return .{};
}

test "exact official capabilities unknown preserves raw no discovery" {
    const t = std.testing;
    for ([_][]const u8{ "http://api.openai.com/v1", "https://api.openai.com/v1//", "https://api.openai.com.evil/v1", "https://proxy/v1" }) |url| {
        const cap = resolve(url, "gpt-5.2", null);
        try t.expect(!cap.known and cap.levels.mask == 0);
        try t.expectEqualStrings("custom", cap.effective("custom").?);
    }
    try t.expect(!resolve("https://api.openai.com/v1", "gpt-5.2-new", null).known);
    const cap = resolve("https://api.openai.com/v1/", "gpt-5.2", null);
    try t.expectEqualStrings("high", cap.effective("high").?);
    try t.expectEqualStrings("low", cap.effective("minimal").?);
    try t.expectEqualStrings("xhigh", cap.effective("max").?);
    try t.expectEqualStrings("none", cap.wire("none").effort.?);
    try t.expect(cap.wire(null).effort == null and cap.wire(null).thinking == null);
    const disabled = resolve("https://api.openai.com/v1", "gpt-4o", null);
    try t.expectEqualStrings("off", disabled.effective("max").?);
    try t.expect(disabled.wire("off").effort == null);
    try t.expect(resolve("https://api.openai.com/v1", "gpt-6-sol", null).levels.contains(.max));
}
test "deepseek wire and custom maps preserve unspecified validate bounded strings" {
    const t = std.testing;
    for ([_][]const u8{ "https://api.deepseek.com", "https://api.deepseek.com/v1/" }) |url| {
        const cap = resolve(url, "deepseek-flash", null);
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
    const pro = resolve("https://api.deepseek.com", "deepseek-v4-pro", null);
    try t.expectEqualStrings("high", pro.effective("low").?);
    try t.expectEqual(@as(usize, 3), pro.levels.count());
    try t.expect(!pro.levels.contains(.low));
    const custom = resolve("https://proxy", "custom", .{ .map = .{ .off = "disabled", .high = "intensive" } });
    try t.expectEqualStrings("intensive", custom.wire("low").effort.?);
    try t.expectEqualStrings("disabled", custom.wire("none").effort.?);
    try t.expectError(error.InvalidReasoningMap, (Declaration{ .map = .{} }).validate());
    try t.expectError(error.InvalidReasoningMap, (Declaration{ .format = .deepseek, .map = .{ .high = "high" } }).validate());
    const too_long: [129]u8 = @splat('x');
    for ([_][]const u8{ "", "   ", "bad\n", "bad\x7f", &too_long }) |bad| {
        try t.expectError(error.InvalidReasoningMap, (Declaration{ .map = .{ .low = bad } }).validate());
    }
}
