//! Owned, generation-scoped display captions only. No canonical/history effects.
//! get() borrows an entry only for the duration of the caller's operation;
//! subsequent mutations may replace its caption or move the entry.
const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const presentation = @import("presentation.zig");
const Allocator = std.mem.Allocator;
const limit = 64;

pub const Entry = struct {
    key: p.ToolDisplayKey,
    caption: presentation.Caption,
    ready: bool,
    order: usize,
};

pub const Views = struct {
    generation: ?u64 = null,
    entries: std.ArrayList(Entry) = .empty,
    ready_count: usize = 0,

    pub fn begin(self: *Views, a: Allocator, generation: u64) void {
        self.clear(a);
        self.generation = generation;
    }

    pub fn discard(self: *Views, a: Allocator, generation: u64) void {
        if (self.matches(generation)) self.clear(a);
    }

    pub fn commit(self: *Views, a: Allocator, generation: u64) void {
        if (!self.matches(generation)) return;
        var kept: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.ready) {
                self.entries.items[kept] = entry;
                kept += 1;
            } else entry.caption.deinit(a);
        }
        self.entries.items.len = kept;
        // At most 64 entries; ready order follows first canonical-ready arrival,
        // never protocol index or provisional arrival order.
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, left: Entry, right: Entry) bool {
                return left.order < right.order;
            }
        }.lessThan);
    }

    pub fn upsert(self: *Views, a: Allocator, event: r.ToolView) !void {
        if (!self.matches(event.key.generation)) return;
        const index = self.find(event.key);
        if (index) |i| {
            if (self.entries.items[i].ready and !event.ready) return;
        } else if (self.entries.items.len == limit and (!event.ready or self.ready_count == limit)) return;

        // Build all fallible state first. Neither an OOM during formatting nor
        // append failure may destroy the previously displayed caption/order.
        const candidate = try presentation.fromToolView(a, event.name, event.fields);
        errdefer candidate.deinit(a);
        if (index) |i| {
            const entry = &self.entries.items[i];
            const became_ready = !entry.ready and event.ready;
            const old = entry.caption;
            entry.caption = candidate;
            entry.ready = event.ready;
            if (became_ready) entry.order = self.nextOrder();
            old.deinit(a);
        } else {
            const entry: Entry = .{
                .key = event.key,
                .caption = candidate,
                .ready = event.ready,
                .order = if (event.ready) self.ready_count else limit,
            };
            if (self.entries.items.len == limit) {
                // Canonical calls outrank unconfirmed metadata. A full set of
                // provisional rows must not hide a final-only/rebound call.
                var last = self.entries.items.len;
                while (last != 0) {
                    last -= 1;
                    if (!self.entries.items[last].ready) break;
                }
                const withdrawn = self.entries.orderedRemove(last);
                withdrawn.caption.deinit(a);
                self.entries.appendAssumeCapacity(entry);
            } else try self.entries.append(a, entry);
            if (event.ready) _ = self.nextOrder();
        }
    }

    pub fn get(self: *const Views, identity: p.ToolDisplayKey) ?*const Entry {
        const index = self.find(identity) orelse return null;
        return &self.entries.items[index];
    }

    pub fn remove(self: *Views, a: Allocator, identity: p.ToolDisplayKey) void {
        const index = self.find(identity) orelse return;
        const entry = self.entries.orderedRemove(index);
        entry.caption.deinit(a);
        if (entry.ready) {
            self.ready_count -= 1;
            // Keep ready ranks dense: repeated remove/insert cycles cannot
            // overflow a counter or give two ready entries the same order.
            for (self.entries.items) |*other| {
                if (other.ready and other.order > entry.order) other.order -= 1;
            }
        }
    }

    pub fn cloneReadyCaption(self: *const Views, a: Allocator, identity: p.ToolDisplayKey) !?presentation.Caption {
        const entry = self.get(identity) orelse return null;
        if (!entry.ready) return null;
        var copy = entry.caption;
        copy.label = try a.dupe(u8, entry.caption.label);
        // These are renderer-owned numeric offsets / a static allowlisted
        // reason, not additional owned allocations or borrowed argument text.
        return copy;
    }

    pub fn clear(self: *Views, a: Allocator) void {
        for (self.entries.items) |entry| entry.caption.deinit(a);
        self.entries.clearRetainingCapacity();
        self.generation = null;
        self.ready_count = 0;
    }

    pub fn deinit(self: *Views, a: Allocator) void {
        self.clear(a);
        self.entries.deinit(a);
        self.* = .{};
    }

    fn matches(self: *const Views, generation: u64) bool {
        return if (self.generation) |active| active == generation else false;
    }

    fn find(self: *const Views, identity: p.ToolDisplayKey) ?usize {
        if (!self.matches(identity.generation)) return null;
        for (self.entries.items, 0..) |entry, i| {
            if (entry.key.eql(identity)) return i;
        }
        return null;
    }

    fn nextOrder(self: *Views) usize {
        std.debug.assert(self.ready_count < limit);
        const order = self.ready_count;
        self.ready_count += 1;
        return order;
    }
};

