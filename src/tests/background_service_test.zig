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
            self.service.deinit();
            self.service_active = false;
        }
        self.env.deinit();
        self.root.deinit();
        self.tmp.cleanup();
    }

    /// Explicitly hand the manager back so owned pid checks can run before the
    /// rest of the fixture is torn down.
    fn closeService(self: *Fixture) void {
        if (!self.service_active) return;
        self.service.deinit();
        self.service_active = false;
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

fn cancelAfter(token: *p.Cancellation, milliseconds: u64) void {
    std.Io.sleep(std.testing.io, .fromMilliseconds(@intCast(milliseconds)), .awake) catch {};
    token.cancel();
}

test "twelve cumulative starts, six live services and exact pagination" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: p.Cancellation = .{};

    var short_ids: [6][]const u8 = undefined;
    for (0..6) |i| {
        const command = try std.fmt.allocPrint(a, "printf SHORT_{d}", .{i});
        const receipt = try startJson(&fixture, a, command, 5000, 65536, &cancel);
        short_ids[i] = try receiptId(a, receipt);
        if (i > 0) try std.testing.expect(!std.mem.eql(u8, short_ids[i], short_ids[i - 1]));
    }

    var live_ids: [6][]const u8 = undefined;
    var live_pids: [6]u64 = undefined;
    for (0..6) |i| {
        const command = try std.fmt.allocPrint(a, "printf LIVE_{d}; exec sleep 30", .{i});
        const receipt = try startJson(&fixture, a, command, 5000, 65536, &cancel);
        live_ids[i] = try receiptId(a, receipt);
    }

    // A running status with an owned pid plus the real startup marker proves
    // the services are processes, not merely registered Futures.
    for (live_ids, 0..) |id, i| {
        const status = try controlJson(&fixture, a, .{ .action = .status, .id = id }, &cancel);
        const service = try statusService(a, status);
        try std.testing.expectEqualStrings("running", stateOf(service));
        live_pids[i] = pidOf(service);
        try std.testing.expect(live_pids[i] > 1);
        try std.testing.expectEqualStrings(id, service.object.get("id").?.string);
        const marker = try std.fmt.allocPrint(a, "LIVE_{d}", .{i});
        const stdout = try waitLogContains(&fixture, a, id, marker, &cancel);
        try std.testing.expect(std.mem.indexOf(u8, stdout.object.get("text").?.string, marker) != null);
    }

    // A full page at the maximum size must still be bounded by the real total.
    const max_page = try controlJson(&fixture, a, .{ .action = .list, .limit = 100 }, &cancel);
    try std.testing.expectEqual(@as(i64, 12), max_page.object.get("total").?.integer);
    try std.testing.expectEqual(@as(usize, 12), max_page.object.get("services").?.array.items.len);
    try std.testing.expect(!max_page.object.get("has_more").?.bool);

    // Pagination traverses every retained job; limit 2 is a page size, not a
    // service limit, and no id may be skipped or duplicated.
    var seen = std.StringHashMap(void).init(a);
    var after: ?u64 = null;
    var pages: usize = 0;
    while (pages < 20) : (pages += 1) {
        const query: bg.Query = .{ .action = .list, .after = after, .limit = 2 };
        const response = try controlJson(&fixture, a, query, &cancel);
        const services = response.object.get("services").?;
        if (services != .array) return error.InvalidList;
        for (services.array.items) |service| {
            const id = service.object.get("id").?.string;
            if (seen.contains(id)) return error.DuplicateListId;
            try seen.put(try a.dupe(u8, id), {});
        }
        const has_more = response.object.get("has_more").?.bool;
        if (!has_more) break;
        after = @as(u64, @intCast(response.object.get("next").?.integer));
    }
    try std.testing.expectEqual(@as(usize, 12), seen.count());
    for (short_ids) |id| try std.testing.expect(seen.contains(id));
    for (live_ids) |id| try std.testing.expect(seen.contains(id));

    // Stop every owned live service so the deferred deinit has nothing to kill
    // except already-reaped records.
    for (live_ids) |id| {
        const response = try controlJson(&fixture, a, .{ .action = .stop, .id = id }, &cancel);
        const service = try statusService(a, response);
        try std.testing.expect(!std.mem.eql(u8, stateOf(service), "running"));
    }
    fixture.closeService();
    for (live_pids) |pid| try expectProcessGone(pid);
}

