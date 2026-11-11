//! Bounded, value-only, optional timing diagnostics. Never carries model text.
const std = @import("std");
const p = @import("protocol.zig");
const decision = @import("decision.zig");
pub const Stage = enum { assistant_commit, observer, checkpoint, host_emit, end_task, watchdog_join, memory_submit, memory_finalize, memory_extract, memory_write, memory_request, decision_request, finished_emit };
pub const Phase = enum { begin, end, point };
pub const Result = enum { ok, failed, canceled, skipped };
pub const ErrorName = struct {
    label: [96]u8 = @splat(0),
    len: u8 = 0,
    pub fn fromError(err: anyerror) ErrorName {
        var value: ErrorName = .{};
        const error_label = @errorName(err);
        const n = @min(error_label.len, value.label.len);
        @memcpy(value.label[0..n], error_label[0..n]);
        value.len = @intCast(n);
        return value;
    }
    pub fn name(self: *const ErrorName) []const u8 {
        return self.label[0..self.len];
    }
    pub fn jsonStringify(self: ErrorName, jw: anytype) !void {
        try jw.write(self.label[0..self.len]);
    }
};
pub const Origin = struct { turn: u64, began_ms: i64 };
pub const Record = struct {
    stage: Stage,
    origin: ?Origin = null,
    memory_job_id: ?u64 = null,
    phase: Phase = .point,
    span_id: u64 = 0,
    elapsed_ms: ?u64 = null,
    result: ?Result = null,
    error_name: ?ErrorName = null,
    operation: ?decision.Diagnostic.Operation = null,
    protocol: ?p.Protocol = null,
    backend: ?decision.Diagnostic.Backend = null,
    route_hash: ?u64 = null,
    timeout_ms: ?u32 = null,
    http_status: ?u16 = null,
    model_failure: ?p.FailureKind = null,
    decision_failure: ?decision.Diagnostic = null,
    candidate_index: ?u32 = null,
    count: ?u32 = null,
};
pub const Sink = struct {
    context: ?*anyopaque = null,
    emit_fn: ?*const fn (?*anyopaque, Record) void = null,
    next_fn: ?*const fn (?*anyopaque) u64 = null,
    origin: ?Origin = null,
    memory_job_id: ?u64 = null,
    pub fn emit(self: Sink, record: Record) void {
        var copy = record;
        if (self.origin) |origin| copy.origin = origin;
        if (self.memory_job_id) |id| copy.memory_job_id = id;
        if (self.emit_fn) |f| f(self.context, copy);
    }
    pub fn next(self: Sink) u64 {
        return if (self.next_fn) |f| f(self.context) else 0;
    }
};
pub const Span = struct {
    sink: Sink,
    io: std.Io,
    record: Record,
    started_ms: i64 = 0,
    done: bool = false,
    pub fn start(sink: Sink, io: std.Io, record: Record) Span {
        var span: Span = .{ .sink = sink, .io = io, .record = record };
        span.record.span_id = sink.next();
        if (span.record.span_id != 0) {
            span.started_ms = std.Io.Clock.awake.now(io).toMilliseconds();
            span.record.phase = .begin;
            sink.emit(span.record);
        }
        return span;
    }
    pub fn finish(self: *Span, result: Result) void {
        if (self.done) return;
        self.done = true;
        if (self.record.span_id == 0) return;
        self.record.phase = .end;
        self.record.result = result;
        self.record.elapsed_ms = @intCast(@max(0, std.Io.Clock.awake.now(self.io).toMilliseconds() -| self.started_ms));
        self.sink.emit(self.record);
    }
    pub fn fail(self: *Span, err: anyerror) void {
        if (self.done) return;
        self.record.error_name = ErrorName.fromError(err);
        self.finish(if (err == error.Canceled) .canceled else .failed);
    }
};
