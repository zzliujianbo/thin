//! Bounded display-only streaming state. Never owns canonical arguments or IDs.
const std = @import("std");
const p = @import("protocol.zig");
const preview = @import("tool_preview.zig");
pub const limit = 64;
pub const View = struct { key: p.ToolDisplayKey, name: []const u8, fields: preview.Snapshot = .{}, ready: bool = false };
pub const Digest = [32]u8;
pub fn digest(id: []const u8) Digest {
    var out: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &out, .{});
    return out;
}
pub const Links = struct {
    generation: u64 = 0,
    entries: [limit]struct { hash: ?Digest, key: p.ToolDisplayKey } = undefined,
    len: usize = 0,
    pub fn lookup(self: *const Links, id: []const u8) ?p.ToolDisplayKey {
        const hash = digest(id);
        for (self.entries[0..self.len]) |entry| if (entry.hash) |known| {
            if (std.mem.eql(u8, &hash, &known)) return entry.key;
        };
        return null;
    }
    pub fn fresh(self: *const Links, chosen: []const p.ToolDisplayKey) p.ToolDisplayKey {
        var index: usize = 0;
        outer: while (true) : (index += 1) {
            for (self.entries[0..self.len]) |entry| if (entry.key.index == index) continue :outer;
            for (chosen) |key| if (key.index == index) continue :outer;
            return .{ .generation = self.generation, .index = index };
        }
    }
};
pub const Controller = struct {
    const Slot = struct {
        index: usize,
        hash: ?Digest = null,
        extractor: preview.Extractor = .{},
    };
    generation: u64,
    schemas: []const p.ToolSchema,
    slots: [limit]Slot = undefined,
    len: usize = 0,
    pub fn observe(self: *Controller, delta: @FieldType(p.ModelEvent, "tool_delta")) ?View {
        var slot: ?*Slot = null;
        for (self.slots[0..self.len]) |*candidate| if (candidate.index == delta.index) {
            slot = candidate;
            break;
        };
        if (slot == null) {
            if (self.len == limit) return null;
            self.slots[self.len] = .{ .index = delta.index };
            slot = &self.slots[self.len];
            self.len += 1;
        }
        const current = slot.?;
        if (delta.call_id) |id| if (id.len != 0) {
            const hash = digest(id);
            // Conflicting identity cannot reuse previously extracted fields.
            if (current.hash) |old| {
                if (!std.mem.eql(u8, &old, &hash)) current.extractor = .{};
            }
            current.hash = hash;
        };
        current.extractor.feed(delta.arguments);
        for (self.schemas) |schema| if (std.mem.eql(u8, schema.name, delta.name)) {
            return .{ .key = .{ .generation = self.generation, .index = delta.index }, .name = schema.name, .fields = current.extractor.snapshot() };
        };
        return null;
    }
    pub fn links(self: *const Controller) Links {
        var result: Links = .{ .generation = self.generation };
        // Reserve even anonymous preview indices: a final-only call must not
        // steal an unconfirmed stream row's identity before commit prunes it.
        for (self.slots[0..self.len]) |slot| {
            result.entries[result.len] = .{ .hash = slot.hash, .key = .{ .generation = self.generation, .index = slot.index } };
            result.len += 1;
        }
        return result;
    }
};

test "stream links use complete ids not name or canonical ordinal" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .generation = 7, .schemas = &.{.{ .name = "read_file", .description = "", .parameters_json = "{}" }} };
    try t.expect(c.observe(.{ .index = 19, .name = "read_", .arguments = "{\"path\":", .call_id = "one" }) == null);
    const v = c.observe(.{ .index = 19, .name = "read_file", .arguments = "\"a\"}", .call_id = "one" }).?;
    try t.expectEqualStrings("a", v.fields.path.?.text);
    _ = c.observe(.{ .index = 4, .name = "read_file", .arguments = "{}", .call_id = "two" });
    const links = c.links();
    try t.expectEqual(@as(usize, 19), links.lookup("one").?.index);
    try t.expectEqual(@as(usize, 4), links.lookup("two").?.index);
    try t.expect(links.lookup("missing") == null);
    try t.expectEqual(@as(usize, 0), links.fresh(&.{}).index);
}

test "stream final-only keys cannot collide with anonymous preview indices" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .generation = 3, .schemas = &.{} };
    _ = c.observe(.{ .index = 0, .arguments = "{}" });
    const links = c.links();
    try t.expect(links.lookup("final") == null);
    try t.expectEqual(@as(usize, 1), links.fresh(&.{}).index);
    try t.expectEqual(@as(usize, 2), links.fresh(&.{.{ .generation = 3, .index = 1 }}).index);
}

test "stream hashes full ids beyond a shared large prefix" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .generation = 1, .schemas = &.{} };
    const id = try t.allocator.alloc(u8, 100000);
    defer t.allocator.free(id);
    @memset(id, 'a');
    id[id.len - 1] = 'x';
    _ = c.observe(.{ .index = 90, .arguments = "{}", .call_id = id });
    id[id.len - 1] = 'y';
    _ = c.observe(.{ .index = 91, .arguments = "{}", .call_id = id });
    const links = c.links();
    try t.expectEqual(@as(usize, 91), links.lookup(id).?.index);
    id[id.len - 1] = 'x';
    try t.expectEqual(@as(usize, 90), links.lookup(id).?.index);
    try t.expectEqual(@as(usize, 2), links.len);
}

test "stream controller caps previews and generations isolate reused indices" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .generation = 8, .schemas = &.{.{ .name = "bash", .description = "", .parameters_json = "{}" }} };
    for (0..limit) |index| try t.expect(c.observe(.{ .index = index, .name = "bash", .arguments = "{}" }) != null);
    try t.expect(c.observe(.{ .index = limit, .name = "bash", .arguments = "{}" }) == null);
    c.* = .{ .generation = 9, .schemas = c.schemas };
    try t.expectEqual(@as(u64, 9), c.observe(.{ .index = 0, .name = "bash", .arguments = "{}" }).?.key.generation);
}
