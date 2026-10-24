//! Offline regressions for the application-level async subagent host. No real
//! API, credentials, external network or process launching is used. Child
//! models are injected through the private test seam; production configuration
//! never exposes that switch.

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const r = @import("../core/runtime.zig");
const http = @import("../llm/http.zig");
const subagent = @import("../core/subagent.zig");
const service_mod = @import("../app/subagent_service.zig");
const SubagentService = service_mod.SubagentService;
const tools_mod = @import("../tools/tools.zig");
const mem = @import("../tools/memory.zig");

const Stub = struct {
    fn call(_: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        return error.UnexpectedRequest;
    }
    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return error.UnexpectedTool;
    }
    fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        return error.UnexpectedTool;
    }
};

const Behavior = enum { text, tool_then_text, wait_for_cancel, ask_parent, progress_flood, steer_skip_write, progress_loop };

/// Assistant tool-call message owned by the caller's arena. The Runtime validates
/// the response after `call` returns, so a stack temporary would dangle.
fn toolCallMessage(a: std.mem.Allocator, id: []const u8, name: []const u8, arguments: []const u8) !p.Message {
    const blocks = try a.alloc(p.Block, 1);
    blocks[0] = .{ .tool_call = .{ .id = id, .name = name, .arguments = arguments } };
    return .{ .role = .assistant, .blocks = blocks };
}

const FakeModel = struct {
    io: std.Io,
    calls: usize = 0,
    behavior: Behavior = .text,
    parent_cancel: ?*const p.Cancellation = null,
    parent_was_requested: bool = false,
    saw_child_mode: bool = false,
    saw_replay: bool = false,
    config_protocol: p.Protocol = .auto,
    report_text: []const u8 = "child report",
    request_protocol: p.Protocol = .auto,
    saw_steering: bool = false,
    saw_reply: bool = false,
    saw_progress: bool = false,
    saw_skip: bool = false,
    entered: std.atomic.Value(bool) = .init(false),
    // progress_flood only: set once the child has observed the queue-full result,
    // so the parent can ack without racing the child's ninth post.
    progress_flood_checked: std.atomic.Value(bool) = .init(false),
    hold: std.atomic.Value(bool) = .init(false),

    fn make(raw: *anyopaque, _: std.mem.Allocator, config: *const cfg.Config) !p.Model {
        const self: *FakeModel = @ptrCast(@alignCast(raw));
        self.config_protocol = config.model.protocol;
        return .{ .context = self, .call_fn = call };
    }

    fn lastToolText(request: p.Request) ?[]const u8 {
        var index = request.messages.len;
        while (index > 0) {
            index -= 1;
            const message = request.messages[index];
            if (message.role != .tool) continue;
            for (message.blocks) |block| switch (block) {
                .tool_result => |result| return result.text,
                else => {},
            };
        }
        return null;
    }

    fn call(raw: *anyopaque, a: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *FakeModel = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.entered.store(true, .release);
        while (self.hold.load(.acquire)) {
            std.Io.sleep(self.io, .fromMilliseconds(2), .awake) catch break;
        }
        self.request_protocol = request.scope.protocol;
        if (std.mem.indexOf(u8, request.system, "Subagent mode") != null) self.saw_child_mode = true;
        for (request.messages) |message| {
            if (message.replay != null) self.saw_replay = true;
            for (message.blocks) |block| switch (block) {
                .text => |text| {
                    if (message.role == .user and std.mem.indexOf(u8, text, "STEER-MARKER") != null) self.saw_steering = true;
                },
                else => {},
            };
        }
        switch (self.behavior) {
            .wait_for_cancel => {
                const cancel = request.cancellation.?;
                while (!cancel.isRequested()) {
                    std.Io.sleep(self.io, .fromMilliseconds(2), .awake) catch break;
                }
                if (self.parent_cancel) |parent| self.parent_was_requested = parent.isRequested();
                return .{ .failure = .{ .kind = .canceled, .message = "fixture canceled", .usage = .{ .input_tokens = 1, .output_tokens = 1 } } };
            },
            .tool_then_text => {
                const has_result = for (request.messages) |message| {
                    if (message.role == .tool) break true;
                } else false;
                if (!has_result) return .{ .success = .{
                    .message = try toolCallMessage(a, "fixture-call", "read_file", "{\"path\":\"fixture.txt\"}"),
                    .finish = .tool_calls,
                    .usage = .{ .input_tokens = 10, .output_tokens = 2 },
                } };
                return .{ .success = .{
                    .message = try p.textMessage(a, .assistant, "FINAL REPORT"),
                    .finish = .stop,
                    .usage = .{ .input_tokens = 10, .output_tokens = 2 },
                } };
            },
            .ask_parent => {
                const last = lastToolText(request) orelse return .{ .success = .{
                    .message = try toolCallMessage(a, "ask-call", "message_parent", "{\"message\":\"need direction\",\"wait_for_reply\":true}"),
                    .finish = .tool_calls,
                } };
                if (std.mem.indexOf(u8, last, "PARENT-REPLY-MARKER") != null) self.saw_reply = true;
                return .{ .success = .{
                    .message = try p.textMessage(a, .assistant, "answered"),
                    .finish = .stop,
                } };
            },
            .progress_flood => {
                if (self.calls <= 9) return .{ .success = .{
                    .message = try toolCallMessage(
                        a,
                        try std.fmt.allocPrint(a, "progress-{d}", .{self.calls}),
                        "message_parent",
                        try std.fmt.allocPrint(a, "{{\"message\":\"progress-{d}\"}}", .{self.calls}),
                    ),
                    .finish = .tool_calls,
                } };
                if (lastToolText(request)) |last| {
                    self.saw_progress = std.mem.indexOf(u8, last, "SubagentMessageQueueFull") != null;
                }
                self.progress_flood_checked.store(true, .release);
                return .{ .success = .{
                    .message = try p.textMessage(a, .assistant, "progress done"),
                    .finish = .stop,
                } };
            },
            .steer_skip_write => {
                if (lastToolText(request)) |last| {
                    if (std.mem.indexOf(u8, last, "superseded by steering") != null) self.saw_skip = true;
                    return .{ .success = .{
                        .message = try p.textMessage(a, .assistant, "steered child done"),
                        .finish = .stop,
                    } };
                }
                return .{ .success = .{
                    .message = try toolCallMessage(a, "stale-write", "write_file", "{\"path\":\"sentinel.txt\",\"content\":\"CHILD-OVERWRITE\",\"overwrite\":true}"),
                    .finish = .tool_calls,
                } };
            },
            .progress_loop => return .{ .success = .{
                .message = try toolCallMessage(
                    a,
                    try std.fmt.allocPrint(a, "progress-loop-{d}", .{self.calls}),
                    "message_parent",
                    try std.fmt.allocPrint(a, "{{\"message\":\"progress-{d}\"}}", .{self.calls}),
                ),
                .finish = .tool_calls,
            } },
            .text => return .{ .success = .{
                .message = try p.textMessage(a, .assistant, self.report_text),
                .finish = .stop,
                .usage = .{ .input_tokens = 10, .output_tokens = 2, .cached_input_tokens = 4 },
            } },
        }
    }
};

