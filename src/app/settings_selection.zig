//! Pure declaration editing. No credentials are inferred and no transport is used.
const std = @import("std");
const cfg = @import("../core/config.zig");
pub const Choice = union(enum) { off, model: []const u8 };

/// Own the settings while preserving frozen primary routing/capabilities/proxy.
pub fn activeClone(a: std.mem.Allocator, active: cfg.Config, declaration: cfg.Config) !std.json.Parsed(cfg.Config) {
    var candidate = active;
    candidate.registry = declaration.registry;
    candidate.image = declaration.image;
    candidate.limits.low_price_input = declaration.limits.low_price_input;
    candidate.limits.compaction_enabled = declaration.limits.compaction_enabled;
    candidate.limits.show_reported_usage = declaration.limits.show_reported_usage;
    candidate.limits.command_timeout_ms = declaration.limits.command_timeout_ms;
    candidate.limits.request_timeout_ms = declaration.limits.request_timeout_ms;
    // A frozen active/pending selection may have different budget constraints
    // from the declaration. Reject before the caller's CAS save, not afterward.
    // Missing restored providers remain display-only, without inventing a route
    // or preventing independent global preference edits.
    if (candidate.selection_pending and candidate.provider.base_url.len == 0)
        return cfg.clonePendingSettings(a, candidate);
    return cfg.clone(a, candidate);
}
