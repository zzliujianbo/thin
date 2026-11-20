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
            offset = next;
        }
        try std.testing.expectEqual(bytes.len, offset);
    }
}
