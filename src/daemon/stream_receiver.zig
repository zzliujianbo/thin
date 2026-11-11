//! Single-owner subscription receiver. Only this task touches the stream fd;
//! the consumer takes owned complete frames and never performs socket I/O.
//! Queue saturation stops reads, not the controller/task. Stop is independent
//! of queue capacity and always wakes the task before join.
//!
//! The same bound watch socket carries the coalesced display ACK. The UI only
//! admits the newest watermark through a mutex; this task writes at most one
//! nonblocking ACK frame at a time and keeps reading pages meanwhile. A
//! recognizable ACK reply is consumed here and never becomes a display item, so
//! the control connection keeps its cancel/approval latency budget.
const std = @import("std");
const unix = @import("unix.zig");
const protocol = @import("protocol.zig");
const Cancellation = @import("../core/protocol.zig").Cancellation;
const Wakeup = @import("../platform/wakeup.zig").Wakeup;

/// Bounded, allocation-free set of independently displayed sequence ranges.
/// `first == 0` denotes the prefix `[0, last]`, otherwise the range is
/// inclusive. Overlapping/adjacent ranges merge; a hole between two ranges is
/// never bridged, so an earlier unshown event cannot be claimed by a later
/// one. A full set refuses admission instead of dropping proof: the caller
/// keeps the exact range for retry.
pub const AckRanges = struct {
    pub const capacity = 64;
    pub const Range = struct { first: u64, last: u64 };

    items: [capacity]Range = undefined,
    len: usize = 0,

    pub fn clear(self: *AckRanges) void {
        self.len = 0;
    }

    pub fn count(self: *const AckRanges) usize {
        return self.len;
    }

    /// `skip` keeps a leading in-flight entry out of merging.
    pub fn insert(self: *AckRanges, first: u64, last: u64, skip: usize) error{QueueFull}!void {
        std.debug.assert(last != 0 and first <= last);
        std.debug.assert(skip <= self.len);
        var merged = Range{ .first = first, .last = last };
        var start = skip;
        while (start < self.len and self.items[start].last +| 1 < merged.first) : (start += 1) {}
        var end = start;
        while (end < self.len and touches(self.items[end], merged)) : (end += 1) {
            merged.first = @min(merged.first, self.items[end].first);
            merged.last = @max(merged.last, self.items[end].last);
        }
        if (start == end) {
            if (self.len == capacity) return error.QueueFull;
            var i = self.len;
            while (i > start) : (i -= 1) self.items[i] = self.items[i - 1];
            self.len += 1;
        } else {
            var src = end;
            var dst = start + 1;
            while (src < self.len) {
                self.items[dst] = self.items[src];
                src += 1;
                dst += 1;
            }
            self.len -= end - start - 1;
        }
        self.items[start] = merged;
    }

    fn removeHead(self: *AckRanges) Range {
        std.debug.assert(self.len != 0);
        const head = self.items[0];
        var i: usize = 1;
        while (i < self.len) : (i += 1) self.items[i - 1] = self.items[i];
        self.len -= 1;
        return head;
    }

    fn touches(left: Range, right: Range) bool {
        return left.first <= right.last +| 1 and right.first <= left.last +| 1;
    }
};

