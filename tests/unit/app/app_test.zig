test "subagent private environment owns only configured keys and CA through allocation failures" {
    const a = std.testing.allocator;
    var source = std.process.Environ.Map.init(a);
    defer source.deinit();
    try source.put("CURL_CA_BUNDLE", "ca-original");
    try source.put("ACTIVE_KEY", "active-original");
    try source.put("OTHER_KEY", "other-original");
    try source.put("SECRET", "not-captured");
    try source.put("PATH", "/not-captured");
    const config: cfg.Config = .{
        .provider = .{ .base_url = "https://active.invalid", .api_key_env = "ACTIVE_KEY" },
        .model = .{ .name = "model", .context_tokens = 32768 },
        .registry = .{ .default = "active/model", .providers = &.{
            .{ .name = "active", .connection = .{ .base_url = "https://active.invalid", .api_key_env = "ACTIVE_KEY" } },
            .{ .name = "other", .connection = .{ .base_url = "https://other.invalid", .api_key_env = "OTHER_KEY" } },
            .{ .name = "duplicate", .connection = .{ .base_url = "https://duplicate.invalid", .api_key_env = "OTHER_KEY" } },
            .{ .name = "missing", .connection = .{ .base_url = "https://missing.invalid", .api_key_env = "MISSING_KEY" } },
        } },
    };
    // Only the snapshot uses the fault allocator; the source and config remain
    // valid for every retry. putMove transfers both buffers only on success.
    try std.testing.checkAllAllocationFailures(a, subagentEnvironmentAllocationCase, .{ config, &source });
    {
        var snapshot = try captureSubagentEnvironment(a, config, &source);
        defer wipeSubagentEnvironment(&snapshot);
        try source.put("ACTIVE_KEY", "active-changed");
        try source.put("OTHER_KEY", "other-changed");
        try source.put("CURL_CA_BUNDLE", "ca-changed");
        try std.testing.expectEqual(@as(usize, 3), snapshot.count());
        try std.testing.expectEqualStrings("active-original", snapshot.get("ACTIVE_KEY").?);
        try std.testing.expectEqualStrings("other-original", snapshot.get("OTHER_KEY").?);
        try std.testing.expectEqualStrings("ca-original", snapshot.get("CURL_CA_BUNDLE").?);
        try std.testing.expect(snapshot.get("SECRET") == null);
        try std.testing.expect(snapshot.get("PATH") == null);
    }
    try std.testing.expectEqualStrings("active-changed", source.get("ACTIVE_KEY").?);
    try std.testing.expectEqualStrings("other-changed", source.get("OTHER_KEY").?);
    try std.testing.expectEqualStrings("ca-changed", source.get("CURL_CA_BUNDLE").?);
    try std.testing.expectEqualStrings("not-captured", source.get("SECRET").?);
    try std.testing.expectEqualStrings("/not-captured", source.get("PATH").?);
}
test "subagent metadata fallback preserves resource cancellation and permission errors" {
    try std.testing.expect(!badSubagentMetadata(error.OutOfMemory));
    try std.testing.expect(!badSubagentMetadata(error.Canceled));
    try std.testing.expect(!badSubagentMetadata(error.AccessDenied));
    try std.testing.expect(!badSubagentMetadata(error.PermissionDenied));
    try std.testing.expect(badSubagentMetadata(error.InvalidMetadata));
}
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
            try std.testing.expect(app.config.value.limits.low_price_input and !app.config.value.decisionActive());
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
test "App session title capability survives settings and connection rebinds" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root.path);
    const fixture =
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"context_tokens":32768,"protocol":"chat"},"alternate":{"context_tokens":32768,"protocol":"chat"}}}}},"memory":{"auto":false}}
    ;
    var parsed = try cfg.parse(a, fixture);
    model_resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &.{}) catch |err| {
        cfg.release(&parsed);
        return err;
    };
    const app = try App.initConfiguredAnchoredAuth(a, io, &env, &root, "/unused/private/config.json", .{}, parsed);
    defer app.deinit();
    try std.testing.expect(app.executor.session_title == null);
    try expectSessionTitleSchema(app, 0);
    // Runtime.init keeps its system prompt separately from canonical history.
    try std.testing.expectEqual(@as(usize, 0), app.runtime.messages().len);
    const title = Title.fromText("保留标题");
    app.enableSessionTitle(title);
    try std.testing.expect(Title.eql(title, app.executor.session_title.?));
    try expectSessionTitleSchema(app, 1);

    var declaration = app.config.value;
    declaration.limits.request_timeout_ms += 1;
    var settings = try app.prepareSettings(declaration, &env);
    defer settings.deinit();
    app.installSettings(&settings);
    try std.testing.expect(Title.eql(title, app.executor.session_title.?));
    try expectSessionTitleSchema(app, 1);

    var candidate = try cfg.clone(a, app.config.value);
    candidate.value.model.name = "alternate";
    const connection = try app.prepareConnection(candidate, &env);
    app.installConnection(connection);
    try std.testing.expectEqualStrings("alternate", app.config.value.model.name);
    try std.testing.expect(Title.eql(title, app.executor.session_title.?));
    try expectSessionTitleSchema(app, 1);

    // A separately initialized App does not inherit the parent's capability.
    var child_config = try cfg.parse(a, fixture);
    model_resolver.applyDefault(child_config.arena.allocator(), &child_config.value, &.{}) catch |err| {
        cfg.release(&child_config);
        return err;
    };
    const child = try App.initConfiguredAnchoredAuth(a, io, &env, &root, "/unused/private/config.json", .{}, child_config);
    defer child.deinit();
    try std.testing.expect(child.executor.session_title == null);
    try expectSessionTitleSchema(child, 0);
}
test "App unavailable decision key never blocks startup and chat replacement keeps independent reference" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root.path);
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"context_tokens":32768,"protocol":"chat"},"alternate":{"context_tokens":32768,"protocol":"chat"}}},"judge":{"base_url":"http://judge.invalid/v1","api_key_env":"MISSING_JUDGE_KEY","models":{"mini":{"context_tokens":16384,"protocol":"responses"}}}}},"decision":{"model":"judge/mini"}}
    );
    model_resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &.{}) catch |err| {
        cfg.release(&parsed);
        return err;
    };
    const app = try App.initConfiguredAnchoredAuth(a, io, &env, &root, "/unused/private/config.json", .{}, parsed);
    defer app.deinit();
    try std.testing.expect(app.decision_client != null and app.runtime.decision_service != null);
    try std.testing.expect(app.decision_client.?.resolved == null and app.decision_client.?.calls == 0);
    const previous = app.decision_client.?;
    var candidate = try cfg.clone(a, app.config.value);
    candidate.value.model.name = "alternate";
    const replacement = try app.prepareConnection(candidate, &env);
    app.installConnection(replacement);
    try std.testing.expectEqualStrings("alternate", app.config.value.model.name);
    try std.testing.expect(app.decision_client.? != previous);
    try std.testing.expectEqualStrings("judge/mini", app.decision_client.?.source.value.decision.?.model);
    try std.testing.expect(app.runtime.decision_service.?.context == @as(*anyopaque, @ptrCast(app.decision_client.?)));
    const sink = app.journal.diagnosticSink();
    try std.testing.expect(app.runtime.diagnostics.context == sink.context);
    try std.testing.expect(app.decision_client.?.diagnostics.context == sink.context);
    try std.testing.expect(app.memory_coordinator.diagnostics.context == sink.context);
    if (app.memory_coordinator.extractor) |extractor| try std.testing.expect(extractor.diagnostics.context == sink.context);
    const checkpoint = try app.runtime.checkpoint();
    try std.testing.expect(!@hasField(@TypeOf(checkpoint), "decision"));
    try std.testing.expect(!@hasField(@TypeOf(checkpoint), "decision_service"));
}
