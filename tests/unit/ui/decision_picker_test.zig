test "direct choices intersect exact providers preserve raw IDs and never invent current" {
    try std.testing.expectEqual(@as(usize, 2), count(&profiles, &logged, ""));
    try std.testing.expectEqual(@as(usize, 1), count(&profiles, null, ""));
    try std.testing.expect(choice(&profiles, null, "", 0).? == .off);
    try std.testing.expect(choice(&profiles, null, "", 1) == null);
    try std.testing.expectEqualStrings("login/Family/Judge", choice(&profiles, &logged, "", 1).?.model);
    try std.testing.expectEqual(@as(usize, 1), indexOf(&profiles, &logged, "", "login/Family/Judge"));
    try std.testing.expectEqual(@as(usize, 0), indexOf(&profiles, &logged, "", "login/ghost"));
    try std.testing.expectEqual(@as(usize, 0), indexOf(&profiles, &logged, "", "login/family/judge"));
    const before = fingerprint(&profiles, &logged).?;
    var changed = profiles;
    changed[0].protocol = .responses;
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&changed, &logged).?));
    changed = profiles;
    changed[0].name = "login/another";
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&changed, &logged).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, null).?));
}
test "direct decision windows keep selection visible and reject paste or clipping" {
    const a = std.testing.allocator;
    for (0..count(&profiles, &logged, "")) |selected| for (0..7) |height| for (0..65) |columns| {
        const rendered = try rows(a, .{ .selected = selected }, &profiles, &logged, "", columns, height);
        defer freeRows(a, rendered);
        const label = if (selected == 0) "Off" else profiles[0].name;
        try std.testing.expect(rendered.lines.len <= height);
        try std.testing.expectEqual(height != 0 and columns >= 2 + label.len, rendered.can_confirm);
        if (rendered.selected_line) |index| {
            try std.testing.expect(index < rendered.lines.len);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[index], label) != null);
        } else try std.testing.expect(height == 0);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
    };
    const pasted = try rows(a, .{ .pasted = true }, &profiles, &logged, "", 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
test "decision rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "decision search AND tokens fold ASCII preserve slash IDs and filter Off" {
    const providers = [_]Provider{ .{ .name = "login" }, .{ .name = "second" } };
    try std.testing.expectEqual(@as(usize, 2), count(&profiles, &providers, " JUDGE\tFAMILY/ "));
    try std.testing.expectEqual(@as(usize, 1), count(&profiles, &providers, "SECOND /JUDGE"));
    try std.testing.expectEqualStrings("second/family/judge", choice(&profiles, &providers, "SECOND /JUDGE", 0).?.model);
    try std.testing.expectEqual(@as(usize, 0), indexOf(&profiles, &providers, "SECOND", "second/family/judge"));
    try std.testing.expectEqual(@as(usize, 0), count(&profiles, &logged, "SECOND"));
    try std.testing.expectEqual(@as(usize, 1), count(&profiles, null, "oFf"));
    try std.testing.expect(choice(&profiles, null, "oFf", 0).? == .off);
    try std.testing.expect(choice(&profiles, &logged, "missing", 0) == null);
    const chinese = [_]cfg.Model{.{ .name = "login/中文/Judge", .context_tokens = 16384 }};
    try std.testing.expectEqual(@as(usize, 1), count(&chinese, &logged, "中文 judge"));
    try std.testing.expectEqual(@as(usize, 0), count(&chinese, &logged, "中文 JUDGES"));
    for (0..5) |height| for (0..30) |columns| {
        const rendered = try rows(std.testing.allocator, .{ .selected = std.math.maxInt(usize) }, &profiles, &logged, "missing", columns, height);
        defer freeRows(std.testing.allocator, rendered);
        try std.testing.expect(!rendered.can_confirm and rendered.selected_line == null);
        try std.testing.expect(rendered.lines.len <= height);
        if (height != 0 and columns >= 18) try std.testing.expectEqualStrings("No matching models", rendered.lines[0]);
    };
    var menu: Menu = .{};
    menu.move(true, 0);
    menu.move(false, 0);
    try std.testing.expectEqual(@as(usize, 0), menu.selected);
}
test "native protocol is an ordinary exact model and large windows stay bounded" {
    const a = std.testing.allocator;
    const models: [40]cfg.Model = @splat(.{ .name = "login/Native/Judge", .protocol = .systemone, .context_tokens = 16384 });
    try std.testing.expectEqual(@as(usize, 41), count(&models, &logged, ""));
    try std.testing.expectEqualStrings("login/Native/Judge", choice(&models, &logged, "", 40).?.model);
    for ([_]usize{ 1, 2, 3, 10, 100 }) |height| {
        const rendered = try rows(a, .{ .selected = 40 }, &models, &logged, "", 80, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.can_confirm);
        try std.testing.expect(rendered.lines.len <= @min(height, 11));
        try std.testing.expect(rendered.selected_line.? < rendered.lines.len);
        try std.testing.expect(std.mem.find(u8, rendered.lines[rendered.selected_line.?], "login/Native/Judge") != null);
    }
    const many: [4097]cfg.Model = @splat(models[0]);
    try std.testing.expect(fingerprint(&many, &logged) != null);
    try std.testing.expectEqual(@as(usize, 4098), count(&many, &logged, ""));
    try std.testing.expectEqualStrings(models[0].name, choice(&many, &logged, "", 4097).?.model);
    var providers: [257]Provider = @splat(.{ .name = "other" });
    providers[256] = .{ .name = "login" };
    try std.testing.expectEqual(@as(usize, 41), count(&models, &providers, ""));
    try std.testing.expect(fingerprint(&models, &providers) != null);
    const long_name: [max_name_bytes + 1]u8 = @splat('a');
    const too_long = [_]cfg.Model{.{ .name = &long_name, .context_tokens = 16384 }};
    try std.testing.expect(fingerprint(&too_long, &logged) == null);
}
