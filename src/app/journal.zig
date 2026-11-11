//! 有界本地诊断日志；不参与模型历史、授权或终态决策。
//! 明文日志只替换当前已知 key，不是 vault，也不扫描其他秘密。
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const diagnostics = @import("../core/diagnostics.zig");
const logs = @import("log_store.zig");
const selections = @import("selection.zig");
const decision = @import("../core/decision.zig");

fn safeDiagnosticCause(d: *const decision.Diagnostic) ?[]const u8 {
    if (d.cause_len == 0 or d.cause_len > d.cause.len) return null;
    const name = d.causeName();
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return null;
    return name;
}

const text_limit = 1 * 1024 * 1024;
const record_limit = 5 * 1024 * 1024;
const omitted = "[omitted]";

const SelectionEvent = struct {
    snapshot: selections.Snapshot,
    seq: u64,
    turn: u64,
    timestamp_ms: i64,
    elapsed_ms: i64,
};

const DiagnosticEvent = struct { record: diagnostics.Record, seq: u64, turn: u64, timestamp_ms: i64, elapsed_ms: i64, dropped_total: u64 };
const Item = union(enum) {
    record: []u8,
    selection: SelectionEvent,
    diagnostic: DiagnosticEvent,

    fn size(self: Item) usize {
        return switch (self) {
            .record => |bytes| bytes.len,
            .selection => @sizeOf(SelectionEvent),
            .diagnostic => 0,
        };
    }
};

