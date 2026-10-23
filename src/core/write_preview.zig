//! Bounded display-only write diff preview. It retains only line fingerprints;
//! generated file content is never stored here and never becomes execution data.
const std = @import("std");
const line_stats = @import("../util/line_stats.zig");

pub const max_lines = 2048;
pub const max_cells = 1024 * 1024;

pub const Fingerprint = struct {
    digest: [16]u8,
    byte_len: u32,

    fn eql(a: Fingerprint, b: Fingerprint) bool {
        return a.byte_len == b.byte_len and std.mem.eql(u8, &a.digest, &b.digest);
    }
};

pub const Progress = struct {
    added: ?u64 = null,
    deleted: ?u64 = null,

    pub fn unknown() Progress {
        return .{};
    }
};

pub const Baseline = struct {
    allocator: std.mem.Allocator,
    lines: []Fingerprint,

    pub fn deinit(self: *Baseline) void {
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    pub fn fromBytes(a: std.mem.Allocator, bytes: []const u8) !?Baseline {
        if (bytes.len > line_stats.max_bytes or !std.unicode.utf8ValidateSlice(bytes)) return null;
        const count = line_stats.count(bytes);
        if (count > max_lines) return null;
        const lines = try a.alloc(Fingerprint, @intCast(count));
        errdefer a.free(lines);
        var start: usize = 0;
        var index: usize = 0;
        while (start < bytes.len) : (index += 1) {
            const end = if (std.mem.findScalar(u8, bytes[start..], '\n')) |offset| start + offset + 1 else bytes.len;
            lines[index] = fingerprint(bytes[start..end]);
            start = end;
        }
        return .{ .allocator = a, .lines = lines };
    }
};

fn fingerprint(bytes: []const u8) Fingerprint {
    var full: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &full, .{});
    return .{ .digest = full[0..16].*, .byte_len = @intCast(bytes.len) };
}

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    baseline: ?Baseline = null,
    lines: std.ArrayList(Fingerprint) = .empty,
    current: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    current_len: u32 = 0,
    bytes_seen: usize = 0,
    cells_spent: usize = 0,
    revision: u64 = 0,
    cached_revision: ?u64 = null,
    cached: Progress = .{},
    closed: bool = false,
    invalid: bool = false,

    pub fn init(a: std.mem.Allocator) Tracker {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *Tracker) void {
        if (self.baseline) |*value| value.deinit();
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn revoke(self: *Tracker) void {
        self.invalid = true;
        self.cached_revision = null;
    }

    pub fn setBaseline(self: *Tracker, baseline: ?Baseline) void {
        if (self.baseline != null or self.invalid) {
            if (baseline) |value_| {
                var value = value_;
                value.deinit();
            }
            return;
        }
        self.baseline = baseline;
        self.revision +%= 1;
        self.cached_revision = null;
    }

    pub fn scalar(self: *Tracker, cp: u21) void {
        if (self.invalid or self.closed) return;
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &bytes) catch {
            self.revoke();
            return;
        };
        if (self.bytes_seen + len > line_stats.max_bytes) {
            self.revoke();
            return;
        }
        self.bytes_seen += len;
        self.current.update(bytes[0..len]);
        self.current_len += @intCast(len);
        if (cp == '\n') self.commitLine();
        self.revision +%= 1;
        self.cached_revision = null;
    }

    pub fn finish(self: *Tracker) void {
        if (self.closed) return;
        self.closed = true;
        self.revision +%= 1;
        self.cached_revision = null;
    }

    fn commitLine(self: *Tracker) void {
        if (self.lines.items.len == max_lines) {
            self.revoke();
            return;
        }
        var full: [32]u8 = undefined;
        var copy = self.current;
        copy.final(&full);
        self.lines.append(self.allocator, .{ .digest = full[0..16].*, .byte_len = self.current_len }) catch {
            self.revoke();
            return;
        };
        self.current = std.crypto.hash.sha2.Sha256.init(.{});
        self.current_len = 0;
    }

    fn partial(self: *const Tracker) ?Fingerprint {
        if (self.current_len == 0) return null;
        var full: [32]u8 = undefined;
        var copy = self.current;
        copy.final(&full);
        return .{ .digest = full[0..16].*, .byte_len = self.current_len };
    }

    pub fn progress(self: *Tracker) Progress {
        if (self.invalid) return .unknown();
        if (self.cached_revision == self.revision) return self.cached;
        const old = if (self.baseline) |value| value.lines else return .unknown();
        const extra: usize = @intFromBool(self.partial() != null);
        const new_len = self.lines.items.len + extra;
        if (new_len > max_lines) {
            self.revoke();
            return .unknown();
        }
        if (old.len == 0) {
            self.cached = .{ .added = new_len, .deleted = 0 };
            self.cached_revision = self.revision;
            return self.cached;
        }
        if (new_len == 0) {
            self.cached = .{ .added = 0, .deleted = old.len };
            self.cached_revision = self.revision;
            return self.cached;
        }
        const cells = old.len * new_len;
        if (cells > max_cells or self.cells_spent > max_cells - cells) {
            self.revoke();
            return .unknown();
        }
        self.cells_spent += cells;
        const previous = self.allocator.alloc(u16, old.len + 1) catch {
            self.revoke();
            return .unknown();
        };
        defer self.allocator.free(previous);
        const current = self.allocator.alloc(u16, old.len + 1) catch {
            self.revoke();
            return .unknown();
        };
        defer self.allocator.free(current);
        @memset(previous, 0);
        var prev = previous;
        var next = current;
        const partial_line = self.partial();
        for (0..new_len) |i| {
            next[0] = 0;
            const line = if (i < self.lines.items.len) self.lines.items[i] else partial_line.?;
            for (old, 0..) |old_line, j| {
                next[j + 1] = if (line.eql(old_line)) prev[j] + 1 else @max(prev[j + 1], next[j]);
            }
            const swap = prev;
            prev = next;
            next = swap;
        }
        const lcs: usize = if (old.len == 0) 0 else prev[old.len];
        self.cached = .{ .added = @intCast(new_len - lcs), .deleted = @intCast(old.len - lcs) };
        self.cached_revision = self.revision;
        return self.cached;
    }
};

