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

test "ack ranges coalesce adjacency and never bridge a hole" {
    var ranges: AckRanges = .{};
    try ranges.insert(0, 5, 0);
    try ranges.insert(6, 9, 0);
    try std.testing.expectEqual(@as(usize, 1), ranges.len);
    try std.testing.expectEqual(AckRanges.Range{ .first = 0, .last = 9 }, ranges.items[0]);
    try ranges.insert(20, 30, 0);
    try ranges.insert(31, 40, 0);
    try ranges.insert(50, 60, 0);
    try std.testing.expectEqual(@as(usize, 3), ranges.len);
    try std.testing.expectEqual(AckRanges.Range{ .first = 20, .last = 40 }, ranges.items[1]);
    try std.testing.expectEqual(AckRanges.Range{ .first = 50, .last = 60 }, ranges.items[2]);
    // A prefix that reaches the next range merges through it; a hole survives.
    try ranges.insert(0, 10, 0);
    try std.testing.expectEqual(AckRanges.Range{ .first = 0, .last = 10 }, ranges.items[0]);
    try std.testing.expectEqual(@as(usize, 3), ranges.len);
    var full: AckRanges = .{};
    for (0..AckRanges.capacity) |index| try full.insert(index * 2 + 1, index * 2 + 1, 0);
    const before = full;
    try std.testing.expectError(error.QueueFull, full.insert(10_000, 10_000, 0));
    try std.testing.expectEqual(AckRanges.capacity, full.len);
    try std.testing.expectEqualSlices(AckRanges.Range, before.items[0..before.len], full.items[0..full.len]);
    // In-flight head is immutable even when the new proof touches it; the
    // remaining ranges are independently sorted and coalesced.
    var inflight: AckRanges = .{};
    try inflight.insert(50, 60, 0);
    try inflight.insert(80, 90, 1);
    try inflight.insert(10, 49, 1);
    try inflight.insert(70, 79, 1);
    try std.testing.expectEqualSlices(AckRanges.Range, &.{ .{ .first = 50, .last = 60 }, .{ .first = 10, .last = 49 }, .{ .first = 70, .last = 90 } }, inflight.items[0..inflight.len]);
}

pub const Receiver = struct {
    pub const max_count: usize = 64;
    pub const max_bytes: usize = 2 * unix.max_frame_len;
    const setup_timeout_ms = 5_000;

    a: std.mem.Allocator,
    io: std.Io,
    endpoint: []u8,
    uid: u32,
    epoch: u64,
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
        if (epoch == 0) return error.StaleControl;
        const self = try a.create(Receiver);
        errdefer a.destroy(self);
        const path = try a.dupe(u8, endpoint);
        errdefer a.free(path);
        var resume_wake = try Wakeup.init();
        errdefer resume_wake.deinit();
        var ready = try Wakeup.init();
        errdefer ready.deinit();
        self.* = .{ .a = a, .io = io, .endpoint = path, .uid = uid, .epoch = epoch, .resume_cursor = cursor, .resume_wake = resume_wake, .ready = ready };
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
                .{ .fd = self.resume_wake.fd, .events = std.os.linux.POLL.IN, .revents = 0 },
                .{ .fd = if (can_read or writing) conn.fd else -1, .events = (if (can_read) @as(i16, std.os.linux.POLL.IN) else 0) | (if (writing) @as(i16, std.os.linux.POLL.OUT) else 0), .revents = 0 },
            };
            const n = std.c.poll(&descriptors, descriptors.len, 50);
            if (n < 0 and std.c._errno().* != @backingInt(std.os.linux.E.INTR)) return error.Transport;
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

