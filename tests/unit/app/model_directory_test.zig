test "directory owns exact provider keys and metadata across value copies" {
    const t = std.testing;
    var original: Directory = .{};
    var input = [_]u8{ 'n', 'e', 'w', '/', 'i', 'd' };
    const row = try original.upsert(.opencode_go, &input);
    row.tokens = 123;
    row.dev_context_tokens = 456;
    row.available = true;
    row.protocol = .chat;
    row.dev_protocol = .anthropic;
    row.dev_present = true;
    row.reasoning = try Profile.from(.{ .map = .{ .off = "none", .low = "low" } });
    row.dev_reasoning = try Profile.from(.{ .format = .anthropic, .map = .{ .off = "disabled", .high = "high" } });
    input[0] = 'X';
    var copied = original;
    original.names[0] = 'X';
    try t.expectEqualStrings("opencode-go/new/id", copied.selector(0));
    try t.expectEqualStrings("new/id", copied.name(0));
    try t.expect(copied.find(.deepseek, "new/id") == null);
    try t.expect(copied.find(.opencode_go, "new") == null);
    try t.expect(copied.find(.opencode_go, "opencode-go/new/id") == null);
    try t.expectEqual(@as(usize, 0), copied.find(.opencode_go, "new/id").?);
    try t.expectEqual(@as(usize, 1), copied.count);
    _ = try copied.upsert(.opencode_go, "new/id");
    try t.expectEqual(@as(usize, 1), copied.count);
    var dest: Directory = .{};
    _ = try dest.upsert(.deepseek, "other");
    try dest.copyRecord(&copied, 0);
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
    try dest.copyRecord(&dest, 1);
    try t.expectEqual(@as(usize, 2), dest.count);
}
test "directory rejects invalid IDs and fails atomically at both capacity limits" {
    const t = std.testing;
    var d: Directory = .{};
    const long: [257]u8 = @splat('x');
    for ([_][]const u8{ "", "   ", "\t", "bad\n", "bad\x7f", &long }) |id| {
        try t.expectError(error.InvalidMetadata, d.upsert(.deepseek, id));
    }
    try t.expectEqual(@as(usize, 0), d.count);
    var buf: [32]u8 = undefined;
    for (0..max_models) |i| _ = try d.upsert(.deepseek, try std.fmt.bufPrint(&buf, "id-{d}", .{i}));
    const used = d.used;
    try t.expectError(error.MetadataTooLarge, d.upsert(.deepseek, "overflow"));
    try t.expectEqual(used, d.used);
    _ = try d.upsert(.deepseek, "id-0"); // Updating at capacity remains legal.
    d = .{};
    const name_bytes: [256]u8 = @splat('x');
    var i: usize = 0;
    while (true) : (i += 1) {
        var id = name_bytes;
        _ = try std.fmt.bufPrint(id[0..8], "{d:0>8}", .{i});
        const before_count = d.count;
        const before_used = d.used;
        _ = d.upsert(.opencode_go, &id) catch |err| {
            try t.expectEqual(error.MetadataTooLarge, err);
            try t.expectEqual(before_count, d.count);
            try t.expectEqual(before_used, d.used);
            try t.expect(d.count < max_models);
            break;
        };
    }
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