const Outcome = struct {
    text: []u8,
    is_error: bool,
    canceled: bool,
    truncated: bool,
    cleanup_failed: bool,

    fn deinit(self: *Outcome, a: std.mem.Allocator) void {
        a.free(self.text);
    }
};

const Fixture = struct {
    a: std.mem.Allocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    root: fs.Root,
    env: std.process.Environ.Map,
    config: cfg.Config,
    parent_client: http.Client,
    parent_runtime: r.Runtime,
    decision: ?*@import("../app/decision_client.zig").Client = null,
    image: ?*@import("../app/image_client.zig").Client = null,
    service: SubagentService,
    parent_cancel: p.Cancellation = .{},

    fn create(a: std.mem.Allocator, io: std.Io, parent_protocol: p.Protocol, effective: p.Protocol, task_timeout_ms: u32) !*Fixture {
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        self.a = a;
        self.io = io;
        self.decision = null;
        self.image = null;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const path = buffer[0..try self.tmp.dir.realPath(io, &buffer)];
        self.root = try fs.Root.open(a, io, path);
        errdefer self.root.deinit();
        self.env = std.process.Environ.Map.init(a);
        errdefer self.env.deinit();
        self.config = .{
            .provider = .{ .base_url = "http://127.0.0.1:1/v1", .api_key = "fake-parent-key" },
            .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = parent_protocol, .output_tokens = 8192 },
            .limits = .{ .low_price_input = false, .request_timeout_ms = 10000, .task_timeout_ms = task_timeout_ms },
        };
        self.parent_client = try http.Client.init(a, io, &self.config, "fake-parent-key");
        errdefer self.parent_client.deinit();
        self.parent_runtime = try r.Runtime.init(a, io, &self.config, .{ .context = self, .call_fn = Stub.call }, .{
            .context = self,
            .schemas = &.{},
            .prepare_fn = Stub.prepare,
            .execute_fn = Stub.execute,
        }, .{}, "");
        errdefer self.parent_runtime.deinit();
        self.parent_runtime.selector = .{ .configured = parent_protocol, .selected = effective, .initial_attempted = true };
        self.service = .{};
        // Uninitialized heap memory: the accepted-root token must start clear.
        self.parent_cancel = .{};
        self.service.deps = .{
            .allocator = a,
            .config = &self.config,
            .http_client = &self.parent_client,
            .decision = &self.decision,
            .image = &self.image,
            .root = &self.root,
            .environment = &self.env,
            .auth_path = null,
            .home_path = "",
            .shell_name = "bash",
            .session_cwd = self.root.path,
            .runtime = &self.parent_runtime,
        };
        return self;
    }

    fn deinit(self: *Fixture) void {
        const a = self.a;
        self.service.deinit();
        self.parent_runtime.deinit();
        self.parent_client.deinit();
        self.root.deinit();
        self.env.deinit();
        self.tmp.cleanup();
        a.destroy(self);
    }

    fn withModel(self: *Fixture, fake: *FakeModel) void {
        fake.io = self.io;
        self.service.deps.model_factory = .{ .context = fake, .make_fn = FakeModel.make };
    }

    /// Begin a new accepted root and start one job, returning an owned id.
    fn start(self: *Fixture, request: subagent.Request) ![]u8 {
        self.service.beginTask(&self.parent_cancel);
        return self.runCurrentRoot(request);
    }

    /// Start another job inside the current accepted root (no quota reset).
    fn runCurrentRoot(self: *Fixture, request: subagent.Request) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const result = try self.service.service().run(arena.allocator(), request, &self.parent_cancel);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.a, result.text, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("running", parsed.value.object.get("status").?.string);
        return self.a.dupe(u8, parsed.value.object.get("id").?.string);
    }

    fn get(self: *Fixture, id: []const u8, wait: bool) !std.json.Parsed(std.json.Value) {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const result = try self.service.service().get(arena.allocator(), .{ .id = id, .wait = wait }, &self.parent_cancel);
        return std.json.parseFromSlice(std.json.Value, self.a, result.text, .{ .allocate = .alloc_always });
    }

    fn getResult(self: *Fixture, id: []const u8, wait: bool) !Outcome {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const result = try self.service.service().get(arena.allocator(), .{ .id = id, .wait = wait }, &self.parent_cancel);
        return .{
            .text = try self.a.dupe(u8, result.text),
            .is_error = result.is_error,
            .canceled = result.canceled,
            .truncated = result.truncated,
            .cleanup_failed = result.cleanup_failed,
        };
    }

    fn send(self: *Fixture, id: []const u8, text: []const u8) !std.json.Parsed(std.json.Value) {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const result = try self.service.service().send(arena.allocator(), .{ .id = id, .message = text }, &self.parent_cancel);
        return std.json.parseFromSlice(std.json.Value, self.a, result.text, .{ .allocate = .alloc_always });
    }

    fn cancelJob(self: *Fixture, id: []const u8) !Outcome {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const result = try self.service.service().cancel(arena.allocator(), .{ .id = id }, &self.parent_cancel);
        return .{
            .text = try self.a.dupe(u8, result.text),
            .is_error = result.is_error,
            .canceled = result.canceled,
            .truncated = result.truncated,
            .cleanup_failed = result.cleanup_failed,
        };
    }

    fn endTask(self: *Fixture) !void {
        return self.service.service().endTask(&self.parent_cancel);
    }

    fn active(self: *Fixture) bool {
        return self.service.service().active();
    }
};

