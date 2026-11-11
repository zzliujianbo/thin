test "source refresh commits rotation before observing cancellation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const manager = try Manager.init(a, std.testing.io, home, &env);
    defer manager.deinit();
    var initial = try manager.store.loadOrInitialize();
    defer cfg.release(&initial);
    const names = try merge(a, &initial.value, "codex", .{ .access_token = "old-access", .refresh_token = "old-refresh", .expires_at_ms = 1 }, true);
    defer a.free(names);
    try manager.store.save(initial.value);
    var cancel: p.Cancellation = .{};
    var fake: FakeWire = .{ .cancel_on_refresh = &cancel };
    manager.wire = fake.wire();
    try std.testing.expectError(error.Cancelled, manager.source().acquire(a, "codex", &cancel, 5000));
    var latest = try manager.store.loadExisting();
    defer cfg.release(&latest);
    const updated = try credential(latest.value, "codex");
    try std.testing.expectEqualStrings("new-access", updated.access_token);
    try std.testing.expectEqualStrings("new-refresh", updated.refresh_token);
    try std.testing.expect(!updated.refresh_pending);
    try std.testing.expectEqual(@as(usize, 1), fake.refresh_count);
}
test "refresh intent prevents replay across reopen and stale settings save" {
    const a = std.testing.allocator;
    for (0..3) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buf: [4096]u8 = undefined;
        const home = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        const manager = try Manager.init(a, std.testing.io, home, &env);
        var initial = try manager.store.loadOrInitialize();
        defer cfg.release(&initial);
        initial.value.registry.?.reasoning_effort = "high";
        const names = try merge(a, &initial.value, "codex", .{ .access_token = "old-access", .refresh_token = "old-refresh", .expires_at_ms = 1 }, true);
        defer a.free(names);
        try manager.store.save(initial.value);
        var stale_store = try store_mod.Store.open(a, std.testing.io, home);
        defer stale_store.deinit();
        var stale = try stale_store.loadExisting();
        defer cfg.release(&stale);
        var fake: FakeWire = .{ .fail_refresh = mode == 1 };
        manager.wire = fake.wire();
        manager.before_refresh_save = if (mode == 0) failIntentSave else if (mode == 2) failRotationSave else null;
        try std.testing.expectError(if (mode == 1) error.OAuthRefreshFailed else error.OAuthCommitFailed, manager.source().acquire(a, "codex", null, 5000));
        try std.testing.expectEqual(@as(usize, if (mode == 0) 0 else 1), fake.refresh_count);
        if (mode != 0) try std.testing.expectError(error.AuthVersionConflict, stale_store.save(stale.value));
        manager.deinit();
        const reopened = try Manager.init(a, std.testing.io, home, &env);
        defer reopened.deinit();
        reopened.wire = fake.wire();
        var latest = try reopened.store.loadExisting();
        defer cfg.release(&latest);
        try std.testing.expectEqualStrings("high", latest.value.registry.?.reasoning_effort.?);
        try std.testing.expectEqual(mode != 0, (try credential(latest.value, "codex")).refresh_pending);
        if (mode != 0) {
            try std.testing.expectError(error.OAuthReauthenticationRequired, reopened.source().acquire(a, "codex", null, 5000));
            try std.testing.expectEqual(@as(usize, 1), fake.refresh_count);
        }
    }
}
test "source validates selected alias before wire" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const manager = try Manager.init(a, std.testing.io, home, &env);
    defer manager.deinit();
    var initial = try manager.store.loadOrInitialize();
    defer cfg.release(&initial);
    var fake: FakeWire = .{};
    manager.wire = fake.wire();
    try std.testing.expectError(error.InvalidCodexProvider, manager.source().acquire(a, "deepseek", null, 5000));
    try std.testing.expectError(error.CodexProviderNotFound, manager.source().acquire(a, "unknown", null, 5000));
    try std.testing.expect(!headerValue("abc\r\nInjected"));
    try std.testing.expectEqual(@as(usize, 0), fake.refresh_count);
}
test "source rejects missing JWT account claim" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const manager = try Manager.init(a, std.testing.io, home, &env);
    defer manager.deinit();
    var initial = try manager.store.loadOrInitialize();
    defer cfg.release(&initial);
    const expiry: i64 = @as(i64, @intCast(std.Io.Clock.real.now(std.testing.io).toMilliseconds())) + 3_600_000;
    const names = try merge(a, &initial.value, "codex", .{ .access_token = "not-a-jwt", .refresh_token = "refresh", .expires_at_ms = expiry }, true);
    defer a.free(names);
    try manager.store.save(initial.value);
    var fake: FakeWire = .{};
    manager.wire = fake.wire();
    manager.wire.account = wireAccount;
    try std.testing.expectError(error.InvalidCodexAccount, manager.source().acquire(a, "codex", null, 5000));
    try std.testing.expectEqual(@as(usize, 0), fake.refresh_count);
}
test "login merges latest unrelated settings and refuses competing credentials" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const home = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const manager = try Manager.init(a, std.testing.io, home, &env);
    defer manager.deinit();
    manager.min_poll_interval_ms = 1;
    var initial = try manager.store.loadOrInitialize();
    defer cfg.release(&initial);
    var other = try store_mod.Store.open(a, std.testing.io, home);
    defer other.deinit();
    var fake: FakeWire = .{ .mutate_store = &other };
    manager.wire = fake.wire();
    var cancel: p.Cancellation = .{};
    try manager.login("codex", &cancel, .{});
    var latest = try other.loadExisting();
    defer cfg.release(&latest);
    try std.testing.expectEqualStrings("high", latest.value.registry.?.reasoning_effort.?);
    try std.testing.expectEqualStrings("new-refresh", (try credential(latest.value, "codex")).refresh_token);
    try std.testing.expectEqual(@as(usize, 0), (try provider(latest.value, "codex")).models.len);
    fake.change_credential = true;
    try std.testing.expectError(error.OAuthLoginConflict, manager.login("codex", &cancel, .{}));
    var after = try other.loadExisting();
    defer cfg.release(&after);
    try std.testing.expectEqualStrings("parallel-refresh", (try credential(after.value, "codex")).refresh_token);
}
