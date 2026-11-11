//! Session-local submitted user inputs, independent of clipped display records.
//! No disk persistence; auth/commands never call prepare/commit.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const History = struct {
    pub const max_entries = 64;
    pub const max_bytes = 1024 * 1024;
    pub const max_entry_bytes = 65536;
    entries: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
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
        if (value.len == 0 or value.len > max_entry_bytes or !std.unicode.utf8ValidateSlice(value)) return error.InvalidHistoryInput;
        const owned = try a.dupe(u8, value);
        errdefer release(a, owned);
        try self.entries.ensureUnusedCapacity(a, 1);
        return owned;
    }

    pub fn discard(a: Allocator, prepared: []u8) void {
        release(a, prepared);
    }

    /// Called only after the task successfully starts. Infallible ownership transfer.
    pub fn commit(self: *History, a: Allocator, prepared: []u8) void {
        while (self.entries.items.len >= max_entries or self.bytes > max_bytes - prepared.len) {
            const oldest = self.entries.orderedRemove(0);
            self.bytes -= oldest.len;
            release(a, oldest);
        }
        self.entries.appendAssumeCapacity(prepared);
        self.bytes += prepared.len;
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
