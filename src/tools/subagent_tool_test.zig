//! Offline regressions for the subagent tool surface: service-driven schema
//! publication, prepare/execute visibility gates, strict bounded arguments,
//! parent write/bash conflict protection, single-layer encoded JSON pass-through,
//! child-channel isolation and the Runtime hook forwarding. No network, real
//! config or filesystem.

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const image = @import("../core/image.zig");
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
    running: bool = false,
    plan: enum { ok, canceled, cleanup, failed } = .ok,
    wait: bool = true,
    last_message: []const u8 = "",

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

    fn run(raw: *anyopaque, _: std.mem.Allocator, _: sub.Request, _: *const p.Cancellation) anyerror!sub.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.runs += 1;
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

    fn active(raw: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.running;
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
            .active_fn = active,
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

test "subagent job tools publish exactly when the host service exists" {
    var config = fixtureConfig();
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = undefined };
    const base = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 4), base.len);
    for ([_][]const u8{ "read_file", "write_file", "bash", "memory" }, base) |name, schema| try std.testing.expectEqualStrings(name, schema.name);
    for (base) |schema| try std.testing.expect(!std.mem.eql(u8, schema.name, "subagent"));

    var fake: FakeService = .{};
    tools.subagent = fake.service();
    const parent = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 8), parent.len);
    for ([_][]const u8{ "read_file", "write_file", "bash", "memory", "subagent", "get_subagent_result", "send_subagent_message", "cancel_subagent" }, parent) |name, schema| try std.testing.expectEqualStrings(name, schema.name);
    // Same capability set keeps handing out the same read-only slice.
    try std.testing.expectEqual(parent.ptr, tools.executor().schemas.ptr);

    var image_dummy: u8 = 0;
    tools.image = .{ .context = &image_dummy, .inspect_fn = FakeImage.inspect, .check_fn = FakeImage.check };
    const with_image = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 9), with_image.len);
    try std.testing.expectEqualStrings("read_image", with_image[4].name);
    try std.testing.expectEqualStrings("subagent", with_image[5].name);

    tools.subagent = null;
    tools.image = null;
    tools.allow_memory = false;
    var channel: FakeChannel = .{};
    tools.parent_channel = .{ .context = &channel, .message_fn = FakeChannel.message };
    const child = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 4), child.len);
    for ([_][]const u8{ "read_file", "write_file", "bash", "message_parent" }, child) |name, schema| try std.testing.expectEqualStrings(name, schema.name);

    tools.parent_channel = null;
    const bare = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 3), bare.len);
    for (bare) |schema| try std.testing.expect(!std.mem.eql(u8, schema.name, "message_parent"));
}

test "missing service rejects forged parent job tools at prepare and execute" {
    const config = fixtureConfig();
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = undefined };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const executor = tools.executor();
    var cancel: p.Cancellation = .{};
    for ([_]struct { name: []const u8, args: []const u8, action: tools_mod.Action }{
        .{ .name = "subagent", .args = "{\"task\":\"x\"}", .action = .{ .subagent = .{ .task = "x" } } },
        .{ .name = "get_subagent_result", .args = "{\"id\":\"j\"}", .action = .{ .get_subagent_result = .{ .id = "j" } } },
        .{ .name = "send_subagent_message", .args = "{\"id\":\"j\",\"message\":\"m\"}", .action = .{ .send_subagent_message = .{ .id = "j", .message = "m" } } },
        .{ .name = "cancel_subagent", .args = "{\"id\":\"j\"}", .action = .{ .cancel_subagent = .{ .id = "j" } } },
    }) |case| {
        try std.testing.expectError(error.SubagentDisabled, executor.prepare_fn(executor.context, a, .{ .id = "c", .name = case.name, .arguments = case.args }));
        try std.testing.expectError(error.SubagentDisabled, tools.execute(a, case.action, &cancel));
    }
    try std.testing.expectError(error.SubagentMessageDisabled, executor.prepare_fn(executor.context, a, .{ .id = "c", .name = "message_parent", .arguments = "{\"message\":\"m\"}" }));
    try std.testing.expectError(error.SubagentMessageDisabled, tools.execute(a, .{ .message_parent = .{ .message = "m" } }, &cancel));
}