fn waitFlag(io: std.Io, flag: *const std.atomic.Value(bool), budget_ms: u64) !void {
    const began = std.Io.Clock.awake.now(io);
    while (!flag.load(.acquire)) {
        if (began.untilNow(io, .awake).toMilliseconds() > budget_ms) return error.FixtureTimeout;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

fn cancelLater(io: std.Io, cancel: *p.Cancellation) !void {
    try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    cancel.cancel();
}

test "subagent start returns an id and get collects isolated report usage and no artifacts" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    try fix.root.write("fixture.txt", "child-only-file", false);
    const parent_arena = fix.parent_runtime.arena.allocator();
    try fix.parent_runtime.history.append(parent_arena, try p.textMessage(parent_arena, .user, "PARENT_MARKER"));
    var fake: FakeModel = .{ .io = std.testing.io, .behavior = .tool_then_text };
    fix.withModel(&fake);

    const id = try fix.start(.{ .task = "inspect fixture", .context = "reference material" });
    defer a.free(id);
    try std.testing.expect(fix.active());
    var parsed = try fix.get(id, true);
    defer parsed.deinit();
    const value = parsed.value;
    try std.testing.expectEqualStrings(id, value.object.get("id").?.string);
    try std.testing.expectEqualStrings("success", value.object.get("status").?.string);
    try std.testing.expectEqualStrings("FINAL REPORT", value.object.get("report").?.string);
    try std.testing.expect(!value.object.get("truncated").?.bool);
    // Empty message list and progress are still present fields.
    try std.testing.expectEqual(@as(usize, 0), value.object.get("messages").?.array.items.len);
    try std.testing.expectEqualStrings("", value.object.get("progress").?.string);
    const usage = value.object.get("usage").?.object;
    try std.testing.expectEqual(@as(i64, 2), usage.get("normal_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 0), usage.get("summary_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 20), usage.get("normal").?.object.get("input_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 4), usage.get("normal").?.object.get("output_tokens").?.integer);
    try std.testing.expect(value.object.get("auxiliary_usage_excluded").?.bool);
    try std.testing.expect(fake.saw_child_mode);
    try std.testing.expect(!fake.saw_replay);
    try std.testing.expect(!fake.saw_steering);
    try std.testing.expect(!fix.active());
    // No child Journal, selection record or Memory migration is created.
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(fix.root.dir.handle, ".thin"));
}

test "subagent inherits the parent effective protocol for chat responses and anthropic" {
    const a = std.testing.allocator;
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        const fix = try Fixture.create(a, std.testing.io, .auto, protocol, 1_000_000);
        defer fix.deinit();
        var fake: FakeModel = .{ .io = std.testing.io };
        fix.withModel(&fake);
        const id = try fix.start(.{ .task = "answer briefly" });
        defer a.free(id);
        var parsed = try fix.get(id, true);
        defer parsed.deinit();
        try std.testing.expectEqualStrings("success", parsed.value.object.get("status").?.string);
        try std.testing.expectEqual(protocol, fake.config_protocol);
        try std.testing.expectEqual(protocol, fake.request_protocol);
    }
}

test "subagent quota resets only for a new accepted root and does not block get or send" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io };
    fix.withModel(&fake);
    var last_id: []u8 = &.{};
    // One accepted root: only beginTask resets the per-root quota.
    fix.service.beginTask(&fix.parent_cancel);
    var round: u32 = 0;
    while (round < subagent.max_runs_per_task) : (round += 1) {
        const id = try fix.runCurrentRoot(.{ .task = "bounded task" });
        var parsed = try fix.get(id, true);
        defer parsed.deinit();
        try std.testing.expectEqualStrings("success", parsed.value.object.get("status").?.string);
        // The completed id stays readable in the same root.
        var again = try fix.getResult(id, true);
        defer again.deinit(a);
        try std.testing.expect(!again.is_error);
        if (round == subagent.max_runs_per_task - 1) last_id = id else a.free(id);
    }
    defer a.free(last_id);
    try std.testing.expectEqual(@as(usize, 4), fake.calls);

    // Health check stays clean and is not a quota gate for get/send.
    try fix.service.checkReady();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.SubagentRunsExhausted, fix.service.service().run(arena.allocator(), .{ .task = "too many" }, &fix.parent_cancel));

    // A genuinely new accepted root resets the quota and the id cache.
    try fix.endTask();
    const id = try fix.start(.{ .task = "new accepted task" });
    defer a.free(id);
    var parsed = try fix.get(id, true);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 5), fake.calls);
}

test "subagent long CJK report truncates at a UTF-8 boundary" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var long: [subagent.max_report_bytes + 8]u8 = undefined;
    var i: usize = 0;
    while (i + 3 <= long.len) : (i += 3) {
        long[i] = 0xe4;
        long[i + 1] = 0xb8;
        long[i + 2] = 0xad;
    }
    while (i < long.len) : (i += 1) long[i] = 'a';
    try std.testing.expect(std.unicode.utf8ValidateSlice(&long));
    var fake: FakeModel = .{ .io = std.testing.io, .report_text = &long };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "long report" });
    defer a.free(id);
    var parsed = try fix.get(id, true);
    defer parsed.deinit();
    const report = parsed.value.object.get("report").?.string;
    try std.testing.expect(std.unicode.utf8ValidateSlice(report));
    try std.testing.expect(report.len <= subagent.max_report_bytes);
    try std.testing.expect(report.len > 0);
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
}

