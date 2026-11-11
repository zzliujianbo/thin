test "provider selection wraps in both directions" {
    var picker: Picker = .{};
    picker.move(false, 4);
    try std.testing.expectEqual(@as(usize, 3), picker.selected);
    picker.move(true, 4);
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
    picker.selected = 99;
    picker.move(true, 4);
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
    const generation = picker.generation;
    picker.move(false, 0);
    try std.testing.expectEqual(generation, picker.generation);
}
test "provider candidate window has no title and confirms complete labels only" {
    const a = std.testing.allocator;
    const available = choices(true);
    const configured = (@as(u8, 1) << Id.all.len) - 1;
    for (0..available.len) |selected| {
        const picker: Picker = .{ .selected = selected };
        const width = 4 + text.width(available.items[selected].label());
        for (0..width + 1) |columns| {
            const rendered = try rows(a, picker, available, configured, columns, 1);
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
            try std.testing.expectEqual(@as(usize, 1), rendered.lines.len);
            try std.testing.expectEqual(@as(usize, 0), rendered.selected_line.?);
            try std.testing.expectEqual(columns == width, rendered.can_confirm);
            try std.testing.expectEqual(@as(u16, if (selected == 0) 0 else 1), rendered.checked_mask);
            try std.testing.expect(text.width(rendered.lines[0]) <= columns);
            try std.testing.expect(std.unicode.utf8ValidateSlice(rendered.lines[0]));
            if (rendered.can_confirm) try std.testing.expectEqualStrings(available.items[selected].label(), rendered.lines[0][if (selected == 0) @as(usize, 4) else 6..]);
        }
    }
    const all = try rows(a, .{ .selected = 3 }, available, 0, 80, 20);
    defer {
        for (all.lines) |line| a.free(line);
        a.free(all.lines);
    }
    try std.testing.expectEqual(@as(u16, 0), all.checked_mask);
    try std.testing.expectEqual(available.len, all.lines.len);
    try std.testing.expectEqual(@as(usize, 3), all.selected_line.?);
    const empty = try rows(a, .{}, available, 0, 80, 0);
    defer a.free(empty.lines);
    try std.testing.expect(empty.lines.len == 0 and empty.selected_line == null and !empty.can_confirm);
}
test "provider checked bits follow saved visible rows not navigation selection" {
    const a = std.testing.allocator;
    const available = choices(true);
    const saved_id = available.items[2].provider;
    const configured = @as(u8, 1) << @intCast(@backingInt(saved_id));
    for (0..available.len) |selected| {
        const rendered = try rows(a, .{ .selected = selected }, available, configured, 80, 2);
        defer {
            for (rendered.lines) |line| a.free(line);
            a.free(rendered.lines);
        }
        const start = @min(selected -| 1, available.len - 2);
        try std.testing.expectEqual(selected - start, rendered.selected_line.?);
        try std.testing.expect(rendered.can_confirm);
        for (rendered.lines, start..) |line, index| {
            const saved = index == 2;
            try std.testing.expectEqual(saved, rendered.checked_mask & (@as(u16, 1) << @intCast(index - start)) != 0);
            try std.testing.expectEqualStrings(if (selected == index) "> " else "  ", line[0..2]);
            const prefix_bytes: usize = if (saved) 6 else 4;
            try std.testing.expectEqualStrings(if (saved) "✓ " else "  ", line[2..prefix_bytes]);
            try std.testing.expect(std.mem.startsWith(u8, line[prefix_bytes..], available.items[index].label()));
            try std.testing.expectEqualStrings(available.items[index].label(), line[prefix_bytes..]);
            try std.testing.expect(std.mem.findScalar(u8, line, 0x1b) == null);
        }
    }
}
test "provider picker distinguishes Zen Go and local setup without holding keys" {
    const available = choices(true);
    try std.testing.expectEqual(Id.all.len + 1, available.len);
    try std.testing.expectEqualStrings("Current endpoint", available.items[0].label());
    try std.testing.expectEqualStrings("OpenCode Zen", available.items[2].label());
    try std.testing.expectEqualStrings("OpenCode Go", available.items[3].label());
    var picker: Picker = .{};
    picker.move(true, available.len);
    try std.testing.expectEqualStrings("DeepSeek", available.items[picker.selected].label());
    picker.markPaste();
    const a = std.testing.allocator;
    const rendered = try rows(a, picker, available, 7, 80, 8);
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expect(!rendered.can_confirm);
    try std.testing.expectEqual(@as(u16, 0b1110), rendered.checked_mask);
    try std.testing.expectEqualStrings("> ✓ DeepSeek", rendered.lines[1]);
    try std.testing.expectEqualStrings("    Current endpoint", rendered.lines[0]);
    picker.clear();
    for (0..7) |height| {
        const clipped = try rows(a, picker, available, 0, 5, height);
        defer {
            for (clipped.lines) |line| a.free(line);
            a.free(clipped.lines);
        }
        try std.testing.expect(!clipped.can_confirm and clipped.lines.len <= height);
        for (clipped.lines) |line| try std.testing.expect(text.width(line) <= 5);
    }
}