test "child-like tools reject recursion memory and cross-channel calls" {
    const config = fixtureConfig();
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = undefined, .allow_memory = false };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const executor = tools.executor();
    var cancel: p.Cancellation = .{};
    // Hiding a schema is not the boundary: every forged phase must refuse.
    try std.testing.expectError(error.SubagentDisabled, executor.prepare_fn(executor.context, a, .{ .id = "s", .name = "subagent", .arguments = "{\"task\":\"x\"}" }));
    try std.testing.expectError(error.MemoryDisabled, executor.prepare_fn(executor.context, a, .{ .id = "m", .name = "memory", .arguments = "{\"action\":\"list\"}" }));
    try std.testing.expectError(error.SubagentDisabled, tools.execute(a, .{ .subagent = .{ .task = "x" } }, &cancel));
    // self.memory is undefined: early rejection must precede any Store access.
    try std.testing.expectError(error.MemoryDisabled, tools.execute(a, .{ .memory = .{ .action = .list } }, &cancel));
    // A child cannot forge a parent job-control action either.
    try std.testing.expectError(error.SubagentDisabled, tools.execute(a, .{ .get_subagent_result = .{ .id = "j" } }, &cancel));

    var channel: FakeChannel = .{};
    tools.parent_channel = .{ .context = &channel, .message_fn = FakeChannel.message };
    const prepared = try executor.prepare_fn(executor.context, a, .{ .id = "p", .name = "message_parent", .arguments = "{\"message\":\"need input\",\"wait_for_reply\":true}" });
    try std.testing.expect(std.mem.indexOf(u8, prepared.description, "need input") == null);
    const result = try executor.execute_fn(executor.context, a, prepared, &cancel);
    try std.testing.expectEqualStrings("{\"delivered\":true}", result.text);
    try std.testing.expect(!result.memory_evidence);
    try std.testing.expectEqual(@as(usize, 1), channel.calls);
    try std.testing.expectEqualStrings("need input", channel.last_message);
    try std.testing.expect(channel.wait_for_reply);
}

test "parent get send and cancel stay pure in prepare and pass encoded JSON through" {
    var config = fixtureConfig();
    var fake: FakeService = .{};
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = undefined, .subagent = fake.service() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const executor = tools.executor();
    var cancel: p.Cancellation = .{};

    const get_prepared = try executor.prepare_fn(executor.context, a, .{ .id = "g", .name = "get_subagent_result", .arguments = "{\"id\":\"job-1\",\"wait\":false}" });
    try std.testing.expectEqual(@as(usize, 0), fake.checks);
    try std.testing.expectEqual(@as(usize, 0), fake.gets);
    try std.testing.expect(std.mem.indexOf(u8, get_prepared.description, "job-1") != null);
    const got = try executor.execute_fn(executor.context, a, get_prepared, &cancel);
    try std.testing.expectEqualStrings(payload_snapshot, got.text);
    try std.testing.expect(!got.memory_evidence);
    try std.testing.expect(!fake.wait);
    try std.testing.expectEqual(@as(usize, 1), fake.checks);

    const send_prepared = try executor.prepare_fn(executor.context, a, .{ .id = "s", .name = "send_subagent_message", .arguments = "{\"id\":\"job-1\",\"message\":\"private-message-body\"}" });
    try std.testing.expect(std.mem.indexOf(u8, send_prepared.description, "job-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, send_prepared.description, "private-message-body") == null);
    const sent = try executor.execute_fn(executor.context, a, send_prepared, &cancel);
    try std.testing.expectEqualStrings(payload_receipt, sent.text);
    try std.testing.expectEqualStrings("private-message-body", fake.last_message);
    try std.testing.expect(!sent.memory_evidence);

    const cancel_prepared = try executor.prepare_fn(executor.context, a, .{ .id = "c", .name = "cancel_subagent", .arguments = "{\"id\":\"job-1\"}" });
    try std.testing.expect(std.mem.indexOf(u8, cancel_prepared.description, "job-1") != null);
    const canceled = try executor.execute_fn(executor.context, a, cancel_prepared, &cancel);
    try std.testing.expectEqualStrings(payload_canceled, canceled.text);
    // A child job's canceled terminal state is not the parent call cancellation.
    try std.testing.expect(!canceled.canceled);
    try std.testing.expect(!canceled.is_error);
    try std.testing.expect(!canceled.memory_evidence);

    const start_prepared = try executor.prepare_fn(executor.context, a, .{ .id = "r", .name = "subagent", .arguments = "{\"task\":\"inspect release paths\",\"context\":\"parent-only-context-body\"}" });
    try std.testing.expect(std.mem.indexOf(u8, start_prepared.description, "inspect release paths") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_prepared.description, "parent-only-context-body") == null);
    try std.testing.expectEqual(@as(usize, 0), fake.runs);
    const started = try executor.execute_fn(executor.context, a, start_prepared, &cancel);
    try std.testing.expectEqualStrings(payload_running, started.text);
    try std.testing.expectEqual(@as(usize, 1), fake.runs);
    try std.testing.expect(!started.memory_evidence);
}

test "single-layer failure and cleanup results keep their flags" {
    var config = fixtureConfig();
    var fake: FakeService = .{ .plan = .cleanup };
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = undefined, .subagent = fake.service() };
    const cancel: p.Cancellation = .{};
    // A failing allocator must not hide the cleanup failure or its encoded text.
    const result = try tools.execute(FailingAllocator.allocator(), .{ .get_subagent_result = .{ .id = "job-1" } }, &cancel);
    try std.testing.expect(result.cleanup_failed);
    try std.testing.expect(result.is_error);
    try std.testing.expect(!result.canceled);
    try std.testing.expect(!result.memory_evidence);
    try std.testing.expectEqualStrings(payload_cleanup, result.text);

    fake.plan = .failed;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failed = try tools.execute(arena.allocator(), .{ .send_subagent_message = .{ .id = "job-1", .message = "m" } }, &cancel);
    try std.testing.expect(failed.is_error);
    try std.testing.expect(!failed.canceled);
    try std.testing.expectEqualStrings(payload_failed, failed.text);
}

