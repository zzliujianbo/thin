//! Offline steering lifecycle probes; no shared test-root changes.
const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const cfg = @import("../core/config.zig");
const inbox = @import("../core/inbox.zig");
const Stage = enum { model, prepare, approval, result, stop, none, request, launch, late, execution, modal, modal_empty };
const Fake = struct {
    box: *r.Inbox,
    stage: Stage,
    queued: bool = false,
    calls: usize = 0,
    executions: usize = 0,
    users: usize = 0,
    cleared: usize = 0,
    results: usize = 0,
    submitted: usize = 0,
    payload: []const u8 = "change direction",
    fault: ?*std.testing.FailingAllocator = null,
    entered_modal: std.atomic.Value(bool) = .init(false),
    stop_ready: std.atomic.Value(bool) = .init(false),
    withdraw_permission: bool = false,
    withdraw_skipped: bool = false,
    withdraw_stop: bool = false,
    permissions: usize = 0,
    failed_withdrawals: usize = 0,
    fn queue(self: *Fake, stage: Stage) !void {
        if (self.queued or self.stage != stage) return;
        _ = try self.box.enqueue(std.testing.allocator, .steering, self.payload);
        self.queued = true;
    }
    fn call(raw: *anyopaque, _: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try std.testing.expectEqual(p.Purpose.normal, request.purpose);
        try self.queue(.model);
        if (self.calls > 1 or self.stage == .stop or self.stage == .none) return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} },
            .finish = .stop,
        } };
        return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{
                .{ .tool_call = .{ .id = "one", .name = "probe", .arguments = "{}" } },
                .{ .tool_call = .{ .id = "two", .name = "probe", .arguments = "{}" } },
            } },
            .finish = .tool_calls,
        } };
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        const self: *Fake = @ptrCast(@alignCast(raw));
        try self.queue(.prepare);
        return .{ .payload = raw, .description = "probe", .explicit_denial = if (self.stage == .approval) "ask" else null };
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.executions += 1;
        try self.queue(.execution);
        return .{ .text = "executed" };
    }
    fn authorize(raw: ?*anyopaque, permission: r.Permission, _: *const p.Cancellation) !r.Decision {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        self.permissions += 1;
        if (self.permissions > 1) return .allow_once;
        try self.queue(.approval);
        try std.testing.expect(permission.interrupt.?.hasSteering());
        return error.Steered;
    }
    fn event(raw: ?*anyopaque, ev: r.Event, _: *const p.Cancellation) !void {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        switch (ev) {
            .state => |state| {
                if (state == .calling_model) try self.queue(.request);
                if (state == .executing_tool) {
                    try self.queue(.launch);
                    if ((self.stage == .modal or self.stage == .modal_empty) and !self.entered_modal.load(.acquire)) {
                        try self.queue(.modal);
                        self.box.pauseClaims(true);
                        self.entered_modal.store(true, .release);
                    }
                }
            },
            .finished => try self.queue(.late),
            .tool_result => {
                if (self.withdraw_skipped and self.stage == .model) {
                    // Skip delivery must happen while the input is RESERVED:
                    // it cannot disappear between skipping and user commit.
                    const id = self.box.next_id;
                    if (self.box.withdraw(id)) |value| {
                        var entry = value;
                        entry.deinit();
                        return error.SkippedWithoutReservation;
                    }
                    self.failed_withdrawals += 1;
                }
                self.results += 1;
                try self.queue(.result);
            },
            .assistant_committed => |blocks| if (blocks.len == 1 and blocks[0] == .text) {
                try self.queue(.stop);
                if (self.stage == .stop) self.stop_ready.store(true, .release);
                if (self.withdraw_stop) if (self.box.snapshot().newest_id) |id| {
                    var entry = self.box.withdraw(id).?;
                    entry.deinit();
                };
                if (self.fault) |fault| {
                    fault.fail_index = fault.alloc_index;
                    fault.resize_fail_index = fault.resize_index;
                }
            },
            .user_committed => |user| {
                try std.testing.expectEqualStrings(self.payload, user.text);
                self.users += 1;
            },
            .permission_cleared => {
                self.cleared += 1;
                if (self.withdraw_permission) if (self.box.snapshot().newest_id) |id| {
                    var entry = self.box.withdraw(id).?;
                    entry.deinit();
                };
            },
            else => {},
        }
    }
    fn observe(raw: ?*anyopaque, observation: r.Observation) void {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        if (observation == .submitted) self.submitted += 1;
    }
    fn init(self: *Fake, config: *cfg.Config) !r.Runtime {
        var runtime = try r.Runtime.init(if (self.fault) |fault| fault.allocator() else std.testing.allocator, std.testing.io, config, .{ .context = self, .call_fn = call }, .{ .context = self, .schemas = &.{.{ .name = "probe", .description = "offline", .parameters_json = "{}" }}, .prepare_fn = prepare, .execute_fn = execute }, .{ .context = self, .emit_fn = event, .authorize_fn = authorize }, "");
        runtime.inbox = self.box;
        runtime.observer = .{ .context = self, .notify_fn = observe };
        return runtime;
    }
};
fn configValue() cfg.Config {
    return .{ .provider = .{ .base_url = "http://offline.invalid" }, .model = .{ .name = "fixture", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
}

fn enqueueOom(a: std.mem.Allocator) !void {
    var box: inbox.Inbox = .{};
    defer box.deinit();
    _ = box.enqueue(a, .steering, "text") catch |err| {
        try std.testing.expectEqual(@as(usize, 0), box.snapshot().steering);
        return err;
    };
}
