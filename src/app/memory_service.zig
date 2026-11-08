//! Project-local automatic Memory finalizer. Independent extraction
//! failures are observable but never rewrite an already completed primary task.
//! Jobs are copied into an owned, heap-stable FIFO and finalized by one owned
//! asynchronous worker; the Runtime only enqueues before publishing finished;
//! only headless exit explicitly drains. A parent-side failure never rewrites a job outcome.
const std = @import("std");
const builtin = @import("builtin");
const diag = @import("../core/diagnostics.zig");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const k = @import("../core/knowledge.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const knowledge = @import("../tools/knowledge_store.zig");
const Extractor = @import("memory_client.zig").Client;
const codex_auth = @import("../core/codex_auth.zig");
const memory_status = @import("../core/memory_status.zig");
const notifications = @import("memory_notifications.zig");

pub const State = enum(u8) { idle, finalizing, saved, skipped, failed, uncertain, canceled };

/// One job's frozen outcome. Terminal classification uses this value rather
/// than the parent-visible failure that reportFailure() may update concurrently.
const Outcome = struct {
    state: State = .idle,
    err: ?anyerror = null,
    saved_count: u32 = 0,
    summary: memory_status.Summary = .{},

    fn set(self: *Outcome, state: State, err: ?anyerror) void {
        self.state = state;
        self.err = err;
    }
};

const Job = struct {
    next: ?*Job = null,
    id: u64 = 0,
    wiping: cfg.WipingAllocator,
    arena: std.heap.ArenaAllocator,
    capture: k.Capture,
    protocol: p.Protocol,
    cancel: p.Cancellation = .{},
    sink: diag.Sink,
    outcome: Outcome = .{},
    notification: ?*notifications.Node = null,

    fn destroy(self: *Job, a: std.mem.Allocator) void {
        self.arena.deinit();
        std.crypto.secureZero(u8, std.mem.asBytes(&self.outcome));
        a.destroy(self);
    }
};
pub const SecretGuard = struct {
    context: *anyopaque,
    contains_fn: *const fn (*anyopaque, []const u8) bool,
};

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: fs.Root,
    store: mem.Store,
    config: std.json.Parsed(cfg.Config),
    diagnostics: diag.Sink = .{},
    extractor: ?*Extractor = null,
    /// Test-only provider-independent seam. No fake behavior in production.
    service_override: ?k.Service = null,
    codex_source: ?codex_auth.CredentialSource = null,
    failure: std.atomic.Value(u16) = .init(0),
    poisoned: std.atomic.Value(bool) = .init(false),
    secrets: [34]?[]u8 = @splat(null),
    secret_count: usize = 0,
    secret_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    secret_registration_failed: bool = false,
    /// Bound before use; points to the owning App's stable journal.
    secret_guard: ?SecretGuard = null,
    queue_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    wake: std.Io.Event = .unset,
    future: ?std.Io.Future(void) = null,
    head: ?*Job = null,
    tail: ?*Job = null,
    active_job: ?*Job = null,
    stopped: bool = false,
    next_id: u64 = 0,
    status: memory_status.View = .{},
    /// Session-owned, stable until all coordinators have joined. Null for
    /// standalone/headless owners; never changed after this owner starts work.
    notification_queue: ?*notifications.Queue = null,
    /// Test-only, gated worker-wait failure seam. Production has no branch.
    wait_ready: if (builtin.is_test) std.atomic.Value(bool) else void = if (builtin.is_test) .init(false) else {},
    fail_wait: if (builtin.is_test) std.atomic.Value(bool) else void = if (builtin.is_test) .init(false) else {},
    /// 0 idle, 1 worker paused after a gated wait failure, 2 released by test.
    fail_wait_gate: if (builtin.is_test) std.atomic.Value(u8) else void = if (builtin.is_test) .init(0) else {},

    fn lock(self: *Coordinator) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.queue_mutex) == .SUCCESS);
    }
    fn unlock(self: *Coordinator) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.queue_mutex) == .SUCCESS);
    }

    pub fn view(self: *const Coordinator) memory_status.View {
        const mutable = @constCast(self);
        mutable.lock();
        defer mutable.unlock();
        var result = self.status;
        result.enabled = self.config.value.memory.auto;
        return result;
    }

    /// Bind before any admission; a replacement receives the same Session sink.
    pub fn bindNotifications(self: *Coordinator, queue: ?*notifications.Queue) void {
        self.lock();
        defer self.unlock();
        std.debug.assert(self.future == null and self.head == null and self.active_job == null);
        self.notification_queue = queue;
    }

    fn statusTerminal(self: *Coordinator, value: memory_status.Terminal) void {
        self.status.last_terminal = value;
        self.status.revision +%= 1;
    }

    /// Caller holds the coordinator lock, which also orders publications.
    fn notifyTerminal(self: *Coordinator, value: memory_status.Terminal, node: ?*notifications.Node) void {
        if (self.notification_queue) |queue| {
            if (node) |reserved| {
                queue.publish(reserved, value);
            } else if (queue.reserve()) |reserved| {
                queue.publish(reserved, value);
            }
        } else std.debug.assert(node == null);
    }

    /// A reserved job terminal requires no allocation at publication. A
    /// reservation-OOM path makes one attempt in notifyTerminal instead.
    fn terminal(self: *Coordinator, value: memory_status.Terminal, node: ?*notifications.Node) void {
        self.statusTerminal(value);
        self.notifyTerminal(value, node);
    }

    fn admissionFailure(self: *Coordinator, id: u64, err: anyerror, node: ?*notifications.Node) void {
        self.lock();
        defer self.unlock();
        self.terminal(.{ .id = id, .result = .failed, .failure = classifyFailure(err) }, node);
    }

    /// Safe value-only admission diagnostic: bounded error name, no prompt text
    /// and no primary-task failure. Emitted for every rejected enqueue.
    fn emitAdmissionFailure(sink: diag.Sink, id: u64, err: anyerror) void {
        var local = sink;
        if (id != 0) local.memory_job_id = id;
        local.emit(.{
            .stage = .memory_submit,
            .phase = .point,
            .result = .failed,
            .error_name = diag.ErrorName.fromError(err),
            .memory_job_id = if (id == 0) null else id,
        });
    }

    pub fn enqueueCopy(self: *Coordinator, capture: *const k.Capture, protocol: p.Protocol, sink: diag.Sink) !u64 {
        // Every rejected admission preserves the headless error/cleanup poison;
        // its existing admission path publishes the sole display terminal.
        return self.enqueueCopyInner(capture, protocol, sink) catch |err| {
            self.publishFailure(err);
            return err;
        };
    }

    fn enqueueCopyInner(self: *Coordinator, capture: *const k.Capture, protocol: p.Protocol, sink: diag.Sink) !u64 {
        // Reserve independently of Job/capture before any fallible admission
        // work. Even a rejected attempt gets its own terminal when possible.
        const node: ?*notifications.Node = if (self.notification_queue) |queue| queue.reserve() else null;
        if (self.notification_queue != null and node == null) {
            // The optional display channel must not impose a Memory job limit.
            // Explicitly diagnose the only case in which even our emergency
            // reservation failed; publication will make one more attempt.
            sink.emit(.{
                .stage = .memory_submit,
                .phase = .point,
                .result = .failed,
                .error_name = diag.ErrorName.fromError(error.MemoryNotificationReservationUnavailable),
            });
        }
        self.lock();
        if (self.stopped or !self.config.value.memory.auto) {
            self.unlock();
            self.admissionFailure(0, error.MemoryUnavailable, node);
            emitAdmissionFailure(sink, 0, error.MemoryUnavailable);
            return error.MemoryUnavailable;
        }
        // Never wrap an exhausted id to a previously used job id.
        if (self.next_id == std.math.maxInt(u64)) {
            self.unlock();
            self.admissionFailure(0, error.MemoryIdExhausted, node);
            emitAdmissionFailure(sink, 0, error.MemoryIdExhausted);
            return error.MemoryIdExhausted;
        }
        self.next_id += 1;
        const id = self.next_id;
        self.unlock();
        if (capture.incomplete) {
            self.admissionFailure(id, error.IncompleteCapture, node);
            emitAdmissionFailure(sink, id, error.IncompleteCapture);
            return error.IncompleteCapture;
        }
        const job = self.allocator.create(Job) catch |err| {
            self.admissionFailure(id, err, node);
            emitAdmissionFailure(sink, id, err);
            return err;
        };
        job.wiping = .{ .backing = self.allocator };
        job.arena = std.heap.ArenaAllocator.init(job.wiping.allocator());
        job.next = null;
        job.id = id;
        job.protocol = protocol;
        job.cancel = .{};
        job.sink = sink;
        job.sink.memory_job_id = id;
        job.outcome = .{};
        job.notification = node;
        job.capture = .{ .allocator = job.arena.allocator(), .bytes = capture.bytes, .omitted_sources = capture.omitted_sources };
        errdefer job.destroy(self.allocator);
        for (capture.sources.items) |source| {
            const text = job.capture.allocator.dupe(u8, source.text) catch |err| {
                self.admissionFailure(id, err, node);
                emitAdmissionFailure(sink, id, err);
                return err;
            };
            job.capture.sources.append(job.capture.allocator, .{ .id = source.id, .kind = source.kind, .text = text }) catch |err| {
                self.admissionFailure(id, err, node);
                emitAdmissionFailure(sink, id, err);
                return err;
            };
        }
        self.lock();
        if (self.stopped) {
            self.terminal(.{ .id = id, .result = .failed, .failure = .unavailable }, node);
            self.unlock();
            emitAdmissionFailure(sink, id, error.MemoryUnavailable);
            return error.MemoryUnavailable;
        }
        if (self.future == null) {
            self.future = std.Io.concurrent(self.io, worker, .{self}) catch |err| {
                self.terminal(.{ .id = id, .result = .failed, .failure = classifyFailure(err) }, node);
                self.unlock();
                emitAdmissionFailure(sink, id, err);
                return err;
            };
        }
        if (self.tail) |tail| tail.next = job else self.head = job;
        self.tail = job;
        self.status.queued_count += 1;
        self.status.revision +%= 1;
        self.wake.set(self.io);
        self.unlock();
        return id;
    }

    fn worker(self: *Coordinator) void {
        while (true) {
            self.lock();
            if (self.stopped) {
                self.unlock();
                return;
            }
            const job = self.head orelse {
                self.wake.reset();
                if (builtin.is_test) {
                    self.wait_ready.store(true, .release);
                }
                self.unlock();
                self.wake.wait(self.io) catch |err| {
                    self.failPending(err);
                    return;
                };
                if (builtin.is_test) {
                    if (self.fail_wait.swap(false, .acq_rel)) {
                        // Gate the failure so a test can queue more than one job
                        // after the failed wake and before pending publication.
                        self.fail_wait_gate.store(1, .release);
                        var spins: usize = 0;
                        while (self.fail_wait_gate.load(.acquire) == 1 and spins < 2000) : (spins += 1) {
                            self.lock();
                            const stopping = self.stopped;
                            self.unlock();
                            if (stopping) return;
                            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch |err| {
                                self.failPending(err);
                                return;
                            };
                        }
                        if (self.fail_wait_gate.load(.acquire) == 1) {
                            self.failPending(error.TestWaitGateTimeout);
                            return;
                        }
                        self.failPending(error.TestWaitFailure);
                        return;
                    }
                }
                continue;
            };
            self.head = job.next;
            if (self.head == null) self.tail = null;
            self.active_job = job;
            self.status.queued_count -= 1;
            self.status.active = .{ .id = job.id, .phase = .extracting };
            self.status.revision +%= 1;
            self.unlock();
            self.diagnostics = job.sink;
            if (self.extractor) |client| client.diagnostics = job.sink;
            var span = diag.Span.start(job.sink, self.io, .{ .stage = .memory_finalize });
            self.execute(&job.outcome, &job.capture, job.protocol, &job.cancel);
            const outcome = job.outcome;
            if (outcome.err) |err| span.fail(err) else span.finish(if (outcome.state == .skipped) .skipped else .ok);
            const result: memory_status.Result = switch (outcome.state) {
                .saved => .saved,
                .skipped => .skipped,
                .uncertain => .uncertain,
                .canceled => .canceled,
                else => .failed,
            };
            self.lock();
            self.active_job = null;
            self.status.active = null;
            self.publishFailure(outcome.err);
            self.terminal(.{
                .id = job.id,
                .result = result,
                .failure = if (outcome.err) |err| classifyFailure(err) else null,
                .saved_count = outcome.saved_count,
                .summary = outcome.summary,
            }, job.notification);
            self.unlock();
            job.destroy(self.allocator);
        }
    }

    /// The worker can no longer wait. Publish one typed failed terminal for every
    /// queued job, detach the list, then wipe it outside the queue lock. Never
    /// leaves drain watching a queue that no worker will ever consume.
    fn failPending(self: *Coordinator, err: anyerror) void {
        var pending: ?*Job = null;
        self.lock();
        pending = self.head;
        self.head = null;
        self.tail = null;
        self.status.queued_count = 0;
        self.status.active = null;
        self.active_job = null;
        self.stopped = true;
        self.publishFailure(err);
        var cursor = pending;
        while (cursor) |job| : (cursor = job.next) self.terminal(.{ .id = job.id, .result = .failed, .failure = classifyFailure(err) }, job.notification);
        self.status.revision +%= 1;
        self.wake.set(self.io);
        self.unlock();
        cursor = pending;
        while (cursor) |job| {
            cursor = job.next;
            job.destroy(self.allocator);
        }
    }

    fn classifyFailure(err: anyerror) memory_status.Failure {
        return switch (err) {
            error.Canceled => .canceled,
            error.CleanupFailed => .cleanup,
            error.MemoryUnavailable => .unavailable,
            error.Busy => .busy,
            error.MemoryConflict, error.VersionConflict, error.GenerationConflict, error.PathAlreadyExists => .conflict,
            error.InvalidMemoryOutput,
            error.InvalidMemoryVersion,
            error.InvalidMemoryEvidence,
            error.InvalidMemoryCandidate,
            error.DuplicateMemoryCandidate,
            error.InvalidMaterial,
            error.InvalidDecision,
            error.InvalidDecisionOutput,
            error.InvalidKnowledgeRecord,
            error.SensitiveMemoryMaterial,
            error.TooManySessionCredentials,
            => .invalid_output,
            error.FileChanged,
            error.CoreTooLarge,
            error.ShardTooLarge,
            error.IndexTooLarge,
            error.InvalidGeneration,
            error.GenerationOverflow,
            error.NotRegularFile,
            => .storage,
            else => .other,
        };
    }

    fn phase(self: *Coordinator, value: memory_status.Phase) void {
        self.lock();
        defer self.unlock();
        if (self.status.active) |*active| if (active.phase != value) {
            active.phase = value;
            self.status.revision +%= 1;
        };
    }

    pub fn drain(self: *Coordinator, cancel: *const p.Cancellation) void {
        while (true) {
            if (cancel.isRequested()) {
                self.cancelAndJoin();
                return;
            }
            self.lock();
            const done = self.head == null and self.active_job == null;
            const stopped = self.stopped;
            self.unlock();
            if (done) return;
            // A failed worker or an owner-initiated stop must never leave drain
            // polling a queue that cannot make progress.
            if (stopped) {
                self.cancelAndJoin();
                return;
            }
            std.Io.sleep(self.io, .fromMilliseconds(5), .awake) catch {
                self.cancelAndJoin();
                return;
            };
        }
    }

    pub fn cancelAndJoin(self: *Coordinator) void {
        var pending: ?*Job = null;
        self.lock();
        // Idempotent owner-only stop, but still join a finished-but-unawaited
        // worker future before deinit destroys its owner state.
        if (self.stopped and self.future == null and self.head == null and self.active_job == null) {
            self.unlock();
            return;
        }
        self.stopped = true;
        if (self.active_job) |job| job.cancel.cancel();
        pending = self.head;
        self.head = null;
        self.tail = null;
        self.status.queued_count = 0;
        self.status.revision +%= 1;
        self.wake.set(self.io);
        self.unlock();
        // Join before touching pending jobs: the worker may still hold the lock
        // only for bookkeeping, and no deallocation may happen under it.
        if (self.future) |*future| future.await(self.io);
        self.future = null;
        if (pending) |first| {
            self.lock();
            var cursor: ?*Job = first;
            while (cursor) |job| : (cursor = job.next) self.terminal(.{ .id = job.id, .result = .canceled, .failure = .canceled }, job.notification);
            self.unlock();
            cursor = first;
            while (cursor) |job| {
                cursor = job.next;
                job.destroy(self.allocator);
            }
        }
    }

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
            std.debug.assert(std.c.pthread_mutex_destroy(&self.queue_mutex) == .SUCCESS);
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
        // Do not nest the journal key mutex with our own secret mutex.
        if (self.secret_guard) |guard| if (guard.contains_fn(guard.context, text)) return true;
        const mutex = &@constCast(self).secret_mutex;
        std.debug.assert(std.c.pthread_mutex_lock(mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(mutex) == .SUCCESS);
        for (self.secrets[0..self.secret_count]) |key| if (std.mem.find(u8, text, key.?) != null) return true;
        return false;
    }
    pub fn isPoisoned(self: *const Coordinator) bool {
        return self.poisoned.load(.acquire);
    }
    fn publishFailure(self: *Coordinator, err: ?anyerror) void {
        if (err) |failure_| if (failure_ == error.CleanupFailed) self.poisoned.store(true, .release);
        self.failure.store(if (err) |e| @intFromError(e) else 0, .release);
    }

    pub fn retrieve(self: *Coordinator, a: std.mem.Allocator, query: []const u8, max_bytes: usize) ![]const u8 {
        if (self.isPoisoned()) return error.CleanupFailed;
        if (self.secret_registration_failed) return error.TooManySessionCredentials;
        // Retrieval can run concurrently with an automatic Memory job. Store has
        // mutable transaction state, so use a distinct instance on the same root.
        var store = mem.Store.init(&self.root, self.config.value.limits);
        store.wait_for_lock = false;
        if (max_bytes == 0) return a.dupe(u8, "");
        var end = @min(query.len, 8192);
        while (end > 0 and end < query.len and query[end] & 0xc0 == 0x80) end -= 1;
        var repository = knowledge.Repository.init(&store);
        var reference_wiping: cfg.WipingAllocator = .{ .backing = a };
        const reference = try repository.retrieve(reference_wiping.allocator(), query[0..end], now(self.io), @min(max_bytes, k.max_retrieval_bytes));
        if (self.containsSecret(reference)) {
            reference_wiping.allocator().free(reference);
            return error.SensitiveMemoryMaterial;
        }
        return reference;
    }

    /// Execute one job into its private outcome. The parent-visible failure is
    /// not read or written here, so reportFailure() cannot directly rewrite the
    /// job's outcome. Cleanup poison remains shared.
    fn execute(self: *Coordinator, out: *Outcome, capture: *const k.Capture, protocol: p.Protocol, cancel: *const p.Cancellation) void {
        out.* = .{};
        if (!self.config.value.memory.auto) return;
        if (self.isPoisoned()) {
            out.set(.failed, error.CleanupFailed);
            return;
        }
        if (capture.incomplete or capture.sources.items.len == 0) {
            out.set(.skipped, null);
            return;
        }
        if (cancel.isRequested()) {
            out.set(.canceled, error.Canceled);
            return;
        }
        if (self.service_override == null) {
            if (protocol == .auto or protocol == .systemone) {
                out.set(.failed, error.MemoryUnavailable);
                return;
            }
            self.extractor.?.bindProtocol(protocol) catch |err| {
                out.set(.failed, err);
                return;
            };
        }

        out.set(.finalizing, null);
        var wiping: cfg.WipingAllocator = .{ .backing = self.allocator };
        var scratch = std.heap.ArenaAllocator.init(wiping.allocator());
        defer scratch.deinit();
        const a = scratch.allocator();
        // Capture the generation at processing time, not at prompt retrieval:
        // an earlier queued job may legitimately have written in the meantime.
        const generation = self.store.generation() catch |err| {
            out.set(.failed, err);
            return;
        };
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
        self.process(a, out, material, cancel) catch |err| {
            if (err == error.Canceled) out.set(.canceled, err) else if (err == error.MemoryUnavailable) out.set(.uncertain, err) else out.set(.failed, err);
            return;
        };
    }

    /// Test helper: run one capture on the caller's thread, publish its failure,
    /// and return its outcome. Production App only enqueues.
    fn finalize(self: *Coordinator, capture: *const k.Capture, protocol: p.Protocol, cancel: *const p.Cancellation) Outcome {
        var outcome: Outcome = .{};
        self.execute(&outcome, capture, protocol, cancel);
        self.publishFailure(outcome.err);
        return outcome;
    }

    pub fn reportFailure(self: *Coordinator, err: anyerror) void {
        // Publish the headless failure before locking. Job terminals use each
        // job's own outcome, while cleanup poison remains shared.
        self.publishFailure(err);
        self.lock();
        defer self.unlock();
        // Preserve an active job's snapshot and outcome, but independently
        // deliver this non-job failure rather than hiding it in the footer.
        const value: memory_status.Terminal = .{ .id = 0, .result = .failed, .failure = classifyFailure(err) };
        if (self.status.active == null) self.statusTerminal(value);
        self.notifyTerminal(value, null);
    }
    fn now(io: std.Io) u64 {
        const value = std.Io.Clock.real.now(io).toMilliseconds();
        return @intCast(@max(0, value));
    }
    fn process(self: *Coordinator, a: std.mem.Allocator, out: *Outcome, source: k.Material, cancel: *const p.Cancellation) !void {
        if (cancel.isRequested()) return error.Canceled;
        if (self.secret_registration_failed) return error.TooManySessionCredentials;
        var repository = knowledge.Repository.init(&self.store);
        var query: std.ArrayList(u8) = .empty;
        var sources: std.ArrayList(k.Evidence) = .empty;
        for (source.sources) |evidence| {
            if (self.containsSecret(evidence.text) or k.sensitiveMaterial(evidence.text)) continue;
            try sources.append(a, evidence);
            if (evidence.kind == .user and query.items.len + evidence.text.len + 1 <= 8192) {
                try query.appendSlice(a, evidence.text);
                try query.append(a, '\n');
            }
        }
        if (sources.items.len == 0) {
            out.set(.skipped, null);
            return;
        }
        var material = source;
        material.sources = sources.items;
        var related: std.ArrayList(k.Related) = .empty;
        for (try repository.related(a, query.items, now(self.io))) |entry| {
            if (self.containsSecret(entry.content) or self.containsSecret(entry.topic) or k.sensitiveMaterial(entry.content) or k.sensitiveMaterial(entry.topic)) continue;
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
        for (candidates, 0..) |candidate, index| {
            if (cancel.isRequested()) return error.Canceled;
            if (self.containsSecret(candidate.topic) or self.containsSecret(candidate.content)) continue;
            if (cancel.isRequested()) return error.Canceled;
            self.phase(.saving);
            var span = diag.Span.start(self.diagnostics, self.io, .{ .stage = .memory_write, .candidate_index = @intCast(@min(index, std.math.maxInt(u32))), .count = @intCast(@min(candidates.len, std.math.maxInt(u32))) });
            const result = repository.apply(a, material, candidate) catch |err| {
                span.fail(err);
                return err;
            };
            span.finish(if (result == .unchanged or result == .expired or result == .conflict) .skipped else .ok);
            switch (result) {
                .created, .updated => {
                    out.saved_count +|= 1;
                    out.summary.append(std.mem.trim(u8, candidate.content, " \t\r\n"));
                },
                .conflict, .unchanged, .expired => {},
            }
        }
        out.set(if (out.saved_count == 0) .skipped else .saved, null);
    }

    pub fn deinit(self: *Coordinator) void {
        self.cancelAndJoin();
        std.debug.assert(std.c.pthread_mutex_destroy(&self.queue_mutex) == .SUCCESS);
        if (self.extractor) |client| client.deinit();
        self.releaseSecrets();
        std.debug.assert(std.c.pthread_mutex_destroy(&self.secret_mutex) == .SUCCESS);
        cfg.release(&self.config);
        self.root.deinit();
        std.crypto.secureZero(u8, std.mem.asBytes(&self.status));
        self.allocator.destroy(self);
    }
};

