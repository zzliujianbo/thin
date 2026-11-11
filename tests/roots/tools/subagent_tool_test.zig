//! Offline regressions for the subagent tool surface: service-driven schema
//! publication, prepare/execute visibility gates, strict bounded arguments,
//! parent write/bash with uncollected jobs, single-layer encoded JSON pass-through,
//! child-channel isolation and the Runtime hook forwarding. No network, real
//! config or filesystem outside the temporary root.

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const image = @import("../core/image.zig");
const mem = @import("memory.zig");
const sub = @import("../core/subagent.zig");
const tools_mod = @import("tools.zig");

const Tools = tools_mod.Tools;

// The App owns encoding. These fixtures are already-encoded tool-result JSON;
// Tools must pass them through without re-encoding or re-truncation.
const payload_running = "{\"id\":\"job-1\",\"status\":\"running\"}";
const payload_snapshot = "{\"id\":\"job-1\",\"status\":\"running\",\"messages\":[],\"progress\":null}";
const payload_receipt = "{\"id\":\"job-1\",\"delivered\":true}";
const payload_canceled = "{\"id\":\"job-1\",\"status\":\"canceled\",\"report\":\"child canceled\"}";
const payload_cleanup = "{\"status\":\"failed\",\"cleanup_failed\":true}";
const payload_failed = "{\"status\":\"failed\",\"report\":\"child failed\"}";

const FakeService = struct {
    runs: usize = 0,
    checks: usize = 0,
    begins: usize = 0,
    gets: usize = 0,
    sends: usize = 0,
    cancels: usize = 0,
    before_calls: usize = 0,
    ends: usize = 0,
    plan: enum { ok, canceled, cleanup, failed } = .ok,
    wait: bool = true,
    last_message: []const u8 = "",
    last_model: ?[]const u8 = null,

    fn begin(raw: *anyopaque, _: *const p.Cancellation) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.begins += 1;
    }

    fn check(raw: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.checks += 1;
    }

    fn encoded(self: *@This(), ok: []const u8) sub.Result {
        return switch (self.plan) {
            .ok => .{ .text = ok },
            .canceled => .{ .text = payload_canceled },
            .cleanup => .{ .text = payload_cleanup, .cleanup_failed = true },
            .failed => .{ .text = payload_failed, .is_error = true },
        };
    }

    fn run(raw: *anyopaque, _: std.mem.Allocator, request: sub.Request, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.runs += 1;
        self.last_model = request.model;
        return self.encoded(payload_running);
    }

    fn get(raw: *anyopaque, _: std.mem.Allocator, query: sub.Query, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.gets += 1;
        self.wait = query.wait;
        return self.encoded(payload_snapshot);
    }

    fn send(raw: *anyopaque, _: std.mem.Allocator, message: sub.Send, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.sends += 1;
        self.last_message = message.message;
        return self.encoded(payload_receipt);
    }

    fn cancel(raw: *anyopaque, _: std.mem.Allocator, _: sub.Cancel, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.cancels += 1;
        return self.encoded(payload_canceled);
    }

    fn before(raw: *anyopaque, a: std.mem.Allocator, _: *const p.Cancellation) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.before_calls += 1;
        return try a.dupe(u8, "subagent job hint");
    }

    fn end(raw: *anyopaque, _: *const p.Cancellation) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.ends += 1;
    }

    fn service(self: *@This()) sub.Service {
        return .{
            .context = self,
            .run_fn = run,
            .begin_task_fn = begin,
            .check_fn = check,
            .get_fn = get,
            .send_fn = send,
            .cancel_fn = cancel,
            .before_finish_fn = before,
            .end_task_fn = end,
        };
    }
};

const FakeChannel = struct {
    calls: usize = 0,
    last_message: []const u8 = "",
    wait_for_reply: bool = false,

    fn message(raw: *anyopaque, a: std.mem.Allocator, request: sub.Message, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.last_message = request.message;
        self.wait_for_reply = request.wait_for_reply;
        return .{ .text = try a.dupe(u8, "{\"delivered\":true}") };
    }
};

const FakeImage = struct {
    fn inspect(_: *anyopaque, a: std.mem.Allocator, _: image.Input, _: *const p.Cancellation) anyerror!image.Output {
        return .{ .text = try a.dupe(u8, "fixture"), .usage = .{} };
    }
    fn check(_: *anyopaque) anyerror!void {}
};

/// Allocation always fails: proves the mapping path adds none and cannot mask a
/// cleanup failure with an OOM.
const FailingAllocator = struct {
    var dummy: u8 = 0;
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        return null;
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

    fn allocator() std.mem.Allocator {
        return .{ .ptr = &dummy, .vtable = &vtable };
    }
};

fn fixtureConfig() cfg.Config {
    return .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
}

fn expectParseFailure(result: anytype) !void {
    if (result) |_| return error.ExpectedParseFailure else |_| {}
}
