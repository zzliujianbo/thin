//! Static rendering through the same lightweight scanner as streaming bodies.
const std = @import("std");
const output = @import("markdown_writer.zig");
const engine = @import("whitelist_render.zig");
const Allocator = std.mem.Allocator;
pub const Tone = output.Tone;
pub const Options = struct { columns: usize, max_lines: ?usize, ansi: bool = true, markdown: bool = true, tone: Tone = .normal };
pub const Rendered = struct { lines: []const []const u8, total_lines: usize, truncated: bool };

pub fn release(a: Allocator, rendered: Rendered) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}

pub fn render(a: Allocator, input: []const u8, options: Options) !Rendered {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const clean = try @import("../util/display_text.zig").sanitizeAll(scratch, input);
    var lines: std.ArrayList([]const u8) = .empty;
    var clipped = false;
    if (options.markdown) {
        const result = try engine.renderAll(scratch, clean, options.columns, options.ansi, options.tone);
        for (result.rows) |row| try lines.append(scratch, row.text);
        clipped = clipped or result.consumed != clean.len;
    } else {
        var writer: output.Writer = .{ .a = scratch, .columns = std.math.clamp(options.columns, 1, 512), .ansi = options.ansi, .base = options.tone };
        try writer.emit(clean);
        if (writer.hasContent()) try writer.finish();
        try lines.appendSlice(scratch, writer.lines.items);
    }
    const total = lines.items.len;
    const start = if (options.max_lines) |max_lines| total - @min(total, max_lines) else 0;
    const result = try a.alloc([]const u8, total - start);
    var allocated: usize = 0;
    errdefer {
        for (result[0..allocated]) |line| a.free(line);
        a.free(result);
    }
    for (lines.items[start..], 0..) |line, i| {
        result[i] = try a.dupe(u8, line);
        allocated += 1;
    }
    return .{ .lines = result, .total_lines = total, .truncated = clipped };
}
