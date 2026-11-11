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

fn allocationCase(a: Allocator) !void {
    const body = try body_mod.Body.create(a, 4);
    defer body.destroy();
    try body.append("abc\xf0\x9f");
    const before_end = body.acceptedSourceEnd();
    const before_carry = body.decoder.carry_len;
    const before_cr = body.decoder.held_cr;
    body.append("\x91\xa9more") catch |err| {
        try std.testing.expectEqual(before_end, body.acceptedSourceEnd());
        try std.testing.expectEqual(before_carry, body.decoder.carry_len);
        try std.testing.expectEqual(before_cr, body.decoder.held_cr);
        try std.testing.expectEqualSlices(u8, "\xf0\x9f", body.decoder.carry[0..body.decoder.carry_len]);
        try std.testing.expectEqualStrings("abc", body.source.items);
        try std.testing.expect(!body.finished);
        return err;
    };
    try body.finish();
    var rows: std.ArrayList([]const u8) = .empty;
    defer freeRows(a, &rows);
    try progress(a, body, &rows, true);
    const rendered = try markdown.render(a, "**abc**\n", .{ .columns = 2, .max_lines = 10 });
    markdown.release(a, rendered);
}

fn appendHeldCrAllocationCase(a: Allocator) !void {
    const body = try body_mod.Body.create(a, 4);
    defer body.destroy();
    try body.append("abcdefgh\r");
    const before_end = body.acceptedSourceEnd();
    body.append("\nmore") catch |err| {
        try std.testing.expectEqual(before_end, body.acceptedSourceEnd());
        try std.testing.expect(body.decoder.held_cr);
        try std.testing.expectEqual(@as(usize, 0), body.decoder.carry_len);
        try std.testing.expectEqualStrings("abcdefgh", body.source.items);
        try std.testing.expect(!body.finished);
        return err;
    };
    try std.testing.expect(!body.decoder.held_cr);
    try std.testing.expectEqualStrings("abcdefgh\nmore", body.source.items);
}

fn finishAllocationCase(a: Allocator, suffix: []const u8, expected: []const u8) !void {
    const body = try body_mod.Body.create(a, 4);
    defer body.destroy();
    try body.append("abcdefgh");
    try body.append(suffix);
    const before_end = body.acceptedSourceEnd();
    const before_carry = body.decoder.carry_len;
    const before_cr = body.decoder.held_cr;
    body.finish() catch |err| {
        try std.testing.expectEqual(before_end, body.acceptedSourceEnd());
        try std.testing.expectEqual(before_carry, body.decoder.carry_len);
        try std.testing.expectEqual(before_cr, body.decoder.held_cr);
        try std.testing.expectEqualSlices(u8, if (before_cr) "" else suffix, body.decoder.carry[0..body.decoder.carry_len]);
        try std.testing.expectEqualStrings("abcdefgh", body.source.items);
        try std.testing.expect(!body.finished);
        return err;
    };
    try std.testing.expect(body.finished);
    try std.testing.expect(!body.decoder.held_cr);
    try std.testing.expectEqual(@as(usize, 0), body.decoder.carry_len);
    try std.testing.expectEqualStrings(expected, body.source.items);
}
