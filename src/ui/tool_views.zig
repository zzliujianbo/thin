//! Owned, generation-scoped display captions only. No canonical/history effects.
//! get() borrows an entry only for the duration of the caller's operation;
//! subsequent mutations may replace its caption or move the entry.
const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const presentation = @import("presentation.zig");
const write_preview = @import("../core/write_preview.zig");
const Allocator = std.mem.Allocator;
const limit = 64;

pub const Entry = struct {
    key: p.ToolDisplayKey,
    caption: presentation.Caption,
    ready: bool,
    write_progress: ?write_preview.Progress = null,
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
        const plain = try presentation.fromToolView(a, event.name, event.fields);
        // A later ready refresh without metadata must not revert a guarded
        // caption back to the raw preview or discard its value-owned metadata.
        const display = event.display orelse if (index) |i| self.entries.items[i].caption.display else null;
        const base = if (display) |metadata| blk: {
            defer plain.deinit(a);
            break :blk try presentation.withBackground(a, plain, metadata);
        } else plain;
        const candidate = if (event.ready and event.subagent_progress != null) blk: {
            defer base.deinit(a);
            break :blk try presentation.subagentProgress(a, base, event.subagent_progress.?);
        } else base;
        errdefer candidate.deinit(a);
        if (index) |i| {
            const entry = &self.entries.items[i];
            const became_ready = !entry.ready and event.ready;
            const old = entry.caption;
            entry.caption = candidate;
            entry.ready = event.ready;
            if (event.write_progress) |progress| {
                const old_known = if (entry.write_progress) |old_progress| old_progress.added != null and old_progress.deleted != null else false;
                const new_known = progress.added != null and progress.deleted != null;
                if (!old_known or new_known) entry.write_progress = progress;
            }
            if (became_ready) entry.order = self.nextOrder();
            old.deinit(a);
        } else {
            const entry: Entry = .{
                .key = event.key,
                .caption = candidate,
                .ready = event.ready,
                .write_progress = event.write_progress,
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
