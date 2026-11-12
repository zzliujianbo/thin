//! Bounded by-value metadata. Keys are owned bytes addressed by offsets; no
//! record or reasoning profile borrows storage from a parser or another copy.
const std = @import("std");
const providers = @import("../core/providers.zig");
const thinking = @import("../core/thinking.zig");
const Protocol = @import("../core/protocol.zig").Protocol;

const level_names = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "max" };

pub const OffWire = enum { absent, off, none, disabled };

/// Only canonical metadata wire values can enter this pointer-free structure.
pub const Profile = struct {
    format: thinking.Format,
    levels: u8,
    off_wire: OffWire = .absent,

    pub fn from(value: thinking.Declaration) !Profile {
        try value.validate();
        var result: Profile = .{ .format = value.format, .levels = 0 };
        if (value.map.off) |wire| {
            result.off_wire = switch (value.format) {
                .deepseek => if (std.mem.eql(u8, wire, "off")) .off else return error.InvalidMetadata,
                .anthropic => if (std.mem.eql(u8, wire, "disabled")) .disabled else return error.InvalidMetadata,
                .standard => if (std.mem.eql(u8, wire, "off")) .off else if (std.mem.eql(u8, wire, "none")) .none else return error.InvalidMetadata,
            };
            result.levels |= 1;
        }
        inline for (level_names[1..], 1..) |field, index| {
            if (@field(value.map, field)) |wire| {
                if (!std.mem.eql(u8, wire, field)) return error.InvalidMetadata;
                result.levels |= @as(u8, 1) << @intCast(index);
            }
        }
        return result;
    }

    pub fn declaration(self: Profile) thinking.Declaration {
        var result: thinking.Declaration = .{ .format = self.format, .map = .{} };
        if (self.levels & 1 != 0) result.map.off = switch (self.off_wire) {
            .absent => null,
            .off => "off",
            .none => "none",
            .disabled => "disabled",
        };
        inline for (level_names[1..], 1..) |field, index| {
            if (self.levels & (@as(u8, 1) << @intCast(index)) != 0) @field(result.map, field) = field;
        }
        return result;
    }
};

pub const Record = struct {
    provider: providers.Id,
    offset: usize,
    len: usize,
    next_hash: ?usize = null,
    tokens: ?u32 = null,
    output_tokens: ?u32 = null,
    dev_output_tokens: ?u32 = null,
    /// Exact models.dev limit.context; never an official window.
    dev_context_tokens: ?u32 = null,
    /// Earliest exact-route public context price increase; not a context window.
    dev_input_price_threshold: ?u32 = null,
    /// Verified span with no context input-price increase; not inferred from absence.
    dev_input_price_flat_limit: ?u32 = null,
    available: ?bool = null,
    /// Null means input modalities were not advertised or were malformed.
    input_image: ?bool = null,
    default_reasoning: ?@import("../presentation/activity.zig").ReasoningEffort = null,
    protocol: Protocol = .auto,
    dev_protocol: Protocol = .auto,
    reasoning: ?Profile = null,
    dev_reasoning: ?Profile = null,
    dev_present: bool = false,
};

pub fn validateId(id: []const u8) !void {
    if (id.len == 0 or std.mem.trim(u8, id, " \t\r\n").len == 0) return error.InvalidMetadata;
    for (id) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidMetadata;
}

pub const Directory = struct {
    count: usize = 0,
    used: usize = 0,
    rows: []Record = &.{},
    names: []u8 = &.{},
    index: std.AutoHashMapUnmanaged(u64, usize) = .empty,

    fn growth(current: usize, needed: usize) usize {
        const extra = current / 2 + 1;
        const expanded = std.math.add(usize, current, extra) catch needed;
        return @max(needed, expanded);
    }

    fn keyHash(provider: providers.Id, id: []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(provider.slug());
        h.update("/");
        h.update(id);
        return h.final();
    }

    pub fn deinit(self: *Directory, a: std.mem.Allocator) void {
        a.free(self.rows);
        a.free(self.names);
        self.index.deinit(a);
        self.* = .{};
    }

    pub fn clone(self: *const Directory, a: std.mem.Allocator) !Directory {
        const rows = try a.dupe(Record, self.rows[0..self.count]);
        errdefer a.free(rows);
        const names = try a.dupe(u8, self.names[0..self.used]);
        errdefer a.free(names);
        return .{ .rows = rows, .names = names, .index = try self.index.clone(a), .count = self.count, .used = self.used };
    }

    pub fn upsert(self: *Directory, a: std.mem.Allocator, provider: providers.Id, id: []const u8) !*Record {
        try validateId(id);
        if (self.find(provider, id)) |index| return &self.rows[index];
        const slug = provider.slug();
        const len = try std.math.add(usize, try std.math.add(usize, slug.len, 1), id.len);
        const new_used = try std.math.add(usize, self.used, len);
        const new_count = try std.math.add(usize, self.count, 1);
        const hash = keyHash(provider, id);
        try self.index.ensureUnusedCapacity(a, 1);
        if (new_used > self.names.len) self.names = try a.realloc(self.names, growth(self.names.len, new_used));
        if (new_count > self.rows.len) self.rows = try a.realloc(self.rows, growth(self.rows.len, new_count));
        const offset = self.used;
        @memcpy(self.names[offset..][0..slug.len], slug);
        self.names[offset + slug.len] = '/';
        @memcpy(self.names[offset + slug.len + 1 ..][0..id.len], id);
        self.rows[self.count] = .{ .provider = provider, .offset = offset, .len = len, .next_hash = self.index.get(hash) };
        self.index.putAssumeCapacity(hash, self.count);
        self.used = new_used;
        self.count = new_count;
        return &self.rows[self.count - 1];
    }

    /// Exact raw ID lookup. A slash inside a raw ID is not a selector separator.
    pub fn find(self: *const Directory, provider: providers.Id, id: []const u8) ?usize {
        var next = self.index.get(keyHash(provider, id));
        while (next) |index| {
            const row = self.rows[index];
            if (row.provider == provider and std.mem.eql(u8, self.name(index), id)) return index;
            next = row.next_hash;
        }
        return null;
    }

    pub fn selector(self: *const Directory, index: usize) []const u8 {
        const row = self.rows[index];
        return self.names[row.offset..][0..row.len];
    }

    pub fn name(self: *const Directory, index: usize) []const u8 {
        return self.selector(index)[self.rows[index].provider.slug().len + 1 ..];
    }

    pub fn copyRecord(self: *Directory, a: std.mem.Allocator, other: *const Directory, index: usize) !void {
        const source = other.rows[index];
        const dest = try self.upsert(a, source.provider, other.name(index));
        const offset = dest.offset;
        const len = dest.len;
        const next_hash = dest.next_hash;
        dest.* = source;
        dest.offset = offset;
        dest.len = len;
        dest.next_hash = next_hash;
    }
};
