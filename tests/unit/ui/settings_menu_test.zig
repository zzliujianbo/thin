test "settings expose eight preference rows" {
    try std.testing.expectEqual(@as(usize, 8), count);
    try std.testing.expectEqualStrings("Auto memory", label(6));
    try std.testing.expectEqualStrings("on", value(.{}, 6));
    try std.testing.expectEqualStrings("off", value(.{ .memory_auto = false }, 6));
    try std.testing.expectEqual(@as(?Key, .memory_auto), preferenceKey(6));
    try std.testing.expectEqualStrings("Proxy", label(7));
    try std.testing.expectEqual(@as(?Key, null), preferenceKey(7));
    try std.testing.expectEqualStrings("Not configured", value(.{}, 7));
    try std.testing.expectEqualStrings("", value(.{ .proxy_address = "127.0.0.1", .proxy_port = 3128, .proxy_model_count = 2 }, 7));
    try std.testing.expectEqualStrings("", label(8));
    try std.testing.expectEqualStrings("Off", value(.{}, 5));
    try std.testing.expectEqualStrings("login/deepseek-flash", value(.{ .image_enabled = true, .image_model = "login/deepseek-flash" }, 5));
    try std.testing.expectEqualStrings("on", value(.{}, 0));
    try std.testing.expectEqualStrings("off", value(.{ .low_price_input_enabled = false }, 0));
    try std.testing.expectEqualStrings("Off", value(.{}, 1));
    try std.testing.expectEqualStrings("Not set", value(.{ .decision_enabled = true }, 1));
    try std.testing.expectEqualStrings("provider/rawID", value(.{ .decision_enabled = true, .decision_model = "provider/rawID" }, 1));
    try std.testing.expect(std.mem.find(u8, description(4), "including decisions") != null);
    try std.testing.expectEqual(@as(?Key, .compaction_enabled), preferenceKey(2));
    try std.testing.expectEqual(@as(?Key, null), preferenceKey(5));
    try std.testing.expectEqual(@as(?Key, null), preferenceKey(1));
    try std.testing.expectEqual(@as(?Key, .memory_auto), preferenceKey(6));
    try std.testing.expect(std.mem.find(u8, description(0), "unknown") != null);
    try std.testing.expect(std.mem.find(u8, description(1), "Memory") != null);
    try std.testing.expect(std.mem.find(u8, description(7), "proxy") != null);
}
test "Proxy root row shows host:port and opens on its static label" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("Proxy", label(7));
    const configured: Snapshot = .{ .proxy_configured = true, .proxy_address = "10.0.0.1", .proxy_port = 8080, .proxy_model_count = 3 };
    for (0..90) |columns| {
        const rendered = try rows(a, .{ .selected = 7 }, configured, columns, 1);
        defer freeRows(a, rendered);
        // Opening the child menu never requires the (unsaved) value to fit.
        try std.testing.expectEqual(columns >= 2 + label(7).len, rendered.can_confirm);
        try std.testing.expect(text.width(rendered.lines[0]) <= columns);
    }
    const counted = try rows(a, .{ .selected = 7 }, configured, 80, 1);
    defer freeRows(a, counted);
    try std.testing.expect(std.mem.find(u8, counted.lines[0], "10.0.0.1:8080") != null);
    const v6 = try rows(a, .{ .selected = 7 }, .{ .proxy_configured = true, .proxy_address = "::1", .proxy_port = 3128 }, 80, 1);
    defer freeRows(a, v6);
    try std.testing.expect(std.mem.find(u8, v6.lines[0], "[::1]:3128") != null);
    const empty = try rows(a, .{ .selected = 7 }, .{}, 80, 1);
    defer freeRows(a, empty);
    try std.testing.expect(std.mem.find(u8, empty.lines[0], "Not configured") != null);
    // A long endpoint is clipped, but the label still opens the child editor.
    const long: [253]u8 = @splat('a');
    const clipped = try rows(a, .{ .selected = 7 }, .{ .proxy_configured = true, .proxy_address = &long, .proxy_port = 65535 }, 12, 1);
    defer freeRows(a, clipped);
    try std.testing.expect(clipped.can_confirm and text.width(clipped.lines[0]) <= 12);
    const pasted = try rows(a, .{ .selected = 7, .pasted = true }, .{}, 80, 3);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
