//! 单生产者本地诊断日志；不参与模型历史、授权或终态决策。
//! 明文日志只替换当前已知 key，不是 vault，也不扫描其他秘密。
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const logs = @import("log_store.zig");
const selections = @import("selection.zig");

const text_limit = 256 * 1024;
const record_limit = 2 * 1024 * 1024;
const omitted = "[omitted]";

const SelectionEvent = struct {
    snapshot: selections.Snapshot,
    seq: u64,
    turn: u64,
    timestamp_ms: i64,
    elapsed_ms: i64,
};

const Item = union(enum) {
    record: []u8,
    selection: SelectionEvent,

    fn size(self: Item) usize {
        return switch (self) {
            .record => |bytes| bytes.len,
            .selection => @sizeOf(SelectionEvent),
        };
    }
};

pub const Journal = struct {
    const queue_limit = 128;
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
    enabled: bool = true,
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

    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    wake: std.Io.Event = .unset,
    queue: [queue_limit]Item = undefined,
    head: usize = 0,
    count: usize = 0,
    outstanding: usize = 0,
    bytes: usize = 0,
    stopping: bool = false,
    done: bool = false,
    worker: ?std.Io.Future(void) = null,
    // Tests only: cancellable stall without filesystem I/O.
    test_stall: if (@import("builtin").is_test) std.atomic.Value(bool) else void = if (@import("builtin").is_test) .init(false) else {},

    fn lock(self: *Journal) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }

    fn unlock(self: *Journal) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }

    fn fail(self: *Journal, err: anyerror) void {
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
        self.head = (self.head + 1) % queue_limit;
        self.count -= 1;
        return data;
    }

    fn enqueue(self: *Journal, data: []u8) !void {
        try self.enqueueItem(.{ .record = data });
    }

    fn enqueueItem(self: *Journal, data: Item) !void {
        self.lock();
        if (self.stopping or self.outstanding == queue_limit or data.size() > byte_limit - self.bytes) {
            const stopped = self.stopping;
            self.unlock();
            return if (stopped) error.LogStopped else error.LogQueueFull;
        }
        self.queue[(self.head + self.count) % queue_limit] = data;
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
        self.lock();
        self.stopping = true;
        self.unlock();
        self.wake.set(self.root.io);
        self.wait(true);
    }

    fn wait(self: *Journal, finishing: bool) void {
        if (self.worker == null) return;
        const deadline = std.Io.Clock.awake.now(self.root.io).toMilliseconds() + 1000;
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

    /// Owner-only, with no active observer producer. Preparation may extend
    /// redaction before a save, but never forgets an earlier credential.
    pub fn rememberKey(self: *Journal, key: []const u8) !void {
        if (key.len == 0 or key.len > 16384) return error.InvalidApiKey;
        for (key) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidApiKey;
        if (self.isKey(key)) return;
        if (self.known_key_count == self.known_keys.len) return error.TooManySessionCredentials;
        const owned = try self.allocator.dupe(u8, key);
        self.known_keys[self.known_key_count] = owned;
        self.known_key_count += 1;
    }

    fn isKey(self: *const Journal, value: []const u8) bool {
        if (self.key.len != 0 and std.mem.eql(u8, self.key, value)) return true;
        for (self.known_keys[0..self.known_key_count]) |key| if (std.mem.eql(u8, key, value)) return true;
        return false;
    }
    const SecretMatch = struct { at: usize, len: usize };
    fn nextSecret(self: *const Journal, value: []const u8) ?SecretMatch {
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
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
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

    /// 仅在 Runtime.run 之前调用，不与生产者并发。
    pub fn setEnabled(self: *Journal, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Owner-only, producer joined. No disk I/O or capacity wait after connection
    /// publication. Lazy writer creation can fail but never rolls back a live selection.
    pub fn setSelection(self: *Journal, candidate: anyerror!selections.Snapshot) void {
        const snapshot = candidate catch |err| {
            if (self.enabled) self.fail(err);
            return;
        };
        if (self.nextSecret(snapshot.model()) != null) {
            if (self.enabled) self.fail(error.SensitiveSelection);
            return;
        }
        self.selection = snapshot;
        if (!self.enabled or (!self.started and !self.resumed) or self.failure() != null) return;
        self.enqueueSelection() catch |err| self.fail(err);
    }

    fn enqueueSelection(self: *Journal) !void {
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

    pub fn observer(self: *Journal) r.Observer {
        return .{ .context = self, .notify_fn = notify };
    }

    fn notify(ctx: ?*anyopaque, observation: r.Observation) void {
        const self: *Journal = @ptrCast(@alignCast(ctx.?));
        if (!self.enabled or self.failure() != null or !self.accepting()) return;
        var wiping = WipingAllocator{ .backing = self.allocator };
        var arena = std.heap.ArenaAllocator.init(wiping.allocator());
        defer arena.deinit();
        self.observe(arena.allocator(), observation) catch |err| {
            self.fail(err);
        };
    }

    fn record(self: *Journal, a: std.mem.Allocator, event: []const u8, data: anytype) !void {
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
    }

    fn observe(self: *Journal, a: std.mem.Allocator, observation: r.Observation) !void {
        if (observation == .submitted) {
            self.turn = try std.math.add(u64, self.turn, 1);
            self.began_ms = std.Io.Clock.awake.now(self.root.io).toMilliseconds();
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
                // Ephemeral display snapshots are not canonical archive data.
                .tool_views, .tool_view => {},
                .state => |v| {
                    if (v == .calling_model or v == .compacting) self.first = false;
                    try self.record(a, "state", .{ .state = v });
                },
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
                .finished => |v| try self.record(a, "finished", .{ .status = v.status, .detail = if (v.detail) |err| @errorName(err) else null, .model_failure = v.model_failure, .http_status = v.http_status, .usage = v.usage }),
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

    /// 小字符串不预分配 256 KiB；扩容有硬上限，失败不会产生半个 JSON 字符串。
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

fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
}

test "selection snapshots are lazy ordered and save the last switch without another submission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    const id = "0123456789abcdef0123456789abcdef".*;
    try journal.pinSessionID(id);
    var config: @import("../core/config.zig").Config = .{
        .provider = .{ .base_url = "https://fixture.invalid/v1" },
        .model = .{ .name = "first-fixture", .protocol = .chat, .context_tokens = 32768 },
    };
    journal.setSelection(selections.capture(config));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    journal.observer().notify(.{ .submitted = "fixture goal" });
    config.model.name = "last-fixture";
    config.model.protocol = .responses;
    config.model.reasoning_effort = "high";
    journal.setSelection(selections.capture(config));
    journal.flush();
    try std.testing.expect(journal.failure() == null);
    const data = try root.read(std.testing.allocator, journal.store.path(), 0, 8192);
    defer std.testing.allocator.free(data.data);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, data.data, "\"event\":\"selection\""));
    try std.testing.expect(std.mem.indexOf(u8, data.data, "\"model\":\"last-fixture\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data.data, "\"protocol\":\"responses\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data.data, "\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, data.data, "https://fixture.invalid") == null);
    try std.testing.expect(std.mem.find(u8, data.data, ".selection.json") == null);
    config.model.name = "prefix-fake-key-suffix";
    journal.setSelection(selections.capture(config));
    try std.testing.expectEqual(error.SensitiveSelection, journal.failure().?);
    try std.testing.expect(std.mem.find(u8, data.data, "prefix-fake-key-suffix") == null);
}

test "no log selection updates create no snapshot or archive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.setEnabled(false);
    const config: @import("../core/config.zig").Config = .{
        .provider = .{ .base_url = "https://fixture.invalid/v1" },
        .model = .{ .name = "fixture", .context_tokens = 32768 },
    };
    journal.setSelection(selections.capture(config));
    journal.observer().notify(.{ .submitted = "not recorded" });
    journal.setSelection(selections.capture(config));
    journal.finish();
    try std.testing.expect(journal.failure() == null);
    try std.testing.expectEqual(@as(u64, 0), journal.seq);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
}

test "journal retains multiple keys and redacts overlapping and encoded credentials" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(a, &root, "fake-key");
    defer journal.deinit();
    try journal.rememberKey("fake-key-longer");
    try journal.rememberKey("other-key");
    try journal.rememberKey("other-key");
    try std.testing.expectEqual(@as(usize, 2), journal.known_key_count);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    try std.testing.expectEqualStrings("[redacted] [redacted] [redacted]", try journal.safe(temp, "fake-key-longer other-key fake-key"));
    const encoded = try journal.jsonText(temp, "{\"key\":\"other\\u002dkey\"}");
    try std.testing.expectEqualStrings("{\"key\":\"[redacted]\"}", encoded.text);
    try std.testing.expectError(error.InvalidApiKey, journal.rememberKey("bad\nkey"));
    for (2..journal.known_keys.len) |index| {
        var buffer: [40]u8 = undefined;
        try journal.rememberKey(try std.fmt.bufPrint(&buffer, "fake-rotation-{d}", .{index}));
    }
    try std.testing.expectError(error.TooManySessionCredentials, journal.rememberKey("fake-excess"));
    try journal.rememberKey("other-key"); // Dedup remains allowed at the bound.
    try std.testing.expectEqualStrings("[redacted]", try journal.safe(temp, "other-key"));
}

