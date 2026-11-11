test "proxy candidates use logged aliases preserve raw IDs and never synthesize Off" {
    try std.testing.expectEqual(@as(usize, 2), count(&profiles, &logged, ""));
    try std.testing.expectEqual(@as(usize, 0), count(&profiles, null, ""));
    try std.testing.expectEqual(@as(usize, 3), count(&profiles, &[_]Provider{ .{ .name = "login" }, .{ .name = "second" } }, ""));
    try std.testing.expectEqualStrings("login/Family/Proxy", candidate(&profiles, &logged, "", 0).?);
    try std.testing.expectEqualStrings("login/native/Judge", candidate(&profiles, &logged, "", 1).?);
    try std.testing.expect(candidate(&profiles, &logged, "", 2) == null);
    // AND tokens fold ASCII case; the order is irrelevant, the parts are not.
    try std.testing.expectEqual(@as(usize, 1), count(&profiles, &logged, " JUDGE native "));
    try std.testing.expectEqual(@as(usize, 0), count(&profiles, &logged, "OFF"));
    try std.testing.expectEqual(@as(usize, 1), count(&profiles, &logged, "login/family/proxy"));
    try std.testing.expectEqualStrings("login/Family/Proxy", candidate(&profiles, &logged, "FAMILY", 0).?);
    const chinese = [_]cfg.Model{.{ .name = "login/中文/Proxy", .context_tokens = 0 }};
    try std.testing.expectEqual(@as(usize, 1), count(&chinese, &logged, "中文 proxy"));
    try std.testing.expect(!isSelected(&.{"login/Family/Proxy"}, "login/family/proxy"));
    try std.testing.expect(isSelected(&.{ "other/one", "login/Family/Proxy" }, "login/Family/Proxy"));
}
test "proxy fingerprint binds candidates selection and configured endpoint" {
    const before = fingerprint(&profiles, &logged, &.{"login/Family/Proxy"}, true, "10.0.0.1", 8080).?;
    try std.testing.expectEqual(@as(usize, 32), before.len);
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &logged, &.{"login/Family/Proxy"}, false, "10.0.0.1", 8080).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &logged, &.{ "login/Family/Proxy", "login/native/Judge" }, true, "10.0.0.1", 8080).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &logged, &.{"login/native/Judge"}, true, "10.0.0.1", 8080).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &logged, &.{"login/Family/Proxy"}, true, "10.0.0.2", 8080).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &logged, &.{"login/Family/Proxy"}, true, "10.0.0.1", 8081).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &logged, &.{"login/Family/Proxy"}, true, null, 0).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &[_]Provider{ .{ .name = "login" }, .{ .name = "second" } }, &.{"login/Family/Proxy"}, true, "10.0.0.1", 8080).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, null, &.{"login/Family/Proxy"}, true, "10.0.0.1", 8080).?));
    var changed = profiles;
    changed[0].protocol = .responses;
    try std.testing.expectEqualSlices(u8, &before, &fingerprint(&changed, &logged, &.{"login/Family/Proxy"}, true, "10.0.0.1", 8080).?);
    changed[0].name = "login/Family/Other";
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&changed, &logged, &.{"login/Family/Proxy"}, true, "10.0.0.1", 8080).?));
    const too_many: [max_models + 1]cfg.Model = @splat(profiles[0]);
    try std.testing.expect(fingerprint(&too_many, &logged, &.{}, true, "10.0.0.1", 8080) == null);
    const too_many_selected: [max_selected + 1][]const u8 = @splat("login/Family/Proxy");
    try std.testing.expect(fingerprint(&profiles, &logged, &too_many_selected, true, "10.0.0.1", 8080) == null);
    const long_name: [max_name_bytes + 1]u8 = @splat('a');
    try std.testing.expect(fingerprint(&profiles, &logged, &.{&long_name}, true, "10.0.0.1", 8080) == null);
    const long_address: [cfg.max_proxy_endpoint_bytes + 1]u8 = @splat('a');
    try std.testing.expect(fingerprint(&profiles, &logged, &.{}, true, &long_address, 8080) == null);
}
test "proxy rows confirm complete rows and surface a missing endpoint" {
    const a = std.testing.allocator;
    const chosen = [_][]const u8{"login/native/Judge"};
    for (0..count(&profiles, &logged, "")) |selected| for (0..7) |height| for (0..70) |columns| {
        const rendered = try rows(a, .{ .selected = selected }, &profiles, &logged, &chosen, true, "10.0.0.1", 8080, "", columns, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.lines.len <= height);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
        if (height == 0) {
            try std.testing.expect(rendered.selected_line == null and !rendered.can_confirm);
            continue;
        }
        const name = if (selected == 0) "login/Family/Proxy" else "login/native/Judge";
        const width = 2 + "[ ] ".len + name.len;
        try std.testing.expectEqual(columns >= width, rendered.can_confirm);
        if (rendered.can_confirm) {
            const index = rendered.selected_line.?;
            try std.testing.expect(std.mem.find(u8, rendered.lines[index], name) != null);
            try std.testing.expect(std.mem.startsWith(u8, rendered.lines[index][2..], if (selected == 1) "[x]" else "[ ]"));
        }
    };
    const unconfigured = try rows(a, .{}, &profiles, &logged, &.{}, false, null, 0, "", 80, 10);
    defer freeRows(a, unconfigured);
    // The frame is acknowledged so Enter reports the missing endpoint; the
    // owner callback still refuses to save anything.
    try std.testing.expect(unconfigured.can_confirm);
    try std.testing.expectEqualStrings("Proxy host/port not configured; Enter shows what is missing", unconfigured.lines[2]);
    const pasted = try rows(a, .{ .pasted = true }, &profiles, &logged, &.{}, true, "10.0.0.1", 8080, "", 80, 3);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
    const missing = try rows(a, .{}, &profiles, &logged, &.{}, true, "10.0.0.1", 8080, "missing", 80, 3);
    defer freeRows(a, missing);
    try std.testing.expect(!missing.can_confirm and missing.selected_line == null);
    try std.testing.expectEqualStrings("No matching models", missing.lines[0]);
    const clipped = try rows(a, .{}, &profiles, &logged, &.{}, true, "10.0.0.1", 8080, "", 6, 1);
    defer freeRows(a, clipped);
    try std.testing.expect(!clipped.can_confirm and text.width(clipped.lines[0]) <= 6);
    const empty = try rows(a, .{}, &profiles, &logged, &.{}, true, "10.0.0.1", 8080, "", 80, 0);
    defer a.free(empty.lines);
    try std.testing.expect(empty.lines.len == 0 and empty.selected_line == null and !empty.can_confirm);
}
test "proxy rows keep one bounded window for large catalogs" {
    const a = std.testing.allocator;
    const models: [40]cfg.Model = @splat(.{ .name = "login/Native/Judge", .protocol = .systemone, .context_tokens = 0 });
    try std.testing.expectEqual(@as(usize, 40), count(&models, &logged, ""));
    for ([_]usize{ 1, 2, 3, 10, 100 }) |height| {
        const rendered = try rows(a, .{ .selected = 39 }, &models, &logged, &.{}, true, "10.0.0.1", 8080, "", 80, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.can_confirm);
        try std.testing.expect(rendered.lines.len <= @min(height, 11));
        try std.testing.expect(rendered.selected_line.? < rendered.lines.len);
        try std.testing.expect(std.mem.find(u8, rendered.lines[rendered.selected_line.?], "login/Native/Judge") != null);
    }
    var menu: Menu = .{};
    const generation = menu.generation;
    menu.move(false, 0);
    try std.testing.expectEqual(generation, menu.generation);
}
test "proxy rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
