test "streaming chunks and ACK checkpoints match static glyph styles" {
    try @import("../ui/text.zig").initLocale();
    const a = std.testing.allocator;
    const samples = [_][]const u8{
        "# Heading\n**wide 中文 text and even longer bold across rows** [link](url)\n| raw | table |\n```\ncode 👩‍💻 é plain\n```\n",
        "normal é **a👩‍💻b** end\n",
        "**before `中👩‍💻**` after** [a ``x`]`` b](url)\n",
    };
    for (samples) |source| for ([_]usize{ 1, 2, 7, 12 }) |columns| for ([_]usize{ 1, 7, 64, 4096 }) |quantum| {
        const reference = try markdown.render(a, source, .{ .columns = columns, .max_lines = 4096 });
        defer markdown.release(a, reference);
        const body = try body_mod.Body.create(a, columns);
        defer body.destroy();
        body.max_window_bytes = quantum;
        var rows: std.ArrayList([]const u8) = .empty;
        defer freeRows(a, &rows);
        var pos: usize = 0;
        while (pos < source.len) {
            const end = @min(source.len, pos + 3);
            try body.append(source[pos..end]);
            pos = end;
            try progress(a, body, &rows, false);
        }
        try body.finish();
        try progress(a, body, &rows, true);
        try std.testing.expect(body.isDrained());
        try std.testing.expectEqual(body.acceptedSourceEnd(), body.committedSourceEnd());
        try expectAppearance(a, reference.lines, rows.items);
    };
}
test "Chinese English strong static and every byte split one row ACK" {
    try @import("../ui/text.zig").initLocale();
    const a = std.testing.allocator;
    const inner = "不是三 schema";
    const cases = [_]struct { source: []const u8, visible: []const u8, start: usize }{
        .{ .source = "**不是三 schema**", .visible = "不是三 schema\n", .start = 0 },
        .{ .source = "前**不是三 schema**后", .visible = "前不是三 schema后\n", .start = "前".len },
    };
    for (cases) |case| {
        const wide = try markdown.render(a, case.source, .{ .columns = 80, .max_lines = 256 });
        defer markdown.release(a, wide);
        const glyphs = try appearance(a, wide.lines);
        defer a.free(glyphs);
        try std.testing.expectEqual(case.visible.len, glyphs.len);
        for (glyphs, 0..) |glyph, i| {
            try std.testing.expectEqual(case.visible[i], glyph.byte);
            try std.testing.expectEqual(i >= case.start and i < case.start + inner.len, glyph.style.bold);
        }
        for ([_]usize{ 1, 4, 12, 80 }) |columns| {
            const reference = try markdown.render(a, case.source, .{ .columns = columns, .max_lines = 256 });
            defer markdown.release(a, reference);
            for ([_]usize{ 1, 64 }) |quantum| for (0..case.source.len + 1) |split| {
                const body = try body_mod.Body.create(a, columns);
                defer body.destroy();
                body.max_window_bytes = quantum;
                var rows: std.ArrayList([]const u8) = .empty;
                defer freeRows(a, &rows);
                try body.append(case.source[0..split]);
                try progressOne(a, body, &rows);
                try body.append(case.source[split..]);
                try body.finish();
                for (0..16384) |_| {
                    if (body.isDrained()) break;
                    try progressOne(a, body, &rows);
                }
                try std.testing.expect(body.isDrained());
                try std.testing.expectEqual(body.acceptedSourceEnd(), body.committedSourceEnd());
                try expectAppearance(a, reference.lines, rows.items);
            };
        }
    }
}
test "Chinese English strong inline code remains literal purple" {
    try @import("../ui/text.zig").initLocale();
    const a = std.testing.allocator;
    const expected = "**不是三 schema**\n";
    const rendered = try markdown.render(a, "`**不是三 schema**`", .{ .columns = 80, .max_lines = 16 });
    defer markdown.release(a, rendered);
    const glyphs = try appearance(a, rendered.lines);
    defer a.free(glyphs);
    try std.testing.expectEqual(expected.len, glyphs.len);
    for (glyphs, 0..) |glyph, i| {
        try std.testing.expectEqual(expected[i], glyph.byte);
        try std.testing.expect(!glyph.style.bold);
        if (i + 1 < glyphs.len) try std.testing.expectEqual(@as(u16, 141), glyph.style.fg);
    }
}
test "inline code static and streaming agree at every split" {
    try @import("../ui/text.zig").initLocale();
    const a = std.testing.allocator;
    const source = "**a `中👩‍💻**` z** [x ``a`]`` y](u)\n";
    for ([_]usize{ 2, 7 }) |columns| for ([_]usize{ 1, 64 }) |quantum| {
        const reference = try markdown.render(a, source, .{ .columns = columns, .max_lines = 256 });
        defer markdown.release(a, reference);
        for (0..source.len + 1) |split| {
            const body = try body_mod.Body.create(a, columns);
            defer body.destroy();
            body.max_window_bytes = quantum;
            var rows: std.ArrayList([]const u8) = .empty;
            defer freeRows(a, &rows);
            try body.append(source[0..split]);
            try progress(a, body, &rows, false);
            try body.append(source[split..]);
            try body.finish();
            try progress(a, body, &rows, true);
            try std.testing.expect(body.isDrained());
            try std.testing.expectEqual(body.acceptedSourceEnd(), body.committedSourceEnd());
            try expectAppearance(a, reference.lines, rows.items);
        }
    };
}
test "inline code uses purple and keeps literal markup" {
    const a = std.testing.allocator;
    const rendered = try markdown.render(a, "x `**raw**` y", .{ .columns = 80, .max_lines = 16 });
    defer markdown.release(a, rendered);
    const glyphs = try appearance(a, rendered.lines);
    defer a.free(glyphs);
    const bytes = try a.alloc(u8, glyphs.len);
    defer a.free(bytes);
    for (glyphs, 0..) |g, i| bytes[i] = g.byte;
    try std.testing.expectEqualStrings("x **raw** y\n", bytes);
    for (glyphs[2..9]) |g| {
        try std.testing.expectEqual(@as(u16, 141), g.style.fg);
        try std.testing.expect(!g.style.bold);
    }
}
test "single-byte chunks and one-row ACK preserve full-width and styled boundaries" {
    try @import("../ui/text.zig").initLocale();
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "abcd\n", "abcd", "**ab👩‍💻cdef**\n", "[abcd](url)\n", "**a `中👩‍💻**` z**\n", "x ``a`b``\n", "A👩‍💻\r\n中文\r\n" };
    for (cases) |source| {
        const reference = try markdown.render(a, source, .{ .columns = 4, .max_lines = 128 });
        defer markdown.release(a, reference);
        const body = try body_mod.Body.create(a, 4);
        defer body.destroy();
        body.max_window_bytes = 1;
        var rows: std.ArrayList([]const u8) = .empty;
        defer freeRows(a, &rows);
        for (source) |byte| {
            try body.append(&.{byte});
            try progressOne(a, body, &rows);
        }
        try body.finish();
        for (0..16384) |_| {
            if (body.isDrained()) break;
            try progressOne(a, body, &rows);
        }
        try std.testing.expect(body.isDrained());
        try std.testing.expectEqual(body.acceptedSourceEnd(), body.committedSourceEnd());
        try expectAppearance(a, reference.lines, rows.items);
    }
}
test "UTF8 and CRLF at every split match static rendering" {
    try @import("../ui/text.zig").initLocale();
    const a = std.testing.allocator;
    const source = "## 标题 👩‍💻\r\n**é中文**\r\nx\r\n";
    for ([_]usize{ 1, 2, 7 }) |columns| {
        const reference = try markdown.render(a, source, .{ .columns = columns, .max_lines = 256 });
        defer markdown.release(a, reference);
        for (0..source.len + 1) |split| {
            const body = try body_mod.Body.create(a, columns);
            defer body.destroy();
            body.max_window_bytes = 1;
            var rows: std.ArrayList([]const u8) = .empty;
            defer freeRows(a, &rows);
            try body.append(source[0..split]);
            try progressOne(a, body, &rows);
            try body.append(source[split..]);
            try body.finish();
            for (0..16384) |_| {
                if (body.isDrained()) break;
                try progressOne(a, body, &rows);
            }
            try std.testing.expect(body.isDrained());
            try std.testing.expectEqual(body.acceptedSourceEnd(), body.committedSourceEnd());
            try expectAppearance(a, reference.lines, rows.items);
        }
    }
}
test "decoder state and row checkpoints survive aborted frames" {
    try @import("../ui/text.zig").initLocale();
    const body = try body_mod.Body.create(std.testing.allocator, 2);
    defer body.destroy();
    try body.append("A\r");
    try std.testing.expect(body.decoder.held_cr);
    try std.testing.expectEqual(@as(usize, 2), body.acceptedSourceEnd());
    try std.testing.expectEqualStrings("A", body.source.items);
    try body.append("\n\xf0\x9f");
    try std.testing.expect(!body.decoder.held_cr);
    try std.testing.expectEqual(@as(usize, 2), body.decoder.carry_len);
    try std.testing.expectEqualSlices(u8, "\xf0\x9f", body.decoder.carry[0..body.decoder.carry_len]);
    try std.testing.expectEqualStrings("A\n", body.source.items);
    try body.append("\x91\xa9\n");
    try std.testing.expectEqual(@as(usize, 0), body.decoder.carry_len);
    try std.testing.expectEqualStrings("A\n👩\n", body.source.items);
    try body.finish();
    try body.build();
    try std.testing.expectEqual(@as(usize, 2), body.visibleRows().len);
    try std.testing.expectEqual(@as(usize, 0), body.visibleRows()[0].start);
    try std.testing.expectEqual(@as(usize, 2), body.visibleRows()[0].end);
    try std.testing.expectEqual(@as(usize, 2), body.visibleRows()[1].start);
    try std.testing.expectEqual(@as(usize, 7), body.visibleRows()[1].end);
    try std.testing.expect(body.visibleRows()[0].complete and body.visibleRows()[1].complete);
    try std.testing.expect(std.mem.indexOf(u8, body.visibleRows()[0].text, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body.visibleRows()[1].text, "👩") != null);
    try std.testing.expectEqual(@as(usize, 2), body.visibleSourceEndForRows(1));
    try std.testing.expectEqual(@as(usize, 7), body.visibleSourceEnd());
    try std.testing.expectEqual(@as(usize, 0), body.committedSourceEnd());
    try std.testing.expectEqual(@as(usize, 7), body.windowBytes());

    // The caller aborts an incomplete frame before retrying its checkpoints.
    body.abort();
    try std.testing.expectEqual(@as(usize, 0), try body.commit(1));
    try std.testing.expectEqual(@as(usize, 0), body.committedSourceEnd());
    try std.testing.expectEqual(@as(usize, 7), body.windowBytes());
    try body.build();
    // Model the caller committing the covered prefix after a fresh frame ACK.
    try std.testing.expectEqual(@as(usize, 1), try body.commit(1));
    try std.testing.expectEqual(@as(usize, 2), body.committedSourceEnd());
    try std.testing.expectEqual(@as(usize, 5), body.windowBytes());
    try body.build();
    try std.testing.expectEqual(@as(usize, 2), body.visibleRows()[0].start);
    try std.testing.expectEqual(@as(usize, 7), body.visibleRows()[0].end);
    body.releasePin();
    try std.testing.expectEqual(@as(usize, 0), try body.commit(1));
    try std.testing.expectEqual(@as(usize, 2), body.committedSourceEnd());
    try body.build();
    try std.testing.expectEqual(@as(usize, 1), try body.commit(1));
    try std.testing.expect(body.isDrained());
    try std.testing.expectEqual(@as(usize, 7), body.committedSourceEnd());
}
test "empty heading metadata waits for a fresh checkpoint commit" {
    const body = try body_mod.Body.create(std.testing.allocator, 2);
    defer body.destroy();
    try body.append("# ");
    try body.build();
    try std.testing.expect(!body.hasMetadataProgress());
    try body.finish();
    try std.testing.expect(!body.hasMetadataProgress());
    body.releasePin();
    try body.build();
    try std.testing.expectEqual(@as(usize, 0), body.visibleRows().len);
    try std.testing.expectEqual(@as(usize, 0), body.pendingBytes());
    try std.testing.expect(body.hasMetadataProgress());
    try std.testing.expectEqual(@as(usize, 0), body.committedSourceEnd());
    body.abort();
    try std.testing.expectEqual(@as(usize, 0), try body.commit(0));
    try std.testing.expectEqual(@as(usize, 2), body.windowBytes());
    try body.build();
    try std.testing.expect(body.hasMetadataProgress());
    try std.testing.expectEqual(@as(usize, 0), try body.commit(0));
    try std.testing.expectEqual(@as(usize, 2), body.committedSourceEnd());
    try std.testing.expect(body.isDrained());
}
test "literal unclosed inline cap and long fenced code make progress" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "**");
    try source.appendNTimes(a, 'x', 2200);
    try source.appendSlice(a, "\n```\n");
    try source.appendNTimes(a, 'c', 400);
    try source.appendSlice(a, "\n```\n");
    const reference = try markdown.render(a, source.items, .{ .columns = 7, .max_lines = 4096 });
    defer markdown.release(a, reference);
    const body = try body_mod.Body.create(a, 7);
    defer body.destroy();
    body.max_window_bytes = 7;
    var rows: std.ArrayList([]const u8) = .empty;
    defer freeRows(a, &rows);
    var pos: usize = 0;
    while (pos < source.items.len) {
        const end = @min(source.items.len, pos + 31);
        try body.append(source.items[pos..end]);
        pos = end;
        try progress(a, body, &rows, false);
    }
    try body.finish();
    try progress(a, body, &rows, true);
    try std.testing.expect(body.isDrained());
    try std.testing.expectEqual(body.acceptedSourceEnd(), body.committedSourceEnd());
    try expectAppearance(a, reference.lines, rows.items);
}
test "pinned append partial commit abort resize and metadata-only closer" {
    const a = std.testing.allocator;
    const body = try body_mod.Body.create(a, 2);
    defer body.destroy();
    try body.append("**abcd**");
    try body.finish();
    try body.build();
    const n = body.releaseLimit(body.visibleRows().len);
    try std.testing.expect(n != 0);
    try std.testing.expectEqual(@as(usize, 1), try body.commit(1));
    const first = body.committedSourceEnd();
    try body.build();
    body.abort();
    try std.testing.expectEqual(first, body.committedSourceEnd());
    body.resize(1);
    var rows: std.ArrayList([]const u8) = .empty;
    defer freeRows(a, &rows);
    // Retire displayed rows only; the closing delimiter must be a separate ACK.
    for (0..32) |_| {
        try body.build();
        if (body.hasMetadataProgress()) break;
        const take = body.releaseLimit(body.visibleRows().len);
        try std.testing.expect(take != 0);
        _ = try body.commit(take);
    }
    try std.testing.expect(body.hasMetadataProgress());
    const before = body.committedSourceEnd();
    body.abort();
    try std.testing.expectEqual(@as(usize, 0), try body.commit(0));
    try std.testing.expectEqual(before, body.committedSourceEnd());
    try body.build();
    try std.testing.expect(body.hasMetadataProgress());
    _ = try body.commit(0);
    try std.testing.expect(body.isDrained());
    try std.testing.expectEqual(body.acceptedSourceEnd(), body.committedSourceEnd());

    const pin = try body_mod.Body.create(a, 4);
    defer pin.destroy();
    try pin.append("abcdef");
    try pin.build();
    const count = pin.visibleRows().len;
    try pin.append("gh\n");
    try std.testing.expectEqual(count, pin.visibleRows().len);
    pin.releasePin();
    try pin.finish();
    try progress(a, pin, &rows, true);
    try std.testing.expect(pin.isDrained());
}
test "plain mode does not invent a trailing empty row" {
    const a = std.testing.allocator;
    const result = try markdown.render(a, "line\n", .{ .columns = 80, .max_lines = 20, .ansi = false, .markdown = false });
    defer markdown.release(a, result);
    try std.testing.expectEqual(@as(usize, 1), result.lines.len);
    try std.testing.expectEqualStrings("line", result.lines[0]);
}
test "allocation failures preserve decoder and release owned resources" {
    // Strict fault indices must not depend on allocator-layout-dependent remaps.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationCase, .{});
    try std.testing.checkAllAllocationFailures(backing.allocator(), appendHeldCrAllocationCase, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);

    // The no-remap count bounds the normal path, where successful growth can
    // eliminate allocations. Still check every induced failure and ownership.
    var nofail = std.testing.FailingAllocator.init(backing.allocator(), .{});
    try allocationCase(nofail.allocator());
    const bound = nofail.alloc_index;
    try std.testing.expect(bound > 0);
    try std.testing.expectEqual(nofail.allocated_bytes, nofail.freed_bytes);
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
    _ = try sweepNormalAllocationCase(bound, false);
    // A fresh fixed-buffer layout makes growth reproducible independently of
    // the heap's current bucket occupancy, while running the same callback.
    try std.testing.expect(try sweepNormalAllocationCase(bound, true));
}
test "finish allocation failures retain held CR and UTF8 for retry" {
    // Force growth through allocation so staging and source publication both
    // participate in exhaustive failure injection.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), finishAllocationCase, .{ "\r", "abcdefgh�" });
    try std.testing.checkAllAllocationFailures(backing.allocator(), finishAllocationCase, .{ "\xf0\x9f", "abcdefgh��" });
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
test "oversized cluster fails explicitly without retiring source" {
    const a = std.testing.allocator;
    const body = try body_mod.Body.create(a, 8);
    defer body.destroy();
    body.max_window_bytes = 1;
    try body.append("a");
    for (0..engine.max_cluster_source_bytes / 2 + 2) |_| try body.append("\u{0301}");
    try body.finish();
    try std.testing.expectError(error.MarkdownRenderLimit, body.build());
    try std.testing.expect(body.limit != .none);
    try std.testing.expectEqual(@as(usize, 0), body.committedSourceEnd());
    try std.testing.expect(body.windowBytes() != 0);
}
test "row cap yields completed rows without dropping staged glyph" {
    const a = std.testing.allocator;
    const body = try body_mod.Body.create(a, 2);
    defer body.destroy();
    body.max_rows = 1;
    try body.append("abcdefgh\n");
    try body.finish();
    var rows: std.ArrayList([]const u8) = .empty;
    defer freeRows(a, &rows);
    try progress(a, body, &rows, true);
    try std.testing.expect(body.isDrained());
    const expected = try markdown.render(a, "abcdefgh\n", .{ .columns = 2, .max_lines = 10 });
    defer markdown.release(a, expected);
    try expectAppearance(a, expected.lines, rows.items);
}
