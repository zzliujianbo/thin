//! Wire-safe session failure classification, independent of UI and Runtime.
const std = @import("std");

/// `other` is a generic remote failure, never a fabricated local error name.
pub const Failure = enum {
    other,
    cleanup_failed,
    unsafe_to_continue,
    input_budget_exceeded,
    unknown_input_price_threshold,
    input_budget_summary_failed,
    decision_unavailable,
    subagent_interaction_required,
    no_compaction_candidate,
    canceled,
    transport,
    timeout,
    protocol,
    rejected,

    pub fn fromError(err: anyerror) Failure {
        return switch (err) {
            error.CleanupFailed => .cleanup_failed,
            error.UnsafeToContinue => .unsafe_to_continue,
            error.InputBudgetExceeded => .input_budget_exceeded,
            error.UnknownInputPriceThreshold => .unknown_input_price_threshold,
            error.InputBudgetSummaryFailed => .input_budget_summary_failed,
            error.DecisionUnavailable => .decision_unavailable,
            error.SubagentInteractionRequired => .subagent_interaction_required,
            error.NoCompactionCandidate => .no_compaction_candidate,
            error.Canceled => .canceled,
            error.ConnectionLost, error.Transport => .transport,
            error.Timeout => .timeout,
            error.ProtocolError => .protocol,
            error.Rejected => .rejected,
            else => .other,
        };
    }

    /// Only `other` degrades to a generic remote error.
    pub fn toError(self: Failure) ?anyerror {
        return switch (self) {
            .cleanup_failed => error.CleanupFailed,
            .unsafe_to_continue => error.UnsafeToContinue,
            .input_budget_exceeded => error.InputBudgetExceeded,
            .unknown_input_price_threshold => error.UnknownInputPriceThreshold,
            .input_budget_summary_failed => error.InputBudgetSummaryFailed,
            .decision_unavailable => error.DecisionUnavailable,
            .subagent_interaction_required => error.SubagentInteractionRequired,
            .no_compaction_candidate => error.NoCompactionCandidate,
            .canceled => error.Canceled,
            .transport => error.Transport,
            .timeout => error.Timeout,
            .protocol => error.ProtocolError,
            .rejected => error.Rejected,
            .other => error.RemoteFailure,
        };
    }
};

test "session failure exact error round trips and aliases" {
    const cases = [_]struct { code: Failure, err: anyerror }{
        .{ .code = .cleanup_failed, .err = error.CleanupFailed },
        .{ .code = .unsafe_to_continue, .err = error.UnsafeToContinue },
        .{ .code = .input_budget_exceeded, .err = error.InputBudgetExceeded },
        .{ .code = .unknown_input_price_threshold, .err = error.UnknownInputPriceThreshold },
        .{ .code = .input_budget_summary_failed, .err = error.InputBudgetSummaryFailed },
        .{ .code = .decision_unavailable, .err = error.DecisionUnavailable },
        .{ .code = .subagent_interaction_required, .err = error.SubagentInteractionRequired },
        .{ .code = .no_compaction_candidate, .err = error.NoCompactionCandidate },
        .{ .code = .canceled, .err = error.Canceled },
        .{ .code = .transport, .err = error.Transport },
        .{ .code = .timeout, .err = error.Timeout },
        .{ .code = .protocol, .err = error.ProtocolError },
        .{ .code = .rejected, .err = error.Rejected },
    };
    try std.testing.expectEqual(std.meta.fieldNames(Failure).len - 1, cases.len);
    for (cases) |case| {
        try std.testing.expectEqual(case.code, Failure.fromError(case.err));
        try std.testing.expectEqual(case.err, case.code.toError().?);
    }
    try std.testing.expectEqual(Failure.transport, Failure.fromError(error.ConnectionLost));
    try std.testing.expectEqual(error.Transport, Failure.fromError(error.ConnectionLost).toError().?);
    try std.testing.expectEqual(Failure.other, Failure.fromError(error.SomethingElse));
    try std.testing.expectEqual(error.RemoteFailure, Failure.other.toError().?);
}
