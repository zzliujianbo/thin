//! Regressions for the application-level async subagent host. No real API,
//! credentials or external network are used. Child models are injected through
//! the private test seam; the Decision approval regression uses an owned
//! loopback reviewer and an owned project sentinel.

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

const Behavior = enum { text, tool_then_text, wait_for_cancel, ask_parent, progress_flood, steer_skip_write, progress_loop, concurrent_write };

/// Cross-child barrier for the concurrency regression. Every field is atomic, so
/// independent FakeModel instances can share it without a data race; plain fake
/// fields are still only read after the owning worker was joined.
const Barrier = struct {
    entered: std.atomic.Value(usize) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
};

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
    /// ask_parent only: per-instance question and reply marker, so a test can
    /// prove two siblings never see each other's question or reply.
    question: []const u8 = "need direction",
    reply_tag: []const u8 = "PARENT-REPLY-MARKER",
    final_text: []const u8 = "answered",
    /// concurrent_write only: the barrier to enter before the mutation call and
    /// the exact per-child file payload to write through the shared gate.
    barrier: ?*Barrier = null,
    write_path: []const u8 = "",
    write_tag: []const u8 = "",
    /// Set by the worker just before it returns from a canceled wait; read only
    /// after that worker was joined.
    saw_cancel: bool = false,

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
                self.saw_cancel = true;
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
                    .message = try toolCallMessage(a, "ask-call", "message_parent", try std.fmt.allocPrint(a, "{{\"message\":\"{s}\",\"wait_for_reply\":true}}", .{self.question})),
                    .finish = .tool_calls,
                } };
                if (std.mem.indexOf(u8, last, self.reply_tag) != null) self.saw_reply = true;
                return .{ .success = .{
                    .message = try p.textMessage(a, .assistant, self.final_text),
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
                    self.saw_progress = std.mem.indexOf(u8, last, "sent") != null;
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
            .concurrent_write => {
                const has_result = for (request.messages) |message| {
                    if (message.role == .tool) break true;
                } else false;
                if (!has_result) {
                    if (self.barrier) |barrier| {
                        _ = barrier.entered.fetchAdd(1, .acq_rel);
                        while (!barrier.release.load(.acquire)) {
                            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch break;
                        }
                    }
                    return .{ .success = .{
                        .message = try toolCallMessage(
                            a,
                            "concurrent-write",
                            "write_file",
                            try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"{s}\",\"overwrite\":true}}", .{ self.write_path, self.write_tag }),
                        ),
                        .finish = .tool_calls,
                    } };
                }
                return .{ .success = .{
                    .message = try p.textMessage(a, .assistant, self.report_text),
                    .finish = .stop,
                } };
            },
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

    fn create(a: std.mem.Allocator, io: std.Io, parent_protocol: p.Protocol, effective: p.Protocol) !*Fixture {
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
            .limits = .{ .low_price_input = false, .request_timeout_ms = 10000 },
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

    /// Start another job inside the current accepted root (no task lifecycle
    /// reset; the root is not begun again).
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
        const token: p.Cancellation = .{};
        const hint = self.service.service().beforeFinish(self.a, &token) catch unreachable;
        if (hint) |text| {
            self.a.free(text);
            return true;
        }
        return false;
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

/// Live sibling jobs currently linked for the accepted root.
fn jobCount(fix: *Fixture) usize {
    var count: usize = 0;
    var node = fix.service.current;
    while (node) |job| : (node = job.next) count += 1;
    return count;
}

// These declarations are entirely owned and never contacted. The custom target
// has no catalog price metadata, while the parent gets a synthetic known price.
const app_selection_fixture =
    \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://127.0.0.1:1/v1","api_key":"fake-parent","models":{"chat":{"protocol":"chat","context_tokens":65536}}},"target":{"base_url":"http://127.0.0.1:2/v1","api_key_env":"TARGET_KEY","models":{"family/raw":{"protocol":"responses","context_tokens":32768}}},"inline":{"base_url":"http://127.0.0.1:3/v1","api_key":"fake-inline","models":{"m":{"protocol":"anthropic","context_tokens":49152,"output_tokens":1024}}},"missing":{"base_url":"http://127.0.0.1:4/v1","api_key_env":"MISSING_TARGET_KEY","models":{"m":{"protocol":"chat","context_tokens":32768}}},"bad":{"base_url":"http://127.0.0.1:5/v1","api_key":"fake-bad","models":{"window":{"protocol":"chat"},"judge":{"protocol":"systemone"}}},"codex":{"base_url":"https://chatgpt.com/backend-api/codex","kind":"openai_codex","codex_oauth":{"access_token":"fake-access","refresh_token":"fake-refresh","expires_at_ms":123456789},"models":{"gpt-fixture":{"protocol":"responses","context_tokens":32768}}}}},"memory":{"auto":false},"proxy":{"address":"127.0.0.1","port":34567,"models":["target/family/raw"]}}
;

fn selectionApp(fix: *Fixture) !*@import("../app/app.zig").App {
    const a = fix.a;
    try fix.env.put("HOME", fix.root.path);
    try fix.env.put("TARGET_KEY", "fake-target-old");
    var parsed = try cfg.parse(a, app_selection_fixture);
    var consumed = false;
    errdefer if (!consumed) cfg.release(&parsed);
    const cache = try a.create(@import("../app/model_metadata.zig").Cache);
    defer a.destroy(cache);
    cache.* = .{};
    try @import("../app/model_resolver.zig").applyDefault(parsed.arena.allocator(), &parsed.value, cache);
    parsed.value.model.input_price_threshold = 20000;
    parsed.value.model.input_price_flat_limit = 50000;
    // initConfigured consumes parsed on success and failure.
    consumed = true;
    return @import("../app/app.zig").App.initConfiguredAnchoredAuth(a, fix.io, &fix.env, &fix.root, "/owned/unused-auth", .{}, parsed);
}

fn selectedClient(app: *@import("../app/app.zig").App, parsed: *std.json.Parsed(cfg.Config), reference: []const u8, cancel: *const p.Cancellation) !http.Client {
    const factory = app.subagent.deps.client_factory.?;
    return factory.prepare_fn(factory.context, std.testing.allocator, parsed, reference, cancel);
}

fn expectSelectedKey(app: *@import("../app/app.zig").App, expected: []const u8) !void {
    var parsed = try cfg.clone(std.testing.allocator, app.config.value);
    defer cfg.release(&parsed);
    var cancel: p.Cancellation = .{};
    var client = try selectedClient(app, &parsed, "target/family/raw", &cancel);
    defer client.deinit();
    try std.testing.expectEqualStrings(expected, client.authorization);
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
    /// When set, every authorization must carry this job id in its description:
    /// several siblings may hold identical pending approvals at the same time.
    expect_source: []const u8 = "",
    io: std.Io = undefined,
    delay_ms: u64 = 0,
    reply: r.Decision = .deny,
    /// A finite child-local cancellation at the authorization boundary; this
    /// replaces the removed accepted-task watchdog in approval lifecycle tests.
    cancel_child: ?*p.Cancellation = null,

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
        if (self.expect_source.len != 0)
            try std.testing.expect(std.mem.indexOf(u8, permission.description, self.expect_source) != null);
        // Emit-before-authorize: the parent already published this id.
        try std.testing.expectEqual(self.authorized, self.emitted);
        // A cooperative host aborts on the broker-local token when child-local
        // cancellation or steering withdraws the question without touching root.
        if (self.cancel_child) |child| child.cancel();
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
        return self.reply;
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
            .message = try toolCallMessage(a, "approval-call", "bash", "{\"command\":\"rm -f .ssh/fixture-marker\"}"),
            .finish = .tool_calls,
        } };
        return .{ .success = .{ .message = try p.textMessage(a, .assistant, "after denial"), .finish = .stop } };
    }
};

