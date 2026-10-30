//! Project-local automatic Memory finalizer. Independent extraction/review
//! failures are observable but never rewrite an already completed primary task.
//! Finalization is synchronous: an accepted task cannot publish finished/idle
//! until Memory reaches a terminal outcome.
const std = @import("std");
const diag = @import("../core/diagnostics.zig");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const k = @import("../core/knowledge.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const knowledge = @import("../tools/knowledge_store.zig");
const Extractor = @import("memory_client.zig").Client;
const Reviewer = @import("decision_client.zig").Client;
const codex_auth = @import("../core/codex_auth.zig");

pub const State = enum(u8) { idle, finalizing, saved, skipped, failed, uncertain, canceled };
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: fs.Root,
    store: mem.Store,
    config: std.json.Parsed(cfg.Config),
    diagnostics: diag.Sink = .{},
    extractor: ?*Extractor = null,
    reviewer: ?*Reviewer = null,
    /// Test-only provider-independent seam. No fake behavior in production.
    service_override: ?k.Service = null,
    review_override: ?@import("../core/decision.zig").Service = null,
    codex_source: ?codex_auth.CredentialSource = null,
    state: std.atomic.Value(u8) = .init(@backingInt(State.idle)),
    failure: std.atomic.Value(u16) = .init(0),
    completed: std.atomic.Value(u64) = .init(0),
    poisoned: std.atomic.Value(bool) = .init(false),
    accepted_generation: std.atomic.Value(u64) = .init(0),
    acceptance_valid: std.atomic.Value(bool) = .init(false),
    secrets: [34]?[]u8 = @splat(null),
    secret_count: usize = 0,
    secret_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    secret_registration_failed: bool = false,

    pub fn create(a: std.mem.Allocator, io: std.Io, root: *const fs.Root, config: cfg.Config, env: *const std.process.Environ.Map) !*Coordinator {
        return createWithCodexSource(a, io, root, config, env, null);
    }

    pub fn createWithCodexSource(a: std.mem.Allocator, io: std.Io, root: *const fs.Root, config: cfg.Config, env: *const std.process.Environ.Map, source: ?codex_auth.CredentialSource) !*Coordinator {
        const self = try a.create(Coordinator);
        errdefer a.destroy(self);
        var anchored = try root.duplicate();
        errdefer anchored.deinit();
        var owned = try cfg.clone(a, config);
        errdefer cfg.release(&owned);
        self.* = .{ .allocator = a, .io = io, .root = anchored, .store = undefined, .config = owned, .codex_source = source };
        self.store = mem.Store.init(&self.root, owned.value.limits);
        // Automatic finalization is auxiliary and must never hang primary settle
        // behind another process's project transaction.
        self.store.wait_for_lock = false;
        errdefer {
            self.releaseSecrets();
            std.debug.assert(std.c.pthread_mutex_destroy(&self.secret_mutex) == .SUCCESS);
        }
        if (config.provider.api_key) |key| try self.registerSecret(key);
        if (config.provider.codex_oauth) |credential| {
            try self.registerSecret(credential.access_token);
            try self.registerSecret(credential.refresh_token);
        }
        if (env.get(config.provider.api_key_env)) |key| try self.registerSecret(key);
        if (config.registry) |registry| for (registry.providers) |provider| {
            if (provider.connection.api_key) |key| try self.registerSecret(key);
            if (provider.connection.codex_oauth) |credential| {
                try self.registerSecret(credential.access_token);
                try self.registerSecret(credential.refresh_token);
            }
            if (env.get(provider.connection.api_key_env)) |key| try self.registerSecret(key);
        };
        if (config.memory.auto) {
            const guarded_source: ?codex_auth.CredentialSource = if (source != null) .{ .context = self, .acquire_fn = acquireGuardedCodex } else null;
            self.extractor = try Extractor.createWithCodexSource(a, io, config, env, guarded_source);
            errdefer if (self.extractor) |client| client.deinit();
            self.reviewer = try Reviewer.createWithCodexSource(a, io, config, env, guarded_source);
            errdefer if (self.reviewer) |client| client.deinit();
        }
        return self;
    }

    fn acquireGuardedCodex(ctx: ?*anyopaque, a: std.mem.Allocator, alias: []const u8, cancel: ?*const p.Cancellation, timeout: u32) !codex_auth.RequestCredential {
        const self: *Coordinator = @ptrCast(@alignCast(ctx orelse return error.MissingCredentialSource));
        const source = self.codex_source orelse return error.MissingCredentialSource;
        var credential = try source.acquire(a, alias, cancel, timeout);
        errdefer credential.deinit(a);
        const refresh = credential.redaction_refresh_token orelse return error.CodexSecretRegistrationUnavailable;
        if (refresh.len == 0 or credential.access_token.len == 0) return error.CodexSecretRegistrationUnavailable;
        try self.rememberSecret(credential.access_token);
        try self.rememberSecret(refresh);
        return credential;
    }

    pub fn bindDiagnostics(self: *Coordinator, sink: diag.Sink) void {
        self.diagnostics = sink;
        if (self.extractor) |client| client.diagnostics = sink;
        if (self.reviewer) |client| client.diagnostics = sink;
    }

    fn registerSecret(self: *Coordinator, key: []const u8) !void {
        self.rememberSecret(key) catch |err| switch (err) {
            error.TooManySessionCredentials => self.secret_registration_failed = true,
            else => return err,
        };
    }

    fn rememberSecret(self: *Coordinator, key: []const u8) !void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.secret_mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.secret_mutex) == .SUCCESS);
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
        const mutex = &@constCast(self).secret_mutex;
        std.debug.assert(std.c.pthread_mutex_lock(mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(mutex) == .SUCCESS);
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
        if (self.secret_registration_failed) return error.TooManySessionCredentials;
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
        if (self.secret_registration_failed) return error.TooManySessionCredentials;
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
        const candidates = blk: {
            var span = diag.Span.start(self.diagnostics, self.io, .{ .stage = .memory_extract });
            defer span.finish(.ok);
            const result = service.extract(a, material, cancel) catch |err| {
                span.fail(err);
                return err;
            };
            span.record.count = @intCast(@min(result.len, std.math.maxInt(u32)));
            break :blk result;
        };
        if (cancel.isRequested()) return error.Canceled;
        for (candidates) |candidate| {
            if (self.containsSecret(candidate.topic) or self.containsSecret(candidate.content) or self.containsSecret(candidate.quote)) return error.SensitiveMemoryMaterial;
        }
        var saved: usize = 0;
        for (candidates, 0..) |candidate, index| {
            if (cancel.isRequested()) return error.Canceled;
            switch (try repository.inspect(a, material, candidate)) {
                .unchanged, .expired => continue,
                .conflict => return error.MemoryConflict,
                .created, .updated => {},
            }
            if (self.review_override orelse if (self.reviewer) |client| client.service() else null) |reviewer| {
                var span = diag.Span.start(self.diagnostics, self.io, .{ .stage = .memory_review, .candidate_index = @intCast(@min(index, std.math.maxInt(u32))), .count = @intCast(@min(candidates.len, std.math.maxInt(u32))) });
                const output = reviewer.decide(a, .{ .memory_write = .{ .topic = candidate.topic, .content = candidate.content, .expected_version = candidate.expected_version } }, cancel) catch |err| {
                    span.fail(err);
                    return err;
                };
                if (output != .memory_write) {
                    span.fail(error.InvalidDecision);
                    return error.InvalidDecision;
                }
                span.finish(if (output.memory_write) .ok else .skipped);
                if (!output.memory_write) continue;
            }
            if (cancel.isRequested()) return error.Canceled;
            var span = diag.Span.start(self.diagnostics, self.io, .{ .stage = .memory_write, .candidate_index = @intCast(@min(index, std.math.maxInt(u32))), .count = @intCast(@min(candidates.len, std.math.maxInt(u32))) });
            const result = repository.apply(a, material, candidate) catch |err| {
                span.fail(err);
                return err;
            };
            if (result == .conflict) span.fail(error.MemoryConflict) else span.finish(if (result == .unchanged or result == .expired) .skipped else .ok);
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
        std.debug.assert(std.c.pthread_mutex_destroy(&self.secret_mutex) == .SUCCESS);
        cfg.release(&self.config);
        self.root.deinit();
        self.allocator.destroy(self);
    }
};

