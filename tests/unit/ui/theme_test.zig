test "Markdown uses vivid yellow green and cool violet without changing font styles" {
    const std = @import("std");
    const testing = std.testing;
    try testing.expectEqualStrings("\x1b[1m\x1b[38;5;220m", heading);
    try testing.expectEqualStrings("\x1b[4m\x1b[38;5;12m", link);
    try testing.expectEqualStrings("\x1b[38;5;141m", inline_code);
    try testing.expectEqualStrings("\x1b[38;5;77m", code);
    try testing.expectEqualStrings(inline_code, bullet);
    try testing.expectEqualStrings("\x1b[1m", strong);
    for ([_][]const u8{ heading, link, inline_code, code, bullet }) |style| {
        for ([_][]const u8{ "38;2;", "48;" }) |rejected| try testing.expect(std.mem.indexOf(u8, style, rejected) == null);
    }
    for ([_][]const u8{ link, inline_code, code, bullet }) |style| try testing.expect(std.mem.indexOf(u8, style, "\x1b[1m") == null);
    try testing.expectEqualStrings("\x1b[38;5;2m", diff_added);
    try testing.expectEqualStrings("\x1b[38;5;1m", diff_removed);
    try testing.expectEqualStrings(reset, effortColor(.medium));
    try testing.expectEqualStrings("\x1b[38;5;75m", effortColor(.high));
    try testing.expectEqualStrings("\x1b[38;5;171m", effortColor(.xhigh));
}
test "tool icon breathing uses only warm 256-color foreground levels in a smooth round trip" {
    const std = @import("std");
    const testing = std.testing;
    const warm = [_][]const u8{ "\x1b[38;5;137m", "\x1b[38;5;173m", "\x1b[38;5;208m", "\x1b[38;5;214m" };
    var levels: usize = 0;
    for (tool_icon_pulse, 0..) |tone, i| {
        // Foreground-only standard palette; never truecolor, background or bold.
        for ([_][]const u8{ "38;2;", "48;", "\x1b[1m", "\x1b[4m", "\x1b[7m" }) |rejected| try testing.expect(std.mem.indexOf(u8, tone, rejected) == null);
        var supported = false;
        for (warm) |allowed| supported = supported or std.mem.eql(u8, allowed, tone);
        try testing.expect(supported);
        // Adjacent frames always move one visual level: no repeat, no glyph swap.
        if (i != 0) try testing.expect(!std.mem.eql(u8, tone, tool_icon_pulse[i - 1]));
        var known = false;
        for (tool_icon_pulse[0..i]) |seen| known = known or std.mem.eql(u8, seen, tone);
        if (!known) levels += 1;
    }
    try testing.expect(levels >= 4);
    try testing.expectEqualStrings(tool_icon_pulse[0], toolIconColor(0));
    try testing.expect(!std.mem.eql(u8, toolIconColor(0), toolIconColor(180)));
    try testing.expectEqualStrings(toolIconColor(0), toolIconColor(180 * tool_icon_pulse.len));
    try testing.expect(toolIconColor(std.math.maxInt(u64)).len != 0);
}
