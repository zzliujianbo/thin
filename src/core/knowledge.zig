//! Bounded, provider-independent automatic-memory contract. No disk or network.
const std = @import("std");
const p = @import("protocol.zig");
pub const max_sources = 24;
pub const max_source_bytes = 4096;
pub const max_material_bytes = 24576;
pub const max_candidates = 8;
pub const max_content_bytes = 2048;
pub const max_retrieval_bytes = 8192;
pub const Category = enum { preferences, project, environment, solutions, pitfalls };
pub const EvidenceKind = enum { user, tool, assistant };
pub const Evidence = struct { id: u16, kind: EvidenceKind, text: []const u8 };
pub const Related = struct { category: Category, topic: []const u8, content: []const u8, version: []const u8 };
pub const Material = struct {
    id: []const u8,
    generation: u64,
    created_ms: u64,
    sources: []const Evidence,
    related: []const Related = &.{},
    omitted_sources: usize = 0,
};
pub const Candidate = struct {
    category: Category,
    topic: []const u8,
    content: []const u8,
    expected_version: ?[]const u8 = null,
    expires_at_ms: ?u64 = null,
};
/// All extractor results (including partially allocated results on errors) use
/// the caller's allocator and belong to its task arena. The caller destroys that
/// arena on ALL exits, including post-extract cancellation/validation failure.
/// Service never individually frees candidate slices: fake services may borrow
/// static fixtures. Production coordinators provide an independent wiping arena.
pub const Service = struct {
    context: *anyopaque,
    extract_fn: *const fn (*anyopaque, std.mem.Allocator, Material, *const p.Cancellation) anyerror![]const Candidate,
    pub fn extract(self: Service, a: std.mem.Allocator, material: Material, cancel: *const p.Cancellation) ![]const Candidate {
        if (cancel.isRequested()) return error.Canceled;
        const result = try self.extract_fn(self.context, a, material, cancel);
        if (cancel.isRequested()) return error.Canceled;
        if (material.sources.len > max_sources or result.len > max_candidates) return error.InvalidMemoryCandidate;
        var filtered: std.ArrayList(Candidate) = .empty;
        for (result) |candidate| {
            validateCandidate(material, candidate) catch continue;
            var duplicate = false;
            for (filtered.items) |prior| if (prior.category == candidate.category and std.mem.eql(u8, prior.topic, candidate.topic)) {
                duplicate = true;
                break;
            };
            if (!duplicate) try filtered.append(a, candidate);
        }
        if (cancel.isRequested()) return error.Canceled;
        return filtered.toOwnedSlice(a);
    }
};
pub fn validateCandidate(material: Material, candidate: Candidate) !void {
    if (candidate.topic.len == 0 or candidate.topic.len > 40 or candidate.topic[candidate.topic.len - 1] == '-' or std.mem.trim(u8, candidate.content, " \t\r\n").len == 0 or candidate.content.len > max_content_bytes or !std.unicode.utf8ValidateSlice(candidate.content) or std.mem.findScalar(u8, candidate.content, 0) != null or sensitiveMaterial(candidate.topic) or sensitiveMaterial(candidate.content)) return error.InvalidMemoryCandidate;
    for (candidate.topic, 0..) |c, i| {
        if (!(c >= 'a' and c <= 'z') and !(c >= '0' and c <= '9') and !(i != 0 and c == '-' and candidate.topic[i - 1] != '-')) return error.InvalidMemoryCandidate;
    }
    if (candidate.expected_version) |expected| {
        if (expected.len != 64) return error.InvalidMemoryVersion;
        for (expected) |c| if (!std.ascii.isHex(c)) return error.InvalidMemoryVersion;
        var authorized = false;
        for (material.related) |related| {
            if (related.category == candidate.category and std.mem.eql(u8, related.topic, candidate.topic) and std.mem.eql(u8, related.version, expected)) {
                authorized = true;
                break;
            }
        }
        if (!authorized) return error.InvalidMemoryVersion;
    }
    if (candidate.expires_at_ms) |end| if (end <= material.created_ms) return error.InvalidMemoryCandidate;
}

/// Only explicit PEM private-key headers are recognized here. The coordinator
/// separately filters exact host-known credentials.
pub fn sensitiveMaterial(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.ascii.findIgnoreCase(line, "-----BEGIN ")) |start| {
            if (std.ascii.findIgnoreCase(line[start + "-----BEGIN ".len ..], "PRIVATE KEY-----") != null) return true;
        }
    }
    return false;
}