test "handoff survives caller cancellation, one stop leaves siblings running" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: p.Cancellation = .{};

    var ids: [6][]const u8 = undefined;
    var pids: [6]u64 = undefined;
    for (0..6) |i| {
        const command = try std.fmt.allocPrint(a, "printf SIB_{d}; exec sleep 30", .{i});
        const receipt = try startJson(&fixture, a, command, 5000, 65536, &cancel);
        ids[i] = try receiptId(a, receipt);
        const status = try controlJson(&fixture, a, .{ .action = .status, .id = ids[i] }, &cancel);
        pids[i] = pidOf(try statusService(a, status));
    }

    // The accepted-task/tool token may be canceled after handoff; it is not a
    // service owner.
    cancel.cancel();
    for (ids) |id| {
        const status = try controlJson(&fixture, a, .{ .action = .status, .id = id }, &cancel);
        try std.testing.expectEqualStrings("running", stateOf(try statusService(a, status)));
    }
    cancel = .{};

    const stopped = try controlJson(&fixture, a, .{ .action = .stop, .id = ids[2] }, &cancel);
    try std.testing.expect(!std.mem.eql(u8, stateOf(try statusService(a, stopped)), "running"));
    for (ids, 0..) |id, i| {
        if (i == 2) continue;
        const status = try controlJson(&fixture, a, .{ .action = .status, .id = id }, &cancel);
        try std.testing.expectEqualStrings("running", stateOf(try statusService(a, status)));
    }

    // A repeated stop queries the retained terminal record and must not signal
    // the reaped pid again.
    const again = try controlJson(&fixture, a, .{ .action = .stop, .id = ids[2] }, &cancel);
    try std.testing.expect(!std.mem.eql(u8, stateOf(try statusService(a, again)), "running"));

    // Another instance's well-formed id is unknown here and is rejected, while
    // malformed ids fail strict validation before any lookup.
    const foreign = "deadbeefdead-7";
    try std.testing.expect(bg.validId(foreign));
    const unknown = try controlResult(&fixture, a, .{ .action = .status, .id = foreign }, &cancel);
    try std.testing.expect(unknown.is_error);
    const malformed = try controlResult(&fixture, a, .{ .action = .status, .id = "NOT-HEX" }, &cancel);
    try std.testing.expect(malformed.is_error);

    for (ids, 0..) |id, i| {
        if (i == 2) continue;
        _ = try controlJson(&fixture, a, .{ .action = .stop, .id = id }, &cancel);
    }
    fixture.closeService();
    for (pids, 0..) |pid, i| {
        // The stopped sibling may already be reaped; all are gone after deinit.
        _ = i;
        try expectProcessGone(pid);
    }
}

