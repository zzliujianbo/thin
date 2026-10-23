//! Dedicated headless automatic Memory lifecycle tests. No App/config files/API.
const std = @import("std");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const k = @import("../core/knowledge.zig");

const Fake = struct {
    retrieves: usize = 0,
    completes: usize = 0,
    calls: usize = 0,
    summaries: usize = 0,
    finished: usize = 0,
    reference: []const u8 = "project facts A",
    retrieval_error: bool = false,
    retrieval_poison: ?anyerror = null,
    invalid_return: bool = false,
    maxbytes: usize = 0,
    tool: bool = false,
    output: r.Execution = .{ .text = "verified tool fact" },
    fail: bool = false,
    refused: bool = false,
    disconnect: bool = false,
    cancel_stop: ?*p.Cancellation = null,
    box: ?*r.Inbox = null,
    steer: bool = false,
    source_count: usize = 0,
    source_text: [8192]u8 = undefined,
    source_len: usize = 0,
    incomplete: bool = false,
    fn retrieve(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, maxbytes: usize) ![]const u8 {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.retrieves += 1;
        self.maxbytes = maxbytes;
        if (self.retrieval_poison) |err| return err;
        if (self.retrieval_error) return error.OfflineUnavailable;
        if (self.invalid_return) return &@as([8193]u8, @splat('x'));
        return if (self.reference.len <= maxbytes) self.reference else "";
    }
    fn complete(raw: *anyopaque, capture: *const k.Capture) void {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.completes += 1;
        self.source_count = capture.sources.items.len;
        self.incomplete = capture.incomplete;
        self.source_len = 0;
        for (capture.sources.items) |source| {
            const n = @min(source.text.len, self.source_text.len - self.source_len);
            @memcpy(self.source_text[self.source_len..][0..n], source.text[0..n]);
            self.source_len += n;
        }
    }
    fn call(raw: *anyopaque, _: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        if (request.purpose == .summary) {
            self.summaries += 1;
            return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "Earlier work summarized." }} }, .finish = .stop } };
        }
        self.calls += 1;
        if (self.summaries != 0) for (request.messages) |message| {
            try std.testing.expect(message.replay == null);
        };
        if (self.fail) return error.OfflineModelFailure;
        if (self.tool and self.calls == 1) return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "offline-one", .name = "probe", .arguments = "{\"guess\":\"do not capture arguments\"}" } }} },
            .finish = .tool_calls,
        } };
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "assistant conjecture must not be captured" }} }, .finish = .stop, .refused = self.refused } };
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return .{ .payload = raw, .description = "offline probe" };
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        const self: *Fake = @ptrCast(@alignCast(raw));
        return self.output;
    }
    fn authorize(_: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        return .allow_once;
    }
    fn event(raw: ?*anyopaque, event_value: r.Event, _: *const p.Cancellation) !void {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        if (event_value == .finished) self.finished += 1;
        if (event_value == .assistant_committed and event_value.assistant_committed.len == 1 and event_value.assistant_committed[0] == .text) {
            if (self.cancel_stop) |cancel| cancel.cancel();
            if (self.disconnect) return error.OfflineHostGone;
            if (self.steer) {
                self.steer = false;
                _ = try self.box.?.enqueue(std.testing.allocator, .steering, "committed steering fact");
            }
        }
    }
    fn init(self: *Fake, config: *cfg.Config) !r.Runtime {
        var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, config, .{ .context = self, .call_fn = call }, .{ .context = self, .schemas = &.{.{ .name = "probe", .description = "offline", .parameters_json = "{}" }}, .prepare_fn = prepare, .execute_fn = execute }, .{ .context = self, .emit_fn = event, .authorize_fn = authorize }, "stale startup snapshot");
        runtime.memory_hooks = .{ .context = self, .retrieve_fn = retrieve, .complete_fn = complete };
        runtime.inbox = self.box;
        return runtime;
    }
    fn captured(self: *Fake) []const u8 {
        return self.source_text[0..self.source_len];
    }
};
fn configValue() cfg.Config {
    return .{ .provider = .{ .base_url = "http://offline.invalid" }, .model = .{ .name = "fixture", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
}
fn referenceCount(runtime: *r.Runtime) usize {
    var n: usize = 0;
    for (runtime.messages()) |message| if (message.role == .context) {
        for (message.blocks) |block| if (block == .text and std.mem.startsWith(u8, block.text, "Latest Memory reference")) {
            n += 1;
        };
    };
    return n;
}
fn lastReference(runtime: *r.Runtime) []const u8 {
    var latest: []const u8 = "";
    for (runtime.messages()) |message| if (message.role == .context) {
        for (message.blocks) |block| if (block == .text and std.mem.startsWith(u8, block.text, "Latest Memory reference")) {
            latest = block.text;
        };
    };
    return latest;
}

test "automatic Memory headless log-off captures user and complete tool only once" {
    var fake = Fake{ .tool = true };
    var config = configValue();
    config.memory.auto = false; // Manual retrieval remains active; App gates enqueue.
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("durable user fact", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expectEqual(@as(usize, 1), fake.completes);
    try std.testing.expectEqual(@as(usize, 2), fake.source_count);
    try std.testing.expectEqualStrings("durable user factverified tool fact", fake.captured());
    try std.testing.expect(runtime.memory_capture == null);
    try std.testing.expectEqual(@as(u32, 2), terminal.usage.normal_calls);
    try std.testing.expectEqual(@as(u32, 0), terminal.usage.summary_calls);
    try std.testing.expect(fake.maxbytes <= 8192);
}

test "automatic Memory excludes errored canceled truncated cleanup and sensitive tool material" {
    for ([_]r.Execution{
        .{ .text = "error detail", .is_error = true },
        .{ .text = "partial cancellation", .canceled = true },
        .{ .text = "fragment", .truncated = true },
        .{ .text = "Authorization: Bearer hidden" },
    }) |output| {
        var fake = Fake{ .tool = true, .output = output };
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.run("user fact", &cancel);
        if (output.canceled) {
            try std.testing.expectEqual(r.Status.canceled, terminal.status);
            try std.testing.expectEqual(@as(usize, 0), fake.completes);
            continue;
        }
        try std.testing.expectEqual(r.Status.success, terminal.status);
        try std.testing.expectEqualStrings("user fact", fake.captured());
        try std.testing.expectEqual(@as(usize, 1), fake.source_count);
    }
}

test "automatic Memory never completes failure cancellation or assistant commit disconnect" {
    for (0..4) |mode| {
        var cancel: p.Cancellation = .{};
        var fake = Fake{ .fail = mode == 0, .disconnect = mode == 1, .cancel_stop = if (mode == 2) &cancel else null, .tool = mode == 3, .output = .{ .text = "unsafe", .cleanup_failed = mode == 3 } };
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        const terminal = try runtime.run("user fact", &cancel);
        try std.testing.expect(terminal.status != .success);
        try std.testing.expectEqual(@as(usize, 0), fake.completes);
        try std.testing.expect(runtime.memory_capture == null);
    }
}

test "automatic Memory refused response remains visible successful but never enqueues" {
    var fake = Fake{ .refused = true };
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("refused task", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 0), fake.completes);
    try std.testing.expectEqual(@as(usize, 1), fake.finished);
    const last = runtime.messages()[runtime.messages().len - 1];
    try std.testing.expectEqual(p.Role.assistant, last.role);
    try std.testing.expectEqualStrings("assistant conjecture must not be captured", last.blocks[0].text);
    fake.refused = false;
    _ = try runtime.run("next normal task", &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.completes);
    try std.testing.expectEqualStrings("next normal task", fake.captured());
}

test "automatic Memory final-stop steering commits before capture and followup gets own task" {
    var box: r.Inbox = .{};
    defer box.deinit();
    var fake = Fake{ .box = &box, .steer = true };
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    _ = try box.enqueue(std.testing.allocator, .follow_up, "future followup fact");
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("original fact", &cancel)).status);
    try std.testing.expectEqualStrings("original factcommitted steering fact", fake.captured());
    try std.testing.expectEqual(@as(usize, 1), fake.completes);
    const lease = box.claimNext().?;
    var followup = box.commit(lease).?;
    defer followup.deinit();
    try std.testing.expectEqual(r.Status.success, (try runtime.run(followup.text, &cancel)).status);
    try std.testing.expectEqualStrings("future followup fact", fake.captured());
    try std.testing.expectEqual(@as(usize, 2), fake.completes);
}

