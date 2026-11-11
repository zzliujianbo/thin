test "arbitrary chunk boundaries keep the exact plain tail" {
    try text.initLocale();
    const a = testing.allocator;
    const bodies = [_][]const u8{
        "",
        "plain",
        "h\u{00e9}llo \u{4e2d}\u{6587}\r\nnext \u{1f44d}\u{1f3fd} \u{1f469}\u{200d}\u{1f4bb} \u{1f1fa}\u{1f1f8}\tTabbed\n\nlast",
        "a\rb\rc\r\nd",
        "e\u{0301}\u{fe0f}z",
    };
    for (bodies) |body| {
        for (0..body.len + 1) |split| {
            const tail = try Tail.create(a, 7, 3, 1 << 16);
            defer tail.destroy();
            try tail.append(body[0..split]);
            try tail.append(body[split..]);
            try expectTail(tail, 7, body);
        }
        const bytes = try Tail.create(a, 7, 3, 1 << 16);
        defer bytes.destroy();
        for (0..body.len) |i| try bytes.append(body[i .. i + 1]);
        try expectTail(bytes, 7, body);
    }
}
test "long ASCII without newlines stays bounded and tail-exact" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 10, 3, 4096);
    defer tail.destroy();
    const chunk: [97]u8 = @splat('x');
    for (0..200) |_| try tail.append(&chunk);
    try testing.expect(tail.retainedBytes() <= 4096);
    try testing.expect(tail.retainedRows() <= 4);
    try testing.expect(tail.retainedSource().len <= 4096);
    try testing.expectEqual(Limit.none, tail.limitState());
    const body: [97 * 200]u8 = @splat('x');
    try expectTail(tail, 10, &body);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    try testing.expectEqual(@as(usize, 3), snap.rows.len);
}
test "tabs keep the shared writer tab stops at narrow and wide columns" {
    try text.initLocale();
    const a = testing.allocator;
    const body = "a\tb\t\tc\td\te\tf\tg";
    for ([_]usize{ 1, 2, 79 }) |columns| {
        const tail = try Tail.create(a, columns, 4, 1 << 16);
        defer tail.destroy();
        for (0..body.len) |i| try tail.append(body[i .. i + 1]);
        try expectTail(tail, columns, body);
    }
}
test "snapshots are clones: later combining bytes still extend a pending cluster" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 4, 3, 1 << 16);
    defer tail.destroy();
    try tail.append("e");
    var first = try tail.snapshot(a);
    defer first.deinit(a);
    var second = try tail.snapshot(a);
    defer second.deinit(a);
    try testing.expectEqual(first.rows.len, second.rows.len);
    for (first.rows, second.rows) |x, y| try testing.expectEqualStrings(x, y);
    try tail.append("\u{0301}");
    try tail.append("\n");
    try tail.append("\u{1f469}\u{200d}\u{1f4bb}\u{1f1fa}\u{1f1f8}\u{fe0f}");
    try expectTail(tail, 4, "e\u{0301}\n\u{1f469}\u{200d}\u{1f4bb}\u{1f1fa}\u{1f1f8}\u{fe0f}");
}
test "input ANSI, controls, CRLF and bidi controls never reach the tail" {
    try text.initLocale();
    const a = testing.allocator;
    const body = "\x1b[31mred\x1b[0m\x07\x00a\rb\r\nc\u{202e}d\x7f\x9b\u{2066}e";
    const tail = try Tail.create(a, 6, 3, 1 << 16);
    defer tail.destroy();
    for (0..body.len) |i| try tail.append(body[i .. i + 1]);
    try expectTail(tail, 6, body);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    for (snap.rows) |row| {
        try testing.expect(std.mem.indexOf(u8, row, "\x1b[31") == null);
        try testing.expect(std.mem.indexOfScalar(u8, row, 0x07) == null);
        try testing.expect(std.mem.indexOfScalar(u8, row, 0x00) == null);
        try testing.expect(std.mem.indexOfScalar(u8, row, '\r') == null);
    }
}
test "a pathological cluster stops in a bounded display-limit state" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 8, 3, 4096);
    defer tail.destroy();
    try tail.append("ok\n");
    try tail.append("a");
    for (0..20000) |_| try tail.append("\u{0301}");
    try testing.expectEqual(Limit.cluster, tail.limitState());
    try testing.expect(tail.retainedBytes() <= 4096);
    try testing.expect(tail.retainedSource().len <= 4096);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    try testing.expectEqual(Limit.cluster, snap.limit);
    var saw_ok = false;
    for (snap.rows) |row| saw_ok = saw_ok or std.mem.indexOf(u8, row, "ok") != null;
    try testing.expect(saw_ok);
    // Further input is counted, never buffered.
    const dropped = tail.droppedBytes();
    try tail.append("tail");
    try testing.expectEqual(dropped + 4, tail.droppedBytes());
    try testing.expect(tail.retainedBytes() <= 4096);
}
test "resize reflows only the retained source window" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 12, 3, 1 << 16);
    defer tail.destroy();
    var buf: [64]u8 = undefined;
    for (0..60) |i| {
        const line = try std.fmt.bufPrint(&buf, "row {d} with text\n", .{i});
        try tail.append(line);
    }
    const retained = try a.dupe(u8, tail.retainedSource());
    defer a.free(retained);
    try testing.expect(std.mem.indexOf(u8, retained, "row 0 ") == null);
    try tail.resize(28);
    try testing.expectEqual(@as(usize, 28), tail.columns());
    try expectTail(tail, 28, retained);
    const narrow = try a.dupe(u8, tail.retainedSource());
    defer a.free(narrow);
    try testing.expect(std.mem.indexOf(u8, narrow, "row 0 ") == null);
    try tail.resize(64);
    try expectTail(tail, 64, narrow);
}
test "allocation failures release every owned row and source byte" {
    try text.initLocale();
    const Scenario = struct {
        fn run(a: Allocator) !void {
            const tail = try Tail.create(a, 9, 3, 1 << 12);
            defer tail.destroy();
            const chunks = [_][]const u8{ "ab", "\u{00e9}", "\u{1f469}\u{200d}\u{1f4bb}", "\r", "\n", "line two\tend", "\n" };
            for (chunks) |chunk| try tail.append(chunk);
            var snap = try tail.snapshot(a);
            defer snap.deinit(a);
            try tail.resize(4);
            try tail.append("more\n");
            var again = try tail.snapshot(a);
            defer again.deinit(a);
        }
    };
    var backing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    try testing.checkAllAllocationFailures(backing.allocator(), Scenario.run, .{});
    try testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
test "snapshot at every prefix shows the sanitized held bytes, then completion" {
    try text.initLocale();
    const a = testing.allocator;
    const bodies = [_][]const u8{
        "a\r\nb",
        "x\ty",
        "\u{00e9}",
        "e\u{0301}",
        "\u{1f469}\u{200d}\u{1f4bb}",
        "cr\r",
        "end\r\n",
    };
    for (bodies) |body| {
        for (0..body.len + 1) |split| {
            const tail = try Tail.create(a, 5, 3, 1 << 16);
            defer tail.destroy();
            for (0..split) |i| try tail.append(body[i .. i + 1]);
            // Prefix: a trailing CR or a partial scalar must already read as
            // U+FFFD, but only inside the clone.
            try expectTail(tail, 5, body[0..split]);
            for (split..body.len) |i| try tail.append(body[i .. i + 1]);
            // Completion replaced the preview: a CRLF is one newline and a
            // finished scalar extends the live cluster.
            try expectTail(tail, 5, body);
        }
    }
}
test "retained row source starts align with a resized refeed" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 12, 3, 1 << 16);
    defer tail.destroy();
    var buf: [48]u8 = undefined;
    for (0..40) |i| {
        const line = try std.fmt.bufPrint(&buf, "line {d} tab\tend\r\n", .{i});
        try tail.append(line);
    }
    try tail.resize(6);
    try tail.resize(20);
    // Re-emitting the retained window at the current width must reproduce the
    // exact same absolute emit-stream row starts.
    var probe: StartProbe = .{ .a = a };
    defer probe.deinit();
    var w: Writer = .{ .a = a, .columns = tail.columns(), .ansi = true, .base = .thinking, .sink = probe.sink() };
    defer w.deinit();
    w.pos = tail.source_base;
    try w.emit(tail.retainedSource());
    const rows = tail.rows.items[tail.first..];
    try testing.expect(rows.len != 0);
    try testing.expect(probe.starts.items.len >= rows.len);
    const offset = probe.starts.items.len - rows.len;
    for (rows, probe.starts.items[offset..]) |row, start| try testing.expectEqual(row.src_start, start);
}
test "owned memory stays inside its documented bound" {
    try text.initLocale();
    const a = testing.allocator;
    const tail = try Tail.create(a, 7, 3, 2048);
    defer tail.destroy();
    try testing.expect(tail.ownedBytes() <= tail.ownedBound());
    const chunk: [128]u8 = @splat('x');
    for (0..400) |_| {
        try tail.append(&chunk);
        try testing.expect(tail.ownedBytes() <= tail.ownedBound());
    }
    try testing.expect(tail.ownedBytes() >= tail.retainedBytes());
    try testing.expectEqual(Limit.none, tail.limitState());
    // A single huge combining cluster is capped by max_cluster_bytes, so the
    // bound must never need a rows*columns*4 estimate.
    try tail.append("\n");
    for (0..4000) |_| try tail.append("\u{0301}");
    try testing.expectEqual(Limit.cluster, tail.limitState());
    try testing.expect(tail.ownedBytes() <= tail.ownedBound());
    try testing.expect(tail.ownedBytes() >= tail.retainedBytes());
}
test "any append allocation failure latches the display limit" {
    try text.initLocale();
    var backing = testing.FailingAllocator.init(testing.allocator, .{});
    const tail = try Tail.create(backing.allocator(), 8, 3, 1 << 12);
    {
        defer tail.destroy();
        try tail.append("warm\n");
        try testing.expectEqual(Limit.none, tail.limitState());
        backing.fail_index = backing.alloc_index; // the very next allocation fails
        try testing.expectError(error.OutOfMemory, tail.append("another line\n"));
        try testing.expectEqual(Limit.memory, tail.limitState());
        // Frozen, countable and still readable; nothing is silently retried.
        const dropped = tail.droppedBytes();
        try tail.append("later");
        try testing.expectEqual(dropped + 5, tail.droppedBytes());
        var snap = try tail.snapshot(testing.allocator);
        defer snap.deinit(testing.allocator);
        try testing.expectEqual(Limit.memory, snap.limit);
        try testing.expect(snap.rows.len != 0);
    }
    try testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
test "row sinks never free a row the writer still owns" {
    const a = testing.allocator;
    var backing = testing.FailingAllocator.init(a, .{});
    const tail = try Tail.create(backing.allocator(), 8, 3, 1 << 12);
    {
        defer tail.destroy();
        const row = try backing.allocator().dupe(u8, "owned-row");
        backing.fail_index = backing.alloc_index; // row push must fail
        try testing.expectError(error.OutOfMemory, Tail.onRow(tail, row, 0, ""));
        // The sink did not free it: the writer (this test) still owns it, so
        // exactly one free happens here. A sink-side free would double free.
        backing.allocator().free(row);
    }
    try testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);

    // Same contract for the resize collector.
    var second = testing.FailingAllocator.init(a, .{});
    var collector: Collector = .{ .a = second.allocator(), .keep = 2 };
    {
        defer collector.deinit();
        const row = try second.allocator().dupe(u8, "collector-row");
        second.fail_index = second.alloc_index;
        try testing.expectError(error.OutOfMemory, Collector.onRow(&collector, row, 0, ""));
        second.allocator().free(row);
    }
    try testing.expectEqual(second.allocated_bytes, second.freed_bytes);
}