test "logs use absolute raw cursors, bounded budgets and safe escaping" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: p.Cancellation = .{};

    // 200 raw bytes on stdout and stderr exceed a 64-byte ring, so old bytes are
    // overwritten and available_from advances.
    const receipt = try startJson(&fixture, a, "head -c 200 /dev/zero | tr '\\0' A; head -c 200 /dev/zero | tr '\\0' B >&2", 5000, 64, &cancel);
    const id = try receiptId(a, receipt);
    const terminal = try waitTerminal(&fixture, a, id, &cancel);
    try std.testing.expect(!std.mem.eql(u8, stateOf(terminal), "running"));

    const zero = try controlJson(&fixture, a, .{ .action = .logs, .id = id, .stdout_offset = 0, .stderr_offset = 0, .limit = 1 }, &cancel);
    const out = zero.object.get("stdout").?.object;
    const err = zero.object.get("stderr").?.object;
    const out_total: u64 = @intCast(out.get("total_bytes").?.integer);
    const err_total: u64 = @intCast(err.get("total_bytes").?.integer);
    try std.testing.expectEqual(@as(u64, 200), out_total);
    try std.testing.expectEqual(@as(u64, 200), err_total);
    const out_available: u64 = @intCast(out.get("available_from").?.integer);
    const err_available: u64 = @intCast(err.get("available_from").?.integer);
    try std.testing.expect(out_available > 0);
    try std.testing.expect(err_available > 0);
    try std.testing.expect(out.get("lost_bytes").?.integer > 0);
    try std.testing.expect(err.get("lost_bytes").?.integer > 0);
    const out_next: u64 = @intCast(out.get("next_offset").?.integer);
    try std.testing.expect(out_next <= out_total);
    try std.testing.expect(out_next > out_available);

    // An odd budget is split fairly, one byte per stream, and offsets stay raw
    // source bytes rather than escaped text length.
    const odd = try controlJson(&fixture, a, .{ .action = .logs, .id = id, .stdout_offset = out_available, .stderr_offset = err_available, .limit = 3 }, &cancel);
    const odd_out = odd.object.get("stdout").?.object;
    const odd_err = odd.object.get("stderr").?.object;
    const odd_out_next: u64 = @intCast(odd_out.get("next_offset").?.integer);
    const odd_err_next: u64 = @intCast(odd_err.get("next_offset").?.integer);
    try std.testing.expect(odd_out_next > out_available);
    try std.testing.expect(odd_err_next > err_available);
    try std.testing.expect(odd_out_next - out_available <= 2);
    try std.testing.expect(odd_err_next - err_available <= 1);

    // A cursor past the retained end is rejected, not silently clamped.
    const beyond = try controlResult(&fixture, a, .{ .action = .logs, .id = id, .stdout_offset = out_total + 1 }, &cancel);
    try std.testing.expect(beyond.is_error);

    // Unsafe bytes and backslashes are escaped in text while the cursors keep
    // counting the original bytes. Tab/newline are printable by the shared
    // renderer, so only the invalid byte and backslash grow the text.
    const unsafe_receipt = try startJson(&fixture, a, "printf 'a\\377b\\\\c\\td\\n'", 5000, 4096, &cancel);
    const unsafe_id = try receiptId(a, unsafe_receipt);
    _ = try waitTerminal(&fixture, a, unsafe_id, &cancel);
    const escaped = try controlJson(&fixture, a, .{ .action = .logs, .id = unsafe_id, .stdout_offset = 0, .stderr_offset = 0, .limit = 4096 }, &cancel);
    const escaped_out = escaped.object.get("stdout").?.object;
    const text = escaped_out.get("text").?.string;
    const raw_total: u64 = @intCast(escaped_out.get("total_bytes").?.integer);
    try std.testing.expectEqual(@as(u64, 8), raw_total);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\xff") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\\\") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\t') != null);
    try std.testing.expect(text.len > raw_total);
    try std.testing.expectEqual(raw_total, @as(u64, @intCast(escaped_out.get("next_offset").?.integer)));

    // Tiny/zero capacities must be reported truthfully, never as full output.
    const tiny_receipt = try startJson(&fixture, a, "printf 0123456789", 5000, 0, &cancel);
    const tiny_id = try receiptId(a, tiny_receipt);
    _ = try waitTerminal(&fixture, a, tiny_id, &cancel);
    const tiny = try controlJson(&fixture, a, .{ .action = .logs, .id = tiny_id, .stdout_offset = 0, .stderr_offset = 0, .limit = 4096 }, &cancel);
    const tiny_out = tiny.object.get("stdout").?.object;
    try std.testing.expectEqual(@as(u64, 10), @as(u64, @intCast(tiny_out.get("total_bytes").?.integer)));
    try std.testing.expectEqualStrings("", tiny_out.get("text").?.string);
    try std.testing.expect(tiny_out.get("lost_bytes").?.integer >= 10);
}

