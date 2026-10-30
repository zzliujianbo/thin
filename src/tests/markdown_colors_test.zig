const std = @import("std");
const markdown = @import("../ui/markdown.zig");
const body_mod = @import("../ui/body_stream.zig");
const engine = @import("../ui/whitelist_render.zig");
const Allocator = std.mem.Allocator;

fn freeRows(a: Allocator, rows: *std.ArrayList([]const u8)) void {
    for (rows.items) |row| a.free(row);
    rows.deinit(a);
}
fn progress(a: Allocator, body: *body_mod.Body, out: *std.ArrayList([]const u8), final: bool) !void {
    for (0..16384) |_| {
        if (body.isDrained()) return;
        try body.build();
        try std.testing.expect(body.stats.max_window_bytes <= @max(body.max_window_bytes, 1) + engine.max_row_source_bytes + 4);
        if (body.hasMetadataProgress()) {
            _ = try body.commit(0);
            continue;
        }
        const n = body.releaseLimit(body.visibleRows().len);
        if (n == 0) {
            body.releasePin();
            if (final) return error.DrainDidNotFinish;
            return;
        }
        for (body.visibleRows()[0..n]) |row| {
            const copy = try a.dupe(u8, row.text);
            errdefer a.free(copy);
            try out.append(a, copy);
        }
        try std.testing.expectEqual(n, try body.commit(n));
    }
    return error.DrainDidNotFinish;
}

const Appearance = struct { fg: u16 = 256, bold: bool = false, dim: bool = false, italic: bool = false, underline: bool = false, strike: bool = false };
const GlyphByte = struct { byte: u8, style: Appearance };
fn appearance(a: Allocator, lines: []const []const u8) ![]GlyphByte {
    var result: std.ArrayList(GlyphByte) = .empty;
    errdefer result.deinit(a);
    var state: Appearance = .{};
    for (lines) |line| {
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == 27) {
                if (i + 2 >= line.len or line[i + 1] != '[') return error.InvalidSgr;
                const end = i + 2 + (std.mem.indexOfScalar(u8, line[i + 2 ..], 'm') orelse return error.InvalidSgr);
                var parts = std.mem.splitScalar(u8, line[i + 2 .. end], ';');
                while (parts.next()) |part| {
                    const n: u16 = if (part.len == 0) 0 else try std.fmt.parseInt(u16, part, 10);
                    switch (n) {
                        0 => state = .{},
                        1 => state.bold = true,
                        2 => state.dim = true,
                        3 => state.italic = true,
                        4 => state.underline = true,
                        9 => state.strike = true,
                        22 => {
                            state.bold = false;
                            state.dim = false;
                        },
                        23 => state.italic = false,
                        24 => state.underline = false,
                        29 => state.strike = false,
                        39 => state.fg = 256,
                        38 => {
                            const mode = parts.next() orelse return error.InvalidSgr;
                            if (!std.mem.eql(u8, mode, "5")) return error.InvalidSgr;
                            state.fg = try std.fmt.parseInt(u16, parts.next() orelse return error.InvalidSgr, 10);
                        },
                        else => return error.InvalidSgr,
                    }
                }
                i = end + 1;
            } else {
                try result.append(a, .{ .byte = line[i], .style = state });
                i += 1;
            }
        }
        try result.append(a, .{ .byte = '\n', .style = .{} });
    }
    return result.toOwnedSlice(a);
}
fn expectAppearance(a: Allocator, left: []const []const u8, right: []const []const u8) !void {
    const x = try appearance(a, left);
    defer a.free(x);
    const y = try appearance(a, right);
    defer a.free(y);
    try std.testing.expectEqual(x.len, y.len);
    for (x, y) |one, two| {
        try std.testing.expectEqual(one.byte, two.byte);
        try std.testing.expectEqualDeep(one.style, two.style);
    }
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
    const cases = [_][]const u8{ "abcd\n", "abcd", "**ab👩‍💻cdef**\n", "[abcd](url)\n", "**a `中👩‍💻**` z**\n", "x ``a`b``\n" };
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

fn progressOne(a: Allocator, body: *body_mod.Body, rows: *std.ArrayList([]const u8)) !void {
    try body.build();
    try std.testing.expect(body.stats.max_window_bytes <= @max(body.max_window_bytes, 1) + engine.max_row_source_bytes + 4);
    if (body.hasMetadataProgress()) {
        _ = try body.commit(0);
        return;
    }
    if (body.releaseLimit(1) == 0) {
        body.releasePin();
        return;
    }
    {
        const copy = try a.dupe(u8, body.visibleRows()[0].text);
        errdefer a.free(copy);
        try rows.append(a, copy);
    }
    try std.testing.expectEqual(@as(usize, 1), try body.commit(1));
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

fn allocationCase(a: Allocator) !void {
    const body = try body_mod.Body.create(a, 4);
    defer body.destroy();
    try body.append("abc\xf0\x9f");
    const before_end = body.acceptedSourceEnd();
    const before_carry = body.carry_len;
    body.append("\x91\xa9more") catch |err| {
        try std.testing.expectEqual(before_end, body.acceptedSourceEnd());
        try std.testing.expectEqual(before_carry, body.carry_len);
        return err;
    };
    try body.finish();
    var rows: std.ArrayList([]const u8) = .empty;
    defer freeRows(a, &rows);
    try progress(a, body, &rows, true);
    const rendered = try markdown.render(a, "**abc**\n", .{ .columns = 2, .max_lines = 10 });
    markdown.release(a, rendered);
}

test "allocation failures preserve decoder and release owned resources" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
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
