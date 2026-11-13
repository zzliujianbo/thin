const ascii_scan = @import("../ui/whitelist.zig");
const ascii_output = @import("../ui/markdown_writer.zig");

fn asciiCompare(reference: engine.Result, actual: engine.Result) !void {
    try std.testing.expectEqual(reference.consumed, actual.consumed);
    try std.testing.expectEqual(reference.work, actual.work);
    try std.testing.expectEqualDeep(reference.metadata, actual.metadata);
    try std.testing.expectEqual(reference.rows.len, actual.rows.len);
    for (reference.rows, actual.rows) |x, y| {
        try std.testing.expectEqualStrings(x.text, y.text);
        try std.testing.expectEqual(x.start, y.start);
        try std.testing.expectEqual(x.end, y.end);
        try std.testing.expectEqualDeep(x.checkpoint, y.checkpoint);
        try std.testing.expectEqual(x.complete, y.complete);
    }
}

fn asciiPair(source: []const u8, base: usize, state: ascii_scan.State, final: bool, columns: usize, quantum: usize, max_rows: usize, tone: ascii_output.Tone) !void {
    var reference_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer reference_arena.deinit();
    var actual_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer actual_arena.deinit();
    const a = reference_arena.allocator();
    const b = actual_arena.allocator();
    const reference = try ReferenceRender.render(a, source, base, state, final, columns, true, tone, quantum, max_rows);
    const actual = try engine.render(b, source, base, state, final, columns, true, tone, quantum, max_rows);
    try asciiCompare(reference, actual);
    for (reference.rows) |row| {
        if (row.end > base and row.end <= base + source.len) {
            const suffix = source[row.end - base ..];
            const x = try ReferenceRender.render(a, suffix, row.end, row.checkpoint, final, columns, true, tone, quantum, max_rows);
            const y = try engine.render(b, suffix, row.end, row.checkpoint, final, columns, true, tone, quantum, max_rows);
            try asciiCompare(x, y);
        }
    }
}

fn asciiFixture() [2807]u8 {
    var result: [2807]u8 = undefined;
    for (&result, 0..) |*byte, i| {
        const n = i / 6;
        byte.* = switch (i % 6) {
            0 => 'K',
            1 => '0' + @as(u8, @intCast(n / 1000 % 10)),
            2 => '0' + @as(u8, @intCast(n / 100 % 10)),
            3 => '0' + @as(u8, @intCast(n / 10 % 10)),
            4 => '0' + @as(u8, @intCast(n % 10)),
            else => ' ',
        };
    }
    return result;
}

test "ASCII batching matches independent scalar renderer and checkpoints" {
    try @import("../ui/text.zig").initLocale();
    const samples = [_][]const u8{
        "",                                            "K0001 K0002 Plain 345",                 "# ", "abcd", "abcd\n",
        "# Head\n> quote\n**bold** [link](u) \\* end", "```zig\ncode\n```\na_ * dangling [x](",
        "abc 中文 é 👩‍💻\tend\nnext",
        "**a**plain `x` trailing\\",
    };
    for (samples) |source| for ([_]usize{ 1, 2, 7, 109 }) |columns| for ([_]usize{ 0, 1, 2, 7, 4096 }) |quantum| for ([_]usize{ 1, 2, 65536 }) |max_rows| for ([_]bool{ false, true }) |final| {
        try asciiPair(source, 31, .{}, final, columns, quantum, max_rows, .normal);
        var seeded: ascii_scan.State = .{};
        seeded.at_line_start = false;
        try asciiPair(source, 31, seeded, final, columns, quantum, max_rows, .normal);
    };
    for (samples) |source| for (0..source.len + 1) |cut| {
        if (!std.unicode.utf8ValidateSlice(source[0..cut]) or !std.unicode.utf8ValidateSlice(source[cut..])) continue;
        try asciiPair(source[0..cut], 19, .{}, false, 7, 7, 2, .normal);
        var seeded: ascii_scan.State = .{};
        seeded.at_line_start = false;
        try asciiPair(source[cut..], 19 + cut, seeded, true, 7, 7, 2, .normal);
    };
    const long = asciiFixture();
    for ([_]bool{ false, true }) |final| try asciiPair(&long, 0, .{}, final, 109, 4096, 65536, .normal);
    for ([_]ascii_output.Tone{ .normal, .thinking, .user, .success }) |tone| {
        const source = "plain text **bold** 中文 end";
        try asciiPair(source, 31, .{}, true, 7, 4096, 65536, tone);
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        var b = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer b.deinit();
        const reference = try ReferenceRender.render(a.allocator(), source, 0, .{}, true, 109, true, tone, source.len, null);
        const actual = try engine.renderAll(b.allocator(), source, 109, true, tone);
        try asciiCompare(reference, actual);
    }
    try std.testing.expectError(error.MarkdownRenderLimit, engine.render(std.testing.allocator, "abc", 0, .{}, true, 7, true, .normal, 1, 0));
}