fn key(generation: u64, index: usize) p.ToolDisplayKey {
    return .{ .generation = generation, .index = index };
}

fn view(generation: u64, index: usize, label: []const u8, ready: bool) r.ToolView {
    return .{
        .key = key(generation, index),
        .name = "read_file",
        .fields = .{ .path = .{ .text = label } },
        .ready = ready,
    };
}

test "tool views same key updates in place and same names remain distinct" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 7);
    var label = [_]u8{ 'o', 'n', 'e' };
    try views.upsert(a, view(7, 12, &label, false));
    label[0] = 'X';
    try std.testing.expectEqualStrings("one", views.get(key(7, 12)).?.caption.label);
    const first = views.get(key(7, 12)).?;
    try views.upsert(a, view(7, 12, "new", false));
    try std.testing.expect(first == views.get(key(7, 12)).?);
    try std.testing.expectEqualStrings("new", first.caption.label);
    try views.upsert(a, view(7, 2, "other", false));
    try std.testing.expectEqual(@as(usize, 2), views.entries.items.len);
    try std.testing.expectEqualStrings("new", views.get(key(7, 12)).?.caption.label);
    try std.testing.expectEqualStrings("other", views.get(key(7, 2)).?.caption.label);
}

test "tool views require explicit begin and ignore stale generations and discard" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    try views.upsert(a, view(1, 0, "ignored", true));
    try std.testing.expectEqual(@as(usize, 0), views.entries.items.len);
    views.begin(a, 1);
    try views.upsert(a, view(1, 0, "old", true));
    const capacity = views.entries.capacity;
    views.begin(a, 2);
    try std.testing.expectEqual(capacity, views.entries.capacity);
    try views.upsert(a, view(2, 0, "new", false));
    views.discard(a, 1);
    views.commit(a, 1);
    try views.upsert(a, view(1, 0, "late", true));
    try std.testing.expect(views.get(key(1, 0)) == null);
    try std.testing.expectEqualStrings("new", views.get(key(2, 0)).?.caption.label);
    views.discard(a, 2);
    try std.testing.expect(views.generation == null);
    try views.upsert(a, view(2, 0, "late after discard", true));
    try std.testing.expectEqual(@as(usize, 0), views.entries.items.len);
}

test "tool views ready resists provisional rollback commit sorts and prunes" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 1);
    try views.upsert(a, view(1, 9, "nine", false));
    try views.upsert(a, view(1, 0, "zero", false));
    try views.upsert(a, view(1, 5, "prune", false));
    try std.testing.expect((try views.cloneReadyCaption(a, key(1, 9))) == null);
    try views.upsert(a, view(1, 0, "first ready", true));
    try views.upsert(a, view(1, 9, "second ready", true));
    try views.upsert(a, view(1, 0, "late provisional", false));
    try views.upsert(a, view(1, 0, "ready update", true));
    try std.testing.expectEqual(@as(usize, 2), views.ready_count);
    views.commit(a, 1);
    try std.testing.expectEqual(@as(usize, 2), views.entries.items.len);
    try std.testing.expect(views.entries.items[0].key.eql(key(1, 0)));
    try std.testing.expect(views.entries.items[1].key.eql(key(1, 9)));
    try std.testing.expectEqualStrings("ready update", views.entries.items[0].caption.label);
    try std.testing.expect(views.get(key(1, 5)) == null);
    views.commit(a, 1);
    try std.testing.expectEqual(@as(usize, 2), views.entries.items.len);
}

test "tool views cloned caption owns label and preserves renderer metadata" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 3);
    try views.upsert(a, view(3, 0, "source", true));
    const marks: presentation.WriteMarks = .{
        .added = .{ .start = 0, .end = 1 },
        .removed = .{ .start = 2, .end = 3 },
    };
    views.entries.items[0].caption.write_marks = marks;
    views.entries.items[0].caption.failure_reason = "static reason";
    const original = views.get(key(3, 0)).?.caption;
    const clone = (try views.cloneReadyCaption(a, key(3, 0))).?;
    defer clone.deinit(a);
    try std.testing.expect(original.label.ptr != clone.label.ptr);
    try std.testing.expectEqual(original.kind, clone.kind);
    try std.testing.expectEqualDeep(original.write_marks, clone.write_marks);
    try std.testing.expectEqualStrings("static reason", clone.failure_reason.?);
    try views.upsert(a, view(3, 0, "replacement", true));
    views.remove(a, key(3, 0));
    try std.testing.expectEqualStrings("source", clone.label);
    try std.testing.expect((try views.cloneReadyCaption(a, key(3, 0))) == null);
    try std.testing.expectEqual(@as(usize, 0), views.ready_count);
}

