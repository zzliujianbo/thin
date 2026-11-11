test "supervisor keeps one private setup host per socket without registering a session" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..n];
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "runtime", .fromMode(0o700));
    try tmp.dir.createDir(io, "project", .default_dir);
    try tmp.dir.createDir(io, "elsewhere", .default_dir);

    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    const runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{base});
    defer a.free(runtime);
    const project = try std.fmt.allocPrint(a, "{s}/project", .{base});
    defer a.free(project);
    const elsewhere = try std.fmt.allocPrint(a, "{s}/elsewhere", .{base});
    defer a.free(elsewhere);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("XDG_RUNTIME_DIR", runtime);

    var reg = try registry.Registry.init(a, io, &env);
    defer reg.deinit();
    var workers = try spawn.Workers.init(a, io, &env);
    defer workers.deinit();

    var lock = try unix.Lock.acquire(a, reg.runtimeDirectory(), daemon_lock);
    defer lock.release();
    var listener = try unix.Listener.bind(a, reg.runtimeDirectory(), daemon_socket, .{ .lock = &lock });
    defer listener.deinit();

    var supervisor = Supervisor{
        .allocator = a,
        .io = io,
        .environ = &env,
        .registry = &reg,
        .workers = &workers,
        .listener = &listener,
        .auto_refresh_models = false,
    };
    defer supervisor.deinit();

    const me: u32 = @intCast(c.geteuid());
    var client = try unix.connect(a, listener.socketPath(), me, testWait());
    defer client.close();

    supervisor.acceptTick();
    try std.testing.expect(supervisor.slots[0] != null);
    // Nothing is built until a setup request arrives.
    try std.testing.expect(supervisor.slots[0].?.setup == null);

    // 1. `settings` creates the slot's private host, with no worker/registry row.
    {
        const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{project});
        defer a.free(body);
        const frame = try setupOpFrame(a, 1, "settings", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"session\":\"") != null);
    }
    const setup_host = supervisor.slots[0].?.setup.?.host;
    try std.testing.expectEqualStrings(project, supervisor.slots[0].?.setup.?.project);
    try std.testing.expect(supervisor.slots[0].?.setup.?.epoch != 0);
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);
    {
        const records = try reg.list(a, false, 0);
        defer registry.freeRecords(a, records);
        try std.testing.expectEqual(@as(usize, 0), records.len);
    }

    // 2. `login` with a fake key mutates the same host; no registration and no
    //    automatic metadata refresh (the setup host never auto-refreshes).
    {
        const body = try std.fmt.allocPrint(
            a,
            ",\"key\":\"fake-owner-key\",\"provider\":\"deepseek\",\"project\":\"{s}\"",
            .{project},
        );
        defer a.free(body);
        const frame = try setupOpFrame(a, 2, "login", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    // Cross-request survival: the very same host answered login.
    try std.testing.expect(supervisor.slots[0].?.setup.?.host == setup_host);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);

    // 3. `poll_metadata` is served by the same host and starts no worker/network.
    {
        const body = try std.fmt.allocPrint(a, ",\"wait\":true,\"project\":\"{s}\"", .{project});
        defer a.free(body);
        const frame = try setupOpFrame(a, 3, "poll_metadata", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    try std.testing.expect(supervisor.slots[0].?.setup.?.host == setup_host);
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);

    // 4. Setup never becomes a task endpoint: `submit` stays unsupported.
    {
        const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\",\"text\":\"x\",\"epoch\":9", .{project});
        defer a.free(body);
        const frame = try setupOpFrame(a, 4, "submit", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "unsupported") != null);
    }
    try std.testing.expect(supervisor.slots[0].?.setup.?.host == setup_host);

    // 5. A real project switch rebuilds the setup context from scratch.
    {
        const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 5, "settings", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    try std.testing.expectEqualStrings(elsewhere, supervisor.slots[0].?.setup.?.project);
    try std.testing.expect(supervisor.slots[0].?.setup.?.host != setup_host);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);

    // 6. Proxy allowlist mutations route to the private setup host, not to a
    //    worker. The owner refuses without a configured proxy endpoint, but the
    //    control router no longer answers `unsupported`.
    {
        const body = try std.fmt.allocPrint(a, ",\"name\":\"\",\"enabled\":true,\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 6, "proxy_model", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":false") != null);
        // The host already validates the id, so routing is proven without
        // depending on the owner's proxy-configuration refusal code.
        try std.testing.expect(std.mem.indexOf(u8, reply, "invalid_input") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "unsupported") == null);
    }
    {
        const body = try std.fmt.allocPrint(a, ",\"name\":\"p/m\",\"enabled\":true,\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 7, "proxy_model", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        // Any host answer proves routing; the exact refusal stays the owner's
        // proxy-configuration decision, not this test's assumption.
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "unsupported") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);
    // 7. The public settings projection carries the proxy fields.
    {
        const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 8, "settings", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"proxy_configured\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"proxy_address\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"proxy_port\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"proxy_models\":[]") != null);
    }

    // 8. Proxy endpoint edits route to the private setup host. An invalid
    //    endpoint is rejected by the host itself, so routing is proven without
    //    depending on whether this owner also wired its save callback.
    {
        const body = try std.fmt.allocPrint(a, ",\"value\":\"user@host:8080\",\"epoch\":1,\"project\":\"{s}\"", .{elsewhere});
        defer a.free(body);
        const frame = try setupOpFrame(a, 9, "proxy_address", body);
        defer a.free(frame);
        const reply = try controlRoundTrip(&supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "invalid_input") != null);
        try std.testing.expect(std.mem.indexOf(u8, reply, "unsupported") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), workers.list.items.len);

    // 9. EOF destroys the slot and its setup host; nothing was ever listed.
    client.close();
    supervisor.serveTick();
    try std.testing.expect(supervisor.slots[0] == null);
    try std.testing.expectEqual(@as(usize, 0), supervisor.created.items.len);
    {
        const records = try reg.list(a, false, 0);
        defer registry.freeRecords(a, records);
        try std.testing.expectEqual(@as(usize, 0), records.len);
    }
}
test "setup host is private per connection and rejects a client-supplied epoch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    var first = try rig.connect(a);
    defer first.close();
    var second = try rig.connect(a);
    defer second.close();
    rig.supervisor.acceptTick();
    rig.supervisor.acceptTick();
    try std.testing.expect(rig.supervisor.slots[0] != null and rig.supervisor.slots[1] != null);

    const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{rig.project});
    defer a.free(body);
    const one = try setupOpFrame(a, 1, "settings", body);
    defer a.free(one);
    const reply_one = try controlRoundTrip(&rig.supervisor, &first, one);
    defer a.free(reply_one);
    try std.testing.expect(std.mem.indexOf(u8, reply_one, "\"ok\":true") != null);

    const two = try setupOpFrame(a, 2, "settings", body);
    defer a.free(two);
    const reply_two = try controlRoundTrip(&rig.supervisor, &second, two);
    defer a.free(reply_two);
    try std.testing.expect(std.mem.indexOf(u8, reply_two, "\"ok\":true") != null);

    const slot_a = rig.supervisor.slots[0].?.setup.?;
    const slot_b = rig.supervisor.slots[1].?.setup.?;
    try std.testing.expect(slot_a.host != slot_b.host);
    try std.testing.expect(slot_a.epoch != 0 and slot_b.epoch != 0);

    // A client-supplied epoch never becomes the setup host's control epoch.
    const spoof = try std.fmt.allocPrint(
        a,
        ",\"key\":\"fake-owner-key\",\"provider\":\"deepseek\",\"epoch\":999,\"project\":\"{s}\"",
        .{rig.project},
    );
    defer a.free(spoof);
    const login = try setupOpFrame(a, 3, "login", spoof);
    defer a.free(login);
    const reply_login = try controlRoundTrip(&rig.supervisor, &first, login);
    defer a.free(reply_login);
    try std.testing.expect(std.mem.indexOf(u8, reply_login, "\"ok\":true") != null);
    try std.testing.expect(rig.supervisor.slots[0].?.setup.?.host == slot_a.host);
    try std.testing.expect(rig.supervisor.slots[1].?.setup == null or rig.supervisor.slots[1].?.setup.?.host == slot_b.host);

    try std.testing.expectEqual(@as(usize, 0), rig.supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.workers.list.items.len);
}
test "setup host honors first user input directory then explicit project hint" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    var client = try rig.connect(a);
    defer client.close();
    rig.supervisor.acceptTick();
    try std.testing.expect(rig.supervisor.slots[0] != null);

    // No hint and no accepted input yet: the owner's HOME is the fallback.
    {
        const frame = try setupOpFrame(a, 1, "settings", "");
        defer a.free(frame);
        const reply = try controlRoundTrip(&rig.supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    try std.testing.expectEqualStrings(rig.home, rig.supervisor.slots[0].?.setup.?.project);

    // Simulate the first accepted user input (a created session's directory)
    // without spawning a worker.
    rig.supervisor.first_project = try a.dupe(u8, rig.project);

    {
        const frame = try setupOpFrame(a, 2, "settings", "");
        defer a.free(frame);
        const reply = try controlRoundTrip(&rig.supervisor, &client, frame);
        defer a.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    }
    try std.testing.expectEqualStrings(rig.project, rig.supervisor.slots[0].?.setup.?.project);

    const body = try std.fmt.allocPrint(a, ",\"project\":\"{s}\"", .{rig.elsewhere});
    defer a.free(body);
    const frame = try setupOpFrame(a, 2, "settings", body);
    defer a.free(frame);
    const reply = try controlRoundTrip(&rig.supervisor, &client, frame);
    defer a.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
    try std.testing.expectEqualStrings(rig.elsewhere, rig.supervisor.slots[0].?.setup.?.project);
    // The remembered first input directory is not overwritten by a hint.
    try std.testing.expectEqualStrings(rig.project, rig.supervisor.first_project.?);
}
test "closed worker keeps a resumable locator and drops an empty session" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    const keep_id = try ids.generate(io);
    const drop_id = try ids.generate(io);
    const diagnostics_id = try ids.generate(io);

    const keep_ep = try publishTestRecord(a, &rig.reg, keep_id, rig.project, "aaaaaaaaaaaaaaa1");
    defer a.free(keep_ep);
    const drop_ep = try publishTestRecord(a, &rig.reg, drop_id, rig.project, "aaaaaaaaaaaaaaa2");
    defer a.free(drop_ep);
    const diagnostics_ep = try publishTestRecord(a, &rig.reg, diagnostics_id, rig.project, "aaaaaaaaaaaaaaa3");
    defer a.free(diagnostics_ep);

    try rig.supervisor.created.append(a, try ownedCreated(a, rig.project, keep_id, keep_ep));
    try rig.supervisor.created.append(a, try ownedCreated(a, rig.project, drop_id, drop_ep));
    try rig.supervisor.created.append(a, try ownedCreated(a, rig.project, diagnostics_id, diagnostics_ep));

    // One clean join with a complete checkpoint, one empty session, and one
    // session that only ever wrote a diagnostic log.
    try writeTestCheckpoint(a, io, rig.project, keep_id);
    try writeTestDiagnostic(a, io, rig.project, diagnostics_id);

    try rig.supervisor.shutdownOwned();

    // The checkpointed session keeps its locator metadata for resume and list.
    var kept = (try rig.reg.resolve(a, keep_id, rig.project)) orelse return error.TestExpectedRecord;
    defer registry.freeRecord(a, &kept);
    try std.testing.expectEqualStrings(keep_ep, kept.endpoint);
    try std.testing.expectEqualStrings(rig.project, kept.project);
    // A session with nothing to resume loses exactly its own record.
    try std.testing.expect((try rig.reg.resolve(a, drop_id, rig.project)) == null);
    // Diagnostics are never treated as history.
    try std.testing.expect((try rig.reg.resolve(a, diagnostics_id, rig.project)) == null);
    try std.testing.expectEqual(@as(usize, 0), rig.supervisor.created.items.len);
}
test "a retired worker never deletes a locator a later owner republished" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    const id = try ids.generate(io);
    const old_ep = try publishTestRecord(a, &rig.reg, id, rig.project, "bbbbbbbbbbbbbbb1");
    defer a.free(old_ep);
    // A later owner (a foreground resume of the same id) republished the entry.
    const new_ep = try publishTestRecord(a, &rig.reg, id, rig.project, "bbbbbbbbbbbbbbb2");
    defer a.free(new_ep);

    // The older worker exits with no checkpoint; its retirement must leave the
    // newer record untouched instead of unpublishing by id alone.
    rig.supervisor.retireWorker(id, rig.project, old_ep);

    var kept = (try rig.reg.resolve(a, id, rig.project)) orelse return error.TestExpectedRecord;
    defer registry.freeRecord(a, &kept);
    try std.testing.expectEqualStrings(new_ep, kept.endpoint);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbb2", kept.owner_instance);
}
test "an owner lifecycle stop is never probed and then killed without force" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const rig = try TestRig.create(a, io);
    defer rig.deinit(a);

    const id = try ids.generate(io);
    const endpoint = try publishTestRecord(a, &rig.reg, id, rig.project, "ccccccccccccccc1");
    defer a.free(endpoint);
    try rig.supervisor.created.append(a, try ownedCreated(a, rig.project, id, endpoint));

    var client = try rig.connect(a);
    defer client.close();
    rig.supervisor.acceptTick();

    const frame = try std.fmt.allocPrint(
        a,
        "{{\"v\":{d},\"id\":1,\"op\":\"close\",\"session\":\"{s}\"}}",
        .{ protocol.version, id },
    );
    defer a.free(frame);
    const reply = try controlRoundTrip(&rig.supervisor, &client, frame);
    defer a.free(reply);
    // A probe-then-stop could kill a task submitted between the probe and the
    // kill, so `force` is required instead of probing at all.
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"accepted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"busy\"") != null);
    try std.testing.expectEqual(@as(usize, 1), rig.supervisor.created.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.workers.list.items.len);
    var kept = (try rig.reg.resolve(a, id, rig.project)) orelse return error.TestExpectedRecord;
    defer registry.freeRecord(a, &kept);
    try std.testing.expectEqualStrings(endpoint, kept.endpoint);
}
