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
    synthetic: bool = false,
    leaf: usize = 0,
    output_start: usize = 0,
    output_end: usize = 0,
    output_window: usize = 0,
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
    max_rows: usize,
    overflow: bool = false,
    fn onRow(ctx: *anyopaque, line: []const u8, _: usize, _: []const u8) output.Error!void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        if (self.rows.items.len >= self.max_rows) {
            self.a.free(line);
            self.overflow = true;
            return;
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
    var budget: output.Budget = .{};
    var writer: output.Writer = .{ .a = a, .columns = std.math.clamp(columns, 1, 512), .ansi = ansi, .base = tone, .budget = &budget };
    defer writer.deinit();
    if (max_rows == 0) return error.MarkdownRenderLimit;
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
        if (sink.rows.items.len >= max_rows or (offset >= @max(quantum, 1) and sink.rows.items.len != 0)) break;
        if (base + offset - sink.seed.end > max_row_source_bytes) return error.MarkdownRenderLimit;
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
                    if (writer.cluster != null and !writer.pending_origin_synthetic and
                        writer.pending_origin_end - writer.pending_origin_start > max_cluster_source_bytes)
                        return error.MarkdownRenderLimit;
                }
                if (base + offset - sink.seed.end > max_row_source_bytes) return error.MarkdownRenderLimit;
            },
        }
    }
    const work = offset;
    const eof = final and !stopped and offset == source.len;
    if (writer.hasContent() and sink.rows.items.len < max_rows) {
        sink.preview = !eof;
        try writer.finish();
    } else if (sink.rows.items.len >= max_rows and (sink.overflow or writer.hasContent() or !eof)) {
        // The staged next cluster belongs to the next build, never this frame.
        offset = sink.seed.end - base;
    }
    var metadata: ?Checkpoint = null;
    if (sink.rows.items.len == 0 and offset != 0 and eof) metadata = .{ .end = base + offset, .state = current };
    return .{ .rows = try sink.rows.toOwnedSlice(a), .consumed = offset, .work = work, .metadata = metadata };
}
