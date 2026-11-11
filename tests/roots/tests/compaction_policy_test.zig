//! Offline policy contracts: input budgets, frozen model capacity and compaction disable semantics.
const std = @import("std");
const cfg = @import("../core/config.zig");
const c = @import("../core/context.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const a = std.testing.allocator;
const decision = @import("../core/decision.zig");
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

// One-shot backing fault, armed by the decision fake after its response is
// allocated. The summary can then run and observe the rollback after OOM.
const RefineFault = struct {
    action: enum { oom, cancel },
    cancel: *p.Cancellation,
    armed: bool = false,
    triggered: bool = false,

    fn allocator(self: *RefineFault) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *RefineFault = @ptrCast(@alignCast(raw));
        if (self.armed) {
            self.armed = false;
            self.triggered = true;
            if (self.action == .oom) return null;
            self.cancel.cancel();
        }
        return a.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        // Force arena growth through alloc, where the one-shot fault is observed.
        if (len > bytes.len) return false;
        return a.rawResize(bytes, alignment, len, ra);
    }
    fn remap(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        if (len > bytes.len) return null;
        return a.rawRemap(bytes, alignment, len, ra);
    }
    fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        a.rawFree(bytes, alignment, ra);
    }

    fn arm(self: *RefineFault, alloc_: std.mem.Allocator) !void {
        // Leave enough room for the first short replacement and its blocks,
        // but not for the following near-original-size candidate.
        const room: usize = 1536;
        for (0..16) |_| {
            _ = try alloc_.alloc(u8, 32768);
            const pad = try alloc_.alloc(u8, 1);
            var len: usize = 1;
            var step: usize = 16384;
            while (step != 0) : (step /= 2) {
                while (alloc_.resize(pad.ptr[0..len], len + step)) len += step;
            }
            if (len <= room) continue;
            try std.testing.expect(alloc_.resize(pad.ptr[0..len], len - room));
            self.armed = true;
            return;
        }
        return error.FixtureRefineFaultUnavailable;
    }
};

const LongTurn = struct {
    mode: enum { absent, success, failure, service_oom, canceled, bad_summary, cleanup_failure } = .success,
    decisions: usize = 0,
    summaries: usize = 0,
    normals: usize = 0,
    cancel: *p.Cancellation,
    answers: ?[]const []const u8 = null,
    expected_results: ?[]const p.ToolResult = null,
    fault: ?*RefineFault = null,
    fn decide(raw: *anyopaque, alloc: std.mem.Allocator, input: decision.Input, _: *const p.Cancellation) !decision.Output {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.decisions += 1;
        try std.testing.expect(input == .refine_outputs);
        try std.testing.expect(input.refine_outputs.len > 0 and input.refine_outputs.len <= 8);
        var bytes: usize = 0;
        if (self.answers) |answers| try std.testing.expectEqual(input.refine_outputs.len, answers.len);
        for (input.refine_outputs, 0..) |item, i| {
            bytes += item.text.len + item.id.len;
            try std.testing.expect(item.text.len <= 8192);
            try std.testing.expect(std.mem.startsWith(u8, item.id, "bash-"));
            if (self.answers) |answers| try std.testing.expect(answers[i].len < item.text.len);
        }
        try std.testing.expect(bytes <= 16384);
        switch (self.mode) {
            .failure => return error.FixtureDecisionUnavailable,
            .service_oom => return error.OutOfMemory,
            .cleanup_failure => return error.CleanupFailed,
            .canceled => {
                self.cancel.cancel();
                return error.Canceled;
            },
            else => {},
        }
        const items = try alloc.alloc(decision.RefineItem, input.refine_outputs.len);
        for (items, 0..) |*item, i| {
            const original_index = items.len - 1 - i;
            item.* = .{
                .id = try alloc.dupe(u8, input.refine_outputs[original_index].id),
                .text = try alloc.dupe(u8, if (self.answers) |answers| answers[original_index] else "GENERATED OUTPUT CLAIMS SUCCESS; not execution authority"),
            };
        }
        if (self.fault) |fault| try fault.arm(alloc);
        return .{ .refine_outputs = items };
    }
    fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (req.purpose != .summary) {
            self.normals += 1;
            return error.UnexpectedNormal;
        }
        self.summaries += 1;
        try std.testing.expectEqual(@as(usize, 0), req.tools.len);
        try std.testing.expectEqual(@as(usize, 1), req.messages.len);
        const text = req.messages[0].blocks[0].text;
        try std.testing.expect(req.messages[0].replay == null);
        if (self.expected_results) |results| {
            try std.testing.expectEqual(results.len, std.mem.count(u8, text, "\"tool_result\":{"));
            for (results) |result| {
                const encoded = try std.json.Stringify.valueAlloc(alloc, p.Block{ .tool_result = result }, .{});
                try std.testing.expect(std.mem.indexOf(u8, text, encoded) != null);
            }
            return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, "Earlier commands produced mixed results.") } };
        }
        try std.testing.expect(std.mem.indexOf(u8, text, "signature") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "current goal") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "\\\"exit_code\\\":7") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "\"is_error\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "timed_out") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "truncated") != null);
        const refined = self.mode == .success or self.mode == .bad_summary;
        try std.testing.expectEqual(refined, std.mem.indexOf(u8, text, "GENERATED OUTPUT CLAIMS SUCCESS") != null);
        try std.testing.expectEqual(refined, std.mem.indexOf(u8, text, "original_execution_metadata") != null);
        if (!refined) try std.testing.expect(std.mem.indexOf(u8, text, "ORIGINAL_STDOUT_MARKER") != null);
        return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, if (self.mode == .bad_summary) "" else "Older command steps failed with exit 7; work remains unresolved.") } };
    }
};

