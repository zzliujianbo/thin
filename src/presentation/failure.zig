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

test "output limit pause explains shared output budget without implying network failure" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Paused", error.OutputLimitReached, .output_limit, null);
    try std.testing.expectEqualStrings("Paused: OutputLimitReached / output_limit; provider output limit reached; split the response or lower reasoning effort", writer.buffered());
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "HTTP") == null);
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "ModelRequestFailed") == null);
}

test "decision summary stays concise and never borrows primary HTTP or error prose" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Ready", error.DecisionUnavailable, .authentication, 401);
    try std.testing.expectEqualStrings("Paused: decision review failed; operation not executed", writer.buffered());
    var diagnostic: @import("../core/decision.zig").Diagnostic = .{ .stage = .http, .backend = .systemone, .http_status = 403 };
    diagnostic.setError(error.DecisionUnavailable);
    writer = std.Io.Writer.fixed(&buffer);
    try writeDecision(&writer, diagnostic);
    try std.testing.expectEqualStrings("Paused: decision review failed [HTTP 403]; operation not executed", writer.buffered());
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "DecisionUnavailable") == null);
}

test "failure diagnostics expose HTTP status early without provider text" {
    const cases = [_]struct { status: ?u16, prefix: []const u8, hint: []const u8 }{
        .{ .status = 401, .prefix = "Failed [HTTP 401]", .hint = "credentials rejected" },
        .{ .status = 403, .prefix = "Failed [HTTP 403]", .hint = "workspace/model permissions" },
        .{ .status = null, .prefix = "Failed: ModelRequestFailed", .hint = "credentials and access permissions" },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try write(&writer, "Failed", error.ModelRequestFailed, .authentication, case.status);
        try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), case.prefix));
        try std.testing.expect(std.mem.find(u8, writer.buffered(), case.hint) != null);
        if (case.status == null) try std.testing.expect(std.mem.find(u8, writer.buffered(), "HTTP") == null);
    }
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Failed", error.ModelRequestFailed, .server, 503);
    try std.testing.expectEqualStrings("Failed [HTTP 503]: ModelRequestFailed / server", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Canceled", error.Canceled, null, null);
    try std.testing.expectEqualStrings("Canceled: Canceled", writer.buffered());
}
