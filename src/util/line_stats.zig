//! Passive, bounded text-line observations, never write/approval parameters.
//! LF separates lines (CRLF counts once); a final LF creates no extra empty line.
const std = @import("std");

pub const Changes = struct { modified: u64 = 0, added: u64 = 0, removed: u64 = 0 };
pub const File = struct { read: ?u64 = null, partial: bool = false, changes: ?Changes = null };
pub const max_bytes = 256 * 1024;
const max_lines = 2048;
const max_cells = 1024 * 1024;

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
    if (std.mem.eql(u8, before, after)) return Changes{};
    if (before.len > max_bytes or after.len > max_bytes) return null;
    if (!std.unicode.utf8ValidateSlice(before) or !std.unicode.utf8ValidateSlice(after)) return null;
    if (before.len == 0) return Changes{ .added = count(after) };
    if (after.len == 0) return Changes{ .removed = count(before) };
    if (count(before) > max_lines or count(after) > max_lines) return null;
    const old_all = try split(a, before);
    defer a.free(old_all);
    const new_all = try split(a, after);
    defer a.free(new_all);
    var prefix: usize = 0;
    while (prefix < @min(old_all.len, new_all.len) and std.mem.eql(u8, old_all[prefix], new_all[prefix])) : (prefix += 1) {}
    var old_end = old_all.len;
    var new_end = new_all.len;
    while (old_end > prefix and new_end > prefix and std.mem.eql(u8, old_all[old_end - 1], new_all[new_end - 1])) {
        old_end -= 1;
        new_end -= 1;
    }
    const old = old_all[prefix..old_end];
    const new = new_all[prefix..new_end];
    const stride = new.len + 1;
    const cells = (old.len + 1) * stride; // <= 2049^2, no adversarial usize overflow.
    if (cells > max_cells) return null;
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
