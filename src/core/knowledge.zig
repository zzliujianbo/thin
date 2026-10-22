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
    source_id: u16,
    quote: []const u8,
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
        try validate(material, result);
        return result;
    }
};
pub fn validate(material: Material, candidates: []const Candidate) !void {
    if (material.sources.len > max_sources or candidates.len > max_candidates) return error.InvalidMemoryCandidate;
    for (candidates, 0..) |candidate, index| {
        for (candidates[0..index]) |prior| if (prior.category == candidate.category and std.mem.eql(u8, prior.topic, candidate.topic)) return error.DuplicateMemoryCandidate;
        if (candidate.topic.len == 0 or candidate.topic.len > 40 or candidate.content.len == 0 or candidate.content.len > max_content_bytes or
            !std.unicode.utf8ValidateSlice(candidate.content) or std.mem.findScalar(u8, candidate.content, 0) != null or
            candidate.quote.len == 0 or candidate.quote.len > 1024 or !std.unicode.utf8ValidateSlice(candidate.quote) or
            std.mem.findScalar(u8, candidate.quote, 0) != null) return error.InvalidMemoryCandidate;
        for (candidate.topic, 0..) |c, i| if (!(c >= 'a' and c <= 'z') and !(c >= '0' and c <= '9') and !(i != 0 and c == '-')) return error.InvalidMemoryCandidate;
        var evidence: ?Evidence = null;
        for (material.sources) |source| if (source.id == candidate.source_id) {
            evidence = source;
            break;
        };
        const source = evidence orelse return error.InvalidMemoryCandidate;
        if (source.kind == .assistant or std.mem.find(u8, source.text, candidate.quote) == null) return error.InvalidMemoryEvidence;
        if (sensitiveMaterial(source.text) or sensitiveMaterial(candidate.content) or sensitiveMaterial(candidate.quote)) return error.InvalidMemoryEvidence;
        if (candidate.expected_version) |expected| {
            // Store versions are SHA-256 hex. Fake services must obey the same
            // syntax as the codec, even if malformed related data matches.
            if (expected.len != 64) return error.InvalidMemoryVersion;
            for (expected) |c| if (!std.ascii.isHex(c)) return error.InvalidMemoryVersion;
            // A version from another topic/category is never overwrite authority.
            var authorized = false;
            for (material.related) |related| {
                if (related.category == candidate.category and std.mem.eql(u8, related.topic, candidate.topic) and
                    std.mem.eql(u8, related.version, expected))
                {
                    authorized = true;
                    break;
                }
            }
            if (!authorized) return error.InvalidMemoryVersion;
        }
        if (candidate.expires_at_ms) |end| if (end <= material.created_ms) return error.InvalidMemoryCandidate;
    }
}
/// Pure conservative screening; the App additionally rejects journal-known keys.
/// Whole sources are omitted, never partially redacted into misleading quotes.
pub fn sensitiveMaterial(text: []const u8) bool {
    const markers = [_][]const u8{
        "-----BEGIN ",    "PRIVATE KEY",      "authorization:", "bearer ",
        "api_key",        "api-key",          "access_token",   "refresh_token",
        "client_secret",  "password=",        "password:",      "\"password\"",
        "sk-",            "ghp_",             "github_pat_",    "/.ssh/",
        "/.aws/",         "/.config/gcloud/", "/auth.json",     "/credentials",
        "/sessions/",     "/history/",        "/.thin/",        ".env",
        "session_cookie",
    };
    for (markers) |marker| if (std.ascii.findIgnoreCase(text, marker) != null) return true;
    return false;
}

test "knowledge direct and fake Service exact CAS syntax authority and whole batch rejection" {
    const v = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const other = "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var material: Material = .{ .id = "synthetic", .generation = 1, .created_ms = 100, .sources = &.{.{ .id = 0, .kind = .user, .text = "Prefer Zig." }} };
    const create: Candidate = .{ .category = .preferences, .topic = "editor", .content = "Prefer Zig.", .source_id = 0, .quote = "Prefer Zig." };
    var update = create;
    update.topic = "language";
    update.expected_version = v;
    const Fake = struct {
        items: []const Candidate,
        calls: usize = 0,
        fn extract(raw: *anyopaque, _: std.mem.Allocator, _: Material, _: *const p.Cancellation) ![]const Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return self.items;
        }
    };
    var batch = [_]Candidate{ create, update };
    var fake: Fake = .{ .items = &batch };
    const service: Service = .{ .context = &fake, .extract_fn = Fake.extract };
    var cancel: p.Cancellation = .{};
    const related: Related = .{ .category = .preferences, .topic = "language", .content = "Old", .version = v };
    material.related = &.{related};
    try validate(material, &batch);
    try std.testing.expectEqual(@as(usize, 2), (try service.extract(std.testing.allocator, material, &cancel)).len);
    // Keep each negative unauthorized; a valid first item must not escape.
    for (0..7) |case| {
        var r = related;
        batch[1] = update;
        switch (case) {
            0 => material.related = &.{},
            1 => r.category = .project,
            2 => r.topic = "other",
            3 => r.version = other,
            4 => batch[1].expected_version = "",
            5 => batch[1].expected_version = "abc",
            6 => batch[1].expected_version = "g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            else => unreachable,
        }
        // Malformed matching related data must not grant fake-Service authority.
        if (case >= 4) r.version = batch[1].expected_version.?;
        if (case != 0) material.related = &.{r};
        try std.testing.expectError(error.InvalidMemoryVersion, validate(material, &batch));
        try std.testing.expectError(error.InvalidMemoryVersion, service.extract(std.testing.allocator, material, &cancel));
    }
    try std.testing.expectEqual(@as(usize, 8), fake.calls);
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
