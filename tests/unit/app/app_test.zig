test "headless missing and blank configuration use the same new schema without requests" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |blank| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
        var store = try @import("auth_store.zig").Store.open(a, io, home);
        defer store.deinit();
        if (blank) try store.root.writeMode(cfg.file_name, " \t\n", false, 0o600);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        try std.testing.expectError(error.ApiKeyNotFound, App.init(a, io, &env, home, .{}));
        var created = try store.loadExisting();
        defer cfg.release(&created);
        try std.testing.expect(created.value.registry != null);
        try std.testing.expectEqualStrings("deepseek/deepseek-flash", created.value.registry.?.default);
        try std.testing.expect(created.value.registry.?.providers[0].connection.api_key == null);
        try std.testing.expectError(error.FileNotFound, store.root.read(a, "settings.json", 0, 1024));
    }
}
test "headless global defaults ignore legacy settings and never create project settings" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { json: []const u8, effort: ?[]const u8 }{
        .{ .json =
        \\{"llm":{"default":"fixture/fake","reasoning_effort":"high","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat","reasoning_effort":"off","reasoning":{"map":{"off":"none","medium":"medium","high":"high"}}}}}}},"limits":{"low_price_input":false}}
        , .effort = "high" },
        .{ .json =
        \\{"llm":{"default":"fixture/fake","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat","reasoning_effort":"off","reasoning":{"map":{"off":"none","medium":"medium","high":"high"}}}}}}},"limits":{"low_price_input":false}}
        , .effort = "off" },
        .{ .json =
        \\{"llm":{"default":"fixture/fake","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat","reasoning":{"map":{"off":"none","medium":"medium","high":"high"}}}}}}},"limits":{"low_price_input":false}}
        , .effort = "off" },
        .{ .json =
        \\{"llm":{"default":"fixture/fake","reasoning_effort":"high","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat","reasoning_effort":"custom"}}}}},"limits":{"low_price_input":false}}
        , .effort = null },
    };
    // No Runtime.run: initialization uses owned config/cache fixtures only and
    // must not contact even the deliberately unresolvable model endpoint.
    for (cases) |case| for ([_]?[]const u8{ null, "{\"version\":1,\"reasoning_effort\":\"low\"}\n", "{broken settings" }) |legacy| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
        var store = try @import("auth_store.zig").Store.open(a, io, home);
        defer store.deinit();
        try store.root.writeMode(cfg.file_name, case.json, false, 0o600);
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
        const project = try std.fs.path.join(a, &.{ home, "project" });
        defer a.free(project);
        var root = try fs.Root.open(a, io, project);
        defer root.deinit();
        if (legacy) |content| {
            try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(root.dir.handle, ".thin", 0o700));
            try root.write(".thin/settings.json", content, false);
        }
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        const app = try App.init(a, io, &env, project, .{});
        defer app.deinit();
        try std.testing.expectEqualStrings("fake", app.config.value.model.name);
        try std.testing.expectEqualStrings("fixture/fake", app.config.value.registry.?.default);
        if (case.effort) |effort| {
            try std.testing.expectEqualStrings(effort, app.config.value.model.reasoning_effort.?);
        } else try std.testing.expect(app.config.value.model.reasoning_effort == null);
        if (legacy) |content| {
            const unchanged = try root.read(a, ".thin/settings.json", 0, 1024);
            defer a.free(unchanged.data);
            try std.testing.expectEqualStrings(content, unchanged.data);
        } else try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
        const unchanged_config = try store.root.read(a, cfg.file_name, 0, 8192);
        defer a.free(unchanged_config.data);
        try std.testing.expectEqualStrings(case.json, unchanged_config.data);

        // App owns a duplicated dirfd after init's local Root has closed. A
        // replacement pathname must never redirect its file operations.
        try std.testing.expectEqual(@as(c_int, 0), std.c.renameat(tmp.dir.handle, "project", tmp.dir.handle, "retired"));
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
        try app.root.write("anchored.txt", "original inode", false);
        const anchored = try root.read(a, "anchored.txt", 0, 100);
        defer a.free(anchored.data);
        try std.testing.expectEqualStrings("original inode", anchored.data);
        var replacement = try fs.Root.open(a, io, project);
        defer replacement.deinit();
        try std.testing.expectError(error.FileNotFound, replacement.read(a, "anchored.txt", 0, 100));
        try std.testing.expectError(error.FileNotFound, fs.openDirectory(replacement.dir.handle, ".thin"));
        try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("project", tmp.dir.handle, "project-alias"));
        const alias = try std.fs.path.join(a, &.{ home, "project-alias" });
        defer a.free(alias);
        // Linux O_DIRECTORY | O_NOFOLLOW rejects the symlink as ENOTDIR.
        try std.testing.expectError(error.NotDir, App.init(a, io, &env, alias, .{}));
    };
}
test "App ignores retired memory layout and preserves its artifacts" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var config_store = try @import("auth_store.zig").Store.open(a, io, home);
    defer config_store.deinit();
    try config_store.root.writeMode(cfg.file_name,
        \\{"llm":{"default":"fixture/fake","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat"}}}}},"memory":{"auto":false}}
    , false, 0o600);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
    const project = try std.fs.path.join(a, &.{ home, "project" });
    defer a.free(project);
    var root = try fs.Root.open(a, io, project);
    defer root.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(root.dir.handle, ".thin", 0o700));
    const thin = try fs.openDirectory(root.dir.handle, ".thin");
    defer fs.closeFd(thin);
    for ([_][:0]const u8{ "mem", "memory", "mem-jobs" }) |name| {
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(thin, name, 0o700));
    }
    for ([_][:0]const u8{ "mem", "memory" }) |name| {
        const dir = try fs.openDirectory(thin, name);
        defer fs.closeFd(dir);
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(dir, "jobs", 0o700));
    }
    const markers = [_][]const u8{
        ".thin/mem/core.md",      ".thin/mem/jobs/item",     ".thin/mem/jobs-owner",
        ".thin/memory/jobs/item", ".thin/memory/jobs-owner", ".thin/mem-jobs/item",
        ".thin/mem-jobs-owner",
    };
    for (markers) |path| try root.writeMode(path, "retired marker", false, 0o600);
    try root.writeMode(".thin/memory/core.md", "current core", false, 0o600);
    // A held retired owner lock must not gate initialization or Store access.
    const owner = fs.openAt(thin, "mem-jobs-owner", .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    try std.testing.expect(owner >= 0);
    defer fs.closeFd(owner);
    try std.testing.expectEqual(@as(c_int, 0), fs.flock(owner, fs.LOCK.EX | fs.LOCK.NB));
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    const app = try App.init(a, io, &env, project, .{});
    defer app.deinit();
    const current = try app.memory.read(a, "core");
    defer a.free(current.content);
    try std.testing.expectEqualStrings("current core", current.content);
    const updated = try app.memory.replace(a, "core", "updated core");
    defer a.free(updated.content);
    const reread = try app.memory.read(a, "core");
    defer a.free(reread.content);
    try std.testing.expectEqualStrings("updated core", reread.content);
    for (markers) |path| {
        const marker = try root.read(a, path, 0, 1024);
        defer a.free(marker.data);
        try std.testing.expectEqualStrings("retired marker", marker.data);
    }
}
test "App protects actual configuration behind HOME and file symlinks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fake =
        \\{"llm":{"default":"fixture/fake","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat"}}}}}}
    ;
    for ([_]bool{ false, true }) |linked_file| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "home", 0o700));
        var home_dir = try tmp.dir.openDir(io, "home", .{});
        defer home_dir.close(io);
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(home_dir.handle, ".thin", 0o700));
        const target = if (linked_file) "credentials.json" else ".thin/config.json";
        try home_dir.writeFile(io, .{ .sub_path = target, .data = fake });
        // Retired global settings are not a second configuration source.
        try home_dir.writeFile(io, .{ .sub_path = ".thin/settings.json", .data = "{broken legacy preferences" });
        if (linked_file) try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("../credentials.json", home_dir.handle, ".thin/config.json"));
        try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("home", tmp.dir.handle, "alias"));
        var buffer: [4096]u8 = undefined;
        const n = try home_dir.realPath(io, &buffer);
        const project = buffer[0..n];
        const alias = try std.fs.path.resolve(a, &.{ project, "../alias" });
        defer a.free(alias);
        for ([_][]const u8{ project, alias }) |home| {
            var env = std.process.Environ.Map.init(a);
            defer env.deinit();
            try env.put("HOME", home);
            const app = try App.init(a, io, &env, project, .{});
            defer app.deinit();
            try std.testing.expect(app.config.value.limits.low_price_input and !app.config.value.imageActive());
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const allocator = arena.allocator();
            const executor = app.executor.executor();
            const arguments = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{target});
            const prepared = try executor.prepare_fn(executor.context, allocator, .{ .id = "read-config", .name = "read_file", .arguments = arguments });
            var cancel = @import("../core/protocol.zig").Cancellation{};
            try std.testing.expectError(error.ProtectedAuthFile, executor.execute_fn(executor.context, allocator, prepared, &cancel));
            for ([_][]const u8{ target, app.auth_path }) |path| {
                try std.testing.expectError(error.ProtectedAuthFile, app.executor.execute(allocator, .{ .read_file = .{ .path = path } }, &cancel));
                try std.testing.expectError(error.ProtectedAuthFile, app.executor.execute(allocator, .{ .write_file = .{ .path = path, .content = "not written", .overwrite = true } }, &cancel));
            }
        }
    }
}
test "App submit rejection emits one completion and keeps the primary runtime usable" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    var root = try fs.Root.open(a, io, buffer[0..try tmp.dir.realPath(io, &buffer)]);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root.path);
    const fixture =
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"context_tokens":32768,"protocol":"chat"}}}}},"limits":{"low_price_input":false}}
    ;
    var parsed = try cfg.parse(a, fixture);
    model_resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &.{}) catch |err| {
        cfg.release(&parsed);
        return err;
    };
    const queue = try MemoryNotifications.create(a);
    defer queue.deinit();
    const app = try App.initConfiguredAnchoredAuth(a, io, &env, &root, "/unused/private/config.json", .{}, parsed);
    defer app.deinit();
    app.bindMemoryNotifications(queue);
    var capture: knowledge.Capture = .{ .allocator = a, .incomplete = true };
    App.submitMemory(app, &capture, .chat);
    try std.testing.expectEqual(@as(u16, @intFromError(error.IncompleteCapture)), app.memory_coordinator.failure.load(.acquire));
    const completion = queue.take().?;
    try std.testing.expectEqual(@as(u64, 1), completion.id);
    try std.testing.expectEqual(@import("../core/memory_status.zig").Result.failed, completion.result);
    try std.testing.expect(queue.take() == null);
    try std.testing.expect(!app.runtime.poisoned);
    try std.testing.expectEqual(@as(usize, 0), app.runtime.messages().len);
}
