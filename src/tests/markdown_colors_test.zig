//! Check the active foreground AT each glyph, not just SGR presence somewhere.
//! This owned-output decoder is a test helper, not a terminal/protocol parser.
const std = @import("std");
const md = @import("../ui/markdown.zig");
const Color = union(enum) { normal, rgb: [3]u8, indexed: u8 };

fn nextNumber(fields: *std.mem.SplitIterator(u8, .scalar)) !u16 {
    const field = fields.next() orelse return error.InvalidSgr;
    return if (field.len == 0) 0 else std.fmt.parseInt(u16, field, 10);
}

fn at(bytes: []const u8, glyph: u8) !Color {
    var color: Color = .normal;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 27 and i + 1 < bytes.len and bytes[i + 1] == '[') {
            const end = i + 2 + (std.mem.indexOfScalar(u8, bytes[i + 2 ..], 'm') orelse return error.InvalidSgr);
            var fields = std.mem.splitScalar(u8, bytes[i + 2 .. end], ';');
            while (fields.next()) |field| {
                const v = if (field.len == 0) 0 else try std.fmt.parseInt(u16, field, 10);
                if (v == 0 or v == 39) color = .normal;
                if (v == 38) {
                    const mode = try nextNumber(&fields);
                    if (mode == 2) {
                        var rgb: [3]u8 = undefined;
                        for (&rgb) |*channel| channel.* = std.math.cast(u8, try nextNumber(&fields)) orelse return error.InvalidSgr;
                        color = .{ .rgb = rgb };
                    } else if (mode == 5) {
                        color = .{ .indexed = std.math.cast(u8, try nextNumber(&fields)) orelse return error.InvalidSgr };
                    } else return error.InvalidSgr;
                }
            }
            i = end + 1;
        } else {
            if (bytes[i] == glyph) return color;
            i += 1;
        }
    }
    return error.GlyphNotFound;
}

fn expectColor(bytes: []const u8, glyph: u8, expected: Color) !void {
    const actual = try at(bytes, glyph);
    try std.testing.expect(std.meta.activeTag(expected) == std.meta.activeTag(actual));
    switch (expected) {
        .normal => {},
        .rgb => |rgb| try std.testing.expectEqualSlices(u8, &rgb, &actual.rgb),
        .indexed => |value| try std.testing.expectEqual(value, actual.indexed),
    }
}

test "vivid Markdown semantic colors stay distinct and inline color never leaks into body" {
    try @import("../ui/text.zig").initLocale();
    const sample = "# H\n\nO **S** `I` A [K](https://example.org) B\n\n- L `J` C\n\n```\nG\n```\n\nD\n\n| `T` | U |\n|---|---|\n| V | `W` |\n\nE";
    for ([_]usize{ 8, 20, 80 }) |columns| {
        const r = try md.render(std.testing.allocator, sample, .{ .columns = columns, .max_lines = 100 });
        defer md.release(std.testing.allocator, r);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(std.testing.allocator);
        for (r.lines) |line| {
            try bytes.appendSlice(std.testing.allocator, line);
            try bytes.append(std.testing.allocator, '\n');
        }
        try expectColor(bytes.items, 'H', .{ .indexed = 220 });
        try expectColor(bytes.items, 'K', .{ .indexed = 12 });
        for ("IJTW") |glyph| try expectColor(bytes.items, glyph, .{ .indexed = 141 });
        try expectColor(bytes.items, 'G', .{ .indexed = 77 });
        // Strong is not a heading. Body, list prose and cells regain defaults.
        for ("OSABLCDEVU") |glyph| try expectColor(bytes.items, glyph, .normal);
        const following = try md.render(std.testing.allocator, "Z", .{ .columns = columns, .max_lines = 10 });
        defer md.release(std.testing.allocator, following);
        try expectColor(following.lines[0], 'Z', .normal);
    }
}