test "automatic Memory fresh retrieval deduplicates latest reference but refreshes changes empty and unavailable" {
    var fake = Fake{};
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("one", &cancel);
    _ = try runtime.run("two", &cancel);
    try std.testing.expectEqual(@as(usize, 1), referenceCount(&runtime));
    fake.reference = "project facts B";
    _ = try runtime.run("three", &cancel);
    fake.reference = "project facts A";
    _ = try runtime.run("four", &cancel);
    try std.testing.expectEqual(@as(usize, 3), referenceCount(&runtime));
    fake.reference = "";
    _ = try runtime.run("five", &cancel);
    try std.testing.expect(std.mem.find(u8, lastReference(&runtime), "is empty") != null);
    fake.retrieval_error = true;
    _ = try runtime.run("six", &cancel);
    try std.testing.expect(std.mem.find(u8, lastReference(&runtime), "unavailable") != null);
    fake.retrieval_error = false;
    fake.invalid_return = true;
    _ = try runtime.run("seven", &cancel);
    try std.testing.expect(std.mem.find(u8, lastReference(&runtime), "invalid retrieval") != null);
    try std.testing.expectEqual(@as(usize, 7), fake.retrieves);
    try std.testing.expectEqual(@as(usize, 7), fake.completes);
}

test "automatic Memory validates input before retrieve and command compact never capture" {
    var fake = Fake{};
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("\xff", &cancel);
    _ = try runtime.run("   ", &cancel);
    _ = try runtime.executeCommand("!printf offline", &cancel);
    _ = try runtime.compactContext(&cancel);
    try std.testing.expectEqual(@as(usize, 0), fake.retrieves);
    try std.testing.expectEqual(@as(usize, 0), fake.completes);
}