test "receiver task keeps reading without a consumer and stops while its queue is full" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var dir = try unix.Directory.resolveUnder(a, path[0..n], "rt", @intCast(std.c.getuid()));
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "stream.sock", .{});
    defer listener.deinit();
    const receiver = try Receiver.start(a, io, listener.path, @intCast(std.c.getuid()), 7);
    defer receiver.deinit();
    var connection = try listener.accept(.{ .io = io, .timeout_ms = 2000 });
    defer connection.close();
    const raw = (try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })).?;
    defer a.free(raw);
    var request = try protocol.parseRequest(a, raw);
    defer request.deinit();
    try std.testing.expectEqual(protocol.Op.watch, request.op);
    try std.testing.expectEqual(@as(u64, 7), try request.u64Field("epoch"));
    for (0..Receiver.max_count + 4) |index| {
        var page_buffer: [256]u8 = undefined;
        const page = try std.fmt.bufPrint(&page_buffer, "{{\"v\":{d},\"id\":1,\"ok\":true,\"epoch\":7,\"stream\":\"events\",\"from\":{d},\"through\":{d},\"events\":[{{\"t\":\"text\",\"v\":\"x\",\"seq\":{d}}}]}}", .{ protocol.version, index, index + 1, index + 1 });
        try connection.writeFrame(page, .{ .io = io, .timeout_ms = 1000 });
    }
    const deadline = std.Io.Clock.awake.now(io);
    var count: usize = 0;
    while (deadline.untilNow(io, .awake).toMilliseconds() < 2000) {
        receiver.lock();
        count = receiver.count;
        receiver.unlock();
        if (count == Receiver.max_count) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(Receiver.max_count, count);
    receiver.lock();
    const queued_bytes = receiver.bytes;
    receiver.unlock();
    try std.testing.expect(queued_bytes > 0 and queued_bytes <= Receiver.max_bytes);
    // Never pop, never close the peer: only the independent stop wake can let
    // this task leave its backpressure wait.
    const start = std.Io.Clock.awake.now(io);
    receiver.stop.cancel();
    receiver.resume_wake.notify();
    receiver.future.?.await(io);
    receiver.future = null;
    try std.testing.expect(start.untilNow(io, .awake).toMilliseconds() < 1000);
    try std.testing.expect(receiver.done);
    try std.testing.expectEqual(error.Canceled, receiver.failure.?);
    var drained_bytes: usize = 0;
    for (0..Receiver.max_count) |index| {
        const frame = (try receiver.pop()) orelse return error.TestExpectedFrame;
        defer a.free(frame);
        var expected_buffer: [256]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"v\":{d},\"id\":1,\"ok\":true,\"epoch\":7,\"stream\":\"events\",\"from\":{d},\"through\":{d},\"events\":[{{\"t\":\"text\",\"v\":\"x\",\"seq\":{d}}}]}}", .{ protocol.version, index, index + 1, index + 1 });
        try std.testing.expectEqualStrings(expected, frame);
        drained_bytes += frame.len;
    }
    try std.testing.expectEqual(queued_bytes, drained_bytes);
    try std.testing.expectError(error.Canceled, receiver.pop());
}

test "adopting carried ACK ranges wakes receiver without bridging holes" {
    var resume_wake = try Wakeup.init();
    defer resume_wake.deinit();
    var ready = try Wakeup.init();
    defer ready.deinit();
    var receiver: Receiver = .{ .a = std.testing.allocator, .io = std.testing.io, .endpoint = &.{}, .uid = 0, .epoch = 7, .resume_wake = resume_wake, .ready = ready };
    defer std.debug.assert(std.c.pthread_mutex_destroy(&receiver.mutex) == .SUCCESS);

    var carried: AckRanges = .{};
    try carried.insert(2, 3, 0);
    try carried.insert(5, 7, 0);
    var descriptors = [_]std.c.pollfd{.{ .fd = receiver.resume_wake.fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&descriptors, 1, 0));
    try receiver.adoptRanges(carried);
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&descriptors, 1, 0));
    try std.testing.expectEqual(@as(usize, 2), receiver.ack_ranges.len);
    try std.testing.expectEqualSlices(AckRanges.Range, &.{ .{ .first = 2, .last = 3 }, .{ .first = 5, .last = 7 } }, receiver.ack_ranges.items[0..receiver.ack_ranges.len]);
    receiver.resume_wake.drain();
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&descriptors, 1, 0));

    // An already claimed head must remain immutable, even if carried proof touches it.
    receiver.ack_outstanding = true;
    carried.clear();
    try carried.insert(1, 2, 0);
    try receiver.adoptRanges(carried);
    try std.testing.expectEqualSlices(AckRanges.Range, &.{ .{ .first = 2, .last = 3 }, .{ .first = 1, .last = 2 }, .{ .first = 5, .last = 7 } }, receiver.ack_ranges.items[0..receiver.ack_ranges.len]);
}

