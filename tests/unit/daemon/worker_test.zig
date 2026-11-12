test "watch binds kernel peer and epoch and pushes without events RPC" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // Linux socketpair flags
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    var slots: [max_connections]?Active = @splat(null);
    defer closeSlots(host, &slots);
    var peers: [2]?unix.Connection = @splat(null);
    defer for (&peers) |*peer| if (peer.*) |*conn| conn.close();
    for (0..2) |i| {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const credentials: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        slots[i] = .{ .id = i + 1, .conn = unix.Connection.init(a, fds[0], credentials) };
        peers[i] = unix.Connection.init(a, fds[1], credentials);
    }
    var attach = try protocol.parseRequest(a, "{\"v\":5,\"id\":1,\"op\":\"attach\"}");
    defer attach.deinit();
    const attached = try host.dispatch(a, &attach, 1, false);
    defer a.free(attached);
    var request = try protocol.parseRequest(a, "{\"v\":5,\"id\":2,\"op\":\"watch\",\"epoch\":1}");
    defer request.deinit();
    // A stream on the control socket itself must not erase its identity.
    try std.testing.expectError(error.StaleControl, startWatch(host, a, io, &slots[0].?, &request, &slots));
    try std.testing.expect(slots[0].?.watch == null);
    slots[1].?.conn.peer.pid +%= 1;
    try std.testing.expectError(error.StaleControl, startWatch(host, a, io, &slots[1].?, &request, &slots));
    slots[1].?.conn.peer.pid -%= 1;
    try startWatch(host, a, io, &slots[1].?, &request, &slots);
    try std.testing.expect(watchValid(host, &slots, &slots[1].?));
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const first = (try peers[1].?.readStep()).frame;
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"stream\":\"snapshot\"") != null);
    // A real Bridge event arrives AFTER baseline freeze but before delivery.
    const bridge_host = host.bridge.host();
    try bridge_host.emit_fn(bridge_host.context, .{ .text = "live after freeze" }, &host.cancel);
    host.pump(nowMs(io));
    try advanceWatch(host, a, io, &slots[1].?);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const baseline = (try peers[1].?.readStep()).frame;
    defer a.free(baseline);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "\"stream\":\"baseline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "live after freeze") == null);
    // No inbound RPC at all: advancing the owner publishes the event.
    try advanceWatch(host, a, io, &slots[1].?);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const event = (try peers[1].?.readStep()).frame;
    defer a.free(event);
    try std.testing.expect(std.mem.indexOf(u8, event, "live after freeze") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"from\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"through\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"seq\":1") != null);
    var invalid = try protocol.parseRequest(a, "{\"v\":5,\"id\":3,\"op\":\"watch\",\"epoch\":1,\"since\":2}");
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidSequence, host.watchResume(1, try invalid.u64Field("since")));
    var resumed = try protocol.parseRequest(a, "{\"v\":5,\"id\":4,\"op\":\"watch\",\"epoch\":1,\"since\":1}");
    defer resumed.deinit();
    try startWatch(host, a, io, &slots[1].?, &resumed, &slots);
    try std.testing.expect(slots[1].?.watch.?.baseline == null);
    try std.testing.expectEqual(@as(u64, 1), slots[1].?.watch.?.cursor);
    // The resumed subscription first sends its snapshot, without a history baseline.
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const resume_snapshot = (try peers[1].?.readStep()).frame;
    defer a.free(resume_snapshot);
    var resume_doc = try std.json.parseFromSlice(std.json.Value, a, resume_snapshot, .{});
    defer resume_doc.deinit();
    try std.testing.expectEqualStrings("snapshot", resume_doc.value.object.get("stream").?.string);
    try std.testing.expectEqual(@as(i64, 4), resume_doc.value.object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 1), resume_doc.value.object.get("epoch").?.integer);
    try std.testing.expectEqual(@as(i64, 1), resume_doc.value.object.get("through").?.integer);
    try std.testing.expect(resume_doc.value.object.get("history") == null);
    try std.testing.expect(!slots[1].?.conn.writePending());
    // The bound watch socket is the only stream-side mutation: a display ACK.
    // A future watermark is refused without retiring anything.
    try peers[1].?.writeFrame("{\"v\":5,\"id\":5,\"op\":\"ack\",\"epoch\":1,\"sequence\":9}", .{ .io = io, .timeout_ms = 2_000 });
    serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const refused = (try peers[1].?.readStep()).frame;
    defer a.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "invalid_input") != null);
    try std.testing.expectEqual(@as(u64, 0), host.events.reclaimed_through);
    // The displayed watermark retires exactly through the offered page and the
    // reply is a control frame, not a display page.
    try peers[1].?.writeFrame("{\"v\":5,\"id\":6,\"op\":\"ack\",\"epoch\":1,\"sequence\":1}", .{ .io = io, .timeout_ms = 2_000 });
    serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const confirmed = (try peers[1].?.readStep()).frame;
    defer a.free(confirmed);
    try std.testing.expect(std.mem.indexOf(u8, confirmed, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, confirmed, "\"ack\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, confirmed, "\"stream\"") == null);
    try std.testing.expectEqual(@as(u64, 1), host.events.reclaimed_through);

    // A connected socket without a subscription cannot ACK: the watch path is
    // not a general RPC surface for any peer of this worker.
    {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const credentials: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        var impostor = unix.Connection.init(a, fds[1], credentials);
        defer impostor.close();
        slots[2] = .{ .id = 3, .conn = unix.Connection.init(a, fds[0], credentials) };
        try impostor.writeFrame("{\"v\":5,\"id\":7,\"op\":\"ack\",\"epoch\":1,\"sequence\":2}", .{ .io = io, .timeout_ms = 2_000 });
        serveWatchInput(host, a, io, &slots[2].?, &slots[2], &slots);
        try std.testing.expect(slots[2] == null);
        try std.testing.expectEqual(@as(u64, 1), host.events.reclaimed_through);
        try std.testing.expect(!host.cancel.isRequested());
    }
    // A different kernel peer cannot borrow the controller's binding even with
    // a plausible epoch and a byte-identical ACK.
    {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const peer: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        const other: unix.Credentials = .{ .pid = peer.pid +% 1, .uid = peer.uid, .gid = peer.gid };
        var impostor = unix.Connection.init(a, fds[1], other);
        defer impostor.close();
        slots[2] = .{ .id = 4, .conn = unix.Connection.init(a, fds[0], other) };
        slots[2].?.watch = .{ .request_id = 9, .epoch = 1, .control_id = 1, .cursor = 1, .stamp = host.watchStamp(), .baseline = null };
        try impostor.writeFrame("{\"v\":5,\"id\":8,\"op\":\"ack\",\"epoch\":1,\"sequence\":2}", .{ .io = io, .timeout_ms = 2_000 });
        serveWatchInput(host, a, io, &slots[2].?, &slots[2], &slots);
        try std.testing.expect(slots[2] == null);
        try std.testing.expectEqual(@as(u64, 1), host.events.reclaimed_through);
        try std.testing.expect(!host.cancel.isRequested());
    }
    // Revoking the control view invalidates only the subscription; nothing in
    // this path owns task cancellation or grants the stream mutation rights.
    host.disconnected(1);
    try std.testing.expect(!watchValid(host, &slots, &slots[1].?));
    // After revocation an ACK-shaped frame with a stale epoch is dropped: no
    // position is retired and the session task is untouched.
    try peers[1].?.writeFrame("{\"v\":5,\"id\":9,\"op\":\"ack\",\"epoch\":1,\"sequence\":2}", .{ .io = io, .timeout_ms = 2_000 });
    serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    try std.testing.expect(slots[1] == null);
    try std.testing.expectEqual(@as(u64, 1), host.events.reclaimed_through);
    try std.testing.expect(!host.cancel.isRequested());
}
test "owner pid rejects values outside target signed pid range without trapping" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    for ([_][]const u8{ "2147483648", "4294967295", "4294967296", "00000000000" }) |raw| {
        try env.put("THIN_WORKER_OWNER_PID", raw);
        try std.testing.expectError(error.InvalidOwnerPid, expectedOwnerPid(&env));
    }
    try env.put("THIN_WORKER_OWNER_PID", "1");
    try std.testing.expectEqual(@as(c.pid_t, 1), try expectedOwnerPid(&env));
    try env.put("THIN_WORKER_OWNER_PID", "2147483647");
    try std.testing.expectEqual(std.math.maxInt(c.pid_t), try expectedOwnerPid(&env));
}
test "owner fd rejects stdio signed nonnumeric and overflowing values" {
    for ([_][]const u8{ "", "0", "1", "2", "-7", "+3", "3x", "2147483648", "4294967296", "00000000003" }) |raw| {
        try std.testing.expectError(error.InvalidOwnerFd, parseOwnerFd(raw));
    }
    try std.testing.expectEqual(@as(c.fd_t, 3), try parseOwnerFd("3"));
    try std.testing.expectEqual(std.math.maxInt(c.fd_t), try parseOwnerFd("2147483647"));
}
test "Darwin worker rejects daemon owner before activating a session" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.UnsupportedPlatform, runInner(std.testing.allocator, std.testing.io, &env, .{
        .mode = .worker,
        .worker_owner = .daemon,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
}
test "Darwin owner pipe restores CLOEXEC and EOF ignores retained readers" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // Wakeup supplies a NONBLOCK/CLOEXEC Darwin pipe for this unit fixture;
    // production lifetime pipes remain separate from all notification pipes.
    var pipe = try Wakeup.init();
    defer pipe.deinit();
    const reader = pipe.fd;
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(reader, c.F.SETFD, @as(c_int, 0)));
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var buf: [16]u8 = undefined;
    try env.put("THIN_WORKER_OWNER_FD", try std.fmt.bufPrint(&buf, "{d}", .{reader}));
    pipe.fd = -1; // transfer into takeOwnerPipe, including its failure paths
    const owned = try takeOwnerPipe(&env);
    defer fs.closeFd(owned);
    try std.testing.expect(c.fcntl(owned, c.F.GETFD) & c.FD_CLOEXEC != 0);
    try std.testing.expect(try lifetimeAlive(owned));
    const retained = c.fcntl(owned, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    try std.testing.expect(retained >= 0);
    defer fs.closeFd(retained);
    pipe.deinit(); // close only writer, not either independently owned reader
    try std.testing.expect(!try lifetimeAlive(owned));
    try std.testing.expect(!try lifetimeAlive(retained));
}
test "endpoint validation rejects paths outside the private workers directory" {
    try std.testing.expectEqualStrings("ok.sock", std.fs.path.basename("/run/thin/workers/ok.sock"));
    try std.testing.expectEqualStrings("escape.sock", std.fs.path.basename("../escape.sock"));
}
test "worker entry rejects non-worker mode before creating any session state" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expectError(error.InvalidArguments, runInner(a, std.testing.io, &env, .{ .mode = .foreground }));
    try std.testing.expectError(error.InvalidArguments, runInner(a, std.testing.io, &env, .{ .mode = .worker }));
    try std.testing.expectError(error.InvalidArguments, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_endpoint = "relative.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
    // A missing or malformed owner pid is refused before any session state.
    try std.testing.expectError(error.MissingOwnerPid, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_owner = .foreground,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
    try env.put("THIN_WORKER_OWNER_PID", "0");
    try std.testing.expectError(error.InvalidOwnerPid, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_owner = .foreground,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
    try env.put("THIN_WORKER_OWNER_PID", "-7");
    try std.testing.expectError(error.InvalidOwnerPid, runInner(a, std.testing.io, &env, .{
        .mode = .worker,
        .worker_owner = .foreground,
        .worker_endpoint = "/tmp/placeholder.sock",
        .worker_session = std.mem.zeroes([32]u8),
    }));
}
test "watch ACK retires thousands of retained events while the control channel stays live" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // Linux socketpair flags
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    var slots: [max_connections]?Active = @splat(null);
    defer closeSlots(host, &slots);
    var peers: [2]?unix.Connection = @splat(null);
    defer for (&peers) |*peer| if (peer.*) |*conn| conn.close();
    for (0..2) |i| {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const credentials: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        slots[i] = .{ .id = i + 1, .conn = unix.Connection.init(a, fds[0], credentials) };
        peers[i] = unix.Connection.init(a, fds[1], credentials);
    }
    const parent_pid: std.os.linux.pid_t = @intCast(std.os.linux.getpid());
    var attach = try protocol.parseRequest(a, "{\"v\":5,\"id\":1,\"op\":\"attach\"}");
    defer attach.deinit();
    const attached = try host.dispatch(a, &attach, 1, false);
    defer a.free(attached);
    var watch = try protocol.parseRequest(a, "{\"v\":5,\"id\":2,\"op\":\"watch\",\"epoch\":1}");
    defer watch.deinit();
    try startWatch(host, a, io, &slots[1].?, &watch, &slots);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const snapshot = (try peers[1].?.readStep()).frame;
    defer a.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"stream\":\"snapshot\"") != null);
    try advanceWatch(host, a, io, &slots[1].?);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const baseline = (try peers[1].?.readStep()).frame;
    defer a.free(baseline);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "\"stream\":\"baseline\"") != null);

    // No ACK at all: every produced event remains available beyond the old
    // 1024-entry bound. The control socket still has independent progress.
    const bridge_host = host.bridge.host();
    const produced: usize = 4096;
    for (0..produced) |_| {
        host.pump(0);
        try bridge_host.emit_fn(bridge_host.context, .{ .text = "s" }, &host.cancel);
    }
    host.pump(0);
    try std.testing.expectEqual(produced, host.events.items.items.len);
    try std.testing.expect(host.pending_event == null);
    try std.testing.expectEqual(@as(u64, 0), host.events.reclaimed_through);
    // Saturation of the display path does not gate this control connection.
    try peers[0].?.writeFrame("{\"v\":5,\"id\":9,\"op\":\"ping\"}", .{ .io = io, .timeout_ms = 2_000 });
    serveOne(host, a, io, &slots[0].?, parent_pid, &slots[0], &slots);
    try std.testing.expect(try slots[0].?.conn.writeStep());
    const pong = (try peers[0].?.readStep()).frame;
    defer a.free(pong);
    try std.testing.expect(std.mem.indexOf(u8, pong, "\"ok\":true") != null);

    // Phase 2: every page is acknowledged on the bound watch socket; the ring
    // is reclaimed and production completes with no missing position.
    var delivered: usize = 0;
    var acked: u64 = 0;
    var rounds: usize = 0;
    while (delivered < produced and rounds < 400_000) : (rounds += 1) {
        host.pump(0);
        if (!slots[1].?.conn.writePending()) try advanceWatch(host, a, io, &slots[1].?);
        _ = try slots[1].?.conn.writeStep();
        while (true) {
            const step = try peers[1].?.readStep();
            const frame = switch (step) {
                .pending => break,
                .eof => return error.TestUnexpectedResult,
                .frame => |bytes| bytes,
            };
            defer a.free(frame);
            var document = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
            defer document.deinit();
            const object = switch (document.value) {
                .object => |value| value,
                else => return error.TestUnexpectedResult,
            };
            if (object.get("ack")) |value| {
                try std.testing.expect(value.bool);
                continue;
            }
            const stream_kind = switch (object.get("stream") orelse return error.TestUnexpectedResult) {
                .string => |value| value,
                else => return error.TestUnexpectedResult,
            };
            if (!std.mem.eql(u8, stream_kind, "events")) continue;
            const entries = switch (object.get("events") orelse return error.TestUnexpectedResult) {
                .array => |value| value,
                else => return error.TestUnexpectedResult,
            };
            delivered += entries.items.len;
            const through = switch (object.get("through") orelse return error.TestUnexpectedResult) {
                .integer => |value| @as(u64, @intCast(value)),
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expect(through > acked);
            acked = through;
            var buffer: [160]u8 = undefined;
            const ack = try std.fmt.bufPrint(&buffer, "{{\"v\":{d},\"id\":7,\"op\":\"ack\",\"epoch\":1,\"sequence\":{d}}}", .{ protocol.version, through });
            try peers[1].?.writeFrame(ack, .{ .io = io, .timeout_ms = 2_000 });
        }
        serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    }
    try std.testing.expectEqual(produced, delivered);
    try std.testing.expect(delivered > 1024);
    try std.testing.expectEqual(acked, host.events.reclaimed_through);
    try std.testing.expect(host.pending_event == null);
    try std.testing.expectEqual(@as(usize, 0), host.events.items.items.len);
    // Reversible pause: one more ordinary event is admitted after reclamation.
    try bridge_host.emit_fn(bridge_host.context, .{ .text = "resumed" }, &host.cancel);
    host.pump(0);
    try std.testing.expectEqual(@as(usize, 1), host.events.items.items.len);
}
test "a held CR cannot block selectively acknowledged metadata before its LF" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // Linux socketpair flags
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    var slots: [max_connections]?Active = @splat(null);
    defer closeSlots(host, &slots);
    var peers: [2]?unix.Connection = @splat(null);
    defer for (&peers) |*peer| if (peer.*) |*conn| conn.close();
    for (0..2) |i| {
        var fds: [2]std.c.fd_t = undefined;
        const rc = std.os.linux.socketpair(1, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
        const credentials: unix.Credentials = .{ .pid = @intCast(std.os.linux.getpid()), .uid = @intCast(std.c.geteuid()), .gid = @intCast(std.c.getegid()) };
        slots[i] = .{ .id = i + 1, .conn = unix.Connection.init(a, fds[0], credentials) };
        peers[i] = unix.Connection.init(a, fds[1], credentials);
    }
    var attach = try protocol.parseRequest(a, "{\"v\":5,\"id\":1,\"op\":\"attach\"}");
    defer attach.deinit();
    const attached = try host.dispatch(a, &attach, 1, false);
    defer a.free(attached);
    var watch = try protocol.parseRequest(a, "{\"v\":5,\"id\":2,\"op\":\"watch\",\"epoch\":1}");
    defer watch.deinit();
    try startWatch(host, a, io, &slots[1].?, &watch, &slots);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const snapshot = (try peers[1].?.readStep()).frame;
    defer a.free(snapshot);
    try advanceWatch(host, a, io, &slots[1].?);
    try std.testing.expect(try slots[1].?.conn.writeStep());
    const baseline = (try peers[1].?.readStep()).frame;
    defer a.free(baseline);

    // seq1 is text ending in a held CR: it can never be proven until the LF
    // arrives. Metadata follows and must remain independently ackable.
    const metadata: usize = 1080;
    const planned: usize = metadata + 2;
    const bridge_host = host.bridge.host();
    var produced: usize = 0;
    var delivered: usize = 0;
    var cursor: u64 = 0;
    var highest: u64 = 0;
    var got_cr = false;
    var got_lf = false;
    var rounds: usize = 0;
    while (delivered < planned and rounds < 2_000_000) : (rounds += 1) {
        host.pump(0);
        if (produced < planned and host.pending_event == null) {
            if (produced == 0) {
                try bridge_host.emit_fn(bridge_host.context, .{ .text = "x\r" }, &host.cancel);
            } else if (produced == planned - 1) {
                try bridge_host.emit_fn(bridge_host.context, .{ .text = "\n" }, &host.cancel);
            } else {
                try bridge_host.emit_fn(bridge_host.context, .{ .state = .calling_model }, &host.cancel);
            }
            produced += 1;
        }
        if (!slots[1].?.conn.writePending()) try advanceWatch(host, a, io, &slots[1].?);
        _ = try slots[1].?.conn.writeStep();
        while (true) {
            const step = try peers[1].?.readStep();
            const frame = switch (step) {
                .pending => break,
                .eof => return error.TestUnexpectedResult,
                .frame => |bytes| bytes,
            };
            defer a.free(frame);
            var document = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
            defer document.deinit();
            const object = switch (document.value) {
                .object => |value| value,
                else => return error.TestUnexpectedResult,
            };
            if (object.get("ack")) |value| {
                try std.testing.expect(value.bool);
                continue;
            }
            const stream_kind = switch (object.get("stream") orelse return error.TestUnexpectedResult) {
                .string => |value| value,
                else => return error.TestUnexpectedResult,
            };
            if (!std.mem.eql(u8, stream_kind, "events")) continue;
            const entries = switch (object.get("events") orelse return error.TestUnexpectedResult) {
                .array => |value| value,
                else => return error.TestUnexpectedResult,
            };
            for (entries.items) |entry| {
                const event = switch (entry) {
                    .object => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                const kind = switch (event.get("t") orelse return error.TestUnexpectedResult) {
                    .string => |value| value,
                    else => return error.TestUnexpectedResult,
                };
                if (std.mem.eql(u8, kind, "text")) {
                    const text = switch (event.get("v") orelse return error.TestUnexpectedResult) {
                        .string => |value| value,
                        else => return error.TestUnexpectedResult,
                    };
                    if (std.mem.eql(u8, text, "x\r")) got_cr = true;
                    if (std.mem.eql(u8, text, "\n")) got_lf = true;
                }
            }
            delivered += entries.items.len;
            const through = switch (object.get("through") orelse return error.TestUnexpectedResult) {
                .integer => |value| @as(u64, @intCast(value)),
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expect(through > cursor);
            // The CR position (1) is never part of a proven range.
            const first = @max(cursor + 1, 2);
            cursor = through;
            if (first > through) continue;
            highest = through;
            var buffer: [192]u8 = undefined;
            const ack = try std.fmt.bufPrint(&buffer, "{{\"v\":{d},\"id\":8,\"op\":\"ack\",\"epoch\":1,\"sequence\":{d},\"first\":{d}}}", .{ protocol.version, through, first });
            try peers[1].?.writeFrame(ack, .{ .io = io, .timeout_ms = 2_000 });
        }
        serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    }
    try std.testing.expectEqual(planned, produced);
    try std.testing.expectEqual(planned, delivered);
    try std.testing.expect(got_cr and got_lf);
    // Metadata was retired selectively; the unproven CR keeps the exact-recovery
    // cursor at zero instead of fabricating its proof.
    try std.testing.expectEqual(@as(u64, 0), host.events.reclaimed_through);
    try std.testing.expectEqual(highest, host.events.highest_acknowledged);
    try std.testing.expectEqual(@as(usize, 1), host.events.items.items.len);
    try std.testing.expectEqual(@as(u64, 1), host.events.items.items[0].seq);
    // Once the CR text is really proven as a prefix, everything retires.
    const all = try std.fmt.allocPrint(a, "{{\"v\":5,\"id\":9,\"op\":\"ack\",\"epoch\":1,\"sequence\":{d}}}", .{highest});
    defer a.free(all);
    try peers[1].?.writeFrame(all, .{ .io = io, .timeout_ms = 2_000 });
    serveWatchInput(host, a, io, &slots[1].?, &slots[1], &slots);
    try std.testing.expectEqual(highest, host.events.reclaimed_through);
    try std.testing.expectEqual(@as(usize, 0), host.events.items.items.len);
}