const NotificationTestFixture = struct {
    tmp: std.testing.TmpDir,
    queue: *notifications.Queue,
    owner: *Coordinator,

    fn init(io: std.Io) !@This() {
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path: [4096]u8 = undefined;
        var root = try fs.Root.open(a, io, path[0..try tmp.dir.realPath(io, &path)]);
        defer root.deinit();
        var config = try cfg.clone(a, .{
            .provider = .{ .base_url = "http://fixture.invalid", .api_key = "fixture-key" },
            .selected_provider = "local",
            .model = .{ .name = "fixture", .protocol = .chat, .context_tokens = 32768, .output_tokens = 8192 },
            .limits = .{ .low_price_input = false },
        });
        defer cfg.release(&config);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        const queue = try notifications.Queue.create(a);
        errdefer queue.deinit();
        const owner = try Coordinator.create(a, io, &root, config.value, &env);
        owner.bindNotifications(queue);
        return .{ .tmp = tmp, .queue = queue, .owner = owner };
    }

    fn deinit(self: *@This()) void {
        self.owner.deinit();
        self.queue.deinit();
        self.tmp.cleanup();
    }

    fn enqueue(owner: *Coordinator, text: []const u8) !u64 {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var capture: k.Capture = .{ .allocator = arena.allocator() };
        capture.add(.user, text);
        return owner.enqueueCopy(&capture, .chat, .{});
    }

    fn waitBool(io: std.Io, flag: *const std.atomic.Value(bool)) !void {
        const start = std.Io.Clock.awake.now(io);
        while (!flag.load(.acquire)) {
            if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 2000) return error.TestTimeout;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }

    fn waitGate(io: std.Io, flag: *const std.atomic.Value(u8)) !void {
        const start = std.Io.Clock.awake.now(io);
        while (flag.load(.acquire) == 0) {
            if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 2000) return error.TestTimeout;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }
};

