//! Immutable refcounted checkpoint of rendered body rows, never canonical messages.
//!
//! A checkpoint is a chain of segments: each one owns only the rows newly
//! released by one growing frame, while its parent stays owned by the previous
//! checkpoint. Growing a suffix therefore copies just that suffix, not the whole
//! released prefix. Released segments are freed iteratively, so a 4096-row chain
//! cannot recurse in deinit. Row/byte bounds are unchanged.
const std = @import("std");

const max_rows = 4096;
const max_bytes = 4 * 1024 * 1024;

pub const Prefix = struct {
    node: *Node,
    /// Rows covered by this checkpoint (all segments, oldest to newest).
    row_count: usize,
    /// Styling/source bytes covered by this checkpoint.
    byte_count: usize,
    columns: usize,

    const Node = struct {
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        /// Only this segment's newly released rows.
        rows: []const []const u8,
        /// Absolute row index of rows[0] inside the checkpoint.
        start: usize,
        parent: ?*Node,
        refs: usize,
    };

    /// Bounds are checked before any allocation. Styling bytes are significant.
    pub fn capture(a: std.mem.Allocator, rows: []const []const u8, columns: usize) !?Prefix {
        if (rows.len > max_rows) return null;
        var bytes: usize = 0;
        for (rows) |row| {
            if (row.len > max_bytes - bytes) return null;
            bytes += row.len;
        }
        const node = try allocNode(a, 0, null, rows);
        return .{ .node = node, .row_count = rows.len, .byte_count = bytes, .columns = columns };
    }

    /// Append only `suffix` as a new segment shared with the existing checkpoint.
    /// A zero-length suffix is a reference clone with no allocation. A column
    /// change is not an extension, so callers fall back to `capture`.
    pub fn extend(self: *const Prefix, a: std.mem.Allocator, suffix: []const []const u8, columns: usize) !?Prefix {
        if (columns != self.columns or suffix.len > max_rows - self.row_count) return null;
        var bytes = self.byte_count;
        for (suffix) |row| {
            if (row.len > max_bytes - bytes) return null;
            bytes += row.len;
        }
        if (suffix.len == 0) {
            self.node.refs += 1;
            return .{ .node = self.node, .row_count = self.row_count, .byte_count = self.byte_count, .columns = columns };
        }
        const node = try allocNode(a, self.row_count, self.node, suffix);
        return .{ .node = node, .row_count = self.row_count + suffix.len, .byte_count = bytes, .columns = columns };
    }

    pub fn rowCount(self: *const Prefix) usize {
        return self.row_count;
    }

    pub fn byteCount(self: *const Prefix) usize {
        return self.byte_count;
    }

    /// Exact styled comparison over disjoint segments: each segment compares its
    /// own newly released source rows at its original absolute range.
    pub fn matches(self: *const Prefix, rows: []const []const u8, columns: usize) bool {
        if (columns != self.columns or rows.len < self.row_count) return false;
        var segment: ?*Node = self.node;
        while (segment) |node| {
            for (node.rows, rows[node.start..][0..node.rows.len]) |old, row| {
                if (!std.mem.eql(u8, old, row)) return false;
            }
            segment = node.parent;
        }
        return true;
    }

    /// Release one reference. Iterative: shared ancestors stop the walk, so a
    /// deep chain is teardown, not recursion.
    pub fn deinit(self: *Prefix) void {
        var segment: ?*Node = self.node;
        while (segment) |node| {
            if (node.refs > 1) {
                node.refs -= 1;
                break;
            }
            const parent = node.parent;
            const allocator = node.allocator;
            var arena = node.arena;
            arena.deinit();
            allocator.destroy(node);
            segment = parent;
        }
        self.* = undefined;
    }

    fn allocNode(a: std.mem.Allocator, start: usize, parent: ?*Node, rows: []const []const u8) !*Node {
        const node = try a.create(Node);
        node.* = .{
            .allocator = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .rows = &.{},
            .start = start,
            .parent = parent,
            .refs = 1,
        };
        errdefer {
            node.arena.deinit();
            a.destroy(node);
        }
        const arena = node.arena.allocator();
        const owned = try arena.alloc([]const u8, rows.len);
        for (rows, owned) |row, *copy| copy.* = try arena.dupe(u8, row);
        node.rows = owned;
        // The parent reference exists only once this whole segment succeeded.
        if (parent) |p| p.refs += 1;
        return node;
    }
};