test "service filters borrowed candidates without mutation" {
    const Fake = struct {
        fn extract(_: *anyopaque, _: std.mem.Allocator, _: Material, _: *const p.Cancellation) ![]const Candidate {
            return &.{
                .{ .category = .project, .topic = "invalid slug", .content = "bad" },
                .{ .category = .project, .topic = "blank", .content = "   \t\r\n" },
                .{ .category = .project, .topic = "sk-abcdefghijklmnopqrstuvwxyz", .content = "ordinary content" },
                .{ .category = .project, .topic = "bearer-secret", .content = "Bearer abc.def" },
                .{ .category = .project, .topic = "config", .content = "Store configuration in .env; api_key is optional." },
                .{ .category = .project, .topic = "secret", .content = "password=secret" },
                .{ .category = .project, .topic = "config", .content = "duplicate" },
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dummy: u8 = 0;
    const service: Service = .{ .context = &dummy, .extract_fn = Fake.extract };
    const material: Material = .{ .id = "test", .generation = 0, .created_ms = 1, .sources = &.{} };
    var cancel: p.Cancellation = .{};
    const items = try service.extract(arena.allocator(), material, &cancel);
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("sk-abcdefghijklmnopqrstuvwxyz", items[0].topic);
    try std.testing.expectEqualStrings("bearer-secret", items[1].topic);
    try std.testing.expectEqualStrings("config", items[2].topic);
    try std.testing.expectEqualStrings("secret", items[3].topic);
    var capture: Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, "Bearer abc.def");
    capture.add(.user, "ordinary source");
    try std.testing.expectEqual(@as(usize, 2), capture.sources.items.len);
    try std.testing.expectEqualStrings("Bearer abc.def", capture.sources.items[0].text);
    try std.testing.expectEqualStrings("ordinary source", capture.sources.items[1].text);
    try std.testing.expectEqual(@as(usize, 0), capture.omitted_sources);
    for ([_][]const u8{
        "Use Bearer authentication for HTTP requests",
        "token = nextToken()",
        "password: minimum 8 characters",
        "Use .env and api_key when configuring /.thin/",
        "Bearer abc.def",
        "ghp_abcdefghijklmnopqrstuvwxyz",
        "sk-abcdefghijklmnopqrstuvwxyz",
    }) |text| {
        try std.testing.expect(!sensitiveMaterial(text));
        try validateCandidate(material, .{ .category = .project, .topic = "ordinary", .content = text });
        capture.add(.user, text);
    }
    try std.testing.expectEqual(@as(usize, 9), capture.sources.items.len);
    try std.testing.expect(sensitiveMaterial("-----BEGIN PRIVATE KEY-----"));
    try std.testing.expect(sensitiveMaterial("-----BEGIN RSA PRIVATE KEY-----"));
    try std.testing.expect(!sensitiveMaterial("-----BEGIN CERTIFICATE-----\nPRIVATE KEY-----"));
}

pub const Capture = struct {
    allocator: std.mem.Allocator,
    sources: std.ArrayList(Evidence) = .empty,
    bytes: usize = 0,
    incomplete: bool = false,
    omitted_sources: usize = 0,
    pub fn add(self: *Capture, kind: EvidenceKind, text: []const u8) void {
        if (self.incomplete or text.len == 0) return;
        if (kind == .assistant or !std.unicode.utf8ValidateSlice(text) or sensitiveMaterial(text)) {
            self.omitted_sources += 1;
            return;
        }
        if (self.sources.items.len == max_sources or text.len > max_source_bytes or self.bytes + text.len > max_material_bytes) {
            // Omit whole oversized sources; report the omission to extraction.
            // An omitted tool log cannot support an invented evidence quote.
            self.omitted_sources += 1;
            return;
        }
        const copy = self.allocator.dupe(u8, text) catch {
            self.incomplete = true;
            return;
        };
        self.sources.append(self.allocator, .{ .id = @intCast(self.sources.items.len), .kind = kind, .text = copy }) catch {
            self.allocator.free(copy);
            self.incomplete = true;
            return;
        };
        self.bytes += text.len;
    }
};