test "journal recursively redacts encoded JSON content without reformatting untouched text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const key = "nested-\"-\\-secret";
    var journal = try Journal.init(std.testing.allocator, &root, key);
    defer journal.deinit();
    var wiping = WipingAllocator{ .backing = std.testing.allocator };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const inner = try std.json.Stringify.valueAlloc(a, .{ .secret = key }, .{});
    const outer = try std.json.Stringify.valueAlloc(a, .{ .content = inner }, .{});
    const redacted = try journal.jsonText(a, outer);
    const result = try std.json.parseFromSlice(std.json.Value, a, redacted.text, .{});
    const content = try std.json.parseFromSlice(std.json.Value, a, result.value.object.get("content").?.string, .{});
    try std.testing.expectEqualStrings("[redacted]", content.value.object.get("secret").?.string);
    try std.testing.expect(!redacted.omitted and !redacted.truncated);
    const args = try journal.jsonValue(a, outer);
    const argument_content = try std.json.parseFromSlice(std.json.Value, a, args.value.object.get("content").?.string, .{});
    try std.testing.expectEqualStrings("[redacted]", argument_content.value.object.get("secret").?.string);
    const untouched = " { \"keep\": [1, true] } ";
    try std.testing.expectEqualStrings(untouched, (try journal.jsonText(a, untouched)).text);

    // 对象字段名也可以是完整的 JSON 字符串，不能只对值递归。
    var keyed: std.json.ObjectMap = .{};
    try keyed.put(a, inner, .{ .string = "value" });
    const keyed_input = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = keyed }, .{});
    const keyed_output = try journal.jsonValue(a, keyed_input);
    const decoded_key = try std.json.parseFromSlice(std.json.Value, a, keyed_output.value.object.keys()[0], .{});
    try std.testing.expectEqualStrings("[redacted]", decoded_key.value.object.get("secret").?.string);
}