test "tool views cap ignores only new entries and remove keeps bounded ready order" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 4);
    for (0..limit) |i| try views.upsert(a, view(4, i, "row", true));
    try views.upsert(a, view(4, limit, "ignored", true));
    try std.testing.expectEqual(@as(usize, limit), views.entries.items.len);
    try std.testing.expectEqual(@as(usize, limit), views.ready_count);
    try views.upsert(a, view(4, 0, "updated at cap", true));
    try std.testing.expectEqualStrings("updated at cap", views.get(key(4, 0)).?.caption.label);
    for (0..128) |_| {
        views.remove(a, key(4, 0));
        views.remove(a, key(999, 1));
        try views.upsert(a, view(4, 0, "reinserted", true));
        try std.testing.expectEqual(@as(usize, limit), views.ready_count);
        try std.testing.expectEqual(@as(usize, limit - 1), views.get(key(4, 0)).?.order);
    }
    views.commit(a, 4);
    for (views.entries.items, 0..) |entry, i| try std.testing.expectEqual(i, entry.order);
    views.remove(a, key(4, 0));
    views.remove(a, key(4, 0));
    try std.testing.expectEqual(@as(usize, limit - 1), views.ready_count);
    views.clear(a);
    try std.testing.expect(views.entries.capacity >= limit);
    try std.testing.expect(views.generation == null);
    try std.testing.expectEqual(@as(usize, 0), views.ready_count);
    views.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), views.entries.capacity);
}

test "canonical ready row replaces provisional metadata at the display cap" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 5);
    for (0..limit) |i| try views.upsert(a, view(5, i, "provisional", false));
    try views.upsert(a, view(5, limit, "authoritative", true));
    try std.testing.expectEqual(@as(usize, limit), views.entries.items.len);
    try std.testing.expect(views.get(key(5, limit)).?.ready);
    try std.testing.expectEqual(@as(usize, 1), views.ready_count);
    views.commit(a, 5);
    try std.testing.expectEqual(@as(usize, 1), views.entries.items.len);
    try std.testing.expectEqualStrings("authoritative", views.entries.items[0].caption.label);
}

fn allocationScenario(a: Allocator) !void {
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 1);
    views.upsert(a, view(1, 0, "old", false)) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), views.entries.items.len);
        try std.testing.expectEqual(@as(usize, 0), views.ready_count);
        return err;
    };
    const label_before = views.get(key(1, 0)).?.caption.label;
    views.upsert(a, view(1, 0, "ready", true)) catch |err| {
        const old = views.get(key(1, 0)).?;
        try std.testing.expect(!old.ready);
        try std.testing.expect(old.caption.label.ptr == label_before.ptr);
        try std.testing.expectEqualStrings("old", old.caption.label);
        try std.testing.expectEqual(@as(usize, 0), views.ready_count);
        return err;
    };
    views.upsert(a, view(1, 1, "second", true)) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), views.entries.items.len);
        try std.testing.expectEqual(@as(usize, 1), views.ready_count);
        try std.testing.expectEqualStrings("ready", views.get(key(1, 0)).?.caption.label);
        return err;
    };
    const clone = (views.cloneReadyCaption(a, key(1, 0)) catch |err| {
        try std.testing.expectEqualStrings("ready", views.get(key(1, 0)).?.caption.label);
        try std.testing.expectEqual(@as(usize, 2), views.ready_count);
        return err;
    }).?;
    defer clone.deinit(a);
    try std.testing.expect(clone.label.ptr != views.get(key(1, 0)).?.caption.label.ptr);
    views.clear(a);
    try std.testing.expectEqualStrings("ready", clone.label);
}

fn growthScenario(a: Allocator) !void {
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 5);
    try views.upsert(a, view(5, 0, "first", true));
    const initial_capacity = views.entries.capacity;
    try std.testing.expect(initial_capacity < limit);
    for (1..initial_capacity) |i| try views.upsert(a, view(5, i, "existing", true));
    const label_before = views.entries.items[0].caption.label;
    views.upsert(a, view(5, initial_capacity, "growing", true)) catch |err| {
        try std.testing.expectEqual(initial_capacity, views.entries.items.len);
        try std.testing.expectEqual(initial_capacity, views.ready_count);
        try std.testing.expect(label_before.ptr == views.entries.items[0].caption.label.ptr);
        try std.testing.expectEqualStrings("first", views.entries.items[0].caption.label);
        return err;
    };
    try std.testing.expectEqual(initial_capacity + 1, views.ready_count);
}

test "tool views upsert and clone allocation failures preserve ownership and state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, growthScenario, .{});
}
