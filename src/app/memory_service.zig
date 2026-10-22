//! Project-local automatic memory owner. Independent network/config lifetimes;
//! background failures never rewrite the accepted primary task's terminal state.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const k = @import("../core/knowledge.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const knowledge = @import("../tools/knowledge_store.zig");
const queue_module = @import("../tools/memory_queue.zig");
const Extractor = @import("memory_client.zig").Client;
const Reviewer = @import("decision_client.zig").Client;

pub const State = enum(u8) { idle, queued, running, saved, skipped, failed, uncertain };
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
    cancel: p.Cancellation = .{},
    wake: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    processing: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(u8) = .init(@backingInt(State.idle)),
    failure: std.atomic.Value(u16) = .init(0),
    completed: std.atomic.Value(u64) = .init(0),
    work_version: std.atomic.Value(u64) = .init(0),
    settled_version: std.atomic.Value(u64) = .init(0),
    poisoned: std.atomic.Value(bool) = .init(false),
    confirmed_protocol: std.atomic.Value(u8) = .init(@backingInt(p.Protocol.auto)),
    accepted_generation: std.atomic.Value(u64) = .init(0),
    acceptance_valid: std.atomic.Value(bool) = .init(false),
    secrets: [34]?[]u8 = @splat(null),
    secret_count: usize = 0,
    future: ?std.Io.Future(void) = null,

    pub fn create(a: std.mem.Allocator, io: std.Io, root: *const fs.Root, config: cfg.Config, env: *const std.process.Environ.Map) !*Coordinator {
        const self = try a.create(Coordinator);
        errdefer a.destroy(self);
        var anchored = try root.duplicate();
        errdefer anchored.deinit();
        var owned = try cfg.clone(a, config);
        errdefer cfg.release(&owned);
        self.* = .{ .allocator = a, .io = io, .root = anchored, .store = undefined, .config = owned };
        self.store = mem.Store.init(&self.root, owned.value.limits);
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
            self.future = try std.Io.concurrent(io, work, .{self});
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
    pub fn confirmProtocol(self: *Coordinator, protocol: p.Protocol) void {
        if (protocol != .auto and protocol != .systemone) self.confirmed_protocol.store(@backingInt(protocol), .release);
    }
    pub fn isPoisoned(self: *const Coordinator) bool {
        return self.poisoned.load(.acquire);
    }
    fn publish(self: *Coordinator, value: State, err: ?anyerror) void {
        if (err) |failure| if (failure == error.CleanupFailed) {
            self.poisoned.store(true, .release);
        };
        self.failure.store(if (err) |e| @intFromError(e) else 0, .release);
        self.state.store(@backingInt(value), .release);
    }
    pub fn notice(self: *const Coordinator) ?[]const u8 {
        if (!self.config.value.memory.auto) return null;
        return switch (@as(State, @fromBackingInt(@intCast(self.state.load(.acquire))))) {
            .idle => null,
            .queued => "Memory: queued",
            .running => "Memory: extracting (separate auxiliary request)",
            .saved => "Memory: saved",
            .skipped => "Memory: no new durable entries",
            .failed => "Memory: failed; inspect memory status before retrying",
            .uncertain => "Memory: request outcome uncertain; no automatic replay",
        };
    }

    /// No startup inference. A real accepted task wakes recovery, even if the
    /// process was restarted with a queued job. Sending/uncertain jobs are not replayed.
    pub fn retrieve(self: *Coordinator, a: std.mem.Allocator, query: []const u8, max_bytes: usize) ![]const u8 {
        if (self.isPoisoned()) return error.CleanupFailed;
        // This flag records an observed generation, not successful reference
        // rendering. A rejected legacy reference must not discard safe new user
        // evidence; a failed generation read still leaves acceptance false.
        self.acceptance_valid.store(false, .release);
        var reader = self.store;
        reader.wait_for_lock = false;
        const generation = try reader.generation();
        self.accepted_generation.store(generation, .release);
        self.acceptance_valid.store(true, .release);
        // Wake recovery after this read releases its own root transactions;
        // otherwise a fresh worker can contend with our nonwaiting snapshot.
        defer if (self.config.value.memory.auto) {
            _ = self.work_version.fetchAdd(1, .acq_rel);
            self.wake.store(true, .release);
        };
        if (max_bytes == 0) return a.dupe(u8, "");
        var end = @min(query.len, 8192);
        while (end > 0 and end < query.len and query[end] & 0xc0 == 0x80) end -= 1;
        var repository = knowledge.Repository.init(&reader);
        var reference_wiping: cfg.WipingAllocator = .{ .backing = a };
        const reference = try repository.retrieve(reference_wiping.allocator(), query[0..end], now(self.io), @min(max_bytes, k.max_retrieval_bytes));
        if (self.containsSecret(reference)) {
            reference_wiping.allocator().free(reference);
            self.publish(.failed, error.SensitiveMemoryMaterial);
            return error.SensitiveMemoryMaterial;
        }
        return reference;
    }

    pub fn enqueue(self: *Coordinator, capture: *const k.Capture) !void {
        if (!self.config.value.memory.auto or capture.incomplete or capture.sources.items.len == 0 or !self.acceptance_valid.load(.acquire)) return;
        if (self.isPoisoned()) return error.CleanupFailed;
        var wiping: cfg.WipingAllocator = .{ .backing = self.allocator };
        var scratch = std.heap.ArenaAllocator.init(wiping.allocator());
        defer scratch.deinit();
        const a = scratch.allocator();
        const generation = self.accepted_generation.load(.acquire);
        for (capture.sources.items) |source| if (self.containsSecret(source.text)) return error.SensitiveMemoryMaterial;
        // Stable task material ID; generation prevents a forgotten fact being
        // revived by an old job, while repeat processing is idempotent.
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
        var queue = queue_module.Queue.init(&self.root);
        queue.tryEnqueue(a, material) catch |err| {
            // Generation is checked under the shared root transaction lock;
            // stale material is skipped, never republished after forgetting.
            // Contention remains an auxiliary failure, never a primary wait.
            if (err == error.GenerationConflict) return;
            return err;
        };
        _ = self.state.cmpxchgStrong(@backingInt(State.idle), @backingInt(State.queued), .acq_rel, .acquire);
        _ = self.work_version.fetchAdd(1, .acq_rel);
        self.wake.store(true, .release);
    }

    pub fn reportFailure(self: *Coordinator, err: anyerror) void {
        self.publish(.failed, err);
    }
    fn materialExpired(material: k.Material, stamp: u64) bool {
        return stamp < material.created_ms or stamp - material.created_ms > 86400000;
    }
    fn now(io: std.Io) u64 {
        const value = std.Io.Clock.real.now(io).toMilliseconds();
        return @intCast(@max(0, value));
    }
    fn work(self: *Coordinator) void {
        var lease: ?c_int = null;
        defer if (lease) |fd| fs.closeFd(fd);
        while (!self.stop.load(.acquire)) {
            if (self.wake.load(.acquire)) {
                if (self.config.value.model.protocol == .auto and self.service_override == null) {
                    const protocol: p.Protocol = @fromBackingInt(@intCast(self.confirmed_protocol.load(.acquire)));
                    if (protocol == .auto) {
                        std.Io.sleep(self.io, .fromMilliseconds(40), .awake) catch return;
                        continue;
                    }
                    self.extractor.?.bindProtocol(protocol) catch |err| {
                        self.publish(.failed, err);
                        return;
                    };
                }
                var queue = queue_module.Queue.init(&self.root);
                if (lease == null) {
                    var wiping: cfg.WipingAllocator = .{ .backing = self.allocator };
                    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
                    defer arena.deinit();
                    lease = queue.acquireWorker(arena.allocator()) catch |err| {
                        if (err != error.Busy) self.publish(.failed, err);
                        std.Io.sleep(self.io, .fromMilliseconds(40), .awake) catch return;
                        continue;
                    };
                    queue.recover(arena.allocator()) catch |err| {
                        self.publish(.failed, err);
                        return;
                    };
                }
                const version = self.work_version.load(.acquire);
                self.processPending() catch |err| {
                    if (err != error.Canceled) self.publish(.failed, err);
                    if (err == error.CleanupFailed or err == error.Canceled) return;
                };
                self.settled_version.store(version, .release);
            }
            std.Io.sleep(self.io, .fromMilliseconds(40), .awake) catch return;
        }
    }
    fn processPending(self: *Coordinator) !void {
        if (self.cancel.isRequested()) return error.Canceled;
        var wiping = cfg.WipingAllocator{ .backing = self.allocator };
        var arena = std.heap.ArenaAllocator.init(wiping.allocator());
        defer arena.deinit();
        const a = arena.allocator();
        var queue = queue_module.Queue.init(&self.root);
        const jobs = try queue.pending(a);
        for (jobs) |job| {
            if (self.cancel.isRequested()) return error.Canceled;
            self.processing.store(true, .release);
            defer self.processing.store(false, .release);
            if (job.generation != try self.store.generation() or materialExpired(job, now(self.io))) {
                try queue.mark(a, job.id, .done);
                self.publish(.skipped, null);
                continue;
            }
            // Persist the at-most-once send boundary BEFORE an inference call.
            // A crash after this point requires an explicit retry, never replay.
            try queue.mark(a, job.id, .sending);
            self.publish(.running, null);
            self.process(a, job) catch |err| {
                if (err == error.SensitiveMemoryMaterial or err == error.ExpiredMemoryMaterial) {
                    // Credentials or validity can change while work is pending.
                    // Drop its plaintext rather than offer paid replay.
                    queue.mark(a, job.id, .done) catch |mark_err| {
                        if (mark_err != error.FileNotFound) return mark_err;
                    };
                    if (err == error.ExpiredMemoryMaterial) self.publish(.skipped, null) else self.publish(.failed, err);
                    continue;
                }
                queue.mark(a, job.id, .uncertain) catch {};
                self.publish(.uncertain, err);
                if (err == error.CleanupFailed) return err;
                continue;
            };
            try queue.mark(a, job.id, .done);
            _ = self.completed.fetchAdd(1, .acq_rel);
        }
    }
    fn process(self: *Coordinator, a: std.mem.Allocator, source: k.Material) !void {
        if (materialExpired(source, now(self.io))) return error.ExpiredMemoryMaterial;
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
            // Manual corrections are untrusted too. Omit a complete related
            // entry, never redact part of its evidence or send a known key.
            if (self.containsSecret(entry.content) or self.containsSecret(entry.topic) or k.sensitiveMaterial(entry.content)) continue;
            try related.append(a, entry);
        }
        material.related = related.items;
        const service = self.service_override orelse if (self.extractor) |client| client.service() else return error.MemoryUnavailable;
        const candidates = try service.extract(a, material, &self.cancel);
        // Validate whole output before the first possible write.
        try k.validate(material, candidates);
        if (self.cancel.isRequested()) return error.Canceled;
        if (materialExpired(source, now(self.io))) return error.ExpiredMemoryMaterial;
        for (candidates) |candidate| {
            if (self.containsSecret(candidate.topic) or self.containsSecret(candidate.content) or self.containsSecret(candidate.quote)) return error.SensitiveMemoryMaterial;
        }
        var saved: usize = 0;
        for (candidates) |candidate| {
            if (self.cancel.isRequested()) return error.Canceled;
            switch (try repository.inspect(a, material, candidate)) {
                .unchanged, .expired => continue,
                .conflict => return error.MemoryConflict,
                .created, .updated => {},
            }
            if (self.review_override orelse if (self.reviewer) |client| client.service() else null) |reviewer| {
                const output = try reviewer.decide(a, .{ .memory_write = .{ .topic = candidate.topic, .content = candidate.content, .expected_version = candidate.expected_version } }, &self.cancel);
                if (output != .memory_write) return error.InvalidDecision;
                if (!output.memory_write) continue;
            }
            if (self.cancel.isRequested()) return error.Canceled;
            if (materialExpired(source, now(self.io))) return error.ExpiredMemoryMaterial;
            const result = try repository.apply(a, material, candidate);
            switch (result) {
                .created, .updated => saved += 1,
                .conflict => return error.MemoryConflict,
                .unchanged, .expired => {},
            }
        }
        self.publish(if (saved == 0) .skipped else .saved, null);
    }

    /// Bounded natural-exit drain. Reconfiguration/Off calls deinit directly and
    /// cancels instead of silently issuing remaining queued requests.
    pub fn finish(self: *Coordinator) void {
        self.finishCancellable(null);
    }
    pub fn finishCancellable(self: *Coordinator, interrupted: ?*const fn () bool) void {
        if (self.future == null or !self.wake.load(.acquire)) return;
        const version = self.work_version.load(.acquire);
        const start = std.Io.Clock.awake.now(self.io);
        const deadline_ms = @min(self.config.value.limits.request_timeout_ms, 30000);
        // No filesystem lock or plaintext queue copy on the exiting owner.
        // An enqueue during an old worker pass cannot be mistaken for settled.
        while (self.settled_version.load(.acquire) < version) {
            if (interrupted) |check| if (check()) break;
            if (self.isPoisoned()) break;
            if (start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= deadline_ms) break;
            std.Io.sleep(self.io, .fromMilliseconds(5), .awake) catch break;
        }
    }
    pub fn deinit(self: *Coordinator) void {
        self.stop.store(true, .release);
        self.cancel.cancel();
        if (self.future) |*future| future.cancel(self.io);
        if (self.reviewer) |reviewer| reviewer.deinit();
        if (self.extractor) |client| client.deinit();
        self.releaseSecrets();
        cfg.release(&self.config);
        self.root.deinit();
        self.allocator.destroy(self);
    }
};

test "automatic memory material age rejects future time and expires after bounded validity" {
    var material: k.Material = .{ .id = "synthetic", .generation = 0, .created_ms = 100, .sources = &.{} };
    try std.testing.expect(Coordinator.materialExpired(material, 99));
    try std.testing.expect(!Coordinator.materialExpired(material, 100));
    try std.testing.expect(!Coordinator.materialExpired(material, 100 + 86400000));
    try std.testing.expect(Coordinator.materialExpired(material, 101 + 86400000));
    material.created_ms = std.math.maxInt(u64);
    try std.testing.expect(Coordinator.materialExpired(material, 0));
    try std.testing.expect(!Coordinator.materialExpired(material, std.math.maxInt(u64)));
}