test "coordinator diagnostics pair extraction reviews and writes" {
    const Capture = struct {
        records: [32]diag.Record = undefined,
        len: usize = 0,
        seq: u64 = 0,
        fn next(raw: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.seq += 1;
            return self.seq;
        }
        fn emit(raw: ?*anyopaque, record: diag.Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.records[self.len] = record;
            self.len += 1;
        }
    };
    const Fake = struct {
        fail: bool = false,
        cancel: bool = false,
        reviews: usize = 0,
        fn extract(raw: *anyopaque, a: std.mem.Allocator, material: k.Material, cancellation: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.cancel) {
                @constCast(cancellation).cancel();
                return error.Canceled;
            }
            if (self.fail) return error.MemoryUnavailable;
            return a.dupe(k.Candidate, &.{
                .{ .category = .preferences, .topic = "first", .content = "Prefers concise explanations.", .source_id = material.sources[0].id, .quote = "prefer concise explanations" },
                .{ .category = .preferences, .topic = "second", .content = "Prefers concise reviews.", .source_id = material.sources[0].id, .quote = "prefer concise explanations" },
            });
        }
        fn review(raw: *anyopaque, _: std.mem.Allocator, _: @import("../core/decision.zig").Input, _: *const p.Cancellation) !@import("../core/decision.zig").Output {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reviews += 1;
            return .{ .memory_write = self.reviews == 1 };
        }
    };
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    var root = try fs.Root.open(a, io, path[0..try tmp.dir.realPath(io, &path)]);
    defer root.deinit();
    var config = try cfg.clone(a, .{ .provider = .{ .base_url = "http://127.0.0.1:1", .api_key = "fixture" }, .selected_provider = "local", .model = .{ .name = "fixture", .protocol = .chat, .context_tokens = 32768, .output_tokens = 8192 }, .limits = .{ .low_price_input = false } });
    defer cfg.release(&config);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const owner = try Coordinator.create(a, io, &root, config.value, &env);
    defer owner.deinit();
    var events: Capture = .{};
    owner.bindDiagnostics(.{ .context = &events, .emit_fn = Capture.emit, .next_fn = Capture.next });
    var fake: Fake = .{};
    owner.service_override = .{ .context = &fake, .extract_fn = Fake.extract };
    owner.review_override = .{ .context = &fake, .decide_fn = Fake.review };
    const text = "I prefer concise explanations in all code reviews.";
    var cancel: p.Cancellation = .{};
    const reference = try owner.retrieve(a, text, 8192);
    a.free(reference);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, text);
    owner.finalize(&capture, .chat, &cancel);
    try std.testing.expectEqualStrings("Memory: saved", owner.notice().?);
    try std.testing.expectEqual(@as(usize, 8), events.len);
    try std.testing.expectEqual(diag.Stage.memory_extract, events.records[0].stage);
    try std.testing.expectEqual(@as(?u32, 0), events.records[2].candidate_index);
    try std.testing.expectEqual(diag.Stage.memory_write, events.records[4].stage);
    try std.testing.expectEqual(@as(?u32, 1), events.records[6].candidate_index);
    try std.testing.expectEqual(diag.Result.skipped, events.records[7].result.?);
    events.len = 0;
    fake.fail = true;
    const again = try owner.retrieve(a, text, 8192);
    a.free(again);
    owner.finalize(&capture, .chat, &cancel);
    try std.testing.expectEqualStrings("MemoryUnavailable", events.records[1].error_name.?.name());
    events.len = 0;
    fake.fail = false;
    fake.cancel = true;
    const last = try owner.retrieve(a, text, 8192);
    a.free(last);
    owner.finalize(&capture, .chat, &cancel);
    try std.testing.expectEqual(diag.Result.canceled, events.records[1].result.?);
}