test "ordinary ASCII renderer propagates allocation failures" {
    try @import("../ui/text.zig").initLocale();
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), asciiAllocationCase, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
    var nofail = std.testing.FailingAllocator.init(backing.allocator(), .{});
    try asciiAllocationCase(nofail.allocator());
    const bound = nofail.alloc_index;
    try std.testing.expect(bound > 0);
    try std.testing.expectEqual(nofail.allocated_bytes, nofail.freed_bytes);
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
    _ = try asciiSweepAllocationCase(bound, false);
    try std.testing.expect(try asciiSweepAllocationCase(bound, true));
}

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
test "body warm invalid rebuilds reuse arena and preserve pinned rows" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    {
        const body = try body_mod.Body.create(backing.allocator(), 8);
        defer body.destroy();
        try body.append("alpha beta gamma\n");
        try body.build();
        body.abort();
        try body.build(); // Consolidate the initial arena nodes.
        body.abort();
        try body.build(); // Warm the consolidated layout.
        body.releasePin();
        const allocs = backing.allocations;
        const renders = body.stats.renders;
        try body.build(); // valid repin does not render
        try std.testing.expectEqual(renders, body.stats.renders);
        const old = body.visibleRows()[0].text;
        const old_copy = try std.testing.allocator.dupe(u8, old);
        defer std.testing.allocator.free(old_copy);
        try body.append("delta\n");
        try body.finish();
        try std.testing.expectEqual(old.ptr, body.visibleRows()[0].text.ptr);
        try std.testing.expectEqualStrings(old_copy, body.visibleRows()[0].text);
        body.releasePin();
        try body.build();
        body.abort();
        try body.build(); // consolidate after the larger source
        body.abort();
        try body.build();
        body.abort();
        const warm_allocs = backing.allocations;
        try std.testing.expect(warm_allocs >= allocs);
        for (0..3) |_| {
            try body.build();
            body.abort();
        }
        try std.testing.expectEqual(warm_allocs, backing.allocations);
        body.resize(4);
        try body.build();
        try std.testing.expectEqualStrings("alpha beta gamma\ndelta\n", body.source.items);
    }
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "body retain reset preheat OOM clears render refs without semantic mutation" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    {
        const body = try body_mod.Body.create(backing.allocator(), 8);
        defer body.destroy();
        try body.append("alpha\n\xf0\x9f");
        try body.build();
        body.abort();
        // Force multiple used nodes so retain_capacity must preheat via alloc.
        _ = try body.arena.allocator().alloc(u8, 16384);
        _ = try body.arena.allocator().alloc(u8, 65536);
        const before_base = body.base;
        const before_state = body.state;
        const before_decoder = body.decoder;
        const before_stats = body.stats;
        const before_finished = body.finished;
        const before_dirty = body.dirty;
        const before_end = body.acceptedSourceEnd();
        backing.fail_index = backing.alloc_index;
        try std.testing.expectError(error.OutOfMemory, body.build());
        try std.testing.expect(backing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), body.rows.len);
        try std.testing.expect(body.metadata == null);
        try std.testing.expectEqual(@as(usize, 0), body.consumed);
        try std.testing.expect(!body.valid and !body.pinned);
        try std.testing.expectEqual(body_mod.Limit.memory, body.limit);
        try std.testing.expectEqual(before_base, body.base);
        try std.testing.expectEqualDeep(before_state, body.state);
        try std.testing.expectEqualDeep(before_decoder, body.decoder);
        try std.testing.expectEqualDeep(before_stats, body.stats);
        try std.testing.expectEqual(before_finished, body.finished);
        try std.testing.expectEqual(before_dirty, body.dirty);
        try std.testing.expectEqual(before_end, body.acceptedSourceEnd());
        try std.testing.expectEqualStrings("alpha\n", body.source.items);
        backing.fail_index = std.math.maxInt(usize);
        try body.build();
        try std.testing.expectEqual(body_mod.Limit.memory, body.limit);
    }
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "body releases only unpinned drained render capacity" {
    const body = try body_mod.Body.create(std.testing.allocator, 80);
    defer body.destroy();
    try body.append("hello\n");
    try body.build();
    const capacity = body.arena.queryCapacity();
    try std.testing.expect(capacity > 0);
    body.releaseDrainedRender();
    try std.testing.expectEqual(capacity, body.arena.queryCapacity());
    try body.finish();
    body.releaseDrainedRender();
    try std.testing.expectEqual(capacity, body.arena.queryCapacity());
    body.releasePin();
    body.releaseDrainedRender();
    try std.testing.expectEqual(capacity, body.arena.queryCapacity());
    try body.build();
    _ = try body.commit(body.visibleRows().len);
    try std.testing.expect(body.isDrained());
    const stats = body.stats;
    body.releaseDrainedRender();
    try std.testing.expectEqual(@as(usize, 0), body.arena.queryCapacity());
    try std.testing.expectEqual(@as(usize, 0), body.rows.len);
    try std.testing.expect(body.metadata == null and !body.valid);
    try std.testing.expectEqual(@as(usize, 0), body.consumed);
    try std.testing.expectEqualDeep(stats, body.stats);
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