test "failed ACK claim restores sorted unprotected ranges" {
    const a = std.testing.allocator;
    var receiver: Receiver = .{ .a = a, .io = std.testing.io, .endpoint = &.{}, .uid = 0, .epoch = 7, .resume_wake = try Wakeup.init(), .ready = try Wakeup.init() };
    defer receiver.resume_wake.deinit();
    defer receiver.ready.deinit();
    try receiver.ack_ranges.insert(50, 60, 0);
    receiver.ack_first = 50;
    receiver.ack_last = 60;
    receiver.ack_outstanding = true;
    try receiver.ack_ranges.insert(10, 49, 1);
    try receiver.ack_ranges.insert(70, 90, 1);
    receiver.lock();
    receiver.releaseAckClaimLocked();
    receiver.unlock();
    try std.testing.expect(!receiver.ackState().outstanding);
    try std.testing.expectEqual(@as(usize, 2), receiver.ackState().pending);
    try std.testing.expectEqualSlices(AckRanges.Range, &.{ .{ .first = 10, .last = 60 }, .{ .first = 70, .last = 90 } }, receiver.ack_ranges.items[0..receiver.ack_ranges.len]);
}

test "receiver queue is bounded and publishes owned frames before its failure" {
    const a = std.testing.allocator;
    var receiver: Receiver = .{ .a = a, .io = std.testing.io, .endpoint = &.{}, .uid = 0, .epoch = 1, .resume_wake = try Wakeup.init(), .ready = try Wakeup.init() };
    defer receiver.resume_wake.deinit();
    defer receiver.ready.deinit();
    defer for (receiver.frames) |frame| if (frame) |bytes| a.free(bytes);
    const first = try a.dupe(u8, "first");
    receiver.publish(first);
    receiver.failure = error.StreamGap;
    receiver.done = true;
    const got = (try receiver.pop()).?;
    defer a.free(got);
    try std.testing.expectEqual(first.ptr, got.ptr);
    try std.testing.expectError(error.StreamGap, receiver.pop());
    for (0..Receiver.max_count) |_| receiver.publish(try a.dupe(u8, "x"));
    try std.testing.expect(!receiver.room());
    const one = (try receiver.pop()).?;
    a.free(one);
    try std.testing.expect(receiver.room());
}

