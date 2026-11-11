const text = @import("text.zig");

const display = @import("../util/display_text.zig");

const testing = std.testing;

fn plainRows(a: Allocator, columns: usize, body: []const u8, out: *std.ArrayList([]u8)) !void {
    const clean = try display.sanitize(a, body, 1 << 20);
    defer a.free(clean);
    var w: Writer = .{ .a = a, .columns = clampColumns(columns), .ansi = true, .base = .thinking };
    defer w.deinit();
    try w.emit(clean);
    try w.finish();
    for (w.lines.items) |row| try out.append(a, try a.dupe(u8, row));
}

fn expectTail(tail: *Tail, columns: usize, body: []const u8) !void {
    const a = testing.allocator;
    var want: std.ArrayList([]u8) = .empty;
    defer {
        for (want.items) |row| a.free(row);
        want.deinit(a);
    }
    try plainRows(a, columns, body, &want);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    const count = @min(tail.keepRows(), want.items.len);
    try testing.expectEqual(count, snap.rows.len);
    const expected = want.items[want.items.len - count ..];
    for (expected, snap.rows) |e, got| try testing.expectEqualStrings(e, got);
}

const StartProbe = struct {
    a: Allocator,
    starts: std.ArrayList(usize) = .empty,

    fn onRow(context: *anyopaque, row: []const u8, src_start: usize, _: []const u8) output.Error!void {
        const self: *StartProbe = @ptrCast(@alignCast(context));
        // On failure the Writer still owns `row` and frees it.
        try self.starts.append(self.a, src_start);
        self.a.free(row);
    }

    fn sink(self: *StartProbe) output.RowSink {
        return .{ .context = self, .onRow = onRow };
    }

    fn deinit(self: *StartProbe) void {
        self.starts.deinit(self.a);
    }
};
