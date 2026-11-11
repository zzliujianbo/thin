test "endpoint hello refuses a claimed PID different from kernel peer" {
    const a = testing.allocator;
    const fds = try unix.socketPair();
    const uid: u32 = @intCast(c.geteuid());
    var client_conn = unix.Connection.init(a, fds[0], .{ .pid = 31415, .uid = uid, .gid = 0 });
    defer client_conn.close();
    var responder = unix.Connection.init(a, fds[1], .{ .pid = 31415, .uid = uid, .gid = 0 });
    defer responder.close();
    var out = protocol.Out.init(a);
    defer out.deinit();
    try out.ok(1);
    try out.field("session", "0123456789abcdef0123456789abcdef");
    try out.field("owner", "foreground");
    try out.field("pid", @as(u32, 31416));
    try out.field("protocol", protocol.version);
    const bytes = try out.finish();
    defer a.free(bytes);
    const wait: unix.Wait = .{ .io = testing.io, .timeout_ms = 1000 };
    try responder.writeFrame(bytes, wait);
    try testing.expectError(error.PeerPidMismatch, EndpointClient.init(a, testing.io, uid).exchangeHello(&client_conn, 1000));
}
test "registry publishes schema v1 id strings and resolves across projects" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);

    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    {
        const st = try metadata.statFd(registry.index_fd);
        try testing.expectEqual(@as(u16, 0o700), @as(u16, @intCast(st.mode & 0o777)));
    }

    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const project = "/tmp/project-one";
    var record = try testRecord(&registry, id, project, "aaaaaaaaaaaaaaaa");
    defer freeRecord(a, &record);
    try registry.register(record);

    // On-disk schema: `id` is a 32-hex JSON string, not an array of numbers.
    const key = projectKey(project);
    var key_z_buf: [33]u8 = undefined;
    @memcpy(key_z_buf[0..32], &key);
    key_z_buf[32] = 0;
    const key_fd = try fs.openDirectory(registry.index_fd, key_z_buf[0..32 :0]);
    defer fs.closeFd(key_fd);
    var file_z_buf: [64]u8 = undefined;
    const file_z = try std.fmt.bufPrintSentinel(&file_z_buf, "{s}.json", .{id[0..]}, 0);
    const fd = fs.openAt(key_fd, file_z, .{ .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
    try testing.expect(fd >= 0);
    defer fs.closeFd(fd);
    var raw_buf: [4096]u8 = undefined;
    const n = try fs.fileFromFd(fd).readPositionalAll(testing.io, &raw_buf, 0);
    const raw = raw_buf[0..n];
    try testing.expect(std.mem.indexOf(u8, raw, "\"id\":\"0123456789abcdef0123456789abcdef\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"v\":1") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"owner\":\"foreground\"") != null);

    const resolved = (try registry.resolve(a, id, project)) orelse return error.TestUnexpectedResult;
    defer {
        var owned = resolved;
        freeRecord(a, &owned);
    }
    try testing.expectEqual(id, resolved.id);
    try testing.expectEqualStrings(project, resolved.project);
    try testing.expectEqual(cli.WorkerOwner.foreground, resolved.owner);

    // Same id in another project must be refused as ambiguous, not guessed.
    var other = try testRecord(&registry, id, "/tmp/project-two", "bbbbbbbbbbbbbbbb");
    defer freeRecord(a, &other);
    try registry.register(other);
    try testing.expectError(error.AmbiguousSession, registry.resolve(a, id, null));
    const scoped = (try registry.resolve(a, id, project)) orelse return error.TestUnexpectedResult;
    defer {
        var owned = scoped;
        freeRecord(a, &owned);
    }
    try testing.expectEqualStrings(project, scoped.project);

    const page = try registry.list(a, false, 0);
    defer freeRecords(a, page);
    try testing.expectEqual(@as(usize, 2), page.len);

    // A hostile page index (UI/RPC supplied) must clamp to an empty tail page
    // instead of overflowing `page * max_page`.
    const past_end = try registry.list(a, false, std.math.maxInt(usize));
    defer freeRecords(a, past_end);
    try testing.expectEqual(@as(usize, 0), past_end.len);

    try registry.unpublish(id, "/tmp/project-two");
    const remaining = (try registry.resolve(a, id, null)) orelse return error.TestUnexpectedResult;
    defer {
        var owned = remaining;
        freeRecord(a, &owned);
    }
    try testing.expectEqualStrings(project, remaining.project);
    try registry.unpublish(id, project);
    const after = try registry.resolve(a, id, null);
    if (after) |value| {
        var owned = value;
        freeRecord(a, &owned);
        return error.TestUnexpectedResult;
    }
}
test "registry distinguishes absent entries from invalid or unreadable records" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);
    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    const id: ids.Id = "1234567890abcdef1234567890abcdef".*;
    const good_id: ids.Id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*;
    const missing_id: ids.Id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".*;
    const project = "/tmp/strict-project";

    // Neither a missing project directory nor a missing entry is an error.
    try testing.expect((try registry.resolve(a, id, project)) == null);
    try testing.expect((try registry.resolve(a, id, null)) == null);
    // A project-key path that exists but is not a directory is not absent.
    const blocked_project = "/tmp/not-a-directory";
    const blocked_key = projectKey(blocked_project);
    var blocked_name_buf: [33]u8 = undefined;
    @memcpy(blocked_name_buf[0..32], &blocked_key);
    blocked_name_buf[32] = 0;
    const blocked_name = blocked_name_buf[0..32 :0];
    const index_dir: std.Io.Dir = .{ .handle = registry.index_fd };
    try index_dir.writeFile(testing.io, .{ .sub_path = blocked_name, .data = "" });
    try testing.expectError(error.NotDir, registry.resolve(a, id, blocked_project));
    try testing.expectEqual(@as(c_int, 0), c.unlinkat(registry.index_fd, blocked_name, 0));
    var good = try testRecord(&registry, good_id, project, "aaaaaaaaaaaaaaaa");
    defer freeRecord(a, &good);
    try registry.register(good);
    try testing.expect((try registry.resolve(a, missing_id, project)) == null);
    try testing.expect((try registry.resolve(a, missing_id, null)) == null);

    var record = try testRecord(&registry, id, project, "bbbbbbbbbbbbbbbb");
    defer freeRecord(a, &record);
    try registry.register(record);
    const key = projectKey(project);
    const key_fd = try registry.openKeyDir(key, false);
    defer fs.closeFd(key_fd);
    const key_dir: std.Io.Dir = .{ .handle = key_fd };
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buf, "{s}{s}", .{ id[0..], index_suffix }, 0);

    try key_dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
    try expectResolveError(&registry, id, project, error.ProtocolError);
    try key_dir.writeFile(testing.io, .{ .sub_path = name, .data = "{\"v\":" });
    try expectResolveError(&registry, id, project, error.ProtocolError);
    try key_dir.writeFile(testing.io, .{ .sub_path = name, .data = "{}" });
    try expectResolveError(&registry, id, project, error.ProtocolError);
    {
        const page = try registry.list(a, false, 0);
        defer freeRecords(a, page);
        try testing.expectEqual(@as(usize, 1), page.len);
        try testing.expectEqual(good_id, page[0].id);
    }

    // Exactly the limit is allowed, but a valid JSON prefix at the limit
    // must not hide any extra byte in the actual file.
    const encoded = try registry.encode(record, key);
    defer a.free(encoded);
    try testing.expect(encoded.len < max_index_bytes);
    var padded: [max_index_bytes + 1]u8 = undefined;
    @memset(&padded, ' ');
    @memcpy(padded[0..encoded.len], encoded);
    try key_dir.writeFile(testing.io, .{ .sub_path = name, .data = padded[0..max_index_bytes] });
    {
        var resolved = (try registry.resolve(a, id, project)) orelse return error.TestUnexpectedResult;
        defer freeRecord(a, &resolved);
        try testing.expectEqual(id, resolved.id);
    }
    padded[max_index_bytes] = '!';
    try key_dir.writeFile(testing.io, .{ .sub_path = name, .data = &padded });
    try expectResolveError(&registry, id, project, error.FileTooLarge);
    {
        const page = try registry.list(a, false, 0);
        defer freeRecords(a, page);
        try testing.expectEqual(@as(usize, 1), page.len);
        try testing.expectEqual(good_id, page[0].id);
    }

    try testing.expectEqual(@as(c_int, 0), c.unlinkat(key_fd, name, 0));
    try testing.expectEqual(@as(c_int, 0), c.mkdirat(key_fd, name, 0o700));
    try expectResolveError(&registry, id, project, error.NotRegularFile);
    try testing.expectEqual(@as(c_int, 0), c.unlinkat(key_fd, name, c.AT.REMOVEDIR));
    try testing.expectEqual(@as(c_int, 0), mkfifoat(key_fd, name, 0o600));
    try expectResolveError(&registry, id, project, error.NotRegularFile);
    try testing.expectEqual(@as(c_int, 0), c.unlinkat(key_fd, name, 0));
    try testing.expectEqual(@as(c_int, 0), c.symlinkat("missing-target", key_fd, name));
    try expectResolveError(&registry, id, project, error.SymlinkNotAllowed);

    // Open and metadata failures are not reclassified as a missing entry.
    try testing.expectError(error.FileSystemError, registry.readOneLocked(a, id, key, -1, project));
    try testing.expectError(error.FileSystemError, isRegularFd(-1));
}
test "registry read allocation failures propagate and release partial records" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);
    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    const id: ids.Id = "abcdefabcdefabcdefabcdefabcdefab".*;
    const project = "/tmp/allocation-one";
    var first = try testRecord(&registry, id, project, "cccccccccccccccc");
    defer freeRecord(a, &first);
    try registry.register(first);

    // Exercise JSON parsing and every separately owned record field, as well
    // as list's allocation-failure cleanup after a record was accumulated.
    try testing.checkAllAllocationFailures(a, resolveAllocationCase, .{ &registry, id, @as(?[]const u8, project) });
    try testing.checkAllAllocationFailures(a, resolveAllocationCase, .{ &registry, id, @as(?[]const u8, null) });
    try testing.checkAllAllocationFailures(a, listAllocationCase, .{&registry});

    // If a later project fails or is ambiguous, the first result must be freed.
    const other_project = "/tmp/allocation-two";
    var second = try testRecord(&registry, id, other_project, "dddddddddddddddd");
    defer freeRecord(a, &second);
    try registry.register(second);
    try testing.checkAllAllocationFailures(a, ambiguousAllocationCase, .{ &registry, id });

    const key_fd = try registry.openKeyDir(projectKey(other_project), false);
    defer fs.closeFd(key_fd);
    const key_dir: std.Io.Dir = .{ .handle = key_fd };
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buf, "{s}{s}", .{ id[0..], index_suffix }, 0);
    try key_dir.writeFile(testing.io, .{ .sub_path = name, .data = "{" });
    var counted = testing.FailingAllocator.init(a, .{});
    try testing.expectError(error.ProtocolError, registry.resolve(counted.allocator(), id, null));
    try testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}