test "journal omits duplicated permission body and redacts JSON encoded call identifiers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-secret");
    defer journal.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = "{\"secret\":\"fake\\u002dsecret\"}";
    const action = @import("../tools/tools.zig").Action{ .memory = .{ .action = .write, .topic = "core", .content = content } };
    const description = try action.description(a);
    const arguments = try std.json.Stringify.valueAlloc(a, action.memory, .{});
    const observer = journal.observer();
    observer.notify(.{ .submitted = "fixture" });
    observer.notify(.{ .event = .{ .assistant_committed = &.{.{ .tool_call = .{ .id = content, .name = "memory", .arguments = arguments } }} } });
    observer.notify(.{ .event = .{ .permission = .{ .id = 7, .tool_name = "memory", .description = description } } });
    observer.notify(.{ .decision = .{ .id = 7, .value = .deny } });
    observer.notify(.{ .tool_completed = .{ .call_id = content, .result = .{ .text = "User denied this action", .is_error = true } } });
    observer.notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const file = try root.read(a, journal.store.path(), 0, record_limit);
    var lines = std.mem.splitScalar(u8, file.data, '\n');
    var permission_seen = false;
    var ids: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        const event = parsed.value.object.get("event").?.string;
        const data = parsed.value.object.get("data").?.object;
        if (std.mem.eql(u8, event, "permission")) {
            permission_seen = true;
            const saved = data.get("description").?.object;
            try std.testing.expect(saved.get("omitted").?.bool);
            try std.testing.expectEqualStrings(omitted, saved.get("text").?.string);
            try std.testing.expectEqual(description.len, @as(usize, @intCast(saved.get("source_bytes").?.integer)));
        }
        if (data.get("call_id")) |id| {
            ids += 1;
            const decoded = try std.json.parseFromSlice(std.json.Value, a, id.string, .{});
            try std.testing.expectEqualStrings("[redacted]", decoded.value.object.get("secret").?.string);
        }
    }
    try std.testing.expect(permission_seen);
    try std.testing.expectEqual(@as(usize, 2), ids);
}

