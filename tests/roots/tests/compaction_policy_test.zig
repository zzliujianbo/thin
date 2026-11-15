//! Offline policy contracts: input budgets, frozen model capacity and compaction disable semantics.
const std = @import("std");
const cfg = @import("../core/config.zig");
const c = @import("../core/context.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const a = std.testing.allocator;
const anthropic = @import("../llm/anthropic.zig");
const synthetic_replay = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"fixture thought\",\"signature\":\"fixture-stale-signature\"},{\"type\":\"text\",\"text\":\"retained answer\"},{\"type\":\"tool_use\",\"id\":\"completed-id\",\"name\":\"read_file\",\"input\":{}}]}";

const PrefixFake = struct {
    summaries: usize = 0,
    normal: usize = 0,
    fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try std.testing.expectEqualStrings("high", req.reasoning_effort.?);
        try std.testing.expectEqual(@as(?u32, 65536), req.model_output_tokens);
        const wire = try anthropic.encode(alloc, req);
        if (req.purpose == .summary) {
            self.summaries += 1;
            try std.testing.expect(std.mem.indexOf(u8, wire, "fixture-stale-signature") == null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "fixture thought") == null);
            try std.testing.expectEqual(@as(usize, 0), req.tools.len);
            try std.testing.expectEqual(@as(usize, 1), req.messages.len);
            for (req.messages[0].blocks) |block| try std.testing.expect(block == .text);
        } else {
            self.normal += 1;
            try std.testing.expect(c.hasSummaryPrefix(req.messages));
            try std.testing.expect(std.mem.indexOf(u8, wire, "fixture-stale-signature") == null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "fixture thought") == null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "retained answer") != null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "completed-id") != null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "completed result") != null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "new goal") != null);
        }
        return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, "Summary or final answer.") } };
    }
};

fn signedTail(protocol: p.Protocol) p.Message {
    return .{ .role = .assistant, .blocks = &.{
        .{ .reasoning = "fixture thought" },                                                 .{ .text = "retained answer" },
        .{ .tool_call = .{ .id = "completed-id", .name = "read_file", .arguments = "{}" } },
    }, .replay = .{ .scope = .{ .connection = "https://fixture.invalid/v1", .model = "fixture", .protocol = protocol }, .json = synthetic_replay } };
}

const completed_result: p.Message = .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "completed-id", .text = "completed result" } }} };

fn normalizedRestoreAllocation(alloc: std.mem.Allocator) !void {
    var config = configuration();
    config.model.protocol = .anthropic;
    config.model.reasoning.?.format = .anthropic;
    var fake: Fake = .{};
    var runtime = try r.Runtime.init(alloc, std.testing.io, &config, fake.model(), fake.executor(), .{}, "before");
    defer runtime.deinit();
    const system = runtime.system;
    var state = try runtime.checkpoint();
    state.system = "restored";
    state.messages = &.{
        .{ .role = .context, .blocks = &.{.{ .text = c.summary_marker ++ "fixture" }} },
        signedTail(.anthropic),
        completed_result,
    };
    runtime.restoreCheckpoint(state) catch |err| {
        try std.testing.expectEqual(system.ptr, runtime.system.ptr);
        try std.testing.expectEqual(@as(usize, 0), runtime.messages().len);
        try std.testing.expectEqual(@as(usize, 0), fake.normal + fake.summaries);
        try std.testing.expectEqualStrings(synthetic_replay, state.messages[1].replay.?.json);
        return err;
    };
    try std.testing.expect(runtime.messages()[1].replay == null);
    try std.testing.expectEqualStrings("restored", runtime.system);
}

fn configuration() cfg.Config {
    return .{ .provider = .{ .base_url = "https://fixture.invalid/v1" }, .model = .{
        .name = "fixture",
        .protocol = .chat,
        .context_tokens = 1000000,
        .output_tokens = 65536,
        .reasoning_effort = "high",
        .reasoning = .{ .format = .standard, .map = .{ .high = "high" } },
    }, .limits = .{ .low_price_input = false } };
}

fn windowForInputBudget(budget: u32) u32 {
    std.debug.assert(budget > 0);
    const room = @as(u64, budget) + 1;
    const window: u32 = @intCast(room + @min(cfg.Policy.safety_tokens, room / 7));
    std.debug.assert(@as(u64, window) - cfg.Policy.safetyTokens(window) - 1 == budget);
    return window;
}

const Fake = struct {
    normal: usize = 0,
    summaries: usize = 0,
    capacity: ?u32 = null,
    exhausted: bool = false,
    summary_text: ?[]const u8 = null,
    summary_fault: enum { none, empty, whitespace, non_stop, tool } = .none,
    fn model(self: *Fake) p.Model {
        return .{ .context = self, .call_fn = call };
    }
    fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        try std.testing.expectEqualStrings("high", req.reasoning_effort.?);
        if (req.purpose == .summary) {
            self.summaries += 1;
            self.capacity = req.model_output_tokens;
            if (self.exhausted) return .{ .failure = .{ .kind = .output_limit, .message = "fixture limit" } };
        } else self.normal += 1;
        if (req.purpose == .summary) switch (self.summary_fault) {
            .none => {},
            .empty, .whitespace => return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, if (self.summary_fault == .empty) "" else " \t\r\n") } },
            .non_stop => return .{ .success = .{ .finish = .tool_calls, .message = try p.textMessage(alloc, .assistant, "Incomplete summary") } },
            .tool => return .{ .success = .{ .finish = .stop, .message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "forbidden", .name = "bash", .arguments = "{}" } }} } } },
        };
        return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, self.summary_text orelse "Earlier work completed.") } };
    }
    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return error.UnexpectedTool;
    }
    fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        return error.UnexpectedTool;
    }
    fn executor(self: *Fake) r.Executor {
        return .{ .context = self, .schemas = &.{}, .prepare_fn = prepare, .execute_fn = execute };
    }
};

fn seed(runtime: *r.Runtime, text: []const u8) !void {
    const alloc = runtime.arena.allocator();
    try runtime.history.append(alloc, try p.textMessage(alloc, .user, "old task"));
    try runtime.history.append(alloc, try p.textMessage(alloc, .assistant, text));
    try runtime.history.append(alloc, try p.textMessage(alloc, .user, "recent task"));
    try runtime.history.append(alloc, try p.textMessage(alloc, .assistant, "recent answer"));
}
