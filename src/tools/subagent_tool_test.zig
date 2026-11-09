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

test "subagent job tools publish exactly when the host service exists" {
    var config = fixtureConfig();
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = undefined };
    const base = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 5), base.len);
    for ([_][]const u8{ "read_file", "write_file", "bash", "memory", "edit_file" }, base) |name, schema| try std.testing.expectEqualStrings(name, schema.name);
    for (base) |schema| try std.testing.expect(!std.mem.eql(u8, schema.name, "subagent"));

    var fake: FakeService = .{};
    tools.subagent = fake.service();
    const parent = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 9), parent.len);
    for ([_][]const u8{ "read_file", "write_file", "bash", "memory", "subagent", "get_subagent_result", "send_subagent_message", "cancel_subagent", "edit_file" }, parent) |name, schema| try std.testing.expectEqualStrings(name, schema.name);
    // Same capability set keeps handing out the same read-only slice.
    try std.testing.expectEqual(parent.ptr, tools.executor().schemas.ptr);
    try std.testing.expect(std.mem.indexOf(u8, parent[4].description, "Parent and child tools can run concurrently") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent[4].description, "coordinate overlapping changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent[4].parameters_json, "\"model\":{\"type\":[\"string\",\"null\"],\"minLength\":1,\"maxLength\":1089}") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent[4].parameters_json, "\"additionalProperties\":false") != null);
    const parsed_schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, parent[4].parameters_json, .{});
    defer parsed_schema.deinit();
    const model_schema = parsed_schema.value.object.get("properties").?.object.get("model").?.object;
    const model_type = model_schema.get("type").?;
    try std.testing.expect(model_type == .array);
    try std.testing.expectEqual(@as(usize, 2), model_type.array.items.len);
    try std.testing.expect(model_type.array.items[0] == .string);
    try std.testing.expectEqualStrings("string", model_type.array.items[0].string);
    try std.testing.expect(model_type.array.items[1] == .string);
    try std.testing.expectEqualStrings("null", model_type.array.items[1].string);
    const model_min = model_schema.get("minLength").?;
    const model_max = model_schema.get("maxLength").?;
    try std.testing.expect(model_min == .integer);
    try std.testing.expectEqual(@as(i64, 1), model_min.integer);
    try std.testing.expect(model_max == .integer);
    try std.testing.expectEqual(@as(i64, 1089), model_max.integer);
    // A terminal job is collected even with wait=false, so the report must be kept.
    try std.testing.expect(std.mem.indexOf(u8, parent[5].description, "collected and released even with wait=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent[5].description, "bounded terminal cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent[7].description, "already collected") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent[7].description, "bounded terminal cache") != null);

    var image_dummy: u8 = 0;
    tools.image = .{ .context = &image_dummy, .inspect_fn = FakeImage.inspect, .check_fn = FakeImage.check };
    const with_image = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 10), with_image.len);
    try std.testing.expectEqualStrings("edit_file", with_image[9].name);
    try std.testing.expectEqualStrings("read_image", with_image[4].name);
    try std.testing.expectEqualStrings("subagent", with_image[5].name);

    tools.subagent = null;
    tools.image = null;
    tools.allow_memory = false;
    var channel: FakeChannel = .{};
    tools.parent_channel = .{ .context = &channel, .message_fn = FakeChannel.message };
    const child = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 5), child.len);
    for ([_][]const u8{ "read_file", "write_file", "bash", "message_parent", "edit_file" }, child) |name, schema| try std.testing.expectEqualStrings(name, schema.name);

    tools.parent_channel = null;
    const bare = tools.executor().schemas;
    try std.testing.expectEqual(@as(usize, 4), bare.len);
    try std.testing.expectEqualStrings("edit_file", bare[3].name);
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
    try std.testing.expect(fake.last_model == null);
    try std.testing.expect(!started.memory_evidence);

    const selected = try executor.prepare_fn(executor.context, a, .{ .id = "r2", .name = "subagent", .arguments = "{\"task\":\"inspect\",\"model\":\"Provider/Org/Model-v1\"}" });
    _ = try executor.execute_fn(executor.context, a, selected, &cancel);
    try std.testing.expectEqualStrings("Provider/Org/Model-v1", fake.last_model.?);
    try std.testing.expectError(error.InvalidSubagentModel, executor.prepare_fn(executor.context, a, .{ .id = "bad", .name = "subagent", .arguments = "{\"task\":\"x\",\"model\":\"bad\"}" }));
    try std.testing.expectError(error.InvalidSubagentModel, tools.execute(a, .{ .subagent = .{ .task = "x", .model = "bad" } }, &cancel));
    try std.testing.expectEqual(@as(usize, 2), fake.runs);
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

test "parent write and bash execute with an uncollected child" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, io, buffer[0..n]);
    defer root.deinit();
    var config = fixtureConfig();
    var store = mem.Store.init(&root, config.limits);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var fake: FakeService = .{};
    var tools: Tools = .{ .root = &root, .memory = &store, .config = &config, .environment = &env, .subagent = fake.service() };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const executor = tools.executor();
    const cancel: p.Cancellation = .{};
    const started = try tools.execute(a, .{ .subagent = .{ .task = "work" } }, &cancel);
    try std.testing.expectEqualStrings(payload_running, started.text);
    const write = try executor.prepare_fn(executor.context, a, .{ .id = "w", .name = "write_file", .arguments = "{\"path\":\"parent.txt\",\"content\":\"parent content\"}" });
    const written = try executor.execute_fn(executor.context, a, write, &cancel);
    try std.testing.expect(!written.is_error);
    const bash = try executor.prepare_fn(executor.context, a, .{ .id = "b", .name = "bash", .arguments = "{\"command\":\"printf command > command.txt\"}" });
    try std.testing.expect(bash.explicit_denial == null);
    const ran = try executor.execute_fn(executor.context, a, bash, &cancel);
    try std.testing.expect(!ran.is_error);
    const parent = try tmp.dir.readFileAlloc(io, "parent.txt", a, .limited(100));
    try std.testing.expectEqualStrings("parent content", parent);
    const command = try tmp.dir.readFileAlloc(io, "command.txt", a, .limited(100));
    try std.testing.expectEqualStrings("command", command);
    try std.testing.expectEqual(@as(usize, 0), fake.gets);
    const got = try tools.execute(a, .{ .get_subagent_result = .{ .id = "job-1" } }, &cancel);
    try std.testing.expectEqualStrings(payload_snapshot, got.text);
}