const reviewed_command = "printf A >> sentinel.txt";

const ReviewedBashModel = struct {
    calls: usize = 0,
    saw_result: bool = false,
    saw_denial: bool = false,

    fn make(raw: *anyopaque, _: std.mem.Allocator, _: *const cfg.Config) !p.Model {
        return .{ .context = raw, .call_fn = call };
    }

    fn call(raw: *anyopaque, a: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *ReviewedBashModel = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (FakeModel.lastToolText(request)) |text| {
            self.saw_result = true;
            self.saw_denial = std.mem.indexOf(u8, text, "Decision requires explicit approval") != null;
            return .{ .success = .{
                .message = try p.textMessage(a, .assistant, "reviewed child done"),
                .finish = .stop,
                .usage = .{ .input_tokens = 10, .output_tokens = 2 },
            } };
        }
        return .{ .success = .{
            .message = try toolCallMessage(a, "reviewed-bash", "bash", "{\"command\":\"printf A >> sentinel.txt\"}"),
            .finish = .tool_calls,
            .usage = .{ .input_tokens = 10, .output_tokens = 2 },
        } };
    }
};

// One real generic reviewer POST, served only on the owned loopback listener.
// The request is parsed before replying so the child must actually use its
// cloned Decision client; no Decision service or transport is injected.
fn serveChildReview(io: std.Io, listener: *std.Io.net.Server, posts: *std.atomic.Value(usize)) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);
    var rb: [8192]u8 = undefined;
    var wb: [8192]u8 = undefined;
    var reader = stream.reader(io, &rb);
    var writer = stream.writer(io, &wb);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var req = try server.receiveHead();
    try std.testing.expectEqual(std.http.Method.POST, req.head.method);
    const size = req.head.content_length orelse return error.MissingLength;
    var body: [16384]u8 = undefined;
    try std.testing.expect(size <= body.len);
    const request_reader = req.readerExpectNone(&.{});
    try request_reader.readSliceAll(body[0..@intCast(size)]);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body[0..@intCast(size)], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("judge", parsed.value.object.get("model").?.string);
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    var envelope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, messages[1].object.get("content").?.string, .{});
    defer envelope.deinit();
    try std.testing.expectEqualStrings("command", envelope.value.object.get("operation").?.string);
    const data = envelope.value.object.get("data").?.object;
    try std.testing.expectEqual(@as(usize, 2), data.count());
    try std.testing.expectEqualStrings(reviewed_command, data.get("command").?.string);
    try std.testing.expect(data.get("risk") != null);
    _ = posts.fetchAdd(1, .release);
    try req.respond(
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"{\\\"ask\\\":true}\"},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":4311,\"completion_tokens\":919,\"total_tokens\":5230}}\n\n" ++
            "data: [DONE]\n\n",
        .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }} },
    );
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

