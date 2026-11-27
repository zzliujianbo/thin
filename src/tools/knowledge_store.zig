//! Classified local reference records. Metadata is constructed by the host only.
const std = @import("std");
const mem = @import("memory.zig");
const fs = @import("../platform/filesystem.zig");

/// On-disk V3 category tags. The automatic extractor is gone; this enum only
/// decodes records it left behind, while new writes are plain memory topics.
const Category = enum { preferences, project, environment, solutions, pitfalls };
const Record = struct {
    schema: u8 = 3,
    source: []const u8,
    created_ms: u64,
    category: Category,
    topic: []const u8,
    content: []const u8,
};
const marker = "\n<!-- thin-knowledge-v3 -->\n";
const marker_v2 = "\n<!-- thin-knowledge-v2 -->\n";
const marker_v1 = "\n<!-- thin-knowledge-v1 -->\n";

pub const Repository = struct {
    store: *mem.Store,
    pub fn init(store: *mem.Store) Repository {
        return .{ .store = store };
    }
    /// Public read semantic: V3 records return their content, manual raw
    /// topics return their raw body, and legacy v1/v2 records are invisible.
    /// Corrupt V3 records remain errors instead of leaking framing bytes.
    pub fn readContent(self: *Repository, a: std.mem.Allocator, topic: []const u8) ![]u8 {
        const entry = try self.store.read(a, topic);
        defer a.free(entry.content);
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const record = decode(scratch.allocator(), topic, entry.content) catch |err| switch (err) {
            error.InvalidKnowledgeRecord => return error.InvalidKnowledgeRecord,
            else => return err,
        };
        if (record) |r| return a.dupe(u8, r.content);
        if (isLegacy(entry.content)) return error.FileNotFound;
        return a.dupe(u8, entry.content);
    }

    pub fn retrieve(self: *Repository, a: std.mem.Allocator, query: []const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const hits = try self.collect(temp, a, query);
        var out: std.ArrayList(u8) = .empty;
        for (hits) |hit| {
            const prefix = try std.fmt.allocPrint(temp, "[Untrusted current local reference: {s}]\n", .{hit.key});
            try out.appendSlice(temp, prefix);
            try out.appendSlice(temp, hit.body);
            try out.append(temp, '\n');
        }
        return a.dupe(u8, out.items);
    }
    const Hit = struct { key: []const u8, body: []const u8, score: usize };
    fn collect(self: *Repository, a: std.mem.Allocator, scratch_backing: std.mem.Allocator, query: []const u8) ![]Hit {
        if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidQuery;
        var hits: std.ArrayList(Hit) = .empty;
        // Small core is always the first reference, independent of lexical rank.
        const core = self.store.read(a, "core") catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (core) |entry| if (entry.content.len > 0) {
            try hits.append(a, .{ .key = "core", .body = entry.content, .score = std.math.maxInt(usize) });
        };
        for (try self.store.referenceKeys(a)) |key| {
            var scratch = std.heap.ArenaAllocator.init(scratch_backing);
            defer scratch.deinit();
            const item = scratch.allocator();
            const entry = try self.store.readReference(item, key) orelse continue;
            const record = decode(item, key, entry.content) catch |err| switch (err) {
                error.InvalidKnowledgeRecord => continue,
                else => return err,
            };
            if (record == null and isLegacy(entry.content)) continue;
            const body = if (record) |r| r.content else entry.content;
            const rank = score(query, key, body);
            if (rank == 0) continue;
            try hits.append(a, .{ .key = key, .body = try a.dupe(u8, body), .score = rank });
        }
        std.mem.sort(Hit, hits.items, {}, struct {
            fn less(_: void, x: Hit, y: Hit) bool {
                if (x.score != y.score) return x.score > y.score;
                return std.mem.order(u8, x.key, y.key) == .lt;
            }
        }.less);
        return hits.items;
    }
};
fn validId(id: []const u8) bool {
    if (id.len != 64) return false;
    for (id) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
fn decode(a: std.mem.Allocator, key: []const u8, text: []const u8) !?Record {
    if (std.mem.find(u8, text, marker_v2) != null or std.mem.find(u8, text, marker_v1) != null) return null;
    const pos = std.mem.find(u8, text, marker) orelse return null;
    // The prefix is a preview, not the authoritative record; accept complete
    // valid records regardless of the length of that untrusted preview.
    const parsed = std.json.parseFromSlice(Record, a, text[pos + marker.len ..], .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidKnowledgeRecord;
    };
    const r = parsed.value;
    if (r.schema != 3) return error.InvalidKnowledgeRecord;
    const expected = try std.fmt.allocPrint(a, "{s}-{s}", .{ @tagName(r.category), r.topic });
    if (!validId(r.source) or !std.mem.eql(u8, key, expected) or r.content.len == 0) return error.InvalidKnowledgeRecord;
    try mem.validTopic(r.topic);
    if (r.topic.len > 40) return error.InvalidKnowledgeRecord;
    try fs.validateText(r.content);
    return r;
}
fn isLegacy(text: []const u8) bool {
    return std.mem.find(u8, text, marker_v2) != null or std.mem.find(u8, text, marker_v1) != null;
}
fn score(query: []const u8, key: []const u8, body: []const u8) usize {
    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n,.;:!?/\\-_");
    var rank: usize = 0;
    while (tokens.next()) |token| {
        if (contains(key, token)) rank +|= 2;
        if (contains(body, token)) rank +|= 1;
        // Chinese prose often has no spaces. Match bounded two-codepoint
        // substrings as well as whole tokens, retaining UTF-8 boundaries.
        var i: usize = 0;
        while (i < token.len) {
            const n = std.unicode.utf8ByteSequenceLength(token[i]) catch break;
            const next = i + n;
            if (n >= 3 and next < token.len) {
                const m = std.unicode.utf8ByteSequenceLength(token[next]) catch break;
                if (m >= 3 and m <= token.len - next) {
                    const pair = token[i .. next + m];
                    if (contains(key, pair)) rank +|= 2;
                    if (contains(body, pair)) rank +|= 1;
                }
            }
            i = next;
        }
    }
    return rank;
}
fn contains(text: []const u8, term: []const u8) bool {
    if (term.len == 0 or term.len > text.len) return false;
    for (0..text.len - term.len + 1) |i| {
        if (text[i] & 0xc0 == 0x80) continue;
        if (!std.ascii.eqlIgnoreCase(text[i..][0..term.len], term)) continue;
        const end = i + term.len;
        if (end < text.len and text[end] & 0xc0 == 0x80) continue;
        // ASCII terms require word boundaries; CJK terms match contiguous text.
        if (term[0] < 128 and i > 0 and std.ascii.isAlphanumeric(text[i - 1])) continue;
        if (term[term.len - 1] < 128 and end < text.len and std.ascii.isAlphanumeric(text[end])) continue;
        return true;
    }
    return false;
}