test "cleanup failure outranks encoding OOM and retained owner drops job borrows" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io };
    fix.withModel(&fake);
    fix.service.deps.test_cleanup_failed = true;
    fix.service.deps.test_encode_oom = true;
    const id = try fix.start(.{ .task = "cleanup priority" });
    defer a.free(id);
    var result = try fix.getResult(id, true);
    defer result.deinit(a);
    // Release the injected fault before any assertion can fail: the fixture's
    // own deinit fail-stops on a retained owner that still reports failure.
    defer {
        if (fix.service.current != null) fix.endTask() catch {};
        if (fix.service.retained_child) |owner| owner.test_cleanup_failed = false;
    }
    try std.testing.expect(result.cleanup_failed);
    try std.testing.expect(result.is_error);
    try std.testing.expect(result.truncated);
    // Static fallback: the caller must not free this literal.
    try std.testing.expect(std.mem.indexOf(u8, result.text, "cleanup failed") != null);
    // The encoded body, the Result flags and the same-root cache all agree.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
    try std.testing.expect(parsed.value.object.get("cleanup_failed").?.bool);
    var cached_result = try fix.getResult(id, true);
    defer cached_result.deinit(a);
    try std.testing.expect(cached_result.truncated);
    try std.testing.expect(cached_result.cleanup_failed);
    const retained = fix.service.retained_child orelse return error.FixtureMissingOwner;
    // No worker/job borrow survives the transfer.
    try std.testing.expect(retained.job == null);
    try std.testing.expect(retained.cancel.parent == null);
    try std.testing.expect(retained.tools.parent_channel == null);
    try std.testing.expectError(error.CleanupFailed, fix.service.checkReady());
    // Release the injected fault and retry the retained owner.
    retained.test_cleanup_failed = false;
    fix.service.deinit();
    try std.testing.expect(fix.service.retained_child == null);
}

test "pure encoding OOM is reported as a failure not a success" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io };
    fix.withModel(&fake);
    fix.service.deps.test_encode_oom = true;
    const id = try fix.start(.{ .task = "encoding oom" });
    defer a.free(id);
    // Nothing may stay retained after a pure encoding failure; release any
    // injected fault before the fixture fail-stops in deinit.
    defer {
        if (fix.service.current != null) fix.endTask() catch {};
        if (fix.service.retained_child) |owner| owner.test_cleanup_failed = false;
    }
    var parsed = try fix.get(id, true);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("failed", parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("OutOfMemory", parsed.value.object.get("detail").?.string);
    try std.testing.expect(fix.service.retained_child == null);
}

test "parent cancellation reaches the child and only then marks the result canceled" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fix = try Fixture.create(a, io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = io, .behavior = .wait_for_cancel, .parent_cancel = &fix.parent_cancel };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "wait until canceled" });
    defer a.free(id);
    var future = try std.Io.concurrent(io, cancelLater, .{ io, &fix.parent_cancel });
    var result = try fix.getResult(id, true);
    defer result.deinit(a);
    try future.await(io);
    try std.testing.expect(result.canceled);
    try std.testing.expect(result.is_error);
    try std.testing.expect(!result.cleanup_failed);
    // The parent cancel interrupted get, so the worker is joined by endTask.
    try fix.endTask();
    try std.testing.expect(fake.parent_was_requested);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("canceled", parsed.value.object.get("status").?.string);
}

test "single-child cancellation returns canceled JSON without canceling the parent" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io, .behavior = .wait_for_cancel, .parent_cancel = &fix.parent_cancel };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "cancel just the child" });
    defer a.free(id);
    var result = try fix.cancelJob(id);
    defer result.deinit(a);
    try std.testing.expect(result.is_error);
    try std.testing.expect(!result.canceled);
    try std.testing.expect(!fix.parent_cancel.isRequested());
    try std.testing.expect(!fix.active());
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(id, parsed.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("canceled", parsed.value.object.get("status").?.string);
    try std.testing.expect(!parsed.value.object.get("cleanup_failed").?.bool);
    // Canceling collected the job, so the parent may finish normally.
    try fix.service.checkReady();
}

test "child local timeout fails the child without canceling the parent task" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 20);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io, .behavior = .wait_for_cancel, .parent_cancel = &fix.parent_cancel };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "outlive the child deadline" });
    defer a.free(id);
    var result = try fix.getResult(id, true);
    defer result.deinit(a);
    try std.testing.expect(result.is_error);
    try std.testing.expect(!result.canceled);
    try std.testing.expect(!fix.parent_cancel.isRequested());
    try std.testing.expect(!fake.parent_was_requested);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const value = parsed.value;
    // Product semantics: a watchdog timeout is a failed child, not a canceled
    // one, and it never cancels the parent task.
    try std.testing.expectEqualStrings("failed", value.object.get("status").?.string);
    try std.testing.expectEqualStrings("TaskTimeout", value.object.get("detail").?.string);
    try std.testing.expect(!fix.parent_runtime.poisoned);
}

test "parent steering skips an unstarted child tool and reaches the next child request" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fix = try Fixture.create(a, io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    try fix.root.write("sentinel.txt", "SENTINEL-ORIGINAL", false);
    var fake: FakeModel = .{ .io = io, .behavior = .steer_skip_write };
    fake.hold.store(true, .release);
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "steer away from the stale write" });
    defer a.free(id);
    try waitFlag(io, &fake.entered, 1_000);
    // The steering is accepted while the child's first model request is still
    // in flight; it must sit in the child Inbox before the stale call lands.
    var receipt = try fix.send(id, "STEER-MARKER do not write the target");
    defer receipt.deinit();
    try std.testing.expectEqualStrings("delivered", receipt.value.object.get("status").?.string);
    fake.hold.store(false, .release);
    var parsed = try fix.get(id, true);
    defer parsed.deinit();
    // The unstarted write_file must be skipped, not executed and then explained.
    try std.testing.expect(fake.saw_skip);
    try std.testing.expect(fake.saw_steering);
    const sentinel = try fix.root.readBinary(a, "sentinel.txt", 4096);
    defer a.free(sentinel);
    try std.testing.expectEqualStrings("SENTINEL-ORIGINAL", sentinel);
    try std.testing.expectEqualStrings("success", parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("steered child done", parsed.value.object.get("report").?.string);
}

test "child question stays visible until the parent reply commits" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io, .behavior = .ask_parent };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "ask the parent" });
    defer a.free(id);

    var question = try fix.get(id, true);
    defer question.deinit();
    try std.testing.expectEqualStrings("waiting_for_reply", question.value.object.get("status").?.string);
    const messages = question.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0].object.get("requires_reply").?.bool);
    try std.testing.expectEqualStrings("need direction", messages[0].object.get("message").?.string);

    // Reading again while still unanswered repeats the question, never blocks.
    var again = try fix.get(id, true);
    defer again.deinit();
    try std.testing.expectEqualStrings("waiting_for_reply", again.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 1), again.value.object.get("messages").?.array.items.len);

    var receipt = try fix.send(id, "PARENT-REPLY-MARKER proceed");
    defer receipt.deinit();
    try std.testing.expectEqualStrings("reply_delivered", receipt.value.object.get("status").?.string);

    var done = try fix.get(id, true);
    defer done.deinit();
    try std.testing.expectEqualStrings("success", done.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 0), done.value.object.get("messages").?.array.items.len);
    try std.testing.expectEqualStrings("answered", done.value.object.get("report").?.string);
    try std.testing.expect(fake.saw_reply);
}