test "automatic Memory retrieval budget reserves incoming text and respects calibrated context room" {
    var fake = Fake{};
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    runtime.estimator.per_mille = 2000;
    const query = "small user input";
    config.limits.max_input_tokens = @intCast(runtime.estimatedTokens() + 400);
    var cancel: p.Cancellation = .{};
    _ = try runtime.run(query, &cancel);
    try std.testing.expect(fake.maxbytes < 400);
    try std.testing.expect(fake.maxbytes <= 8192);
    try std.testing.expectEqual(@as(usize, 1), fake.retrieves);
}

test "automatic Memory unsafe retrieval poisons Runtime before any primary request" {
    for ([_]anyerror{ error.CleanupFailed, error.UnsafeToContinue }) |failure| {
        var fake = Fake{ .retrieval_poison = failure };
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        try std.testing.expectEqual(r.Status.failed, (try runtime.run("safe user input", &cancel)).status);
        try std.testing.expect(runtime.poisoned);
        fake.retrieval_poison = null;
        _ = try runtime.run("later task", &cancel);
        try std.testing.expectEqual(@as(usize, 0), fake.calls);
        try std.testing.expectEqual(@as(usize, 0), fake.completes);
        try std.testing.expectEqual(@as(usize, 1), fake.retrieves);
    }
}

test "automatic Memory zero retrieval budget still snapshots generation without appending" {
    var fake = Fake{};
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    config.limits.max_input_tokens = 1;
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("valid task", &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.retrieves);
    try std.testing.expectEqual(@as(usize, 0), fake.maxbytes);
    try std.testing.expectEqual(@as(usize, 0), referenceCount(&runtime));
    _ = try runtime.run("second task", &cancel);
    try std.testing.expectEqual(@as(usize, 2), fake.retrieves);
    try std.testing.expectEqual(@as(usize, 0), fake.completes);
}

test "automatic Memory restore consults current Store instead of trusting saved context" {
    var first = Fake{};
    var config = configValue();
    var runtime = try first.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("old task", &cancel);
    const state = try runtime.exportCheckpoint();
    var second = Fake{ .reference = "current Store B" };
    var restored = try second.init(&config);
    defer restored.deinit();
    try restored.restoreCheckpoint(state);
    try std.testing.expectEqual(@as(usize, 0), second.retrieves);
    _ = try restored.run("new task", &cancel);
    try std.testing.expectEqual(@as(usize, 1), second.retrieves);
    try std.testing.expect(std.mem.endsWith(u8, lastReference(&restored), "current Store B"));
    try std.testing.expectEqualStrings("new task", second.captured());
}

