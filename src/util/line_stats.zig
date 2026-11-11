//! Passive, bounded text-line observations, never write/approval parameters.
//! LF separates lines (CRLF counts once); a final LF creates no extra empty line.
const std = @import("std");

pub const Changes = struct { modified: u64 = 0, added: u64 = 0, removed: u64 = 0 };
pub const File = struct { read: ?u64 = null, partial: bool = false, changes: ?Changes = null };
pub const max_bytes = 256 * 1024;
const max_lines = 2048;
pub const max_cells = 1024 * 1024;

pub fn count(bytes: []const u8) u64 {
    if (bytes.len == 0) return 0;
    return @as(u64, @intCast(std.mem.count(u8, bytes, "\n"))) + @intFromBool(bytes[bytes.len - 1] != '\n');
}

fn split(a: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    const out = try a.alloc([]const u8, @intCast(count(bytes)));
    var start: usize = 0;
    var i: usize = 0;
    while (start < bytes.len) : (i += 1) {
        const end = if (std.mem.findScalar(u8, bytes[start..], '\n')) |n| start + n + 1 else bytes.len;
        out[i] = bytes[start..end];
        start = end;
    }
    return out;
}

fn lineEnd(bytes: []const u8, start: usize) usize {
    return if (std.mem.indexOfScalar(u8, bytes[start..], '\n')) |n| start + n + 1 else bytes.len;
}

fn lineStartBefore(bytes: []const u8, end: usize) usize {
    const search_end = if (bytes[end - 1] == '\n') end - 1 else end;
    return if (std.mem.lastIndexOfScalar(u8, bytes[0..search_end], '\n')) |n| n + 1 else 0;
}

fn hunk(out: *Changes, removed: *u64, added: *u64) void {
    // Pair replacement lines, then count unpaired additions/deletions. No double
    // counting: ~M +A -D is a presentation convention, not patch +/- totals.
    const paired = @min(removed.*, added.*);
    out.modified += paired;
    out.removed += removed.* - paired;
    out.added += added.* - paired;
    removed.* = 0;
    added.* = 0;
}

/// Deterministic LCS against a PRE-WRITE fd snapshot. Trim common ends, cap
/// bytes/lines/table work; unavailable is null, never fabricated zero changes.
/// Call before commit. OOM may be ignored by the optional observation caller.
pub fn compare(a: std.mem.Allocator, before: []const u8, after: []const u8) !?Changes {
    var budget: usize = max_cells;
    return compareBudgeted(a, before, after, &budget);
}

/// Shared cell budget permits independent, aligned hunks without multiplying the work cap.
pub fn compareBudgeted(a: std.mem.Allocator, before: []const u8, after: []const u8, budget: *usize) !?Changes {
    if (std.mem.eql(u8, before, after)) return Changes{};
    if (!std.unicode.utf8ValidateSlice(before) or !std.unicode.utf8ValidateSlice(after)) return null;
    var start: usize = 0;
    while (start < before.len and start < after.len) {
        const old_end = lineEnd(before, start);
        const new_end = lineEnd(after, start);
        if (!std.mem.eql(u8, before[start..old_end], after[start..new_end])) break;
        start = old_end;
    }
    var old_end = before.len;
    var new_end = after.len;
    while (old_end > start and new_end > start) {
        const old_start = lineStartBefore(before, old_end);
        const new_start = lineStartBefore(after, new_end);
        if (old_start < start or new_start < start or !std.mem.eql(u8, before[old_start..old_end], after[new_start..new_end])) break;
        old_end = old_start;
        new_end = new_start;
    }
    const old_bytes = before[start..old_end];
    const new_bytes = after[start..new_end];
    if (old_bytes.len > max_bytes or new_bytes.len > max_bytes) return null;
    const old_count = count(old_bytes);
    const new_count = count(new_bytes);
    if (old_count > max_lines or new_count > max_lines) return null;
    if (old_count == 0) return Changes{ .added = new_count };
    if (new_count == 0) return Changes{ .removed = old_count };
    const cells = (@as(usize, @intCast(old_count)) + 1) * (@as(usize, @intCast(new_count)) + 1);
    if (cells > budget.*) return null;
    budget.* -= cells;
    const old = try split(a, old_bytes);
    defer a.free(old);
    const new = try split(a, new_bytes);
    defer a.free(new);
    const stride = new.len + 1;
    const table = try a.alloc(u16, cells);
    defer a.free(table);
    @memset(table, 0);
    var i = old.len;
    while (i != 0) {
        i -= 1;
        var j = new.len;
        while (j != 0) {
            j -= 1;
            table[i * stride + j] = if (std.mem.eql(u8, old[i], new[j])) table[(i + 1) * stride + j + 1] + 1 else @max(table[(i + 1) * stride + j], table[i * stride + j + 1]);
        }
    }
    i = 0;
    var j: usize = 0;
    var removed: u64 = 0;
    var added: u64 = 0;
    var out: Changes = .{};
    while (i < old.len or j < new.len) {
        if (i < old.len and j < new.len and std.mem.eql(u8, old[i], new[j])) {
            hunk(&out, &removed, &added);
            i += 1;
            j += 1;
        } else if (i < old.len and (j == new.len or table[(i + 1) * stride + j] >= table[i * stride + j + 1])) {
            removed += 1;
            i += 1;
        } else {
            added += 1;
            j += 1;
        }
    }
    hunk(&out, &removed, &added);
    return out;
}

