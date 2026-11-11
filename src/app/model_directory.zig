//! Bounded by-value metadata. Keys are owned bytes addressed by offsets; no
//! record or reasoning profile borrows storage from a parser or another copy.
const std = @import("std");
const providers = @import("../core/providers.zig");
const thinking = @import("../core/thinking.zig");
const Protocol = @import("../core/protocol.zig").Protocol;

pub const max_models = 1536;
pub const max_name_bytes = 128 * 1024;
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
    offset: u32,
    len: u16,
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
    if (id.len == 0 or id.len > 256 or std.mem.trim(u8, id, " \t\r\n").len == 0) return error.InvalidMetadata;
    for (id) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidMetadata;
}

pub const Directory = struct {
    count: usize = 0,
    used: usize = 0,
    rows: [max_models]Record = undefined,
    names: [max_name_bytes]u8 = undefined,

    pub fn upsert(self: *Directory, provider: providers.Id, id: []const u8) !*Record {
        try validateId(id);
        if (self.find(provider, id)) |index| return &self.rows[index];
        const slug = provider.slug();
        const len = slug.len + 1 + id.len;
        if (self.count >= max_models or len > max_name_bytes - self.used) return error.MetadataTooLarge;
        const offset = self.used;
        @memcpy(self.names[offset..][0..slug.len], slug);
        self.names[offset + slug.len] = '/';
        @memcpy(self.names[offset + slug.len + 1 ..][0..id.len], id);
        self.rows[self.count] = .{ .provider = provider, .offset = @intCast(offset), .len = @intCast(len) };
        self.used += len;
        self.count += 1;
        return &self.rows[self.count - 1];
    }

    /// Exact raw ID lookup. A slash inside a raw ID is not a selector separator.
    pub fn find(self: *const Directory, provider: providers.Id, id: []const u8) ?usize {
        for (self.rows[0..self.count], 0..) |row, index| {
            if (row.provider == provider and std.mem.eql(u8, self.name(index), id)) return index;
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

    pub fn copyRecord(self: *Directory, other: *const Directory, index: usize) !void {
        const source = other.rows[index];
        const dest = try self.upsert(source.provider, other.name(index));
        const offset = dest.offset;
        const len = dest.len;
        dest.* = source;
        dest.offset = offset;
        dest.len = len;
    }
};