test "non-zero exit and stdin EOF are observed, not guessed" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: p.Cancellation = .{};

    // `cat` sees EOF immediately because stdin is /dev/null; the shell then
    // exits 7, which status must report without treating it as a tool failure.
    const receipt = try startJson(&fixture, a, "cat >/dev/null; exit 7", 5000, 4096, &cancel);
    const id = try receiptId(a, receipt);
    const terminal = try waitTerminal(&fixture, a, id, &cancel);
    try std.testing.expectEqualStrings("exited", stateOf(terminal));
    try std.testing.expectEqual(@as(i64, 7), terminal.object.get("exit_code").?.integer);
    try std.testing.expect(terminal.object.get("pid").?.integer > 1);
}

test "pre-cancel leaves no retained service; handshake cancel and startup timeout stay distinct" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var canceled_before: p.Cancellation = .{};
    canceled_before.cancel();
    const pre_cancel_result = try startText(&fixture, a, "printf NEVER", 5000, 4096, &canceled_before);
    try std.testing.expect(pre_cancel_result.is_error and pre_cancel_result.canceled);
    var cancel: p.Cancellation = .{};
    const after_pre_cancel = try controlJson(&fixture, a, .{ .action = .list }, &cancel);
    try std.testing.expectEqual(@as(i64, 0), after_pre_cancel.object.get("total").?.integer);

    // Test seam: hold the startup handshake so the caller token can be
    // delivered before fork/handoff. It must behave as caller cancellation.
    fixture.service.test_hold_handshake_ms = 300;
    var handshake_cancel: p.Cancellation = .{};
    const thread = try std.Thread.spawn(.{}, cancelAfter, .{ &handshake_cancel, 30 });
    defer thread.join();
    const handshake_result = try startText(&fixture, a, "printf HANDSHAKE", 5000, 4096, &handshake_cancel);
    try std.testing.expect(handshake_result.is_error and handshake_result.canceled);
    const after_handshake = try controlJson(&fixture, a, .{ .action = .list }, &cancel);
    try std.testing.expectEqual(@as(i64, 0), after_handshake.object.get("total").?.integer);

    // A startup timeout is a failed start, not cancellation, and does not
    // poison the manager for later ordinary starts.
    const timeout_result = try startText(&fixture, a, "printf TIMEOUT", 20, 4096, &cancel);
    try std.testing.expect(timeout_result.is_error and !timeout_result.canceled);
    const still_usable = try startJson(&fixture, a, "printf AFTER_TIMEOUT", 5000, 4096, &cancel);
    const usable_id = try receiptId(a, still_usable);
    _ = try waitTerminal(&fixture, a, usable_id, &cancel);
}

test "deterministic construction OOM fails before spawn and leaves no owned service" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();

    // Dedicated manager over the same real root/env but a failing allocator.
    // fail_index 0 makes the next deps allocation (Job construction) fail
    // deterministically; it is disabled right after so the same fixture can
    // prove recovery. No checkAllAllocationFailures loop forks real commands.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var oom_service: manager.BackgroundService = .{};
    oom_service.deps = .{
        .allocator = failing.allocator(),
        .io = fixture.io,
        .root = &fixture.root,
        .environment = &fixture.env,
    };
    defer oom_service.deinit();
    var cancel: p.Cancellation = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (oom_service.service().start(a, startArgs("printf OOM", 5000, 4096), &cancel)) |_| {
        return error.ExpectedOutOfMemory;
    } else |err| try std.testing.expectEqual(error.OutOfMemory, err);

    failing.fail_index = std.math.maxInt(usize);
    const recovered = try oom_service.service().start(a, startArgs("printf RECOVERED", 5000, 4096), &cancel);
    try std.testing.expect(!recovered.is_error);
    const receipt = try std.json.parseFromSliceLeaky(std.json.Value, a, recovered.text, .{ .allocate = .alloc_always });
    const id = try receiptId(a, receipt);
    _ = try waitTerminalOf(&oom_service, a, id, &cancel);
}

