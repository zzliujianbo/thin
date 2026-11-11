const suffix = "\r\x1b[3C\x1b[?25h";

const stable = "\x1b[0m\x1b[2Kstable table\x1b[0m";

const footer_a = "\x1b[0m\x1b[2Kfooter A\x1b[0m";

const footer_b = "\x1b[0m\x1b[2Kfooter B\x1b[0m";

fn fixture(a: std.mem.Allocator, rows: []const []const u8) !Snapshot {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (rows, 0..) |row, i| {
        if (i != 0) try out.writer.writeAll("\r\n");
        try out.writer.writeAll(row);
    }
    const offset = out.written().len;
    try out.writer.writeAll(suffix);
    return (try Snapshot.capture(a, out.written(), rows.len, offset)).?;
}

fn expectDiff(old_rows: []const []const u8, new_rows: []const []const u8, expected: []const u8) !void {
    var old = try fixture(std.testing.allocator, old_rows);
    defer old.deinit();
    var new = try fixture(std.testing.allocator, new_rows);
    defer new.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitDiff(&out.writer, &old);
    try std.testing.expectEqualStrings(expected, out.written());
}

fn allocationScenario(a: std.mem.Allocator) !void {
    // Enough bytes that allocating the row descriptors also exercises arena growth.
    var raw: [16384]u8 = @splat('x');
    for (0..199) |i| {
        raw[i * 2] = '\r';
        raw[i * 2 + 1] = '\n';
    }
    var snap = (try Snapshot.capture(a, &raw, 200, raw.len)).?;
    defer snap.deinit();
    try std.testing.expectEqual(@as(usize, 200), snap.rows.len);
    try std.testing.expectEqualStrings(&raw, snap.full);
}

fn expectGrowing(old_rows: []const []const u8, new_rows: []const []const u8, prefix: []const []const u8, expected: []const u8) !void {
    var old = try fixture(std.testing.allocator, old_rows);
    defer old.deinit();
    var new = try fixture(std.testing.allocator, new_rows);
    defer new.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitGrowingDiff(&out.writer, &old, prefix);
    try std.testing.expectEqualStrings(expected, out.written());
}

fn menuHistoryAllocationScenario(a: std.mem.Allocator) !void {
    var raw = "committed row".*;
    var history = try MenuHistory.capture(a, &.{&raw}, &.{stable});
    defer history.deinit();
    @memset(&raw, 'x');
    try std.testing.expectEqualStrings("committed row", history.above[0]);
    try std.testing.expectEqualStrings(stable, history.borrowed[0]);
}
