//! Pure declaration editing. No credentials are inferred and no transport is used.
const std = @import("std");
const cfg = @import("../core/config.zig");
pub const Choice = enum { off, opencode_jev_free };
pub const native_url = "https://opencode.ai/inference/systemone/v1";
pub const raw_id = "jev-1.13-free";

pub fn isNative(provider: cfg.Provider) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, provider.base_url, "/"), native_url);
}

pub fn selected(config: cfg.Config) bool {
    const decision = config.decision orelse return false;
    if (!decision.enabled or decision.backend != .systemone) return false;
    const ref = cfg.splitDefault(decision.model) catch return false;
    if (!std.mem.eql(u8, ref.model, raw_id)) return false;
    const registry = config.registry orelse return false;
    return isNative((registry.find(ref.provider) orelse return false).connection);
}

/// Mutates only an arena-owned clone. False is an intentional no-write no-op.
pub fn apply(a: std.mem.Allocator, config: *cfg.Config, choice: Choice) !bool {
    if (choice == .off) {
        if (config.decision) |*decision| {
            decision.enabled = false;
            return true;
        }
        return false;
    }
    const registry = config.registry orelse return error.MissingRegistry;
    var name: ?[]const u8 = null;
    if (config.decision) |decision| {
        const ref = try cfg.splitDefault(decision.model);
        if (registry.find(ref.provider)) |provider| if (isNative(provider.connection)) {
            name = provider.name;
        };
    }
    if (name == null) {
        for (registry.providers) |provider| if (isNative(provider.connection)) {
            if (name != null) return error.AmbiguousDecisionProvider;
            name = provider.name;
        };
    }
    if (name == null) {
        if (registry.providers.len >= 16) return error.TooManyProviders;
        var candidate: []const u8 = "opencode-jev";
        var suffix: usize = 1;
        while (registry.find(candidate) != null) : (suffix += 1) {
            if (suffix > 16) return error.TooManyProviders;
            candidate = try std.fmt.allocPrint(a, "opencode-jev-{d}", .{suffix});
        }
        const providers = try a.alloc(cfg.NamedProvider, registry.providers.len + 1);
        @memcpy(providers[0..registry.providers.len], registry.providers);
        providers[registry.providers.len] = .{ .name = candidate, .connection = .{ .base_url = native_url } };
        config.registry.?.providers = providers;
        name = candidate;
    }
    var decision = config.decision orelse cfg.DecisionConfig{ .model = "" };
    decision.enabled = true;
    decision.backend = .systemone;
    decision.model = try std.fmt.allocPrint(a, "{s}/{s}", .{ name.?, raw_id });
    config.decision = decision;
    return true;
}

/// Own the settings while preserving frozen primary routing/capabilities/proxy.
pub fn activeClone(a: std.mem.Allocator, active: cfg.Config, declaration: cfg.Config) !std.json.Parsed(cfg.Config) {
    var candidate = active;
    candidate.registry = declaration.registry;
    candidate.decision = declaration.decision;
    candidate.limits.low_price_input = declaration.limits.low_price_input;
    return cfg.clone(a, candidate);
}