test "registry rejects records outside the runtime endpoint shape" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);
    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    const id: ids.Id = "ffffffffffffffffffffffffffffffff".*;
    var record = try testRecord(&registry, id, "/tmp/project", "cccccccccccccccc");
    // Swap the endpoint for one outside `<runtime>/workers`.
    a.free(record.endpoint);
    record.endpoint = try a.dupe(u8, "/tmp/elsewhere.sock");
    defer freeRecord(a, &record);
    try testing.expectError(error.InvalidInput, registry.register(record));

    // Non-hex owner-instance is also refused before publication.
    a.free(record.endpoint);
    record.endpoint = try a.dupe(u8, "/tmp/elsewhere.sock");
    a.free(record.owner_instance);
    record.owner_instance = try a.dupe(u8, "NOTHEX");
    try testing.expectError(error.InvalidInput, registry.register(record));
}
test "registry keeps liveness independent of pid and index entry" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);
    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    // An index record whose endpoint does not exist must never appear live,
    // even though its pid belongs to a real process and the file exists.
    const id: ids.Id = "11111111111111111111111111111111".*;
    var record = try testRecord(&registry, id, "/tmp/project", "dddddddddddddddd");
    defer freeRecord(a, &record);
    try registry.register(record);
    try testing.expect(!registry.isLive(record, 20));
    try testing.expectEqual(Probe.State.dead, registry.probe(record, 20).state);

    // A mismatched instance/endpoint pair is refused without any connection.
    var forged = record;
    forged.owner_instance = "eeeeeeeeeeeeeeee";
    try testing.expect(!registry.isLive(forged, 20));
}
test "list reports probed state instead of the frozen index text" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);
    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    const id: ids.Id = "22222222222222222222222222222222".*;
    // The index says "running" for every entry; only the probe may correct it.
    var record = try testRecord(&registry, id, "/tmp/project", "ffffffffffffffff");
    defer freeRecord(a, &record);
    try testing.expectEqualStrings("running", record.state);
    try registry.register(record);

    // No endpoint exists, so both listings must report `unreachable`; a dead
    // record is never surfaced as running and is excluded from `--running`.
    {
        const page = try registry.list(a, false, 0);
        defer freeRecords(a, page);
        try testing.expectEqual(@as(usize, 1), page.len);
        try testing.expectEqualStrings("unreachable", page[0].state);
        try testing.expectEqualStrings("/tmp/project", page[0].project);
    }
    {
        const page = try registry.list(a, true, 0);
        defer freeRecords(a, page);
        try testing.expectEqual(@as(usize, 0), page.len);
    }

    // The display state was never written back to the index.
    try testing.expectEqualStrings("running", record.state);
    const resolved = (try registry.resolve(a, id, null)) orelse return error.TestUnexpectedResult;
    defer {
        var owned = resolved;
        freeRecord(a, &owned);
    }
    try testing.expectEqualStrings("running", resolved.state);
}
test "probe state labels and running filter are explicit" {
    // Idle and dead are never presented as work in flight; a live owner whose
    // snapshot timed out stays explicitly unknown.
    try testing.expectEqualStrings("running", stateLabel(.running));
    try testing.expectEqualStrings("waiting_approval", stateLabel(.waiting_approval));
    try testing.expectEqualStrings("idle", stateLabel(.idle));
    try testing.expectEqualStrings("unknown", stateLabel(.unknown));
    try testing.expectEqualStrings("unreachable", stateLabel(.dead));

    try testing.expect(probeVisible(.running, true));
    try testing.expect(probeVisible(.waiting_approval, true));
    try testing.expect(probeVisible(.unknown, true));
    try testing.expect(!probeVisible(.idle, true));
    try testing.expect(!probeVisible(.dead, true));

    inline for (std.meta.tags(Probe.State)) |state| try testing.expect(probeVisible(state, false));
}
test "probe state reads the pending approval id the wire actually publishes" {
    const a = testing.allocator;
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var out = protocol.Out.init(a);
    defer out.deinit();
    try out.ok(2);
    try protocol.encodeSnapshot(&out, .{
        .session = id,
        .project = "/tmp/project",
        .owner = .daemon,
        .busy = true,
        .pending_permission = 7,
    });
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    defer doc.deinit();
    const object = doc.value.object.get("snapshot").?.object;

    // The approval id travels as `pending`; reading any other name reported a
    // permanently idle session even while a command waited for approval.
    try testing.expect(object.get("pending_permission") == null);
    try testing.expect(pendingApproval(object.get("pending")));
    try testing.expectEqual(Probe.State.waiting_approval, probeState(true, pendingApproval(object.get("pending"))));

    // A busy task without an approval id is running, not waiting.
    try testing.expect(!pendingApproval(.null));
    try testing.expect(!pendingApproval(null));
    try testing.expectEqual(Probe.State.running, probeState(true, false));
    try testing.expectEqual(Probe.State.idle, probeState(false, false));
}
test "probe reads the nested snapshot object a real reply carries" {
    const a = testing.allocator;
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;

    const Case = struct { busy: bool, pending: ?u64, state: Probe.State };
    const cases = [_]Case{
        .{ .busy = true, .pending = null, .state = .running },
        .{ .busy = false, .pending = null, .state = .idle },
        .{ .busy = false, .pending = 7, .state = .waiting_approval },
    };
    for (cases) |case| {
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(2);
        try protocol.encodeSnapshot(&out, .{
            .session = id,
            .project = "/tmp/project",
            .owner = .daemon,
            .busy = case.busy,
            .pending_permission = case.pending,
            .attached = true,
        });
        const bytes = try out.finish();
        defer a.free(bytes);

        // The root object never carries a probe field; only `snapshot` does.
        var frame = try parseTestFrame(a, bytes, 2);
        defer frame.deinit();
        try testing.expect(frame.root.get("busy") == null);
        try testing.expect(frame.root.get("snapshot") != null);

        const probe = try probeFromReply(a, bytes);
        try testing.expect(probe.live);
        try testing.expectEqual(@as(u32, 4242), probe.pid);
        try testing.expectEqual(case.busy, probe.busy);
        try testing.expectEqual(case.pending != null, probe.pending_permission);
        try testing.expect(probe.attached);
        try testing.expectEqual(case.state, probe.state);
        // This is what `/ls --running` renders: only real work stays listed.
        try testing.expectEqual(case.state != .idle, probeVisible(probe.state, true));
    }
}
test "probe stays unknown when the reply has no usable snapshot" {
    const a = testing.allocator;
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;

    // 1. `ok` reply with no nested `snapshot` object at all.
    var bare = protocol.Out.init(a);
    defer bare.deinit();
    try bare.ok(2);
    const bare_bytes = try bare.finish();
    defer a.free(bare_bytes);
    const bare_probe = try probeFromReply(a, bare_bytes);
    try testing.expect(bare_probe.live);
    try testing.expectEqual(Probe.State.unknown, bare_probe.state);
    try testing.expect(!bare_probe.busy);
    try testing.expect(!bare_probe.pending_permission);
    try testing.expect(!bare_probe.attached);

    // 2. `snapshot` present but not an object.
    var wrong_type = protocol.Out.init(a);
    defer wrong_type.deinit();
    try wrong_type.ok(2);
    try wrong_type.field("snapshot", @as(?u8, null));
    const wrong_type_bytes = try wrong_type.finish();
    defer a.free(wrong_type_bytes);
    try testing.expectEqual(Probe.State.unknown, (try probeFromReply(a, wrong_type_bytes)).state);

    // 3. Nested object whose `busy` flag is not a bool: never default to idle.
    var bad_busy = protocol.Out.init(a);
    defer bad_busy.deinit();
    try bad_busy.ok(2);
    try bad_busy.beginObject("snapshot");
    try bad_busy.field("busy", @as(?u8, null));
    try bad_busy.field("pending", @as(?u64, null));
    try bad_busy.field("attached", true);
    try bad_busy.endObject();
    const bad_busy_bytes = try bad_busy.finish();
    defer a.free(bad_busy_bytes);
    const bad_busy_probe = try probeFromReply(a, bad_busy_bytes);
    try testing.expectEqual(Probe.State.unknown, bad_busy_probe.state);
    try testing.expect(!bad_busy_probe.busy);

    // 4. A real encoded snapshot with `busy` stripped keeps `unknown` too.
    var stripped = protocol.Out.init(a);
    defer stripped.deinit();
    try stripped.ok(2);
    try stripped.beginObject("snapshot");
    try stripped.field("session", id[0..]);
    try stripped.field("attached", true);
    try stripped.endObject();
    const stripped_bytes = try stripped.finish();
    defer a.free(stripped_bytes);
    try testing.expectEqual(Probe.State.unknown, (try probeFromReply(a, stripped_bytes)).state);
}
