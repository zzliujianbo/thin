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
