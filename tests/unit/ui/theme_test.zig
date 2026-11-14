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
test "executing row flow uses only warm foreground levels in a fading band" {
    const std = @import("std");
    const testing = std.testing;
    const warm = [_][]const u8{ "\x1b[38;5;137m", "\x1b[38;5;173m", "\x1b[38;5;208m", "\x1b[38;5;214m", "\x1b[38;5;220m", "\x1b[38;5;223m" };
    try testing.expect(flow_band.len >= 4);
    for (flow_band, 0..) |tone, i| {
        // Foreground-only standard palette; never truecolor, background or bold.
        for ([_][]const u8{ "38;2;", "48;", "\x1b[1m", "\x1b[4m", "\x1b[7m" }) |rejected| try testing.expect(std.mem.indexOf(u8, tone, rejected) == null);
        var supported = false;
        for (warm) |allowed| supported = supported or std.mem.eql(u8, allowed, tone);
        try testing.expect(supported);
        // Adjacent columns always differ: the band never repeats one level.
        if (i != 0) try testing.expect(!std.mem.eql(u8, tone, flow_band[i - 1]));
    }
}
