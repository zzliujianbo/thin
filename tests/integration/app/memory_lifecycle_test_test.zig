test "initial core failures reach Session queue exactly once" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |busy| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root = try openRoot(a, io, tmp.dir);
        defer root.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", root.path);
        if (!busy) {
            var store = @import("../tools/memory.zig").Store.init(&root, .{});
            const entry = try store.write(a, "core", "known owned-memory-lifecycle-key", null);
            a.free(entry.content);
            a.free(entry.version);
        }
        const held = try fs.openDirectory(root.dir.handle, ".");
        defer fs.closeFd(held);
        if (busy) try std.testing.expectEqual(@as(c_int, 0), fs.flock(held, fs.LOCK.EX | fs.LOCK.NB));
        const queue = try @import("memory_notifications.zig").Queue.create(a);
        defer queue.deinit();
        const config = try cfg.clone(a, .{
            .provider = .{ .base_url = "http://127.0.0.1:1", .api_key = "owned-memory-lifecycle-key" },
            .selected_provider = "owned",
            .model = .{ .name = "main", .protocol = .chat, .context_tokens = 32768 },
            .limits = .{ .low_price_input = false },
        });
        const app = try App.initConfiguredAnchoredAuthWithNotifications(a, io, &env, &root, "/unused/private/config.json", .{}, config, queue);
        defer app.deinit();
        const terminal = queue.take().?;
        try std.testing.expectEqual(@as(u64, 0), terminal.id);
        try std.testing.expectEqual(@import("../core/memory_status.zig").Result.failed, terminal.result);
        try std.testing.expectEqual(if (busy) @import("../core/memory_status.zig").Failure.busy else .invalid_output, terminal.failure.?);
        try std.testing.expect(queue.take() == null);
        try std.testing.expect(!app.runtime.poisoned);
        try std.testing.expectEqual(@as(usize, 0), app.runtime.messages().len);
    }
}
test "Runtime publishes finished and accepts next prompt while Memory is gated" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try openRoot(a, io, tmp.dir);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const home = root.path;
    try env.put("HOME", home);
    const auth_path = try std.fs.path.join(a, &.{ home, "absent-config.json" });
    defer a.free(auth_path);
    var extractor: Extractor = .{ .io = io };
    var host: HostState = .{ .extractor = &extractor };
    const app = try createApp(a, io, &root, &env, auth_path, host.host());
    defer app.deinit();
    var primary: Primary = .{};
    app.runtime.model = .{ .context = &primary, .call_fn = Primary.call };
    app.memory_coordinator.service_override = extractor.service();

    var cancel: p.Cancellation = .{};
    var job: Job = .{ .runtime = &app.runtime, .cancel = &cancel, .prompt = "Wait for Memory before publishing idle." };
    var future = try std.Io.concurrent(io, Job.run, .{&job});
    defer future.await(io);
    try waitFlag(io, &extractor.started);
    try waitFlag(io, &job.done);
    future.await(io);
    try std.testing.expectEqual(r.Status.success, (try job.result()).status);
    try std.testing.expectEqual(@as(usize, 1), host.finished_events.load(.acquire));
    try std.testing.expect(host.finished_before_memory.load(.acquire));
    try std.testing.expectEqual(r.Status.success, (try app.runtime.run("A second task", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 2), primary.calls);
    extractor.release.store(true, .release);
    app.drainMemory(&cancel);
    try expectNoJobs(&root);
}
test "Memory failure and cancellation after finished do not change primary success" {
    const a = std.testing.allocator;
    for (0..2) |mode| {
        var backend = std.Io.Threaded.init(a, .{});
        defer backend.deinit();
        const io = backend.io();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root = try openRoot(a, io, tmp.dir);
        defer root.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", root.path);
        const auth_path = try std.fs.path.join(a, &.{ root.path, "absent-config.json" });
        defer a.free(auth_path);
        var extractor: Extractor = .{ .io = io, .fail = mode == 0 };
        var host: HostState = .{ .extractor = &extractor };
        const app = try createApp(a, io, &root, &env, auth_path, host.host());
        defer app.deinit();
        var primary: Primary = .{};
        app.runtime.model = .{ .context = &primary, .call_fn = Primary.call };
        app.memory_coordinator.service_override = extractor.service();
        var cancel: p.Cancellation = .{};
        var job: Job = .{ .runtime = &app.runtime, .cancel = &cancel, .prompt = "Wait for Memory before reporting success." };
        var future = try std.Io.concurrent(io, Job.run, .{&job});
        defer future.await(io);
        try waitFlag(io, &extractor.started);
        try waitFlag(io, &job.done);
        future.await(io);
        try std.testing.expectEqual(r.Status.success, (try job.result()).status);
        try std.testing.expectEqual(@as(usize, 1), host.finished_events.load(.acquire));
        try std.testing.expect(host.finished_before_memory.load(.acquire));
        var drain_cancel: p.Cancellation = .{};
        if (mode == 0) extractor.release.store(true, .release) else drain_cancel.cancel();
        app.drainMemory(&drain_cancel);
        const terminal = app.memoryView().last_terminal orelse return error.MissingMemoryTerminal;
        try std.testing.expect(terminal.result != .saved);
        try expectNoJobs(&root);
    }
}
test "Memory closeout CleanupFailed blocks prompt compact and command" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try openRoot(a, io, tmp.dir);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root.path);
    const auth_path = try std.fs.path.join(a, &.{ root.path, "absent-config.json" });
    defer a.free(auth_path);
    var extractor: Extractor = .{ .io = io, .cleanup_fail = true };
    var host: HostState = .{ .extractor = &extractor };
    const app = try createApp(a, io, &root, &env, auth_path, host.host());
    defer app.deinit();
    var primary: Primary = .{};
    app.runtime.model = .{ .context = &primary, .call_fn = Primary.call };
    app.memory_coordinator.service_override = extractor.service();

    var cancel: p.Cancellation = .{};
    var job: Job = .{ .runtime = &app.runtime, .cancel = &cancel, .prompt = "Wait for Memory before publishing idle." };
    var future = try std.Io.concurrent(io, Job.run, .{&job});
    defer {
        cancel.cancel();
        extractor.release.store(true, .release);
        future.await(io);
    }
    try waitFlag(io, &extractor.started);
    try waitFlag(io, &job.done);
    const original = try job.result();
    try std.testing.expectEqual(r.Status.success, original.status);
    try std.testing.expectEqual(@as(usize, 1), primary.calls);
    try std.testing.expectEqual(@as(usize, 1), host.finished_events.load(.acquire));
    try std.testing.expect(host.finished_before_memory.load(.acquire));
    try std.testing.expect(!extractor.finished.load(.acquire));

    extractor.release.store(true, .release);
    app.drainMemory(&cancel);
    try std.testing.expect(app.memory_coordinator.isPoisoned());
    const memory_terminal = app.memoryView().last_terminal orelse return error.MissingMemoryTerminal;
    try std.testing.expect(memory_terminal.result == .failed);
    try std.testing.expect(memory_terminal.failure != null and memory_terminal.failure.? == .cleanup);
    try std.testing.expect(!app.runtime.poisoned);
    try std.testing.expectEqual(r.Status.success, (try job.result()).status);
    try std.testing.expectEqual(r.Status.success, original.status);

    var executor: CountingExecutor = .{};
    app.runtime.executor = executor.executor();
    const primary_baseline = primary.calls;
    const helper_baseline = extractor.calls.load(.acquire);
    try std.testing.expectEqual(@as(usize, 1), helper_baseline);
    for (0..3) |operation| {
        const terminal = switch (operation) {
            0 => try app.runtime.run("Another owned prompt", &cancel),
            1 => try app.runtime.compactContext(&cancel),
            else => try app.runtime.executeCommand("!owned-no-sideeffects", &cancel),
        };
        try std.testing.expectEqual(r.Status.failed, terminal.status);
        try std.testing.expect(terminal.detail != null and terminal.detail.? == error.UnsafeToContinue);
        try std.testing.expectEqual(primary_baseline, primary.calls);
        try std.testing.expectEqual(@as(usize, 0), executor.prepares);
        try std.testing.expectEqual(@as(usize, 0), executor.executions);
        app.drainMemory(&cancel);
        try std.testing.expectEqual(helper_baseline, extractor.calls.load(.acquire));
        try std.testing.expect(!app.runtime.busy.load(.acquire));
    }
    try expectNoJobs(&root);
}
test "discarded settings replacement leaves live Memory owner accepting work" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try openRoot(a, io, tmp.dir);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root.path);
    const auth_path = try std.fs.path.join(a, &.{ root.path, "absent-config.json" });
    defer a.free(auth_path);
    var extractor: Extractor = .{ .io = io };
    var host: HostState = .{ .extractor = &extractor };
    const app = try createApp(a, io, &root, &env, auth_path, host.host());
    defer app.deinit();
    var primary: Primary = .{};
    app.runtime.model = .{ .context = &primary, .call_fn = Primary.call };
    app.memory_coordinator.service_override = extractor.service();

    var replacement = try app.prepareSettingsRefresh(app.config.value, &env, .decision);
    try std.testing.expect(replacement.replace_memory);
    replacement.deinit(); // Simulate a failed save: the live owner must survive.
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(r.Status.success, (try app.runtime.run("Wait for Memory before publishing idle.", &cancel)).status);
    try waitFlag(io, &extractor.started);
    try std.testing.expectEqual(@as(usize, 1), primary.calls);
    extractor.release.store(true, .release);
    app.drainMemory(&cancel);
    try expectNoJobs(&root);
}
