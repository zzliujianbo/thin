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
