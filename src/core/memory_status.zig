pub const Phase = enum { extracting, reviewing, saving };
pub const Result = enum { saved, skipped, failed, uncertain, canceled };
pub const Failure = enum { canceled, unavailable, invalid_output, conflict, busy, storage, cleanup, other };
pub const Active = struct { id: u64, phase: Phase };
pub const Terminal = struct { id: u64, result: Result, failure: ?Failure = null };
pub const View = struct {
    enabled: bool = false,
    revision: u64 = 0,
    active: ?Active = null,
    queued_count: u64 = 0,
    last_terminal: ?Terminal = null,
};
