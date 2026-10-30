//! Actual App hooks with automatic recording and no HTTP: primary and extractor are owned fakes.
const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const App = @import("app.zig").App;
const source =
    \\{"llm":{"default":"owned/main","providers":{"owned":{"base_url":"http://127.0.0.1:1","api_key":"private-owned-test-key","models":{"main":{"protocol":"PRIMARY_PROTOCOL","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
;
const Fake = struct {
    calls: usize = 0,
    extracted: std.atomic.Value(usize) = .init(0),
    fn main(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .success = .{ .message = try p.textMessage(a, .assistant, "Owned answer."), .finish = .stop, .usage = .{ .total_tokens = 1234 } } };
    }
    fn auxiliary(raw: *anyopaque, a: std.mem.Allocator, request: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        _ = self.extracted.fetchAdd(1, .acq_rel);
        try std.testing.expect(request.scope.protocol != .auto and request.tools.len == 0);
        try sink.emit(.{ .usage = .{ .total_tokens = 333 } });
        return .{ .success = .{ .message = try p.textMessage(a, .assistant,
            \\{"items":[{"category":"preferences","topic":"review-style","content":"Prefers concise review explanations.","source_id":0,"quote":"prefer concise explanations","expected_version":null,"expires_at_ms":null}]}
        ), .finish = .stop, .usage = .{ .total_tokens = 333 } } };
    }
};

test "App memory root contention initial core skips Busy without blocking startup" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const cwd = path[0..try tmp.dir.realPath(io, &path)];
    var root = try fs.Root.open(a, io, cwd);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", cwd);
    const auth_path = try std.fs.path.join(a, &.{ cwd, "owned-absent-config.json" });
    defer a.free(auth_path);
    const Releaser = struct {
        io: std.Io,
        fd: c_int,
        released: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer {
                fs.closeFd(self.fd);
                self.released.store(true, .release);
            }
            std.Io.sleep(self.io, .fromMilliseconds(200), .awake) catch {};
        }
    };
    var held: ?c_int = try fs.openDirectory(root.dir.handle, ".");
    defer if (held) |fd| fs.closeFd(fd);
    try std.testing.expectEqual(@as(c_int, 0), fs.linux.flock(held.?, 2 | 4));
    var releaser: Releaser = .{ .io = io, .fd = held.? };
    var release = try std.Io.concurrent(io, Releaser.run, .{&releaser});
    held = null;
    defer release.await(io);

    const config = try cfg.clone(a, .{
        .provider = .{ .base_url = "http://127.0.0.1:1", .api_key = "private-owned-test-key" },
        .selected_provider = "owned",
        .model = .{ .name = "main", .protocol = .chat, .context_tokens = 32768 },
        .limits = .{ .low_price_input = false },
    });
    const app = try App.initConfiguredAnchoredAuth(a, io, &env, &root, auth_path, .{}, config);
    defer app.deinit();
    try std.testing.expectEqual(@as(u16, @intFromError(error.Busy)), app.memory_coordinator.failure.load(.acquire));
    try std.testing.expect(!releaser.released.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), app.memory_coordinator.extractor.?.calls);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
}

test "App default automatic memory succeeds with recording and without Decision and preserves primary context through Off" {
    const a = std.testing.allocator;
    for ([_]p.Protocol{ .chat, .auto }) |protocol| {
        var backend = std.Io.Threaded.init(a, .{});
        defer backend.deinit();
        const io = backend.io();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [4096]u8 = undefined;
        const cwd = path[0..try tmp.dir.realPath(io, &path)];
        var root = try fs.Root.open(a, io, cwd);
        defer root.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", cwd);
        const document = try std.mem.replaceOwned(u8, a, source, "PRIMARY_PROTOCOL", @tagName(protocol));
        defer a.free(document);
        var config = try cfg.parse(a, document);
        // Exercise the same pure declaration→active selection boundary as App
        // startup, rather than passing a still-pending disk DTO to activation.
        const cache = try a.create(@import("model_metadata.zig").Cache);
        defer a.destroy(cache);
        cache.* = .{};
        @import("model_resolver.zig").applyDefault(config.arena.allocator(), &config.value, cache) catch |err| {
            cfg.release(&config);
            return err;
        };
        const auth_path = try std.fs.path.join(a, &.{ cwd, "owned-absent-config.json" });
        defer a.free(auth_path);
        const app = try App.initConfiguredAnchoredAuth(a, io, &env, &root, auth_path, .{}, config);
        defer app.deinit();
        var fake: Fake = .{};
        app.runtime.model = .{ .context = &fake, .call_fn = Fake.main };
        app.memory_coordinator.extractor.?.model_override = .{ .context = &fake, .call_fn = Fake.auxiliary };
        const primary = app.client.authorization.ptr;
        try std.testing.expect(app.config.value.memory.auto and app.decision_client == null);
        try std.testing.expectEqual(@as(usize, 0), fake.extracted.load(.acquire));
        var cancel: p.Cancellation = .{};
        const terminal = try app.runtime.run("I prefer concise explanations in all reviews.", &cancel);
        app.drainMemory(&cancel);
        try std.testing.expectEqual(r.Status.success, terminal.status);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expectEqual(@as(usize, 1), fake.extracted.load(.acquire));
        const context = app.runtime.contextSnapshot();
        try std.testing.expect(context.known and context.tokens == 1234);
        try std.testing.expectEqual(@as(u64, 1), app.memory_coordinator.extractor.?.calls);
        try std.testing.expectEqual(@as(?u64, 333), app.memory_coordinator.extractor.?.last_usage.total());
        const saved = try app.memory.read(a, "preferences-review-style");
        defer a.free(saved.content);
        defer a.free(saved.version);
        try std.testing.expect(std.mem.find(u8, saved.content, "concise") != null);
        var off = try cfg.clone(a, app.config.value);
        defer cfg.release(&off);
        off.value.memory.auto = false;
        var replacement = try app.prepareSettings(off.value, &env);
        defer replacement.deinit();
        app.installSettings(&replacement);
        try std.testing.expect(!app.config.value.memory.auto and app.memory_coordinator.extractor == null);
        try std.testing.expect(app.client.authorization.ptr == primary);
        try std.testing.expectEqualDeep(context, app.runtime.contextSnapshot());
        // Off is not a switch disabling manual memory or project retrieval.
        const reference = try app.memory_coordinator.retrieve(a, "concise reviews", 1024);
        defer a.free(reference);
        try std.testing.expect(std.mem.find(u8, reference, "concise") != null);
        app.journal.flush();
        try std.testing.expect(app.journal.failure() == null);
        const record = try root.read(a, app.journal.store.path(), 0, 65536);
        defer a.free(record.data);
        try std.testing.expect(std.mem.find(u8, record.data, "concise explanations") != null);
    }
}
