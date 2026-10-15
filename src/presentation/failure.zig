//! Credential-free terminal diagnostics shared by TUI and --print.
//! Accept only local labels/error names, enum categories and numeric status;
//! never accept provider prose, response JSON, credentials or request headers.
const std = @import("std");
const p = @import("../core/protocol.zig");

pub fn write(writer: *std.Io.Writer, label: []const u8, detail: ?anyerror, kind: ?p.FailureKind, status: ?u16) !void {
    try writer.writeAll(label);
    // Put the status before verbose details so narrow terminal rows retain it.
    if (status) |code| try writer.print(" [HTTP {d}]", .{code});
    if (detail) |err| try writer.print(": {s}", .{@errorName(err)});
    if (kind) |failure| {
        try writer.print(" / {s}", .{@tagName(failure)});
        if (failure == .authentication) try writer.writeAll(switch (status orelse 0) {
            401 => "; credentials rejected; check /login",
            403 => "; access denied; check workspace/model permissions",
            else => "; check credentials and access permissions",
        });
        if (failure == .output_limit) try writer.writeAll("; output token limit reached; raise limits.max_output_tokens or lower reasoning effort");
    }
}

test "output limit pause explains shared output budget without implying network failure" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, "Paused", error.OutputLimitReached, .output_limit, null);
    try std.testing.expectEqualStrings("Paused: OutputLimitReached / output_limit; output token limit reached; raise limits.max_output_tokens or lower reasoning effort", writer.buffered());
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "HTTP") == null);
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "ModelRequestFailed") == null);
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