fn runRoot(fix: *Fixture, cancel: *p.Cancellation) anyerror!r.Terminal {
    return fix.parent_runtime.run("delegate the bounded child task", cancel);
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

const GroupProgressModel = struct {
    io: std.Io,
    kind: enum { ignored, ordinary, message, passive },
    entered: std.atomic.Value(bool) = .init(false),
    command: std.atomic.Value(u8) = .init(0),
    observed: std.atomic.Value(u8) = .init(0),
    calls: usize = 0,

    fn make(raw: *anyopaque, _: std.mem.Allocator, _: *const cfg.Config) !p.Model {
        return .{ .context = raw, .call_fn = call };
    }
    fn wait(self: *GroupProgressModel, request: p.Request, target: u8) !void {
        while (self.command.load(.acquire) < target) {
            if (request.cancellation.?.isRequested()) return error.Canceled;
            try std.Io.sleep(self.io, .fromMilliseconds(2), .awake);
        }
    }
    fn call(raw: *anyopaque, a: std.mem.Allocator, request: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *GroupProgressModel = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.entered.store(true, .release);
        if (self.calls == 1) {
            try self.wait(request, 1);
            switch (self.kind) {
                .ordinary => try sink.emit(.{ .text_delta = "SECOND" }),
                .passive => try sink.emit(.{ .text_delta = "THIRD" }),
                .ignored => {
                    try sink.emit(.{ .reasoning_delta = "private reasoning" });
                    try sink.emit(.{ .usage = .{ .total_tokens = 5 } });
                },
                else => {},
            }
            self.observed.store(1, .release);
            try self.wait(request, 2);
            if (self.kind == .message) return .{ .success = .{
                .message = try toolCallMessage(a, "group-message", "message_parent", "{\"message\":\"queued message\"}"),
                .finish = .tool_calls,
            } };
        } else {
            self.observed.store(2, .release);
        }
        try self.wait(request, 3);
        return .{ .success = .{ .message = try p.textMessage(a, .assistant, "done"), .finish = .stop } };
    }
};

fn waitGroupObserved(io: std.Io, value: *const std.atomic.Value(u8), expected: u8) !void {
    const began = std.Io.Clock.awake.now(io);
    while (value.load(.acquire) < expected) {
        if (began.untilNow(io, .awake).toMilliseconds() > 5000) return error.FixtureTimeout;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

fn waitGroupCompleted(fix: *Fixture, expected: u64) !void {
    const began = std.Io.Clock.awake.now(fix.io);
    while (fix.service.view().completed < expected) {
        if (began.untilNow(fix.io, .awake).toMilliseconds() > 5000) return error.FixtureTimeout;
        try std.Io.sleep(fix.io, .fromMilliseconds(2), .awake);
    }
}