test "completed jobs retain full FIFO values beyond last snapshot" {
    const Fake = struct {
        fn extract(_: *anyopaque, a: std.mem.Allocator, material: k.Material, _: *const p.Cancellation) ![]const k.Candidate {
            const text = material.sources[0].text;
            if (std.mem.eql(u8, text, "failure evidence")) return error.InvalidMemoryOutput;
            if (std.mem.eql(u8, text, "canceled evidence")) return error.Canceled;
            const first = std.mem.eql(u8, text, "first saved fact");
            return a.dupe(k.Candidate, &.{.{ .category = .preferences, .topic = if (first) "first" else "second", .content = text }});
        }
    };
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    var context: u8 = 0;
    fixture.owner.service_override = .{ .context = &context, .extract_fn = Fake.extract };
    const reference = try fixture.owner.retrieve(a, "first saved fact", 8192);
    a.free(reference);
    const one = try NotificationTestFixture.enqueue(fixture.owner, "first saved fact");
    const two = try NotificationTestFixture.enqueue(fixture.owner, "second saved fact");
    var cancel: p.Cancellation = .{};
    fixture.owner.drain(&cancel);
    try std.testing.expectEqual(two, fixture.owner.view().last_terminal.?.id);
    try std.testing.expectEqual(one, fixture.queue.peek().?.id);
    try std.testing.expectEqual(one, fixture.queue.peek().?.id);

    const fail_id = try NotificationTestFixture.enqueue(fixture.owner, "failure evidence");
    fixture.owner.drain(&cancel);
    const canceled_id = try NotificationTestFixture.enqueue(fixture.owner, "canceled evidence");
    fixture.owner.drain(&cancel);
    var incomplete: k.Capture = .{ .allocator = a, .incomplete = true };
    try std.testing.expectError(error.IncompleteCapture, fixture.owner.enqueueCopy(&incomplete, .chat, .{}));

    const first = fixture.queue.take().?;
    try std.testing.expectEqual(one, first.id);
    try std.testing.expectEqual(memory_status.Result.saved, first.result);
    try std.testing.expectEqual(@as(u32, 1), first.saved_count);
    try std.testing.expectEqualStrings("first saved fact", first.summary.text());
    const second = fixture.queue.take().?;
    try std.testing.expectEqual(two, second.id);
    try std.testing.expectEqual(memory_status.Result.saved, second.result);
    try std.testing.expectEqual(@as(u32, 1), second.saved_count);
    try std.testing.expectEqualStrings("second saved fact", second.summary.text());
    const failed = fixture.queue.take().?;
    try std.testing.expectEqual(fail_id, failed.id);
    try std.testing.expectEqual(memory_status.Result.failed, failed.result);
    try std.testing.expectEqual(memory_status.Failure.invalid_output, failed.failure.?);
    const canceled = fixture.queue.take().?;
    try std.testing.expectEqual(canceled_id, canceled.id);
    try std.testing.expectEqual(memory_status.Result.canceled, canceled.result);
    try std.testing.expectEqual(memory_status.Failure.canceled, canceled.failure.?);
    const rejected = fixture.queue.take().?;
    try std.testing.expectEqual(canceled_id + 1, rejected.id);
    try std.testing.expectEqual(memory_status.Result.failed, rejected.result);
    try std.testing.expect(fixture.queue.take() == null);
}

