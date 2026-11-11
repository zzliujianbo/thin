//! Offline regressions for the in-process subagent seam: request/message
//! validation, bounded reports, service wrappers, the
//! ParentChannel, accepted-task hooks and the Runtime child-lifecycle contracts
//! (stop reminder, context-not-user, 3-reminder pause, end-task ordering and
//! cleanup domination). No network, App, UI or filesystem.

const std = @import("std");
const sub = @import("subagent.zig");
const p = @import("protocol.zig");
const runtime = @import("runtime.zig");
const cfg = @import("config.zig");
const knowledge = @import("knowledge.zig");

const FakeService = struct {
    begins: usize = 0,
    checks: usize = 0,
    runs: usize = 0,
    gets: usize = 0,
    sends: usize = 0,
    cancels: usize = 0,
    before_calls: usize = 0,
    ends: usize = 0,
    fail_get_cleanup: bool = false,
    end_error: ?anyerror = null,

    fn begin(raw: *anyopaque, _: *const p.Cancellation) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.begins += 1;
    }
    fn check(raw: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.checks += 1;
    }
    fn run(raw: *anyopaque, a: std.mem.Allocator, _: sub.Request, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.runs += 1;
        return .{ .text = try a.dupe(u8, "run") };
    }
    fn get(raw: *anyopaque, a: std.mem.Allocator, query: sub.Query, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.gets += 1;
        return .{ .text = try a.dupe(u8, if (query.wait) "get-wait" else "get"), .canceled = true, .cleanup_failed = self.fail_get_cleanup };
    }
    fn send(raw: *anyopaque, a: std.mem.Allocator, message: sub.Send, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.sends += 1;
        return .{ .text = try a.dupe(u8, message.message) };
    }
    fn cancel(raw: *anyopaque, a: std.mem.Allocator, request: sub.Cancel, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.cancels += 1;
        return .{ .text = try a.dupe(u8, request.id) };
    }
    fn before(raw: *anyopaque, a: std.mem.Allocator, _: *const p.Cancellation) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.before_calls += 1;
        return try a.dupe(u8, "child job hint");
    }
    fn end(raw: *anyopaque, _: *const p.Cancellation) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.ends += 1;
        if (self.end_error) |err| return err;
    }

    fn full(self: *@This()) sub.Service {
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
    reply: bool = false,

    fn message(raw: *anyopaque, a: std.mem.Allocator, request: sub.Message, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.reply = request.wait_for_reply;
        return .{ .text = try a.dupe(u8, "receipt"), .cleanup_failed = false };
    }
};

fn fixtureConfig() cfg.Config {
    return .{
        .provider = .{ .base_url = "https://fixture.invalid/v1" },
        .model = .{ .name = "fixture", .protocol = .chat, .context_tokens = 32768 },
        .limits = .{ .low_price_input = false },
    };
}

const Lifecycle = struct {
    hints: u8 = 0,
    hint_calls: usize = 0,
    begins: usize = 0,
    ends: usize = 0,
    before_calls: usize = 0,
    end_error: ?anyerror = null,
    finalized: usize = 0,
    user_sources: usize = 0,
    tool_sources: usize = 0,
    user_committed_events: usize = 0,
    finished: usize = 0,
    order_violation: bool = false,

    fn begin(raw: *anyopaque, _: *const p.Cancellation) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.begins += 1;
    }
    fn before(raw: *anyopaque, a: std.mem.Allocator, _: *const p.Cancellation) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.before_calls += 1;
        if (self.hints == 0) return null;
        self.hints -= 1;
        self.hint_calls += 1;
        return try a.dupe(u8, "Child job job-1 is still active; collect it with get_subagent_result.");
    }
    fn end(raw: *anyopaque, _: *const p.Cancellation) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.ends += 1;
        if (self.end_error) |err| return err;
    }
    fn retrieve(_: *anyopaque, a: std.mem.Allocator, _: []const u8, _: usize) anyerror![]const u8 {
        return try a.dupe(u8, "");
    }
    fn finalize(raw: *anyopaque, capture: *const knowledge.Capture, _: p.Protocol) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.finalized += 1;
        if (self.ends == 0 or self.finished != 0) self.order_violation = true;
        for (capture.sources.items) |source| switch (source.kind) {
            .user => self.user_sources += 1,
            .tool => self.tool_sources += 1,
            .assistant => {},
        };
    }
    fn emit(raw: ?*anyopaque, event: runtime.Event, _: *const p.Cancellation) anyerror!void {
        const self: *Lifecycle = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .user_committed => self.user_committed_events += 1,
            .finished => {
                self.finished += 1;
                if (self.ends == 0) self.order_violation = true;
            },
            else => {},
        }
    }
};

const ModelFake = struct {
    plan: enum { success, failure, tool_once } = .success,
    calls: usize = 0,
    fn call(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        switch (self.plan) {
            .success => return .{ .success = .{ .finish = .stop, .message = try p.textMessage(a, .assistant, "answer") } },
            .failure => return .{ .failure = .{ .kind = .model, .message = "fixture failure" } },
            .tool_once => if (self.calls == 1) {
                const blocks = try a.alloc(p.Block, 1);
                blocks[0] = .{ .tool_call = .{ .id = "call-1", .name = "bash", .arguments = "{\"command\":\"true\"}" } };
                return .{ .success = .{ .finish = .tool_calls, .message = .{ .role = .assistant, .blocks = blocks } } };
            } else return .{ .success = .{ .finish = .stop, .message = try p.textMessage(a, .assistant, "done") } },
        }
    }
};

fn lifecycleExecutor(life: *Lifecycle) runtime.Executor {
    return .{
        .context = life,
        .schemas = &.{},
        .prepare_fn = LifecyclePrepare,
        .execute_fn = LifecycleExecute,
        .begin_task_fn = Lifecycle.begin,
        .before_finish_fn = Lifecycle.before,
        .end_task_fn = Lifecycle.end,
    };
}

fn LifecyclePrepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !runtime.Prepared {
    return error.UnexpectedTool;
}
fn LifecycleExecute(_: *anyopaque, a: std.mem.Allocator, _: runtime.Prepared, _: *const p.Cancellation) !runtime.Execution {
    return .{ .text = try a.dupe(u8, "ok") };
}

const LifecyclePlan = enum { success, failure, canceled, paused };
