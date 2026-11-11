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
test "bound watch rejects a different kernel peer before sending watch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var dir = try unix.Directory.resolveUnder(a, path[0..n], "bound", @intCast(std.c.getuid()));
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "stream.sock", .{});
    defer listener.deinit();
    const actual_pid: u32 = @intCast(std.c.getpid());
    const receiver = try Receiver.startBound(a, io, listener.path, @intCast(std.c.getuid()), 7, null, actual_pid + 1);
    defer receiver.deinit();
    var connection = try listener.accept(.{ .io = io, .timeout_ms = 2000 });
    defer connection.close();
    try std.testing.expect((try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })) == null);
    try std.testing.expectError(error.PeerPidMismatch, receiver.copyInitial(.{ .io = io, .timeout_ms = 2000 }));
}
test "initial watch wait observes progress and cancellation on a real peer" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var dir = try unix.Directory.resolveUnder(a, path[0..n], "cancel", @intCast(std.c.getuid()));
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "stream.sock", .{});
    defer listener.deinit();
    const receiver = try Receiver.start(a, io, listener.path, @intCast(std.c.getuid()), 7);
    var receiver_live = true;
    defer if (receiver_live) receiver.deinit();
    var connection = try listener.accept(.{ .io = io, .timeout_ms = 2000 });
    defer connection.close();
    const watch = (try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })) orelse return error.TestExpectedFrame;
    defer a.free(watch);
    const Progress = struct {
        fn tick(raw: ?*anyopaque) !void {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
        }
    };
    var ticks: usize = 0;
    var cancel: Cancellation = .{};
    cancel.cancel();
    try std.testing.expectError(error.Canceled, receiver.copyInitial(.{ .io = io, .timeout_ms = 2000, .cancel = &cancel, .progress_context = &ticks, .progress_fn = Progress.tick }));
    try std.testing.expectEqual(@as(usize, 1), ticks);
    receiver.deinit();
    receiver_live = false;
    try std.testing.expect((try connection.readFrame(.{ .io = io, .timeout_ms = 2000 })) == null);
}
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
    var descriptors = [_]std.c.pollfd{.{ .fd = receiver.resume_wake.fd, .events = std.c.POLL.IN, .revents = 0 }};
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
    var quiet = [_]std.c.pollfd{.{ .fd = connection.fd, .events = std.c.POLL.IN, .revents = 0 }};
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