test "parent failure while a job is active notifies without changing either outcome" {
    const r = @import("../core/runtime.zig");
    const Fake = struct {
        io: std.Io,
        owner: *Coordinator,
        started: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        fn extract(raw: *anyopaque, a: std.mem.Allocator, _: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started.store(true, .release);
            while (!self.release.load(.acquire)) {
                if (cancel.isRequested()) return error.Canceled;
                try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
            }
            return a.dupe(k.Candidate, &.{.{ .category = .preferences, .topic = "parent-test", .content = "Job result remains saved." }});
        }
        fn call(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.owner.reportFailure(error.Busy);
            return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "Primary success" }} }, .finish = .stop } };
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
            return error.UnexpectedTool;
        }
    };
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    var fake: Fake = .{ .io = io, .owner = fixture.owner };
    fixture.owner.service_override = .{ .context = &fake, .extract_fn = Fake.extract };
    const id = try NotificationTestFixture.enqueue(fixture.owner, "Evidence for a saved job.");
    try NotificationTestFixture.waitBool(io, &fake.started);
    const before = fixture.owner.view();
    try std.testing.expectEqual(id, before.active.?.id);
    var runtime = try r.Runtime.init(a, io, &fixture.owner.config.value, .{ .context = &fake, .call_fn = Fake.call }, .{ .context = &fake, .schemas = &.{}, .prepare_fn = Fake.prepare, .execute_fn = Fake.execute }, .{}, "");
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const primary = try runtime.run("Primary task", &cancel);
    try std.testing.expectEqual(r.Status.success, primary.status);
    const during = fixture.owner.view();
    try std.testing.expectEqual(before.active.?.id, during.active.?.id);
    try std.testing.expectEqualDeep(before.last_terminal, during.last_terminal);
    const failure = fixture.queue.take().?;
    try std.testing.expectEqual(@as(u64, 0), failure.id);
    try std.testing.expectEqual(memory_status.Result.failed, failure.result);
    try std.testing.expectEqual(memory_status.Failure.busy, failure.failure.?);
    fake.release.store(true, .release);
    fixture.owner.drain(&cancel);
    const completed = fixture.queue.take().?;
    try std.testing.expectEqual(id, completed.id);
    try std.testing.expectEqual(memory_status.Result.saved, completed.result);
    try std.testing.expect(completed.failure == null);
    try std.testing.expectEqual(@as(u32, 1), completed.saved_count);
    try std.testing.expectEqualStrings("Job result remains saved.", completed.summary.text());
    try std.testing.expect(fixture.queue.take() == null);
}

