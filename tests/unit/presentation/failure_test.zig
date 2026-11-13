test "output limit pause explains shared output budget without implying network failure" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Paused", error.OutputLimitReached, .output_limit, null);
    try std.testing.expectEqualStrings("Paused: provider output limit reached; split the response or lower reasoning effort", writer.buffered());
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "HTTP") == null);
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "OutputLimitReached") == null);
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
        .{ .status = 401, .prefix = "Failed [HTTP 401]", .hint = "check /login" },
        .{ .status = 403, .prefix = "Failed [HTTP 403]", .hint = "workspace/model permissions" },
        .{ .status = null, .prefix = "Failed:", .hint = "credentials and access permissions" },
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
    try std.testing.expectEqualStrings("Failed [HTTP 503]: provider service error; resend", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Canceled", error.Canceled, null, null);
    try std.testing.expectEqualStrings("Canceled: Canceled", writer.buffered());
}
test "classified failures read as one actionable sentence without internal names" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "\u{2717}", error.ModelRequestFailed, .transport, null);
    try std.testing.expectEqualStrings("\u{2717}: cannot reach the model service; check network or proxy, then resend", writer.buffered());
    // The same wording is reached when only the local error value is known.
    writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "\u{2717}", error.ModelRequestFailed, null, null);
    try std.testing.expectEqualStrings("\u{2717}: cannot reach the model service; check network or proxy, then resend", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "\u{2717}", error.Timeout, .timeout, null);
    try std.testing.expectEqualStrings("\u{2717}: model request timed out; resend or lower reasoning effort", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "\u{2717}", error.ModelRequestFailed, .rate_limit, 429);
    try std.testing.expectEqualStrings("\u{2717} [HTTP 429]: provider rate limit reached; resend later", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "\u{2717}", error.ModelRequestFailed, .context_limit, null);
    try std.testing.expectEqualStrings("\u{2717}: provider context limit reached; run /compact", writer.buffered());
    // A wire placeholder never reaches the row as a bare internal name.
    writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "\u{2717}", error.RemoteFailure, null, null);
    try std.testing.expectEqualStrings("\u{2717}: model request failed; resend, or check the diagnostics log", writer.buffered());
}