test "subagent model references are strict and preserve maximum escaped envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const limits: cfg.Limits = .{};
    const omitted = try tools_mod.parse(a, "subagent", "{\"task\":\"x\"}", limits);
    try std.testing.expect(omitted.subagent.model == null);
    const null_model = try tools_mod.parse(a, "subagent", "{\"task\":\"x\",\"model\":null}", limits);
    try std.testing.expect(null_model.subagent.model == null);
    for ([_][]const u8{
        "{\"task\":\"x\",\"model\":true}",
        "{\"task\":\"x\",\"model\":false}",
        "{\"task\":\"x\",\"model\":1}",
        "{\"task\":\"x\",\"model\":1.5}",
        "{\"task\":\"x\",\"model\":[true]}",
        "{\"task\":\"x\",\"model\":{}}",
    }) |json| {
        try std.testing.expectError(error.UnexpectedToken, tools_mod.parse(a, "subagent", json, limits));
    }
    try std.testing.expectError(error.InvalidSubagentModel, tools_mod.parse(a, "subagent", "{\"task\":\"x\",\"model\":[]}", limits));
    try std.testing.expectError(error.DuplicateField, tools_mod.parse(a, "subagent", "{\"task\":\"x\",\"model\":null,\"model\":\"p/m\"}", limits));
    try std.testing.expectError(error.UnknownField, tools_mod.parse(a, "subagent", "{\"task\":\"x\",\"unknown\":1}", limits));
    for ([_][]const u8{ "", "p", "/m", "p/", "bad alias/m", "p/m\x00n", "p/m\n", "p/\xff" }) |model| {
        try std.testing.expectError(error.InvalidSubagentModel, sub.validate(.{ .task = "x", .model = model }));
    }
    try std.testing.expectError(error.InvalidSubagentModel, tools_mod.parse(a, "subagent", "{\"task\":\"x\",\"model\":\"p/m\\u0000\"}", limits));
    try std.testing.expectError(error.InvalidSubagentModel, tools_mod.parse(a, "subagent", "{\"task\":\"x\",\"model\":\"\"}", limits));
    const provider: [65]u8 = @splat('a');
    const raw: [1025]u8 = @splat('m');
    const over_provider = try std.fmt.allocPrint(a, "{s}/m", .{&provider});
    const over_raw = try std.fmt.allocPrint(a, "p/{s}", .{&raw});
    const over_all = try std.fmt.allocPrint(a, "{s}/{s}", .{ &provider, raw[0..1024] });
    for ([_][]const u8{ over_provider, over_raw, over_all }) |model| {
        try std.testing.expectError(error.InvalidSubagentModel, sub.validate(.{ .task = "x", .model = model }));
    }

    const escaped_task = try a.alloc(u8, 6 * sub.max_task_bytes);
    const escaped_context = try a.alloc(u8, 6 * sub.max_context_bytes);
    const escaped_model = try a.alloc(u8, 6 * sub.max_model_bytes);
    for (0..sub.max_task_bytes) |i| @memcpy(escaped_task[i * 6 ..][0..6], "\\u0074");
    for (0..sub.max_context_bytes) |i| @memcpy(escaped_context[i * 6 ..][0..6], "\\u0063");
    for (0..sub.max_model_bytes) |i| @memcpy(escaped_model[i * 6 ..][0..6], if (i == 64) "\\u002f" else "\\u0061");
    const json = try std.fmt.allocPrint(a, "{{\"task\":\"{s}\",\"context\":\"{s}\",\"model\":\"{s}\"}}", .{ escaped_task, escaped_context, escaped_model });
    const max = try tools_mod.parse(a, "subagent", json, limits);
    try std.testing.expectEqual(@as(usize, sub.max_model_bytes), max.subagent.model.?.len);
    const expected = try a.alloc(u8, sub.max_model_bytes);
    @memset(expected, 'a');
    expected[64] = '/';
    try std.testing.expectEqualStrings(expected, max.subagent.model.?);
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

test "pre-canceled write and bash perform no side effects" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, io, buffer[0..n]);
    defer root.deinit();
    var config = fixtureConfig();
    var store = mem.Store.init(&root, config.limits);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var tools: Tools = .{ .root = &root, .memory = &store, .config = &config, .environment = &env };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const canceled: p.Cancellation = .{ .requested = .init(true) };
    const write = try tools.execute(a, .{ .write_file = .{ .path = "canceled-write.txt", .content = "x" } }, &canceled);
    try std.testing.expect(write.canceled and write.is_error);
    const bash = try tools.execute(a, .{ .bash = .{ .command = "touch canceled-bash.txt" } }, &canceled);
    try std.testing.expect(bash.canceled and bash.is_error);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "canceled-write.txt", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "canceled-bash.txt", .{}));
}
