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

// Observe actual successful growth, not attempted resizes or shrinking.
const GrowthObserver = struct {
    failing: *std.testing.FailingAllocator,
    grew: bool = false,

    fn allocator(self: *GrowthObserver) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *GrowthObserver = @ptrCast(@alignCast(ctx));
        return self.failing.allocator().rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *GrowthObserver = @ptrCast(@alignCast(ctx));
        if (!self.failing.allocator().rawResize(bytes, alignment, len, ra)) return false;
        if (len > bytes.len and !self.failing.has_induced_failure) self.grew = true;
        return true;
    }
    fn remap(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *GrowthObserver = @ptrCast(@alignCast(ctx));
        const result = self.failing.allocator().rawRemap(bytes, alignment, len, ra) orelse return null;
        if (len > bytes.len and !self.failing.has_induced_failure) self.grew = true;
        return result;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *GrowthObserver = @ptrCast(@alignCast(ctx));
        self.failing.allocator().rawFree(bytes, alignment, ra);
    }
};

fn sweepNormalAllocationCase(bound: usize, fixed: bool) !bool {
    var grew_before_oom = false;
    for (0..bound) |fail_index| {
        // Reset the controlled layout for every attempt; the other sweep uses
        // the ordinary testing allocator and makes no layout assumptions.
        var storage: [256 * 1024]u8 = undefined;
        var buffer = std.heap.FixedBufferAllocator.init(&storage);
        const backing = if (fixed) buffer.allocator() else std.testing.allocator;
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        var observer: GrowthObserver = .{ .failing = &failing };
        if (allocationCase(observer.allocator())) |_| {
            try std.testing.expect(!failing.has_induced_failure);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            if (observer.grew) grew_before_oom = true;
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    return grew_before_oom;
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
