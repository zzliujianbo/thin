//! Synchronous automatic-Memory settle boundary tests. No network or user state.
const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const k = @import("../core/knowledge.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const Job = @import("../core/task.zig").Job;
const App = @import("app.zig").App;

const Primary = struct {
    calls: usize = 0,
    fn call(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .success = .{ .message = try p.textMessage(a, .assistant, "primary answer is frozen"), .finish = .stop } };
    }
};

const Extractor = struct {
    io: std.Io,
    started: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    fail: bool = false,
    fn service(self: *@This()) k.Service {
        return .{ .context = self, .extract_fn = extract };
    }
    fn extract(raw: *anyopaque, a: std.mem.Allocator, material: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.started.store(true, .release);
        defer self.finished.store(true, .release);
        while (!self.release.load(.acquire)) {
            if (cancel.isRequested()) return error.Canceled;
            try std.Io.sleep(self.io, .fromMilliseconds(2), .awake);
        }
        if (self.fail) return error.MemoryUnavailable;
        return a.dupe(k.Candidate, &.{.{
            .category = .preferences,
            .topic = "settle-order",
            .content = "Wait for Memory before publishing idle.",
            .source_id = material.sources[0].id,
            .quote = "Wait for Memory",
        }});
    }
};

const HostState = struct {
    extractor: *Extractor,
    finished_events: std.atomic.Value(usize) = .init(0),
    finished_before_memory: std.atomic.Value(bool) = .init(false),
    fn host(self: *@This()) r.Host {
        return .{ .context = self, .emit_fn = emit, .authorize_fn = authorize };
    }
    fn emit(raw: ?*anyopaque, event: r.Event, _: *const p.Cancellation) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (event == .finished) {
            if (!self.extractor.finished.load(.acquire)) self.finished_before_memory.store(true, .release);
            _ = self.finished_events.fetchAdd(1, .acq_rel);
        }
    }
    fn authorize(_: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        return .allow_once;
    }
};

fn openRoot(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    return fs.Root.open(a, io, buffer[0..try dir.realPath(io, &buffer)]);
}
fn createApp(a: std.mem.Allocator, io: std.Io, root: *const fs.Root, env: *const std.process.Environ.Map, auth_path: []const u8, host: r.Host) !*App {
    const config = try cfg.clone(a, .{
        .provider = .{ .base_url = "http://127.0.0.1:1", .api_key = "owned-memory-lifecycle-key" },
        .selected_provider = "owned",
        .model = .{ .name = "main", .protocol = .chat, .context_tokens = 32768 },
        .limits = .{ .low_price_input = false },
    });
    return App.initConfiguredAnchoredAuth(a, io, env, root, auth_path, host, config);
}
fn waitFlag(io: std.Io, flag: *const std.atomic.Value(bool)) !void {
    const start = std.Io.Clock.awake.now(io);
    while (!flag.load(.acquire)) {
        if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 2000) return error.TestTimeout;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}
fn expectNoJobs(root: *fs.Root) !void {
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin/memory/jobs"));
    try std.testing.expectError(error.FileNotFound, fs.openPath(root.dir.handle, ".thin/memory/jobs-owner"));
}

test "Runtime cannot publish finished or idle before synchronous Memory finalization" {
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
    try std.testing.expect(!job.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), host.finished_events.load(.acquire));
    try std.testing.expectEqualStrings("Memory: finalizing (separate auxiliary request)", app.memoryNotice().?);

    extractor.release.store(true, .release);
    future.await(io);
    try std.testing.expectEqual(r.Status.success, (try job.result()).status);
    try std.testing.expectEqual(@as(usize, 1), primary.calls);
    try std.testing.expectEqual(@as(usize, 1), host.finished_events.load(.acquire));
    try std.testing.expect(!host.finished_before_memory.load(.acquire));
    try std.testing.expectEqualStrings("Memory: saved", app.memoryNotice().?);
    try expectNoJobs(&root);
}

test "Memory failure and cancellation settle before finished without changing primary success" {
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
        if (mode == 0) extractor.release.store(true, .release) else cancel.cancel();
        future.await(io);
        try std.testing.expectEqual(r.Status.success, (try job.result()).status);
        try std.testing.expectEqual(@as(usize, 1), host.finished_events.load(.acquire));
        if (mode == 0) {
            try std.testing.expect(std.mem.find(u8, app.memoryNotice().?, "uncertain") != null);
            try std.testing.expect(!host.finished_before_memory.load(.acquire));
        } else {
            try std.testing.expectEqualStrings("Memory: finalization canceled", app.memoryNotice().?);
        }
        try expectNoJobs(&root);
    }
}