test "journal small records use stack scratch and large retry preserves envelope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var wiping = WipingAllocator{ .backing = counted.allocator() };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    journal.began_ms = std.Io.Clock.awake.now(root.io).toMilliseconds();
    try journal.record(arena.allocator(), "state", .{ .state = r.State.calling_model });
    try journal.record(arena.allocator(), "usage", p.Usage{ .input_tokens = 123 });
    try std.testing.expectEqual(@as(usize, 0), counted.allocations);
    try std.testing.expectEqual(@as(usize, 0), counted.allocated_bytes);

    const payload: [8192]u8 = @splat('x');
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, journal.record(failing.allocator(), "large", .{ .text = &payload }));
    try std.testing.expectEqual(@as(u64, 2), journal.seq);
    try journal.record(arena.allocator(), "large", .{ .text = &payload });
    try std.testing.expect(counted.allocated_bytes >= record_limit - 64);
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const content = try root.read(std.testing.allocator, journal.store.path(), 0, record_limit);
    defer std.testing.allocator.free(content.data);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var seq: i64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        seq += 1;
        try std.testing.expectEqual(seq, parsed.value.object.get("seq").?.integer);
        if (seq == 3) try std.testing.expectEqualStrings(&payload, parsed.value.object.get("data").?.object.get("text").?.string);
    }
    try std.testing.expectEqual(@as(i64, 3), seq);
}

fn expectWriterWaiting(journal: *Journal) !void {
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (@atomicLoad(std.Io.Event, &journal.wake, .acquire) != .waiting) {
        try std.testing.expectEqual(null, journal.failure());
        try std.testing.expect(start.untilNow(std.testing.io, .awake).toMilliseconds() < 1000);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
}

test "journal enqueue wakes idle consumer and finish wakes empty consumer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.observer().notify(.{ .submitted = "first" });
    journal.flush();
    for (0..16) |_| {
        try expectWriterWaiting(&journal);
        const previous = journal.seq;
        journal.observer().notify(.{ .event = .{ .state = .calling_model } });
        journal.flush();
        try std.testing.expectEqual(previous + 1, journal.seq);
    }
    try expectWriterWaiting(&journal);
    journal.finish();
    try std.testing.expectEqual(null, journal.failure());
    try std.testing.expect(journal.done and journal.worker == null);
    try std.testing.expectEqual(@as(usize, 0), journal.outstanding);
    try std.testing.expectEqual(@as(usize, 0), journal.bytes);
}

fn canceledWriterWait(_: ?*anyopaque, _: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
    return error.Canceled;
}

test "journal idle writer failure is visible and never accepts stranded records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var table = root.io.vtable.*;
    table.futexWait = canceledWriterWait;
    root.io.vtable = &table;
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.observer().notify(.{ .submitted = "fixture" });
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (true) {
        journal.lock();
        const done = journal.done;
        journal.unlock();
        if (done) break;
        try std.testing.expect(start.untilNow(std.testing.io, .awake).toMilliseconds() < 1000);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    try std.testing.expectEqual(error.Canceled, journal.failure().?);
    const seq = journal.seq;
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    try std.testing.expectEqual(seq, journal.seq);
    journal.flush();
    try std.testing.expect(journal.worker == null);
    try std.testing.expectEqual(@as(usize, 0), journal.outstanding);
}

