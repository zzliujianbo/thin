test "colored rows preserve width, card background and ANSI ownership" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 10, .ansi = true, .base = .user };
    defer w.deinit();
    try w.emit("中文 é\nnext");
    try w.finish();
    for (w.lines.items) |line| {
        try std.testing.expectEqual(@as(usize, 10), displayWidth(line));
        try std.testing.expect(std.mem.indexOf(u8, line, theme.user_background) != null);
        try std.testing.expect(std.mem.endsWith(u8, line, theme.reset));
    }
}
test "warning and failure tones keep body color and row reset intact" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 40, .ansi = true };
    defer w.deinit();
    try w.setStyle(.{ .tone = .warning });
    try w.emit("warn\n");
    try w.setStyle(.{ .tone = .failure });
    try w.emit("fail\n");
    try w.setStyle(.{});
    try w.emit("plain");
    try w.finish();
    try std.testing.expectEqual(@as(usize, 3), w.lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, w.lines.items[0], "\x1b[38;5;220m" ++ "warn") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.lines.items[1], "\x1b[38;5;203m" ++ "fail") != null);
    for (w.lines.items) |line| try std.testing.expect(std.mem.endsWith(u8, line, theme.reset));
    // Returning to the default tone clears the color before ordinary body text.
    try std.testing.expect(std.mem.indexOf(u8, w.lines.items[2], theme.reset ++ "plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.lines.items[2], "\x1b[38;5;220m") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.lines.items[2], "\x1b[38;5;203m") == null);
    try expectRows(&w);
}
test "deferred FE0F and style boundary wrap the complete cluster" {
    try text.initLocale();
    for ([_]bool{ false, true }) |ansi| {
        var w: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = ansi };
        defer w.deinit();
        try w.emit("x❤");
        try std.testing.expectEqual(@as(usize, 1), w.col);
        try std.testing.expect(w.hasContent());
        try w.setStyle(.{ .bold = true });
        try w.emit("️");
        try w.setStyle(.{});
        try w.boundary();
        try std.testing.expectEqual(@as(usize, 2), w.lines.items.len);
        try std.testing.expectEqual(@as(usize, 1), displayWidth(w.lines.items[0]));
        try std.testing.expectEqual(@as(usize, 2), displayWidth(w.lines.items[1]));
        try std.testing.expect(std.mem.indexOf(u8, w.lines.items[1], "❤") != null);
        try std.testing.expect(std.mem.indexOf(u8, w.lines.items[1], "?") == null);
        if (ansi) try std.testing.expect(std.mem.indexOf(u8, w.lines.items[1], "❤" ++ theme.reset ++ "\x1b[1m️") != null);
        try expectRows(&w);
    }
}
test "combining modifiers ZWJ and regional triples across callbacks" {
    try text.initLocale();
    const Case = struct { pieces: []const []const u8, expected: []const u8, width: usize };
    const cases = [_]Case{
        .{ .pieces = &.{ "e", "́" }, .expected = "é", .width = 1 },
        .{ .pieces = &.{ "👍", "🏽" }, .expected = "👍🏽", .width = text.width("👍🏽") },
        .{ .pieces = &.{ "👩", "‍", "💻" }, .expected = "👩‍💻", .width = 4 },
        .{ .pieces = &.{ "🇺", "🇸", "🇨" }, .expected = "🇺🇸🇨", .width = 6 },
    };
    for (cases) |case| for ([_]bool{ false, true }) |ansi| {
        var w: Writer = .{ .a = std.testing.allocator, .columns = 20, .ansi = ansi };
        defer w.deinit();
        for (case.pieces, 0..) |piece, i| {
            try w.setStyle(.{ .italic = i % 2 == 1 });
            try w.emit(piece);
        }
        try w.finish();
        try std.testing.expectEqual(@as(usize, 1), w.lines.items.len);
        try std.testing.expectEqual(case.width, displayWidth(w.lines.items[0]));
        if (!ansi) try std.testing.expectEqualStrings(case.expected, w.lines.items[0]);
        try expectRows(&w);
    };
}
test "first glyph style and later logical style survive moved cluster" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = true };
    defer w.deinit();
    try w.emit("x");
    try w.setStyle(.{ .italic = true });
    try w.emit("❤");
    try w.setStyle(.{ .bold = true });
    try w.emit("️");
    try w.setStyle(.{ .underline = true });
    try w.emit("z");
    try w.finish();
    try std.testing.expectEqual(@as(usize, 3), w.lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, w.lines.items[1], theme.reset ++ "\x1b[3m❤" ++ theme.reset ++ "\x1b[1m️") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.lines.items[2], "\x1b[4mz") != null);
    try expectRows(&w);
}
test "prefix shares incremental state continuation physical rows and narrow glyphs" {
    try text.initLocale();
    var joined: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = false, .prefix = "❤" };
    defer joined.deinit();
    try joined.emit("️");
    try joined.finish();
    try std.testing.expectEqual(@as(usize, 1), joined.lines.items.len);
    try std.testing.expectEqualStrings("❤️", joined.lines.items[0]);
    var tight: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = false, .prefix = "> " };
    defer tight.deinit();
    try tight.emit("中");
    try tight.finish();
    try std.testing.expectEqual(@as(usize, 1), tight.lines.items.len);
    try std.testing.expectEqualStrings("中", tight.lines.items[0]);
    var cont: Writer = .{ .a = std.testing.allocator, .columns = 4, .ansi = false, .prefix = "- ", .continuation = "  " };
    defer cont.deinit();
    try cont.emit("abc");
    try cont.finish();
    try std.testing.expectEqualStrings("- ab", cont.lines.items[0]);
    try std.testing.expectEqualStrings("  c", cont.lines.items[1]);
    var leading: Writer = .{ .a = std.testing.allocator, .columns = 1, .ansi = false };
    defer leading.deinit();
    try leading.emit("́");
    try leading.emit("x");
    try leading.finish();
    try std.testing.expectEqualStrings("◌́", leading.lines.items[0]);
    try std.testing.expectEqualStrings("x", leading.lines.items[1]);
    var oversized: Writer = .{ .a = std.testing.allocator, .columns = 1, .ansi = false };
    defer oversized.deinit();
    try oversized.emit("❤");
    try oversized.emit("️");
    try oversized.finish();
    try std.testing.expectEqualStrings("?", oversized.lines.items[0]);
    try expectRows(&joined);
    try expectRows(&tight);
    try expectRows(&cont);
    try expectRows(&leading);
}
test "tab LF emitStyled user padding and discard APIs drain pending" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 8, .ansi = false };
    defer w.deinit();
    try w.emit("e");
    try w.emit("́\tq\n");
    try std.testing.expectEqualStrings("é   q", w.lines.items[0]);
    try w.emit("❤");
    try w.emit("️");
    try w.emitStyled("\x1b[1mx\x1b[0m");
    try std.testing.expectEqual(@as(usize, 3), w.col);
    try w.finish();
    try std.testing.expectEqual(@as(usize, 3), displayWidth(w.lines.items[1]));
    try w.setStyle(.{ .bold = true });
    w.prefix = "> ";
    try w.emit("discard");
    w.discardLine();
    try std.testing.expect(!w.hasContent());
    try std.testing.expectEqual(@as(usize, 0), w.col);
    try std.testing.expect(!w.row_started);
    try std.testing.expect(w.style.bold);
    try std.testing.expectEqualStrings("> ", w.prefix);
    try std.testing.expectEqual(@as(usize, 2), w.lines.items.len);
    var prefixed_tab: Writer = .{ .a = std.testing.allocator, .columns = 5, .ansi = false, .prefix = ">>>> " };
    defer prefixed_tab.deinit();
    try prefixed_tab.emit("\t");
    try prefixed_tab.finish();
    try std.testing.expectEqual(@as(usize, 1), prefixed_tab.lines.items.len);
    try std.testing.expectEqualStrings(">   ", prefixed_tab.lines.items[0]);
    var overflow: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = false };
    defer overflow.deinit();
    try overflow.emit("❤️");
    try std.testing.expectError(error.MarkdownCellOverflow, overflow.emitStyled("x"));
    try std.testing.expectEqual(@as(usize, 2), overflow.col);
    try std.testing.expect(overflow.cluster == null);
    var card: Writer = .{ .a = std.testing.allocator, .columns = 4, .ansi = true, .base = .user };
    defer card.deinit();
    try card.emit("❤");
    try card.setStyle(.{ .bold = true });
    try card.emit("️");
    try card.finish();
    try std.testing.expectEqual(@as(usize, 4), displayWidth(card.lines.items[0]));
    try std.testing.expect(std.mem.indexOf(u8, card.lines.items[0], "️  ") != null);
}
test "budget charges staged bytes once and bounds work lines and SGR" {
    var work: Budget = .{ .max_work = 3 };
    var w: Writer = .{ .a = std.testing.allocator, .columns = 10, .ansi = false, .budget = &work };
    defer w.deinit();
    try std.testing.expectError(error.MarkdownRenderLimit, w.emit("long"));
    // Bounded progress is kept, never half-dropped.
    try std.testing.expectEqual(@as(usize, 3), work.work);
    try std.testing.expect(w.hasContent());
    try w.finish();
    try std.testing.expectEqual(@as(usize, 1), w.lines.items.len);
    try std.testing.expectEqualStrings("lon", w.lines.items[0]);
    var bytes: Budget = .{ .max_bytes = 3 };
    var b: Writer = .{ .a = std.testing.allocator, .columns = 10, .ansi = false, .budget = &bytes };
    defer b.deinit();
    try b.emit("abc");
    try b.finish();
    try std.testing.expectEqual(@as(usize, 3), bytes.bytes);
    try std.testing.expectEqual(@as(usize, 3), bytes.work);
    try std.testing.expectError(error.MarkdownRenderLimit, b.emit("d"));
    var lines: Budget = .{ .max_lines = 1 };
    var l: Writer = .{ .a = std.testing.allocator, .columns = 1, .ansi = false, .budget = &lines };
    defer l.deinit();
    try l.emit("abc");
    try std.testing.expectError(error.MarkdownRenderLimit, l.finish());
    try std.testing.expectEqual(@as(usize, 1), l.lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), lines.lines);
    var ansi_bytes: Budget = .{ .max_bytes = 1 };
    var s: Writer = .{ .a = std.testing.allocator, .columns = 10, .ansi = true, .budget = &ansi_bytes };
    defer s.deinit();
    try std.testing.expectError(error.MarkdownRenderLimit, s.emit("a"));
    try std.testing.expectEqual(@as(usize, 0), ansi_bytes.bytes);
    try std.testing.expectEqual(@as(usize, 0), s.line.items.len);
}
test "joined scalars and regional pairs move atomically at narrow boundaries" {
    try text.initLocale();
    const cases = [_][]const []const u8{
        &.{ "x👩", "‍", "💻" },
        &.{ "x👍", "🏽" },
        &.{ "x🇺", "🇸", "🇨" },
    };
    for (cases) |pieces| for ([_]bool{ false, true }) |ansi| {
        var w: Writer = .{ .a = std.testing.allocator, .columns = 4, .ansi = ansi };
        defer w.deinit();
        for (pieces) |piece| {
            try w.emit(piece);
            try w.setStyle(.{ .italic = true });
        }
        try w.finish();
        try std.testing.expectEqual(@as(usize, 1), displayWidth(w.lines.items[0]));
        try std.testing.expectEqual(@as(usize, 4), displayWidth(w.lines.items[1]));
        try expectRows(&w);
        for (w.lines.items) |line| try std.testing.expect(std.mem.indexOfScalar(u8, line, '?') == null);
    };
    var w: Writer = .{ .a = std.testing.allocator, .columns = 4, .ansi = false };
    defer w.deinit();
    try w.emit("a‍");
    try w.emit("\n");
    try w.emit("b");
    try w.finish();
    try std.testing.expectEqualStrings("a‍", w.lines.items[0]);
    try std.testing.expectEqualStrings("b", w.lines.items[1]);
}
test "many extensions are linear and style changes are generated-byte bounded" {
    try text.initLocale();
    var budget: Budget = .{};
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), budget.max_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), budget.max_work);
    var w: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = false, .budget = &budget };
    defer w.deinit();
    try w.emit("a");
    for (0..4096) |_| try w.emit("́");
    try std.testing.expectEqual(@as(usize, 0), w.col);
    try std.testing.expectEqual(@as(usize, 8193), budget.work);
    try w.finish();
    try std.testing.expectEqual(@as(usize, 8193), budget.bytes);
    try std.testing.expectEqual(@as(usize, 1), displayWidth(w.lines.items[0]));
    var capped: Budget = .{ .max_bytes = 40 };
    var styled: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = true, .budget = &capped };
    defer styled.deinit();
    try styled.emit("a");
    var exceeded = false;
    for (0..20) |_| {
        styled.setStyle(.{ .bold = true }) catch |err| {
            try std.testing.expectEqual(error.MarkdownRenderLimit, err);
            exceeded = true;
            break;
        };
    }
    try std.testing.expect(exceeded);
    try std.testing.expect(capped.bytes <= capped.max_bytes);
}
test "ordinary text reuses cluster storage instead of allocating per glyph" {
    try text.initLocale();
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        var writer: Writer = .{ .a = counted.allocator(), .columns = 512, .ansi = false };
        defer writer.deinit();
        const source: [4096]u8 = @splat('a');
        try writer.emit(&source);
        try writer.finish();
        try std.testing.expectEqual(@as(usize, 8), writer.lines.items.len);
        for (writer.lines.items) |line| try std.testing.expectEqualSlices(u8, source[0..512], line);
        // Capacity growth and eight owned rows are allowed; 4096 independent
        // staging allocations are not. Independent of in-place resize success.
        try std.testing.expect(counted.allocations < 128);
    }
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}
test "allocation failures release detached clusters and owned finished rows" {
    try text.initLocale();
    // SafeAllocator may extend the last bucket allocation in place depending
    // on earlier tests/bucket fill. Exhaustive allocation-index injection needs
    // a stable path: reject resize/remap optimization, exercising EVERY fallback
    // allocation+copy instead. Other tests still use ordinary resizing allocators.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationScenario, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
test "row sink is opt-in and reports exact emit-stream row starts" {
    try text.initLocale();
    const a = std.testing.allocator;
    // Default off: rows keep accumulating in `lines` as before.
    var plain: Writer = .{ .a = a, .columns = 4, .ansi = false };
    defer plain.deinit();
    try plain.emit("abcdef");
    try plain.finish();
    try std.testing.expect(plain.sink == null);
    try std.testing.expectEqual(@as(usize, 2), plain.lines.items.len);

    var probe: SinkProbe = .{ .a = a };
    defer probe.deinit();
    var w: Writer = .{ .a = a, .columns = 4, .ansi = false, .sink = probe.sink() };
    defer w.deinit();
    try w.emit("ab");
    try std.testing.expectEqual(@as(usize, 0), w.lines.items.len);
    try w.emit("cd");
    try w.emit("\nefg");
    try w.finish();
    try std.testing.expectEqual(@as(usize, 0), w.lines.items.len);
    try std.testing.expectEqual(@as(usize, 2), probe.rows.items.len);
    try std.testing.expectEqualStrings("abcd", probe.rows.items[0].bytes);
    try std.testing.expectEqual(@as(usize, 0), probe.rows.items[0].start);
    try std.testing.expectEqualStrings("efg", probe.rows.items[1].bytes);
    try std.testing.expectEqual(@as(usize, 5), probe.rows.items[1].start);

    // A cluster moved onto a new row carries its own source span with it.
    var wrapped: SinkProbe = .{ .a = a };
    defer wrapped.deinit();
    var v: Writer = .{ .a = a, .columns = 2, .ansi = false, .sink = wrapped.sink() };
    defer v.deinit();
    try v.emit("ab");
    try v.emit("\u{2764}");
    try v.emit("\u{fe0f}");
    try v.finish();
    try std.testing.expectEqual(@as(usize, 2), wrapped.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), wrapped.rows.items[0].start);
    try std.testing.expectEqual(@as(usize, 2), wrapped.rows.items[1].start);
    try std.testing.expectEqualStrings("\u{2764}\u{fe0f}", wrapped.rows.items[1].bytes);
}
test "tab and newline row starts stay exact through wraps" {
    try text.initLocale();
    const a = std.testing.allocator;
    var probe: SinkProbe = .{ .a = a };
    defer probe.deinit();
    var w: Writer = .{ .a = a, .columns = 4, .ansi = false, .sink = probe.sink() };
    defer w.deinit();
    try w.emit("ab\tcd\n\tef");
    try w.finish();
    const rows = [_][]const u8{ "ab  ", "cd", "    ", "ef" };
    const starts = [_]usize{ 0, 3, 6, 7 };
    try std.testing.expectEqual(@as(usize, rows.len), probe.rows.items.len);
    for (rows, starts, probe.rows.items) |text_row, start, row| {
        try std.testing.expectEqualStrings(text_row, row.bytes);
        try std.testing.expectEqual(start, row.start);
    }
}
test "bounded emission matches unlimited across scalar and row budgets" {
    try text.initLocale();
    const input = "abcd中文👩‍💻é\txy\nlong text 中文\tend";
    for ([_]bool{ false, true }) |ansi| {
        var reference: Writer = .{ .a = std.testing.allocator, .columns = 5, .ansi = ansi, .prefix = "> ", .continuation = "> " };
        defer reference.deinit();
        try reference.emit(input);
        try reference.finish();
        for ([_]usize{ 1, 2, 5, 17 }) |bytes| {
            var w: Writer = .{ .a = std.testing.allocator, .columns = 5, .ansi = ansi, .prefix = "> ", .continuation = "> " };
            defer w.deinit();
            try std.testing.expectEqual(@as(usize, 0), try w.emitBounded(input, 0, 1));
            try std.testing.expectEqual(@as(usize, 0), try w.emitBounded(input, 1, 0));
            try std.testing.expect(!w.hasContent());
            var offset: usize = 0;
            while (offset < input.len) {
                const before = w.completed_rows;
                const n = try w.emitBounded(input[offset..], bytes, 1);
                try std.testing.expect(n > 0 and n <= bytes + 3);
                try std.testing.expect(w.completed_rows - before <= 2);
                offset += n;
            }
            try w.finish();
            try std.testing.expectEqual(reference.lines.items.len, w.lines.items.len);
            for (reference.lines.items, w.lines.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
        }
    }
}
test "bounded giant single emit makes bounded progress" {
    try text.initLocale();
    const input = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(input);
    @memset(input, 'x');
    var full: Writer = .{ .a = std.testing.allocator, .columns = 12, .ansi = true };
    defer full.deinit();
    try full.emit(input);
    try full.finish();
    var chunked: Writer = .{ .a = std.testing.allocator, .columns = 12, .ansi = true };
    defer chunked.deinit();
    var offset: usize = 0;
    while (offset < input.len) {
        const before = chunked.completed_rows;
        const n = try chunked.emitBounded(input[offset..], 97, 2);
        try std.testing.expect(n > 0 and n <= 100);
        try std.testing.expect(chunked.completed_rows - before <= 3);
        offset += n;
    }
    try chunked.finish();
    try std.testing.expectEqual(full.lines.items.len, chunked.lines.items.len);
    for (full.lines.items, chunked.lines.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}
test "bounded source spans belong to the row containing their glyph" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 1, .ansi = false };
    defer w.deinit();
    var probe: OriginProbe = .{ .writer = &w };
    w.sink = .{ .context = &probe, .onRow = OriginProbe.onRow };
    try std.testing.expectEqual(@as(usize, 1), try w.emitSourcedBounded("ab", 10, 12, true, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), try w.emitSourcedBounded("b", 11, 12, true, 1, 1));
    try w.finish();
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    try std.testing.expectEqual(@as(usize, 10), probe.starts[0]);
    try std.testing.expectEqual(@as(usize, 11), probe.ends[0]);
    try std.testing.expectEqual(@as(usize, 11), probe.starts[1]);
    try std.testing.expectEqual(@as(usize, 12), probe.ends[1]);
}
test "bounded atomic source remains atomic across slices" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 1, .ansi = false };
    defer w.deinit();
    var probe: OriginProbe = .{ .writer = &w };
    w.sink = .{ .context = &probe, .onRow = OriginProbe.onRow };
    try std.testing.expectEqual(@as(usize, 1), try w.emitSourcedBounded("ab", 20, 25, false, 1, 1));
    try std.testing.expectEqual(@as(usize, 1), try w.emitSourcedBounded("b", 20, 25, false, 1, 1));
    try w.finish();
    for (0..probe.count) |i| {
        try std.testing.expectEqual(@as(usize, 20), probe.starts[i]);
        try std.testing.expectEqual(@as(usize, 25), probe.ends[i]);
    }
}
test "synthetic and sourced glyphs keep independent row origins" {
    try text.initLocale();
    var w: Writer = .{ .a = std.testing.allocator, .columns = 1, .ansi = false };
    defer w.deinit();
    var probe: OriginProbe = .{ .writer = &w };
    w.sink = .{ .context = &probe, .onRow = OriginProbe.onRow };
    try w.emitSynthetic("x");
    try w.emitSourced("y", 20, 25, false);
    try w.emitSynthetic("z");
    try w.finish();
    try std.testing.expectEqual(@as(usize, 3), probe.count);
    try std.testing.expect(probe.synthetic[0]);
    try std.testing.expectEqual(@as(usize, 0), probe.ends[0]);
    try std.testing.expect(!probe.synthetic[1]);
    try std.testing.expectEqual(@as(usize, 20), probe.starts[1]);
    try std.testing.expectEqual(@as(usize, 25), probe.ends[1]);
    try std.testing.expect(probe.synthetic[2]);
    try std.testing.expectEqual(@as(usize, 0), probe.ends[2]);

    // A sourced combining mark gives an otherwise synthetic cluster an origin.
    var mixed: Writer = .{ .a = std.testing.allocator, .columns = 2, .ansi = false };
    defer mixed.deinit();
    var combined: OriginProbe = .{ .writer = &mixed };
    mixed.sink = .{ .context = &combined, .onRow = OriginProbe.onRow };
    try mixed.emitSynthetic("a");
    try mixed.emitSourced("́", 30, 32, true);
    try mixed.finish();
    try std.testing.expectEqual(@as(usize, 1), combined.count);
    try std.testing.expect(!combined.synthetic[0]);
    try std.testing.expectEqual(@as(usize, 30), combined.starts[0]);
    try std.testing.expectEqual(@as(usize, 32), combined.ends[0]);
}
test "a rejected sink row is freed exactly once by the writer" {
    try text.initLocale();
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var probe: RejectProbe = .{};
    {
        var w: Writer = .{
            .a = counted.allocator(),
            .columns = 4,
            .ansi = true,
            .sink = .{ .context = &probe, .onRow = RejectProbe.onRow },
        };
        defer w.deinit();
        try w.emit("abcd");
        try std.testing.expectEqual(@as(usize, 0), probe.attempts);
        // The row completes only at the row terminator, where the sink refuses.
        try std.testing.expectError(error.MarkdownRenderLimit, w.emit("\n"));
        try std.testing.expectEqual(@as(usize, 1), probe.attempts);
        try std.testing.expectEqual(@as(usize, 0), w.lines.items.len);
    }
    // Freed by the writer, never by the sink: no leak and no double free.
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}
