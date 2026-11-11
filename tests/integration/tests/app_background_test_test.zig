test "App publishes one background owner and keeps it across settings and connection installs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var root = try fs.Root.open(a, io, path);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path);
    const app = try build(a, io, &env, &root,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://127.0.0.1:1/v1","api_key":"fake-app-key","models":{"main":{"context_tokens":32768,"protocol":"chat"},"alternate":{"context_tokens":32768,"protocol":"chat"}}}}}}
    );
    defer app.deinit();
    try expectBackgroundSurface(app);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cancel = p.Cancellation{};

    // An already-running job must survive both installs with the same identity.
    const started = try app.executor.execute(allocator, .{ .bash = .{
        .command = "printf 'BG-KEEP-LOG\n'; exec sleep 30",
        .background = true,
    } }, &cancel);
    try std.testing.expect(!started.is_error);
    const id = try receiptId(allocator, started.text);
    const before = try serviceSnapshot(allocator, (try app.executor.execute(allocator, .{ .background = .{
        .action = .status,
        .id = id,
    } }, &cancel)).text);
    try std.testing.expectEqualStrings(id, before.id);
    try std.testing.expectEqualStrings("running", before.state);
    try std.testing.expect(before.pid > 0);

    // Idle settings replacement republishes the service value, never the owner.
    var declaration = app.config.value;
    declaration.limits.request_timeout_ms += 1;
    var replacement = try app.prepareSettings(declaration, &env);
    defer replacement.deinit();
    app.installSettings(&replacement);
    try expectBackgroundSurface(app);
    const after_settings = try serviceSnapshot(allocator, (try app.executor.execute(allocator, .{ .background = .{
        .action = .status,
        .id = id,
    } }, &cancel)).text);
    try std.testing.expectEqualStrings(before.id, after_settings.id);
    try std.testing.expectEqual(before.pid, after_settings.pid);
    try std.testing.expectEqualStrings("running", after_settings.state);

    // Connection replacement must not reset the registry either.
    var candidate = try cfg.clone(a, app.config.value);
    candidate.value.model.name = "alternate";
    const connection = try app.prepareConnection(candidate, &env);
    app.installConnection(connection);
    try expectBackgroundSurface(app);
    try std.testing.expectEqualStrings("alternate", app.config.value.model.name);
    const after_connection = try serviceSnapshot(allocator, (try app.executor.execute(allocator, .{ .background = .{
        .action = .status,
        .id = id,
    } }, &cancel)).text);
    try std.testing.expectEqualStrings(before.id, after_connection.id);
    try std.testing.expectEqual(before.pid, after_connection.pid);
    try std.testing.expectEqualStrings("running", after_connection.state);

    // Normal stop, still before App.deinit releases root/environment.
    const stopped = try app.executor.execute(allocator, .{ .background = .{ .action = .stop, .id = id } }, &cancel);
    try std.testing.expect(!stopped.is_error);
    try std.testing.expect(!stopped.cleanup_failed);
}
test "App executor starts, queries and stops a real owned background command" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var root = try fs.Root.open(a, io, path);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path);
    const app = try build(a, io, &env, &root,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://127.0.0.1:1/v1","api_key":"fake-app-key","models":{"main":{"context_tokens":32768,"protocol":"chat"}}}}}}
    );
    // deinit cancels and joins anything still running before env/root release.
    defer app.deinit();
    try expectBackgroundSurface(app);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cancel = p.Cancellation{};

    // Round 1: a real owned process starts and hands off in this App instance.
    const started = try app.executor.execute(allocator, .{ .bash = .{
        .command = "printf 'BG-UNIT-LOG\\n'; exec sleep 30",
        .background = true,
    } }, &cancel);
    try std.testing.expect(!started.is_error);
    try std.testing.expect(!started.cleanup_failed);
    const id = try receiptId(allocator, started.text);

    // Round 2: the same instance can query and stop exactly that service.
    const status = try app.executor.execute(allocator, .{ .background = .{ .action = .status, .id = id } }, &cancel);
    try std.testing.expect(!status.is_error);
    const logs = try app.executor.execute(allocator, .{ .background = .{ .action = .logs, .id = id } }, &cancel);
    try std.testing.expect(!logs.is_error);
    const stopped = try app.executor.execute(allocator, .{ .background = .{ .action = .stop, .id = id } }, &cancel);
    try std.testing.expect(!stopped.is_error);
    try std.testing.expect(!stopped.cleanup_failed);
    // Stopping one service is not the current Q&A being canceled.
    try std.testing.expect(!stopped.canceled);

    // A forged child Tools carries no registry: start and management stay closed.
    var child = app.executor;
    child.background = null;
    try std.testing.expectError(error.BackgroundDisabled, child.execute(allocator, .{ .bash = .{
        .command = "sleep 30",
        .background = true,
    } }, &cancel));
    try std.testing.expectError(error.BackgroundDisabled, child.execute(allocator, .{ .background = .{
        .action = .list,
    } }, &cancel));
}
