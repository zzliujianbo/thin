//! Pure, transactional edits of the five user-facing preferences.
const cfg = @import("config.zig");

pub const Key = enum {
    compaction_enabled,
    command_timeout_ms,
    request_timeout_ms,
    max_output_tokens,
    task_timeout_ms,
};

/// Validate a shallow candidate before publishing even its scalar fields.
/// No budget, model, credential or unrelated declaration is inferred here.
pub fn apply(config: *cfg.Config, key: Key, value: ?u32) !void {
    var candidate = config.*;
    switch (key) {
        .compaction_enabled => {
            const enabled = value orelse return error.InvalidLimit;
            if (enabled > 1) return error.InvalidLimit;
            candidate.limits.compaction_enabled = enabled == 1;
        },
        .max_output_tokens => candidate.limits.max_output_tokens = value,
        .command_timeout_ms => candidate.limits.command_timeout_ms = value orelse return error.InvalidLimit,
        .request_timeout_ms => candidate.limits.request_timeout_ms = value orelse return error.InvalidLimit,
        .task_timeout_ms => candidate.limits.task_timeout_ms = value orelse return error.InvalidLimit,
    }
    try cfg.validate(candidate);
    config.* = candidate;
}
