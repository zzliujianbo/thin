//! Asynchronous automatic-Memory lifecycle tests. No network or user state.
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
    calls: std.atomic.Value(usize) = .init(0),
    fail: bool = false,
    cleanup_fail: bool = false,
    fn service(self: *@This()) k.Service {
        return .{ .context = self, .extract_fn = extract };
    }
    fn extract(raw: *anyopaque, a: std.mem.Allocator, _: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
        const self: *@This() = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.started.store(true, .release);
        defer self.finished.store(true, .release);
        while (!self.release.load(.acquire)) {
            if (cancel.isRequested()) return error.Canceled;
            try std.Io.sleep(self.io, .fromMilliseconds(2), .awake);
        }
        if (self.cleanup_fail) return error.CleanupFailed;
        if (self.fail) return error.MemoryUnavailable;
        return a.dupe(k.Candidate, &.{.{
            .category = .preferences,
            .topic = "settle-order",
            .content = "Wait for Memory before publishing idle.",
        }});
    }
};

const CountingExecutor = struct {
    prepares: usize = 0,
    executions: usize = 0,

    fn executor(self: *@This()) r.Executor {
        return .{ .context = self, .schemas = &.{}, .prepare_fn = prepare, .execute_fn = execute };
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.prepares += 1;
        return .{ .payload = self, .description = "owned harmless fixture" };
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.executions += 1;
        return .{ .text = "owned harmless fixture" };
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
    try std.testing.expectError(error.FileNotFound, root.dir.statFile(root.io, ".thin/memory/jobs-owner", .{ .follow_symlinks = false }));
}
