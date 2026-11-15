test "raw provider cause is shown verbatim after the status" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Failed", error.ModelRequestFailed, 401, "Incorrect API key provided: sk-test");
    try std.testing.expectEqualStrings("Failed [HTTP 401]: Incorrect API key provided: sk-test", writer.buffered());
}
test "without provider text the local error name is the cause" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "\u{2717}", error.ConnectionRefused, 502, "");
    try std.testing.expectEqualStrings("\u{2717} [HTTP 502]: ConnectionRefused", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Canceled", error.Canceled, null, "");
    try std.testing.expectEqualStrings("Canceled: Canceled", writer.buffered());
}
test "no category wording is added for any failure class" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "\u{2717}", error.ModelRequestFailed, 429, "Rate limit reached for gpt-5");
    try std.testing.expectEqualStrings("\u{2717} [HTTP 429]: Rate limit reached for gpt-5", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "\u{2717}", error.ModelRequestFailed, null, "finish_reason: length");
    try std.testing.expectEqualStrings("\u{2717}: finish_reason: length", writer.buffered());
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "resend") == null);
}
test "output limit pause keeps the provider reason instead of a rewritten sentence" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Paused", error.OutputLimitReached, null, "stop_reason: max_tokens");
    try std.testing.expectEqualStrings("Paused: stop_reason: max_tokens", writer.buffered());
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "HTTP") == null);
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "OutputLimitReached") == null);
}
