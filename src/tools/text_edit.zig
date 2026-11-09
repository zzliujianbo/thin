//! Exact edits are resolved against the same original byte sequence.
const std = @import("std");

pub const max_edits: usize = 128;
pub const Edit = struct { old_text: []const u8, new_text: []const u8 };
const Span = struct { start: usize, end: usize, replacement: []const u8 };

pub fn apply(a: std.mem.Allocator, before: []const u8, edits: []const Edit, limit: usize) ![]u8 {
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
    for (spans) |span| {
        const prefix = before[src..span.start];
        @memcpy(result[dst..][0..prefix.len], prefix);
        dst += prefix.len;
        @memcpy(result[dst..][0..span.replacement.len], span.replacement);
        dst += span.replacement.len;
        src = span.end;
    }
    @memcpy(result[dst..], before[src..]);
    return result;
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

test "exact edits propagate allocation failures" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            const out = try apply(a, "abc xyz", &.{.{ .old_text = "abc", .new_text = "long replacement" }}, 100);
            defer a.free(out);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