test "child progress is bounded to eight unread messages and acked after encode" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io, .behavior = .progress_flood };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "post progress" });
    defer a.free(id);
    // Ack nothing until the child has already seen the full queue, so its ninth
    // post is deterministically rejected instead of racing this loop's acks.
    try waitFlag(std.testing.io, &fake.progress_flood_checked, 1_000);
    var total: usize = 0;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var snapshot = try fix.get(id, true);
        defer snapshot.deinit();
        const delivered = snapshot.value.object.get("messages").?.array.items.len;
        try std.testing.expect(delivered <= service_mod.max_unread_child_messages);
        total += delivered;
        const status = snapshot.value.object.get("status").?.string;
        if (!std.mem.eql(u8, status, "running") and !std.mem.eql(u8, status, "waiting_for_reply")) break;
    }
    try std.testing.expectEqual(service_mod.max_unread_child_messages, total);
    try std.testing.expect(fake.saw_progress);
}

test "steering inbox capacity and invalid input fail explicitly" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fix = try Fixture.create(a, io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = io, .behavior = .wait_for_cancel, .parent_cancel = &fix.parent_cancel };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "bounded messaging" });
    defer a.free(id);
    try waitFlag(io, &fake.entered, 1_000);
    // The child Inbox is a bounded 16-slot window; overflow is an explicit
    // failure, never a silent drop, and it does not cancel the parent.
    var round: usize = 0;
    while (round < 16) : (round += 1) {
        var receipt = try fix.send(id, "bounded steering");
        defer receipt.deinit();
        try std.testing.expectEqualStrings("delivered", receipt.value.object.get("status").?.string);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // A full Inbox must fail without leaking the already-encoded steering
    // receipt. The caller allocator here is the leak-checking test allocator,
    // not an arena, so a missing error-path release would be reported.
    try std.testing.expectError(error.InboxFull, fix.service.service().send(a, .{ .id = id, .message = "seventeenth" }, &fix.parent_cancel));
    try std.testing.expectError(error.InvalidSubagentMessage, fix.service.service().send(arena.allocator(), .{ .id = id, .message = "" }, &fix.parent_cancel));
    const too_long: [subagent.max_message_bytes + 1]u8 = @splat('m');
    try std.testing.expectError(error.InvalidSubagentMessage, fix.service.service().send(arena.allocator(), .{ .id = id, .message = &too_long }, &fix.parent_cancel));
    const too_long_id: [subagent.max_id_bytes + 1]u8 = @splat('i');
    try std.testing.expectError(error.InvalidSubagentId, fix.service.service().send(arena.allocator(), .{ .id = &too_long_id, .message = "x" }, &fix.parent_cancel));
    try std.testing.expectError(error.UnknownSubagentId, fix.service.service().send(arena.allocator(), .{ .id = "subagent_999", .message = "x" }, &fix.parent_cancel));
    try fix.endTask();
}

test "parent message direction cap is 32 successful sends" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fix = try Fixture.create(a, io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    // Each child model round reports progress after the Runtime has consumed
    // every pending steering entry, so a progress snapshot is a real delivery
    // barrier (no sleeps) for the next 16-message batch.
    var fake: FakeModel = .{ .io = io, .behavior = .progress_loop };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "consume steering" });
    defer a.free(id);
    var first = try fix.get(id, true);
    defer first.deinit();
    try std.testing.expectEqualStrings("running", first.value.object.get("status").?.string);
    // Four batches of eight keep the peak Inbox usage bounded even if the
    // child consumes a prefix of a batch concurrently: leftovers from one batch
    // plus the next batch can never exceed the 16-slot Inbox.
    var batch: usize = 0;
    while (batch < 4) : (batch += 1) {
        var index: usize = 0;
        while (index < 8) : (index += 1) {
            var receipt = try fix.send(id, "STEER-MARKER batch");
            defer receipt.deinit();
            try std.testing.expectEqualStrings("delivered", receipt.value.object.get("status").?.string);
        }
        var next = try fix.get(id, true);
        defer next.deinit();
        try std.testing.expectEqualStrings("running", next.value.object.get("status").?.string);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.SubagentMessageLimit, fix.service.service().send(arena.allocator(), .{ .id = id, .message = "too many" }, &fix.parent_cancel));
    try fix.endTask();
}

test "old ids from another root fail closed while same-root collected ids stay readable" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io };
    fix.withModel(&fake);
    const first = try fix.start(.{ .task = "first root" });
    defer a.free(first);
    var parsed = try fix.get(first, true);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("success", parsed.value.object.get("status").?.string);
    // Same root, already collected: serve the cached terminal view again.
    var cached = try fix.get(first, true);
    defer cached.deinit();
    try std.testing.expectEqualStrings("success", cached.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("child report", cached.value.object.get("report").?.string);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.SubagentFinished, fix.service.service().send(arena.allocator(), .{ .id = first, .message = "late" }, &fix.parent_cancel));

    // A second job in the same accepted root keeps the first id readable.
    const second = try fix.runCurrentRoot(.{ .task = "second job" });
    defer a.free(second);
    var second_done = try fix.get(second, true);
    defer second_done.deinit();
    var first_again = try fix.get(first, true);
    defer first_again.deinit();
    try std.testing.expectEqualStrings("success", first_again.value.object.get("status").?.string);

    // A new accepted root invalidates both ids.
    try fix.endTask();
    fix.service.beginTask(&fix.parent_cancel);
    try std.testing.expectError(error.UnknownSubagentId, fix.service.service().get(arena.allocator(), .{ .id = first }, &fix.parent_cancel));
    try std.testing.expectError(error.UnknownSubagentId, fix.service.service().get(arena.allocator(), .{ .id = second }, &fix.parent_cancel));
}