// Fails the first output allocation after the manager has built its owned job
// resources, before the worker is spawned. The manager deps allocator is the
// regular testing allocator, so a deps leak is reported by the test runner.
test "receipt allocator OOM leaves no registered job and no dependency leak" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var output = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = fixture.service.service().start(output.allocator(), startArgs("printf RECEIPT_OOM", 5000, 4096), &cancel);
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(usize, 0), output.allocated_bytes);

    const listed = try controlJson(&fixture, a, .{ .action = .list }, &cancel);
    try std.testing.expectEqual(@as(i64, 0), listed.object.get("total").?.integer);
    try std.testing.expectEqual(@as(usize, 0), listed.object.get("services").?.array.items.len);

    fixture.closeService();
    try std.testing.expectEqual(@as(usize, 0), fixture.service.jobs.items.len);
}

// Fresh fixture per index: fail_index counts from zero for the manager-owned
// allocator, so each iteration deterministically reaches one construction
// stage. After disabling the failure the same single owner must recover, stop
// and free everything exactly once.
test "owned construction failure indices stay leak-free and recoverable" {
    for (0..7) |fail_index| {
        var fixture: Fixture = undefined;
        try Fixture.init(&fixture);
        defer fixture.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var cancel: p.Cancellation = .{};

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        fixture.service.deps = .{
            .allocator = failing.allocator(),
            .io = fixture.io,
            .root = &fixture.root,
            .environment = &fixture.env,
        };
        const failed = fixture.service.service().start(a, startArgs("printf CONSTRUCT_FAIL", 5000, 4096), &cancel);
        try std.testing.expectError(error.OutOfMemory, failed);
        try std.testing.expectEqual(@as(usize, 0), fixture.service.jobs.items.len);

        failing.fail_index = std.math.maxInt(usize);
        const listed = try controlJson(&fixture, a, .{ .action = .list }, &cancel);
        try std.testing.expectEqual(@as(i64, 0), listed.object.get("total").?.integer);

        const recovered = try startJson(&fixture, a, "printf CONSTRUCT_OK", 5000, 4096, &cancel);
        const id = try receiptId(a, recovered);
        _ = try waitTerminal(&fixture, a, id, &cancel);
        const stopped = try controlJson(&fixture, a, .{ .action = .stop, .id = id }, &cancel);
        try std.testing.expect(!std.mem.eql(u8, stateOf(try statusService(a, stopped)), "running"));

        fixture.closeService();
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

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

test "future creation failure leaves no registered job" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: p.Cancellation = .{};

    var vtable = std.testing.io.vtable.*;
    vtable.concurrent = rejectConcurrent;
    var wrapped = std.testing.io;
    wrapped.vtable = &vtable;
    fixture.service.deps = .{
        .allocator = std.testing.allocator,
        .io = wrapped,
        .root = &fixture.root,
        .environment = &fixture.env,
    };

    const failed = fixture.service.service().start(a, startArgs("printf NO_FUTURE", 5000, 4096), &cancel);
    try std.testing.expectError(error.ConcurrencyUnavailable, failed);
    try std.testing.expectEqual(@as(usize, 0), fixture.service.jobs.items.len);

    const listed = try controlJson(&fixture, a, .{ .action = .list }, &cancel);
    try std.testing.expectEqual(@as(i64, 0), listed.object.get("total").?.integer);
    try std.testing.expectEqual(@as(usize, 0), listed.object.get("services").?.array.items.len);
}

test "TERM-ignoring service is escalated to KILL without caller cancellation" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: p.Cancellation = .{};

    const started = try fixture.service.service().start(a, .{
        .command = "trap '' TERM; printf KILL-READY; while :; do :; done",
        .startup_timeout_ms = 5000,
        .log_bytes = 4096,
        .term_grace_ms = 40,
        .cleanup_timeout_ms = 3000,
    }, &cancel);
    try std.testing.expect(!started.is_error);
    const receipt = try std.json.parseFromSliceLeaky(std.json.Value, a, started.text, .{ .allocate = .alloc_always });
    const id = try receiptId(a, receipt);

    // Wait for the real trap-installed marker before stopping; sleeping would
    // race the shell setup and could test a default TERM disposition instead.
    _ = try waitLogContains(&fixture, a, id, "KILL-READY", &cancel);
    const stopped = try controlJson(&fixture, a, .{ .action = .stop, .id = id }, &cancel);
    const service = try statusService(a, stopped);
    try std.testing.expectEqual(@as(i64, 9), service.object.get("signal").?.integer);
    try std.testing.expect(!cancel.isRequested());

    fixture.closeService();
}