test "journal structured records redaction turns and first response" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const key = "fake\"\\secret";
    var journal = try Journal.init(std.testing.allocator, &root, key);
    defer journal.deinit();
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    const fixed_id: [32]u8 = @splat('a');
    try journal.pinSessionID(fixed_id);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    const observer = journal.observer();
    observer.notify(.{ .submitted = "hello fake\"\\secret" });
    observer.notify(.{ .event = .{ .state = .calling_model } });
    observer.notify(.{ .event = .{ .text = "" } });
    observer.notify(.{ .event = .{ .reasoning = "NEVER_STORE_REASONING" } });
    observer.notify(.{ .event = .{ .text = "STREAM_ONLY" } });
    observer.notify(.{ .event = .{ .tool_preview = .{ .index = 0, .arguments = "NEVER_STORE_PREVIEW" } } });
    const blocks: []const p.Block = &.{
        .{ .text = "answer fake\"\\secret" },
        .{ .reasoning = "NEVER_STORE_REASONING" },
        .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments = "{\"nested\":[\"fake\\\"\\\\secret\"],\"escaped\":\"fake\\u0022\\u005csecret\"}" } },
    };
    observer.notify(.{ .event = .{ .assistant_committed = blocks } });
    observer.notify(.{ .event = .{ .permission = .{ .id = 7, .tool_name = "read", .description = "read file" } } });
    observer.notify(.{ .decision = .{ .id = 7, .value = .allow_once } });
    observer.notify(.{ .event = .{ .tool_started = .{ .id = 7, .name = "read" } } });
    observer.notify(.{ .tool_completed = .{ .call_id = "call_1", .result = .{ .text = "{\"value\":\"fake\\u0022\\u005csecret\"}", .canceled = true } } });
    observer.notify(.{ .event = .{ .tool_result = .{ .id = 7, .name = "read", .result = .{ .text = "NEVER_DUPLICATE_BODY" } } } });
    observer.notify(.{ .event = .{ .finished = .{ .status = .failed, .detail = error.TestFailure, .http_status = 503 } } });
    observer.notify(.{ .submitted = "second" });
    observer.notify(.{ .event = .{ .state = .compacting } });
    observer.notify(.{ .event = .{ .tool_preview = .{ .index = 0, .arguments = "hidden" } } });
    observer.notify(.{ .event = .{ .text = "hidden" } });
    observer.notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    try std.testing.expectError(error.SessionIDAlreadyStarted, journal.pinSessionID(fixed_id));
    try std.testing.expectEqualSlices(u8, &fixed_id, &journal.store.session_id);
    const content = try root.read(std.testing.allocator, journal.store.path(), 0, record_limit);
    defer std.testing.allocator.free(content.data);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"session\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"") != null);
    for ([_][]const u8{ key, "fake", "NEVER_", "STREAM_ONLY" }) |secret| try std.testing.expect(std.mem.indexOf(u8, content.data, secret) == null);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var seq: i64 = 0;
    var turn: i64 = 1;
    var first_count: usize = 0;
    var tool_count: usize = 0;
    var assistant_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        seq += 1;
        try std.testing.expectEqual(seq, obj.get("seq").?.integer);
        try std.testing.expectEqualStrings(&journal.store.session_id, obj.get("session").?.string);
        try std.testing.expectEqual(@as(i64, 1), obj.get("schema").?.integer);
        try std.testing.expect(obj.get("timestamp_ms").?.integer > 0);
        try std.testing.expect(obj.get("elapsed_ms").?.integer >= 0);
        const event = obj.get("event").?.string;
        const data = obj.get("data").?.object;
        if (std.mem.eql(u8, event, "user") and std.mem.eql(u8, data.get("text").?.string, "second")) turn = 2;
        try std.testing.expectEqual(turn, obj.get("turn").?.integer);
        if (std.mem.eql(u8, event, "first_response")) first_count += 1;
        if (std.mem.eql(u8, event, "permission") or std.mem.eql(u8, event, "decision")) {
            try std.testing.expectEqual(@as(i64, 7), data.get("id").?.integer);
            try std.testing.expect(data.get("host_id") == null);
        }
        if (std.mem.eql(u8, event, "assistant")) {
            assistant_count += 1;
            try std.testing.expectEqualStrings("answer [redacted]", data.get("text").?.string);
        }
        if (std.mem.eql(u8, event, "tool_call")) {
            const args = data.get("arguments").?.object;
            try std.testing.expectEqualStrings("[redacted]", args.get("nested").?.array.items[0].string);
            try std.testing.expectEqualStrings("[redacted]", args.get("escaped").?.string);
        }
        if (std.mem.eql(u8, event, "tool_result")) {
            tool_count += 1;
            try std.testing.expectEqualStrings("call_1", data.get("call_id").?.string);
            try std.testing.expect(data.get("canceled").?.bool);
            try std.testing.expectEqualStrings("{\"value\":\"[redacted]\"}", data.get("text").?.string);
        }
        if (std.mem.eql(u8, event, "finished") and turn == 1) {
            try std.testing.expectEqualStrings("TestFailure", data.get("detail").?.string);
            try std.testing.expectEqual(@as(i64, 503), data.get("http_status").?.integer);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), first_count);
    try std.testing.expectEqual(@as(usize, 1), tool_count);
    try std.testing.expectEqual(@as(usize, 1), assistant_count);
    try std.testing.expectEqual(@as(i64, 2), turn);
}