test "parent write and bash are refused while a child job is active" {
    const config = fixtureConfig();
    var fake: FakeService = .{ .running = true };
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = undefined, .subagent = fake.service() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const executor = tools.executor();
    var cancel: p.Cancellation = .{};
    // prepare and direct execute both refuse; nothing is parsed or executed.
    try std.testing.expectError(error.SubagentActive, executor.prepare_fn(executor.context, a, .{ .id = "w", .name = "write_file", .arguments = "{\"path\":\"a\",\"content\":\"x\"}" }));
    try std.testing.expectError(error.SubagentActive, executor.prepare_fn(executor.context, a, .{ .id = "b", .name = "bash", .arguments = "{\"command\":\"true\"}" }));
    try std.testing.expectError(error.SubagentActive, tools.execute(a, .{ .write_file = .{ .path = "a", .content = "x" } }, &cancel));
    try std.testing.expectError(error.SubagentActive, tools.execute(a, .{ .bash = .{ .command = "true" } }, &cancel));
    // Communication and read paths are not blocked.
    const got = try tools.execute(a, .{ .get_subagent_result = .{ .id = "job-1" } }, &cancel);
    try std.testing.expectEqualStrings(payload_snapshot, got.text);

    fake.running = false;
    const prepared = try executor.prepare_fn(executor.context, a, .{ .id = "b", .name = "bash", .arguments = "{\"command\":\"true\"}" });
    try std.testing.expect(std.mem.indexOf(u8, prepared.description, "Run bash") != null);
}