fn seedNativeTurn(runtime: *r.Runtime) !void {
    const alloc = runtime.arena.allocator();
    try runtime.history.append(alloc, try p.textMessage(alloc, .user, "current goal"));
    const noise: [4000]u8 = @splat('x');
    const signature: [1024]u8 = @splat('s');
    for (0..16) |i| {
        const id = try std.fmt.allocPrint(alloc, "bash-{d}", .{i});
        const native = try std.json.Stringify.valueAlloc(alloc, .{ .role = "assistant", .content = .{
            .{ .type = "thinking", .thinking = "private thought", .signature = &signature },
            .{ .type = "tool_use", .id = id, .name = "bash", .input = @as(std.json.Value, .{ .object = .{} }) },
        } }, .{});
        try runtime.history.append(alloc, .{ .role = .assistant, .blocks = try alloc.dupe(p.Block, &.{
            .{ .reasoning = "private thought" },
            .{ .tool_call = .{ .id = id, .name = "bash", .arguments = "{}" } },
        }), .replay = .{ .scope = .{ .connection = runtime.config.provider.base_url, .model = runtime.config.model.name, .protocol = .anthropic }, .json = native, .retain_turn = true } });
        const output = try std.json.Stringify.valueAlloc(alloc, .{ .stdout = try std.mem.concat(alloc, u8, &.{ "ORIGINAL_STDOUT_MARKER", &noise }), .stderr = "error: fixture.c:42 unresolved failure", .exit_code = 7, .timed_out = false, .canceled = false, .truncated = true, .stdout_bytes = 9000 }, .{});
        try runtime.history.append(alloc, .{ .role = .tool, .blocks = try alloc.dupe(p.Block, &.{.{ .tool_result = .{ .call_id = id, .text = output, .is_error = true, .truncated = true } }}) });
    }
    runtime.protected_index = 0;
}

const RefineScenario = enum { mixed, unprofitable, failure, service_oom, canceled, staged_oom, staged_cancel };