test "journal disabled is lazy and storage failure is sticky" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.setEnabled(false);
    journal.observer().notify(.{ .submitted = "ignored" });
    journal.flush();
    try std.testing.expect(journal.worker == null);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    journal.setEnabled(true);
    journal.store.limits.record_bytes = 0;
    journal.observer().notify(.{ .submitted = "failure" });
    journal.flush();
    try std.testing.expect(journal.worker == null);
    try std.testing.expectEqual(error.InvalidLimits, journal.failure().?);
    journal.setEnabled(true);
    journal.store.limits.record_bytes = record_limit;
    journal.observer().notify(.{ .submitted = "still disabled" });
    try std.testing.expectEqual(error.InvalidLimits, journal.failure().?);
    try std.testing.expect(journal.seq <= 2);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
}

test "journal bounded UTF8 payload and oversized encoded record continue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "x");
    defer journal.deinit();
    const large = try std.testing.allocator.alloc(u8, text_limit + 2);
    defer std.testing.allocator.free(large);
    for (0..large.len / 3) |i| @memcpy(large[i * 3 ..][0..3], "中");
    journal.observer().notify(.{ .submitted = large });
    journal.observer().notify(.{ .tool_completed = .{ .call_id = "x", .result = .{ .text = large } } });
    // Each visible field is bounded, but JSON escaping can exceed the record cap.
    const control = try std.testing.allocator.alloc(u8, text_limit);
    defer std.testing.allocator.free(control);
    @memset(control, 1);
    journal.observer().notify(.{ .event = .{ .assistant_committed = &.{.{ .tool_call = .{ .id = control, .name = control, .arguments = "{}" } }} } });
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const content = try root.read(std.testing.allocator, journal.store.path(), 0, record_limit);
    defer std.testing.allocator.free(content.data);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"omitted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "record_limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"event\":\"finished\"") != null);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) try std.testing.expect(try std.json.validate(std.testing.allocator, line));
    }
}

test "journal nested omissions and real filesystem failure are explicit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    var wiping = WipingAllocator{ .backing = std.testing.allocator };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    var nested: [141]u8 = undefined;
    @memset(nested[0..70], '[');
    nested[70] = '0';
    @memset(nested[71..], ']');
    const json = try journal.jsonValue(arena.allocator(), &nested);
    try std.testing.expect(json.dropped);
    const text = try journal.jsonText(arena.allocator(), &nested);
    try std.testing.expect(text.omitted and text.truncated);
    const quoted = try journal.jsonText(arena.allocator(), "\"fake-key\"");
    try std.testing.expectEqualStrings("\"[redacted]\"", quoted.text);
    var numeric = try Journal.init(std.testing.allocator, &root, "1234567890");
    defer numeric.deinit();
    const number_text = try numeric.jsonText(arena.allocator(), "[1234567890,1]");
    try std.testing.expectEqualStrings("[\"[redacted]\",1]", number_text.text);
    try root.dir.writeFile(std.testing.io, .{ .sub_path = ".thin", .data = "not a directory" });
    journal.observer().notify(.{ .submitted = "not persisted" });
    journal.flush();
    try std.testing.expect(journal.failure() != null);
    const first_error = journal.failure().?;
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    try std.testing.expectEqual(first_error, journal.failure().?);
    try std.testing.expectEqualStrings("", journal.store.path());
}

test "journal flush resumes and finish drains joins and rejects subsequent records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.observer().notify(.{ .submitted = "first" });
    journal.flush();
    try std.testing.expect(journal.worker != null);
    const path = try std.testing.allocator.dupe(u8, journal.store.path());
    defer std.testing.allocator.free(path);
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.finish();
    journal.finish();
    try std.testing.expectEqual(null, journal.failure());
    try std.testing.expect(journal.done and journal.worker == null);
    try std.testing.expectEqual(@as(usize, 0), journal.bytes);
    const seq = journal.seq;
    journal.observer().notify(.{ .submitted = "ignored" });
    try std.testing.expectEqual(seq, journal.seq);
    const content = try root.read(std.testing.allocator, path, 0, record_limit);
    defer std.testing.allocator.free(content.data);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"event\":\"finished\"") != null);
}