pub const Journal = struct {
    const queue_limit = 128;
    const diagnostic_limit = 64;
    const physical_limit = queue_limit + diagnostic_limit;
    const byte_limit = 8 * 1024 * 1024;

    allocator: std.mem.Allocator,
    root: *fs.Root,
    key: []u8,
    /// Retain previous/other configured keys for this session's redaction.
    /// At most 16 additional 16-KiB keys; owner changes these only while joined.
    known_keys: [16][]u8 = undefined,
    known_key_count: usize = 0,
    store: logs.Store,
    protocol: p.Protocol = .auto,
    /// Owned metadata; never borrows old configuration strings.
    /// Recorded in the diagnostic JSONL only. The session checkpoint owns the durable copy.
    selection: ?selections.Snapshot = null,
    failure_code: std.atomic.Value(u16) = .init(0),
    started: bool = false,
    /// An authenticated existing conversation may change selection before its
    /// first submission in this process. Loading alone still starts no writer.
    resumed: bool = false,
    seq: u64 = 0,
    turn: u64 = 0,
    message_index: u64 = 0,
    began_ms: i64 = 0,
    first: bool = false,

    producer_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    key_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    wake: std.Io.Event = .unset,
    queue: [physical_limit]Item = undefined,
    diagnostic_outstanding: usize = 0,
    diagnostic_dropped: std.atomic.Value(u64) = .init(0),
    diagnostic_span: std.atomic.Value(u64) = .init(0),
    diagnostic_ready: std.atomic.Value(bool) = .init(false),
    head: usize = 0,
    count: usize = 0,
    outstanding: usize = 0,
    bytes: usize = 0,
    stopping: bool = false,
    done: bool = false,
    worker: ?std.Io.Future(void) = null,
    // Tests only: cancellable stall without filesystem I/O.
    test_stall: if (@import("builtin").is_test) std.atomic.Value(bool) else void = if (@import("builtin").is_test) .init(false) else {},
    /// Tests may shorten the bounded flush deadline; production keeps 1000ms.
    test_flush_timeout_ms: u32 = 1000,

    fn lock(self: *Journal) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }

    fn unlock(self: *Journal) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }

    fn fail(self: *Journal, err: anyerror) void {
        self.diagnostic_ready.store(false, .release);
        _ = self.failure_code.cmpxchgStrong(0, @intFromError(err), .acq_rel, .acquire);
        self.lock();
        self.stopping = true;
        self.unlock();
        self.wake.set(self.root.io);
    }

    fn accepting(self: *Journal) bool {
        self.lock();
        defer self.unlock();
        return !self.stopping;
    }

    fn release(self: *Journal, data: Item) void {
        const n = data.size();
        if (data == .record) {
            std.crypto.secureZero(u8, data.record);
            self.allocator.free(data.record);
        }
        self.lock();
        self.bytes -= n;
        self.outstanding -= 1;
        if (data == .diagnostic) self.diagnostic_outstanding -= 1;
        self.unlock();
    }

    fn pop(self: *Journal) ?Item {
        self.lock();
        defer self.unlock();
        if (self.count == 0) {
            // Only the single consumer resets, after its previous wait returned.
            // Reset under the queue lock so enqueue cannot lose its wakeup.
            self.wake.reset();
            return null;
        }
        const data = self.queue[self.head];
        self.head = (self.head + 1) % physical_limit;
        self.count -= 1;
        return data;
    }

    fn enqueue(self: *Journal, data: []u8) !void {
        try self.enqueueItem(.{ .record = data });
    }

    fn enqueueItem(self: *Journal, data: Item) !void {
        self.lock();
        if (self.stopping or self.outstanding - self.diagnostic_outstanding == queue_limit or data.size() > byte_limit - self.bytes) {
            const stopped = self.stopping;
            self.unlock();
            return if (stopped) error.LogStopped else error.LogQueueFull;
        }
        self.queue[(self.head + self.count) % physical_limit] = data;
        self.count += 1;
        self.outstanding += 1;
        self.bytes += data.size();
        self.unlock();
        self.wake.set(self.root.io);
    }

    fn writeRecord(self: *Journal, data: []const u8) !void {
        try self.store.start();
        const prefix_len = "{\"session\":\"".len + 32 + "\",".len;
        const line = try self.allocator.alloc(u8, prefix_len + data.len - 1);
        defer {
            std.crypto.secureZero(u8, line);
            self.allocator.free(line);
        }
        _ = try std.fmt.bufPrint(line[0..prefix_len], "{{\"session\":\"{s}\",", .{self.store.session_id});
        @memcpy(line[prefix_len..], data[1..]);
        try self.store.append(line);
    }

    fn writeItem(self: *Journal, item: Item) !void {
        switch (item) {
            .record => |data| try self.writeRecord(data),
            .diagnostic => |event| {
                var buffer: [8192]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buffer);
                const v = event.record;
                try std.json.Stringify.value(.{ .schema = 1, .seq = event.seq, .turn = event.turn, .timestamp_ms = event.timestamp_ms, .elapsed_ms = event.elapsed_ms, .event = "diagnostic", .data = .{
                    .stage = v.stage,
                    .phase = v.phase,
                    .span_id = v.span_id,
                    .origin_turn = if (v.origin) |origin| origin.turn else null,
                    .memory_job_id = v.memory_job_id,
                    .elapsed_ms = v.elapsed_ms,
                    .result = v.result,
                    .error_name = v.error_name,
                    .operation = v.operation,
                    .protocol = v.protocol,
                    .backend = v.backend,
                    .route_hash = v.route_hash,
                    .timeout_ms = v.timeout_ms,
                    .http_status = v.http_status,
                    .model_failure = v.model_failure,
                    .decision_failure = if (v.decision_failure) |*d| .{ .stage = d.stage, .backend = d.backend, .operation = d.operation, .cause = safeDiagnosticCause(d), .http_status = d.http_status, .model_failure = d.model_failure } else null,
                    .candidate_index = v.candidate_index,
                    .count = v.count,
                }, .dropped_total = event.dropped_total }, .{}, &writer);
                try self.writeRecord(writer.buffered());
            },
            .selection => |event| {
                var buffer: [selections.max_bytes]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buffer);
                try std.json.Stringify.value(.{ .schema = 1, .seq = event.seq, .turn = event.turn, .timestamp_ms = event.timestamp_ms, .elapsed_ms = event.elapsed_ms, .event = "selection", .data = event.snapshot.view() }, .{}, &writer);
                try self.writeRecord(writer.buffered());
            },
        }
    }

    fn runWriter(self: *Journal) void {
        defer {
            self.store.deinit();
            while (self.pop()) |data| self.release(data);
            self.lock();
            self.done = true;
            self.unlock();
        }
        while (true) {
            if (@import("builtin").is_test) {
                if (self.test_stall.load(.acquire)) {
                    std.Io.sleep(self.root.io, .fromMilliseconds(5), .awake) catch |err| {
                        self.fail(err);
                        return;
                    };
                    continue;
                }
            }
            if (self.pop()) |data| {
                defer self.release(data);
                self.writeItem(data) catch |err| {
                    self.fail(err);
                    return;
                };
            } else {
                if (!self.accepting()) return;
                self.wake.wait(self.root.io) catch |err| {
                    self.fail(err);
                    return;
                };
            }
        }
    }

    /// One lifecycle owner, producer quiescent. Stable address and a thread-safe
    /// allocator required. Waits for queued/inflight records, not fsync.
    /// A healthy writer remains alive for subsequent records.
    pub fn flush(self: *Journal) void {
        self.wait(false);
    }

    /// Idempotent stop/drain/join. Cancellation is cooperative: uninterruptible
    /// kernel I/O cannot have an absolute wall-clock bound. Never detaches.
    pub fn finish(self: *Journal) void {
        self.diagnostic_ready.store(false, .release);
        self.lock();
        self.stopping = true;
        self.unlock();
        self.wake.set(self.root.io);
        self.wait(true);
    }

    fn wait(self: *Journal, finishing: bool) void {
        if (self.worker == null) return;
        const deadline = std.Io.Clock.awake.now(self.root.io).toMilliseconds() + self.test_flush_timeout_ms;
        while (true) {
            self.lock();
            const done = self.done;
            const drained = self.outstanding == 0;
            const stopping = self.stopping;
            self.unlock();
            if (done) {
                self.worker.?.await(self.root.io);
                self.worker = null;
                return;
            }
            if (!finishing and !stopping and drained) return;
            if (std.Io.Clock.awake.now(self.root.io).toMilliseconds() >= deadline) break;
            std.Io.sleep(self.root.io, .fromMilliseconds(2), .awake) catch break;
        }
        self.fail(error.LogFlushTimeout);
        self.worker.?.cancel(self.root.io);
        self.worker = null;
    }

    /// 不进行 I/O；key 独立持有，root 的生命周期必须覆盖 Journal。
    pub fn init(a: std.mem.Allocator, root: *fs.Root, key: []const u8) !Journal {
        return .{ .allocator = a, .root = root, .key = try a.dupe(u8, key), .store = logs.Store.init(a, root, .{}) };
    }

    /// Thread-safe registration; never forget an earlier credential.
    pub fn rememberKey(self: *Journal, key: []const u8) !void {
        if (key.len == 0 or key.len > 16384) return error.InvalidApiKey;
        for (key) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidApiKey;
        std.debug.assert(std.c.pthread_mutex_lock(&self.key_mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.key_mutex) == .SUCCESS);
        if (self.isKeyUnlocked(key)) return;
        if (self.known_key_count == self.known_keys.len) return error.TooManySessionCredentials;
        const owned = try self.allocator.dupe(u8, key);
        self.known_keys[self.known_key_count] = owned;
        self.known_key_count += 1;
    }

    /// Read-only while Runtime owns an accepted task. Reject entire memory
    /// evidence rather than persisting a partly redacted credential-bearing log.
    pub fn containsSecret(self: *const Journal, value: []const u8) bool {
        return self.nextSecret(value) != null;
    }

    fn isKey(self: *const Journal, value: []const u8) bool {
        const mutex = &@constCast(self).key_mutex;
        std.debug.assert(std.c.pthread_mutex_lock(mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(mutex) == .SUCCESS);
        return self.isKeyUnlocked(value);
    }

    fn isKeyUnlocked(self: *const Journal, value: []const u8) bool {
        if (self.key.len != 0 and std.mem.eql(u8, self.key, value)) return true;
        for (self.known_keys[0..self.known_key_count]) |key| if (std.mem.eql(u8, key, value)) return true;
        return false;
    }
    const SecretMatch = struct { at: usize, len: usize };
    fn nextSecret(self: *const Journal, value: []const u8) ?SecretMatch {
        const mutex = &@constCast(self).key_mutex;
        std.debug.assert(std.c.pthread_mutex_lock(mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(mutex) == .SUCCESS);
        var found: ?SecretMatch = null;
        for (0..self.known_key_count + 1) |index| {
            const key = if (index == 0) self.key else self.known_keys[index - 1];
            if (key.len == 0) continue;
            if (std.mem.find(u8, value, key)) |at| {
                if (found == null or at < found.?.at or (at == found.?.at and key.len > found.?.len)) found = .{ .at = at, .len = key.len };
            }
        }
        return found;
    }

    pub fn deinit(self: *Journal) void {
        self.finish();
        if (!self.done) self.store.deinit(); // No writer ever owned the store.
        std.debug.assert(self.outstanding == 0 and self.bytes == 0);
        std.debug.assert(std.c.pthread_mutex_destroy(&self.producer_mutex) == .SUCCESS);
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
        std.debug.assert(std.c.pthread_mutex_destroy(&self.key_mutex) == .SUCCESS);
        std.crypto.secureZero(u8, self.key);
        self.allocator.free(self.key);
        self.key = &.{};
        for (self.known_keys[0..self.known_key_count]) |key| {
            std.crypto.secureZero(u8, key);
            self.allocator.free(key);
        }
        self.known_key_count = 0;
    }

    /// Lifecycle owner only, before any producer/writer starts. No storage I/O.
    pub fn pinSessionID(self: *Journal, id: [32]u8) !void {
        if (self.started or self.worker != null or self.seq != 0) return error.SessionIDAlreadyStarted;
        try self.store.pinSessionID(id);
    }

    /// Owner-only, producer joined. No disk I/O or capacity wait after connection
    /// publication. Lazy writer creation can fail but never rolls back a live selection.
    pub fn setSelection(self: *Journal, candidate: anyerror!selections.Snapshot) void {
        const snapshot = candidate catch |err| {
            self.fail(err);
            return;
        };
        if (self.nextSecret(snapshot.model()) != null) {
            self.fail(error.SensitiveSelection);
            return;
        }
        self.selection = snapshot;
        if ((!self.started and !self.resumed) or self.failure() != null) return;
        self.enqueueSelection() catch |err| self.fail(err);
    }

    fn enqueueSelection(self: *Journal) !void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.producer_mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.producer_mutex) == .SUCCESS);
        const snapshot = self.selection orelse return;
        const next = try std.math.add(u64, self.seq, 1);
        if (self.worker == null) {
            if (!self.accepting()) return error.LogStopped;
            self.worker = try std.Io.concurrent(self.root.io, runWriter, .{self});
        }
        try self.enqueueItem(.{ .selection = .{
            .snapshot = snapshot,
            .seq = next,
            .turn = self.turn,
            .timestamp_ms = std.Io.Clock.real.now(self.root.io).toMilliseconds(),
            .elapsed_ms = @max(0, std.Io.Clock.awake.now(self.root.io).toMilliseconds() - self.began_ms),
        } });
        self.seq = next;
    }

    /// 唯一允许 UI 线程并发读取的状态。
    pub fn failure(self: *const Journal) ?anyerror {
        const code = self.failure_code.load(.acquire);
        return if (code == 0) null else @errorFromInt(code);
    }

    pub fn diagnosticSink(self: *Journal) diagnostics.Sink {
        return .{ .context = self, .emit_fn = diagnosticEmit, .next_fn = diagnosticNext };
    }

    /// Capture on the Runtime owner thread before the originating turn finishes.
    pub fn memoryDiagnosticSink(self: *Journal) diagnostics.Sink {
        std.debug.assert(std.c.pthread_mutex_lock(&self.producer_mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.producer_mutex) == .SUCCESS);
        var sink = self.diagnosticSink();
        sink.origin = .{ .turn = self.turn, .began_ms = self.began_ms };
        return sink;
    }

    fn diagnosticActive(self: *Journal) bool {
        return self.diagnostic_ready.load(.acquire) and self.failure() == null;
    }

    fn diagnosticNext(ctx: ?*anyopaque) u64 {
        const self: *Journal = @ptrCast(@alignCast(ctx.?));
        if (!self.diagnosticActive()) return 0;
        var current = self.diagnostic_span.load(.monotonic);
        while (current != std.math.maxInt(u64)) {
            if (self.diagnostic_span.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual| {
                current = actual;
            } else return current + 1;
        }
        return 0;
    }

    fn diagnosticEmit(ctx: ?*anyopaque, record_: diagnostics.Record) void {
        const self: *Journal = @ptrCast(@alignCast(ctx.?));
        if (!self.diagnosticActive()) return;
        if (std.c.pthread_mutex_trylock(&self.producer_mutex) != .SUCCESS) {
            _ = self.diagnostic_dropped.fetchAdd(1, .monotonic);
            return;
        }
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.producer_mutex) == .SUCCESS);
        if (std.c.pthread_mutex_trylock(&self.mutex) != .SUCCESS) {
            _ = self.diagnostic_dropped.fetchAdd(1, .monotonic);
            return;
        }
        if (self.stopping or self.diagnostic_outstanding == diagnostic_limit or self.seq == std.math.maxInt(u64)) {
            self.unlock();
            _ = self.diagnostic_dropped.fetchAdd(1, .monotonic);
            return;
        }
        const next = self.seq + 1;
        const origin = record_.origin orelse diagnostics.Origin{ .turn = self.turn, .began_ms = self.began_ms };
        self.queue[(self.head + self.count) % physical_limit] = .{ .diagnostic = .{
            .record = record_,
            .seq = next,
            .turn = origin.turn,
            .timestamp_ms = std.Io.Clock.real.now(self.root.io).toMilliseconds(),
            .elapsed_ms = @max(0, std.Io.Clock.awake.now(self.root.io).toMilliseconds() -| origin.began_ms),
            .dropped_total = self.diagnostic_dropped.load(.monotonic),
        } };
        self.seq = next;
        self.count += 1;
        self.outstanding += 1;
        self.diagnostic_outstanding += 1;
        self.unlock();
        self.wake.set(self.root.io);
    }

    pub fn observer(self: *Journal) r.Observer {
        return .{ .context = self, .notify_fn = notify };
    }

    fn notify(ctx: ?*anyopaque, observation: r.Observation) void {
        const self: *Journal = @ptrCast(@alignCast(ctx.?));
        if (self.failure() != null or !self.accepting()) return;
        var wiping = WipingAllocator{ .backing = self.allocator };
        var arena = std.heap.ArenaAllocator.init(wiping.allocator());
        defer arena.deinit();
        self.observe(arena.allocator(), observation) catch |err| {
            self.fail(err);
        };
    }

    fn record(self: *Journal, a: std.mem.Allocator, event: []const u8, data: anytype) !void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.producer_mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.producer_mutex) == .SUCCESS);
        var small: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &small);
        var large: ?[]u8 = null;
        defer if (large) |buffer| a.free(buffer);
        var writer = std.Io.Writer.fixed(&small);
        const timestamp = std.Io.Clock.real.now(self.root.io).toMilliseconds();
        const elapsed = @max(0, std.Io.Clock.awake.now(self.root.io).toMilliseconds() - self.began_ms);
        const next = try std.math.add(u64, self.seq, 1);
        const envelope = .{ .schema = 1, .seq = next, .turn = self.turn, .timestamp_ms = timestamp, .elapsed_ms = elapsed, .event = event, .data = data };
        std.json.Stringify.value(envelope, .{}, &writer) catch {
            // Fixed writers only fail when full. Retry once at the original cap;
            // the observation's wiping arena owns this uncommon allocation.
            large = try a.alloc(u8, record_limit - 64);
            writer = std.Io.Writer.fixed(large.?);
            std.json.Stringify.value(envelope, .{}, &writer) catch {
                // 固定缓冲写满不产生半行，也不终止日志；保留 envelope 与省略原因。
                writer = std.Io.Writer.fixed(large.?);
                try std.json.Stringify.value(.{ .schema = 1, .seq = next, .turn = self.turn, .timestamp_ms = timestamp, .elapsed_ms = elapsed, .event = event, .data = .{ .omitted = true, .reason = "record_limit" } }, .{}, &writer);
            };
        };
        const owned = try self.allocator.dupe(u8, writer.buffered());
        errdefer {
            std.crypto.secureZero(u8, owned);
            self.allocator.free(owned);
        }
        if (self.worker == null) self.worker = try std.Io.concurrent(self.root.io, runWriter, .{self});
        try self.enqueue(owned);
        self.seq = next;
        if (self.started and self.failure() == null) self.diagnostic_ready.store(true, .release);
    }

    fn observe(self: *Journal, a: std.mem.Allocator, observation: r.Observation) !void {
        if (observation == .submitted) {
            std.debug.assert(std.c.pthread_mutex_lock(&self.producer_mutex) == .SUCCESS);
            self.turn = std.math.add(u64, self.turn, 1) catch |err| {
                std.debug.assert(std.c.pthread_mutex_unlock(&self.producer_mutex) == .SUCCESS);
                return err;
            };
            self.began_ms = std.Io.Clock.awake.now(self.root.io).toMilliseconds();
            std.debug.assert(std.c.pthread_mutex_unlock(&self.producer_mutex) == .SUCCESS);
            self.first = false;
            if (!self.started) {
                self.started = true;
                const selection_view: ?selections.Snapshot.View = if (self.selection) |*snapshot| snapshot.view() else null;
                try self.record(a, "session", .{ .protocol = self.protocol, .selection = selection_view, .format = "jsonl", .text_bytes = text_limit, .record_bytes = record_limit, .plaintext = true, .redaction = "known_key_only" });
                try self.enqueueSelection();
            }
            const t = try self.jsonText(a, observation.submitted);
            try self.record(a, "user", t);
            return;
        }
        if (!self.started) return;
        switch (observation) {
            .submitted => unreachable,
            .decision => |d| try self.record(a, "decision", .{ .id = d.id, .value = d.value }),
            .tool_completed => |c| {
                const t = try self.jsonText(a, c.result.text);
                try self.record(a, "tool_result", .{ .call_id = (try self.jsonText(a, c.call_id)).text, .text = t.text, .source_bytes = t.source_bytes, .is_error = c.result.is_error, .canceled = c.result.canceled, .truncated = c.result.truncated or t.truncated, .omitted = t.omitted, .cleanup_failed = c.result.cleanup_failed });
            },
            .event => |event| switch (event) {
                .text => |v| try self.firstResponse(a, "text", v.len),
                .reasoning => |v| try self.firstResponse(a, "reasoning", v.len),
                .tool_preview => |v| try self.firstResponse(a, "tool_preview", v.arguments.len),
                // Ephemeral display snapshots and owner-only Memory notices
                // are not canonical archive or diagnostic records.
                .tool_views, .tool_view, .memory_completed, .background_completed => {},
                .state => |v| {
                    if (v == .calling_model or v == .compacting) self.first = false;
                    try self.record(a, "state", .{ .state = v });
                },
                .user_committed => |value| {
                    // Runtime re-publishes the accepted direct input under id 0
                    // before the first model call so the checkpoint stays
                    // resumable. The submitted notification already logged that
                    // user row; only nonzero steering ids add a second row.
                    if (value.id == r.direct_input_id) return;
                    // Steering belongs to the accepted task, not a new submitted
                    // turn. Use the same bounded known-key redaction as prompts.
                    const t = try self.jsonText(a, value.text);
                    try self.record(a, "user", .{ .text = t.text, .source_bytes = t.source_bytes, .truncated = t.truncated, .omitted = t.omitted, .delivery = "steering", .input_id = value.id });
                },
                .permission_cleared => |id| try self.record(a, "permission_cleared", .{ .id = id }),
                .assistant_committed => |blocks| {
                    self.message_index = try std.math.add(u64, self.message_index, 1);
                    for (blocks, 0..) |block, index| switch (block) {
                        .text => |v| {
                            const t = try self.jsonText(a, v);
                            try self.record(a, "assistant", .{ .text = t.text, .message_index = self.message_index, .block_index = index, .source_bytes = t.source_bytes, .truncated = t.truncated, .omitted = t.omitted });
                        },
                        .tool_call => |v| {
                            const args = try self.jsonValue(a, v.arguments);
                            try self.record(a, "tool_call", .{ .call_id = (try self.jsonText(a, v.id)).text, .name = (try self.jsonText(a, v.name)).text, .arguments = args.value, .source_bytes = v.arguments.len, .omitted = args.dropped, .truncated = args.dropped, .message_index = self.message_index, .block_index = index });
                        },
                        .reasoning, .tool_result => {},
                    };
                },
                // 展示描述是带前缀的非结构化副本（如 Memory + JSON 内容），不能
                // 重新落盘绕过参数的语义脱敏。正文已在 tool_call.arguments 中记录。
                // 原始描述仍完整送往 UI 审批，这里只保留长度与明确省略标记。
                .permission => |v| try self.record(a, "permission", .{ .id = v.id, .tool_name = (try self.jsonText(a, v.tool_name)).text, .description = Text{ .text = omitted, .source_bytes = v.description.len, .truncated = true, .omitted = true } }),
                .tool_started => |v| try self.record(a, "tool_started", .{ .host_id = v.id, .name = (try self.jsonText(a, v.name)).text }),
                .tool_result => |v| try self.record(a, "tool_status", .{ .host_id = v.id, .name = (try self.jsonText(a, v.name)).text, .is_error = v.result.is_error, .canceled = v.result.canceled, .truncated = v.result.truncated, .cleanup_failed = v.result.cleanup_failed }),
                // Display-only estimate: no duplicate archive accounting path.
                .context_snapshot => {},
                .usage => |v| try self.record(a, "usage", v),
                .fallback => |v| try self.record(a, "fallback", .{ .protocol = v }),
                .compacted => |v| try self.record(a, "compacted", v),
                .compaction_failed => |v| try self.record(a, "compaction_failed", .{ .error_name = @errorName(v) }),
                .finished => |v| try self.record(a, "finished", .{
                    .dropped_total = self.diagnostic_dropped.load(.monotonic),
                    .status = v.status,
                    .detail = if (v.detail) |err| @errorName(err) else null,
                    .model_failure = v.model_failure,
                    .http_status = v.http_status,
                    .decision_failure = if (v.decision_failure) |*diagnostic| .{
                        .stage = diagnostic.stage,
                        .backend = diagnostic.backend,
                        .operation = diagnostic.operation,
                        .cause = diagnostic.causeName(),
                        .http_status = diagnostic.http_status,
                        .model_failure = diagnostic.model_failure,
                        .transport_exit_code = diagnostic.transport_exit_code,
                    } else null,
                    .usage = v.usage,
                }),
            },
        }
    }

    fn firstResponse(self: *Journal, a: std.mem.Allocator, kind: []const u8, len: usize) !void {
        if (len == 0 or self.first) return;
        self.first = true;
        try self.record(a, "first_response", .{ .kind = kind });
    }

    const Text = struct { text: []const u8, source_bytes: usize, truncated: bool, omitted: bool };

    fn text(self: *Journal, a: std.mem.Allocator, input: []const u8) !Text {
        const value = try self.safe(a, input);
        const dropped = std.mem.eql(u8, value, omitted) and !std.mem.eql(u8, input, omitted);
        return .{ .text = value, .source_bytes = input.len, .truncated = dropped, .omitted = dropped };
    }

    /// 超大/非法 UTF-8 整体省略，避免截断横跨边界的 key 或多字节字符。
    fn safe(self: *Journal, a: std.mem.Allocator, input: []const u8) ![]const u8 {
        if (input.len > text_limit or !std.unicode.utf8ValidateSlice(input)) return omitted;
        if (self.nextSecret(input) == null) return input;
        const replacement = "[redacted]";
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var rest = input;
        while (self.nextSecret(rest)) |match| {
            if (out.written().len + match.at + replacement.len > text_limit) return omitted;
            try out.writer.writeAll(rest[0..match.at]);
            try out.writer.writeAll(replacement);
            rest = rest[match.at + match.len ..];
        }
        if (out.written().len + rest.len > text_limit) return omitted;
        try out.writer.writeAll(rest);
        return try a.dupe(u8, out.written());
    }

    const Json = struct { value: std.json.Value, dropped: bool = false, parsed: bool = false, changed: bool = false };

    fn jsonValue(self: *Journal, a: std.mem.Allocator, input: []const u8) !Json {
        return self.jsonValueAt(a, input, 0);
    }

    fn jsonValueAt(self: *Journal, a: std.mem.Allocator, input: []const u8, depth: usize) anyerror!Json {
        if (depth >= 64 or input.len > text_limit or !std.unicode.utf8ValidateSlice(input)) return .{ .value = .{ .string = omitted }, .dropped = true, .changed = true };
        const parsed = std.json.parseFromSlice(std.json.Value, a, input, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| {
            if (err == error.OutOfMemory) return err;
            const t = try self.text(a, input);
            return .{ .value = .{ .string = t.text }, .dropped = t.omitted, .changed = !std.mem.eql(u8, t.text, input) };
        };
        // arena 统一拥有解析树；对象字段名也可能来自不可信工具参数。
        var dropped = false;
        var changed = false;
        const value = try self.redactValue(a, parsed.value, depth, &dropped, &changed);
        return .{ .value = value, .dropped = dropped, .parsed = true, .changed = changed };
    }

    fn redactValue(self: *Journal, a: std.mem.Allocator, value: std.json.Value, depth: usize, dropped: *bool, changed: *bool) anyerror!std.json.Value {
        if (depth >= 64) {
            dropped.* = true;
            changed.* = true;
            return .{ .string = omitted };
        }
        var result = value;
        switch (value) {
            .string => |s| {
                // read_file 的 content / write_file 的 content 本身也可能是 JSON。
                // 逐层解码后再脱敏；未改变的字符串保留原始空白与编码形式。
                const nested = try self.jsonValueAt(a, s, depth + 1);
                const plain = try self.text(a, s);
                var clean = plain.text;
                if (nested.parsed and nested.changed) {
                    clean = (try encodeJson(a, nested.value, s.len)) orelse omitted;
                    if (std.mem.eql(u8, clean, omitted)) dropped.* = true;
                } else if (nested.dropped) clean = omitted;
                dropped.* = dropped.* or plain.omitted or nested.dropped;
                changed.* = changed.* or nested.changed or !std.mem.eql(u8, clean, s);
                result = .{ .string = clean };
            },
            .number_string => |s| {
                if (self.nextSecret(s) != null) {
                    result = .{ .string = "[redacted]" };
                    changed.* = true;
                }
            },
            .array => |array| for (array.items) |*item| {
                item.* = try self.redactValue(a, item.*, depth + 1, dropped, changed);
            },
            .object => |object| {
                var clean: std.json.ObjectMap = .{};
                var it = object.iterator();
                while (it.next()) |entry| {
                    const key = (try self.redactValue(a, .{ .string = entry.key_ptr.* }, depth + 1, dropped, changed)).string;
                    dropped.* = dropped.* or clean.contains(key);
                    try clean.put(a, key, try self.redactValue(a, entry.value_ptr.*, depth + 1, dropped, changed));
                }
                result = .{ .object = clean };
            },
            else => {},
        }
        return result;
    }

    /// 小字符串不预分配 1 MiB；扩容有硬上限，失败不会产生半个 JSON 字符串。
    fn encodeJson(a: std.mem.Allocator, value: std.json.Value, hint: usize) !?[]const u8 {
        var capacity = @min(text_limit, @max(@as(usize, 128), hint));
        while (true) {
            const buffer = try a.alloc(u8, capacity);
            var writer = std.Io.Writer.fixed(buffer);
            std.json.Stringify.value(value, .{}, &writer) catch {
                a.free(buffer);
                if (capacity == text_limit) return null;
                capacity = @min(text_limit, capacity * 2);
                continue;
            };
            return writer.buffered();
        }
    }

    fn jsonText(self: *Journal, a: std.mem.Allocator, input: []const u8) !Text {
        if (input.len > text_limit or self.isKey(input)) return self.text(a, input);
        const json = try self.jsonValue(a, input);
        if (!json.parsed) return .{ .text = json.value.string, .source_bytes = input.len, .truncated = json.dropped, .omitted = json.dropped };
        if (!json.changed) return .{ .text = input, .source_bytes = input.len, .truncated = json.dropped, .omitted = json.dropped };
        const encoded = (try encodeJson(a, json.value, input.len)) orelse return .{ .text = omitted, .source_bytes = input.len, .truncated = true, .omitted = true };
        return .{ .text = encoded, .source_bytes = input.len, .truncated = json.dropped, .omitted = json.dropped };
    }
};

/// 擦除 arena 的整个 backing allocation（包括失败路径和已废弃的缓冲）。
const WipingAllocator = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, bytes);
        self.backing.rawFree(bytes, alignment, ra);
    }
};
