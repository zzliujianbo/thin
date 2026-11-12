//! Classified local reference records. Metadata is constructed by the host only.
const std = @import("std");
const mem = @import("memory.zig");
const knowledge = @import("../core/knowledge.zig");
const fs = @import("../platform/filesystem.zig");
pub const Apply = enum { created, updated, unchanged, conflict, expired };
const Record = struct {
    schema: u8 = 2,
    source: []const u8,
    generation: u64,
    created_ms: u64,
    expires_at_ms: ?u64,
    category: knowledge.Category,
    topic: []const u8,
    content: []const u8,
};
const marker = "\n<!-- thin-knowledge-v2 -->\n";
const marker_v1 = "\n<!-- thin-knowledge-v1 -->\n";
const RecordV1 = struct {
    schema: u8,
    source: []const u8,
    source_id: u16,
    source_kind: knowledge.EvidenceKind,
    quote: []const u8,
    generation: u64,
    created_ms: u64,
    expires_at_ms: ?u64,
    category: knowledge.Category,
    topic: []const u8,
    content: []const u8,
};
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
        const now: u64 = @intCast(@max(0, std.Io.Clock.real.now(self.store.root.io).toMilliseconds()));
        if (candidate.expires_at_ms) |end| {
            if (end <= now) return .expired;
            if (end <= material.created_ms) return error.InvalidMemoryCandidate;
        }
        if (try self.store.generation() != material.generation) return .conflict;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const key = try std.fmt.allocPrint(temp, "{s}-{s}", .{ @tagName(candidate.category), candidate.topic });
        const normalized = std.mem.trim(u8, candidate.content, " \t\r\n");
        if (normalized.len == 0) return error.InvalidMemoryCandidate;
        const old = self.store.read(temp, key) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (old) |entry| {
            if (try decode(temp, key, entry.content)) |record| {
                if (std.mem.eql(u8, record.content, normalized) and record.expires_at_ms == candidate.expires_at_ms) return .unchanged;
            }
            if (candidate.expected_version == null or !std.mem.eql(u8, candidate.expected_version.?, entry.version)) return .conflict;
        } else if (candidate.expected_version != null) return .conflict;
        const record: Record = .{ .source = material.id, .generation = material.generation, .created_ms = material.created_ms, .expires_at_ms = candidate.expires_at_ms, .category = candidate.category, .topic = candidate.topic, .content = normalized };
        const json = try std.json.Stringify.valueAlloc(temp, record, .{});
        // A small content preview makes the bounded index useful without reading
        // every complete JSON shard. Never index the source body or evidence quote.
        var preview_len = @min(@as(usize, 256), std.mem.findScalar(u8, normalized, '\n') orelse normalized.len);
        while (preview_len < normalized.len and preview_len > 0 and normalized[preview_len] & 0xc0 == 0x80) preview_len -= 1;
        const text = try std.fmt.allocPrint(temp, "{s}: {s} {s}{s}{s}\n", .{ @tagName(candidate.category), candidate.topic, normalized[0..preview_len], marker, json });
        _ = self.store.writeGuarded(temp, key, text, candidate.expected_version, material.generation) catch |err| switch (err) {
            error.GenerationConflict, error.VersionConflict, error.PathAlreadyExists => return .conflict,
            else => return err,
        };
        return if (old == null) .created else .updated;
    }
    pub fn related(self: *Repository, a: std.mem.Allocator, query: []const u8, now_ms: u64) ![]const knowledge.Related {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const hits = try self.collect(temp, query, now_ms);
        var out: std.ArrayList(knowledge.Related) = .empty;
        errdefer {
            for (out.items) |entry| {
                a.free(entry.topic);
                a.free(entry.content);
                a.free(entry.version);
            }
            out.deinit(a);
        }
        for (hits) |hit| {
            const r = hit.record orelse continue;
            const topic = try a.dupe(u8, r.topic);
            errdefer a.free(topic);
            const content = try a.dupe(u8, hit.body);
            errdefer a.free(content);
            const version = try a.dupe(u8, hit.version);
            errdefer a.free(version);
            try out.append(a, .{ .category = r.category, .topic = topic, .content = content, .version = version });
        }
        return out.toOwnedSlice(a);
    }
    pub fn retrieve(self: *Repository, a: std.mem.Allocator, query: []const u8, now_ms: u64) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const hits = try self.collect(temp, query, now_ms);
        var out: std.ArrayList(u8) = .empty;
        for (hits) |hit| {
            const prefix = try std.fmt.allocPrint(temp, "[Untrusted current local reference: {s}]\n", .{hit.key});
            try out.appendSlice(temp, prefix);
            try out.appendSlice(temp, hit.body);
            try out.append(temp, '\n');
        }
        return a.dupe(u8, out.items);
    }
    const Hit = struct { key: []const u8, body: []const u8, version: []const u8, record: ?Record, score: usize };
    fn collect(self: *Repository, a: std.mem.Allocator, query: []const u8, now: u64) ![]Hit {
        if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidQuery;
        var hits: std.ArrayList(Hit) = .empty;
        // Small core is always the first reference, independent of lexical rank.
        const core = self.store.read(a, "core") catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (core) |entry| if (entry.content.len > 0) {
            try hits.append(a, .{ .key = "core", .body = entry.content, .version = entry.version, .record = null, .score = std.math.maxInt(usize) });
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
            const record = try decode(a, key, entry.content);
            if (record) |r| if (r.expires_at_ms) |end| if (end <= now) continue;
            const body = if (record) |r| r.content else entry.content;
            const rank = score(query, key, body);
            if (rank == 0) continue;
            try hits.append(a, .{ .key = key, .body = body, .version = entry.version, .record = record, .score = rank });
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
    const pos_v2 = std.mem.find(u8, text, marker);
    const pos_v1 = std.mem.find(u8, text, marker_v1);
    if (pos_v2 == null and pos_v1 == null) return null;
    if (pos_v2 != null and pos_v1 != null) return error.InvalidKnowledgeRecord;
    const pos = pos_v2 orelse pos_v1.?;
    // The prefix is a preview, not the authoritative record; accept complete
    // valid records regardless of the length of that untrusted preview.
    const r: Record = if (pos_v2 != null) blk: {
        const parsed = std.json.parseFromSlice(Record, a, text[pos + marker.len ..], .{ .allocate = .alloc_always }) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.InvalidKnowledgeRecord;
        };
        if (parsed.value.schema != 2) return error.InvalidKnowledgeRecord;
        break :blk parsed.value;
    } else blk: {
        const parsed = std.json.parseFromSlice(RecordV1, a, text[pos + marker_v1.len ..], .{ .allocate = .alloc_always }) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.InvalidKnowledgeRecord;
        };
        const old = parsed.value;
        if (old.schema != 1 or old.source_kind == .assistant or old.quote.len == 0 or old.quote.len > 1024) return error.InvalidKnowledgeRecord;
        try fs.validateText(old.quote);
        break :blk .{ .source = old.source, .generation = old.generation, .created_ms = old.created_ms, .expires_at_ms = old.expires_at_ms, .category = old.category, .topic = old.topic, .content = old.content };
    };
    const expected = try std.fmt.allocPrint(a, "{s}-{s}", .{ @tagName(r.category), r.topic });
    if (!validId(r.source) or !std.mem.eql(u8, key, expected) or r.content.len == 0) return error.InvalidKnowledgeRecord;
    try mem.validTopic(r.topic);
    if (r.topic.len > 40) return error.InvalidKnowledgeRecord;
    try fs.validateText(r.content);
    if (r.expires_at_ms) |end| if (end <= r.created_ms) return error.InvalidKnowledgeRecord;
    return r;
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
