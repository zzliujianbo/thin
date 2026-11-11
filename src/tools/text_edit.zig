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