test "job control arguments stay strict bounded and utf8 checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const limits: cfg.Limits = .{};
    try std.testing.expectError(error.UnknownField, tools_mod.parse(a, "get_subagent_result", "{\"id\":\"j\",\"model\":\"x\"}", limits));
    try std.testing.expectError(error.MissingField, tools_mod.parse(a, "get_subagent_result", "{}", limits));
    try std.testing.expectError(error.InvalidSubagentId, tools_mod.parse(a, "get_subagent_result", "{\"id\":\"a\\u0000b\"}", limits));
    try std.testing.expectError(error.InvalidSubagentId, tools_mod.parse(a, "get_subagent_result", "{\"id\":\"\"}", limits));
    try expectParseFailure(tools_mod.parse(a, "get_subagent_result", "{\"id\":\"j\",\"wait\":\"yes\"}", limits));
    const long_id: [sub.max_id_bytes + 1]u8 = @splat('i');
    const id_json = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{long_id[0..]});
    try std.testing.expectError(error.InvalidSubagentId, tools_mod.parse(a, "get_subagent_result", id_json, limits));

    try std.testing.expectError(error.MissingField, tools_mod.parse(a, "send_subagent_message", "{\"id\":\"j\"}", limits));
    try std.testing.expectError(error.InvalidSubagentMessage, tools_mod.parse(a, "send_subagent_message", "{\"id\":\"j\",\"message\":\"\"}", limits));
    try std.testing.expectError(error.InvalidSubagentMessage, tools_mod.parse(a, "send_subagent_message", "{\"id\":\"j\",\"message\":\"a\\u0000b\"}", limits));
    const long_message: [sub.max_message_bytes + 1]u8 = @splat('m');
    const message_json = try std.fmt.allocPrint(a, "{{\"id\":\"j\",\"message\":\"{s}\"}}", .{long_message[0..]});
    try std.testing.expectError(error.InvalidSubagentMessage, tools_mod.parse(a, "send_subagent_message", message_json, limits));

    try std.testing.expectError(error.UnknownField, tools_mod.parse(a, "cancel_subagent", "{\"id\":\"j\",\"force\":true}", limits));
    try std.testing.expectError(error.MissingField, tools_mod.parse(a, "cancel_subagent", "{}", limits));

    try std.testing.expectError(error.UnknownField, tools_mod.parse(a, "message_parent", "{\"message\":\"m\",\"topic\":\"x\"}", limits));
    try std.testing.expectError(error.MissingField, tools_mod.parse(a, "message_parent", "{}", limits));
    try std.testing.expectError(error.InvalidSubagentMessage, tools_mod.parse(a, "message_parent", "{\"message\":\"\"}", limits));
    try expectParseFailure(tools_mod.parse(a, "message_parent", "{\"message\":\"m\",\"wait_for_reply\":1}", limits));

    const parsed = try tools_mod.parse(a, "get_subagent_result", "{\"id\":\"job-1\"}", limits);
    try std.testing.expect(parsed == .get_subagent_result);
    try std.testing.expect(parsed.get_subagent_result.wait);
    const send = try tools_mod.parse(a, "send_subagent_message", "{\"id\":\"job-1\",\"message\":\"m\"}", limits);
    try std.testing.expectEqualStrings("m", send.send_subagent_message.message);
    const message = try tools_mod.parse(a, "message_parent", "{\"message\":\"m\"}", limits);
    try std.testing.expect(!message.message_parent.wait_for_reply);
}

test "job tool descriptions expose ids but never message or context bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secret = "super-secret-body";
    const cases = [_]struct { action: tools_mod.Action, must: []const u8 }{
        .{ .action = .{ .subagent = .{ .task = "inspect release paths", .context = secret } }, .must = "inspect release paths" },
        .{ .action = .{ .get_subagent_result = .{ .id = "job-7" } }, .must = "job-7" },
        .{ .action = .{ .send_subagent_message = .{ .id = "job-7", .message = secret } }, .must = "job-7" },
        .{ .action = .{ .cancel_subagent = .{ .id = "job-7" } }, .must = "job-7" },
    };
    for (cases) |case| {
        const description = try case.action.description(a);
        try std.testing.expect(std.mem.indexOf(u8, description, case.must) != null);
        try std.testing.expect(std.mem.indexOf(u8, description, secret) == null);
    }
    const child = try (tools_mod.Action{ .message_parent = .{ .message = secret } }).description(a);
    try std.testing.expect(std.mem.indexOf(u8, child, secret) == null);
    const task: [500]u8 = @splat('t');
    const long = try (tools_mod.Action{ .subagent = .{ .task = &task } }).description(a);
    try std.testing.expect(long.len < 300);
    try std.testing.expect(std.mem.endsWith(u8, long, "..."));
}

test "executor lifecycle hooks forward only when the service exists" {
    const config = fixtureConfig();
    var fake: FakeService = .{};
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = undefined, .subagent = fake.service() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cancel: p.Cancellation = .{};
    var executor = tools.executor();
    executor.begin_task_fn.?(executor.context, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.begins);
    const hint = (try executor.before_finish_fn.?(executor.context, arena.allocator(), &cancel)).?;
    try std.testing.expectEqualStrings("subagent job hint", hint);
    try executor.end_task_fn.?(executor.context, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.before_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.ends);

    // A child Tools has no service: no reset, no hint and no cleanup callback.
    tools.subagent = null;
    executor = tools.executor();
    executor.begin_task_fn.?(executor.context, &cancel);
    try std.testing.expect((try executor.before_finish_fn.?(executor.context, arena.allocator(), &cancel)) == null);
    try executor.end_task_fn.?(executor.context, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.begins);
    try std.testing.expectEqual(@as(usize, 1), fake.ends);
}