test "Codex memory secret registration and incomplete source fail closed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    var root = try fs.Root.open(a, io, path[0..try tmp.dir.realPath(io, &path)]);
    defer root.deinit();
    var config = try cfg.clone(a, .{
        .provider = .{ .base_url = "https://chatgpt.com/backend-api/codex", .kind = .openai_codex, .codex_oauth = .{ .access_token = "access-canary", .refresh_token = "refresh-canary", .expires_at_ms = 1 } },
        .selected_provider = "codex",
        .model = .{ .name = "model", .protocol = .responses, .context_tokens = 32768 },
        .limits = .{ .low_price_input = false },
    });
    defer cfg.release(&config);
    try cfg.validate(config.value);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const owner = try Coordinator.create(a, io, &root, config.value, &env);
    defer owner.deinit();
    try std.testing.expect(owner.containsSecret("access-canary"));
    try std.testing.expect(owner.containsSecret("refresh-canary"));
    try std.testing.expectError(error.MissingCredentialSource, Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000));
    const Fake = struct {
        fn acquire(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: []const u8, _: ?*const p.Cancellation, _: u32) !codex_auth.RequestCredential {
            const mode: *u8 = @ptrCast(@alignCast(ctx.?));
            const access = try alloc.dupe(u8, if (mode.* == 2) "new-access-canary" else "rotated-access-canary");
            errdefer alloc.free(access);
            const account = try alloc.dupe(u8, "account");
            errdefer alloc.free(account);
            return .{ .access_token = access, .account_id = account, .redaction_refresh_token = if (mode.* != 0) try alloc.dupe(u8, "rotated-refresh-canary") else null };
        }
    };
    var mode: u8 = 1;
    owner.codex_source = .{ .context = &mode, .acquire_fn = Fake.acquire };
    var credential = try Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000);
    credential.deinit(a);
    try std.testing.expect(owner.containsSecret("rotated-access-canary"));
    try std.testing.expect(owner.containsSecret("rotated-refresh-canary"));
    mode = 0;
    try std.testing.expectError(error.CodexSecretRegistrationUnavailable, Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000));
    while (owner.secret_count < owner.secrets.len) {
        var buffer: [40]u8 = undefined;
        try owner.rememberSecret(try std.fmt.bufPrint(&buffer, "capacity-{d}", .{owner.secret_count}));
    }
    mode = 1;
    var duplicate = try Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000);
    duplicate.deinit(a);
    mode = 2;
    try std.testing.expectError(error.TooManySessionCredentials, Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000));
}
