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
pub const EvidenceRejection = struct {
    pub const Reason = enum { assistant_source, quote_mismatch, sensitive_source, sensitive_content, sensitive_quote };
    reason: Reason,
    candidate_index: u32,
    source_id: u16,
};

pub fn validate(material: Material, candidates: []const Candidate) !void {
    return validateWithRejection(material, candidates, null);
}

pub fn validateWithRejection(material: Material, candidates: []const Candidate, rejection: ?*?EvidenceRejection) !void {
    if (rejection) |out| out.* = null;
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
        const reason: ?EvidenceRejection.Reason = if (source.kind == .assistant)
            .assistant_source
        else if (std.mem.find(u8, source.text, candidate.quote) == null)
            .quote_mismatch
        else if (sensitiveMaterial(source.text))
            .sensitive_source
        else if (sensitiveMaterial(candidate.content))
            .sensitive_content
        else if (sensitiveMaterial(candidate.quote))
            .sensitive_quote
        else
            null;
        if (reason) |why| {
            if (rejection) |out| out.* = .{ .reason = why, .candidate_index = @intCast(index), .source_id = candidate.source_id };
            return error.InvalidMemoryEvidence;
        }
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
        "-----BEGIN ",      "PRIVATE KEY", "authorization:", "bearer ",
        "api_key",          "api-key",     "access_token",   "refresh_token",
        "client_secret",    "password=",   "password:",      "\"password\"",
        "ghp_",             "github_pat_", "/.ssh/",         "/.aws/",
        "/.config/gcloud/", "/auth.json",  "/credentials",   "/sessions/",
        "/history/",        "/.thin/",     "session_cookie",
    };
    for (markers) |marker| if (std.ascii.findIgnoreCase(text, marker) != null) return true;
    return sensitiveSk(text) or sensitiveEnv(text);
}

fn identifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn sensitiveSk(text: []const u8) bool {
    var offset: usize = 0;
    while (std.ascii.findIgnoreCase(text[offset..], "sk-")) |relative| {
        const pos = offset + relative;
        if (pos == 0 or !identifierByte(text[pos - 1])) return true;
        const suffix = text[pos + 3 ..];
        var count: usize = 0;
        while (count < suffix.len and count < 20 and (identifierByte(suffix[count]) or suffix[count] == '-')) : (count += 1) {}
        if (count == 20) return true;
        offset = pos + 3;
    }
    return false;
}

fn sensitiveEnv(text: []const u8) bool {
    var offset: usize = 0;
    while (std.ascii.findIgnoreCase(text[offset..], ".env")) |relative| {
        const pos = offset + relative;
        const end = pos + 4;
        if (!(pos > 0 and identifierByte(text[pos - 1]) and end < text.len and std.ascii.isAlphabetic(text[end]))) return true;
        offset = end;
    }
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

test "memory evidence rejection reports ordered reasons and resets" {
    var sources = [_]Evidence{
        .{ .id = 3, .kind = .user, .text = "valid evidence" },
        .{ .id = 42, .kind = .user, .text = "ordinary evidence" },
    };
    const material: Material = .{ .id = "test", .generation = 1, .created_ms = 1, .sources = &sources };
    const first: Candidate = .{ .category = .project, .topic = "first", .content = "valid", .source_id = 3, .quote = "valid" };
    const second: Candidate = .{ .category = .project, .topic = "second", .content = "ordinary", .source_id = 42, .quote = "ordinary" };
    var batch = [_]Candidate{ first, second };
    var report: ?EvidenceRejection = null;
    const reasons = [_]EvidenceRejection.Reason{ .assistant_source, .quote_mismatch, .sensitive_source, .sensitive_content, .sensitive_quote };
    for (reasons) |reason| {
        sources[1] = .{ .id = 42, .kind = .user, .text = "ordinary evidence" };
        batch[1] = second;
        switch (reason) {
            .assistant_source => sources[1].kind = .assistant,
            .quote_mismatch => batch[1].quote = "absent",
            .sensitive_source => sources[1].text = "ordinary password=secret",
            .sensitive_content => batch[1].content = "password=secret",
            .sensitive_quote => {
                sources[1].text = "task-runner";
                batch[1].quote = "sk-runner";
            },
        }
        try std.testing.expectError(error.InvalidMemoryEvidence, validateWithRejection(material, &batch, &report));
        try std.testing.expectEqual(reason, report.?.reason);
        try std.testing.expectEqual(@as(u32, 1), report.?.candidate_index);
        try std.testing.expectEqual(@as(u16, 42), report.?.source_id);
        try std.testing.expectError(error.InvalidMemoryEvidence, validate(material, &batch));
    }
    batch[1] = second;
    sources[1].text = "ordinary evidence";
    try validateWithRejection(material, &batch, &report);
    try std.testing.expect(report == null);
    report = .{ .reason = .sensitive_source, .candidate_index = 1, .source_id = 42 };
    batch[1].source_id = 99;
    try std.testing.expectError(error.InvalidMemoryCandidate, validateWithRejection(material, &batch, &report));
    try std.testing.expect(report == null);
    try validate(material, batch[0..1]);
}

test "memory evidence rejection bounded sensitive boundaries apply to capture and candidates" {
    const safe = [_][]const u8{ "task-runner", "mask-helper", "os.environ", "os.environb", "std.process.Environ.Map" };
    const unsafe = [_][]const u8{ "sk-token", "'sk-token'", "key=sk-token", " sk-token", "中sk-token", "ask-abcdefghijklmnopqrst", ".env", "/repo/.env", "foo.env", ".env.local", ".env-prod", ".env_dev", ".envrc", "/.envBackup", "process.env" };
    var capture: Capture = .{ .allocator = std.testing.allocator };
    defer {
        for (capture.sources.items) |source| std.testing.allocator.free(source.text);
        capture.sources.deinit(std.testing.allocator);
    }
    for (safe) |text| {
        try std.testing.expect(!sensitiveMaterial(text));
        capture.add(.user, text);
        const source = [_]Evidence{.{ .id = 7, .kind = .user, .text = text }};
        const material: Material = .{ .id = "test", .generation = 1, .created_ms = 1, .sources = &source };
        const candidate: Candidate = .{ .category = .project, .topic = "safe", .content = text, .source_id = 7, .quote = text };
        try validate(material, &.{candidate});
    }
    try std.testing.expectEqual(safe.len, capture.sources.items.len);
    for (unsafe) |text| {
        try std.testing.expect(sensitiveMaterial(text));
        capture.add(.user, text);
        const source = [_]Evidence{.{ .id = 7, .kind = .user, .text = "ordinary" }};
        const material: Material = .{ .id = "test", .generation = 1, .created_ms = 1, .sources = &source };
        const candidate: Candidate = .{ .category = .project, .topic = "unsafe", .content = text, .source_id = 7, .quote = "ordinary" };
        var report: ?EvidenceRejection = null;
        try std.testing.expectError(error.InvalidMemoryEvidence, validateWithRejection(material, &.{candidate}, &report));
        try std.testing.expectEqual(EvidenceRejection.Reason.sensitive_content, report.?.reason);
    }
    try std.testing.expectEqual(safe.len, capture.sources.items.len);
    try std.testing.expectEqual(unsafe.len, capture.omitted_sources);
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
