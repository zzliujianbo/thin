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
    timeout_seen: bool = false,
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
        return .{ .payload = self, .description = args.command, .explicit_denial = "Fixture requires explicit approval; not executed.", .decision_input = .{ .command = .{ .command = args.command, .max_timeout_ms = 1000 } } };
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, prepared: r.Prepared, cancel: *const p.Cancellation) !r.Execution {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.executions += 1;
        if (self.execute_error) return error.CommandFailed;
        if (prepared.command_timeout) |timeout| self.timeout_seen = timeout == .milliseconds and timeout.milliseconds == 123;
        while (self.block and !cancel.isRequested()) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        return .{ .text = self.result_text, .cleanup_failed = self.cleanup, .canceled = cancel.isRequested() };
    }
    fn review(raw: *anyopaque, _: std.mem.Allocator, _: d.Input, _: *const p.Cancellation) !d.Output {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.reviewed += 1;
        if (self.review_error) |err| return err;
        return .{ .command = .{ .ask = true, .timeout = .{ .milliseconds = 123 } } };
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

test "local command unknown price keeps output, pairs checkpoint and next normal stays gated" {
    var fake: Fake = .{};
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.executeCommand("!printf hello", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expectEqual(@as(u32, 0), terminal.usage.normal_calls + terminal.usage.summary_calls);
    try std.testing.expect(!terminal.context_snapshot.?.known);
    try std.testing.expectEqualStrings(&output, runtime.messages()[2].blocks[0].tool_result.text);
    try std.testing.expect(!runtime.messages()[2].blocks[0].tool_result.truncated);
    try paired(&runtime);
    const bytes = try cp.encode(a, try runtime.exportCheckpoint());
    defer a.free(bytes);
    const decoded = try cp.decode(a, bytes);
    defer decoded.deinit();
    // Imported permission counters are not call-ID authority.
    var state = decoded.value;
    state.permission_id = 0;
    var restored = try fake.init(&config, false);
    defer restored.deinit();
    fake.runtime = &restored;
    try restored.restoreCheckpoint(state);
    try std.testing.expectEqual(r.Status.success, (try restored.executeCommand("!second", &cancel)).status);
    try std.testing.expect(!std.mem.eql(u8, restored.messages()[1].blocks[1].tool_call.id, restored.messages()[4].blocks[1].tool_call.id));
    try paired(&restored);
    const next = try restored.run("continue", &cancel);
    try std.testing.expectEqual(error.UnknownInputPriceThreshold, next.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.primary);
    // Independently encode the canonical next-normal history without sending it.
    const encoded = try chat.encode(a, .{ .scope = .{ .connection = "https://offline.invalid", .model = "offline", .protocol = .chat }, .system = restored.system, .messages = restored.messages(), .tools = &schemas, .purpose = .normal });
    defer a.free(encoded);
    const wire = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
    defer wire.deinit();
    inline for (.{ "max_tokens", "max_completion_tokens", "max_output_tokens" }) |key|
        try std.testing.expect(wire.value.object.get(key) == null);
    try std.testing.expectEqual(@as(usize, 3), fake.finished);
    try std.testing.expectEqual(fake.finished, fake.submitted);
}

test "local command default approval and explicit denial never execute" {
    for ([_]bool{ true, false }) |default_host| {
        var fake: Fake = .{ .approve = .deny };
        const config = configuration();
        var runtime = try fake.init(&config, default_host);
        defer runtime.deinit();
        fake.runtime = &runtime;
        var cancel: p.Cancellation = .{};
        _ = try runtime.executeCommand("!denied", &cancel);
        try paired(&runtime);
        try std.testing.expectEqual(@as(usize, 0), fake.executions + fake.primary);
        try std.testing.expect(runtime.messages()[2].blocks[0].tool_result.is_error);
        try std.testing.expectEqual(@as(usize, 1), fake.finished);
    }
}

test "local command decision ask timeout and failure preserve pairing" {
    for ([_]?anyerror{ null, error.AuxiliaryTimeout, error.CleanupFailed }) |failure| {
        var fake: Fake = .{ .review_error = failure };
        const config = configuration();
        var runtime = try fake.init(&config, false);
        defer runtime.deinit();
        fake.runtime = &runtime;
        runtime.decision_service = .{ .context = &fake, .decide_fn = Fake.review };
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.executeCommand("!review", &cancel);
        try paired(&runtime);
        try std.testing.expectEqual(@as(usize, 1), fake.reviewed);
        try std.testing.expectEqual(@as(usize, 1), fake.finished);
        try std.testing.expectEqual(@as(usize, 0), fake.primary);
        if (failure) |err| {
            try std.testing.expectEqual(if (err == error.CleanupFailed) error.CleanupFailed else error.DecisionUnavailable, terminal.detail.?);
            try std.testing.expectEqual(@as(usize, 0), fake.executions + fake.permissions);
        } else {
            try std.testing.expect(fake.timeout_seen);
            try std.testing.expectEqual(@as(usize, 1), fake.permissions);
        }
    }
}

test "local command cancellation timeout cleanup prepare and host errors finish once" {
    for (0..6) |mode| {
        var cancel: p.Cancellation = .{};
        var fake: Fake = .{ .cancel_on_approval = if (mode == 0) &cancel else null, .block = mode == 1, .cleanup = mode == 2, .prepare_error = mode == 3, .disconnect = mode == 4, .execute_error = mode == 5 };
        var config = configuration();
        if (mode == 1) config.limits.task_timeout_ms = 10;
        var runtime = try fake.init(&config, false);
        defer runtime.deinit();
        fake.runtime = &runtime;
        const terminal = try runtime.executeCommand("!fixture", &cancel);
        try paired(&runtime);
        try std.testing.expectEqual(@as(usize, 1), fake.finished);
        try std.testing.expectEqual(@as(usize, 0), fake.primary);
        if (mode == 0) try std.testing.expectEqual(r.Status.canceled, terminal.status);
        if (mode == 1) try std.testing.expectEqual(error.TaskTimeout, terminal.detail.?);
        if (mode == 2) {
            try std.testing.expect(runtime.poisoned);
            const before = fake.executions;
            _ = try runtime.executeCommand("!never", &cancel);
            try std.testing.expectEqual(before, fake.executions);
        }
        if (mode == 3 or mode == 4) try std.testing.expectEqual(@as(usize, 0), fake.executions);
        if (mode == 5) try std.testing.expectEqualStrings("CommandFailed", runtime.messages()[2].blocks[0].tool_result.text);
    }
}

test "local command validates before adding executable history" {
    var fake: Fake = .{};
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    var cancel: p.Cancellation = .{};
    for ([_][]const u8{ "! ", "no bang", "!x\x00", "!\xff" }) |text| {
        try std.testing.expectEqual(error.InvalidInput, (try runtime.executeCommand(text, &cancel)).detail.?);
    }
    var oversized: [32770]u8 = @splat('x');
    oversized[0] = '!';
    try std.testing.expectEqual(error.InputTooLarge, (try runtime.executeCommand(&oversized, &cancel)).detail.?);
    try std.testing.expectEqual(@as(usize, 0), runtime.messages().len);
    try std.testing.expectEqual(@as(usize, 5), fake.finished);
    cancel.cancel();
    try std.testing.expectEqual(r.Status.canceled, (try runtime.executeCommand("!not started", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 0), fake.executions + fake.primary);
}

test "local command matches trimmed UI prefix but preserves exact shell bytes" {
    var fake: Fake = .{};
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    var cancel: p.Cancellation = .{};
    const submitted = " \t! printf '%s' escaped\\ \n";
    const terminal = try runtime.executeCommand(submitted, &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expectEqual(@as(usize, 1), fake.executions);
    try std.testing.expectEqual(@as(usize, 0), fake.primary);
    const messages = runtime.messages();
    try std.testing.expectEqualStrings(submitted, messages[0].blocks[0].text);
    const arguments = messages[1].blocks[1].tool_call.arguments;
    const parsed = try std.json.parseFromSlice(struct { command: []const u8 }, a, arguments, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(" printf '%s' escaped\\ \n", parsed.value.command);
    try paired(&runtime);
}

test "local command retains response cap independently of input policy" {
    var fake: Fake = .{};
    var config = configuration();
    config.limits.max_response_bytes = 1024;
    config.limits.max_event_bytes = 1024;
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    const calibration = runtime.estimator;
    var cancel: p.Cancellation = .{};
    _ = try runtime.executeCommand("!bounded", &cancel);
    const result = runtime.messages()[2].blocks[0].tool_result;
    try std.testing.expectEqual(@as(usize, 1024), result.text.len);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualDeep(calibration, runtime.estimator);
    try std.testing.expectEqual(@as(usize, 0), fake.primary);
    try paired(&runtime);
}

test "local command dense imported IDs are indexed once and pre-cancel never allocates an ID" {
    var fake: Fake = .{};
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    const owned = runtime.arena.allocator();
    const count = 65536;
    const calls = try owned.alloc(p.Block, count);
    const results = try owned.alloc(p.Block, count);
    for (calls, results, 1..) |*call, *result, number| {
        const id = try std.fmt.allocPrint(owned, "local_command_{d}", .{number});
        call.* = .{ .tool_call = .{ .id = id, .name = "old_never_execute", .arguments = "{}" } };
        result.* = .{ .tool_result = .{ .call_id = id, .text = "archived" } };
    }
    try runtime.history.append(owned, .{ .role = .assistant, .blocks = calls });
    try runtime.history.append(owned, .{ .role = .tool, .blocks = results });
    var canceled: p.Cancellation = .{};
    canceled.cancel();
    const rejected = try runtime.executeCommand("!never", &canceled);
    try std.testing.expectEqual(r.Status.canceled, rejected.status);
    try std.testing.expectEqual(@as(u64, 0), runtime.permission_id);
    try std.testing.expectEqual(@as(usize, 2), runtime.messages().len);
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(r.Status.success, (try runtime.executeCommand("!new", &cancel)).status);
    const new_call = runtime.messages()[3].blocks[1].tool_call;
    try std.testing.expectEqualStrings("local_command_65537", new_call.id);
    try std.testing.expectEqualStrings(new_call.id, runtime.messages()[4].blocks[0].tool_result.call_id);
    try std.testing.expectEqual(@as(u64, 65538), runtime.permission_id);
    try std.testing.expectEqual(@as(usize, 1), fake.executions);
    try std.testing.expectEqual(@as(usize, 0), fake.primary);
    try std.testing.expectEqual(@as(usize, 2), fake.finished);
}

test "local command malformed output completes may-have-run and cleanup failure wins" {
    for ([_]bool{ false, true }) |cleanup| {
        var fake: Fake = .{ .result_text = "bad\xffoutput", .cleanup = cleanup };
        const config = configuration();
        var runtime = try fake.init(&config, false);
        defer runtime.deinit();
        fake.runtime = &runtime;
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.executeCommand("!invalid-output", &cancel);
        try std.testing.expectEqual(if (cleanup) error.CleanupFailed else error.InvalidToolOutput, terminal.detail.?);
        const result = runtime.messages()[2].blocks[0].tool_result;
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.text, "may have run") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.text, "Not executed") == null);
        try std.testing.expectEqual(cleanup, runtime.poisoned);
        try std.testing.expectEqual(@as(usize, 1), fake.executions);
        try std.testing.expectEqual(@as(usize, 1), fake.finished);
        try paired(&runtime);
    }
}

test "local command UTF8 truncation aligns multibyte scalars and rejects malformed prefixes" {
    // Exercise each split position of a four-byte scalar at the byte cap.
    for (1..4) |split| {
        var bytes: [1030]u8 = @splat('x');
        const start = 1024 - split;
        @memcpy(bytes[start..][0..4], "\xf0\x9f\x98\x80");
        var fake: Fake = .{ .result_text = &bytes };
        var config = configuration();
        config.limits.max_response_bytes = 1024;
        config.limits.max_event_bytes = 1024;
        var runtime = try fake.init(&config, false);
        defer runtime.deinit();
        fake.runtime = &runtime;
        var cancel: p.Cancellation = .{};
        try std.testing.expectEqual(r.Status.success, (try runtime.executeCommand("!utf8", &cancel)).status);
        const result = runtime.messages()[2].blocks[0].tool_result;
        try std.testing.expectEqual(start, result.text.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(result.text));
        try std.testing.expect(result.truncated);
        try paired(&runtime);
    }
    // Large malformed prefix: one bounded validation, no bytewise rescans.
    var bytes: [8192]u8 = @splat('x');
    bytes[0] = 0xff;
    var fake: Fake = .{ .result_text = &bytes };
    var config = configuration();
    config.limits.max_response_bytes = 4096;
    config.limits.max_event_bytes = 4096;
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(error.InvalidToolOutput, (try runtime.executeCommand("!bad-prefix", &cancel)).detail.?);
    try paired(&runtime);
}
