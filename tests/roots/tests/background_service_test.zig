//! Offline acceptance tests for the instance background manager.
//!
//! Every command here is a short, real, synthetic subprocess writing to owned
//! pipes. No network, API key, repository file or user settings are touched.
//! The manager joins all workers in `deinit`; every test funnels through
//! `Fixture.deinit` so a failed assertion still stops owned services.
//!
//! Not covered here (honest gaps for the first round):
//! - Same-group descendant accounting beyond direct-child PID snapshots.
//! - FD accounting beyond allocator leak detection and /proc checks of owned pids.
//! - Concurrent starts racing each other on one manager.
//! - A real shell that allocates its own process group beyond the direct child.

const std = @import("std");
const p = @import("../core/protocol.zig");
const bg = @import("../core/background.zig");
const fs = @import("../platform/filesystem.zig");
const manager = @import("../app/background_service.zig");

const Fixture = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    io: std.Io = std.testing.io,
    tmp: std.testing.TmpDir = undefined,
    root: fs.Root = undefined,
    env: std.process.Environ.Map = undefined,
    service: manager.BackgroundService = .{},
    service_active: bool = false,

    /// Initializes root/env first and only then points deps at their final
    /// locations. Never stores a pointer to a returned stack temporary.
    fn init(self: *Fixture) !void {
        // Tests declare `var fx: Fixture = undefined`, so every default must be
        // installed here before any field pointer is taken.
        self.* = .{};
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const n = try self.tmp.dir.realPath(self.io, &buffer);
        self.root = try fs.Root.open(self.allocator, self.io, buffer[0..n]);
        errdefer self.root.deinit();
        self.env = std.process.Environ.Map.init(self.allocator);
        errdefer self.env.deinit();
        try self.env.put("PATH", "/usr/bin:/bin");
        try self.env.put("HOME", buffer[0..n]);
        try self.env.put("LANG", "C.UTF-8");
        self.service = .{};
        self.service.deps = .{
            .allocator = self.allocator,
            .io = self.io,
            .root = &self.root,
            .environment = &self.env,
        };
        self.service_active = true;
    }

    fn deinit(self: *Fixture) void {
        if (self.service_active) {
            // close() 失败只打印、不再 panic；需要断言的测试必须先显式
            // closeService()，否则收尾失败会变成静默遗漏。
            self.service.deinit();
            self.service_active = false;
        }
        self.env.deinit();
        self.root.deinit();
        self.tmp.cleanup();
    }

    /// Explicitly hand the manager back so owned pid checks can run before the
    /// rest of the fixture is torn down. Cleanup failure is a normal test
    /// error (with the offending job id), never a process abort.
    fn closeService(self: *Fixture) !void {
        if (!self.service_active) return;
        self.service_active = false;
        try self.service.close();
    }
};

fn startArgs(command: []const u8, timeout_ms: u32, log_bytes: u32) bg.Start {
    return .{
        .command = command,
        .startup_timeout_ms = timeout_ms,
        .log_bytes = log_bytes,
        .term_grace_ms = 500,
        .cleanup_timeout_ms = 5000,
    };
}

fn startText(f: *Fixture, a: std.mem.Allocator, command: []const u8, timeout_ms: u32, log_bytes: u32, cancel: *const p.Cancellation) !bg.Result {
    return f.service.service().start(a, startArgs(command, timeout_ms, log_bytes), cancel);
}

fn startJson(f: *Fixture, a: std.mem.Allocator, command: []const u8, timeout_ms: u32, log_bytes: u32, cancel: *const p.Cancellation) !std.json.Value {
    const result = try startText(f, a, command, timeout_ms, log_bytes, cancel);
    if (result.is_error) return error.StartFailed;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.text, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidManagerJson;
    return parsed;
}

fn controlResultOf(svc: *manager.BackgroundService, a: std.mem.Allocator, query: bg.Query, cancel: *const p.Cancellation) !bg.Result {
    return svc.service().control(a, query, cancel);
}

fn controlJsonOf(svc: *manager.BackgroundService, a: std.mem.Allocator, query: bg.Query, cancel: *const p.Cancellation) !std.json.Value {
    const result = try controlResultOf(svc, a, query, cancel);
    if (result.is_error) return error.ControlFailed;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, result.text, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidManagerJson;
    return parsed;
}

fn controlResult(f: *Fixture, a: std.mem.Allocator, query: bg.Query, cancel: *const p.Cancellation) !bg.Result {
    return controlResultOf(&f.service, a, query, cancel);
}