test "beforeFinish returns bounded host hints whenever a job is uncollected" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io, .behavior = .wait_for_cancel, .parent_cancel = &fix.parent_cancel };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "uncollected job" });
    defer a.free(id);
    const service = fix.service.service();
    try std.testing.expect(service.active());
    // Runtime owns the reminder budget; the host always answers with a hint.
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const hint = (try service.beforeFinish(fix.a, &fix.parent_cancel)).?;
        defer fix.a.free(hint);
        try std.testing.expect(std.mem.indexOf(u8, hint, id) != null);
        try std.testing.expect(hint.len < 256);
    }
    try fix.endTask();
    try std.testing.expect(!fix.active());
    try std.testing.expect((try service.beforeFinish(fix.a, &fix.parent_cancel)) == null);
}

test "unsupported child protocol fails the start without a child run" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    fix.parent_runtime.selector = .{ .configured = .chat, .selected = .systemone, .initial_attempted = true };
    var fake: FakeModel = .{ .io = std.testing.io };
    fix.withModel(&fake);
    fix.service.beginTask(&fix.parent_cancel);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedSubagentProtocol, fix.service.service().run(arena.allocator(), .{ .task = "no child" }, &fix.parent_cancel));
    try std.testing.expect(fix.service.retained_child == null);
    try std.testing.expect(!fix.active());
}

test "start refuses while a job is uncollected and endTask is repeatable" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var fake: FakeModel = .{ .io = std.testing.io, .behavior = .wait_for_cancel, .parent_cancel = &fix.parent_cancel };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "single uncollected job" });
    defer a.free(id);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.SubagentJobPending, fix.service.service().run(arena.allocator(), .{ .task = "second" }, &fix.parent_cancel));
    try fix.endTask();
    try fix.endTask();
    try std.testing.expect(!fix.active());
    // A new accepted root may start again.
    const next = try fix.start(.{ .task = "after end task" });
    defer a.free(next);
    try fix.endTask();
}

const ApprovalRecorder = struct {
    emitted: usize = 0,
    authorized: usize = 0,
    cleared: usize = 0,
    id: ?u64 = null,
    cleared_id: ?u64 = null,
    saw_source: bool = false,
    saw_operation: bool = false,
    saw_canceled: bool = false,
    io: std.Io = undefined,
    delay_ms: u64 = 0,

    fn emit(raw: ?*anyopaque, event: r.Event, _: *const p.Cancellation) !void {
        const self: *ApprovalRecorder = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .permission => |permission| {
                self.emitted += 1;
                self.id = permission.id;
                self.saw_source = std.mem.indexOf(u8, permission.description, "subagent") != null;
                self.saw_operation = std.mem.indexOf(u8, permission.description, "DANGEROUS bash") != null;
            },
            .permission_cleared => |id| {
                self.cleared += 1;
                self.cleared_id = id;
            },
            else => {},
        }
    }

    fn authorize(raw: ?*anyopaque, permission: r.Permission, cancel: *const p.Cancellation) !r.Decision {
        const self: *ApprovalRecorder = @ptrCast(@alignCast(raw.?));
        self.authorized += 1;
        try std.testing.expectEqual(self.id.?, permission.id);
        try std.testing.expect(std.mem.indexOf(u8, permission.description, "subagent") != null);
        // Emit-before-authorize: the parent already published this id.
        try std.testing.expectEqual(@as(usize, 1), self.emitted);
        // A cooperative host must abort the prompt on the broker-local token:
        // the child's local timeout/steering cancels it without touching root.
        if (self.delay_ms != 0) {
            const began = std.Io.Clock.awake.now(self.io);
            while (began.untilNow(self.io, .awake).toMilliseconds() < self.delay_ms) {
                if (cancel.isRequested()) {
                    self.saw_canceled = true;
                    return error.Canceled;
                }
                try std.Io.sleep(self.io, .fromMilliseconds(2), .awake);
            }
        }
        return .deny;
    }
};

const ApprovalModel = struct {
    calls: usize = 0,

    fn make(raw: *anyopaque, _: std.mem.Allocator, _: *const cfg.Config) !p.Model {
        return .{ .context = raw, .call_fn = call };
    }

    fn call(raw: *anyopaque, a: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *ApprovalModel = @ptrCast(@alignCast(raw));
        self.calls += 1;
        const has_result = for (request.messages) |message| {
            if (message.role == .tool) break true;
        } else false;
        if (!has_result) return .{ .success = .{
            .message = try toolCallMessage(a, "approval-call", "bash", "{\"command\":\"rm -rf build\"}"),
            .finish = .tool_calls,
        } };
        return .{ .success = .{ .message = try p.textMessage(a, .assistant, "after denial"), .finish = .stop } };
    }
};

test "child approval maps into the parent permission domain before authorize" {
    const a = std.testing.allocator;
    const fix = try Fixture.create(a, std.testing.io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    var recorder: ApprovalRecorder = .{ .io = std.testing.io };
    fix.parent_runtime.host = .{ .context = &recorder, .emit_fn = ApprovalRecorder.emit, .authorize_fn = ApprovalRecorder.authorize };
    fix.parent_runtime.permission_id = 50;
    var model: ApprovalModel = .{};
    fix.service.deps.model_factory = .{ .context = &model, .make_fn = ApprovalModel.make };
    const id = try fix.start(.{ .task = "try a dangerous command" });
    defer a.free(id);
    var parsed = try fix.get(id, true);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), recorder.emitted);
    try std.testing.expectEqual(@as(usize, 1), recorder.authorized);
    try std.testing.expectEqual(@as(?u64, 51), recorder.id);
    try std.testing.expect(recorder.saw_source);
    try std.testing.expect(recorder.saw_operation);
    try std.testing.expectEqual(@as(u64, 51), fix.parent_runtime.permission_id);
    try std.testing.expectEqualStrings("success", parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("after denial", parsed.value.object.get("report").?.string);
}