test "budget is shared and charged exactly for LCS cells" {
    const a = std.testing.allocator;
    var budget: usize = 8;
    try std.testing.expectEqualDeep(Changes{ .modified = 1 }, (try compareBudgeted(a, "a\n", "b\n", &budget)).?);
    try std.testing.expectEqual(@as(usize, 4), budget);
    try std.testing.expectEqualDeep(Changes{ .modified = 1 }, (try compareBudgeted(a, "x", "y", &budget)).?);
    try std.testing.expectEqual(@as(usize, 0), budget);
    try std.testing.expect((try compareBudgeted(a, "p", "q", &budget)) == null);
    try std.testing.expectEqual(@as(usize, 0), budget);
    // Equal input and pure additions/deletions require no table cells.
    try std.testing.expectEqualDeep(Changes{}, (try compareBudgeted(a, "same", "same", &budget)).?);
    try std.testing.expectEqualDeep(Changes{ .added = 1 }, (try compareBudgeted(a, "", "added\n", &budget)).?);
    try std.testing.expectEqualDeep(Changes{ .removed = 1 }, (try compareBudgeted(a, "removed\n", "", &budget)).?);
    try std.testing.expectEqual(@as(usize, 0), budget);
    budget = 3;
    try std.testing.expect((try compareBudgeted(a, "a", "b", &budget)) == null);
    try std.testing.expectEqual(@as(usize, 3), budget);
}

test "trim complete common lines before applying observation caps" {
    const a = std.testing.allocator;
    const prefix = try a.alloc(u8, 300 * 1024);
    defer a.free(prefix);
    for (prefix, 0..) |*byte, i| byte.* = if (i % 32 == 31) '\n' else 'x';
    const before = try std.mem.concat(a, u8, &.{ prefix, "old\n", prefix });
    defer a.free(before);
    const after = try std.mem.concat(a, u8, &.{ prefix, "new\n", prefix });
    defer a.free(after);
    var budget: usize = 4;
    try std.testing.expectEqualDeep(Changes{ .modified = 1 }, (try compareBudgeted(a, before, after, &budget)).?);
    try std.testing.expectEqual(@as(usize, 0), budget);
}

test "line observations count returned segments and bounded replacement hunks without double counting" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u64, 0), count(""));
    try std.testing.expectEqual(@as(u64, 1), count("\n"));
    try std.testing.expectEqual(@as(u64, 2), count("a\r\n中"));
    try std.testing.expectEqualDeep(Changes{ .added = 2 }, (try compare(a, "", "a\nb\n")).?);
    try std.testing.expectEqualDeep(Changes{ .removed = 2 }, (try compare(a, "a\nb", "")).?);
    try std.testing.expectEqualDeep(Changes{ .modified = 1, .added = 1, .removed = 1 }, (try compare(a, "a\nb\nc\nd\ne\n", "a\nB\nx\nc\ne\n")).?);
    try std.testing.expectEqualDeep(Changes{}, (try compare(a, "same\n", "same\n")).?);
    try std.testing.expectEqualDeep(Changes{ .modified = 1 }, (try compare(a, "last\n", "last")).?);
    try std.testing.expect((try compare(a, "\xff", "valid")) == null);
    const big = try a.alloc(u8, max_bytes + 1);
    defer a.free(big);
    @memset(big, 'a');
    try std.testing.expect((try compare(a, "old", big)) == null);
    const many = try a.alloc(u8, 3000);
    defer a.free(many);
    @memset(many, '\n');
    try std.testing.expect((try compare(a, many, "new")) == null);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, compare(failing.allocator(), "old", "new"));
}
