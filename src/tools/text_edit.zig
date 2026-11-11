//! Exact edits are resolved against the same original byte sequence.
const std = @import("std");
const line_stats = @import("../util/line_stats.zig");

pub const max_edits: usize = 128;
pub const Edit = struct { old_text: []const u8, new_text: []const u8 };
const Span = struct { start: usize, end: usize, replacement: []const u8, after_start: usize = 0, after_end: usize = 0 };
pub const Applied = struct { bytes: []u8, changes: ?line_stats.Changes };

pub fn apply(a: std.mem.Allocator, before: []const u8, edits: []const Edit, limit: usize) ![]u8 {
    return (try applyInternal(a, before, edits, limit, false)).bytes;
}

pub fn applyObserved(a: std.mem.Allocator, before: []const u8, edits: []const Edit, limit: usize) !Applied {
    return applyInternal(a, before, edits, limit, true);
}

fn applyInternal(a: std.mem.Allocator, before: []const u8, edits: []const Edit, limit: usize, observe: bool) !Applied {
    if (before.len > limit) return error.FileTooLarge;
    if (edits.len == 0) return error.EmptyEdits;
    if (edits.len > max_edits) return error.TooManyEdits;
    const spans = try a.alloc(Span, edits.len);
    defer a.free(spans);
    var size = before.len;
    for (edits, 0..) |edit, i| {
        if (edit.old_text.len == 0) return error.EmptyOldText;
        for ([_][]const u8{ edit.old_text, edit.new_text }) |text| {
            if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;
        }
        const start = std.mem.indexOf(u8, before, edit.old_text) orelse return error.EditNotFound;
        if (std.mem.indexOf(u8, before[start + 1 ..], edit.old_text) != null) return error.AmbiguousEdit;
        const end = start + edit.old_text.len;
        for (spans[0..i]) |previous| {
            if (start < previous.end and previous.start < end) return error.OverlappingEdits;
        }
        spans[i] = .{ .start = start, .end = end, .replacement = edit.new_text };
        size -= edit.old_text.len;
        size = std.math.add(usize, size, edit.new_text.len) catch return error.FileTooLarge;
    }
    if (size > limit) return error.FileTooLarge;
    std.mem.sort(Span, spans, {}, struct {
        fn less(_: void, x: Span, y: Span) bool {
            return x.start < y.start;
        }
    }.less);
    const result = try a.alloc(u8, size);
    var src: usize = 0;
    var dst: usize = 0;
    for (spans) |*span| {
        const prefix = before[src..span.start];
        @memcpy(result[dst..][0..prefix.len], prefix);
        dst += prefix.len;
        span.after_start = dst;
        @memcpy(result[dst..][0..span.replacement.len], span.replacement);
        dst += span.replacement.len;
        span.after_end = dst;
        src = span.end;
    }
    @memcpy(result[dst..], before[src..]);
    const changes = if (observe) observeChanges(a, before, result, spans) catch null else null;
    return .{ .bytes = result, .changes = changes };
}

fn lineStart(bytes: []const u8, pos: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, bytes[0..pos], '\n')) |i| i + 1 else 0;
}

fn lineEnd(bytes: []const u8, pos: usize) usize {
    if (pos == 0 or bytes[pos - 1] == '\n') return pos;
    return if (std.mem.indexOfScalar(u8, bytes[pos..], '\n')) |i| pos + i + 1 else bytes.len;
}

fn observeChanges(a: std.mem.Allocator, before: []const u8, after: []const u8, spans: []const Span) !?line_stats.Changes {
    var total: line_stats.Changes = .{};
    var budget: usize = line_stats.max_cells;
    var i: usize = 0;
    while (i < spans.len) {
        const first = spans[i];
        const back = @max(first.start - lineStart(before, first.start), first.after_start - lineStart(after, first.after_start));
        const old_start = first.start - back;
        const new_start = first.after_start - back;
        var last = i;
        var forward: usize = undefined;
        while (true) {
            const span = spans[last];
            forward = @max(lineEnd(before, span.end) - span.end, lineEnd(after, span.after_end) - span.after_end);
            if (last + 1 >= spans.len or forward < spans[last + 1].start - span.end) break;
            last += 1;
        }
        const end_span = spans[last];
        const changes = (try line_stats.compareBudgeted(a, before[old_start .. end_span.end + forward], after[new_start .. end_span.after_end + forward], &budget)) orelse return null;
        total.modified += changes.modified;
        total.added += changes.added;
        total.removed += changes.removed;
        i = last + 1;
    }
    return total;
}

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

test "exact edit count is bounded at the helper boundary" {
    const a = std.testing.allocator;
    var before: [max_edits * 4]u8 = undefined;
    var edits: [max_edits + 1]Edit = undefined;
    for (0..max_edits) |i| {
        const part = before[i * 4 ..][0..4];
        _ = try std.fmt.bufPrint(part, "{d:0>3};", .{i});
        edits[i] = .{ .old_text = part, .new_text = "" };
    }
    edits[max_edits] = .{ .old_text = "extra", .new_text = "" };
    const out = try apply(a, &before, edits[0..max_edits], before.len);
    defer a.free(out);
    try std.testing.expectEqualStrings("", out);
    try std.testing.expectError(error.TooManyEdits, apply(a, &before, &edits, before.len));
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
