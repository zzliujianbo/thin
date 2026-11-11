test "default off shared fallback preserves explicit logical choices" {
    const t = std.testing;
    const standard = resolve("https://api.openai.com/v1", "gpt-5.2", .{ .map = .{ .off = "none", .low = "low", .medium = "medium", .high = "high" } });
    try t.expectEqual(activity.ReasoningEffort.off, standard.defaultEffort(null));
    try t.expectEqual(activity.ReasoningEffort.low, standard.defaultEffort("low"));
    try t.expectEqual(activity.ReasoningEffort.off, standard.defaultEffort("off"));
    try t.expectEqual(activity.ReasoningEffort.off, resolve("https://api.deepseek.com", "deepseek-flash", .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } }).defaultEffort(null));
    try t.expectEqual(activity.ReasoningEffort.off, resolve("https://fixture.invalid", "no-off", .{ .map = .{ .high = "high" } }).defaultEffort(null));
    try t.expectEqual(activity.ReasoningEffort.off, resolve("https://api.openai.com/v1", "gpt-4o", .{ .map = .{ .off = "none" } }).defaultEffort(null));
    const unknown = resolve("https://proxy.invalid", "custom", null);
    try t.expectEqual(activity.ReasoningEffort.off, unknown.defaultEffort(null));
    try t.expect(unknown.wire(null).effort == null); // A saved default is not a capability declaration.
}
test "no builtin capabilities exist for official endpoints or recognized model names" {
    const t = std.testing;
    for ([_][]const u8{ "http://api.openai.com/v1", "https://api.openai.com/v1//", "https://api.openai.com.evil/v1", "https://proxy/v1" }) |url| {
        const cap = resolve(url, "gpt-5.2", null);
        try t.expect(!cap.known and cap.levels.mask == 0);
        try t.expectEqualStrings("custom", cap.effective("custom").?);
    }
    try t.expect(!resolve("https://api.openai.com/v1", "gpt-5.2-new", null).known);
    for ([_][]const u8{ "https://api.openai.com/v1", "https://api.deepseek.com", "https://opencode.ai/zen/v1", "https://opencode.ai/zen/go/v1" }) |url| {
        for ([_][]const u8{ "gpt-4o", "gpt-5.2", "gpt-5.6-luna", "gpt-6-luna", "deepseek-flash", "deepseek-v4-pro", "claude-haiku-5-5" }) |name| {
            const missing = resolve(url, name, null);
            try t.expect(!missing.known and missing.levels.mask == 0);
        }
    }
    const cap = resolve("https://api.openai.com/v1/", "gpt-5.2", .{ .map = .{ .off = "none", .low = "low", .high = "high", .xhigh = "xhigh" } });
    try t.expectEqualStrings("high", cap.effective("high").?);
    try t.expectEqualStrings("low", cap.effective("minimal").?);
    try t.expectEqualStrings("xhigh", cap.effective("max").?);
    try t.expectEqualStrings("none", cap.wire("none").effort.?);
    try t.expectEqualStrings("none", cap.wire("off").effort.?);
    try t.expectEqual(activity.ReasoningEffort.off, cap.defaultEffort("none"));
    try t.expect(cap.wire(null).effort == null and cap.wire(null).thinking == null);
    const unknown = resolve("https://api.openai.com/v1", "gpt-4o", null);
    try t.expect(!unknown.known);
    try t.expect(unknown.wire(null).effort == null);
    try t.expect(!resolve("https://api.openai.com/v1", "gpt-6-sol", null).levels.contains(.max));
}
test "deepseek wire and custom maps preserve unspecified validate bounded strings" {
    const t = std.testing;
    for ([_][]const u8{ "https://api.deepseek.com", "https://api.deepseek.com/v1/" }) |url| {
        const cap = resolve(url, "deepseek-flash", .{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high", .max = "max" } });
        try t.expectEqual(@as(usize, 4), cap.levels.count());
        try t.expectEqualStrings("high", cap.effective("medium").?);
        try t.expect(cap.wire("off").thinking.? == false and cap.wire("off").effort == null);
        try t.expect(cap.wire("max").thinking.?);
        try t.expectEqualStrings("max", cap.wire("max").effort.?);
        try t.expect(cap.wire(null).thinking == null);
    }
    for ([_][]const u8{ "https://api.deepseek.com.evil", "http://api.deepseek.com", "https://api.deepseek.com/v2", "https://api.deepseek.com/v1//" }) |url| {
        try t.expect(!resolve(url, "deepseek-flash", null).known);
    }
    try t.expect(!resolve("https://api.deepseek.com", "prefix-deepseek-flash", null).known);
    const pro = resolve("https://api.deepseek.com", "deepseek-v4-pro", .{ .format = .deepseek, .map = .{ .off = "off", .high = "high", .max = "max" } });
    try t.expectEqualStrings("high", pro.effective("low").?);
    try t.expectEqual(@as(usize, 3), pro.levels.count());
    try t.expect(!pro.levels.contains(.low));
    const custom = resolve("https://proxy", "custom", .{ .map = .{ .off = "disabled", .high = "intensive" } });
    try t.expectEqualStrings("intensive", custom.wire("low").effort.?);
    try t.expectEqualStrings("disabled", custom.wire("off").effort.?);
    // Raw model wire options are opaque, not logical off aliases.
    try t.expectEqualStrings("none", custom.wire("none").effort.?);
    try t.expectError(error.InvalidReasoningMap, (Declaration{ .map = .{} }).validate());
    try t.expectError(error.InvalidReasoningMap, (Declaration{ .format = .deepseek, .map = .{ .high = "high" } }).validate());
    const too_long: [129]u8 = @splat('x');
    for ([_][]const u8{ "", "   ", "bad\n", "bad\x7f", &too_long }) |bad| {
        try t.expectError(error.InvalidReasoningMap, (Declaration{ .map = .{ .low = bad } }).validate());
    }
}
