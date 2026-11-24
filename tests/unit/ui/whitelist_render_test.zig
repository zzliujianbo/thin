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

test "table palette survives ASCII runs and retired physical rows" {
    try @import("text.zig").initLocale();
    const theme = @import("theme.zig");
    const source = "|abcdefghijk  | B\n|---          |---\n|body\nnext";
    const header_lf = std.mem.indexOfScalar(u8, source, '\n').?;
    const body_at = std.mem.indexOf(u8, source, "|body").?;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 4, 40 }) |columns| {
        const baseline = try renderAll(a, source, columns, false, .normal);
        var cursor: usize = 0;
        var state: scan.State = .{};
        for (baseline.rows) |expected| {
            const result = try render(a, source[cursor..], cursor, state, true, columns, true, .normal, 1, 1);
            try std.testing.expectEqual(@as(usize, 1), result.rows.len);
            const row = result.rows[0];
            try std.testing.expect(row.complete and row.end > cursor);
            try std.testing.expectEqual(expected.end, row.end);
            try std.testing.expectEqual(expected.cells, row.cells);
            try std.testing.expectEqual(expected.soft_wrap, row.soft_wrap);
            try std.testing.expectEqualDeep(expected.checkpoint, row.checkpoint);

            // Check the effective SGR of every glyph, not just the first pipe.
            const want: output.Tone = if (cursor < header_lf) .table_header else if (cursor < body_at) .muted else .normal;
            var tone: output.Tone = .normal;
            var rest = row.text;
            var n: usize = 0;
            while (rest.len != 0) {
                if (std.mem.startsWith(u8, rest, theme.reset)) {
                    tone = .normal;
                    rest = rest[theme.reset.len..];
                } else if (std.mem.startsWith(u8, rest, theme.table_header)) {
                    tone = .table_header;
                    rest = rest[theme.table_header.len..];
                } else if (std.mem.startsWith(u8, rest, theme.muted)) {
                    tone = .muted;
                    rest = rest[theme.muted.len..];
                } else {
                    try std.testing.expectEqual(want, tone);
                    try std.testing.expect(n < expected.text.len);
                    try std.testing.expectEqual(expected.text[n], rest[0]);
                    n += 1;
                    rest = rest[1..];
                }
            }
            try std.testing.expectEqual(expected.text.len, n);
            cursor = row.end;
            state = row.checkpoint;
        }
        try std.testing.expectEqual(source.len, cursor);
    }
}

test "unresolved suffix paints literal wrapped rows without proving its source" {
    try @import("text.zig").initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "**可以直接使用", "`可以直接使用`", "| A | B |\n|---|" }) |source| {
        const preview = try render(a, source, 17, .{}, false, 4, false, .normal, 1, 64);
        try std.testing.expect(preview.rows.len > 1);
        var shown: std.ArrayList(u8) = .empty;
        for (preview.rows, 0..) |row, i| {
            if (i != 0 and preview.rows[i - 1].soft_wrap) try std.testing.expect(row.preview_continuation);
            try std.testing.expect(!row.complete);
            try std.testing.expectEqual(@as(usize, 17), row.end);
            try shown.appendSlice(a, row.text);
        }
        const expected = try std.mem.replaceOwned(u8, a, source, "\n", "");
        try std.testing.expectEqualStrings(expected, shown.items);
        try std.testing.expectEqual(@as(usize, 0), preview.consumed);
        try std.testing.expect(preview.metadata == null);
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
    for ([_]usize{ 4, 5 }) |columns| {
        var writer: output.Writer = .{ .a = a, .columns = columns, .ansi = false };
        var sink: Sink = .{ .a = a, .writer = &writer, .base = 0, .seed = .{ .end = 0, .state = .{} }, .max_rows = null };
        writer.sink = .{ .context = &sink, .onRow = Sink.onRow };
        try writer.emit("abcd\t");
        try writer.boundary();
        try writer.emit("e");
        try writer.finish();
        try std.testing.expectEqual(@as(usize, 3), sink.rows.items.len);
        try std.testing.expectEqual(columns == 4, sink.rows.items[0].soft_wrap);
        try std.testing.expect(!sink.rows.items[1].soft_wrap);
        try std.testing.expect(!sink.rows.items[2].soft_wrap);
    }
}
