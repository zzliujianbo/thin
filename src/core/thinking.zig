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