test "write preview fingerprints line semantics without retaining content" {
    const a = std.testing.allocator;
    var baseline = (try Baseline.fromBytes(a, "a\nb\n")).?;
    var tracker = Tracker.init(a);
    defer tracker.deinit();
    tracker.setBaseline(baseline);
    baseline = undefined;
    for ("a\nB\nnew") |byte| tracker.scalar(byte);
    try std.testing.expectEqualDeep(Progress{ .added = 2, .deleted = 1 }, tracker.progress());
    tracker.finish();
    try std.testing.expectEqualDeep(Progress{ .added = 2, .deleted = 1 }, tracker.progress());
}

test "write preview empty baseline progress is constant work" {
    const t = std.testing;
    var tracker = Tracker.init(t.allocator);
    defer tracker.deinit();
    tracker.setBaseline(try Baseline.fromBytes(t.allocator, ""));
    for (0..max_lines - 1) |_| {
        tracker.scalar('x');
        tracker.scalar('\n');
    }
    for (0..128) |_| {
        tracker.scalar('y');
        try t.expectEqual(@as(?usize, max_lines), tracker.progress().added);
        try t.expectEqual(@as(usize, 0), tracker.cells_spent);
    }
}

test "write preview empty final LF CRLF limits and unknown baseline" {
    const a = std.testing.allocator;
    var tracker = Tracker.init(a);
    defer tracker.deinit();
    try std.testing.expectEqualDeep(Progress.unknown(), tracker.progress());
    tracker.setBaseline(try Baseline.fromBytes(a, "x\r\n"));
    for ("x\r\n") |byte| tracker.scalar(byte);
    try std.testing.expectEqualDeep(Progress{ .added = 0, .deleted = 0 }, tracker.progress());
    tracker.scalar('z');
    try std.testing.expectEqualDeep(Progress{ .added = 1, .deleted = 0 }, tracker.progress());
}
