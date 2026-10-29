//! Bounded incremental lightweight Markdown body with ACK-owned checkpoints.
const std = @import("std");
const scanner = @import("whitelist.zig");
const engine = @import("whitelist_render.zig");
const Decoder = @import("../util/stream_text.zig").Decoder;
const Allocator = std.mem.Allocator;
pub const Row = engine.Row;
pub const Limit = enum { none, window, rows, memory, refs, ambiguity, containers };
pub const Stats = struct { renders: usize = 0, window_bytes: usize = 0, retired_bytes: usize = 0, rows_rendered: usize = 0, max_window_bytes: usize = 0, frozen_rows: usize = 0 };

pub const Body = struct {
    a: Allocator,
    columns: usize,
    source: std.ArrayList(u8) = .empty,
    base: usize = 0,
    state: scanner.State = .{},
    decoder: Decoder = .{},
    carry_len: usize = 0,
    held_cr: bool = false,
    finished: bool = false,
    pinned: bool = false,
    limit: Limit = .none,
    max_window_bytes: usize = 4096,
    max_rows: usize = 65536,
    stats: Stats = .{},
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    metadata: ?engine.Checkpoint = null,
    consumed: usize = 0,
    valid: bool = false,
    dirty: bool = false,

    pub fn create(a: Allocator, columns: usize) !*Body {
        const self = try a.create(Body);
        self.* = .{ .a = a, .columns = std.math.clamp(columns, 1, 512), .arena = std.heap.ArenaAllocator.init(a) };
        return self;
    }
    pub fn destroy(self: *Body) void {
        const a = self.a;
        self.source.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }
    pub fn windowBytes(self: *const Body) usize {
        return self.source.items.len;
    }
    pub fn pendingBytes(self: *const Body) usize {
        return self.source.items.len -| if (self.valid) self.consumed else 0;
    }
    pub fn acceptedSourceEnd(self: *const Body) usize {
        return self.base + self.source.items.len + @intFromBool(self.held_cr);
    }
    pub fn committedSourceEnd(self: *const Body) usize {
        return self.base;
    }
    pub fn visibleSourceEnd(self: *const Body) usize {
        return self.visibleSourceEndForRows(self.rows.len);
    }
    pub fn visibleSourceEndForRows(self: *const Body, count: usize) usize {
        if (!self.pinned or count == 0 or self.rows.len == 0) return self.base;
        return @max(self.base, self.rows[@min(count, self.rows.len) - 1].end);
    }
    pub fn hasPendingPresentation(_: *const Body) bool {
        return false;
    }
    pub fn hasMetadataProgress(self: *const Body) bool {
        return self.pinned and self.rows.len == 0 and self.metadata != null and self.metadata.?.end > self.base;
    }
    pub fn isDrained(self: *const Body) bool {
        return self.finished and self.limit == .none and self.source.items.len == 0 and self.carry_len == 0 and !self.held_cr;
    }
    pub fn columnCount(self: *const Body) usize {
        return self.columns;
    }
    pub fn visibleRows(self: *const Body) []const Row {
        return if (self.valid) self.rows else &.{};
    }
    pub fn releasePin(self: *Body) void {
        self.pinned = false;
        if (self.dirty) self.valid = false;
    }
    pub fn abort(self: *Body) void {
        self.pinned = false;
        self.valid = false;
    }
    pub fn resize(self: *Body, columns: usize) void {
        const n = std.math.clamp(columns, 1, 512);
        if (n != self.columns) {
            self.columns = n;
            self.abort();
        }
    }
    const Buffer = struct {
        a: Allocator,
        bytes: std.ArrayList(u8) = .empty,
        fn emit(self: *@This(), bytes: []const u8) anyerror!void {
            try self.bytes.appendSlice(self.a, bytes);
        }
    };
    pub fn append(self: *Body, raw: []const u8) !void {
        if (self.finished) return;
        var next = self.decoder;
        var buf: Buffer = .{ .a = self.a };
        defer buf.bytes.deinit(self.a);
        try next.feed(raw, &buf, Buffer.emit);
        try self.source.appendSlice(self.a, buf.bytes.items);
        self.decoder = next;
        self.carry_len = next.carry_len;
        self.held_cr = next.held_cr;
        if (self.pinned) self.dirty = true else self.valid = false;
    }
    pub fn finish(self: *Body) !void {
        if (self.finished) return;
        var next = self.decoder;
        var buf: Buffer = .{ .a = self.a };
        defer buf.bytes.deinit(self.a);
        try next.finish(&buf, Buffer.emit);
        try self.source.appendSlice(self.a, buf.bytes.items);
        self.decoder = next;
        self.carry_len = next.carry_len;
        self.held_cr = next.held_cr;
        self.finished = true;
        if (self.pinned) self.dirty = true else self.valid = false;
    }
    pub fn build(self: *Body) !void {
        if (self.pinned) return;
        if (!self.valid) {
            self.arena.deinit();
            self.arena = std.heap.ArenaAllocator.init(self.a);
            self.rows = &.{};
            self.metadata = null;
            const result = engine.render(self.arena.allocator(), self.source.items, self.base, self.state, self.finished, self.columns, true, .normal, self.max_window_bytes, self.max_rows) catch |err| {
                self.limit = if (err == error.OutOfMemory) .memory else .window;
                return err;
            };
            self.rows = result.rows;
            self.metadata = result.metadata;
            self.consumed = result.consumed;
            self.stats.renders += 1;
            self.stats.window_bytes += result.work;
            self.stats.max_window_bytes = @max(self.stats.max_window_bytes, result.work);
            self.stats.rows_rendered += result.rows.len;
            self.valid = true;
            self.dirty = false;
        }
        self.pinned = true;
    }
    pub fn releaseLimit(self: *Body, wanted: usize) usize {
        if (!self.pinned) return 0;
        var n: usize = 0;
        while (n < @min(wanted, self.rows.len) and self.rows[n].complete and self.rows[n].end > self.base) : (n += 1) {}
        return n;
    }
    pub fn commit(self: *Body, count: usize) !usize {
        if (!self.pinned) return 0;
        var cp: ?engine.Checkpoint = null;
        var n: usize = 0;
        if (count == 0 and self.hasMetadataProgress()) cp = self.metadata else {
            n = self.releaseLimit(count);
            if (n != 0) cp = .{ .end = self.rows[n - 1].end, .state = self.rows[n - 1].checkpoint };
        }
        if (cp) |checkpoint| {
            const cut = checkpoint.end - self.base;
            std.mem.copyForwards(u8, self.source.items[0 .. self.source.items.len - cut], self.source.items[cut..]);
            self.source.shrinkRetainingCapacity(self.source.items.len - cut);
            self.base = checkpoint.end;
            self.state = checkpoint.state;
            self.stats.retired_bytes += cut;
            self.stats.frozen_rows += n;
        }
        self.pinned = false;
        self.valid = false;
        return n;
    }
};