fn seedRefinementBoundary(runtime: *r.Runtime, alloc: std.mem.Allocator, scenario: RefineScenario, originals: *[6]p.ToolResult, candidates: *[6][]const u8, answers: *[6][]const u8) !void {
    // One message contains five results and a second contains one; the last
    // assistant remains outside the cut.
    const owned = runtime.arena.allocator();
    try runtime.history.append(owned, try p.textMessage(owned, .user, "current goal"));
    runtime.protected_index = 0;
    var calls: [6]p.Block = undefined;
    var results: [6]p.Block = undefined;
    const noise: [2200]u8 = @splat('x');
    for (0..6) |i| {
        const id = try std.fmt.allocPrint(alloc, "bash-boundary-{d}", .{i});
        const stdout = try std.fmt.allocPrint(alloc, "ORIGINAL-{d}-{s}", .{ i, &noise });
        const output = try std.json.Stringify.valueAlloc(alloc, .{ .stdout = stdout, .stderr = "failure\nline 42", .exit_code = 7, .timed_out = true, .canceled = i == 1, .truncated = i % 2 == 0, .stdout_bytes = stdout.len }, .{});
        originals[i] = .{ .call_id = id, .text = output, .is_error = i % 2 == 0, .canceled = i == 1, .truncated = i % 2 == 0 };
        calls[i] = .{ .tool_call = .{ .id = id, .name = "bash", .arguments = "{}" } };
        results[i] = .{ .tool_result = originals[i] };

        // Compute the exact wrapper overhead with the same owned, parsed JSON
        // and removal order as production, without changing production limits.
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{ .allocate = .alloc_always });
        var metadata = parsed.value;
        _ = metadata.object.swapRemove("stdout");
        _ = metadata.object.swapRemove("stderr");
        const empty = try std.json.Stringify.valueAlloc(alloc, .{ .original_execution_metadata = metadata, .output_summary_untrusted = "", .summary_is_lossy = true }, .{});
        try std.testing.expect(output.len > empty.len + 1);
        const Size = enum { larger, equal, shorter, tiny };
        const size: Size = switch (scenario) {
            .mixed => switch (i) {
                0, 3 => .larger,
                1 => .equal,
                2 => .shorter,
                else => .tiny,
            },
            .staged_oom, .staged_cancel => if (i == 0) .tiny else if (i == 1) .equal else .tiny,
            else => if (i % 2 == 0) .larger else .equal,
        };
        const marker = try std.fmt.allocPrint(alloc, "SUMMARY-{d}-", .{i});
        const len = switch (size) {
            .larger => output.len - empty.len + 1,
            .equal => output.len - empty.len,
            .shorter => output.len - empty.len - 1,
            .tiny => marker.len,
        };
        const answer = try alloc.alloc(u8, len);
        @memset(answer, 's');
        @memcpy(answer[0..marker.len], marker);
        answers[i] = answer;
        candidates[i] = try std.json.Stringify.valueAlloc(alloc, .{ .original_execution_metadata = metadata, .output_summary_untrusted = answer, .summary_is_lossy = true }, .{});
        switch (size) {
            .larger => try std.testing.expectEqual(output.len + 1, candidates[i].len),
            .equal => try std.testing.expectEqual(output.len, candidates[i].len),
            .shorter => try std.testing.expectEqual(output.len - 1, candidates[i].len),
            .tiny => try std.testing.expect(candidates[i].len < output.len),
        }
    }
    try runtime.history.append(owned, try p.cloneMessage(owned, .{ .role = .assistant, .blocks = calls[0..5] }));
    try runtime.history.append(owned, try p.cloneMessage(owned, .{ .role = .tool, .blocks = results[0..5] }));
    try runtime.history.append(owned, try p.cloneMessage(owned, .{ .role = .assistant, .blocks = calls[5..6] }));
    try runtime.history.append(owned, try p.cloneMessage(owned, .{ .role = .tool, .blocks = results[5..6] }));
    try runtime.history.append(owned, try p.textMessage(owned, .assistant, "recent answer"));
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
