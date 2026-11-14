test "memory empty snapshot has no side effects and last-writer-wins across Stores" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    var one = Store.init(&root);
    var two = Store.init(&root);
    const empty = try one.snapshot(a);
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    try std.testing.expectError(error.FileNotFound, one.read(a, "missing"));

    const first = try one.create(a, "topic", "first");
    defer freeEntry(a, first);
    try std.testing.expectError(error.PathAlreadyExists, two.create(a, "topic", "lost"));
    const second = try two.replace(a, "topic", "second");
    defer freeEntry(a, second);
    const third = try one.replace(a, "topic", "third");
    defer freeEntry(a, third);

    const latest = try one.read(a, "topic");
    defer freeEntry(a, latest);
    try std.testing.expectEqualStrings("third", latest.content);
    try one.remove("topic");
    try std.testing.expectError(error.FileNotFound, two.read(a, "topic"));
    try std.testing.expectError(error.InvalidTopic, one.read(a, "../x"));

    const stat = try root.dir.statFile(io, ".thin/memory", .{});
    try std.testing.expectEqual(@as(u32, 0o700), stat.permissions.toMode() & 0o777);
}
test "memory real concurrent Stores and cross-process flock exclusion" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{ .concurrent_limit = .limited(4) });
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    var one = Store.init(&root);
    var two = Store.init(&root);
    const initial = try one.create(a, "topic", "initial");
    defer freeEntry(a, initial);

    var first = try std.Io.concurrent(io, competingWrite, .{ &one, "first" });
    defer _ = first.cancel(io) catch {};
    var second = try std.Io.concurrent(io, competingWrite, .{ &two, "second" });
    defer _ = second.cancel(io) catch {};
    const first_won = try first.await(io);
    const second_won = try second.await(io);
    try std.testing.expect(first_won and second_won);
    const latest = try one.read(a, "topic");
    defer freeEntry(a, latest);
    try std.testing.expect(std.mem.eql(u8, latest.content, "first") or std.mem.eql(u8, latest.content, "second"));

    const held = try one.lock();
    defer fs.closeFd(held);

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Only async-signal-safe libc operations after fork in the threaded process.
        // 中文：多线程进程 fork 后，子进程只能调用 async-signal-safe 的操作。
        fs.closeFd(held);
        // 子进程独立 open 根目录，得到新的 open description，flock 应返回 EWOULDBLOCK，证明互斥生效。
        const independent = fs.openAt(root.dir.handle, ".", .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (independent < 0) _exit(2);
        const rc = fs.flock(independent, fs.LOCK.EX | fs.LOCK.NB);
        const excluded = rc == -1 and fs.errno() == .AGAIN;
        fs.closeFd(independent);
        _exit(if (excluded) 0 else 3);
    }

    var status: c_int = 0;
    var waited: c_int = undefined;
    while (true) {
        waited = waitpid(pid, &status, 0);
        if (waited < 0 and fs.errno() == .INTR) continue;
        break;
    }
    try std.testing.expectEqual(pid, waited);
    try std.testing.expectEqual(@as(c_int, 0), status);
}
test "memory refuses symlink directories and shards" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, backend.io(), tmp.dir);
    defer root.deinit();
    var store = Store.init(&root);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("/", root.dir.handle, ".thin"));
    try std.testing.expectError(error.NotDir, store.snapshot(a));
    try std.testing.expectError(error.NotDir, store.create(a, "core", "text"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(root.dir.handle, ".thin", 0));

    const c = try store.create(a, "core", "core");
    defer freeEntry(a, c);

    var mem = try store.directory(false);
    defer mem.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("/not-read", mem.dir.handle, "escape.md"));
    try std.testing.expectError(error.SymlinkNotAllowed, store.read(a, "escape"));
    try std.testing.expectError(error.SymlinkNotAllowed, store.snapshot(a));
}
test "index reads bounded titles, not full shard bodies" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    var store = Store.init(&root);
    const initial = try store.create(a, "topic", "Title\nbody");
    defer freeEntry(a, initial);

    // A separately edited body is checked by read, not secretly loaded into
    // startup context merely to obtain its first line.
    const binary_body: [20000]u8 = @splat(0);
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/memory/topic.md", .data = "Title\n" ++ binary_body });

    const snapshot = try store.snapshot(a);
    defer a.free(snapshot);
    try std.testing.expectEqualStrings("topic.md: Title\n", snapshot);
    try std.testing.expectError(error.BinaryFile, store.read(a, "topic"));

    try std.testing.expectError(error.InvalidTopic, validTopic("-topic"));
    try std.testing.expectError(error.InvalidTopic, validTopic("a_b"));

    const long_topic: [65]u8 = @splat('a');
    try std.testing.expectError(error.InvalidTopic, validTopic(&long_topic));
}
test "memory sorted listing independent limits and project isolation" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var other = std.testing.tmpDir(.{});
    defer other.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    var root2 = try testRoot(a, io, other.dir);
    defer root2.deinit();
    var store = Store.init(&root);
    var isolated = Store.init(&root2);

    const c = try store.create(a, "core", "CORE");
    defer freeEntry(a, c);
    const z = try store.create(a, "z", "zed\nrest");
    defer freeEntry(a, z);
    const aa = try store.create(a, "a", "alpha");
    defer freeEntry(a, aa);

    const snap = try store.snapshot(a);
    defer a.free(snap);
    try std.testing.expectEqualStrings("CORE\n\na.md: alpha\nz.md: zed\n", snap);
    try std.testing.expectError(error.FileNotFound, isolated.read(a, "core"));

    const extra = try store.create(a, "extra", "123456789");
    defer freeEntry(a, extra);
    const extra_read = try store.read(a, "extra");
    defer freeEntry(a, extra_read);
    try std.testing.expectEqualStrings("123456789", extra_read.content);
    const with_extra = try store.snapshot(a);
    defer a.free(with_extra);
    try std.testing.expectEqualStrings("CORE\n\na.md: alpha\nextra.md: 123456789\nz.md: zed\n", with_extra);

    const first_page = try store.listPage(a, 0, 2);
    defer a.free(first_page.text);
    try std.testing.expectEqual(@as(usize, 3), first_page.total);
    try std.testing.expectEqual(@as(usize, 2), first_page.count);
    try std.testing.expectEqualStrings("a.md: alpha\nextra.md: 123456789\n", first_page.text);
    const last_page = try store.listPage(a, 2, 2);
    defer a.free(last_page.text);
    try std.testing.expectEqual(@as(usize, 1), last_page.count);
    try std.testing.expectEqualStrings("z.md: zed\n", last_page.text);
    const empty_page = try store.listPage(a, 3, 2);
    defer a.free(empty_page.text);
    try std.testing.expectEqual(@as(usize, 0), empty_page.count);
    try std.testing.expectEqualStrings("", empty_page.text);

    const stat = try root.dir.statFile(io, ".thin/memory/core.md", .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);

    const large = try a.alloc(u8, 40_000);
    defer a.free(large);
    @memset(large, 'x');
    const updated = try store.replace(a, "core", large);
    defer freeEntry(a, updated);
    const shard = try store.create(a, "shard", large);
    defer freeEntry(a, shard);
    const roundtrip = try store.read(a, "shard");
    defer freeEntry(a, roundtrip);
    try std.testing.expectEqualStrings(large, roundtrip.content);
    const core_read = try store.read(a, "core");
    defer freeEntry(a, core_read);
    try std.testing.expectEqualStrings(large, core_read.content);
}
test "memory listing caps oversized titles on a UTF-8 boundary" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    var store = Store.init(&root);
    const prefix: [max_title_bytes]u8 = @splat('a');
    const content = try std.fmt.allocPrint(a, "{s}中\nbody", .{prefix[0 .. max_title_bytes - 1]});
    defer a.free(content);
    const entry = try store.create(a, "long-title", content);
    defer freeEntry(a, entry);

    const page = try store.listPage(a, 0, 1);
    defer a.free(page.text);
    const header = "long-title.md: ";
    try std.testing.expect(std.mem.startsWith(u8, page.text, header));
    const title = page.text[header.len .. page.text.len - 1];
    try std.testing.expectEqual(max_title_bytes - 1, title.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(title));
}
