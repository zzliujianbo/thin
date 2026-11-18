//! Wire-safe session failure classification, independent of UI and Runtime.

/// `other` is a generic remote failure, never a fabricated local error name.
pub const Failure = enum {
    other,
    cleanup_failed,
    unsafe_to_continue,
    input_budget_exceeded,
    unknown_input_price_threshold,
    input_budget_summary_failed,
    /// Compaction failures that must keep their own wording instead of
    /// degrading to the generic remote failure on the other side of the wire.
    insufficient_compaction,
    compaction_impossible,
    invalid_summary,
    summary_failed,
    summary_requested_tool,
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
            error.InsufficientCompaction => .insufficient_compaction,
            error.CompactionImpossible => .compaction_impossible,
            error.InvalidSummary => .invalid_summary,
            error.SummaryFailed => .summary_failed,
            error.SummaryRequestedTool => .summary_requested_tool,
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
            .insufficient_compaction => error.InsufficientCompaction,
            .compaction_impossible => error.CompactionImpossible,
            .invalid_summary => error.InvalidSummary,
            .summary_failed => error.SummaryFailed,
            .summary_requested_tool => error.SummaryRequestedTool,
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
