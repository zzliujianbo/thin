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
        self.status.queued_count +|= 1;
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
        self.store = mem.Store.init(&self.root);
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

    pub fn retrieve(self: *Coordinator, a: std.mem.Allocator, query: []const u8) ![]const u8 {
        if (self.isPoisoned()) return error.CleanupFailed;
        if (self.secret_registration_failed) return error.TooManySessionCredentials;
        // Retrieval can run concurrently with an automatic Memory job. Store has
        // mutable transaction state, so use a distinct instance on the same root.
        var store = mem.Store.init(&self.root);
        store.wait_for_lock = false;
        var repository = knowledge.Repository.init(&store);
        var reference_wiping: cfg.WipingAllocator = .{ .backing = a };
        const reference = try repository.retrieve(reference_wiping.allocator(), query, now(self.io));
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
            if (evidence.kind == .user) {
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
                .conflict => return error.MemoryConflict,
                .unchanged, .expired => {},
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