test "Proxy child menu keeps Address and Models reachable without an endpoint" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 2), proxy_labels.len);
    try std.testing.expectEqualStrings("Address", proxyLabel(0));
    try std.testing.expectEqualStrings("Models", proxyLabel(1));
    try std.testing.expectEqualStrings("Not configured", proxyValue(.{}, 0));
    try std.testing.expectEqualStrings("Off", proxyValue(.{}, 1));
    for (0..40) |columns| for ([_]usize{ 0, 1 }) |selected| {
        const rendered = try proxyRows(a, .{ .selected = selected }, .{}, columns, 3);
        defer freeRows(a, rendered);
        // A missing endpoint must never hide the row that can create it.
        try std.testing.expectEqual(columns >= 2 + proxyLabel(selected).len, rendered.can_confirm);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
    };
    const empty = try proxyRows(a, .{ .selected = 0 }, .{}, 40, 3);
    defer freeRows(a, empty);
    try std.testing.expect(std.mem.find(u8, empty.lines[0], "> Address") != null);
    try std.testing.expect(std.mem.find(u8, empty.lines[0], "Not configured") != null);
    try std.testing.expect(std.mem.find(u8, empty.lines[1], "Models") != null);
    try std.testing.expect(std.mem.find(u8, empty.lines[2], "Up/Down") != null);
    const configured = try proxyRows(a, .{ .selected = 1 }, .{ .proxy_configured = true, .proxy_address = "::1", .proxy_port = 8080, .proxy_model_count = 2 }, 40, 3);
    defer freeRows(a, configured);
    try std.testing.expect(std.mem.find(u8, configured.lines[0], "[::1]:8080") != null);
    try std.testing.expect(std.mem.find(u8, configured.lines[1], "2 selected") != null);
    try std.testing.expectEqual(@as(?usize, 1), configured.selected_line);
    // A one-row window keeps the selected row visible.
    const narrow = try proxyRows(a, .{ .selected = 1 }, .{}, 40, 1);
    defer freeRows(a, narrow);
    try std.testing.expectEqual(@as(?usize, 0), narrow.selected_line);
    try std.testing.expect(std.mem.find(u8, narrow.lines[0], "Models") != null);
    const none = try proxyRows(a, .{}, .{}, 40, 0);
    defer a.free(none.lines);
    try std.testing.expect(none.lines.len == 0 and none.selected_line == null and !none.can_confirm);
    const pasted = try proxyRows(a, .{ .pasted = true }, .{}, 40, 3);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
    const unavailable = try proxyRows(a, .{}, .{ .global_settings_available = false }, 40, 3);
    defer freeRows(a, unavailable);
    try std.testing.expect(!unavailable.can_confirm);
}
test "Proxy child menu releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, proxyAllocationCase, .{});
}
test "settings bounded windows keep selection visible and clipping disables confirmation" {
    const a = std.testing.allocator;
    for (0..count) |selected| for (0..10) |height| for (0..65) |columns| {
        const rendered = try rows(a, .{ .selected = selected }, .{}, columns, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.lines.len <= height);
        if (rendered.selected_line) |index| {
            try std.testing.expect(index < rendered.lines.len);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[index], label(selected)) != null);
        } else try std.testing.expect(height == 0);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
        if (height == 0 or columns < 2 + label(selected).len) try std.testing.expect(!rendered.can_confirm);
    };
    const exact = try rows(a, .{ .selected = 3 }, .{ .limits = .{ .command_timeout_ms = 123456 } }, 80, 1);
    defer freeRows(a, exact);
    try std.testing.expect(std.mem.find(u8, exact.lines[0], "123.456 s") != null);
    const unavailable = try rows(a, .{}, .{ .global_settings_available = false }, 80, 1);
    defer freeRows(a, unavailable);
    try std.testing.expect(!unavailable.can_confirm);
    const pasted = try rows(a, .{ .pasted = true }, .{}, 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
test "decision root opens with complete static label even when model is clipped" {
    const a = std.testing.allocator;
    var model: [512]u8 = @splat('x');
    @memcpy(model[0..9], "provider/");
    const state: Snapshot = .{ .decision_enabled = true, .decision_model = &model };
    for (0..90) |columns| {
        const rendered = try rows(a, .{ .selected = 1 }, state, columns, 1);
        defer freeRows(a, rendered);
        try std.testing.expectEqual(columns >= 2 + label(1).len, rendered.can_confirm);
        try std.testing.expect(text.width(rendered.lines[0]) <= columns);
    }
    const copied = try rows(a, .{ .selected = 1 }, state, 600, 1);
    defer freeRows(a, copied);
    model[9] = 'y';
    try std.testing.expect(std.mem.find(u8, copied.lines[0], "provider/xxx") != null);
    for ([_]usize{ 0, 2, 3, 4, 6 }) |selected| {
        const clipped = try rows(a, .{ .selected = selected }, .{}, 2 + label(selected).len, 1);
        defer freeRows(a, clipped);
        try std.testing.expect(!clipped.can_confirm);
    }
    const pasted = try rows(a, .{ .selected = 1, .pasted = true }, state, 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
test "Image root long value opens independently with static label" {
    const a = std.testing.allocator;
    const long: [512]u8 = @splat('x');
    for (0..90) |columns| {
        const rendered = try rows(a, .{ .selected = 5 }, .{ .image_enabled = true, .image_model = &long, .decision_enabled = true, .decision_model = "decision/other" }, columns, 1);
        defer freeRows(a, rendered);
        try std.testing.expectEqual(columns >= 2 + label(5).len, rendered.can_confirm);
    }
    try std.testing.expectEqualStrings("Image model", label(5));
    try std.testing.expectEqualStrings("Off", value(.{ .image_model = "stale/model" }, 5));
}
test "settings rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
