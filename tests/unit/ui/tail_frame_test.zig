test "capture owns full bytes, rows and suffix independently of mutable input" {
    var raw = (stable ++ "\r\n" ++ footer_a ++ suffix).*;
    var snap = (try Snapshot.capture(std.testing.allocator, &raw, 2, raw.len - suffix.len)).?;
    defer snap.deinit();
    @memset(&raw, 'x');
    try std.testing.expectEqualStrings(stable, snap.rows[0]);
    try std.testing.expectEqualStrings(footer_a, snap.rows[1]);
    try std.testing.expectEqualStrings(suffix, snap.cursor_suffix);
    try std.testing.expectEqualStrings(stable ++ "\r\n" ++ footer_a ++ suffix, snap.full);
}
test "identical rows emit navigation and cursor only, no EL or payload" {
    try expectDiff(&.{ stable, stable, footer_a }, &.{ stable, stable, footer_a }, "\x1b[2B" ++ suffix);
    try expectDiff(&.{stable}, &.{stable}, suffix);
}
test "cursor-only movement leaves identical styled rows untouched" {
    var old = try fixture(std.testing.allocator, &.{ stable, footer_a });
    defer old.deinit();
    const moved_suffix = "\r\x1b[1C\x1b[?25h";
    const raw = stable ++ "\r\n" ++ footer_a ++ moved_suffix;
    var new = (try Snapshot.capture(std.testing.allocator, raw, 2, raw.len - moved_suffix.len)).?;
    defer new.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitDiff(&out.writer, &old);
    try std.testing.expectEqualStrings("\x1b[1B" ++ moved_suffix, out.written());
}
test "footer-only diff writes one EL and no stable table text" {
    try expectDiff(&.{ stable, stable, footer_a }, &.{ stable, stable, footer_b }, "\r\x1b[2B" ++ footer_b ++ suffix);
}
test "style-only and shorter changes replace exact complete styled row" {
    const red = "\x1b[0m\x1b[2K\x1b[31mlong text\x1b[0m";
    const blue = "\x1b[0m\x1b[2K\x1b[34mlong text\x1b[0m";
    const short = "\x1b[0m\x1b[2Kx\x1b[0m";
    try expectDiff(&.{red}, &.{blue}, "\r" ++ blue ++ suffix);
    try expectDiff(&.{blue}, &.{short}, "\r" ++ short ++ suffix);
}
test "monotonic relative navigation has no CRLF, CUP, ED or scrolling" {
    try expectDiff(&.{ footer_a, stable, footer_a, stable, stable }, &.{ footer_b, stable, footer_b, stable, stable }, "\r" ++ footer_b ++ "\r\x1b[2B" ++ footer_b ++ "\x1b[2B" ++ suffix);
    try expectDiff(&.{ stable, footer_a, stable, footer_a }, &.{ stable, footer_b, stable, footer_b }, "\r\x1b[1B" ++ footer_b ++ "\r\x1b[2B" ++ footer_b ++ suffix);
}
test "capture rejects mismatched count and invalid cursor offset" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidTailFrame, Snapshot.capture(a, "a\r\nb", 1, 4));
    try std.testing.expectError(error.InvalidTailFrame, Snapshot.capture(a, "a", 2, 1));
    try std.testing.expectError(error.InvalidTailFrame, Snapshot.capture(a, "a", 1, 2));
}
test "capture bounds return null without allocation; exact bounds accepted" {
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect((try Snapshot.capture(fail.allocator(), "", 0, 0)) == null);
    try std.testing.expect((try Snapshot.capture(fail.allocator(), "", 201, 0)) == null);
    const raw = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(raw);
    @memset(raw, 'x');
    try std.testing.expect((try Snapshot.capture(fail.allocator(), raw, 1, raw.len)) == null);
    var snap = (try Snapshot.capture(std.testing.allocator, raw[0..max_bytes], 1, max_bytes)).?;
    defer snap.deinit();
    try std.testing.expectEqual(max_bytes, snap.full.len);
    var rows: [max_rows][]const u8 = @splat(stable);
    var bounded = try fixture(std.testing.allocator, &rows);
    defer bounded.deinit();
    try std.testing.expectEqual(max_rows, bounded.rows.len);
}
test "diff rejects unequal or out of bounds heights before writing" {
    var one = try fixture(std.testing.allocator, &.{stable});
    defer one.deinit();
    var two = try fixture(std.testing.allocator, &.{ stable, stable });
    defer two.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidTailFrame, one.emitDiff(&out.writer, &two));
    const saved = one.rows;
    one.rows = &.{};
    try std.testing.expectError(error.InvalidTailFrame, one.emitDiff(&out.writer, &one));
    var excessive: [201][]const u8 = @splat("");
    one.rows = &excessive;
    try std.testing.expectError(error.InvalidTailFrame, one.emitDiff(&out.writer, &one));
    one.rows = saved;
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}
test "small upward shifts reuse exact rows and repair footer without adding history" {
    const Screen = @import("../tests/regular_screen.zig").Screen;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body: [17][]const u8 = undefined;
    for (&body, 0..) |*row, index|
        row.* = try std.fmt.allocPrint(a, "\x1b[0mrow-{d:0>2} abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz\x1b[0m\x1b[K", .{index});
    body[4] = "\x1b[0m\x1b[K";
    body[8] = body[7]; // Identical duplicates must not confuse the shift.
    body[11] = "\x1b[0m\x1b[31mstyled duplicate\x1b[0m\x1b[K";
    body[12] = "\x1b[0m\x1b[34mstyled duplicate\x1b[0m\x1b[K";
    for ([_]usize{ 1, 2, 4 }) |count| {
        var old_rows: [18][]const u8 = undefined;
        var next_rows: [18][]const u8 = undefined;
        old_rows[0] = stable;
        old_rows[1] = stable;
        next_rows[0] = stable;
        next_rows[1] = stable;
        for (0..13) |index| {
            old_rows[index + 2] = body[index];
            next_rows[index + 2] = body[index + count];
        }
        for (15..18) |index| {
            old_rows[index] = footer_a;
            next_rows[index] = footer_b;
        }
        var old = try fixture(std.testing.allocator, &old_rows);
        defer old.deinit();
        var next = try fixture(std.testing.allocator, &next_rows);
        defer next.deinit();
        const shift = next.chooseShift(&old).?;
        try std.testing.expectEqual(count, shift.count);
        var ordinary: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer ordinary.deinit();
        var reused: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer reused.deinit();
        try next.emitDiff(&ordinary.writer, &old);
        try next.emitBottomDiff(&reused.writer, &old);
        try std.testing.expectEqual(next.diffCost(&old, shift, std.math.maxInt(usize)) + suffix.len, reused.written().len);
        try std.testing.expect(reused.written().len < ordinary.written().len);
        if (count == 1) try std.testing.expect(reused.written().len * 2 < ordinary.written().len);
        try std.testing.expect(std.mem.find(u8, reused.written(), "\n") == null);
        var expected: Screen = .{};
        try expected.replay("prior\r\nabove1\r\nabove2\r\nabove3\r\nabove4\r\nabove5\r\n");
        try expected.replay(old.full);
        try expected.replay("\r\x1b[17A");
        var actual = expected;
        try expected.replay(ordinary.written());
        try actual.replay(reused.written());
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.grid), std.mem.asBytes(&actual.grid));
        try std.testing.expectEqual(expected.row, actual.row);
        try std.testing.expectEqual(expected.col, actual.col);
        try std.testing.expectEqual(@as(usize, 0), actual.history_len);
        try std.testing.expectEqual(@as(usize, 1), actual.count("prior"));
        try std.testing.expect(actual.visible("above5"));
    }
}
test "non shifts and unprofitable shifts keep the ordinary row diff" {
    const Case = struct { old: []const []const u8, next: []const []const u8 };
    for ([_]Case{
        .{ .old = &.{ "a", "b" }, .next = &.{ "b", "c" } },
        .{ .old = &.{ stable, footer_a }, .next = &.{ stable, footer_b } },
        .{ .old = &.{ stable, stable }, .next = &.{ stable, stable } },
    }) |case| {
        var old = try fixture(std.testing.allocator, case.old);
        defer old.deinit();
        var next = try fixture(std.testing.allocator, case.next);
        defer next.deinit();
        try std.testing.expect(next.chooseShift(&old) == null);
        var ordinary: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer ordinary.deinit();
        var reused: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer reused.deinit();
        try next.emitDiff(&ordinary.writer, &old);
        try next.emitBottomDiff(&reused.writer, &old);
        try std.testing.expectEqualStrings(ordinary.written(), reused.written());
    }
}
test "growing diff preserves old rows and uses exactly one CRLF per added row" {
    try expectGrowing(&.{ stable, footer_a }, &.{ stable, footer_a, footer_b, stable }, &.{}, "\r\x1b[1B\r\n" ++ footer_b ++ "\r\n" ++ stable ++ suffix);
    try expectGrowing(&.{stable}, &.{ stable, footer_a }, &.{}, "\r\n" ++ footer_a ++ suffix);
    try expectGrowing(&.{ stable, footer_a, stable }, &.{ footer_b, footer_a, stable, footer_b }, &.{}, "\r" ++ footer_b ++ "\r\x1b[2B\r\n" ++ footer_b ++ suffix);
}
test "growing diff shorter tail and prefixes compare original logical indices" {
    try expectGrowing(&.{ stable, footer_a, footer_b }, &.{footer_b}, &.{ stable, footer_a }, "\r\x1b[2B" ++ suffix);
    try expectGrowing(&.{ stable, footer_a, footer_b }, &.{stable}, &.{ stable, footer_b }, "\r\x1b[1B" ++ footer_b ++ "\r\x1b[1B" ++ stable ++ suffix);
    try expectGrowing(&.{ stable, footer_a, footer_b }, &.{stable}, &.{ stable, footer_a, footer_b }, "\r\x1b[2B\r\n" ++ stable ++ suffix);
}
test "growing diff style equality and current cursor suffix are exact" {
    try expectGrowing(&.{"\x1b[31mx"}, &.{"\x1b[34mx"}, &.{}, "\r\x1b[34mx" ++ suffix);
    var old = try fixture(std.testing.allocator, &.{stable});
    defer old.deinit();
    var new = try fixture(std.testing.allocator, &.{stable});
    defer new.deinit();
    new.cursor_suffix = "\r\x1b[7C";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitGrowingDiff(&out.writer, &old, &.{});
    try std.testing.expectEqualStrings(new.cursor_suffix, out.written());
}
test "growing diff rejects all invalid dimensions and byte sizes before output" {
    var old = try fixture(std.testing.allocator, &.{ stable, footer_a });
    defer old.deinit();
    var new = try fixture(std.testing.allocator, &.{stable});
    defer new.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{}));
    var prefixes: [8192][]const u8 = @splat("");
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &prefixes));
    const saved = new.rows;
    new.rows = &.{};
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    var too_many: [201][]const u8 = @splat("");
    new.rows = &too_many;
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{}));
    new.rows = saved;
    const old_saved = old.rows;
    old.rows = &.{};
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    old.rows = &too_many;
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    old.rows = old_saved;
    const large = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024 + 1);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{large}));
    new.cursor_suffix = large;
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    new.cursor_suffix = suffix;
    old.rows = &.{ large, stable };
    try std.testing.expectError(error.InvalidTailFrame, new.emitGrowingDiff(&out.writer, &old, &.{stable}));
    old.rows = old_saved;
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}
test "growing diff accepts exact combined row bound" {
    var old = try fixture(std.testing.allocator, &.{""});
    defer old.deinit();
    var new = try fixture(std.testing.allocator, &.{""});
    defer new.deinit();
    var prefixes: [8191][]const u8 = @splat("");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try new.emitGrowingDiff(&out.writer, &old, &prefixes);
    try std.testing.expectEqual(8191 * 2 + suffix.len, out.written().len);
    for (0..8191) |i| try std.testing.expectEqualStrings("\r\n", out.written()[i * 2 ..][0..2]);
    try std.testing.expectEqualStrings(suffix, out.written()[8191 * 2 ..]);
}
test "floating contraction erases only the vacated owned rows and restores the cursor" {
    const Screen = @import("../tests/regular_screen.zig").Screen;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emitVacatedRows(&out.writer, 0);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try emitVacatedRows(&out.writer, 2);
    try std.testing.expectEqualStrings("\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[2A", out.written());
    // Descent never uses LF or DL: neither can scroll or shift foreign rows.
    try std.testing.expect(std.mem.indexOfScalar(u8, out.written(), '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[M") == null);

    // Prior shell output, a floating tail whose popup row is returned, and a
    // foreign row below the owned footprint that must never be erased.
    var screen: Screen = .{};
    try screen.replay("shell-prior\r\nabove-1\r\nold-tail-1\r\nold-tail-2\r\npopup-1\r\npopup-2\r\nforeign-row");
    try std.testing.expectEqual(@as(usize, 6), screen.row);
    // Entry is the ACKed tail top (row 2) after the composer row (row 5).
    try screen.replay("\r\x1b[1A\r\x1b[3A");
    try screen.replay("\rnew-tail-1\r\nnew-tail-2\r\nnew-tail-3");
    var contract: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer contract.deinit();
    try emitVacatedRows(&contract.writer, 1);
    try std.testing.expectEqualStrings("\r\x1b[1B\x1b[0K\r\x1b[1A", contract.written());
    try screen.replay(contract.written());
    try std.testing.expectEqual(@as(usize, 0), screen.history_len);
    try std.testing.expectEqual(@as(usize, 4), screen.row);
    try std.testing.expectEqual(@as(usize, 0), screen.col);
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[0], "shell-prior"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[1], "above-1"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[2], "new-tail-1"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[3], "new-tail-2"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[4], "new-tail-3"));
    // Exactly the vacated owned row is blank; rows below it are untouched.
    try std.testing.expectEqualStrings("", std.mem.trim(u8, &screen.grid[5], " "));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[6], "foreign-row"));
}
test "floating contraction erases every vacated owned row and keeps the foreign row below" {
    const Screen = @import("../tests/regular_screen.zig").Screen;
    // Prior shell output, an eight-row ACKed tail, then a distinct foreign
    // sentinel immediately below the owned footprint.
    var screen: Screen = .{};
    try screen.replay("shell-prior\r\nabove-1\r\nold-tail-1\r\nold-tail-2\r\nold-tail-3\r\nold-tail-4\r\nold-tail-5\r\nold-tail-6\r\nold-tail-7\r\nold-tail-8\r\nforeign-sentinel");
    try std.testing.expectEqual(@as(usize, 10), screen.row);
    const history_before = screen.history_len;
    // Entry: the tail top (row 2), as if the cursor sat on the old last row.
    try screen.replay("\r\x1b[8A");
    try screen.replay("\rnew-tail-1\r\nnew-tail-2\r\nnew-tail-3");
    try std.testing.expectEqual(@as(usize, 4), screen.row);
    var contract: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer contract.deinit();
    try emitVacatedRows(&contract.writer, 5);
    try std.testing.expectEqualStrings(
        "\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[1B\x1b[0K\r\x1b[5A",
        contract.written(),
    );
    try screen.replay(contract.written());
    // Constant CR+CUD1 per row cannot overshoot into or erase the foreign row,
    // and CUU(5) lands back on the original last new row.
    try std.testing.expectEqual(history_before, screen.history_len);
    try std.testing.expectEqual(@as(usize, 4), screen.row);
    try std.testing.expectEqual(@as(usize, 0), screen.col);
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[0], "shell-prior"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[1], "above-1"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[2], "new-tail-1"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[3], "new-tail-2"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[4], "new-tail-3"));
    // Every vacated owned row is blank; the foreign sentinel is untouched.
    for (5..10) |row_index|
        try std.testing.expectEqualStrings("", std.mem.trim(u8, &screen.grid[row_index], " "));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[10], "foreign-sentinel"));
}
test "vacated rows reject an unbounded plan before writing" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidTailFrame, emitVacatedRows(&out.writer, max_rows + 1));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try emitVacatedRows(&out.writer, max_rows);
    // Constant CR+CUD1+EL per row, then CR+CUU(max_rows).
    try std.testing.expectEqual(@as(usize, 1807), out.written().len);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.written(), '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[M") == null);
}
test "popup history copies are independent bounded and allocation failure safe" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), menuHistoryAllocationScenario, .{});
    var rows: [201][]const u8 = @splat("");
    try std.testing.expectError(error.InvalidTailFrame, MenuHistory.capture(std.testing.allocator, &rows, &.{}));
}
test "exhaustive capture allocation failures leak no bytes" {
    // Disable optional arena backing resize so replayed allocation counts stay
    // deterministic; production allocation behavior remains unchanged.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationScenario, .{});
}