test "journal stalled writer notify is independent queue full is sticky and finish cancels joins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.test_stall.store(true, .release);
    const observer = journal.observer();
    observer.notify(.{ .submitted = "queued without disk" });
    for (0..Journal.queue_limit) |_| observer.notify(.{ .event = .{ .state = .calling_model } });
    // All callbacks returned even though the writer cannot perform any I/O.
    // Observer is void: log failures/cancellation cannot replace this terminal.
    const terminal: r.Event = .{ .finished = .{ .status = .success } };
    observer.notify(.{ .event = terminal });
    try std.testing.expectEqual(.success, terminal.finished.status);
    try std.testing.expectEqual(error.LogQueueFull, journal.failure().?);
    try std.testing.expectEqual(@as(u64, Journal.queue_limit), journal.seq);
    journal.lock();
    const count = journal.outstanding;
    const bytes = journal.bytes;
    journal.unlock();
    try std.testing.expectEqual(Journal.queue_limit, count);
    try std.testing.expect(bytes <= Journal.byte_limit);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    journal.finish();
    try std.testing.expectEqual(error.LogQueueFull, journal.failure().?);
    try std.testing.expect(journal.done and journal.worker == null);
    try std.testing.expectEqual(@as(usize, 0), journal.outstanding);
    try std.testing.expectEqual(@as(usize, 0), journal.bytes);
}

test "journal flush and finish timeouts cancel stalled writer without leaking" {
    inline for (.{ false, true }) |finishing| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root = try testRoot(tmp.dir);
        defer root.deinit();
        var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
        defer journal.deinit();
        journal.test_stall.store(true, .release);
        journal.observer().notify(.{ .submitted = "queued" });
        const began = std.Io.Clock.awake.now(root.io).toMilliseconds();
        if (finishing) journal.finish() else journal.flush();
        const elapsed = std.Io.Clock.awake.now(root.io).toMilliseconds() - began;
        try std.testing.expect(elapsed >= 1000 and elapsed < 5000);
        try std.testing.expectEqual(error.LogFlushTimeout, journal.failure().?);
        try std.testing.expect(journal.done and journal.worker == null);
        try std.testing.expectEqual(@as(usize, 0), journal.bytes);
        journal.finish();
        try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    }
}

test "journal queue full drains complete prefix when writer progresses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    // Open only through the writer, then save the borrowed path while quiescent.
    journal.observer().notify(.{ .submitted = "first" });
    journal.flush();
    const path = try std.testing.allocator.dupe(u8, journal.store.path());
    defer std.testing.allocator.free(path);
    journal.test_stall.store(true, .release);
    // Allow one extra accepted record if the writer had already passed its
    // stall check; the next iteration observes the atomic stall.
    for (0..Journal.queue_limit + 2) |_| {
        journal.observer().notify(.{ .event = .{ .state = .calling_model } });
    }
    try std.testing.expectEqual(error.LogQueueFull, journal.failure().?);
    const accepted = journal.seq;
    journal.test_stall.store(false, .release);
    journal.finish();
    try std.testing.expectEqual(error.LogQueueFull, journal.failure().?);
    try std.testing.expect(journal.worker == null and journal.done);
    const content = try root.read(std.testing.allocator, path, 0, record_limit);
    defer std.testing.allocator.free(content.data);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var seq: u64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        seq += 1;
        try std.testing.expectEqual(seq, @as(u64, @intCast(parsed.value.object.get("seq").?.integer)));
    }
    try std.testing.expectEqual(accepted, seq);
}

test "journal queue budgets include popped inflight bytes and entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    // No writer: deterministically hold the full byte budget in flight.
    const data = try std.testing.allocator.alloc(u8, Journal.byte_limit);
    @memset(data, 0);
    try journal.enqueue(data);
    const inflight = journal.pop().?;
    const extra = try std.testing.allocator.dupe(u8, "{}");
    defer std.testing.allocator.free(extra);
    try std.testing.expectError(error.LogQueueFull, journal.enqueue(extra));
    try std.testing.expectEqual(@as(usize, 1), journal.outstanding);
    journal.release(inflight);
    try std.testing.expectEqual(@as(usize, 0), journal.bytes);
}

test "journal allocation failure never escapes observer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var journal = try Journal.init(failing.allocator(), &root, "fake-key");
    defer journal.deinit();
    failing.fail_index = failing.alloc_index;
    journal.observer().notify(.{ .submitted = "accepted independently" });
    try std.testing.expectEqual(error.OutOfMemory, journal.failure().?);
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    try std.testing.expectEqual(@as(u64, 0), journal.seq);
}
