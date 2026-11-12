test "directory owns exact provider keys and metadata across independent clones" {
    const t = std.testing;
    var original: Directory = .{};
    defer original.deinit(t.allocator);
    var input = [_]u8{ 'n', 'e', 'w', '/', 'i', 'd' };
    const row = try original.upsert(t.allocator, .opencode_go, &input);
    row.tokens = 123;
    row.dev_context_tokens = 456;
    row.available = true;
    row.protocol = .chat;
    row.dev_protocol = .anthropic;
    row.dev_present = true;
    row.reasoning = try Profile.from(.{ .map = .{ .off = "none", .low = "low" } });
    row.dev_reasoning = try Profile.from(.{ .format = .anthropic, .map = .{ .off = "disabled", .high = "high" } });
    input[0] = 'X';
    var copied = try original.clone(t.allocator);
    defer copied.deinit(t.allocator);
    original.names[0] = 'X';
    try t.expectEqualStrings("opencode-go/new/id", copied.selector(0));
    try t.expectEqualStrings("new/id", copied.name(0));
    try t.expect(copied.find(.deepseek, "new/id") == null);
    try t.expect(copied.find(.opencode_go, "new") == null);
    try t.expect(copied.find(.opencode_go, "opencode-go/new/id") == null);
    try t.expectEqual(@as(usize, 0), copied.find(.opencode_go, "new/id").?);
    try t.expectEqual(@as(usize, 1), copied.count);
    _ = try copied.upsert(t.allocator, .opencode_go, "new/id");
    try t.expectEqual(@as(usize, 1), copied.count);
    var dest: Directory = .{};
    defer dest.deinit(t.allocator);
    _ = try dest.upsert(t.allocator, .deepseek, "other");
    try dest.copyRecord(t.allocator, &copied, 0);
    try t.expect(dest.rows[1].offset != copied.rows[0].offset);
    try t.expectEqualStrings("new/id", dest.name(1));
    try t.expectEqual(@as(?u32, 123), dest.rows[1].tokens);
    try t.expectEqual(@as(?u32, 456), dest.rows[1].dev_context_tokens);
    try t.expectEqual(true, dest.rows[1].available.?);
    try t.expectEqual(Protocol.chat, dest.rows[1].protocol);
    try t.expectEqual(Protocol.anthropic, dest.rows[1].dev_protocol);
    try t.expect(dest.rows[1].dev_present);
    try t.expectEqualStrings("none", dest.rows[1].reasoning.?.declaration().map.off.?);
    try t.expectEqualStrings("disabled", dest.rows[1].dev_reasoning.?.declaration().map.off.?);
    try dest.copyRecord(t.allocator, &dest, 1);
    try t.expectEqual(@as(usize, 2), dest.count);
}
test "directory rejects invalid IDs while growing beyond old limits" {
    const t = std.testing;
    var d: Directory = .{};
    defer d.deinit(t.allocator);
    for ([_][]const u8{ "", "   ", "\t", "bad\n", "bad\x7f" }) |id| {
        try t.expectError(error.InvalidMetadata, d.upsert(t.allocator, .deepseek, id));
    }
    var id: [256]u8 = @splat('x');
    for (0..1600) |i| {
        _ = try std.fmt.bufPrint(id[0..8], "{d:0>8}", .{i});
        _ = try d.upsert(t.allocator, .opencode_go, &id);
    }
    try t.expectEqual(@as(usize, 1600), d.count);
    try t.expect(d.used > 128 * 1024);
    try t.expect(d.find(.opencode_go, &id) != null);
}
test "compact profiles round trip canonical wires and reject custom mappings" {
    const t = std.testing;
    for ([_]thinking.Declaration{
        .{ .map = .{ .off = "none", .minimal = "minimal", .low = "low", .medium = "medium", .high = "high", .xhigh = "xhigh", .max = "max" } },
        .{ .map = .{ .off = "off" } },
        .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } },
        .{ .format = .anthropic, .map = .{ .off = "disabled", .max = "max" } },
        .{ .format = .anthropic, .map = .{ .low = "low" } },
    }) |value| {
        const profile = try Profile.from(value);
        const decoded = profile.declaration();
        try decoded.validate();
        try t.expectEqual(value.format, decoded.format);
        inline for (level_names) |field| {
            if (@field(value.map, field)) |wire| {
                try t.expectEqualStrings(wire, @field(decoded.map, field).?);
            } else try t.expect(@field(decoded.map, field) == null);
        }
    }
    for ([_]thinking.Declaration{
        .{ .map = .{} },
        .{ .map = .{ .high = "intensive" } },
        .{ .map = .{ .off = "disabled" } },
        .{ .format = .deepseek, .map = .{ .off = "none" } },
        .{ .format = .anthropic, .map = .{ .off = "off" } },
    }) |value| {
        if (Profile.from(value)) |_| return error.ExpectedInvalidProfile else |_| {}
    }
    try t.expect(@sizeOf(Profile) <= 4);
}
