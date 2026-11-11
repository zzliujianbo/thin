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
    display: ?@import("background_status.zig").Caption = null,
    /// Borrowed display-only child activity, at most 2048 UTF-8 bytes.
    subagent_progress: ?[]const u8 = null,
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
