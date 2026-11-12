test "record above former five MiB limit is written intact" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var store = Store.init(a, &root);
    defer store.deinit();
    const record = try a.alloc(u8, 5 * 1024 * 1024 + 17);
    defer a.free(record);
    @memset(record, 'x');
    @memcpy(record[0..6], "{\"v\":\"");
    @memcpy(record[record.len - 2 ..], "\"}");
    try store.append(record);
    const result = try root.read(a, store.path(), 0, record.len + 1);
    defer a.free(result.data);
    try std.testing.expectEqual(record.len + 1, result.data.len);
    try std.testing.expectEqualSlices(u8, record, result.data[0..record.len]);
    try std.testing.expectEqual(@as(u8, '\n'), result.data[record.len]);
}
test "pinned identity is lazy immutable and collision never substitutes another identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const id: ids.Id = @splat('b');
    var store = Store.init(std.testing.allocator, &root);
    defer store.deinit();
    var invalid = id;
    invalid[0] = '\n';
    try std.testing.expectError(error.InvalidSessionID, store.pinSessionID(invalid));
    try std.testing.expect(store.pinned_id == null);
    try store.pinSessionID(id);
    try store.pinSessionID(id);
    try std.testing.expectError(error.SessionIDAlreadyPinned, store.pinSessionID(@splat('c')));
    try std.testing.expectError(error.FileNotFound, filesystem.openDirectory(root.dir.handle, ".thin"));
    try store.startTimestamp(1234);
    try std.testing.expectEqualStrings(".thin/sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-1234-0.jsonl", store.path());
    try std.testing.expectEqualSlices(u8, &id, &store.session_id);
    try std.testing.expectError(error.SessionIDAlreadyStarted, store.pinSessionID(id));
    try store.append("{}");
    var collision = Store.init(std.testing.allocator, &root);
    defer collision.deinit();
    try collision.pinSessionID(id);
    try std.testing.expectError(error.LogNameExhausted, collision.startTimestamp(1234));
    try std.testing.expect(collision.file_fd == null and collision.logs_fd == null);
    try std.testing.expectEqualSlices(u8, &id, &collision.pinned_id.?);
    try expectContent(&root, store.path(), "{}\n");
}
test "log store lazy init private modes ordered compact lines and independent sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var store = Store.init(std.testing.allocator, &root);
    defer store.deinit();
    try std.testing.expectEqualStrings("", store.path());
    try std.testing.expectError(error.FileNotFound, filesystem.openDirectory(root.dir.handle, ".thin"));
    try store.start();
    try std.testing.expect(std.mem.startsWith(u8, store.path(), ".thin/sessions/"));
    try std.testing.expectError(error.FileNotFound, root.dir.statFile(root.io, ".thin/logs", .{}));
    try expectContent(&root, ".thin/sessions/.gitignore", "*\n");
    const marker_stat = try root.dir.statFile(root.io, ".thin/sessions/.gitignore", .{});
    try std.testing.expectEqual(@as(u32, 0o600), marker_stat.permissions.toMode() & 0o777);
    const fd = store.file_fd.?;
    const original = try std.testing.allocator.dupe(u8, store.path());
    defer std.testing.allocator.free(original);
    try store.start();
    try std.testing.expectEqual(fd, store.file_fd.?);
    try expectContent(&root, store.path(), "");
    const dir_stat = try filesystem.fileFromFd(store.logs_fd.?).stat(root.io);
    const file_stat = try filesystem.fileFromFd(fd).stat(root.io);
    try std.testing.expectEqual(@as(u32, 0o700), dir_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o600), file_stat.permissions.toMode() & 0o777);
    try store.append(" { \"a\": 1, \"s\": \"中 \\\" \\n\" } ");
    try store.append("{\"b\":2}");
    try expectContent(&root, original, "{\"a\":1,\"s\":\"中 \\\" \\n\"}\n{\"b\":2}\n");
    var other = Store.init(std.testing.allocator, &root);
    defer other.deinit();
    try other.append("{}");
    try std.testing.expect(!std.mem.eql(u8, store.path(), other.path()));
    try std.testing.expect(!std.mem.eql(u8, &store.session_id, &other.session_id));
    try expectContent(&root, other.path(), "{}\n");
}
test "log store does not rotate at former file threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var store = Store.init(std.testing.allocator, &root);
    defer store.deinit();
    try store.pinSessionID(@splat('b'));
    try store.startTimestamp(1234);
    try std.testing.expectEqualStrings(".thin/sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-1234-0.jsonl", store.path());
    try store.append("{}");
    const first = try std.testing.allocator.dupe(u8, store.path());
    defer std.testing.allocator.free(first);
    const old_fd = store.file_fd.?;
    // Sparse positional offset crosses the old 500 MiB threshold without a large fixture.
    store.bytes = 500 * 1024 * 1024;
    try store.append("{}");
    try std.testing.expectEqual(old_fd, store.file_fd.?);
    try std.testing.expectEqualStrings(first, store.path());
    try std.testing.expectEqual(@as(usize, 500 * 1024 * 1024 + 3), store.bytes);
    try std.testing.expectEqual(@as(u64, 500 * 1024 * 1024 + 3), (try filesystem.fileFromFd(old_fd).stat(root.io)).size);
}
test "log store invalid records and allocation failure do not create directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var store = Store.init(std.testing.allocator, &root);
    defer store.deinit();
    try std.testing.expectError(error.RawNewline, store.append("{}\n"));
    try std.testing.expectError(error.RawNewline, store.append("{\r}"));
    try std.testing.expectError(error.InvalidUtf8, store.append("{\"a\":\"\xff\"}"));
    try std.testing.expectError(error.ExpectedJsonObject, store.append("[]"));
    try std.testing.expectError(error.InvalidJson, store.append("{\"a\":}"));
    try std.testing.expectError(error.InvalidJson, store.append("{}{}"));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var oom = Store.init(failing.allocator(), &root);
    defer oom.deinit();
    try std.testing.expectError(error.OutOfMemory, oom.append("{}"));
    try std.testing.expectError(error.FileNotFound, filesystem.openDirectory(root.dir.handle, ".thin"));
}
test "log store partial write poisons store and creation failure closes owned fds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var vtable = root.io.vtable.*;
    root.io.vtable = &vtable;
    var store = Store.init(std.testing.allocator, &root);
    defer store.deinit();
    // 先准备有效 marker，下面的 stat 故障只用于日志新文件。
    const thin = try Store.directory(root.dir.handle, ".thin");
    defer filesystem.closeFd(thin);
    const logs = try Store.directory(thin, "sessions");
    defer filesystem.closeFd(logs);
    try store.ensureIgnore(logs);
    vtable.fileStat = regularStatFailure;
    const before = try openFdCount();
    for (0..8) |_| try std.testing.expectError(error.Unexpected, store.start());
    try std.testing.expectEqual(before, try openFdCount());
    try std.testing.expect(store.file_fd == null and store.logs_fd == null);
    try std.testing.expectEqualStrings("", store.path());
    vtable.fileStat = std.testing.io.vtable.fileStat;
    try store.append("{}");
    vtable.fileWritePositional = partialWriteFailure;
    try std.testing.expectError(error.NoSpaceLeft, store.append("{}"));
    try std.testing.expectEqual(@as(usize, 3), store.bytes);
    try expectContent(&root, store.path(), "{}\n{");
    try std.testing.expectError(error.LogStoreFailed, store.append("{}"));
    try std.testing.expectError(error.LogStoreFailed, store.start());
    try expectContent(&root, store.path(), "{}\n{");
    store.deinit();
    try std.testing.expectEqual(before, try openFdCount());
}
test "log store ignore marker rejects unsafe modes content symlinks FIFO and directories" {
    for (0..10) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root = try testRoot(tmp.dir);
        defer root.deinit();
        const thin = try Store.directory(root.dir.handle, ".thin");
        defer filesystem.closeFd(thin);
        const logs = try Store.directory(thin, "sessions");
        defer filesystem.closeFd(logs);
        switch (case) {
            7 => try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", logs, ".gitignore")),
            8 => try std.testing.expectEqual(@as(c_int, 0), mkfifoat(logs, ".gitignore", 0o600)),
            9 => try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(logs, ".gitignore", 0o700)),
            else => {
                const content = switch (case) {
                    3 => "",
                    4 => "*",
                    5 => "*\nx",
                    6 => "x\n",
                    else => "*\n",
                };
                try root.write(".thin/sessions/.gitignore", content, false);
                const mode: u32 = switch (case) {
                    0 => 0o644,
                    1 => 0o640,
                    2 => 0o604,
                    else => 0o600,
                };
                try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(logs, ".gitignore", @intCast(mode), 0));
            },
        }
        var store = Store.init(std.testing.allocator, &root);
        defer store.deinit();
        const before = try openFdCount();
        for (0..4) |_| {
            if (case == 7) {
                try std.testing.expectError(error.SymlinkNotAllowed, store.append("{}"));
            } else {
                try std.testing.expectError(error.UnsafeLogIgnore, store.append("{}"));
            }
        }
        try std.testing.expectEqual(before, try openFdCount());
        try std.testing.expectEqual(@as(usize, 0), try jsonlCount(&root));
        try std.testing.expectEqualStrings("", store.path());
        if (case < 3) {
            try expectContent(&root, ".thin/sessions/.gitignore", "*\n");
            const stat = try root.dir.statFile(root.io, ".thin/sessions/.gitignore", .{});
            try std.testing.expect(stat.permissions.toMode() & 0o077 != 0);
        }
    }
}
test "log store marker lock is bounded and independent stores start after release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const thin = try Store.directory(root.dir.handle, ".thin");
    defer filesystem.closeFd(thin);
    const logs = try Store.directory(thin, "sessions");
    defer filesystem.closeFd(logs);
    var one = Store.init(std.testing.allocator, &root);
    defer one.deinit();
    var two = Store.init(std.testing.allocator, &root);
    defer two.deinit();
    try std.testing.expectEqual(@as(c_int, 0), filesystem.flock(logs, filesystem.LOCK.EX | filesystem.LOCK.NB));
    const before = try openFdCount();
    const start = std.Io.Clock.awake.now(root.io);
    try std.testing.expectError(error.LogStoreBusy, one.start());
    const elapsed = start.untilNow(root.io, .awake).toMilliseconds();
    try std.testing.expect(elapsed >= 200 and elapsed < 5000);
    try std.testing.expectEqual(before, try openFdCount());
    try std.testing.expect(one.file_fd == null and one.logs_fd == null);
    try std.testing.expectEqual(@as(usize, 0), try jsonlCount(&root));
    try std.testing.expectError(error.FileNotFound, root.dir.statFile(root.io, ".thin/sessions/.gitignore", .{}));
    try std.testing.expectEqual(@as(c_int, 0), filesystem.flock(logs, filesystem.LOCK.UN));
    try one.append("{\"writer\":1}");
    try two.append("{\"writer\":2}");
    try std.testing.expect(!std.mem.eql(u8, one.path(), two.path()));
    try expectContent(&root, one.path(), "{\"writer\":1}\n");
    try expectContent(&root, two.path(), "{\"writer\":2}\n");
    // Successful starts release the marker lock even while archive fds live.
    try std.testing.expectEqual(@as(c_int, 0), filesystem.flock(logs, filesystem.LOCK.EX | filesystem.LOCK.NB));
    try std.testing.expectEqual(@as(c_int, 0), filesystem.flock(logs, filesystem.LOCK.UN));
    one.deinit();
    two.deinit();
    try std.testing.expectEqual(before, try openFdCount());
}
test "log store marker partial creation fails closed without leaking or creating logs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var vtable = root.io.vtable.*;
    root.io.vtable = &vtable;
    vtable.fileWritePositional = partialWriteFailure;
    var store = Store.init(std.testing.allocator, &root);
    defer store.deinit();
    const before = try openFdCount();
    try std.testing.expectError(error.NoSpaceLeft, store.append("{}"));
    try std.testing.expectEqual(before, try openFdCount());
    try std.testing.expectEqual(@as(usize, 0), try jsonlCount(&root));
    vtable.fileWritePositional = std.testing.io.vtable.fileWritePositional;
    try std.testing.expectError(error.UnsafeLogIgnore, store.append("{}"));
    try expectContent(&root, ".thin/sessions/.gitignore", "{");
    try std.testing.expectEqual(before, try openFdCount());
}
test "log store rejects symlink regular file and FIFO at either directory component" {
    for (0..2) |level| {
        for (0..3) |kind| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var root = try testRoot(tmp.dir);
            defer root.deinit();
            const parent = if (level == 0) try filesystem.openDirectory(root.dir.handle, ".") else try Store.directory(root.dir.handle, ".thin");
            defer filesystem.closeFd(parent);
            const entry: [:0]const u8 = if (level == 0) ".thin" else "sessions";
            switch (kind) {
                0 => try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat(".", parent, entry)),
                1 => {
                    const fd = filesystem.openAt(parent, entry, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
                    try std.testing.expect(fd >= 0);
                    filesystem.closeFd(fd);
                },
                2 => try std.testing.expectEqual(@as(c_int, 0), mkfifoat(parent, entry, 0o600)),
                else => unreachable,
            }
            var store = Store.init(std.testing.allocator, &root);
            defer store.deinit();
            // 多次失败始终不拥有 fd；外部有界测试也验证 FIFO 不阻塞。
            const before = try openFdCount();
            for (0..8) |_| try std.testing.expectError(error.NotDir, store.start());
            try std.testing.expectEqual(before, try openFdCount());
            try std.testing.expect(store.file_fd == null and store.logs_fd == null);
            try std.testing.expectEqualStrings("", store.path());
        }
    }
}
test "log store rejects insecure existing logs without chmod and preserves thin permissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const thin = try Store.directory(root.dir.handle, ".thin");
    defer filesystem.closeFd(thin);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(thin, 0o755));
    const logs = try Store.directory(thin, "sessions");
    defer filesystem.closeFd(logs);
    var store = Store.init(std.testing.allocator, &root);
    defer store.deinit();
    for ([_]u32{ 0o710, 0o701, 0o777 }) |mode| {
        try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(logs, @intCast(mode)));
        const before = try openFdCount();
        for (0..8) |_| try std.testing.expectError(error.UnsafeLogDirectory, store.start());
        try std.testing.expectEqual(before, try openFdCount());
        try std.testing.expectEqual(mode, (try filesystem.fileFromFd(logs).stat(root.io)).permissions.toMode() & 0o777);
        try std.testing.expect(store.logs_fd == null and store.file_fd == null);
    }
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(logs, 0o700));
    try store.append("{}");
    try std.testing.expectEqual(@as(u32, 0o755), (try filesystem.fileFromFd(thin).stat(root.io)).permissions.toMode() & 0o777);
    store.deinit();
    // deinit 不接管或关闭 root；也可重复清理。
    try root.write("root-still-owned", "ok", false);
}
