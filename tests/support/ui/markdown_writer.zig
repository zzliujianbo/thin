fn expectRows(w: *const Writer) !void {
    for (w.lines.items) |line| try std.testing.expect(displayWidth(line) <= w.columns);
}

fn allocationScenario(a: Allocator) !void {
    var w: Writer = .{ .a = a, .columns = 4, .ansi = true, .prefix = "- ", .continuation = "  ", .base = .user };
    defer w.deinit();
    try w.emit("x❤");
    try w.setStyle(.{ .bold = true });
    try w.emit("️z\nnext");
    try w.finish();
}

const SinkProbe = struct {
    const Row = struct { bytes: []const u8, start: usize };
    a: Allocator,
    rows: std.ArrayList(Row) = .empty,

    fn onRow(context: *anyopaque, row: []const u8, src_start: usize, _: []const u8) Error!void {
        const self: *SinkProbe = @ptrCast(@alignCast(context));
        // Book-keeping first: on failure the writer still owns and frees `row`.
        try self.rows.append(self.a, .{ .bytes = row, .start = src_start });
    }

    fn sink(self: *SinkProbe) RowSink {
        return .{ .context = self, .onRow = onRow };
    }

    fn deinit(self: *SinkProbe) void {
        for (self.rows.items) |row| self.a.free(row.bytes);
        self.rows.deinit(self.a);
    }
};

const RejectProbe = struct {
    attempts: usize = 0,
    fn onRow(context: *anyopaque, _: []const u8, _: usize, _: []const u8) Error!void {
        const self: *RejectProbe = @ptrCast(@alignCast(context));
        self.attempts += 1;
        // Deliberately does NOT free: the writer owns a refused row.
        return error.MarkdownRenderLimit;
    }
};

const OriginProbe = struct {
    writer: *Writer,
    starts: [8]usize = undefined,
    ends: [8]usize = undefined,
    synthetic: [8]bool = undefined,
    count: usize = 0,
    fn onRow(context: *anyopaque, row: []const u8, _: usize, _: []const u8) Error!void {
        const self: *OriginProbe = @ptrCast(@alignCast(context));
        self.starts[self.count] = self.writer.origin_start;
        self.ends[self.count] = self.writer.origin_end;
        self.synthetic[self.count] = self.writer.origin_synthetic;
        self.count += 1;
        self.writer.a.free(row);
    }
};
