//! Credential-free terminal diagnostics shared by TUI and --print.
//! Accept only local labels/error names, enum categories and numeric status;
//! never accept provider prose, response JSON, credentials or request headers.
const std = @import("std");
const p = @import("../core/protocol.zig");

pub fn write(writer: *std.Io.Writer, label: []const u8, detail: ?anyerror, kind: ?p.FailureKind, status: ?u16) !void {
    if (detail) |err| if (err == error.DecisionUnavailable) return writeDecision(writer, null);
    // A classified failure reads as one actionable sentence. Internal error
    // names and wire codes stay in the diagnostics log, never on the row.
    const classified = kind orelse kindOf(detail);
    if (classified) |value| if (sentence(value, status)) |text| {
        try writer.writeAll(label);
        // Put the status before verbose details so narrow terminal rows retain it.
        if (status) |code| try writer.print(" [HTTP {d}]", .{code});
        try writer.print(": {s}", .{text});
        return;
    };
    try writer.writeAll(label);
    if (status) |code| try writer.print(" [HTTP {d}]", .{code});
    if (detail) |err| {
        // No usable classification: name the failure and, for the few cases the
        // caller can act on, add the next step. A generic remote failure never
        // advertises its placeholder name.
        if (err == error.RemoteFailure) {
            try writer.writeAll(": model request failed; resend, or check the diagnostics log");
            return;
        }
        try writer.print(": {s}", .{@errorName(err)});
        if (err == error.InputBudgetExceeded) try writer.writeAll("; estimated input budget reached; compact context or adjust input policy");
        if (err == error.InputBudgetSummaryFailed) try writer.writeAll("; summary failed; history kept, no further inference sent");
        if (err == error.UnknownInputPriceThreshold) try writer.writeAll("; low-price threshold unavailable; refresh metadata and reselect, or explicitly disable limits.low_price_input");
        if (err == error.UnknownModelOutputCapacity) try writer.writeAll("; Anthropic requires a verified model output capacity; refresh metadata and reselect the model");
        return;
    }
    if (kind) |failure| try writer.print(" / {s}", .{@tagName(failure)});
}

/// Provider failure classes with a user-facing next step. Null keeps the
/// generic name-based path for classes this layer cannot explain.
fn sentence(kind: p.FailureKind, status: ?u16) ?[]const u8 {
    return switch (kind) {
        .authentication => switch (status orelse 0) {
            401 => "credentials rejected; check /login",
            403 => "access denied; check workspace/model permissions",
            else => "check credentials and access permissions",
        },
        .transport => "cannot reach the model service; check network or proxy, then resend",
        .timeout => "model request timed out; resend or lower reasoning effort",
        .rate_limit => "provider rate limit reached; resend later",
        .context_limit => "provider context limit reached; run /compact",
        .server => "provider service error; resend",
        .model => "provider rejected the model request; check /model and reasoning effort",
        .invalid_argument => "provider rejected the request arguments; check /model and settings",
        .unsupported_protocol => "provider protocol unsupported; check the model's protocol",
        .protocol => "invalid provider response; resend",
        .output_limit => "provider output limit reached; split the response or lower reasoning effort",
        .canceled => null,
    };
}

/// Local classification for callers that only carry the error value, so a
/// transport or timeout still reads as one sentence instead of a name.
fn kindOf(detail: ?anyerror) ?p.FailureKind {
    const err = detail orelse return null;
    return switch (err) {
        error.ConnectionLost, error.ConnectionClosed, error.Transport, error.StreamPoisoned, error.ModelRequestFailed => .transport,
        error.Timeout, error.RequestTimeout => .timeout,
        error.ProtocolError, error.TruncatedFrame, error.FrameTooLarge => .protocol,
        else => null,
    };
}

/// Compact current-operation summary; detailed cause/stage stay in JSONL.
/// A separate auxiliary status is never labelled as the primary model's HTTP.
pub fn writeDecision(writer: *std.Io.Writer, diagnostic: ?@import("../core/decision.zig").Diagnostic) !void {
    const stage = if (diagnostic) |value| value.stage else .review;
    try writer.writeAll(switch (stage) {
        .credentials => "Paused: decision credentials unavailable",
        .transport => "Paused: decision connection failed",
        .decode, .validate => "Paused: invalid decision response",
        else => "Paused: decision review failed",
    });
    if (diagnostic) |value| if (value.http_status) |code| try writer.print(" [HTTP {d}]", .{code});
    try writer.writeAll(if (stage == .credentials) "; check /settings" else "; operation not executed");
}