test "child local timeout withdraws a pending approval without canceling the parent" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    // The child watchdog fires while the parent is still deciding; a cooperative
    // host blocks well past the timeout so an early return can only come from
    // the broker-local cancellation token.
    const fix = try Fixture.create(a, io, .chat, .chat, 100);
    defer fix.deinit();
    var recorder: ApprovalRecorder = .{ .io = io, .delay_ms = 1000 };
    fix.parent_runtime.host = .{ .context = &recorder, .emit_fn = ApprovalRecorder.emit, .authorize_fn = ApprovalRecorder.authorize };
    fix.parent_runtime.permission_id = 70;
    var model: ApprovalModel = .{};
    fix.service.deps.model_factory = .{ .context = &model, .make_fn = ApprovalModel.make };
    const id = try fix.start(.{ .task = "approval outlives the child" });
    defer a.free(id);
    var result = try fix.getResult(id, true);
    defer result.deinit(a);
    try std.testing.expect(result.is_error);
    try std.testing.expect(!result.canceled);
    try std.testing.expectEqual(@as(usize, 1), recorder.emitted);
    try std.testing.expectEqual(@as(usize, 1), recorder.authorized);
    // The broker did not hang for the full host delay: the child's local
    // timeout canceled the broker-local token and the parent mirror was cleared.
    try std.testing.expect(recorder.saw_canceled);
    try std.testing.expectEqual(@as(usize, 1), recorder.cleared);
    try std.testing.expectEqual(recorder.id, recorder.cleared_id);
    // A child-local timeout must never cancel or poison the parent task.
    try std.testing.expect(!fix.parent_cancel.isRequested());
    try std.testing.expect(!fix.parent_runtime.poisoned);
    try std.testing.expect(!fix.active());
}

/// Parent model: start one child, then collect it with a real get tool call.
const DelegateModel = struct {
    calls: usize = 0,
    id: []const u8 = "",

    fn call(raw: *anyopaque, a: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *DelegateModel = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.calls == 1) {
            const blocks = try a.alloc(p.Block, 1);
            blocks[0] = .{ .tool_call = .{
                .id = "delegate-start",
                .name = "subagent",
                .arguments = "{\"task\":\"wait on the nested child\"}",
            } };
            return .{ .success = .{
                .message = .{ .role = .assistant, .blocks = blocks },
                .finish = .tool_calls,
                .usage = .{ .input_tokens = 5, .output_tokens = 1 },
            } };
        }
        if (self.id.len == 0) {
            // Find the id in the previous tool result.
            for (request.messages) |message| {
                if (message.role != .tool) continue;
                for (message.blocks) |block| switch (block) {
                    .tool_result => |result| {
                        if (std.mem.indexOf(u8, result.text, "\"id\":\"")) |at| {
                            const rest = result.text[at + 6 ..];
                            const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
                            self.id = rest[0..end];
                        }
                    },
                    else => {},
                };
            }
            if (self.id.len == 0) return .{ .success = .{
                .message = try p.textMessage(a, .assistant, "missing id"),
                .finish = .stop,
            } };
        }
        const call_id = try std.fmt.allocPrint(a, "delegate-get-{d}", .{self.calls});
        const args = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"wait\":true}}", .{self.id});
        const blocks = try a.alloc(p.Block, 1);
        blocks[0] = .{ .tool_call = .{
            .id = call_id,
            .name = "get_subagent_result",
            .arguments = args,
        } };
        return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = blocks },
            .finish = .tool_calls,
        } };
    }
};

/// Nested child model: deliberately ignores the cooperative Cancellation bit and
/// sleeps far longer than the parent's 20ms cleanup grace, so `error.Canceled`
/// here can only come from the parent's forced Io cancellation.
const NestedSleepModel = struct {
    io: std.Io,
    calls: usize = 0,
    entered: std.atomic.Value(bool) = .init(false),
    injected_io_cancel: std.atomic.Value(bool) = .init(false),
    returned_late_report: bool = false,

    fn make(raw: *anyopaque, _: std.mem.Allocator, _: *const cfg.Config) !p.Model {
        return .{ .context = raw, .call_fn = call };
    }

    fn call(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *NestedSleepModel = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.entered.store(true, .release);
        std.Io.sleep(self.io, .fromMilliseconds(200), .awake) catch |err| {
            if (err == error.Canceled) self.injected_io_cancel.store(true, .release);
            return err;
        };
        self.returned_late_report = true;
        return .{ .success = .{ .message = try p.textMessage(a, .assistant, "late child report"), .finish = .stop } };
    }
};

/// Ordering gate for the nested-cancellation fixture only. It observes the
/// canonical start of the parent's own get_subagent_result call, so the cancel
/// can never arrive while the last recorded call is still the start receipt.
/// Every other event is ignored exactly like the default host, and the default
/// deny authorization policy is retained.
const GetStartedHost = struct {
    get_started: std.atomic.Value(bool) = .init(false),

    fn install(self: *GetStartedHost, fix: *Fixture) void {
        fix.parent_runtime.host = .{ .context = self, .emit_fn = emit };
    }

    fn emit(raw: ?*anyopaque, event: r.Event, _: *const p.Cancellation) !void {
        const self: *GetStartedHost = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .tool_started => |started| {
                if (std.mem.eql(u8, started.name, "get_subagent_result")) self.get_started.store(true, .release);
            },
            else => {},
        }
    }
};

test "parent grace expiry injects Io cancellation into a nested async child runtime" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    // 1.5s parent/child watchdog: far above the 20ms grace, far below a hang.
    const fix = try Fixture.create(a, io, .chat, .chat, 1_500);
    defer fix.deinit();

    // Real Tools executor and real Service: the tool path itself must reach the
    // nested child Runtime, not a direct Service call.
    var store = mem.Store.init(&fix.root, fix.config.limits);
    var tools: tools_mod.Tools = .{ .root = &fix.root, .memory = &store, .config = &fix.config, .environment = &fix.env };
    tools.subagent = fix.service.service();
    fix.parent_runtime.executor = tools.executor();

    var root_model: DelegateModel = .{};
    fix.parent_runtime.model = .{ .context = &root_model, .call_fn = DelegateModel.call };
    var child: NestedSleepModel = .{ .io = io };
    fix.service.deps.model_factory = .{ .context = &child, .make_fn = NestedSleepModel.make };
    var host: GetStartedHost = .{};
    host.install(fix);

    var cancel: p.Cancellation = .{};
    var future = try std.Io.concurrent(io, runRoot, .{ fix, &cancel });
    defer _ = future.cancel(io) catch {};

    try waitFlag(io, &child.entered, 1_000);
    // Also wait for the parent's get call to be canonically started: only then
    // does the cancellation land on that tool result instead of leaving the
    // earlier start receipt as the last recorded call.
    try waitFlag(io, &host.get_started, 1_000);
    // The parent flag alone reaches no cancellation point in the sleeping child.
    try std.testing.expect(!child.injected_io_cancel.load(.acquire));
    cancel.cancel();
    const terminal = try future.await(io);

    try std.testing.expect(child.injected_io_cancel.load(.acquire));
    try std.testing.expect(!child.returned_late_report);
    try std.testing.expectEqual(@as(usize, 1), child.calls);
    try std.testing.expectEqual(@as(usize, 2), root_model.calls);
    try std.testing.expectEqual(r.Status.canceled, terminal.status);
    try std.testing.expectEqual(error.Canceled, terminal.detail.?);
    try std.testing.expect(!fix.parent_runtime.poisoned);
    try std.testing.expect(fix.service.retained_child == null);
    try std.testing.expect(!fix.active());
    // The parent recorded the canceled get outcome, never the late report.
    const last = fix.parent_runtime.history.items[fix.parent_runtime.history.items.len - 1];
    try std.testing.expectEqual(p.Role.tool, last.role);
    const recorded = last.blocks[0].tool_result;
    try std.testing.expect(recorded.canceled);
    try std.testing.expect(std.mem.indexOf(u8, recorded.text, "late child report") == null);
    try fix.service.checkReady();
}