test "stopping an already exited job keeps its exit record" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: p.Cancellation = .{};

    const receipt = try startJson(&fixture, a, "cat >/dev/null; exit 7", 5000, 4096, &cancel);
    const id = try receiptId(a, receipt);
    const terminal = try waitTerminal(&fixture, a, id, &cancel);
    try std.testing.expectEqualStrings("exited", stateOf(terminal));
    try std.testing.expectEqual(@as(i64, 7), terminal.object.get("exit_code").?.integer);

    // Repeated stop only reads the retained record; it must not rewrite the
    // natural exit code into a fabricated "stopped" state.
    const first = try controlJson(&fixture, a, .{ .action = .stop, .id = id }, &cancel);
    const first_service = try statusService(a, first);
    try std.testing.expectEqualStrings("exited", stateOf(first_service));
    try std.testing.expectEqual(@as(i64, 7), first_service.object.get("exit_code").?.integer);

    const second = try controlJson(&fixture, a, .{ .action = .stop, .id = id }, &cancel);
    const second_service = try statusService(a, second);
    try std.testing.expectEqualStrings("exited", stateOf(second_service));
    try std.testing.expectEqual(@as(i64, 7), second_service.object.get("exit_code").?.integer);
}

test "graceful stop keeps both TERM cleanup streams in the log ring" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: p.Cancellation = .{};

    // The trap writes to both pipes and exits 0, so a stopped job still owns
    // real post-TERM bytes on stdout and stderr.
    const receipt = try startJson(&fixture, a, "trap 'printf STOPPING-OUT; printf STOPPING-ERR >&2; exit 0' TERM; printf LOG-READY; while :; do :; done", 5000, 65536, &cancel);
    const id = try receiptId(a, receipt);

    // The live marker proves the trap is installed, not merely that a process exists.
    const running = try waitLogContains(&fixture, a, id, "LOG-READY", &cancel);
    try std.testing.expect(std.mem.indexOf(u8, running.object.get("text").?.string, "LOG-READY") != null);

    const stopped = try controlJson(&fixture, a, .{ .action = .stop, .id = id }, &cancel);
    const service = try statusService(a, stopped);
    try std.testing.expect(!std.mem.eql(u8, stateOf(service), "running"));
    // Stopping is the job owner's request, never the caller's token.
    try std.testing.expect(!cancel.isRequested());

    // Both cleanup writes must survive cancellation; their raw cursors count
    // source bytes (9+12 and 12), not escaped text length.
    const logs = try controlJson(&fixture, a, .{ .action = .logs, .id = id, .stdout_offset = 0, .stderr_offset = 0, .limit = 4096 }, &cancel);
    const out = logs.object.get("stdout").?.object;
    const err = logs.object.get("stderr").?.object;
    const out_text = out.get("text").?.string;
    const err_text = err.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, out_text, "LOG-READY") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_text, "STOPPING-OUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_text, "STOPPING-ERR") != null);
    try std.testing.expectEqual(@as(u64, 21), @as(u64, @intCast(out.get("total_bytes").?.integer)));
    try std.testing.expectEqual(@as(u64, 21), @as(u64, @intCast(out.get("next_offset").?.integer)));
    try std.testing.expectEqual(@as(u64, 12), @as(u64, @intCast(err.get("total_bytes").?.integer)));
    try std.testing.expectEqual(@as(u64, 12), @as(u64, @intCast(err.get("next_offset").?.integer)));

    fixture.closeService();
}
