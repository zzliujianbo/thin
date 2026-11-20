test "one ASCII trace record resolves successive displayed boundaries" {
    try @import("text.zig").initLocale();
    const bytes: [256]u8 = @splat('x');
    const base = 37;
    const state: scan.State = .{ .at_line_start = false };
    for ([_]usize{ bytes.len, 7 }) |columns| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var writer: output.Writer = .{ .a = a, .columns = columns, .ansi = false };
        var sink: Sink = .{ .a = a, .writer = &writer, .base = base, .seed = .{ .end = base, .state = state }, .max_rows = null };
        writer.sink = .{ .context = &sink, .onRow = Sink.onRow };

        // Feed one batch directly: the wide case observes its full record
        // count before pruning; narrow rows force callbacks inside that run.
        try sink.emitAscii(&bytes, base);
        try std.testing.expectEqual(@as(usize, 1), sink.trace.items.len);
        try writer.finish();
        try std.testing.expectEqual(@as(usize, 0), sink.trace.items.len);
        var offset: usize = 0;
        for (sink.rows.items) |row| {
            const next = @min(offset + columns, bytes.len);
            try std.testing.expectEqual(base + offset, row.start);
            try std.testing.expectEqual(base + next, row.end);
            try std.testing.expectEqualStrings(bytes[offset..next], row.text);
            try std.testing.expectEqualDeep(state, row.checkpoint);
            try std.testing.expectEqual(next < bytes.len, row.soft_wrap);
            try std.testing.expectEqual(next - offset, row.cells);
            offset = next;
        }
        try std.testing.expectEqual(bytes.len, offset);
    }
}

test "preview cells include emitted user padding but exclude styling" {
    try @import("text.zig").initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |ansi| {
        const result = try render(arena.allocator(), "界", 0, .{}, false, 4, ansi, .user, 16, 1);
        try std.testing.expectEqual(@as(usize, 1), result.rows.len);
        const row = result.rows[0];
        try std.testing.expectEqual(if (ansi) @as(usize, 4) else @as(usize, 2), row.cells);
        try std.testing.expect(!row.complete and !row.soft_wrap);
    }
}

test "tab overflow wraps but explicit boundaries do not" {
    try @import("text.zig").initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var writer: output.Writer = .{ .a = a, .columns = 4, .ansi = false };
    var sink: Sink = .{ .a = a, .writer = &writer, .base = 0, .seed = .{ .end = 0, .state = .{} }, .max_rows = null };
    writer.sink = .{ .context = &sink, .onRow = Sink.onRow };
    try writer.emit("abcd\t");
    try writer.boundary();
    try writer.emit("e");
    try writer.finish();
    try std.testing.expectEqual(@as(usize, 3), sink.rows.items.len);
    try std.testing.expect(sink.rows.items[0].soft_wrap);
    try std.testing.expect(!sink.rows.items[1].soft_wrap);
    try std.testing.expect(!sink.rows.items[2].soft_wrap);
}
