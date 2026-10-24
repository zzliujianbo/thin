//! Project-local automatic Memory finalizer. Independent extraction/review
//! failures are observable but never rewrite an already completed primary task.
//! Finalization is synchronous: an accepted task cannot publish finished/idle
//! until Memory reaches a terminal outcome.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const k = @import("../core/knowledge.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const knowledge = @import("../tools/knowledge_store.zig");
const Extractor = @import("memory_client.zig").Client;
const Reviewer = @import("decision_client.zig").Client;

pub const State = enum(u8) { idle, finalizing, saved, skipped, failed, uncertain, canceled };
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: fs.Root,
    store: mem.Store,
    config: std.json.Parsed(cfg.Config),
    extractor: ?*Extractor = null,
    reviewer: ?*Reviewer = null,
    /// Test-only provider-independent seam. No fake behavior in production.
    service_override: ?k.Service = null,
    review_override: ?@import("../core/decision.zig").Service = null,
    state: std.atomic.Value(u8) = .init(@backingInt(State.idle)),
    failure: std.atomic.Value(u16) = .init(0),
    completed: std.atomic.Value(u64) = .init(0),
    poisoned: std.atomic.Value(bool) = .init(false),
    accepted_generation: std.atomic.Value(u64) = .init(0),
    acceptance_valid: std.atomic.Value(bool) = .init(false),
    secrets: [34]?[]u8 = @splat(null),
    secret_count: usize = 0,

    pub fn create(a: std.mem.Allocator, io: std.Io, root: *const fs.Root, config: cfg.Config, env: *const std.process.Environ.Map) !*Coordinator {
        const self = try a.create(Coordinator);
        errdefer a.destroy(self);
        var anchored = try root.duplicate();
        errdefer anchored.deinit();
        var owned = try cfg.clone(a, config);
        errdefer cfg.release(&owned);
        self.* = .{ .allocator = a, .io = io, .root = anchored, .store = undefined, .config = owned };
        self.store = mem.Store.init(&self.root, owned.value.limits);
        // Automatic finalization is auxiliary and must never hang primary settle
        // behind another process's project transaction.
        self.store.wait_for_lock = false;
        errdefer self.releaseSecrets();
        if (config.provider.api_key) |key| try self.rememberSecret(key);
        if (env.get(config.provider.api_key_env)) |key| try self.rememberSecret(key);
        if (config.registry) |registry| for (registry.providers) |provider| {
            if (provider.connection.api_key) |key| try self.rememberSecret(key);
            if (env.get(provider.connection.api_key_env)) |key| try self.rememberSecret(key);
        };
        if (config.memory.auto) {
            self.extractor = try Extractor.create(a, io, config, env);
            errdefer if (self.extractor) |client| client.deinit();
            self.reviewer = try Reviewer.create(a, io, config, env);
            errdefer if (self.reviewer) |client| client.deinit();
        }
        return self;
    }

    fn rememberSecret(self: *Coordinator, key: []const u8) !void {
        if (key.len == 0) return;
        for (self.secrets[0..self.secret_count]) |old| if (std.mem.eql(u8, old.?, key)) return;
        if (self.secret_count == self.secrets.len) return error.TooManySessionCredentials;
        var wiping: cfg.WipingAllocator = .{ .backing = self.allocator };
        self.secrets[self.secret_count] = try wiping.allocator().dupe(u8, key);
        self.secret_count += 1;
    }
    fn releaseSecrets(self: *Coordinator) void {
        var wiping: cfg.WipingAllocator = .{ .backing = self.allocator };
        for (self.secrets[0..self.secret_count]) |key| wiping.allocator().free(key.?);
        self.secret_count = 0;
    }
    fn containsSecret(self: *const Coordinator, text: []const u8) bool {
        for (self.secrets[0..self.secret_count]) |key| if (std.mem.find(u8, text, key.?) != null) return true;
        return false;
    }
    pub fn isPoisoned(self: *const Coordinator) bool {
        return self.poisoned.load(.acquire);
    }
    fn publish(self: *Coordinator, value: State, err: ?anyerror) void {
        if (err) |failure_| if (failure_ == error.CleanupFailed) self.poisoned.store(true, .release);
        self.failure.store(if (err) |e| @intFromError(e) else 0, .release);
        self.state.store(@backingInt(value), .release);
    }
    pub fn notice(self: *const Coordinator) ?[]const u8 {
        if (!self.config.value.memory.auto) return null;
        return switch (@as(State, @fromBackingInt(@intCast(self.state.load(.acquire))))) {
            .idle => null,
            .finalizing => "Memory: finalizing (separate auxiliary request)",
            .saved => "Memory: saved",
            .skipped => "Memory: no new durable entries",
            .failed => "Memory: finalization failed",
            .uncertain => "Memory: request outcome uncertain; no automatic replay",
            .canceled => "Memory: finalization canceled",
        };
    }

    pub fn retrieve(self: *Coordinator, a: std.mem.Allocator, query: []const u8, max_bytes: usize) ![]const u8 {
        if (self.isPoisoned()) return error.CleanupFailed;
        self.acceptance_valid.store(false, .release);
        const generation = try self.store.generation();
        self.accepted_generation.store(generation, .release);
        self.acceptance_valid.store(true, .release);
        self.publish(.idle, null);
        if (max_bytes == 0) return a.dupe(u8, "");
        var end = @min(query.len, 8192);
        while (end > 0 and end < query.len and query[end] & 0xc0 == 0x80) end -= 1;
        var repository = knowledge.Repository.init(&self.store);
        var reference_wiping: cfg.WipingAllocator = .{ .backing = a };
        const reference = try repository.retrieve(reference_wiping.allocator(), query[0..end], now(self.io), @min(max_bytes, k.max_retrieval_bytes));
        if (self.containsSecret(reference)) {
            reference_wiping.allocator().free(reference);
            self.publish(.failed, error.SensitiveMemoryMaterial);
            return error.SensitiveMemoryMaterial;
        }
        return reference;
    }

    /// Finalize one accepted primary task before Runtime publishes finished.
    /// Auxiliary failure is recorded here and deliberately does not alter the
    /// primary task's already frozen Terminal.
    pub fn finalize(self: *Coordinator, capture: *const k.Capture, protocol: p.Protocol, cancel: *const p.Cancellation) void {
        if (!self.config.value.memory.auto) return;
        if (self.isPoisoned()) {
            self.publish(.failed, error.CleanupFailed);
            return;
        }
        if (capture.incomplete or capture.sources.items.len == 0) {
            self.publish(.skipped, null);
            return;
        }
        if (!self.acceptance_valid.load(.acquire)) {
            if (self.failure.load(.acquire) == 0) self.publish(.failed, error.MemoryUnavailable);
            return;
        }
        if (cancel.isRequested()) {
            self.publish(.canceled, error.Canceled);
            return;
        }
        if (self.service_override == null) {
            if (protocol == .auto or protocol == .systemone) {
                self.publish(.failed, error.MemoryUnavailable);
                return;
            }
            self.extractor.?.bindProtocol(protocol) catch |err| {
                self.publish(.failed, err);
                return;
            };
        }

        self.publish(.finalizing, null);
        var wiping: cfg.WipingAllocator = .{ .backing = self.allocator };
        var scratch = std.heap.ArenaAllocator.init(wiping.allocator());
        defer scratch.deinit();
        const a = scratch.allocator();
        const generation = self.accepted_generation.load(.acquire);
        const current_generation = self.store.generation() catch |err| {
            self.publish(.failed, err);
            return;
        };
        if (current_generation != generation) {
            self.publish(.skipped, null);
            return;
        }
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        var generation_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &generation_bytes, generation, .little);
        digest.update(&generation_bytes);
        for (capture.sources.items) |source| {
            digest.update(@tagName(source.kind));
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, source.text.len, .little);
            digest.update(&size);
            digest.update(source.text);
        }
        const id = std.fmt.bytesToHex(digest.finalResult(), .lower);
        const material: k.Material = .{ .id = &id, .generation = generation, .created_ms = now(self.io), .sources = capture.sources.items, .omitted_sources = capture.omitted_sources };
        self.process(a, material, cancel) catch |err| {
            if (err == error.Canceled) self.publish(.canceled, err) else if (err == error.MemoryUnavailable) self.publish(.uncertain, err) else self.publish(.failed, err);
            return;
        };
        _ = self.completed.fetchAdd(1, .acq_rel);
    }

    pub fn reportFailure(self: *Coordinator, err: anyerror) void {
        self.publish(.failed, err);
    }
    fn now(io: std.Io) u64 {
        const value = std.Io.Clock.real.now(io).toMilliseconds();
        return @intCast(@max(0, value));
    }
    fn process(self: *Coordinator, a: std.mem.Allocator, source: k.Material, cancel: *const p.Cancellation) !void {
        if (cancel.isRequested()) return error.Canceled;
        var repository = knowledge.Repository.init(&self.store);
        var query: std.ArrayList(u8) = .empty;
        for (source.sources) |evidence| if (evidence.kind == .user) {
            if (query.items.len + evidence.text.len <= 8192) {
                try query.appendSlice(a, evidence.text);
                try query.append(a, '\n');
            }
        };
        var material = source;
        for (source.sources) |evidence| if (self.containsSecret(evidence.text) or k.sensitiveMaterial(evidence.text)) return error.SensitiveMemoryMaterial;
        var related: std.ArrayList(k.Related) = .empty;
        for (try repository.related(a, query.items, now(self.io))) |entry| {
            if (self.containsSecret(entry.content) or self.containsSecret(entry.topic) or k.sensitiveMaterial(entry.content)) continue;
            try related.append(a, entry);
        }
        material.related = related.items;
        const service = self.service_override orelse if (self.extractor) |client| client.service() else return error.MemoryUnavailable;
        const candidates = try service.extract(a, material, cancel);
        if (cancel.isRequested()) return error.Canceled;
        for (candidates) |candidate| {
            if (self.containsSecret(candidate.topic) or self.containsSecret(candidate.content) or self.containsSecret(candidate.quote)) return error.SensitiveMemoryMaterial;
        }
        var saved: usize = 0;
        for (candidates) |candidate| {
            if (cancel.isRequested()) return error.Canceled;
            switch (try repository.inspect(a, material, candidate)) {
                .unchanged, .expired => continue,
                .conflict => return error.MemoryConflict,
                .created, .updated => {},
            }
            if (self.review_override orelse if (self.reviewer) |client| client.service() else null) |reviewer| {
                const output = try reviewer.decide(a, .{ .memory_write = .{ .topic = candidate.topic, .content = candidate.content, .expected_version = candidate.expected_version } }, cancel);
                if (output != .memory_write) return error.InvalidDecision;
                if (!output.memory_write) continue;
            }
            if (cancel.isRequested()) return error.Canceled;
            const result = try repository.apply(a, material, candidate);
            switch (result) {
                .created, .updated => saved += 1,
                .conflict => return error.MemoryConflict,
                .unchanged, .expired => {},
            }
        }
        self.publish(if (saved == 0) .skipped else .saved, null);
    }

    pub fn deinit(self: *Coordinator) void {
        if (self.reviewer) |reviewer| reviewer.deinit();
        if (self.extractor) |client| client.deinit();
        self.releaseSecrets();
        cfg.release(&self.config);
        self.root.deinit();
        self.allocator.destroy(self);
    }
};
