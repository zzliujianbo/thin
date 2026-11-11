//! Credential-free terminal diagnostics shared by TUI and --print.
//! Accept only local labels/error names, enum categories and numeric status;
//! never accept provider prose, response JSON, credentials or request headers.
const std = @import("std");
const p = @import("../core/protocol.zig");

pub fn write(writer: *std.Io.Writer, label: []const u8, detail: ?anyerror, kind: ?p.FailureKind, status: ?u16) !void {
    if (detail) |err| if (err == error.DecisionUnavailable) return writeDecision(writer, null);
    try writer.writeAll(label);
    // Put the status before verbose details so narrow terminal rows retain it.
    if (status) |code| try writer.print(" [HTTP {d}]", .{code});
    if (detail) |err| {
        try writer.print(": {s}", .{@errorName(err)});
        if (err == error.InputBudgetExceeded) try writer.writeAll("; estimated input budget reached; compact context or adjust input policy");
        if (err == error.InputBudgetSummaryFailed) try writer.writeAll("; summary failed; history kept, no further inference sent");
        if (err == error.UnknownInputPriceThreshold) try writer.writeAll("; low-price threshold unavailable; refresh metadata and reselect, or explicitly disable limits.low_price_input");
        if (err == error.UnknownModelOutputCapacity) try writer.writeAll("; Anthropic requires a verified model output capacity; refresh metadata and reselect the model");
    }
    if (kind) |failure| {
        try writer.print(" / {s}", .{@tagName(failure)});
        if (failure == .authentication) try writer.writeAll(switch (status orelse 0) {
            401 => "; credentials rejected; check /login",
            403 => "; access denied; check workspace/model permissions",
            else => "; check credentials and access permissions",
        });
        if (failure == .output_limit) try writer.writeAll("; provider output limit reached; split the response or lower reasoning effort");
    }
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