test "automatic Memory survives compaction arena replacement and reinserts reference after signed-prefix rewrite" {
    var fake = Fake{};
    var config = configValue();
    config.model.protocol = .anthropic;
    config.model.output_tokens = 8192;
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("old task", &cancel);
    const a = runtime.arena.allocator();
    const old_text: [6500]u8 = @splat('x');
    try runtime.history.append(a, try p.textMessage(a, .user, &old_text));
    try runtime.history.append(a, try p.cloneMessage(a, .{
        .role = .assistant,
        .blocks = &.{ .{ .reasoning = "old signed thought" }, .{ .text = "old verified answer" } },
        .replay = .{ .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .anthropic }, .json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"old signed thought\",\"signature\":\"old\"},{\"type\":\"text\",\"text\":\"old verified answer\"}]}", .retain_turn = true },
    }));
    const old_arena = runtime.history.items.ptr;
    // Trigger a real summary below the hard request gate; do not make the
    // summary itself exceed the explicit input ceiling.
    config.limits.max_input_tokens = 12000;
    config.limits.compaction_trigger_percent = 20;
    config.limits.compaction_target_percent = 10;
    const terminal = try runtime.run("current durable fact", &cancel);
    try std.testing.expectEqual(@as(?anyerror, null), terminal.detail);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expect(fake.summaries > 0);
    try std.testing.expect(old_arena != runtime.history.items.ptr);
    try std.testing.expectEqualStrings("current durable fact", fake.captured());
    const before = referenceCount(&runtime);
    _ = try runtime.run("next durable fact", &cancel);
    try std.testing.expectEqual(before + 1, referenceCount(&runtime));
    try std.testing.expectEqual(@as(usize, 3), fake.completes);
    try std.testing.expect(std.mem.endsWith(u8, lastReference(&runtime), fake.reference));
}

test "automatic Memory tool-prefix rewrite retains actual usage observation" {
    var fake = Fake{};
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("user input", &cancel);
    runtime.last_context_tokens = 1234;
    var prefix = try runtime.prepareToolPrefix();
    runtime.installToolPrefix(&prefix);
    try std.testing.expectEqual(@as(?u64, 1234), runtime.last_context_tokens);
    try std.testing.expectEqual(@as(usize, 1), fake.completes);
}

test "automatic Memory expected version requires same topic category Related and rejects sensitive candidates" {
    const sources = [_]k.Evidence{.{ .id = 0, .kind = .user, .text = "Use focused offline tests" }};
    const version = "1111111111111111111111111111111111111111111111111111111111111111";
    var material = k.Material{ .id = "offline", .generation = 1, .created_ms = 1, .sources = &sources, .related = &.{.{ .category = .project, .topic = "testing", .content = "old fact", .version = version }} };
    var candidate = k.Candidate{ .category = .project, .topic = "testing", .content = "Use focused offline tests", .source_id = 0, .quote = "focused offline tests", .expected_version = version };
    try k.validate(material, &.{candidate});
    candidate.topic = "other-topic";
    try std.testing.expectError(error.InvalidMemoryVersion, k.validate(material, &.{candidate}));
    candidate.topic = "testing";
    candidate.category = .preferences;
    try std.testing.expectError(error.InvalidMemoryVersion, k.validate(material, &.{candidate}));
    candidate.category = .project;
    candidate.expected_version = "2222222222222222222222222222222222222222222222222222222222222222";
    try std.testing.expectError(error.InvalidMemoryVersion, k.validate(material, &.{candidate}));
    candidate.expected_version = "unknown";
    try std.testing.expectError(error.InvalidMemoryVersion, k.validate(material, &.{candidate}));
    candidate.expected_version = null;
    candidate.content = "Authorization: Bearer credential";
    try std.testing.expectError(error.InvalidMemoryEvidence, k.validate(material, &.{candidate}));
    candidate.content = "safe fact";
    material.related = &.{};
    try k.validate(material, &.{candidate});
}

test "automatic Memory Capture bounded omitted UTF8 assistant sensitive and OOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = k.Capture{ .allocator = arena.allocator() };
    capture.add(.assistant, "conjecture");
    capture.add(.user, "read /home/user/.ssh/id_rsa");
    capture.add(.tool, "-----BEGIN PRIVATE KEY-----");
    capture.add(.tool, "\xff");
    capture.add(.tool, &@as([4097]u8, @splat('x')));
    capture.add(.user, "verified durable fact");
    try std.testing.expectEqual(@as(usize, 1), capture.sources.items.len);
    try std.testing.expectEqual(@as(usize, 5), capture.omitted_sources);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var oom = k.Capture{ .allocator = failing.allocator() };
    oom.add(.user, "fact");
    try std.testing.expect(oom.incomplete);
}
