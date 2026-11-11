fn caption(a: std.mem.Allocator, name: []const u8, arguments: []const u8) !Caption {
    const call = try shared.tools.Call.init(a, name, arguments);
    defer call.deinit(a);
    return fromCall(a, call);
}

fn promptColors(styled: []const u8) ![]u8 {
    const a = std.testing.allocator;
    const colors = try std.mem.replaceOwned(u8, a, styled, "\x1b[1m", "");
    errdefer a.free(colors);
    try std.testing.expect(std.mem.endsWith(u8, colors, theme.reset ++ " "));
    return colors;
}

fn promptDefaultEnd(expected: []const u8) ![]u8 {
    const a = std.testing.allocator;
    if (std.mem.endsWith(u8, expected, theme.reset ++ " ")) return a.dupe(u8, expected);
    return std.mem.concat(a, u8, &.{ expected[0 .. expected.len - 1], theme.reset ++ " " });
}

fn expectPromptStyle(expected: []const u8, actual: []const u8) !void {
    const colors = try promptColors(actual);
    defer std.testing.allocator.free(colors);
    const ended = try promptDefaultEnd(expected);
    defer std.testing.allocator.free(ended);
    try std.testing.expectEqualStrings(ended, colors);
}

fn expectPromptSuffix(actual: []const u8, suffix: []const u8) !void {
    const colors = try promptColors(actual);
    defer std.testing.allocator.free(colors);
    const ended = try promptDefaultEnd(suffix);
    defer std.testing.allocator.free(ended);
    try std.testing.expect(std.mem.endsWith(u8, colors, ended));
}

fn visibleRow(a: std.mem.Allocator, styled: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var at: usize = 0;
    while (at < styled.len) {
        if (styled[at] != '\x1b') {
            try out.writer.writeByte(styled[at]);
            at += 1;
            continue;
        }
        at = (std.mem.findScalarPos(u8, styled, at, 'm') orelse return error.UnterminatedSgr) + 1;
    }
    return a.dupe(u8, out.written());
}
