//! Pure declaration editing. No credentials are inferred and no transport is used.
const std = @import("std");
const cfg = @import("../core/config.zig");
pub const Choice = union(enum) { off, model: []const u8 };

/// Catalog eligibility only. The owner separately rechecks local credentials.
/// Auxiliary budgets do not inherit the primary low-price policy.
pub fn genericCandidate(config: cfg.Config, model: cfg.Model) bool {
    if (model.protocol == .auto or (model.protocol != .systemone and model.context_tokens == 0)) return false;
    const ref = cfg.splitDefault(model.name) catch return false;
    const registry = config.registry orelse return false;
    return registry.find(ref.provider) != null;
}

/// Mutates only an arena-owned clone. False is an intentional no-write no-op.
pub fn apply(a: std.mem.Allocator, config: *cfg.Config, choice: Choice) !bool {
    switch (choice) {
        .off => {
            if (config.decision) |*decision| {
                decision.enabled = false;
                return true;
            }
            return false;
        },
        .model => |name| {
            const ref = try cfg.splitDefault(name);
            const registry = config.registry orelse return error.MissingRegistry;
            _ = registry.find(ref.provider) orelse return error.UnknownProvider;
            var decision = config.decision orelse cfg.DecisionConfig{ .model = "" };
            decision.enabled = true;
            decision.model = try a.dupe(u8, name);
            config.decision = decision;
            return true;
        },
    }
}

/// Own the settings while preserving frozen primary routing/capabilities/proxy.
pub fn activeClone(a: std.mem.Allocator, active: cfg.Config, declaration: cfg.Config) !std.json.Parsed(cfg.Config) {
    var candidate = active;
    candidate.registry = declaration.registry;
    candidate.decision = declaration.decision;
    candidate.image = declaration.image;
    candidate.limits.low_price_input = declaration.limits.low_price_input;
    candidate.limits.compaction_enabled = declaration.limits.compaction_enabled;
    candidate.limits.command_timeout_ms = declaration.limits.command_timeout_ms;
    candidate.limits.request_timeout_ms = declaration.limits.request_timeout_ms;
    candidate.limits.max_output_tokens = declaration.limits.max_output_tokens;
    candidate.limits.task_timeout_ms = declaration.limits.task_timeout_ms;
    // A frozen active/pending selection may have different budget constraints
    // from the declaration. Reject before the caller's CAS save, not afterward.
    // Missing restored providers remain display-only, without inventing a route
    // or preventing independent global preference edits.
    if (candidate.selection_pending and candidate.provider.base_url.len == 0)
        return cfg.clonePendingSettings(a, candidate);
    return cfg.clone(a, candidate);
}
