//! Classified local reference records. Metadata is constructed by the host only.
const std = @import("std");
const mem = @import("memory.zig");
const knowledge = @import("../core/knowledge.zig");
const fs = @import("../platform/filesystem.zig");
pub const Apply = enum { created, updated, unchanged, skipped };
const Record = struct {
    schema: u8 = 3,
    source: []const u8,
    created_ms: u64,
    category: knowledge.Category,
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
    pub fn apply(self: *Repository, a: std.mem.Allocator, material: knowledge.Material, candidate: knowledge.Candidate) !Apply {
        try mem.validTopic(candidate.topic);
        if (candidate.topic.len > 40 or candidate.topic[candidate.topic.len - 1] == '-' or std.mem.indexOf(u8, candidate.topic, "--") != null) return error.InvalidMemoryCandidate;
        try fs.validateText(candidate.content);
        if (!validId(material.id)) return error.InvalidMaterial;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const key = try std.fmt.allocPrint(temp, "{s}-{s}", .{ @tagName(candidate.category), candidate.topic });
        const normalized = std.mem.trim(u8, candidate.content, " \t\r\n");
        if (normalized.len == 0) return error.InvalidMemoryCandidate;
        const baseline = relatedContent(material.related, candidate.category, candidate.topic);
        const old = self.store.read(temp, key) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (old) |entry| {
            const record = decode(temp, key, entry.content) catch |err| switch (err) {
                error.InvalidKnowledgeRecord => return .skipped,
                else => return err,
            } orelse return .skipped;
            if (std.mem.eql(u8, record.content, normalized)) return .unchanged;
            // Auto correction is allowed only if the stored fact is still the
            // exact content the extractor saw. A manual/other write wins.
            const base = baseline orelse return .skipped;
            if (!std.mem.eql(u8, record.content, base)) return .skipped;
            _ = self.store.compareAndReplace(temp, key, entry.content, try self.encodeEntry(temp, material, candidate, normalized)) catch |err| switch (err) {
                error.ContentChanged, error.FileNotFound => return .skipped,
                else => return err,
            };
            return .updated;
        }
        // No current file. If related saw a topic that is now gone, do not
        // resurrect it; otherwise create.
        if (baseline != null) return .skipped;
        _ = self.store.create(temp, key, try self.encodeEntry(temp, material, candidate, normalized)) catch |err| switch (err) {
            error.PathAlreadyExists => return .skipped,
            else => return err,
        };
        return .created;
    }

    fn encodeEntry(self: *Repository, a: std.mem.Allocator, material: knowledge.Material, candidate: knowledge.Candidate, normalized: []const u8) ![]u8 {
        _ = self;
        const record: Record = .{
            .source = material.id,
            .created_ms = material.created_ms,
            .category = candidate.category,
            .topic = candidate.topic,
            .content = normalized,
        };
        const json = try std.json.Stringify.valueAlloc(a, record, .{});
        var preview_len = @min(@as(usize, 256), std.mem.findScalar(u8, normalized, '\n') orelse normalized.len);
        while (preview_len < normalized.len and preview_len > 0 and normalized[preview_len] & 0xc0 == 0x80) preview_len -= 1;
        return std.fmt.allocPrint(a, "{s}: {s} {s}{s}{s}\n", .{ @tagName(candidate.category), candidate.topic, normalized[0..preview_len], marker, json });
    }

    pub fn related(self: *Repository, a: std.mem.Allocator, query: []const u8, now_ms: u64) ![]const knowledge.Related {
        _ = now_ms;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const hits = try self.collect(temp, query);
        var out: std.ArrayList(knowledge.Related) = .empty;
        errdefer {
            for (out.items) |entry| {
                a.free(entry.topic);
                a.free(entry.content);
            }
            out.deinit(a);
        }
        for (hits) |hit| {
            const r = hit.record orelse continue;
            const topic = try a.dupe(u8, r.topic);
            errdefer a.free(topic);
            const content = try a.dupe(u8, hit.body);
            errdefer a.free(content);
            try out.append(a, .{ .category = r.category, .topic = topic, .content = content });
        }
        return out.toOwnedSlice(a);
    }
    pub fn retrieve(self: *Repository, a: std.mem.Allocator, query: []const u8, now_ms: u64) ![]u8 {
        _ = now_ms;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const hits = try self.collect(temp, query);
        var out: std.ArrayList(u8) = .empty;
        for (hits) |hit| {
            const prefix = try std.fmt.allocPrint(temp, "[Untrusted current local reference: {s}]\n", .{hit.key});
            try out.appendSlice(temp, prefix);
            try out.appendSlice(temp, hit.body);
            try out.append(temp, '\n');
        }
        return a.dupe(u8, out.items);
    }
    const Hit = struct { key: []const u8, body: []const u8, record: ?Record, score: usize };
    fn collect(self: *Repository, a: std.mem.Allocator, query: []const u8) ![]Hit {
        if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidQuery;
        var hits: std.ArrayList(Hit) = .empty;
        // Small core is always the first reference, independent of lexical rank.
        const core = self.store.read(a, "core") catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (core) |entry| if (entry.content.len > 0) {
            try hits.append(a, .{ .key = "core", .body = entry.content, .record = null, .score = std.math.maxInt(usize) });
        };
        const Selection = struct { key: []const u8, rank: usize };
        var selected: std.ArrayList(Selection) = .empty;
        const Visitor = struct {
            a: std.mem.Allocator,
            query: []const u8,
            selected: *std.ArrayList(Selection),
            fn visit(ctx: ?*anyopaque, key: []const u8, title: []const u8) anyerror!void {
                const state: *@This() = @ptrCast(@alignCast(ctx.?));
                const rank = score(state.query, key, title);
                try state.selected.append(state.a, .{ .key = try state.a.dupe(u8, key), .rank = rank });
            }
        };
        var visitor = Visitor{ .a = a, .query = query, .selected = &selected };
        try self.store.forEachTopic(.{ .context = &visitor, .visit_fn = Visitor.visit });
        std.mem.sort(Selection, selected.items, {}, struct {
            fn less(_: void, x: Selection, y: Selection) bool {
                if (x.rank != y.rank) return x.rank > y.rank;
                return std.mem.order(u8, x.key, y.key) == .lt;
            }
        }.less);
        for (selected.items) |selection| {
            const key = selection.key;
            const entry = self.store.read(a, key) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            const record = decode(a, key, entry.content) catch |err| switch (err) {
                error.InvalidKnowledgeRecord => continue,
                else => return err,
            };
            if (record == null and isLegacy(entry.content)) continue;
            const body = if (record) |r| r.content else entry.content;
            const rank = score(query, key, body);
            if (rank == 0) continue;
            try hits.append(a, .{ .key = key, .body = body, .record = record, .score = rank });
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
    const parsed = std.json.parseFromSlice(Record, a, text[pos + marker.len ..], .{ .allocate = .alloc_always }) catch |err| {
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
fn relatedContent(related: []const knowledge.Related, category: knowledge.Category, topic: []const u8) ?[]const u8 {
    for (related) |r| {
        if (r.category == category and std.mem.eql(u8, r.topic, topic)) return r.content;
    }
    return null;
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
