//! Shared bounded scanner-to-terminal writer bridge.
const std = @import("std");
const scan = @import("whitelist.zig");
const output = @import("markdown_writer.zig");

pub const max_cluster_source_bytes: usize = 4096;
pub const max_row_source_bytes: usize = 64 * 1024;
pub const Checkpoint = struct { end: usize, state: scan.State };
pub const Row = struct {
    text: []const u8,
    start: usize,
    end: usize,
    checkpoint: scan.State,
    complete: bool,
};
pub const Result = struct {
    rows: []Row,
    consumed: usize,
    work: usize,
    metadata: ?Checkpoint,
};
const Sink = struct {
    a: std.mem.Allocator,
    writer: *output.Writer,
    rows: std.ArrayList(Row) = .empty,
    trace: std.ArrayList(Checkpoint) = .empty,
    base: usize,
    seed: Checkpoint,
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
        std.mem.copyForwards(Checkpoint, self.trace.items[0..remaining], self.trace.items[covered..]);
        self.trace.shrinkRetainingCapacity(remaining);
    }
};

/// `source` is the entire retained window, including lookahead beyond quantum.
pub fn render(a: std.mem.Allocator, source: []const u8, base: usize, state: scan.State, final: bool, columns: usize, ansi: bool, tone: output.Tone, quantum: usize, max_rows: usize) !Result {
    if (max_rows == 0) return error.MarkdownRenderLimit;
    return renderImpl(a, source, base, state, final, columns, ansi, tone, quantum, max_rows);
}

/// Complete static rendering uses the same scanner without streaming budgets.
pub fn renderAll(a: std.mem.Allocator, source: []const u8, columns: usize, ansi: bool, tone: output.Tone) !Result {
    return renderImpl(a, source, 0, .{}, true, columns, ansi, tone, source.len, null);
}

fn plain(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == ' ';
}

fn renderImpl(a: std.mem.Allocator, source: []const u8, base: usize, state: scan.State, final: bool, columns: usize, ansi: bool, tone: output.Tone, quantum: usize, max_rows: ?usize) !Result {
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
        // Work quantum is a yield point, not a hard source cap. Finish one
        // physical row first; enforce a bounded pathological-row policy below.
        if ((if (max_rows) |n| sink.rows.items.len >= n else false) or (max_rows != null and offset >= @max(quantum, 1) and sink.rows.items.len != 0)) break;
        if (max_rows != null and base + offset - sink.seed.end > max_row_source_bytes) return error.MarkdownRenderLimit;
        const pending_ok = if (writer.cluster) |cluster|
            writer.pending.items.len == 1 and plain(writer.pending.items[0]) and cluster.width == 1 and !cluster.awaitZWJ
        else
            true;
        if (!current.at_line_start and current.fence == 0 and current.depth == 0 and !current.heading and !current.quote and !current.escaped and current.literal_until == 0 and pending_ok) {
            const pending_width: usize = if (writer.cluster != null) 1 else 0;
            // Stay within one physical row so no row callback observes future checkpoints.
            var cap = @min(source.len - offset, writer.columns -| writer.col -| pending_width);
            if (max_rows != null and sink.rows.items.len != 0) cap = @min(cap, @max(quantum, 1) -| offset);
            if (max_rows != null) cap = @min(cap, max_row_source_bytes -| (base + offset - sink.seed.end));
            var n: usize = 0;
            while (n < cap and plain(source[offset + n])) : (n += 1) {}
            if (n >= 2) {
                // Retain the scalar path's source proof at every byte boundary.
                for (1..n + 1) |i| try sink.trace.append(a, .{ .end = base + offset + i, .state = current });
                if (!std.meta.eql(writer.style, output.Style{})) try writer.setStyle(.{});
                try writer.emitSourced(source[offset .. offset + n], base + offset, base + offset + n, true);
                offset += n;
                continue;
            }
        }
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
                        writer.pending_origin_end - writer.pending_origin_start > max_cluster_source_bytes)
                        return error.MarkdownRenderLimit;
                }
                if (max_rows != null and base + offset - sink.seed.end > max_row_source_bytes) return error.MarkdownRenderLimit;
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
        // The staged next cluster belongs to the next build, never this frame.
        offset = sink.seed.end - base;
    }
    var metadata: ?Checkpoint = null;
    if (sink.rows.items.len == 0 and offset != 0 and eof) metadata = .{ .end = base + offset, .state = current };
    return .{ .rows = try sink.rows.toOwnedSlice(a), .consumed = offset, .work = work, .metadata = metadata };
}
