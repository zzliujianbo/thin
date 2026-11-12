test "exact edits use original coordinates and unicode" {
    const a = std.testing.allocator;
    const out = try apply(a, "中文🙂 abc xyz", &.{ .{ .old_text = "xyz", .new_text = "!" }, .{ .old_text = "中文🙂", .new_text = "" }, .{ .old_text = "abc", .new_text = "中文" } }, 100);
    defer a.free(out);
    try std.testing.expectEqualStrings(" 中文 !", out);
}
test "exact edits reject ambiguity overlap empty and limits" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.AmbiguousEdit, apply(a, "aaa", &.{.{ .old_text = "aa", .new_text = "" }}, 10));
    try std.testing.expectError(error.AmbiguousEdit, apply(a, "abab", &.{.{ .old_text = "ab", .new_text = "" }}, 10));
    try std.testing.expectError(error.OverlappingEdits, apply(a, "abcd", &.{ .{ .old_text = "abc", .new_text = "" }, .{ .old_text = "bcd", .new_text = "" } }, 10));
    try std.testing.expectError(error.OverlappingEdits, apply(a, "abcd", &.{ .{ .old_text = "ab", .new_text = "" }, .{ .old_text = "ab", .new_text = "" } }, 10));
    try std.testing.expectError(error.EmptyOldText, apply(a, "a", &.{.{ .old_text = "", .new_text = "x" }}, 10));
    try std.testing.expectError(error.EditNotFound, apply(a, "a", &.{.{ .old_text = "z", .new_text = "x" }}, 10));
    try std.testing.expectError(error.FileTooLarge, apply(a, "a", &.{.{ .old_text = "a", .new_text = "xx" }}, 1));
    try std.testing.expectError(error.FileTooLarge, apply(a, "ab", &.{.{ .old_text = "ab", .new_text = "" }}, 1));
}
test "exact edits accept more than 128 entries" {
    const a = std.testing.allocator;
    const count = 160;
    var before: [count * 4]u8 = undefined;
    var edits: [count]Edit = undefined;
    for (0..count) |i| {
        const part = before[i * 4 ..][0..4];
        _ = try std.fmt.bufPrint(part, "{d:0>3};", .{i});
        edits[i] = .{ .old_text = part, .new_text = "" };
    }
    const out = try apply(a, &before, &edits, null);
    defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}