fn runRoot(fix: *Fixture, cancel: *p.Cancellation) anyerror!r.Terminal {
    return fix.parent_runtime.run("delegate the bounded child task", cancel);
}

test "http clone keeps frozen key CA and route while owning a separate pool" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CURL_CA_BUNDLE", "/owned/first-ca.pem");
    try env.put("FROZEN_KEY", "first-key");
    const parent_config: cfg.Config = .{
        .provider = .{ .base_url = "https://example.invalid/v1", .api_key_env = "FROZEN_KEY" },
        .selected_provider = "listed",
        .model = .{ .name = "fixture/model", .context_tokens = 32768, .protocol = .chat },
        .proxy = .{ .address = "127.0.0.1", .port = 18973, .models = &.{"listed/fixture/model"} },
    };
    var parent = try http.Client.initWithEnv(a, std.testing.io, &parent_config, "first-key", &env);
    defer parent.deinit();
    // Ambient changes after creation must never alter the child clone.
    try env.put("FROZEN_KEY", "later-key");
    try env.put("CURL_CA_BUNDLE", "/owned/later-ca.pem");
    const child_config: cfg.Config = .{
        .provider = parent_config.provider,
        .selected_provider = parent_config.selected_provider,
        .model = parent_config.model,
        .proxy = parent_config.proxy,
    };
    var child = try parent.cloneForConfig(a, std.testing.io, &child_config);
    defer child.deinit();
    try std.testing.expectEqualStrings("Bearer first-key", child.authorization);
    try std.testing.expectEqualStrings("http://127.0.0.1:18973", child.proxy_http.?.proxy_url.?);
    try std.testing.expect(parent.proxy_http.?.proxy_url.?.ptr != child.proxy_http.?.proxy_url.?.ptr);
    try std.testing.expectEqualStrings("/owned/first-ca.pem", child.proxy_http.?.env.get("CURL_CA_BUNDLE").?);
    try std.testing.expect(&parent.http != &child.http);
    // A config whose route no longer matches the frozen transport is refused.
    const changed_config: cfg.Config = .{
        .provider = parent_config.provider,
        .selected_provider = "unlisted",
        .model = parent_config.model,
        .proxy = parent_config.proxy,
    };
    try std.testing.expectError(error.ProxyRouteChanged, parent.cloneForConfig(a, std.testing.io, &changed_config));
}

/// Waits until the worker published a terminal state that the parent has not
/// collected yet. `beforeFinish` is the public hint seam for exactly that state;
/// a fresh token keeps a canceled root from short-circuiting the probe.
fn waitUncollectedFinished(fix: *Fixture, service: subagent.Service, budget_ms: u64) !void {
    const io = fix.io;
    const began = std.Io.Clock.awake.now(io);
    var probe: p.Cancellation = .{};
    while (true) {
        const hint = (try service.beforeFinish(fix.a, &probe)) orelse return error.FixtureMissingJob;
        const finished = std.mem.indexOf(u8, hint, "finished but not collected") != null;
        fix.a.free(hint);
        if (finished) return;
        if (began.untilNow(io, .awake).toMilliseconds() > budget_ms) return error.FixtureTimeout;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

test "send refuses a finished or canceled job that is not collected yet" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fix = try Fixture.create(a, io, .chat, .chat, 1_000_000);
    defer fix.deinit();
    const service = fix.service.service();

    // Publication is visible under the job lock: here the worker finished
    // successfully but the parent deliberately did not collect it. A late
    // message must fail explicitly instead of reporting a delivery no child
    // will ever read.
    var fake: FakeModel = .{ .io = io };
    fix.withModel(&fake);
    const id = try fix.start(.{ .task = "finish without collecting" });
    defer a.free(id);
    try waitUncollectedFinished(fix, service, 1_000);
    try std.testing.expect(fix.service.current != null);
    try std.testing.expectError(error.SubagentFinished, service.send(a, .{ .id = id, .message = "late steering" }, &fix.parent_cancel));
    var done = try fix.get(id, true);
    defer done.deinit();
    try std.testing.expectEqualStrings("success", done.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("child report", done.value.object.get("report").?.string);

    // A canceled root leaves the job uncollected. `get` returns the parent
    // cancellation view immediately, and the job's own cancel token already
    // follows the root one way: no send may claim success before or after the
    // worker publishes its canceled terminal.
    try fix.endTask();
    var blocking: FakeModel = .{ .io = io, .behavior = .wait_for_cancel, .parent_cancel = &fix.parent_cancel };
    fix.withModel(&blocking);
    const blocked = try fix.start(.{ .task = "cancel the root then send" });
    defer a.free(blocked);
    fix.parent_cancel.cancel();
    var canceled = try fix.getResult(blocked, true);
    defer canceled.deinit(a);
    try std.testing.expect(canceled.canceled);
    try std.testing.expect(fix.service.current != null);
    // The call-level token is already requested, so probe the job-level guard
    // with a fresh call token: the child chained to the canceled root can no
    // longer accept a message.
    var live: p.Cancellation = .{};
    try std.testing.expectError(error.SubagentFinished, service.send(a, .{ .id = blocked, .message = "too late" }, &live));
    try waitUncollectedFinished(fix, service, 1_000);
    try std.testing.expectError(error.SubagentFinished, service.send(a, .{ .id = blocked, .message = "still too late" }, &live));
    try fix.endTask();
}