test "worker wait failure publishes every pending completion" {
    const Empty = struct {
        fn extract(_: *anyopaque, _: std.mem.Allocator, _: k.Material, _: *const p.Cancellation) ![]const k.Candidate {
            return &.{};
        }
    };
    var backend = std.Io.Threaded.init(std.testing.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    var context: u8 = 0;
    fixture.owner.service_override = .{ .context = &context, .extract_fn = Empty.extract };
    const warm = try NotificationTestFixture.enqueue(fixture.owner, "warmup evidence");
    var cancel: p.Cancellation = .{};
    fixture.owner.drain(&cancel);
    try NotificationTestFixture.waitBool(io, &fixture.owner.wait_ready);
    fixture.owner.fail_wait.store(true, .release);
    const one = try NotificationTestFixture.enqueue(fixture.owner, "first stranded evidence");
    try NotificationTestFixture.waitGate(io, &fixture.owner.fail_wait_gate);
    const two = try NotificationTestFixture.enqueue(fixture.owner, "second stranded evidence");
    fixture.owner.fail_wait_gate.store(2, .release);
    fixture.owner.drain(&cancel);
    fixture.owner.cancelAndJoin();
    try std.testing.expectEqual(warm, fixture.queue.take().?.id);
    const first = fixture.queue.take().?;
    const second = fixture.queue.take().?;
    try std.testing.expectEqual(one, first.id);
    try std.testing.expectEqual(two, second.id);
    try std.testing.expectEqual(memory_status.Result.failed, first.result);
    try std.testing.expectEqual(memory_status.Result.failed, second.result);
    try std.testing.expect(fixture.queue.take() == null);
}

test "cancel joins active and queued jobs before queue release" {
    const Blocked = struct {
        io: std.Io,
        started: std.atomic.Value(bool) = .init(false),
        fn extract(raw: *anyopaque, _: std.mem.Allocator, _: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started.store(true, .release);
            while (!cancel.isRequested()) try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
            return error.Canceled;
        }
    };
    var backend = std.Io.Threaded.init(std.testing.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    var blocked: Blocked = .{ .io = io };
    fixture.owner.service_override = .{ .context = &blocked, .extract_fn = Blocked.extract };
    const one = try NotificationTestFixture.enqueue(fixture.owner, "active cancellation evidence");
    try NotificationTestFixture.waitBool(io, &blocked.started);
    const two = try NotificationTestFixture.enqueue(fixture.owner, "queued cancellation evidence two");
    const three = try NotificationTestFixture.enqueue(fixture.owner, "queued cancellation evidence three");
    fixture.owner.cancelAndJoin();
    for ([_]u64{ one, two, three }) |id| {
        const result = fixture.queue.take().?;
        try std.testing.expectEqual(id, result.id);
        try std.testing.expectEqual(memory_status.Result.canceled, result.result);
    }
    try std.testing.expect(fixture.queue.take() == null);
}

test "notification reservation exhaustion never limits Memory admission" {
    const Gated = struct {
        io: std.Io,
        started: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        fn extract(raw: *anyopaque, _: std.mem.Allocator, _: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started.store(true, .release);
            while (!self.release.load(.acquire)) {
                if (cancel.isRequested()) return error.Canceled;
                try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
            }
            return &.{};
        }
    };
    var backend = std.Io.Threaded.init(std.testing.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    const original = fixture.queue.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.queue.allocator = failing.allocator();
    defer {
        fixture.owner.cancelAndJoin();
        fixture.queue.allocator = original;
    }
    for (0..fixture.queue.emergency.len) |i| {
        fixture.queue.publish(fixture.queue.reserve().?, .{ .id = @intCast(100 + i), .result = .failed });
    }
    var gated: Gated = .{ .io = io };
    fixture.owner.service_override = .{ .context = &gated, .extract_fn = Gated.extract };
    const job = try NotificationTestFixture.enqueue(fixture.owner, "admitted while notifications are exhausted");
    try NotificationTestFixture.waitBool(io, &gated.started);
    // Free one emergency node before completion: publication retries only on
    // this exceptional OOM path and appends without disturbing earlier values.
    try std.testing.expectEqual(@as(u64, 100), fixture.queue.take().?.id);
    gated.release.store(true, .release);
    var cancel: p.Cancellation = .{};
    fixture.owner.drain(&cancel);
    for (101..108) |i| try std.testing.expectEqual(@as(u64, @intCast(i)), fixture.queue.take().?.id);
    const result = fixture.queue.take().?;
    try std.testing.expectEqual(job, result.id);
    try std.testing.expectEqual(memory_status.Result.skipped, result.result);
    try std.testing.expect(fixture.queue.take() == null);
}

test "admission allocation failure produces a reserved terminal" {
    var backend = std.Io.Threaded.init(std.testing.allocator, .{});
    defer backend.deinit();
    var fixture = try NotificationTestFixture.init(backend.io());
    defer fixture.deinit();
    var capture: k.Capture = .{ .allocator = std.testing.allocator };
    const original = fixture.owner.allocator;
    fixture.owner.allocator = std.testing.failing_allocator;
    const result = fixture.owner.enqueueCopy(&capture, .chat, .{});
    fixture.owner.allocator = original;
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(u16, @intFromError(error.OutOfMemory)), fixture.owner.failure.load(.acquire));
    try std.testing.expect(!fixture.owner.isPoisoned());
    const failure = fixture.queue.take().?;
    try std.testing.expectEqual(@as(u64, 1), failure.id);
    try std.testing.expectEqual(memory_status.Result.failed, failure.result);
    try std.testing.expect(fixture.queue.take() == null);
}

test "coordinator diagnostics pair extraction and writes" {
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
        fn extract(raw: *anyopaque, a: std.mem.Allocator, _: k.Material, cancellation: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.cancel) {
                @constCast(cancellation).cancel();
                return error.Canceled;
            }
            if (self.fail) return error.MemoryUnavailable;
            return a.dupe(k.Candidate, &.{
                .{ .category = .preferences, .topic = "first", .content = "Prefers concise explanations." },
                .{ .category = .preferences, .topic = "second", .content = "Prefers concise reviews." },
            });
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
    const text = "I prefer concise explanations in all code reviews.";
    var cancel: p.Cancellation = .{};
    const reference = try owner.retrieve(a, text, 8192);
    a.free(reference);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, text);
    const saved = owner.finalize(&capture, .chat, &cancel);
    try std.testing.expectEqual(State.saved, saved.state);
    try std.testing.expect(saved.err == null);
    try std.testing.expectEqual(@as(u32, 2), saved.saved_count);
    try std.testing.expectEqual(@as(u16, 0), owner.failure.load(.acquire));
    try std.testing.expectEqual(@as(usize, 6), events.len);
    try std.testing.expectEqual(diag.Stage.memory_extract, events.records[0].stage);
    try std.testing.expectEqual(@as(?u32, 0), events.records[2].candidate_index);
    try std.testing.expectEqual(diag.Stage.memory_write, events.records[4].stage);
    try std.testing.expectEqual(@as(?u32, 1), events.records[4].candidate_index);
    events.len = 0;
    fake.fail = true;
    const again = try owner.retrieve(a, text, 8192);
    a.free(again);
    const uncertain = owner.finalize(&capture, .chat, &cancel);
    try std.testing.expectEqual(State.uncertain, uncertain.state);
    try std.testing.expect(uncertain.err.? == error.MemoryUnavailable);
    try std.testing.expectEqual(@as(u16, @intFromError(error.MemoryUnavailable)), owner.failure.load(.acquire));
    try std.testing.expectEqualStrings("MemoryUnavailable", events.records[1].error_name.?.name());
    events.len = 0;
    fake.fail = false;
    fake.cancel = true;
    const last = try owner.retrieve(a, text, 8192);
    a.free(last);
    const canceled = owner.finalize(&capture, .chat, &cancel);
    try std.testing.expectEqual(State.canceled, canceled.state);
    try std.testing.expect(canceled.err.? == error.Canceled);
    try std.testing.expectEqual(@as(u16, @intFromError(error.Canceled)), owner.failure.load(.acquire));
    try std.testing.expectEqual(diag.Result.canceled, events.records[1].result.?);

    owner.reportFailure(error.CleanupFailed);
    try std.testing.expect(owner.isPoisoned());
    try std.testing.expectEqual(@as(u16, @intFromError(error.CleanupFailed)), owner.failure.load(.acquire));
    try std.testing.expectEqual(memory_status.Failure.cleanup, owner.view().last_terminal.?.failure.?);
    var retry_cancel: p.Cancellation = .{};
    const blocked = owner.finalize(&capture, .chat, &retry_cancel);
    try std.testing.expectEqual(State.failed, blocked.state);
    try std.testing.expect(blocked.err.? == error.CleanupFailed);
    try std.testing.expect(owner.isPoisoned());
    try std.testing.expectError(error.CleanupFailed, owner.retrieve(a, text, 8192));
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