test "unlimited exact edit accepts file above former eight MiB boundary" {
    const a = std.testing.allocator;
    const before = try a.alloc(u8, 8 * 1024 * 1024 + 1);
    defer a.free(before);
    @memset(before, 'a');
    before[before.len - 1] = 'z';
    const out = try apply(a, before, &.{.{ .old_text = "z", .new_text = "end" }}, null);
    defer a.free(out);
    try std.testing.expectEqual(before.len + 2, out.len);
    try std.testing.expectEqualStrings("end", out[out.len - 3 ..]);
}
test "observed local edits in a multi-megabyte file" {
    const a = std.testing.allocator;
    // Many complete, short lines, well beyond both whole-file observation caps.
    const before = try a.alloc(u8, 3 * 1024 * 1024);
    defer a.free(before);
    for (before, 0..) |*byte, i| byte.* = if (i % 64 == 63) '\n' else 'a';
    @memcpy(before[1000..1003], "ONE");
    @memcpy(before[before.len - 1000 ..][0..3], "TWO");
    const result = try applyObserved(a, before, &.{
        .{ .old_text = "TWO", .new_text = "two" },
        .{ .old_text = "ONE", .new_text = "one" },
    }, before.len);
    defer a.free(result.bytes);
    try std.testing.expectEqual(before.len, result.bytes.len);
    try std.testing.expectEqualStrings("one", result.bytes[1000..1003]);
    try std.testing.expectEqualStrings("two", result.bytes[before.len - 1000 ..][0..3]);
    try std.testing.expectEqualDeep(line_stats.Changes{ .modified = 2 }, result.changes.?);
}
test "observed line boundaries agree with full comparison" {
    const a = std.testing.allocator;
    const Case = struct { before: []const u8, edits: []const Edit, after: []const u8, changes: line_stats.Changes };
    const cases = [_]Case{
        .{ .before = "one alpha beta end\nnext\n", .edits = &.{ .{ .old_text = "alpha", .new_text = "A" }, .{ .old_text = "beta", .new_text = "B" } }, .after = "one A B end\nnext\n", .changes = .{ .modified = 1 } },
        .{ .before = "left\nright\nend\n", .edits = &.{.{ .old_text = "left\n", .new_text = "left" }}, .after = "leftright\nend\n", .changes = .{ .modified = 1, .removed = 1 } },
        .{ .before = "abc\nend\n", .edits = &.{.{ .old_text = "b", .new_text = "b\n" }}, .after = "ab\nc\nend\n", .changes = .{ .modified = 1, .added = 1 } },
        .{ .before = "first\nsecond\nlast", .edits = &.{.{ .old_text = "second", .new_text = "new\nsecond" }}, .after = "first\nnew\nsecond\nlast", .changes = .{ .added = 1 } },
        .{ .before = "a\r\n中文🙂\r\nlast", .edits = &.{.{ .old_text = "中文🙂", .new_text = "汉字😀" }}, .after = "a\r\n汉字😀\r\nlast", .changes = .{ .modified = 1 } },
        .{ .before = "start\nlast", .edits = &.{.{ .old_text = "last", .new_text = "LAST\n" }}, .after = "start\nLAST\n", .changes = .{ .modified = 1 } },
        .{ .before = "same\n", .edits = &.{.{ .old_text = "same", .new_text = "same" }}, .after = "same\n", .changes = .{} },
        .{ .before = "a\nb\nc\n", .edits = &.{ .{ .old_text = "a\n", .new_text = "a" }, .{ .old_text = "b", .new_text = "B" } }, .after = "aB\nc\n", .changes = .{ .modified = 1, .removed = 1 } },
    };
    for (cases) |case| {
        const result = try applyObserved(a, case.before, case.edits, 1024);
        defer a.free(result.bytes);
        try std.testing.expectEqualStrings(case.after, result.bytes);
        try std.testing.expectEqualDeep(case.changes, result.changes.?);
        try std.testing.expectEqualDeep((try line_stats.compare(a, case.before, result.bytes)).?, result.changes.?);
    }
}
test "observed large changes and shared hunk budget become unavailable" {
    const a = std.testing.allocator;
    const old = try a.alloc(u8, 1022 * 2);
    defer a.free(old);
    const replacement = try a.alloc(u8, old.len);
    defer a.free(replacement);
    for (old, replacement, 0..) |*x, *y, i| {
        x.* = if (i % 2 == 0) 'a' else '\n';
        y.* = if (i % 2 == 0) 'b' else '\n';
    }
    const before = try std.mem.concat(a, u8, &.{ old, "unchanged\n", "last\n" });
    defer a.free(before);
    const result = try applyObserved(a, before, &.{
        .{ .old_text = old, .new_text = replacement },
        .{ .old_text = "last", .new_text = "LAST" },
    }, before.len);
    defer a.free(result.bytes);
    // First hunk costs 1023² cells; the final 1-line hunk still fits.
    try std.testing.expectEqualDeep(line_stats.Changes{ .modified = 1023 }, result.changes.?);

    const old2 = try a.alloc(u8, 46 * 2);
    defer a.free(old2);
    const new2 = try a.alloc(u8, old2.len);
    defer a.free(new2);
    for (old2, new2, 0..) |*x, *y, i| {
        x.* = if (i % 2 == 0) 'c' else '\n';
        y.* = if (i % 2 == 0) 'd' else '\n';
    }
    const before2 = try std.mem.concat(a, u8, &.{ old, "unchanged\n", old2 });
    defer a.free(before2);
    const result2 = try applyObserved(a, before2, &.{ .{ .old_text = old, .new_text = replacement }, .{ .old_text = old2, .new_text = new2 } }, before2.len);
    defer a.free(result2.bytes);
    try std.testing.expect(result2.changes == null);
    try std.testing.expectEqualSlices(u8, replacement, result2.bytes[0..replacement.len]);
    try std.testing.expectEqualSlices(u8, new2, result2.bytes[result2.bytes.len - new2.len ..]);

    const huge = try a.alloc(u8, line_stats.max_bytes + 1);
    defer a.free(huge);
    @memset(huge, 'x');
    const large = try applyObserved(a, huge, &.{.{ .old_text = huge, .new_text = "y" }}, huge.len);
    defer a.free(large.bytes);
    try std.testing.expectEqualStrings("y", large.bytes);
    try std.testing.expect(large.changes == null);
}
test "optional observation allocation failure preserves applied bytes" {
    const a = std.testing.allocator;
    // Spans and output allocate first; each subsequent allocation belongs to observation.
    for (2..5) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const result = try applyObserved(failing.allocator(), "abc xyz", &.{.{ .old_text = "abc", .new_text = "replacement" }}, 100);
        defer failing.allocator().free(result.bytes);
        try std.testing.expectEqualStrings("replacement xyz", result.bytes);
        try std.testing.expect(result.changes == null);
    }
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, applyObserved(failing.allocator(), "abc xyz", &.{.{ .old_text = "abc", .new_text = "replacement" }}, 100));
    }
}
test "exact edits propagate allocation failures" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            const out = try apply(a, "abc xyz", &.{.{ .old_text = "abc", .new_text = "long replacement" }}, 100);
            defer a.free(out);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