fn controlJson(f: *Fixture, a: std.mem.Allocator, query: bg.Query, cancel: *const p.Cancellation) !std.json.Value {
    return controlJsonOf(&f.service, a, query, cancel);
}

fn receiptId(a: std.mem.Allocator, receipt: std.json.Value) ![]const u8 {
    const id = receipt.object.get("id") orelse return error.MissingId;
    if (id != .string or !bg.validId(id.string)) return error.InvalidId;
    if (!std.mem.eql(u8, receipt.object.get("state").?.string, "started")) return error.InvalidReceipt;
    return a.dupe(u8, id.string);
}

fn statusService(a: std.mem.Allocator, response: std.json.Value) !std.json.Value {
    _ = a;
    if (!std.mem.eql(u8, response.object.get("action").?.string, "status")) return error.InvalidStatus;
    const service = response.object.get("service") orelse return error.MissingService;
    if (service != .object) return error.InvalidStatus;
    return service;
}

fn stateOf(service: std.json.Value) []const u8 {
    return service.object.get("state").?.string;
}

fn pidOf(service: std.json.Value) u64 {
    return @intCast(service.object.get("pid").?.integer);
}

fn waitTerminalOf(svc: *manager.BackgroundService, a: std.mem.Allocator, id: []const u8, cancel: *const p.Cancellation) !std.json.Value {
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        const response = try controlJsonOf(svc, a, .{ .action = .status, .id = id }, cancel);
        const service = try statusService(a, response);
        if (!std.mem.eql(u8, stateOf(service), "running")) return service;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    return error.ServiceDidNotTerminate;
}

fn waitTerminal(f: *Fixture, a: std.mem.Allocator, id: []const u8, cancel: *const p.Cancellation) !std.json.Value {
    return waitTerminalOf(&f.service, a, id, cancel);
}

/// Waits for the real startup marker to reach the ring. The handshake only
/// proves a process exists, not that it has written output yet.
fn waitLogContains(f: *Fixture, a: std.mem.Allocator, id: []const u8, marker: []const u8, cancel: *const p.Cancellation) !std.json.Value {
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        const logs = try controlJson(f, a, .{ .action = .logs, .id = id, .stdout_offset = 0, .stderr_offset = 0, .limit = 4096 }, cancel);
        const stdout = logs.object.get("stdout").?.object;
        if (std.mem.indexOf(u8, stdout.get("text").?.string, marker) != null) return .{ .object = stdout };
        try std.Io.sleep(f.io, .fromMilliseconds(5), .awake);
    }
    return error.MarkerDidNotArrive;
}

fn expectProcessGone(pid: u64) !void {
    if (@import("builtin").os.tag == .macos) {
        if (pid <= 1 or pid > std.math.maxInt(std.c.pid_t)) return error.InvalidOwnedPid;
        // Signal 0 delivers no signal. A reused PID or uncertain permission is
        // conservatively still present; never TERM/KILL a reaped cached PID.
        const rc = std.c.kill(@intCast(pid), @fromBackingInt(0));
        if (rc == 0 or std.c.errno(rc) != .SRCH) return error.OwnedProcessStillExists;
        return;
    }
    var buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "/proc/{d}", .{pid});
    if (std.Io.Dir.openFileAbsolute(std.testing.io, path, .{})) |file| {
        file.close(std.testing.io);
        return error.OwnedProcessStillExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

fn guardTestKey(_: *anyopaque, text: []const u8) bool {
    return std.mem.indexOf(u8, text, "test-secret") != null;
}

fn cancelAfter(token: *p.Cancellation, milliseconds: u64) void {
    std.Io.sleep(std.testing.io, .fromMilliseconds(@intCast(milliseconds)), .awake) catch {};
    token.cancel();
}

// Fails the first output allocation after the manager has built its owned job
// resources, before the worker is spawned. The manager deps allocator is the
// regular testing allocator, so a deps leak is reported by the test runner.

// Fresh fixture per index: fail_index counts from zero for the manager-owned
// allocator, so each iteration deterministically reaches one construction
// stage. After disabling the failure the same single owner must recover, stop
// and free everything exactly once.

// Only the concurrent spawn vtable slot is replaced. Every other IO function
// still sees the original userdata, so this cannot corrupt real IO calls.
fn rejectConcurrent(
    _: ?*anyopaque,
    _: usize,
    _: std.mem.Alignment,
    _: []const u8,
    _: std.mem.Alignment,
    _: *const fn (*const anyopaque, *anyopaque) void,
) std.Io.ConcurrentError!*std.Io.AnyFuture {
    return error.ConcurrencyUnavailable;
}
