const std = @import("std");
const markdown = @import("../ui/markdown.zig");
const body_mod = @import("../ui/body_stream.zig");
const engine = @import("../ui/whitelist_render.zig");
const Allocator = std.mem.Allocator;

// Scalar oracle copied from the latest pre-batching renderer. This deliberately
// uses the current writer and scanner, but never calls the product renderer.
const ReferenceRender = struct {
    const scan = @import("../ui/whitelist.zig");
    const output = @import("../ui/markdown_writer.zig");
    const Sink = struct {
        a: Allocator,
        writer: *output.Writer,
        rows: std.ArrayList(engine.Row) = .empty,
        trace: std.ArrayList(engine.Checkpoint) = .empty,
        base: usize,
        seed: engine.Checkpoint,
        preview: bool = false,
        max_rows: ?usize,
        overflow: bool = false,
        fn onRow(ctx: *anyopaque, line: []const u8, _: usize, _: []const u8) output.Error!void {
            const self: *Sink = @ptrCast(@alignCast(ctx));
            if (self.max_rows) |max_rows| {
                if (self.rows.items.len >= max_rows) {
                    self.a.free(line);
                    self.overflow = true;
                    return;
                }
            }
            const end = self.writer.origin_end;
            var cp = self.seed;
            var covered: usize = 0;
            for (self.trace.items) |item| {
                if (item.end > end) break;
                cp = item;
                covered += 1;
            }
            const start = if (self.rows.items.len == 0) self.base else self.rows.items[self.rows.items.len - 1].end;
            try self.rows.append(self.a, .{ .text = line, .start = start, .end = cp.end, .checkpoint = cp.state, .complete = !self.preview });
            self.seed = cp;
            const remaining = self.trace.items.len - covered;
            std.mem.copyForwards(engine.Checkpoint, self.trace.items[0..remaining], self.trace.items[covered..]);
            self.trace.shrinkRetainingCapacity(remaining);
        }
    };

    fn render(a: Allocator, source: []const u8, base: usize, state: scan.State, final: bool, columns: usize, ansi: bool, tone: output.Tone, quantum: usize, max_rows: ?usize) !engine.Result {
        if (max_rows != null and max_rows.? == 0) return error.MarkdownRenderLimit;
        var budget: output.Budget = .{};
        var writer: output.Writer = .{ .a = a, .columns = std.math.clamp(columns, 1, 512), .ansi = ansi, .base = tone, .budget = if (max_rows != null) &budget else null };
        defer writer.deinit();
        var sink: Sink = .{ .a = a, .writer = &writer, .base = base, .seed = .{ .end = base, .state = state }, .max_rows = max_rows };
        defer sink.trace.deinit(a);
        errdefer {
            for (sink.rows.items) |row| a.free(row.text);
            sink.rows.deinit(a);
        }
        writer.sink = .{ .context = &sink, .onRow = Sink.onRow };
        var offset: usize = 0;
        var current = state;
        var stopped = false;
        while (offset < source.len) {
            if ((if (max_rows) |n| sink.rows.items.len >= n else false) or (max_rows != null and offset >= @max(quantum, 1) and sink.rows.items.len != 0)) break;
            if (max_rows != null and base + offset - sink.seed.end > engine.max_row_source_bytes) return error.MarkdownRenderLimit;
            switch (scan.next(source, base, offset, current, final)) {
                .need_more => {
                    stopped = true;
                    break;
                },
                .end => break,
                .token => |token| {
                    if (token.end <= base + offset or token.end > base + source.len) return error.MarkdownRenderLimit;
                    try sink.trace.append(a, .{ .end = token.end, .state = token.after });
                    current = token.after;
                    offset = token.end - base;
                    if (token.text.len != 0) {
                        if (!std.meta.eql(writer.style, token.style)) try writer.setStyle(token.style);
                        try writer.emitSourced(token.text, token.start, token.end, token.exact);
                        if (max_rows != null and writer.cluster != null and !writer.pending_origin_synthetic and
                            writer.pending_origin_end - writer.pending_origin_start > engine.max_cluster_source_bytes)
                            return error.MarkdownRenderLimit;
                    }
                    if (max_rows != null and base + offset - sink.seed.end > engine.max_row_source_bytes) return error.MarkdownRenderLimit;
                },
            }
        }
        const work = offset;
        const eof = final and !stopped and offset == source.len;
        const full = if (max_rows) |n| sink.rows.items.len >= n else false;
        if (writer.hasContent() and !full) {
            sink.preview = !eof;
            try writer.finish();
        } else if (full and (sink.overflow or writer.hasContent() or !eof)) {
            offset = sink.seed.end - base;
        }
        var metadata: ?engine.Checkpoint = null;
        if (sink.rows.items.len == 0 and offset != 0 and eof) metadata = .{ .end = base + offset, .state = current };
        return .{ .rows = try sink.rows.toOwnedSlice(a), .consumed = offset, .work = work, .metadata = metadata };
    }
};

fn asciiAllocationCase(a: Allocator) !void {
    const result = try engine.render(a, "alpha beta gamma delta 12345", 31, .{}, true, 80, true, .normal, 4096, 2);
    defer {
        for (result.rows) |row| a.free(row.text);
        a.free(result.rows);
    }
}

fn asciiSweepAllocationCase(bound: usize, fixed: bool) !bool {
    var grew_before_oom = false;
    for (0..bound) |fail_index| {
        var storage: [256 * 1024]u8 = undefined;
        var buffer = std.heap.FixedBufferAllocator.init(&storage);
        const backing = if (fixed) buffer.allocator() else std.testing.allocator;
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        var observer: GrowthObserver = .{ .failing = &failing };
        if (asciiAllocationCase(observer.allocator())) |_| {
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
    try body.build();
    body.abort();
    try body.build();
    body.abort();
    try body.build();
    body.releasePin();
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
