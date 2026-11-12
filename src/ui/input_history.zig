//! Session-local submitted user inputs, independent of clipped display records.
//! No disk persistence; auth/commands never call prepare/commit.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const History = struct {
    entries: std.ArrayList([]u8) = .empty,
    index: ?usize = null,

    pub fn deinit(self: *History, a: Allocator) void {
        for (self.entries.items) |entry| release(a, entry);
        self.entries.deinit(a);
        self.* = .{};
    }

    fn release(a: Allocator, entry: []u8) void {
        std.crypto.secureZero(u8, entry);
        a.free(entry);
    }

    /// Perform every fallible allocation before launching a task. Capacity may
    /// grow, but failure changes neither entries nor the navigation selection.
    pub fn prepare(self: *History, a: Allocator, value: []const u8) ![]u8 {
        if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidHistoryInput;
        const owned = try a.dupe(u8, value);
        errdefer release(a, owned);
        try self.entries.ensureUnusedCapacity(a, 1);
        return owned;
    }

    pub fn discard(a: Allocator, prepared: []u8) void {
        release(a, prepared);
    }

    /// Called only after the task successfully starts. Infallible ownership transfer.
    pub fn commit(self: *History, _: Allocator, prepared: []u8) void {
        self.entries.appendAssumeCapacity(prepared);
        self.index = null;
    }

    pub const Selection = struct { index: ?usize, text: []const u8 };
    /// Pure lookup. The UI publishes index only after editor allocation succeeds.
    pub fn target(self: *const History, forward: bool) ?Selection {
        if (self.entries.items.len == 0) return null;
        const index = if (forward) blk: {
            const current = self.index orelse return null;
            if (current + 1 == self.entries.items.len) return .{ .index = null, .text = "" };
            break :blk current + 1;
        } else if (self.index) |current| current -| 1 else self.entries.items.len - 1;
        return .{ .index = index, .text = self.entries.items[index] };
    }
};