test "watch socket carries selective ACK ranges and consumes their confirmations" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var dir = try unix.Directory.resolveUnder(a, path[0..n], "ack", @intCast(std.c.getuid()));
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "stream.sock", .{});
    defer listener.deinit();
    const receiver = try Receiver.start(a, io, listener.path, @intCast(std.c.getuid()), 7);
    defer receiver.deinit();
    var connection = try listener.accept(.{ .io = io, .timeout_ms = 2000 });
    defer connection.close();
    const raw = (try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })).?;
    defer a.free(raw);
    var watch = try protocol.parseRequest(a, raw);
    defer watch.deinit();
    try std.testing.expectEqual(protocol.Op.watch, watch.op);

    // Sequence zero is the documented non-live no-op; a foreign epoch and a
    // reversed range are refused instead of being acknowledged.
    try receiver.acknowledge(7, 0);
    try std.testing.expectError(error.StaleControl, receiver.acknowledge(8, 4));
    try std.testing.expectError(error.InvalidInput, receiver.acknowledgeRange(7, 9, 4));

    // Prefix proof is one frame without a `first` field.
    try receiver.acknowledge(7, 9);
    const first = (try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })).?;
    defer a.free(first);
    var prefix = try protocol.parseRequest(a, first);
    defer prefix.deinit();
    try std.testing.expectEqual(protocol.Op.ack, prefix.op);
    try std.testing.expectEqual(@as(u64, 7), try prefix.u64Field("epoch"));
    try std.testing.expectEqual(@as(u64, 9), try prefix.u64Field("sequence"));
    try std.testing.expect((try prefix.optionalU64("first")) == null);
    const prefix_id = prefix.id;

    // While that frame is unconfirmed, later independent ranges merge with each
    // other only: adjacency coalesces, the hole at 41..49 survives.
    try receiver.acknowledgeRange(7, 20, 30);
    try receiver.acknowledgeRange(7, 31, 40);
    try receiver.acknowledgeRange(7, 50, 60);
    const pending = receiver.ackState();
    try std.testing.expectEqual(@as(usize, 3), pending.pending);
    try std.testing.expect(pending.outstanding);
    try std.Io.sleep(io, .fromMilliseconds(40), .awake);
    var quiet = [_]std.c.pollfd{.{ .fd = connection.fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 0), std.c.poll(&quiet, 1, 20));

    const confirm_prefix = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"ack\":true,\"epoch\":7,\"through\":9,\"sequence\":9}}", .{ protocol.version, prefix_id });
    defer a.free(confirm_prefix);
    try connection.writeFrame(confirm_prefix, .{ .io = io, .timeout_ms = 2000 });
    const deadline = std.Io.Clock.awake.now(io);
    while (deadline.untilNow(io, .awake).toMilliseconds() < 2000) {
        if (receiver.ackState().confirmed_through == 9) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(u64, 9), receiver.ackState().confirmed_through);
    try std.testing.expectEqual(@as(usize, 2), receiver.ackState().pending);

    const second = (try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })).?;
    defer a.free(second);
    var range = try protocol.parseRequest(a, second);
    defer range.deinit();
    try std.testing.expectEqual(@as(u64, 20), try range.u64Field("first"));
    try std.testing.expectEqual(@as(u64, 40), try range.u64Field("sequence"));
    // A hole before it keeps the contiguous watermark where it was.
    const confirm_range = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"ack\":true,\"epoch\":7,\"through\":9,\"sequence\":40,\"first\":20}}", .{ protocol.version, range.id });
    defer a.free(confirm_range);
    try connection.writeFrame(confirm_range, .{ .io = io, .timeout_ms = 2000 });
    const third = (try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })).?;
    defer a.free(third);
    var last = try protocol.parseRequest(a, third);
    defer last.deinit();
    try std.testing.expectEqual(@as(u64, 50), try last.u64Field("first"));
    try std.testing.expectEqual(@as(u64, 60), try last.u64Field("sequence"));
    const confirm_last = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"ack\":true,\"epoch\":7,\"through\":9,\"sequence\":60,\"first\":50}}", .{ protocol.version, last.id });
    defer a.free(confirm_last);
    try connection.writeFrame(confirm_last, .{ .io = io, .timeout_ms = 2000 });
    const settled = std.Io.Clock.awake.now(io);
    while (settled.untilNow(io, .awake).toMilliseconds() < 2000) {
        if (receiver.ackState().pending == 0) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), receiver.ackState().pending);

    // A stream page keeps flowing regardless of the ACK state.
    const page = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":1,\"ok\":true,\"epoch\":7,\"stream\":\"events\",\"from\":0,\"through\":1,\"events\":[]}}", .{protocol.version});
    defer a.free(page);
    try connection.writeFrame(page, .{ .io = io, .timeout_ms = 2000 });
    const page_deadline = std.Io.Clock.awake.now(io);
    var received: ?[]u8 = null;
    while (page_deadline.untilNow(io, .awake).toMilliseconds() < 2000) {
        if (try receiver.pop()) |frame| {
            received = frame;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    const owned = received orelse return error.TestExpectedFrame;
    defer a.free(owned);
    try std.testing.expect(std.mem.indexOf(u8, owned, "\"stream\":\"events\"") != null);

    // Unconfirmed ranges survive a replacement receiver instead of being
    // silently dropped or widened.
    try receiver.acknowledgeRange(7, 70, 80);
    const carried = receiver.takeRanges();
    var replacement: Receiver = .{ .a = a, .io = io, .endpoint = &.{}, .uid = 0, .epoch = 7, .resume_wake = try Wakeup.init(), .ready = try Wakeup.init() };
    defer replacement.resume_wake.deinit();
    defer replacement.ready.deinit();
    defer for (replacement.frames) |frame| if (frame) |bytes| a.free(bytes);
    try replacement.adoptRanges(carried);
    try std.testing.expectEqual(carried.len, replacement.ackState().pending);
}

test "ACK range admission is bounded and refuses without dropping proof" {
    const a = std.testing.allocator;
    var receiver: Receiver = .{ .a = a, .io = std.testing.io, .endpoint = &.{}, .uid = 0, .epoch = 7, .resume_wake = try Wakeup.init(), .ready = try Wakeup.init() };
    defer receiver.resume_wake.deinit();
    defer receiver.ready.deinit();
    defer for (receiver.frames) |frame| if (frame) |bytes| a.free(bytes);
    for (0..AckRanges.capacity) |index| {
        try receiver.acknowledgeRange(7, index * 2 + 1, index * 2 + 1);
    }
    try std.testing.expectEqual(AckRanges.capacity, receiver.ackState().pending);
    // A new hole cannot be admitted while the set is full; the existing proof
    // is untouched so the caller can retry it later.
    try std.testing.expectError(error.QueueFull, receiver.acknowledgeRange(7, 10_001, 10_001));
    try std.testing.expectEqual(AckRanges.capacity, receiver.ackState().pending);
    // An adjacent range still merges, so ordinary progress needs no new slot.
    try receiver.acknowledgeRange(7, 2, 2);
    try std.testing.expectEqual(AckRanges.capacity - 1, receiver.ackState().pending);
    try std.testing.expectError(error.StaleControl, receiver.acknowledgeRange(8, 1, 2));
}

test "an unconfirmed ACK range survives a lost reply for the replacement" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var dir = try unix.Directory.resolveUnder(a, path[0..n], "lostack", @intCast(std.c.getuid()));
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "stream.sock", .{});
    defer listener.deinit();
    const receiver = try Receiver.start(a, io, listener.path, @intCast(std.c.getuid()), 7);
    defer receiver.deinit();
    var connection = try listener.accept(.{ .io = io, .timeout_ms = 2000 });
    const raw = (try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })).?;
    defer a.free(raw);
    try receiver.acknowledgeRange(7, 20, 30);
    const frame = (try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })).?;
    defer a.free(frame);
    var request = try protocol.parseRequest(a, frame);
    defer request.deinit();
    try std.testing.expectEqual(@as(u64, 20), try request.u64Field("first"));
    try std.testing.expectEqual(@as(u64, 30), try request.u64Field("sequence"));
    // The peer dies before confirming. The range must stay owned, exact.
    connection.close();
    const deadline = std.Io.Clock.awake.now(io);
    while (deadline.untilNow(io, .awake).toMilliseconds() < 2000) {
        if (receiver.done) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(receiver.done);
    try std.testing.expectEqual(@as(u64, 0), receiver.ackState().confirmed_through);
    const carried = receiver.takeRanges();
    try std.testing.expectEqual(@as(usize, 1), carried.len);
    try std.testing.expectEqual(AckRanges.Range{ .first = 20, .last = 30 }, carried.items[0]);
    var replacement: Receiver = .{ .a = a, .io = io, .endpoint = &.{}, .uid = 0, .epoch = 7, .resume_wake = try Wakeup.init(), .ready = try Wakeup.init() };
    defer replacement.resume_wake.deinit();
    defer replacement.ready.deinit();
    defer for (replacement.frames) |item| if (item) |bytes| a.free(bytes);
    try replacement.adoptRanges(carried);
    try std.testing.expectEqual(@as(usize, 1), replacement.ackState().pending);
    try std.testing.expectEqual(AckRanges.Range{ .first = 20, .last = 30 }, replacement.ack_ranges.items[0]);
}
