//! Offline local !command contract; no primary client, credentials or network.
const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const cfg = @import("../core/config.zig");
const d = @import("../core/decision.zig");
const cp = @import("../core/checkpoint.zig");
const chat = @import("../llm/chat.zig");
const a = std.testing.allocator;
const output: [4096]u8 = @splat('x');
const schemas = [_]p.ToolSchema{.{ .name = "bash", .description = "fixture", .parameters_json = "{\"type\":\"object\"}" }};

const Fake = struct {
    primary: usize = 0,
    executions: usize = 0,
    permissions: usize = 0,
    finished: usize = 0,
    submitted: usize = 0,
    reviewed: usize = 0,
    approve: r.Decision = .allow_once,
    review_error: ?anyerror = null,
    prepare_error: bool = false,
    block: bool = false,
    cleanup: bool = false,
    cancel_on_approval: ?*p.Cancellation = null,
    disconnect: bool = false,
    runtime: ?*r.Runtime = null,
    execute_error: bool = false,
    result_text: []const u8 = &output,
    fn model(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.primary += 1;
        return error.NoPrimaryClient;
    }
    fn prepare(raw: *anyopaque, alloc: std.mem.Allocator, call: p.ToolCall) !r.Prepared {
        const self: *Fake = @ptrCast(@alignCast(raw));
        try std.testing.expectEqualStrings("bash", call.name);
        const args = try std.json.parseFromSliceLeaky(struct { command: []const u8 }, alloc, call.arguments, .{});
        try std.testing.expect(args.command.len != 0);
        if (self.prepare_error) return error.BadCommand;
        return .{ .payload = self, .description = args.command, .explicit_denial = "Fixture requires explicit approval; not executed.", .decision_input = .{ .command = .{ .command = args.command } } };
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, cancel: *const p.Cancellation) !r.Execution {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.executions += 1;
        if (self.execute_error) return error.CommandFailed;
        while (self.block and !cancel.isRequested()) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        return .{ .text = self.result_text, .cleanup_failed = self.cleanup, .canceled = cancel.isRequested() };
    }
    fn review(raw: *anyopaque, _: std.mem.Allocator, input: d.Input, _: *const p.Cancellation) !d.Output {
        const self: *Fake = @ptrCast(@alignCast(raw));
        try std.testing.expect(input == .command);
        try std.testing.expectEqualStrings("review", input.command.command);
        try std.testing.expect(input.command.risk == null);
        try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(input.command)).@"struct".field_names.len);
        try std.testing.expectEqual(@as(usize, 0), self.primary + self.permissions + self.executions);
        self.reviewed += 1;
        if (self.review_error) |err| return err;
        return .{ .command = .{ .ask = true } };
    }
    fn authorize(raw: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        self.permissions += 1;
        if (self.cancel_on_approval) |cancel| cancel.cancel();
        return self.approve;
    }
    fn event(raw: ?*anyopaque, ev: r.Event, cancel: *const p.Cancellation) !void {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        if (ev == .finished) self.finished += 1;
        if (ev == .assistant_committed) {
            var nested: p.Cancellation = .{};
            try std.testing.expectError(error.Busy, self.runtime.?.executeCommand("!old must not run", &nested));
            if (self.disconnect) return error.HostDisconnected;
        }
        _ = cancel;
    }
    fn observe(raw: ?*anyopaque, observation: r.Observation) void {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        if (observation == .submitted) self.submitted += 1;
    }
    fn init(self: *Fake, config: *const cfg.Config, default_host: bool) !r.Runtime {
        var runtime = try r.Runtime.init(a, std.testing.io, config, .{ .context = self, .call_fn = model }, .{ .context = self, .schemas = &schemas, .prepare_fn = prepare, .execute_fn = execute }, .{ .context = self, .emit_fn = event, .authorize_fn = if (default_host) (r.Host{}).authorize_fn else authorize }, "");
        runtime.observer = .{ .context = self, .notify_fn = observe };
        return runtime;
    }
};
fn configuration() cfg.Config {
    return .{ .provider = .{ .base_url = "https://offline.invalid" }, .model = .{ .name = "offline", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .compaction_enabled = false } };
}
fn paired(runtime: *r.Runtime) !void {
    var calls: usize = 0;
    var results: usize = 0;
    for (runtime.messages(), 0..) |message, i| {
        try std.testing.expect(message.replay == null);
        for (message.blocks) |block| {
            if (block == .tool_call) {
                calls += 1;
                var matches: usize = 0;
                for (runtime.messages()[i + 1 ..]) |later| for (later.blocks) |result| {
                    if (result == .tool_result and std.mem.eql(u8, block.tool_call.id, result.tool_result.call_id)) matches += 1;
                };
                try std.testing.expectEqual(@as(usize, 1), matches);
            }
            if (block == .tool_result) results += 1;
        }
    }
    try std.testing.expectEqual(calls, results);
}
