test "native socketPair configures nonblocking close-on-exec and Darwin no-SIGPIPE" {
    const pair = try socketPair();
    defer fs.closeFd(pair[0]);
    defer fs.closeFd(pair[1]);
    const nonblock: u32 = @bitCast(@as(c.O, .{ .NONBLOCK = true }));
    for (pair) |fd| {
        const flags = c.fcntl(fd, c.F.GETFL);
        try std.testing.expect(flags >= 0);
        try std.testing.expect(@as(u32, @intCast(flags)) & nonblock != 0);
        const descriptor = c.fcntl(fd, c.F.GETFD);
        try std.testing.expect(descriptor >= 0);
        try std.testing.expect(descriptor & c.FD_CLOEXEC != 0);
        if (builtin.os.tag == .macos) {
            var enabled: c_int = 0;
            var len: c.socklen_t = @sizeOf(c_int);
            try std.testing.expectEqual(@as(c_int, 0), c.getsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &enabled, &len));
            try std.testing.expectEqual(@as(c_int, 1), enabled);
        }
    }
}
test "partial frame storage is wiped before discard and close is idempotent" {
    var conn = Connection.init(std.testing.allocator, -1, test_peer);
    defer conn.close();
    try conn.body.appendSlice(std.testing.allocator, "partial-login-credential");
    conn.body_read = conn.body.items.len;
    conn.wipePendingBody();
    for (conn.body.items) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    conn.close();
    try std.testing.expectEqual(@as(usize, 0), conn.body.items.len);
    conn.close();
}
test "step reader preserves partial header and body without waiting" {
    var pair = try testPair(std.testing.allocator);
    defer pair.a.close();
    defer pair.b.close();
    try std.testing.expect((try pair.a.readStep()) == .pending);
    try sendAll(pair.b.fd, &.{ 0, 0 });
    try std.testing.expect((try pair.a.readStep()) == .pending);
    try std.testing.expectEqual(@as(usize, 2), pair.a.header_read);
    try sendAll(pair.b.fd, &.{ 0, 3, 'a' });
    try std.testing.expect((try pair.a.readStep()) == .pending);
    try std.testing.expectEqual(@as(usize, 1), pair.a.body_read);
    try sendAll(pair.b.fd, "bc");
    const frame = (try pair.a.readStep()).frame;
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("abc", frame);
    try sendAll(pair.b.fd, &.{ 0, 0, 0, 0 });
    const empty = (try pair.a.readStep()).frame;
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    pair.b.close();
    try std.testing.expect((try pair.a.readStep()) == .eof);
}
test "step reader rejects truncated frames without allocating declared length" {
    for ([_][]const u8{ &.{0}, &.{ 0, 0, 0, 2, 'x' }, &.{ 0xff, 0xff, 0xff, 0xff } }) |raw| {
        var pair = try testPair(std.testing.allocator);
        defer pair.a.close();
        defer pair.b.close();
        try sendAll(pair.b.fd, raw);
        try std.testing.expect((try pair.a.readStep()) == .pending);
        try std.testing.expect(pair.a.body.capacity < 1024);
        pair.b.close();
        try std.testing.expectError(error.TruncatedFrame, pair.a.readStep());
        try std.testing.expectError(error.StreamPoisoned, pair.a.readStep());
    }
}
test "step writer backpressure preserves the exact frame and another connection progresses" {
    const a = std.testing.allocator;
    var slow = try testPair(a);
    defer slow.a.close();
    defer slow.b.close();
    var fast = try testPair(a);
    defer fast.a.close();
    defer fast.b.close();
    const payload = try a.alloc(u8, 1024 * 1024 + 12345);
    defer a.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try slow.a.queueFrame(payload);
    try std.testing.expectError(error.WriteInProgress, slow.a.queueFrame("interleave"));
    try std.testing.expectError(error.WriteInProgress, slow.a.writeFrame("interleave", testWait()));
    // Do not read the peer: bounded steps eventually encounter EAGAIN.
    for (0..64) |_| _ = try slow.a.writeStep();
    try std.testing.expect(slow.a.writePending());
    try std.testing.expect(slow.a.outgoing_offset > 0);
    const stopped_at = slow.a.outgoing_offset;
    try std.testing.expect(!try slow.a.writeStep());
    try std.testing.expectEqual(stopped_at, slow.a.outgoing_offset);
    try fast.a.queueFrame("control-reply");
    try std.testing.expect(try fast.a.writeStep());
    const quick = (try fast.b.readStep()).frame;
    defer a.free(quick);
    try std.testing.expectEqualStrings("control-reply", quick);
    var received = false;
    const transfer_start = std.Io.Clock.awake.now(std.testing.io);
    // Socket buffer sizes differ by target; bound time, not Linux-sized steps.
    while (transfer_start.untilNow(std.testing.io, .awake).toMilliseconds() < 5000) {
        _ = try slow.a.writeStep();
        switch (try slow.b.readStep()) {
            .frame => |frame| {
                defer a.free(frame);
                try std.testing.expectEqualSlices(u8, payload, frame);
                received = true;
                break;
            },
            .pending => {},
            .eof => return error.UnexpectedEof,
        }
    }
    try std.testing.expect(received);
    try std.testing.expect(!slow.a.poisoned);
    try std.testing.expect(!slow.a.writePending());
    try slow.a.queueFrame("next");
    try std.testing.expect(try slow.a.writeStep());
    const next = (try slow.b.readStep()).frame;
    defer a.free(next);
    try std.testing.expectEqualStrings("next", next);
}
test "frame roundtrip and clean EOF" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();
    const wait = testWait();

    try b.writeFrame("hello", wait);
    const frame = (try a.readFrame(wait)).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("hello", frame);

    // A zero-length frame stays distinguishable from EOF.
    try b.writeFrame("", wait);
    const empty = (try a.readFrame(wait)).?;
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    b.close();
    try std.testing.expect((try a.readFrame(wait)) == null);
}
test "read timeout preserves a partial frame" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();
    const short: Wait = .{ .io = std.testing.io, .timeout_ms = 20 };

    var header: [header_size]u8 = undefined;
    std.mem.writeInt(u32, &header, 5, .big);
    try sendAll(b.descriptor(), header[0..2]);
    try std.testing.expectError(error.Timeout, a.readFrame(short));

    // The consumed prefix is retained; the frame completes on the next call.
    try sendAll(b.descriptor(), header[2..4]);
    try sendAll(b.descriptor(), "hello");
    const frame = (try a.readFrame(testWait())).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("hello", frame);
}
test "wait progress ticks while no frame arrives and can cancel" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var token: protocol.Cancellation = .{};
    var probe: TestProgress = .{ .cancel_after = 3, .token = &token };
    const wait: Wait = .{
        .io = std.testing.io,
        .timeout_ms = 2000,
        .cancel = &token,
        .progress_context = &probe,
        .progress_fn = TestProgress.run,
    };

    // No bytes are ever sent: the wait stays silent but the pump keeps ticking.
    try std.testing.expectError(error.Canceled, a.readFrame(wait));
    try std.testing.expect(probe.ticks >= 3);
    try std.testing.expect(token.isRequested());
    // Canceling before any byte preserves the (still empty) partial frame.
    try std.testing.expect(!a.poisoned);
}
test "wait progress errors abort the wait unchanged" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var probe: TestProgress = .{ .fail_after = 2 };
    const wait: Wait = .{
        .io = std.testing.io,
        .timeout_ms = 2000,
        .progress_context = &probe,
        .progress_fn = TestProgress.run,
    };
    try std.testing.expectError(error.Canceled, a.readFrame(wait));
    try std.testing.expectEqual(@as(usize, 2), probe.ticks);
}
test "wait progress ticks do not extend the original deadline" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var probe: TestProgress = .{};
    const start = std.Io.Clock.awake.now(std.testing.io);
    const wait: Wait = .{
        .io = std.testing.io,
        .timeout_ms = 150,
        .progress_context = &probe,
        .progress_fn = TestProgress.run,
    };
    try std.testing.expectError(error.Timeout, a.readFrame(wait));
    const elapsed = start.untilNow(std.testing.io, .awake).toMilliseconds();

    // Several progress ticks happen inside one time budget...
    try std.testing.expect(probe.ticks >= 2);
    // ...and the wait still ends on the original deadline instead of a re-based one.
    try std.testing.expect(elapsed >= 120);
    try std.testing.expect(elapsed < 700);
}
test "truncated frame and poisoned stream" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    try sendAll(b.descriptor(), "\x00\x00");
    b.close();
    try std.testing.expectError(error.TruncatedFrame, a.readFrame(testWait()));
    try std.testing.expectError(error.StreamPoisoned, a.readFrame(testWait()));
}
test "maximum declared length does not allocate on header" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var header: [header_size]u8 = undefined;
    std.mem.writeInt(u32, &header, std.math.maxInt(u32), .big);
    try sendAll(b.descriptor(), &header);
    try std.testing.expect((try a.readStep()) == .pending);
    try std.testing.expectEqual(@as(usize, 0), a.body.capacity);
    b.close();
    try std.testing.expectError(error.TruncatedFrame, a.readStep());
}
test "oversized write is refused before any byte is written" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();
    const wait = testWait();

    if (@sizeOf(usize) <= @sizeOf(u32)) return error.SkipZigTest;
    const ptr: [*]const u8 = @ptrFromInt(1);
    const payload = ptr[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try std.testing.expectError(error.FrameTooLarge, b.writeFrame(payload, wait));

    // The stream is untouched and still usable.
    try b.writeFrame("ok", wait);
    const frame = (try a.readFrame(wait)).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("ok", frame);
}
test "cancellation interrupts a pending read and accept" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var token: protocol.Cancellation = .{};
    token.cancel();
    try std.testing.expectError(
        error.Canceled,
        a.readFrame(.{ .io = std.testing.io, .timeout_ms = 1000, .cancel = &token }),
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();
    var listener = try Listener.bind(allocator, &dir, "c.sock", .{});
    defer listener.deinit();
    try std.testing.expectError(
        error.Canceled,
        listener.accept(.{ .io = std.testing.io, .timeout_ms = 1000, .cancel = &token }),
    );
}
test "private directory requires 0700, same UID, and no symlink" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const parent = buf[0..n];
    const parent_z = try allocator.dupeSentinel(u8, parent, 0);
    defer allocator.free(parent_z);

    // Explicitly establish a non-private directory, independent of umask.
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(parent_z, 0o755));
    try std.testing.expectError(error.InsecurePermissions, Directory.resolveBase(allocator, parent, me));
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(parent_z, 0o700));

    var dir = try Directory.resolveBase(allocator, parent, me);
    defer dir.deinit();
    try std.testing.expect(dir.created);
    const child_z = try allocator.dupeSentinel(u8, dir.path, 0);
    defer allocator.free(child_z);
    const child_st = try statAt(c.AT.FDCWD, child_z, true);
    try std.testing.expect(isDir(child_st.mode));
    try std.testing.expectEqual(@as(u16, 0o700), perms(child_st.mode));

    // Wrong expected owner: the leaf exists but is not owned by that UID.
    try std.testing.expectError(error.NotOwned, Directory.resolveUnder(allocator, parent, "foreign", me + 1));

    // A symlinked base is refused rather than followed.
    const link_z = try testPath(allocator, parent, "link");
    defer allocator.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("rt", c.AT.FDCWD, link_z));
    try std.testing.expectError(error.SymlinkNotAllowed, Directory.resolveBase(allocator, link_z, me));
}
test "runtime directory refuses symlinked ancestors as well as leaves" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "real", .default_dir);
    try tmp.dir.symLink(std.testing.io, "real", "alias", .{});
    var buf: [4096]u8 = undefined;
    const parent = try testParent(&tmp, &buf);
    const alias = try std.fmt.allocPrint(a, "{s}/alias", .{parent});
    defer a.free(alias);
    try std.testing.expectError(error.SymlinkNotAllowed, Directory.resolveUnder(a, alias, "rt", @intCast(c.geteuid())));
}
test "socket names and paths are validated" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    try std.testing.expectError(error.InvalidName, dir.join(allocator, "a/b"));
    try std.testing.expectError(error.InvalidName, dir.join(allocator, ".."));
    try std.testing.expectError(error.InvalidName, dir.join(allocator, ""));

    // room = max name length that still overflows the sockaddr_un path.
    const room: usize = max_socket_path_len - dir.path.len;
    if (room <= max_name_len) {
        var name_buf: [max_name_len + 1]u8 = undefined;
        @memset(&name_buf, 'x');
        try std.testing.expectError(error.NameTooLong, dir.join(allocator, name_buf[0..room]));
        const ok = try dir.join(allocator, name_buf[0 .. room - 1]);
        defer allocator.free(ok);
        try std.testing.expectEqual(max_socket_path_len, ok.len);
    }
}
test "created directory cleanup is empty-only and identity checked" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();
    try std.testing.expect(dir.created);

    const keep_fd = fs.openAt(dir.fd, "keep", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
    try std.testing.expect(keep_fd >= 0);
    fs.closeFd(keep_fd);
    try std.testing.expectError(error.DirectoryNotEmpty, dir.removeIfEmpty());

    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir.fd, "keep", 0));
    const path_copy = try allocator.dupeSentinel(u8, dir.path, 0);
    defer allocator.free(path_copy);
    try dir.removeIfEmpty();
    try std.testing.expectError(error.FileNotFound, statAt(c.AT.FDCWD, path_copy, true));
    // Idempotent when the directory is already gone.
    try dir.removeIfEmpty();
}
test "lock is exclusive, keeps one fixed inode, and is never unlinked" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    var first = try Lock.acquire(allocator, &dir, "daemon.lock");
    try std.testing.expect(first.isHeld());
    try std.testing.expectError(error.AlreadyRunning, Lock.acquire(allocator, &dir, "daemon.lock"));

    const name_z = try allocator.dupeSentinel(u8, "daemon.lock", 0);
    defer allocator.free(name_z);
    const before = try statAt(dir.fd, name_z, true);
    try std.testing.expect(isReg(before.mode));
    try std.testing.expectEqual(@as(u16, 0o600), perms(before.mode));

    first.release();
    try std.testing.expect(!first.isHeld());

    var second = try Lock.acquire(allocator, &dir, "daemon.lock");
    const after = try statAt(dir.fd, name_z, true);
    try std.testing.expectEqual(before.ino, after.ino);
    try std.testing.expectEqual(before.dev_major, after.dev_major);
    second.release();

    const still = try statAt(dir.fd, name_z, true);
    try std.testing.expect(isReg(still.mode));
}
test "lock refuses symlinked and permissive lock files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    const link_z = try allocator.dupeSentinel(u8, "link.lock", 0);
    defer allocator.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("daemon.lock", dir.fd, link_z));

    const loose_fd = fs.openAt(
        dir.fd,
        "loose.lock",
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true },
        0o600,
    );
    try std.testing.expect(loose_fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(loose_fd, 0o644));
    fs.closeFd(loose_fd);

    // O_NOFOLLOW turns the symlink into ELOOP at open time.
    try std.testing.expectError(error.SymlinkNotAllowed, Lock.acquire(allocator, &dir, "link.lock"));
    try std.testing.expectError(error.InsecurePermissions, Lock.acquire(allocator, &dir, "loose.lock"));
}
test "listener binds a 0600 socket and verifies peer UID on both ends" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    var lock = try Lock.acquire(allocator, &dir, "daemon.lock");
    defer lock.release();
    var listener = try Listener.bind(allocator, &dir, "daemon.sock", .{ .lock = &lock });
    defer listener.deinit();

    const name_z = try allocator.dupeSentinel(u8, "daemon.sock", 0);
    defer allocator.free(name_z);
    const st = try statAt(dir.fd, name_z, true);
    try std.testing.expect(isSock(st.mode));
    try std.testing.expectEqual(@as(u16, 0o600), perms(st.mode));
    try std.testing.expectEqual(me, st.uid);

    const wait = testWait();
    var client = try connect(allocator, listener.socketPath(), me, wait);
    defer client.close();
    // The helper is already reaped. Before accept the kernel must identify the
    // actual listener, not the process which bound and transferred its fd.
    try std.testing.expectEqual(@as(u32, @intCast(c.getpid())), client.peer.pid);
    var server = try listener.accept(wait);
    defer server.close();

    try std.testing.expectEqual(me, client.peer.uid);
    try std.testing.expectEqual(me, server.peer.uid);
    try std.testing.expectEqual(@as(u32, @intCast(c.getpid())), server.peer.pid);
    try std.testing.expectEqual(client.peer.pid, (try socketCredentials(client.fd)).pid);

    try client.writeFrame("ping", wait);
    const frame = (try server.readFrame(wait)).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("ping", frame);

    // A client expecting another UID is refused by the path prevalidation:
    // `connect` stats the socket node before dialling, so the wrong owner is
    // rejected as NotOwned and SO_PEERCRED is never consulted. (A genuine
    // PeerUidMismatch needs a peer of a different UID behind a node this UID
    // owns, which an unprivileged owned fixture cannot produce.)
    try std.testing.expectError(error.NotOwned, connect(allocator, listener.socketPath(), me + 1, wait));
}
test "listener accept honors timeout and cancellation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();
    var listener = try Listener.bind(allocator, &dir, "idle.sock", .{});
    defer listener.deinit();

    try std.testing.expectError(
        error.Timeout,
        listener.accept(.{ .io = std.testing.io, .timeout_ms = 30 }),
    );
    var token: protocol.Cancellation = .{};
    token.cancel();
    try std.testing.expectError(
        error.Canceled,
        listener.accept(.{ .io = std.testing.io, .timeout_ms = 1000, .cancel = &token }),
    );
}
test "listener cleanup removes only its own socket inode" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    const name_z = try allocator.dupeSentinel(u8, "owned.sock", 0);
    defer allocator.free(name_z);

    // Normal cleanup removes the socket this instance bound.
    var first = try Listener.bind(allocator, &dir, "owned.sock", .{});
    first.deinit();
    try std.testing.expectError(error.FileNotFound, statAt(dir.fd, name_z, true));

    // If the entry was replaced by another inode, cleanup leaves it alone.
    var second = try Listener.bind(allocator, &dir, "owned.sock", .{});
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir.fd, name_z, 0));
    const other_fd = fs.openAt(
        dir.fd,
        name_z,
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true },
        0o600,
    );
    try std.testing.expect(other_fd >= 0);
    fs.closeFd(other_fd);
    second.deinit();
    const replaced = try statAt(dir.fd, name_z, true);
    try std.testing.expect(isReg(replaced.mode));
}
test "stale socket cleanup requires the lock and the owner UID" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    var lock = try Lock.acquire(allocator, &dir, "daemon.lock");
    defer lock.release();
    var listener = try Listener.bind(allocator, &dir, "stale.sock", .{ .lock = &lock });
    defer listener.deinit();
    listener.close(); // keep the socket inode, drop the listener fd

    // A released lock is not proof of ownership.
    var released = try Lock.acquire(allocator, &dir, "other.lock");
    released.release();
    try std.testing.expectError(error.LockNotHeld, removeStaleSocket(&released, &dir, "stale.sock"));

    try std.testing.expect(try removeStaleSocket(&lock, &dir, "stale.sock"));
    try std.testing.expect(!(try removeStaleSocket(&lock, &dir, "stale.sock")));

    // Regular files are never removed.
    const file_fd = fs.openAt(
        dir.fd,
        "file.sock",
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true },
        0o600,
    );
    try std.testing.expect(file_fd >= 0);
    fs.closeFd(file_fd);
    try std.testing.expectError(error.NotASocket, removeStaleSocket(&lock, &dir, "file.sock"));

    // Nor are symlinks.
    const link_z = try allocator.dupeSentinel(u8, "link.sock", 0);
    defer allocator.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("stale.sock", dir.fd, link_z));
    try std.testing.expectError(error.SymlinkNotAllowed, removeStaleSocket(&lock, &dir, "link.sock"));

    // A UID mismatch between lock and directory is refused outright.
    var foreign_lock: Lock = lock;
    foreign_lock.uid = me + 1;
    foreign_lock.held = true;
    try std.testing.expectError(error.UidMismatch, removeStaleSocket(&foreign_lock, &dir, "stale.sock"));
}
test "stale cleanup requires the lock taken in this very directory" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const parent = try testParent(&tmp, &buf);

    var dir_a = try Directory.resolveUnder(allocator, parent, "a", me);
    defer dir_a.deinit();
    var dir_b = try Directory.resolveUnder(allocator, parent, "b", me);
    defer dir_b.deinit();

    // A genuinely held lock, but of the other directory.
    var lock_a = try Lock.acquire(allocator, &dir_a, "daemon.lock");
    defer lock_a.release();
    try std.testing.expect(lock_a.isHeld());

    // The other directory holds a live socket of this same UID.
    var listener_b = try Listener.bind(allocator, &dir_b, "active.sock", .{});
    defer listener_b.deinit();
    const name_z = try allocator.dupeSentinel(u8, "active.sock", 0);
    defer allocator.free(name_z);

    try std.testing.expectError(error.DirectoryMismatch, removeStaleSocket(&lock_a, &dir_b, "active.sock"));
    const after = try statAt(dir_b.fd, name_z, true);
    try std.testing.expect(Identity.from(after).eql(listener_b.socketIdentity()));

    // The bind path refuses the same way and deletes nothing.
    try std.testing.expectError(
        error.DirectoryMismatch,
        Listener.bind(allocator, &dir_b, "active.sock", .{ .lock = &lock_a }),
    );
    const still = try statAt(dir_b.fd, name_z, true);
    try std.testing.expect(Identity.from(still).eql(listener_b.socketIdentity()));

    // The same lock still authorizes cleanup in the directory it locked.
    var stale = try Listener.bind(allocator, &dir_a, "stale.sock", .{ .lock = &lock_a });
    defer stale.deinit();
    stale.close();
    try std.testing.expect(try removeStaleSocket(&lock_a, &dir_a, "stale.sock"));
}
test "stale cleanup refuses a lock whose file inode was replaced" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    var lock = try Lock.acquire(allocator, &dir, "daemon.lock");
    defer lock.release();
    var listener = try Listener.bind(allocator, &dir, "stale.sock", .{ .lock = &lock });
    defer listener.deinit();
    listener.close();

    const lock_z = try allocator.dupeSentinel(u8, "daemon.lock", 0);
    defer allocator.free(lock_z);
    const sock_z = try allocator.dupeSentinel(u8, "stale.sock", 0);
    defer allocator.free(sock_z);

    // Replace the lock path with a fresh inode while the flock stays held.
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir.fd, lock_z, 0));
    const other_fd = fs.openAt(
        dir.fd,
        lock_z,
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true },
        0o600,
    );
    try std.testing.expect(other_fd >= 0);
    fs.closeFd(other_fd);

    try std.testing.expectError(error.LockIdentityChanged, removeStaleSocket(&lock, &dir, "stale.sock"));
    const kept = try statAt(dir.fd, sock_z, true);
    try std.testing.expect(Identity.from(kept).eql(listener.socketIdentity()));
    try std.testing.expectError(
        error.LockIdentityChanged,
        Listener.bind(allocator, &dir, "stale.sock", .{ .lock = &lock }),
    );
    const kept_again = try statAt(dir.fd, sock_z, true);
    try std.testing.expect(Identity.from(kept_again).eql(listener.socketIdentity()));
}
test "a failed bind owns and removes only the socket it created" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    const worker_z = try allocator.dupeSentinel(u8, "worker.sock", 0);
    defer allocator.free(worker_z);

    // No lock: a unique worker name binds, an occupied one is refused and the
    // existing entry is left untouched.
    var worker = try Listener.bind(allocator, &dir, "worker.sock", .{});
    defer worker.deinit();
    const before = try statAt(dir.fd, worker_z, true);
    try std.testing.expectError(error.AddressInUse, Listener.bind(allocator, &dir, "worker.sock", .{}));
    const after = try statAt(dir.fd, worker_z, true);
    try std.testing.expect(Identity.from(before).eql(Identity.from(after)));
    try std.testing.expect(Identity.from(after).eql(worker.socketIdentity()));

    const fresh_z = try allocator.dupeSentinel(u8, "fresh.sock", 0);
    defer allocator.free(fresh_z);

    // A failure after bind (chmod/listen/dup in production) releases only the
    // node this call created.
    try std.testing.expectError(
        error.InjectedBindFailure,
        Listener.bindInternal(allocator, &dir, "fresh.sock", .{}, .after_bind),
    );
    try std.testing.expectError(error.FileNotFound, statAt(dir.fd, fresh_z, true));

    // The same holds with the lock, where a stale entry is removed first.
    var lock = try Lock.acquire(allocator, &dir, "daemon.lock");
    defer lock.release();
    var stale = try Listener.bind(allocator, &dir, "fresh.sock", .{ .lock = &lock });
    stale.close();
    defer stale.deinit();
    try std.testing.expectError(
        error.InjectedBindFailure,
        Listener.bindInternal(allocator, &dir, "fresh.sock", .{ .lock = &lock }, .after_bind),
    );
    try std.testing.expectError(error.FileNotFound, statAt(dir.fd, fresh_z, true));
}
test "bind refuses a renamed or replaced runtime directory" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const parent = try testParent(&tmp, &buf);
    const parent_z = try allocator.dupeSentinel(u8, parent, 0);
    defer allocator.free(parent_z);
    const parent_fd = try fs.openDirectory(c.AT.FDCWD, parent_z);
    defer fs.closeFd(parent_fd);

    var dir = try Directory.resolveUnder(allocator, parent, "rt", me);
    defer dir.deinit();

    var listener = try Listener.bind(allocator, &dir, "live.sock", .{});
    defer listener.deinit();
    const expected = try dir.join(allocator, "live.sock");
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, listener.socketPath());

    const live_z = try allocator.dupeSentinel(u8, "live.sock", 0);
    defer allocator.free(live_z);
    const bound = try statAt(dir.fd, live_z, true);
    try std.testing.expect(Identity.from(bound).eql(listener.socketIdentity()));

    // Move the directory away while its fd is still held: the fd keeps pointing
    // at the same inode, but the published path no longer names it.
    try std.testing.expectEqual(@as(c_int, 0), c.renameat(parent_fd, "rt", parent_fd, "rt-moved"));
    try std.testing.expectError(error.DirectoryMoved, Listener.bind(allocator, &dir, "other.sock", .{}));

    // A fresh directory at the old path is a different identity: still refused.
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(parent_fd, "rt", 0o700));
    try std.testing.expectError(error.DirectoryMoved, Listener.bind(allocator, &dir, "other.sock", .{}));

    // Neither directory received the refused socket.
    try std.testing.expectError(error.FileNotFound, statAt(dir.fd, "other.sock", true));
    const fresh_fd = try fs.openDirectory(parent_fd, "rt");
    defer fs.closeFd(fresh_fd);
    try std.testing.expectError(error.FileNotFound, statAt(fresh_fd, "other.sock", true));
}
test "connect reports a missing endpoint without creating anything" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    const path = try dir.join(allocator, "absent.sock");
    defer allocator.free(path);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    try std.testing.expectError(error.FileNotFound, connect(allocator, path, @intCast(c.geteuid()), testWait()));
    // The failed client must not leave an entry behind.
    try std.testing.expectError(error.FileNotFound, statAt(c.AT.FDCWD, path_z, true));
}
