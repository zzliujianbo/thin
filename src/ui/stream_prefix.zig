//! Immutable owned checkpoint of rendered body rows, never canonical messages.
const std = @import("std");

const max_rows = 4096;
const max_bytes = 4 * 1024 * 1024;

pub const Prefix = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const []const u8,
    columns: usize,

    /// Bounds are checked before any allocation. Styling bytes are significant.
    pub fn capture(a: std.mem.Allocator, rows: []const []const u8, columns: usize) !?Prefix {
        if (rows.len > max_rows) return null;
        var bytes: usize = 0;
        for (rows) |row| {
            if (row.len > max_bytes - bytes) return null;
            bytes += row.len;
        }
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = try arena.allocator().alloc([]const u8, rows.len);
        for (rows, owned) |row, *copy| copy.* = try arena.allocator().dupe(u8, row);
        return .{ .arena = arena, .rows = owned, .columns = columns };
    }

    pub fn matches(self: *const Prefix, rows: []const []const u8, columns: usize) bool {
        if (columns != self.columns or rows.len < self.rows.len) return false;
        for (self.rows, rows[0..self.rows.len]) |old, row| {
            if (!std.mem.eql(u8, old, row)) return false;
        }
        return true;
    }

    pub fn deinit(self: *Prefix) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "prefix owns row descriptors and styling bytes independently" {
    var text = "\x1b[31mhello\x1b[0m".*;
    var rows = [_][]const u8{ &text, "" };
    var prefix = (try Prefix.capture(std.testing.allocator, &rows, 80)).?;
    defer prefix.deinit();
    @memset(&text, 'x');
    rows[1] = "changed";
    try std.testing.expectEqualStrings("\x1b[31mhello\x1b[0m", prefix.rows[0]);
    try std.testing.expectEqualStrings("", prefix.rows[1]);
    try std.testing.expectEqual(@as(usize, 80), prefix.columns);
    try std.testing.expect(prefix.matches(&.{ "\x1b[31mhello\x1b[0m", "", "more" }, 80));
}

test "prefix requires full exact styled prefix and same columns" {
    var prefix = (try Prefix.capture(std.testing.allocator, &.{ "\x1b[31mx", "y" }, 80)).?;
    defer prefix.deinit();
    try std.testing.expect(prefix.matches(&.{ "\x1b[31mx", "y" }, 80));
    try std.testing.expect(!prefix.matches(&.{ "\x1b[34mx", "y" }, 80));
    try std.testing.expect(!prefix.matches(&.{ "\x1b[31mx", "y" }, 81));
    try std.testing.expect(!prefix.matches(&.{"\x1b[31mx"}, 80));
    try std.testing.expect(!prefix.matches(&.{ "y", "\x1b[31mx" }, 80));
    var empty = (try Prefix.capture(std.testing.allocator, &.{}, 0)).?;
    defer empty.deinit();
    try std.testing.expect(empty.matches(&.{"anything"}, 0));
    try std.testing.expect(!empty.matches(&.{}, 1));
}

test "prefix bounds reject without allocation and accept exact limits" {
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var rows: [max_rows + 1][]const u8 = @splat("");
    try std.testing.expect((try Prefix.capture(fail.allocator(), &rows, 80)) == null);
    const raw = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(raw);
    @memset(raw, 'x');
    try std.testing.expect((try Prefix.capture(fail.allocator(), &.{raw}, 80)) == null);
    try std.testing.expect((try Prefix.capture(fail.allocator(), &.{ raw[0..max_bytes], "x" }, 80)) == null);
    try std.testing.expectEqual(@as(usize, 0), fail.allocations);
    rows[0] = raw[0..max_bytes];
    var prefix = (try Prefix.capture(std.testing.allocator, rows[0..max_rows], 80)).?;
    defer prefix.deinit();
    try std.testing.expectEqual(max_rows, prefix.rows.len);
    try std.testing.expectEqualStrings(raw[0..max_bytes], prefix.rows[0]);
}

fn allocationScenario(a: std.mem.Allocator) !void {
    var bytes: [16384]u8 = @splat('x');
    var prefix = (try Prefix.capture(a, &.{ "first", &bytes, "last" }, 100)).?;
    defer prefix.deinit();
    try std.testing.expect(prefix.matches(&.{ "first", &bytes, "last", "extra" }, 100));
}

test "prefix allocation failures propagate and clean up all owned bytes" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationScenario, .{});
}
