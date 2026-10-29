//! Static rendering through the same lightweight scanner as streaming bodies.
const std = @import("std");
const text = @import("text.zig");
const output = @import("markdown_writer.zig");
const engine = @import("whitelist_render.zig");
const scanner = @import("whitelist.zig");
const Allocator = std.mem.Allocator;
pub const Tone = output.Tone;
pub const Options = struct { columns: usize, max_lines: usize, ansi: bool = true, markdown: bool = true, tone: Tone = .normal };
pub const Rendered = struct { lines: []const []const u8, total_lines: usize, truncated: bool, degraded: bool = false };
const limit = 256 * 1024;

pub fn release(a: Allocator, rendered: Rendered) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}

pub fn render(a: Allocator, input: []const u8, options: Options) !Rendered {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const clean = try text.sanitize(scratch, input, limit);
    var lines: std.ArrayList([]const u8) = .empty;
    var clipped = text.exceedsSanitizedLimit(input, limit);
    if (options.markdown) {
        const result = engine.render(scratch, clean, 0, scanner.State{}, true, options.columns, options.ansi, options.tone, limit + 1, 256 * 1024 + 64) catch |err| {
            if (err == error.OutOfMemory) return err;
            return .{ .lines = try a.alloc([]const u8, 0), .total_lines = 0, .truncated = true, .degraded = true };
        };
        for (result.rows) |row| try lines.append(scratch, row.text);
        clipped = clipped or result.consumed != clean.len;
    } else {
        var budget: output.Budget = .{};
        var writer: output.Writer = .{ .a = scratch, .columns = std.math.clamp(options.columns, 1, 512), .ansi = options.ansi, .base = options.tone, .budget = &budget };
        writer.emit(clean) catch |err| {
            if (err == error.OutOfMemory) return err;
            clipped = true;
        };
        if (writer.hasContent()) writer.finish() catch |err| {
            if (err == error.OutOfMemory) return err;
            clipped = true;
        };
        try lines.appendSlice(scratch, writer.lines.items);
    }
    const total = lines.items.len;
    const start = total - @min(total, @min(options.max_lines, 8192));
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
