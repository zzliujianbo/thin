//! Bounded display-only streaming state. Never owns canonical arguments or IDs.
const std = @import("std");
const p = @import("protocol.zig");
const preview = @import("tool_preview.zig");
const write_preview = @import("write_preview.zig");
pub const limit = 64;
const tracker_limit = 8;

pub const View = struct {
    key: p.ToolDisplayKey,
    name: []const u8,
    fields: preview.Snapshot = .{},
    write_progress: ?write_preview.Progress = null,
    ready: bool = false,
};
pub const Digest = [32]u8;
pub fn digest(value: []const u8) Digest {
    var out: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &out, .{});
    return out;
}

pub const Link = struct { key: p.ToolDisplayKey, write_progress: ?write_preview.Progress = null };
pub const Links = struct {
    generation: u64 = 0,
    entries: [limit]struct { hash: ?Digest, arguments: Digest, key: p.ToolDisplayKey, write_progress: ?write_preview.Progress } = undefined,
    len: usize = 0,
    pub fn lookup(self: *const Links, id: []const u8, arguments: []const u8) ?Link {
        const hash = digest(id);
        const args = digest(arguments);
        for (self.entries[0..self.len]) |entry| if (entry.hash) |known| {
            if (std.mem.eql(u8, &hash, &known) and std.mem.eql(u8, &args, &entry.arguments))
                return .{ .key = entry.key, .write_progress = entry.write_progress };
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

pub const BaselineRequest = struct { index: usize, path: []const u8 };

pub const Controller = struct {
    const Slot = struct {
        index: usize,
        hash: ?Digest = null,
        extractor: preview.Extractor = .{},
        arguments: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
        tracker: ?*write_preview.Tracker = null,
        write_name: bool = false,
        baseline_attempted: bool = false,
    };
    allocator: std.mem.Allocator,
    generation: u64,
    schemas: []const p.ToolSchema,
    slots: [limit]Slot = undefined,
    len: usize = 0,
    tracker_count: usize = 0,

    pub fn deinit(self: *Controller) void {
        for (self.slots[0..self.len]) |*slot| self.releaseTracker(slot);
    }

    fn releaseTracker(self: *Controller, slot: *Slot) void {
        if (slot.tracker) |tracker| {
            tracker.deinit();
            self.allocator.destroy(tracker);
            slot.tracker = null;
            self.tracker_count -= 1;
        }
    }

    fn resetSlot(self: *Controller, slot: *Slot) void {
        self.releaseTracker(slot);
        const index = slot.index;
        slot.* = .{ .index = index };
    }

    fn trackerScalar(ctx: *anyopaque, cp: u21) void {
        const tracker: *write_preview.Tracker = @ptrCast(@alignCast(ctx));
        tracker.scalar(cp);
    }
    fn trackerEnd(ctx: *anyopaque) void {
        const tracker: *write_preview.Tracker = @ptrCast(@alignCast(ctx));
        tracker.finish();
    }
    fn trackerRevoke(ctx: *anyopaque) void {
        const tracker: *write_preview.Tracker = @ptrCast(@alignCast(ctx));
        tracker.revoke();
    }

    fn ensureTracker(self: *Controller, slot: *Slot) void {
        if (slot.tracker != null or self.tracker_count == tracker_limit) return;
        const tracker = self.allocator.create(write_preview.Tracker) catch return;
        tracker.* = write_preview.Tracker.init(self.allocator);
        slot.tracker = tracker;
        self.tracker_count += 1;
        slot.extractor.attachContent(tracker, trackerScalar, trackerEnd, trackerRevoke);
        // Content decoded before the complete tool identity cannot be recovered.
        if (slot.extractor.seen[6]) tracker.revoke();
    }

    fn find(self: *Controller, index: usize) ?*Slot {
        for (self.slots[0..self.len]) |*candidate| if (candidate.index == index) return candidate;
        return null;
    }

    fn view(self: *Controller, slot: *Slot, name: []const u8) View {
        return .{
            .key = .{ .generation = self.generation, .index = slot.index },
            .name = name,
            .fields = slot.extractor.snapshot(),
            .write_progress = if (slot.write_name) if (slot.tracker) |tracker| tracker.progress() else write_preview.Progress.unknown() else null,
        };
    }

    pub fn observe(self: *Controller, delta: @FieldType(p.ModelEvent, "tool_delta")) ?View {
        var slot = self.find(delta.index);
        if (slot == null) {
            if (self.len == limit) return null;
            self.slots[self.len] = .{ .index = delta.index };
            slot = &self.slots[self.len];
            self.len += 1;
        }
        const current = slot.?;
        if (delta.call_id) |id| if (id.len != 0) {
            const hash = digest(id);
            if (current.hash) |old| if (!std.mem.eql(u8, &old, &hash)) self.resetSlot(current);
            current.hash = hash;
        };
        current.arguments.update(delta.arguments);
        var schema_name: ?[]const u8 = null;
        for (self.schemas) |schema| if (std.mem.eql(u8, schema.name, delta.name)) {
            schema_name = schema.name;
            break;
        };
        const current_is_write = delta.write_file or std.mem.eql(u8, delta.name, "write_file");
        if (current.write_name and !current_is_write) {
            current.write_name = false;
            if (current.tracker) |tracker| tracker.revoke();
        } else if (current_is_write and !current.write_name) {
            current.write_name = true;
            self.ensureTracker(current);
        }
        current.extractor.feed(delta.arguments);
        if (schema_name) |name| return self.view(current, name);
        return null;
    }

    pub fn takeBaselineRequest(self: *Controller, index: usize) ?BaselineRequest {
        const slot = self.find(index) orelse return null;
        if (!slot.write_name or slot.baseline_attempted) return null;
        const path = slot.extractor.snapshot().path orelse return null;
        if (path.truncated) {
            slot.baseline_attempted = true;
            if (slot.tracker) |tracker| tracker.revoke();
            return null;
        }
        slot.baseline_attempted = true;
        return .{ .index = index, .path = path.text };
    }

    pub fn resolveBaseline(self: *Controller, index: usize, baseline: ?write_preview.Baseline) ?View {
        const slot = self.find(index) orelse {
            if (baseline) |value_| {
                var value = value_;
                value.deinit();
            }
            return null;
        };
        if (slot.tracker) |tracker| {
            tracker.setBaseline(baseline);
        } else if (baseline) |value_| {
            var value = value_;
            value.deinit();
        }
        return self.view(slot, "write_file");
    }

    pub fn links(self: *Controller) Links {
        var result: Links = .{ .generation = self.generation };
        for (self.slots[0..self.len]) |*slot| {
            const valid = slot.extractor.finish();
            var args: Digest = undefined;
            var copy = slot.arguments;
            copy.final(&args);
            result.entries[result.len] = .{
                .hash = slot.hash,
                .arguments = args,
                .key = .{ .generation = self.generation, .index = slot.index },
                .write_progress = if (slot.write_name) if (valid) if (slot.tracker) |tracker| tracker.progress() else write_preview.Progress.unknown() else write_preview.Progress.unknown() else null,
            };
            result.len += 1;
        }
        return result;
    }
};

test "stream task summary is previewed without the context body" {
    const t = std.testing;
    var c: Controller = .{ .allocator = t.allocator, .generation = 5, .schemas = &.{.{ .name = "subagent", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    const view = c.observe(.{ .index = 0, .name = "subagent", .arguments = "{\"task\":\"check release paths\",\"context\":\"secret-parent-note\"}" }).?;
    try t.expectEqualStrings("check release paths", view.fields.task.?.text);
    try t.expect(view.fields.path == null and view.fields.command == null);
}

test "stream job id is previewed while message body stays hidden" {
    const t = std.testing;
    var c: Controller = .{ .allocator = t.allocator, .generation = 5, .schemas = &.{.{ .name = "send_subagent_message", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    const view = c.observe(.{ .index = 0, .name = "send_subagent_message", .arguments = "{\"id\":\"job-9\",\"message\":\"private-body\"}" }).?;
    try t.expectEqualStrings("job-9", view.fields.id.?.text);
    try t.expect(view.fields.task == null and view.fields.path == null);
}

test "stream links require complete ids and raw arguments" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 7, .schemas = &.{.{ .name = "read_file", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    try t.expect(c.observe(.{ .index = 19, .name = "read_", .arguments = "{\"path\":", .call_id = "one" }) == null);
    const v = c.observe(.{ .index = 19, .name = "read_file", .arguments = "\"a\"}", .call_id = "one" }).?;
    try t.expectEqualStrings("a", v.fields.path.?.text);
    const links = c.links();
    try t.expectEqual(@as(usize, 19), links.lookup("one", "{\"path\":\"a\"}").?.key.index);
    try t.expect(links.lookup("one", "{\"path\":\"b\"}") == null);
    try t.expect(links.lookup("missing", "{\"path\":\"a\"}") == null);
}

test "stream write progress decodes content and binds canonical digest" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 3, .schemas = &.{.{ .name = "write_file", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    const first = c.observe(.{ .index = 2, .name = "write_file", .arguments = "{\"path\":\"x\",\"content\":\"a\\n", .call_id = "w" }).?;
    try t.expect(first.write_progress != null);
    const request = c.takeBaselineRequest(2).?;
    try t.expectEqualStrings("x", request.path);
    _ = c.resolveBaseline(2, try write_preview.Baseline.fromBytes(t.allocator, "old\n"));
    const final = c.observe(.{ .index = 2, .name = "write_file", .arguments = "b\"}", .call_id = "w" }).?;
    try t.expectEqualDeep(write_preview.Progress{ .added = 2, .deleted = 1 }, final.write_progress.?);
    const links = c.links();
    try t.expect(links.lookup("w", "{\"path\":\"x\",\"content\":\"a\\nb\"}") != null);
}

test "stream write invalid duplicate and late identity stay unknown" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 4, .schemas = &.{.{ .name = "write_file", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    _ = c.observe(.{ .index = 1, .name = "", .arguments = "{\"content\":\"lost\"", .call_id = "late" });
    const late = c.observe(.{ .index = 1, .name = "write_file", .arguments = ",\"path\":\"x\"}", .call_id = "late" }).?;
    try t.expect(late.write_progress != null and late.write_progress.?.added == null);

    _ = c.observe(.{ .index = 2, .name = "write_file", .arguments = "{\"path\":\"x\",\"content\":\"a\",", .call_id = "dup" });
    _ = c.resolveBaseline(2, try write_preview.Baseline.fromBytes(t.allocator, ""));
    const duplicate = c.observe(.{ .index = 2, .name = "write_file", .arguments = "\"content\":\"b\"}", .call_id = "dup" }).?;
    try t.expect(duplicate.write_progress.?.added == null);
    const links = c.links();
    try t.expect(links.lookup("late", "{\"content\":\"lost\",\"path\":\"x\"}").?.write_progress.?.added == null);
    try t.expect(links.lookup("dup", "{\"path\":\"x\",\"content\":\"a\",\"content\":\"b\"}").?.write_progress.?.added == null);
}

test "stream write identity revokes when accumulated name changes" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 9, .schemas = &.{.{ .name = "write_file", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    const first = c.observe(.{ .index = 3, .name = "write_file", .arguments = "{\"path\":\"x\",\"content\":\"a", .call_id = "id", .write_file = true }).?;
    try t.expect(first.write_progress != null);
    try t.expect(c.observe(.{ .index = 3, .name = "write_file_other", .arguments = "\"}", .call_id = "id", .write_file = false }) == null);
    const links = c.links();
    try t.expect(links.lookup("id", "{\"path\":\"x\",\"content\":\"a\"}").?.write_progress == null);
}

test "stream final-only keys cannot collide with anonymous preview indices" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 3, .schemas = &.{} };
    defer c.deinit();
    _ = c.observe(.{ .index = 0, .arguments = "{}" });
    const links = c.links();
    try t.expect(links.lookup("final", "{}") == null);
    try t.expectEqual(@as(usize, 1), links.fresh(&.{}).index);
}

test "stream controller caps previews and generations isolate reused indices" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 8, .schemas = &.{.{ .name = "bash", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    for (0..limit) |index| try t.expect(c.observe(.{ .index = index, .name = "bash", .arguments = "{}" }) != null);
    try t.expect(c.observe(.{ .index = limit, .name = "bash", .arguments = "{}" }) == null);
}
