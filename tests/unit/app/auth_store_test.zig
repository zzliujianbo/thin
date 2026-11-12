test "default off fresh store and existing config bytes remain unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    var fresh = try store.loadOrInitialize();
    defer cfg.release(&fresh);
    try std.testing.expectEqualStrings("off", fresh.value.registry.?.reasoning_effort.?);
    var initialized = (try store.read()).?;
    defer initialized.deinit();
    var reloaded = try store.loadOrInitialize();
    defer cfg.release(&reloaded);
    var after = (try store.read()).?;
    defer after.deinit();
    try std.testing.expectEqualStrings(initialized.data(), after.data());

    const existing =
        \\{"llm":{"default":"local/m","reasoning_effort":"medium","providers":{"local":{"base_url":"https://fixture.invalid/v1","models":{"m":{"protocol":"chat","context_tokens":32768}}}}}}
    ;
    try store.root.writeMode(cfg.file_name, existing, true, 0o600);
    var previous = try store.loadOrInitialize();
    defer cfg.release(&previous);
    try std.testing.expectEqualStrings("medium", previous.value.registry.?.reasoning_effort.?);
    var unchanged = (try store.read()).?;
    defer unchanged.deinit();
    try std.testing.expectEqualStrings(existing, unchanged.data());
}
test "transaction latest write rejects stale ordinary save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try testOpen(tmp.dir);
    defer first.deinit();
    var second = try testOpen(tmp.dir);
    defer second.deinit();
    var stale = try first.loadOrInitialize();
    defer cfg.release(&stale);
    var tx = try second.beginTransaction(null, 1000);
    var latest = try tx.loadLatest();
    defer cfg.release(&latest);
    latest.value.registry.?.reasoning_effort = "high";
    try tx.saveLatest(latest.value);
    tx.deinit();
    try std.testing.expectError(error.AuthVersionConflict, first.save(stale.value));
    var verify = try first.loadExisting();
    defer cfg.release(&verify);
    try std.testing.expectEqualStrings("high", verify.value.registry.?.reasoning_effort.?);
}
test "restore auth loading never creates or initializes configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try std.testing.expectError(error.FileNotFound, Store.openExisting(std.testing.allocator, std.testing.io, home));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".thin", .{}));
    var store = try Store.open(std.testing.allocator, std.testing.io, home);
    defer store.deinit();
    try std.testing.expectError(error.ConfigNotFound, store.loadExisting());
    try store.root.dir.writeFile(std.testing.io, .{ .sub_path = cfg.file_name, .data = "  " });
    if (store.loadExisting()) |value| {
        var unexpected = value;
        cfg.release(&unexpected);
        return error.InitializedEmptyConfig;
    } else |_| {}
    const result = try store.root.read(std.testing.allocator, cfg.file_name, 0, 128);
    defer std.testing.allocator.free(result.data);
    try std.testing.expectEqualStrings("  ", result.data);
    try std.testing.expect(store.expected_version == null);
}
test "auth store missing and empty initialize once with private modes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    var parsed = try store.loadOrInitialize();
    defer cfg.release(&parsed);
    try std.testing.expectEqualStrings("deepseek-flash", parsed.value.model.name);
    try std.testing.expectEqualStrings("https://api.deepseek.com", parsed.value.provider.base_url);
    try std.testing.expect(parsed.value.selection_pending);
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", parsed.value.registry.?.default);
    const patch = parsed.value.registry.?.find("deepseek").?.patchFor("deepseek-flash").?;
    try std.testing.expectEqual(@as(?u32, 1000000), patch.context_tokens);
    try std.testing.expectEqual(.chat, patch.protocol.?);
    try std.testing.expect(parsed.value.provider.api_key == null);
    try std.testing.expect(parsed.value.provider.chat_max_tokens);
    try std.testing.expectEqualStrings("", parsed.value.provider.api_key_env);
    const dir_stat = try tmp.dir.statFile(io, ".thin", .{});
    try std.testing.expectEqual(@as(u32, 0o700), dir_stat.permissions.toMode() & 0o777);
    const stat = try store.root.dir.statFile(io, cfg.file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    const version = store.expected_version.?;
    var again = try store.loadOrInitialize();
    defer cfg.release(&again);
    try std.testing.expectEqual(version, store.expected_version.?);
    const same = try store.root.dir.statFile(io, cfg.file_name, .{});
    try std.testing.expectEqual(stat.inode, same.inode);

    for ([_][]const u8{ "", " \t\r\n" }) |empty| {
        try store.root.dir.writeFile(io, .{ .sub_path = cfg.file_name, .data = empty });
        try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(store.root.dir.handle, cfg.file_name, 0o644, 0));
        var initialized = try store.loadOrInitialize();
        defer cfg.release(&initialized);
        const mode = try store.root.dir.statFile(io, cfg.file_name, .{});
        try std.testing.expectEqual(@as(u32, 0o600), mode.permissions.toMode() & 0o777);
        try std.testing.expectEqual(version, store.expected_version.?);
    }
}
test "auth store preserves every nonempty invalid file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    for ([_][]const u8{ "{", "not json", "{}", "\x00", "\x0b", "{\"provider\":{\"api_key\":\"fake-secret\"},\"unknown\":1}", "{\"provider\":{\"base_url\":\"https://api.deepseek.com\"},\"model\":{\"name\":\"deepseek-flash\",\"context_tokens\":1000000}}" }) |invalid| {
        try store.root.dir.writeFile(std.testing.io, .{ .sub_path = cfg.file_name, .data = invalid });
        if (store.loadOrInitialize()) |result| {
            var unexpected = result;
            cfg.release(&unexpected);
            return error.ExpectedInvalidConfig;
        } else |_| {}
        var current = (try store.read()).?;
        defer current.deinit();
        try std.testing.expectEqualStrings(invalid, current.data());
        try std.testing.expect(store.expected_version == null);
    }
}
test "auth store rejects legacy disk and runtime-only saves without overwriting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    const legacy =
        \\{"provider":{"base_url":"https://api.deepseek.com"},"model":{"name":"deepseek-flash","context_tokens":1000000}}
    ;
    try store.root.dir.writeFile(std.testing.io, .{ .sub_path = cfg.file_name, .data = legacy });
    try std.testing.expectError(error.UnknownField, store.loadOrInitialize());
    try std.testing.expectError(error.UnknownField, store.loadExisting());
    try std.testing.expect(store.expected_version == null);
    var old_bytes = (try store.read()).?;
    defer old_bytes.deinit();
    try std.testing.expectEqualStrings(legacy, old_bytes.data());
    try store.root.dir.deleteFile(std.testing.io, cfg.file_name);
    var parsed = try store.loadOrInitialize();
    defer cfg.release(&parsed);
    const version = store.expected_version.?;
    var runtime_only = initial;
    runtime_only.registry = null;
    try std.testing.expectError(error.MissingRegistry, store.save(runtime_only));
    try std.testing.expectEqual(version, store.expected_version.?);
    var unchanged = try store.loadExisting();
    defer cfg.release(&unchanged);
    try std.testing.expectEqual(version, store.expected_version.?);
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", unchanged.value.registry.?.default);
}
test "auth store explicit save mode and version conflict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var one = try testOpen(tmp.dir);
    defer one.deinit();
    try std.testing.expectError(error.AuthStoreNotLoaded, one.save(initial));
    var parsed = try one.loadOrInitialize();
    defer cfg.release(&parsed);
    var two = try testOpen(tmp.dir);
    defer two.deinit();
    var second = try two.loadOrInitialize();
    defer cfg.release(&second);
    var changed = try cfg.clone(std.testing.allocator, parsed.value);
    defer cfg.release(&changed);
    try cfg.setRegistryCredential(changed.arena.allocator(), &changed.value, "deepseek", "fake-secret-only");
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(one.root.dir.handle, cfg.file_name, 0o644, 0));
    try one.save(changed.value);
    try std.testing.expectError(error.AuthVersionConflict, two.save(initial));
    try one.save(changed.value);
    const stat = try one.root.dir.statFile(std.testing.io, cfg.file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    var loaded = try two.loadOrInitialize();
    defer cfg.release(&loaded);
    try std.testing.expectEqualStrings("fake-secret-only", loaded.value.provider.api_key.?);
    // 非空且合法的文件也不应被引导模板改写。
    const saved_version = two.expected_version.?;
    var stable = try two.loadOrInitialize();
    defer cfg.release(&stable);
    try std.testing.expectEqual(saved_version, two.expected_version.?);
    try one.root.dir.deleteFile(std.testing.io, cfg.file_name);
    try std.testing.expectError(error.AuthVersionConflict, one.save(changed.value));
}
test "auth store rejects symlink directory FIFO and accepts large valid config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    const fd = store.root.dir.handle;
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing-fake-target", fd, cfg.file_name));
    try std.testing.expectError(error.SymlinkNotAllowed, store.loadOrInitialize());
    try store.root.dir.deleteFile(std.testing.io, cfg.file_name);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fd, cfg.file_name, 0o700));
    try std.testing.expectError(error.NotRegularFile, store.loadOrInitialize());
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(fd, cfg.file_name, std.c.AT.REMOVEDIR));
    try std.testing.expectEqual(@as(c_int, 0), mkfifoat(fd, cfg.file_name, 0o600));
    try std.testing.expectError(error.NotRegularFile, store.loadOrInitialize());
    try store.root.dir.deleteFile(std.testing.io, cfg.file_name);
    const valid =
        \\{"llm":{"default":"local/m","providers":{"local":{"base_url":"https://fixture.invalid/v1","models":{"m":{"protocol":"chat","context_tokens":32768}}}}}}
    ;
    const big = try std.testing.allocator.alloc(u8, 64 * 1024 + 1 + valid.len);
    defer std.testing.allocator.free(big);
    @memset(big[0 .. big.len - valid.len], ' ');
    @memcpy(big[big.len - valid.len ..], valid);
    try store.root.dir.writeFile(std.testing.io, .{ .sub_path = cfg.file_name, .data = big });
    var loaded = try store.loadOrInitialize();
    defer cfg.release(&loaded);
    try std.testing.expectEqualStrings("local/m", loaded.value.registry.?.default);
    try std.testing.expectEqual(@as(u32, 32768), loaded.value.registry.?.find("local").?.patchFor("m").?.context_tokens.?);
    const stat = try store.root.dir.statFile(std.testing.io, cfg.file_name, .{});
    try std.testing.expectEqual(@as(u64, big.len), stat.size);
    const unchanged = try store.root.dir.readFileAlloc(std.testing.io, cfg.file_name, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualSlices(u8, big, unchanged);
}
test "auth store rejects linked thin directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat(".", tmp.dir.handle, ".thin"));
    try std.testing.expectError(error.NotDir, testOpen(tmp.dir));
}
test "auth store independent directory locks have bounded contention" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var one = try testOpen(tmp.dir);
    defer one.deinit();
    var two = try testOpen(tmp.dir);
    defer two.deinit();
    const fd = try one.lock();
    defer fs.closeFd(fd);
    try std.testing.expectError(error.AuthStoreBusy, two.loadOrInitialize());
}