pub const Receiver = struct {
    pub const max_count: usize = 64;
    pub const max_bytes: usize = 2 * unix.max_frame_len;
    const setup_timeout_ms = 5_000;

    a: std.mem.Allocator,
    io: std.Io,
    endpoint: []u8,
    uid: u32,
    epoch: u64,
    /// Bind every subscription, including replacements, to the controller peer.
    expected_pid: ?u32 = null,
    resume_cursor: ?u64 = null,
    stop: Cancellation = .{},

    // -- selective display ACK (admitted by the UI, sent by this task) --
    /// Ranges already displayed and not yet confirmed. Retained across a
    /// socket failure so the exact range is retried, never widened.
    ack_ranges: AckRanges = .{},
    /// Identity/range of the single outstanding frame.
    ack_id: u64 = 0,
    ack_first: u64 = 0,
    ack_last: u64 = 0,
    ack_outstanding: bool = false,
    /// Owner's reported contiguous watermark (informational; not a range).
    ack_confirmed_through: u64 = 0,
    resume_wake: Wakeup,
    ready: Wakeup,
    future: ?std.Io.Future(void) = null,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    frames: [max_count]?[]u8 = @splat(null),
    head: usize = 0,
    count: usize = 0,
    bytes: usize = 0,
    done: bool = false,
    failure: ?anyerror = null,

    pub fn start(a: std.mem.Allocator, io: std.Io, endpoint: []const u8, uid: u32, epoch: u64) !*Receiver {
        return startResumed(a, io, endpoint, uid, epoch, null);
    }

    pub fn startResumed(a: std.mem.Allocator, io: std.Io, endpoint: []const u8, uid: u32, epoch: u64, cursor: ?u64) !*Receiver {
        return startBound(a, io, endpoint, uid, epoch, cursor, null);
    }

    pub fn startBound(a: std.mem.Allocator, io: std.Io, endpoint: []const u8, uid: u32, epoch: u64, cursor: ?u64, expected_pid: ?u32) !*Receiver {
        if (epoch == 0) return error.StaleControl;
        const self = try a.create(Receiver);
        errdefer a.destroy(self);
        const path = try a.dupe(u8, endpoint);
        errdefer a.free(path);
        var resume_wake = try Wakeup.init();
        errdefer resume_wake.deinit();
        var ready = try Wakeup.init();
        errdefer ready.deinit();
        self.* = .{ .a = a, .io = io, .endpoint = path, .uid = uid, .epoch = epoch, .expected_pid = expected_pid, .resume_cursor = cursor, .resume_wake = resume_wake, .ready = ready };
        self.future = try std.Io.concurrent(io, run, .{self});
        return self;
    }

    fn lock(self: *Receiver) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }
    fn unlock(self: *Receiver) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }

    /// Nonblocking admission of one already-displayed range. The UI thread
    /// only merges it into a bounded set; this task performs the wire write.
    /// A full set is a refusal (retryable proof), never a silent drop.
    pub fn acknowledgeRange(self: *Receiver, epoch: u64, first: u64, last: u64) !void {
        if (last == 0) return;
        if (first != 0 and first > last) return error.InvalidInput;
        self.lock();
        if (epoch == 0 or epoch != self.epoch) {
            self.unlock();
            return error.StaleControl;
        }
        self.ack_ranges.insert(first, last, if (self.ack_outstanding) 1 else 0) catch {
            self.unlock();
            return error.QueueFull;
        };
        self.unlock();
        self.resume_wake.notify();
    }

    /// Cumulative prefix proof retained for existing callers.
    pub fn acknowledge(self: *Receiver, epoch: u64, sequence: u64) !void {
        return self.acknowledgeRange(epoch, 0, sequence);
    }

    pub const AckState = struct { confirmed_through: u64, pending: usize, outstanding: bool };

    pub fn ackState(self: *Receiver) AckState {
        self.lock();
        defer self.unlock();
        return .{ .confirmed_through = self.ack_confirmed_through, .pending = self.ack_ranges.len, .outstanding = self.ack_outstanding };
    }

    /// Copy the unconfirmed ranges for a replacement receiver. Callers use
    /// this only after this task has ended, so no producer can mutate them.
    pub fn takeRanges(self: *Receiver) AckRanges {
        self.lock();
        defer self.unlock();
        return self.ack_ranges;
    }

    pub fn adoptRanges(self: *Receiver, carried: AckRanges) error{QueueFull}!void {
        self.lock();
        var admitted = false;
        defer {
            self.unlock();
            if (admitted) self.resume_wake.notify();
        }
        for (carried.items[0..carried.len]) |range| {
            self.ack_ranges.insert(range.first, range.last, if (self.ack_outstanding) 1 else 0) catch return error.QueueFull;
            admitted = true;
        }
    }

    /// Release a failed claim while holding the mutex. The protected head may
    /// precede an earlier tail range, so restore global order before exposing
    /// the set to admission without a protected head.
    fn releaseAckClaimLocked(self: *Receiver) void {
        std.debug.assert(self.ack_outstanding);
        const head = self.ack_ranges.removeHead();
        std.debug.assert(head.first == self.ack_first and head.last == self.ack_last);
        // Removing the head guarantees a free slot even at full capacity.
        self.ack_ranges.insert(head.first, head.last, 0) catch unreachable;
        self.ack_outstanding = false;
    }

    /// One coalesced nonblocking ACK step. Never waits and never queues more
    /// than one frame; the newest ranges keep merging while one is outstanding.
    fn pumpAck(self: *Receiver, conn: *unix.Connection) !void {
        if (conn.writePending()) {
            if (try conn.writeStep()) {
                // The frame is on the wire; the range stays queued until the
                // owner confirms it (or the replacement resends it).
            }
            return;
        }
        self.lock();
        if (self.ack_outstanding or self.ack_ranges.len == 0) {
            self.unlock();
            return;
        }
        const range = self.ack_ranges.items[0];
        self.ack_id +%= 1;
        if (self.ack_id == 0) self.ack_id = 1;
        const id = self.ack_id;
        self.ack_first = range.first;
        self.ack_last = range.last;
        self.ack_outstanding = true;
        self.unlock();
        errdefer {
            self.lock();
            self.releaseAckClaimLocked();
            self.unlock();
        }
        var buffer: [224]u8 = undefined;
        const frame = if (range.first == 0)
            try std.fmt.bufPrint(&buffer, "{{\"v\":{d},\"id\":{d},\"op\":\"ack\",\"epoch\":{d},\"sequence\":{d}}}", .{ protocol.version, id, self.epoch, range.last })
        else
            try std.fmt.bufPrint(&buffer, "{{\"v\":{d},\"id\":{d},\"op\":\"ack\",\"epoch\":{d},\"sequence\":{d},\"first\":{d}}}", .{ protocol.version, id, self.epoch, range.last, range.first });
        try conn.queueFrame(frame);
    }

    /// A watch page always carries `"stream":"..."` at top level, and every
    /// event value is JSON-escaped, so this marker cannot appear inside one.
    fn isStreamPage(frame: []const u8) bool {
        return std.mem.indexOf(u8, frame, "\"stream\":\"") != null;
    }

    /// Consume the owner's ACK confirmation instead of forwarding it as a
    /// display frame. `false` is a protocol failure for this stream.
    fn applyAckReply(self: *Receiver, frame: []const u8) bool {
        // The owner's reply is a fixed handful of fields; refuse to parse an
        // arbitrarily large non-stream frame on this path.
        if (frame.len > 512) return false;
        var document = std.json.parseFromSlice(std.json.Value, self.a, frame, .{}) catch return false;
        defer document.deinit();
        const object = switch (document.value) {
            .object => |value| value,
            else => return false,
        };
        if (object.count() > 16) return false;
        // The confirmation is part of the same exact IPC version. A v1 or
        // foreign control frame can never retire a range.
        const version = integerField(object.get("v") orelse return false) orelse return false;
        if (version != protocol.version) return false;
        const confirmed = switch (object.get("ack") orelse return false) {
            .bool => |value| value,
            else => return false,
        };
        if (!confirmed) return false;
        const ok = switch (object.get("ok") orelse return false) {
            .bool => |value| value,
            else => return false,
        };
        const id = integerField(object.get("id") orelse return false) orelse return false;
        const epoch = integerField(object.get("epoch") orelse return false) orelse return false;
        if (epoch != self.epoch) return false;
        // A refused ACK means this stream can no longer retire anything; fail
        // it and let the view resume from its own cursor instead of silently
        // keeping a range the owner will never accept.
        if (!ok) return false;
        const through = integerField(object.get("through") orelse return false) orelse return false;
        const sequence = integerField(object.get("sequence") orelse return false) orelse return false;
        const first = if (object.get("first")) |value| integerField(value) orelse return false else 0;
        self.lock();
        defer self.unlock();
        if (!self.ack_outstanding or id != self.ack_id) return false;
        if (sequence != self.ack_last or first != self.ack_first) return false;
        // The head is exactly the in-flight range: inserts never mutate it.
        _ = self.ack_ranges.removeHead();
        self.ack_outstanding = false;
        if (through > self.ack_confirmed_through) self.ack_confirmed_through = through;
        return true;
    }

    fn integerField(value: std.json.Value) ?u64 {
        return switch (value) {
            .integer => |number| if (number >= 0) @intCast(number) else null,
            else => null,
        };
    }

    pub fn buffered(self: *Receiver) bool {
        self.lock();
        defer self.unlock();
        return self.count != 0;
    }

    /// Wait for the initial snapshot and baseline without removing either.
    /// The regular consumer must still process the original ordered frames.
    /// This uses one total deadline and the same cancellation/progress contract
    /// as the control socket, even if the peer sends only the first frame.
    pub fn copyInitial(self: *Receiver, wait: unix.Wait) ![2][]u8 {
        const started = std.Io.Clock.awake.now(wait.io);
        while (true) {
            if (wait.progress_fn) |progress| try progress(wait.progress_context);
            if (wait.cancel) |cancel| if (cancel.isRequested()) return error.Canceled;
            self.ready.drain();
            self.lock();
            if (self.done) {
                const failure = self.failure orelse error.ConnectionClosed;
                self.unlock();
                return failure;
            }
            if (self.count >= 2) {
                const first = self.a.dupe(u8, self.frames[self.head].?) catch |err| {
                    self.unlock();
                    return err;
                };
                const second = self.a.dupe(u8, self.frames[(self.head + 1) % max_count].?) catch |err| {
                    self.a.free(first);
                    self.unlock();
                    return err;
                };
                self.unlock();
                // The ordinary consumer still owns both frames and must wake.
                self.ready.notify();
                return .{ first, second };
            }
            self.unlock();
            const elapsed = started.untilNow(wait.io, .awake).toMilliseconds();
            if (elapsed >= wait.timeout_ms) return error.Timeout;
            const remaining: i64 = @as(i64, wait.timeout_ms) - elapsed;
            var descriptors = [_]std.c.pollfd{.{ .fd = self.ready.fd, .events = std.c.POLL.IN, .revents = 0 }};
            const n = std.c.poll(&descriptors, descriptors.len, @intCast(@min(remaining, 50)));
            if (n < 0 and std.c._errno().* != @backingInt(std.c.E.INTR)) return error.Transport;
        }
    }

    pub fn checkRunning(self: *Receiver) !void {
        self.lock();
        defer self.unlock();
        if (self.done) return self.failure orelse error.ConnectionClosed;
    }

    /// All queued frames precede a terminal transport error. The caller owns
    /// the returned bytes; no receiver arena or backend pointer is borrowed.
    pub fn pop(self: *Receiver) !?[]u8 {
        self.ready.drain();
        self.lock();
        if (self.count != 0) {
            const frame = self.frames[self.head].?;
            self.frames[self.head] = null;
            self.head = (self.head + 1) % max_count;
            self.count -= 1;
            self.bytes -= frame.len;
            self.unlock();
            self.resume_wake.notify();
            return frame;
        }
        const failure = self.failure;
        const done = self.done;
        self.unlock();
        if (failure) |err| return err;
        if (done) return error.ConnectionClosed;
        return null;
    }

    /// Reserve room for the largest legal frame BEFORE another read. The
    /// partial frame adds at most max_frame_len beyond the published queue.
    fn room(self: *Receiver) bool {
        self.lock();
        defer self.unlock();
        return self.count < max_count and self.bytes <= max_bytes - unix.max_frame_len;
    }

    fn publish(self: *Receiver, frame: []u8) void {
        self.lock();
        std.debug.assert(self.count < max_count and self.bytes + frame.len <= max_bytes);
        self.frames[(self.head + self.count) % max_count] = frame;
        self.count += 1;
        self.bytes += frame.len;
        self.unlock();
        self.ready.notify();
    }

    fn run(self: *Receiver) void {
        const failure: ?anyerror = if (self.receive()) |_| null else |err| err;
        self.lock();
        self.failure = failure;
        self.done = true;
        self.unlock();
        self.ready.notify();
    }

    fn receive(self: *Receiver) !void {
        var conn = try unix.connect(self.a, self.endpoint, self.uid, .{ .io = self.io, .timeout_ms = setup_timeout_ms, .cancel = &self.stop });
        defer conn.close();
        if (self.expected_pid) |pid| if (conn.peer.pid != pid) return error.PeerPidMismatch;
        var request_buffer: [160]u8 = undefined;
        const request = if (self.resume_cursor) |cursor|
            try std.fmt.bufPrint(&request_buffer, "{{\"v\":{d},\"id\":1,\"op\":\"watch\",\"epoch\":{d},\"since\":{d}}}", .{ protocol.version, self.epoch, cursor })
        else
            try std.fmt.bufPrint(&request_buffer, "{{\"v\":{d},\"id\":1,\"op\":\"watch\",\"epoch\":{d}}}", .{ protocol.version, self.epoch });
        try conn.writeFrame(request, .{ .io = self.io, .timeout_ms = setup_timeout_ms, .cancel = &self.stop });
        try self.receiveFrom(&conn);
    }

    fn receiveFrom(self: *Receiver, conn: *unix.Connection) !void {
        var first_frame = true;
        var started = std.Io.Clock.awake.now(self.io);
        var partial = false;
        while (!self.stop.isRequested()) {
            // Drain before checking queue space: pop racing either step leaves
            // this fd readable, so a full queue cannot lose its resume signal.
            self.resume_wake.drain();
            // A pending ACK is written before the next read wait and never
            // holds an inbound page behind it: both directions are bounded and
            // nonblocking on this one owned socket.
            try self.pumpAck(conn);
            const can_read = self.room();
            const writing = conn.writePending();
            if (can_read) {
                const was_partial = conn.header_read != 0;
                switch (try conn.readStep()) {
                    .eof => return error.ConnectionClosed,
                    .frame => |frame| {
                        if (isStreamPage(frame)) {
                            self.publish(frame);
                        } else {
                            const accepted = self.applyAckReply(frame);
                            self.a.free(frame);
                            if (!accepted) return error.ProtocolError;
                        }
                        first_frame = false;
                        partial = false;
                        continue;
                    },
                    .pending => {
                        partial = conn.header_read != 0;
                        if (partial and !was_partial and !first_frame) started = std.Io.Clock.awake.now(self.io);
                    },
                }
            }
            // Empty live streams may remain idle indefinitely. Only admission
            // or an actual partial frame has a transport deadline.
            if ((first_frame or partial) and started.untilNow(self.io, .awake).toMilliseconds() >= setup_timeout_ms) return error.Timeout;
            var descriptors = [_]std.c.pollfd{
                .{ .fd = self.resume_wake.fd, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = if (can_read or writing) conn.fd else -1, .events = (if (can_read) @as(i16, std.c.POLL.IN) else 0) | (if (writing) @as(i16, std.c.POLL.OUT) else 0), .revents = 0 },
            };
            const n = std.c.poll(&descriptors, descriptors.len, 50);
            if (n < 0 and std.c._errno().* != @backingInt(std.c.E.INTR)) return error.Transport;
        }
        return error.Canceled;
    }

    pub fn deinit(self: *Receiver) void {
        self.stop.cancel();
        self.resume_wake.notify();
        if (self.future) |*future| future.await(self.io);
        // No producer remains: queued frame ownership is now exclusively ours.
        for (&self.frames) |*frame| if (frame.*) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.a.free(bytes);
            frame.* = null;
        };
        self.resume_wake.deinit();
        self.ready.deinit();
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
        const a = self.a;
        a.free(self.endpoint);
        a.destroy(self);
    }
};
