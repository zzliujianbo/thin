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
