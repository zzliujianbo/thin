test "thinking runtime normal and summary requests map current model" {
    const Stub = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            return error.UnexpectedRequest;
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    var dummy: u8 = 0;
    var config: cfg.Config = .{ .provider = .{ .base_url = "https://api.deepseek.com" }, .model = .{ .name = "deepseek-flash", .context_tokens = 32768, .protocol = .chat, .reasoning_effort = "medium", .reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high", .max = "max" } } }, .limits = .{ .low_price_input = false } };
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &dummy, .call_fn = Stub.call }, .{ .context = &dummy, .schemas = &.{}, .prepare_fn = Stub.prepare, .execute_fn = Stub.execute }, .{}, "");
    defer runtime.deinit();
    const cancel: p.Cancellation = .{};
    var control: ThinkingControl = .{};
    runtime.thinking_control = &control;
    const old_request = try runtime.request(.normal, &.{}, &cancel);
    var strings = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer strings.deinit();
    const opaque_wire = try strings.allocator().dupe(u8, "opaque-wire-value");
    control.publish(.{ .reasoning_effort = "off", .reasoning = .{ .map = .{ .off = "first" } } });
    control.publish(.{ .reasoning_effort = "high", .reasoning = .{ .map = .{ .max = opaque_wire } } });
    const next = try runtime.request(.normal, &.{}, &cancel);
    try std.testing.expectEqualStrings("high", old_request.reasoning_effort.?);
    try std.testing.expectEqualStrings(opaque_wire, next.reasoning_effort.?);
    try std.testing.expectEqualStrings("medium", config.model.reasoning_effort.?);
    // Both constructed requests cross the real model gate without network IO.
    try std.testing.expectError(error.UnexpectedRequest, runtime.checkedModel().call(std.testing.allocator, old_request, .{}));
    try std.testing.expectError(error.UnexpectedRequest, runtime.checkedModel().call(std.testing.allocator, next, .{}));
    control.clear();
    try std.testing.expectEqualStrings(opaque_wire, next.reasoning_effort.?);
    try std.testing.expectEqualStrings("high", (try runtime.request(.normal, &.{}, &cancel)).reasoning_effort.?);
    for ([_]p.Purpose{ .normal, .summary }) |purpose| {
        const req = try runtime.request(purpose, &.{}, &cancel);
        try std.testing.expectEqualStrings("high", req.reasoning_effort.?);
        try std.testing.expect(req.thinking.?);
        try std.testing.expectEqual(thinking.Format.deepseek, req.reasoning_format);
    }
    config.model.reasoning_effort = null;
    try std.testing.expect((try runtime.request(.summary, &.{}, &cancel)).thinking == null);
    config.provider.base_url = "https://proxy";
    config.model.reasoning = .{ .map = .{ .off = "none", .max = "own-wire" } };
    config.model.reasoning_effort = "high";
    const req = try runtime.request(.normal, &.{}, &cancel);
    try std.testing.expectEqualStrings("own-wire", req.reasoning_effort.?);
    try std.testing.expect(req.thinking == null);
}
test "unlimited round counter saturates without imposing a hidden limit" {
    var task: Runtime.Task = .{ .rounds = std.math.maxInt(u16) };
    task.countRound();
    try std.testing.expectEqual(@as(u32, 65536), task.rounds);
    try std.testing.expect(!task.roundLimitReached(null));
    try std.testing.expect(task.roundLimitReached(4096));
    task.rounds = std.math.maxInt(u32) - 1;
    task.countRound();
    task.countRound();
    try std.testing.expectEqual(std.math.maxInt(u32), task.rounds);
    try std.testing.expect(!task.roundLimitReached(null));
    try std.testing.expect(task.roundLimitReached(50));
    var usage: UsageTotals = .{ .normal_calls = std.math.maxInt(u32), .summary_calls = std.math.maxInt(u32) };
    usage.add(.normal, zeroUsage());
    usage.add(.summary, zeroUsage());
    try std.testing.expectEqual(std.math.maxInt(u32), usage.normal_calls);
    try std.testing.expectEqual(std.math.maxInt(u32), usage.summary_calls);
}
test "runtime checkpoint restore ignores archived policy poison and estimator without config mutation" {
    const Stub = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            return error.UnexpectedRequest;
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    var dummy: u8 = 0;
    var config: cfg.Config = .{ .provider = .{ .base_url = "http://unused.invalid" }, .model = .{ .name = "test", .context_tokens = 65536, .protocol = .chat } };
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &dummy, .call_fn = Stub.call }, .{ .context = &dummy, .schemas = &.{}, .prepare_fn = Stub.prepare, .execute_fn = Stub.execute }, .{}, "original");
    defer runtime.deinit();
    var state = try runtime.checkpoint();
    try std.testing.expectEqual(@as(?u32, 65536), state.context_tokens);
    try std.testing.expect(!state.context_official);
    state.system = "restored";
    state.context_tokens = 32768;
    state.context_official = true;
    state.output_tokens = 0;
    state.output_budget_frozen = true;
    state.input_budget_frozen = true;
    state.max_input_tokens = 0;
    state.input_margin_tokens = std.math.maxInt(u32);
    state.poisoned = true;
    state.permission_id = 999;
    state.estimator.per_mille = 0;
    try runtime.restoreCheckpoint(state);
    try std.testing.expect(!runtime.poisoned);
    try std.testing.expectEqual(@as(u64, 0), runtime.permission_id);
    try std.testing.expectEqual(@as(u64, 1000), runtime.estimator.per_mille);
    try std.testing.expectEqual(@as(?u32, null), config.limits.max_input_tokens);
    try std.testing.expectEqual(@as(u32, 65536), config.model.context_tokens);
    try std.testing.expectEqualStrings("restored", runtime.system);
    const restored = try runtime.checkpoint();
    try std.testing.expectEqual(@as(?u32, 65536), restored.context_tokens);
    try std.testing.expectEqual(config.model.output_tokens, restored.output_tokens);
    // Provenance belongs to Session rather than mutable Runtime state.
    try std.testing.expect(!restored.context_official);
    runtime.poisoned = true;
    _ = try runtime.checkpoint(); // Saving displayable history is not permission to send.
    try std.testing.expectError(error.UnsafeToContinue, runtime.restoreCheckpoint(state));
    try std.testing.expectEqualStrings("restored", runtime.system);
    try std.testing.expect(runtime.poisoned);
    runtime.poisoned = false;
    state.context_tokens = null;
    state.context_official = false;
    state.system = "legacy";
    try runtime.restoreCheckpoint(state);
    try std.testing.expectEqual(@as(u32, 65536), config.model.context_tokens);
    try std.testing.expectEqualStrings("legacy", runtime.system);
}
test "restored foreign scope blocks normal replay but permits text-only summary data" {
    const Fake = struct {
        calls: usize = 0,
        tools: usize = 0,
        fn call(raw: *anyopaque, alloc: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqual(p.Purpose.summary, req.purpose);
            const anthropic = req.scope.protocol == .anthropic;
            try std.testing.expectEqualStrings(if (anthropic) "high" else "summary-wire", req.reasoning_effort.?);
            try std.testing.expectEqual(if (anthropic) thinking.Format.anthropic else .standard, req.reasoning_format);
            try std.testing.expectEqual(if (anthropic) @as(?bool, true) else null, req.thinking);
            try std.testing.expectEqual(@as(usize, 0), req.tools.len);
            for (req.messages) |message| {
                try std.testing.expect(message.replay == null);
                for (message.blocks) |block| try std.testing.expect(block == .text);
            }
            return .{ .success = .{ .finish = .stop, .message = try p.textMessage(alloc, .assistant, "Old context summarized as background data.") } };
        }
        fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tools += 1;
            return error.UnexpectedTool;
        }
        fn execute(raw: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tools += 1;
            return error.UnexpectedTool;
        }
    };
    const a = std.testing.allocator;
    const archived = try a.alloc(u8, 4000);
    defer a.free(archived);
    @memset(archived, 'q');
    inline for (.{ p.Protocol.chat, p.Protocol.responses, p.Protocol.anthropic }) |proto| {
        var config: cfg.Config = .{ .provider = .{ .base_url = "https://current.invalid/v1" }, .model = .{ .name = "current", .context_tokens = 65536, .protocol = proto, .output_tokens = 8192 } };
        config.limits.low_price_input = false;
        var fake: Fake = .{};
        var runtime = try Runtime.init(a, std.testing.io, &config, .{ .context = &fake, .call_fn = Fake.call }, .{ .context = &fake, .schemas = &.{}, .prepare_fn = Fake.prepare, .execute_fn = Fake.execute }, .{}, "");
        defer runtime.deinit();
        var control: ThinkingControl = .{};
        runtime.thinking_control = &control;
        // Keep the override legal at the actual protocol encoder boundary.
        control.publish(.{ .reasoning_effort = "high", .reasoning = .{
            .format = if (proto == .anthropic) .anthropic else .standard,
            .map = .{ .high = if (proto == .anthropic) "high" else "summary-wire" },
        } });
        const state: @import("checkpoint.zig").State = .{
            .system = "archive",
            .messages = &.{
                .{ .role = .user, .blocks = &.{.{ .text = archived }} },
                .{ .role = .assistant, .blocks = &.{.{ .text = "old" }}, .replay = .{ .scope = .{ .connection = "https://old.invalid/v1", .model = "old", .protocol = .chat }, .json = "{\"role\":\"assistant\",\"content\":\"old\"}" } },
                .{ .role = .user, .blocks = &.{.{ .text = "second old goal" }} },
                .{ .role = .assistant, .blocks = &.{.{ .text = "recent answer" }} },
                .{ .role = .user, .blocks = &.{.{ .text = "retained goal" }} },
            },
            .selector = .{ .configured = .auto, .selected = .chat },
            .estimator = .{},
            .last_context_tokens = 100,
            .permission_id = 999,
            .context_tokens = 0,
            .output_budget_frozen = true,
            .output_tokens = 0,
            .poisoned = true,
        };
        try runtime.restoreCheckpoint(state);
        const bytes = try @import("checkpoint.zig").encode(a, try runtime.checkpoint());
        defer a.free(bytes);
        const decoded = try @import("checkpoint.zig").decode(a, bytes);
        defer decoded.deinit();
        try std.testing.expectEqualStrings("old", runtime.messages()[1].blocks[0].text);
        var cancel: p.Cancellation = .{};
        const normal = try runtime.run("new goal", &cancel);
        try std.testing.expectEqual(error.ReplayScopeMismatch, normal.detail.?);
        if (proto == .anthropic) {
            const retained_count = runtime.messages().len;
            config.model.output_tokens = null;
            const unknown = try runtime.compactContext(&cancel);
            try std.testing.expectEqual(error.UnknownModelOutputCapacity, unknown.detail.?);
            try std.testing.expectEqual(@as(usize, 0), fake.calls);
            try std.testing.expectEqual(retained_count, runtime.messages().len);
            config.model.output_tokens = 8192;
        }
        const summary = try runtime.compactContext(&cancel);
        try std.testing.expectEqual(Status.success, summary.status);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expectEqual(@as(usize, 0), fake.tools);
        try std.testing.expect(config.model.reasoning_effort == null);
        try std.testing.expect(config.model.reasoning == null);
    }
}
test "compatible restored history sends under current budgets without any archived key binding" {
    const Fake = struct {
        calls: usize = 0,
        fn call(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .success = .{ .finish = .stop, .message = try p.textMessage(a, .assistant, "new answer") } };
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    var config: cfg.Config = .{ .provider = .{ .base_url = "https://fixture.invalid/v1", .api_key = "rotated-fake-key" }, .model = .{ .name = "fixture", .context_tokens = 65536, .protocol = .chat } };
    config.limits.low_price_input = false;
    var fake: Fake = .{};
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fake, .call_fn = Fake.call }, .{ .context = &fake, .schemas = &.{}, .prepare_fn = Fake.prepare, .execute_fn = Fake.execute }, .{}, "");
    defer runtime.deinit();
    var state = try runtime.checkpoint();
    state.context_tokens = 1;
    state.output_tokens = 0;
    state.max_input_tokens = 0;
    state.messages = &.{
        .{ .role = .user, .blocks = &.{.{ .text = "previous goal" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "old" }}, .replay = .{ .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .chat }, .json = "{\"role\":\"assistant\",\"content\":\"old\"}" } },
    };
    try runtime.restoreCheckpoint(state);
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("new goal", &cancel);
    try std.testing.expectEqual(Status.success, terminal.status);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(u32, 65536), config.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, null), config.limits.max_input_tokens);
}
test "restored incomplete tool history never executes old tools or calls a fake model" {
    const Stub = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            return error.UnexpectedRequest;
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    var dummy: u8 = 0;
    var config: cfg.Config = .{ .provider = .{ .base_url = "https://fixture.invalid/v1" }, .model = .{ .name = "fixture", .context_tokens = 65536, .protocol = .chat } };
    config.limits.low_price_input = false;
    config.limits.compaction_enabled = false;
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &dummy, .call_fn = Stub.call }, .{ .context = &dummy, .schemas = &.{}, .prepare_fn = Stub.prepare, .execute_fn = Stub.execute }, .{}, "");
    defer runtime.deinit();
    var state = try runtime.checkpoint();
    state.messages = &.{
        .{ .role = .user, .blocks = &.{.{ .text = "old goal" }} },
        .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "old-call", .name = "never-execute", .arguments = "{}" } }} },
    };
    try runtime.restoreCheckpoint(state);
    const saved = try @import("checkpoint.zig").encode(std.testing.allocator, try runtime.checkpoint());
    defer std.testing.allocator.free(saved);
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("new explicit goal", &cancel);
    try std.testing.expectEqual(error.IncompleteToolGroup, terminal.detail.?);
}
test "selection preserves canonical history and closes retained auto fallback" {
    const Stub = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            return error.UnexpectedRequest;
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    var dummy: u8 = 0;
    var config: cfg.Config = .{ .provider = .{ .base_url = "http://unused.invalid" }, .model = .{ .name = "old", .context_tokens = 32768, .protocol = .chat } };
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &dummy, .call_fn = Stub.call }, .{ .context = &dummy, .schemas = &.{}, .prepare_fn = Stub.prepare, .execute_fn = Stub.execute }, .{}, "");
    defer runtime.deinit();
    const source: p.Message = .{ .role = .assistant, .blocks = &.{ .{ .reasoning = "native-only summary" }, .{ .text = "retained" }, .{ .tool_call = .{ .id = "id", .item_id = "old-native-item", .name = "test", .arguments = "{}" } } }, .replay = .{ .scope = .{ .connection = "c", .model = "old", .protocol = .chat }, .json = "[]" } };
    try runtime.history.append(runtime.arena.allocator(), try p.cloneMessage(runtime.arena.allocator(), source));
    try runtime.history.append(runtime.arena.allocator(), try p.cloneMessage(runtime.arena.allocator(), .{ .role = .assistant, .blocks = &.{.{ .reasoning = "native-only message" }}, .replay = source.replay }));
    try runtime.history.append(runtime.arena.allocator(), try p.cloneMessage(runtime.arena.allocator(), .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "id", .text = "ok" } }} }));
    runtime.protected_index = 2;
    runtime.estimator.per_mille = 2200;
    var next = config.model;
    next.reasoning_effort = "high";
    next.context_tokens = 65536;
    try runtime.prepareSelection(next);
    try std.testing.expect(runtime.history.items[0].replay != null);
    try std.testing.expectEqual(@as(u64, 2200), runtime.estimator.per_mille);
    config.model = next;
    next.name = "new";
    runtime.busy.store(true, .release);
    try std.testing.expectError(error.Busy, runtime.prepareSelection(next));
    runtime.busy.store(false, .release);
    runtime.poisoned = true;
    try std.testing.expectError(error.UnsafeToContinue, runtime.prepareSelection(next));
    runtime.poisoned = false;
    try std.testing.expect(runtime.history.items[0].replay != null);
    next.protocol = .auto;
    try runtime.prepareSelection(next);
    try std.testing.expect(runtime.history.items[0].replay == null);
    try std.testing.expectEqual(@as(usize, 2), runtime.history.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.protected_index);
    try std.testing.expectEqualStrings("retained", runtime.history.items[0].blocks[0].text);
    try std.testing.expect(runtime.history.items[0].blocks[1].tool_call.item_id == null);
    try std.testing.expectEqualStrings("id", runtime.history.items[1].blocks[0].tool_result.call_id);
    for ([_]p.Protocol{ .chat, .responses }) |protocol| {
        const request_: p.Request = .{ .scope = .{ .connection = "c", .model = next.name, .protocol = protocol }, .system = runtime.system, .tools = &.{}, .messages = runtime.messages() };
        const encoded = if (protocol == .chat) try @import("../llm/chat.zig").encode(std.testing.allocator, request_) else try @import("../llm/responses.zig").encode(std.testing.allocator, request_);
        defer std.testing.allocator.free(encoded);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "old-native-item") == null);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "native-only") == null);
        try std.testing.expect(std.mem.indexOf(u8, encoded, "retained") != null);
    }
    try std.testing.expectEqual(@as(u64, 1000), runtime.estimator.per_mille);
    try std.testing.expectEqual(p.Protocol.chat, runtime.selector.selected.?);
    try std.testing.expect(runtime.selector.initial_attempted);
    config.model = next;
    next.name = "another";
    const selector = runtime.selector;
    try runtime.prepareSelection(next);
    try std.testing.expectEqualDeep(selector, runtime.selector);
    config.model = next;
    next.protocol = .responses;
    try runtime.prepareSelection(next);
    try std.testing.expectEqual(p.Protocol.responses, runtime.selector.selected.?);
    config.model = next;
    runtime.history.clearRetainingCapacity();
    next.protocol = .auto;
    try runtime.prepareSelection(next);
    try std.testing.expect(runtime.selector.selected == null);
    try std.testing.expect(!runtime.selector.initial_attempted);
}
test "default low price policy refuses unknown pricing before inference and explicit optout runs" {
    const Fake = struct {
        calls: usize = 0,
        fn call(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .success = .{ .finish = .stop, .message = try p.textMessage(a, .assistant, "fixture answer") } };
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    for ([_]bool{ true, false }) |use_default| {
        var config: cfg.Config = .{ .provider = .{ .base_url = "https://fixture.invalid/v1" }, .model = .{ .name = "fixture", .protocol = .chat, .context_tokens = 32768 } };
        if (!use_default) config.limits.low_price_input = false;
        var fake: Fake = .{};
        var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fake, .call_fn = Fake.call }, .{ .context = &fake, .schemas = &.{}, .prepare_fn = Fake.prepare, .execute_fn = Fake.execute }, .{}, "");
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        const result = try runtime.run("fixture goal", &cancel);
        if (use_default) {
            try std.testing.expectEqual(Status.paused, result.status);
            try std.testing.expectEqual(error.UnknownInputPriceThreshold, result.detail.?);
            try std.testing.expectEqual(@as(usize, 0), fake.calls);
        } else {
            try std.testing.expectEqual(Status.success, result.status);
            try std.testing.expectEqual(@as(usize, 1), fake.calls);
        }
        try std.testing.expectEqualStrings("fixture goal", runtime.messages()[0].blocks[0].text);
    }
}
test "poisoned actual model gate wins over pre-cancellation and invalid request for either purpose" {
    const Stub = struct {
        calls: usize = 0,
        fn call(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return error.UnexpectedRequest;
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    var stub: Stub = .{};
    var config: cfg.Config = .{ .provider = .{ .base_url = "http://unused.invalid" }, .model = .{ .name = "test", .context_tokens = 65536, .protocol = .chat } };
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &stub, .call_fn = Stub.call }, .{
        .context = &stub,
        .schemas = &.{},
        .prepare_fn = Stub.prepare,
        .execute_fn = Stub.execute,
    }, .{}, "");
    defer runtime.deinit();
    runtime.poisoned = true;
    var cancel: p.Cancellation = .{};
    for ([_]bool{ false, true }) |canceled| {
        if (canceled) cancel.cancel();
        for ([_]p.Purpose{ .normal, .summary }) |purpose| {
            // Poison must win before request history or input validation.
            const req: p.Request = .{ .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .chat }, .system = "", .messages = &.{}, .tools = &.{}, .purpose = purpose, .cancellation = &cancel };
            try std.testing.expectError(error.CleanupFailed, runtime.checkedModel().call(std.testing.allocator, req, .{}));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), stub.calls);
}
test "memory reference preserves latest primary usage while input safety estimates still grow" {
    const Stub = struct {
        calls: usize = 0,
        fn call(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return error.UnexpectedRequest;
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    for ([_]?u64{ 0, 1234, null }) |reported| {
        var stub: Stub = .{};
        var config: cfg.Config = .{ .provider = .{ .base_url = "http://unused.invalid" }, .model = .{ .name = "test", .context_tokens = 65536, .protocol = .chat } };
        var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &stub, .call_fn = Stub.call }, .{ .context = &stub, .schemas = &.{}, .prepare_fn = Stub.prepare, .execute_fn = Stub.execute }, .{}, "");
        defer runtime.deinit();
        runtime.last_context_tokens = reported;
        const snapshot = runtime.contextSnapshot();
        const estimate = runtime.estimatedTokens();
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        runtime.appendMemoryReference(scratch.allocator(), "reference A");
        try std.testing.expectEqualDeep(snapshot, runtime.contextSnapshot());
        try std.testing.expect(runtime.estimatedTokens() > estimate);
        const count = runtime.history.items.len;
        runtime.appendMemoryReference(scratch.allocator(), "reference A");
        try std.testing.expectEqual(count, runtime.history.items.len);
        runtime.appendMemoryReference(scratch.allocator(), "reference B");
        try std.testing.expectEqual(count + 1, runtime.history.items.len);
        try std.testing.expectEqualDeep(snapshot, runtime.contextSnapshot());
        try std.testing.expectEqual(@as(usize, 0), stub.calls);
    }
}
test "canceled context preserves only missing cancellation usage and remains per call" {
    const Fake = struct {
        const Mode = enum { thrown_cancel, canceled_empty, canceled_input, canceled_total, canceled_zero, other_error, success_missing };
        mode: Mode,
        calls: usize = 0,
        fn call(raw: *anyopaque, a: std.mem.Allocator, _: p.Request, sink: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls > 2) return error.UnexpectedRequest;
            if (self.calls == 2) return .{ .success = .{
                .finish = .stop,
                .message = try p.textMessage(a, .assistant, "answer"),
                .usage = .{ .input_tokens = 20, .output_tokens = 7 },
            } };
            // Stream usage is deliberately not authoritative.
            try sink.emit(.{ .usage = .{ .input_tokens = 999 } });
            return switch (self.mode) {
                .thrown_cancel => error.Canceled,
                .other_error => error.UnexpectedRequest,
                .canceled_empty => .{ .failure = .{ .kind = .canceled, .message = "canceled" } },
                .canceled_input => .{ .failure = .{ .kind = .canceled, .message = "canceled", .usage = .{ .input_tokens = 50 } } },
                .canceled_total => .{ .failure = .{ .kind = .canceled, .message = "canceled", .usage = .{ .input_tokens = 10, .output_tokens = 5 } } },
                .canceled_zero => .{ .failure = .{ .kind = .canceled, .message = "canceled", .usage = .{ .total_tokens = 0 } } },
                .success_missing => .{ .success = .{ .finish = .stop, .message = try p.textMessage(a, .assistant, "answer") } },
            };
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    for ([_]Fake.Mode{ .thrown_cancel, .canceled_empty, .canceled_input, .canceled_total, .canceled_zero, .other_error, .success_missing }) |mode| {
        for ([_]?u64{ 1234, 0, null }) |prior| {
            var fake: Fake = .{ .mode = mode };
            var config: cfg.Config = .{ .provider = .{ .base_url = "https://fixture.invalid/v1" }, .model = .{ .name = "fixture", .context_tokens = 65536, .protocol = .chat } };
            config.limits.low_price_input = false;
            config.limits.compaction_enabled = false;
            var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fake, .call_fn = Fake.call }, .{ .context = &fake, .schemas = &.{}, .prepare_fn = Fake.prepare, .execute_fn = Fake.execute }, .{}, "");
            defer runtime.deinit();
            runtime.last_context_tokens = prior;
            const before = runtime.estimatedTokens();
            var cancel: p.Cancellation = .{};
            const terminal = try runtime.run("A retained user request with enough text to increase the safety estimate independently of the display count.", &cancel);
            const expected: ?u64 = switch (mode) {
                .thrown_cancel, .canceled_empty, .canceled_input => prior,
                .canceled_total => 15,
                .canceled_zero => 0,
                .other_error, .success_missing => null,
            };
            const status: Status = switch (mode) {
                .other_error => .failed,
                .success_missing => .success,
                else => .canceled,
            };
            try std.testing.expectEqual(status, terminal.status);
            try std.testing.expectEqual(@as(usize, 1), fake.calls);
            try std.testing.expectEqual(expected, runtime.last_context_tokens);
            try std.testing.expectEqualDeep(runtime.contextSnapshot(), terminal.context_snapshot.?);
            try std.testing.expectEqual(expected != null, terminal.context_snapshot.?.known);
            try std.testing.expectEqual(expected orelse 0, terminal.context_snapshot.?.tokens);
            try std.testing.expect(runtime.estimatedTokens() > before);
            if (mode == .canceled_input) try std.testing.expectEqual(@as(?u64, 50), terminal.usage.normal.input_tokens);
            const next = try runtime.run("next request", &cancel);
            try std.testing.expectEqual(Status.success, next.status);
            try std.testing.expectEqual(@as(usize, 2), fake.calls);
            try std.testing.expectEqual(@as(?u64, 27), runtime.last_context_tokens);
            try std.testing.expectEqualDeep(runtime.contextSnapshot(), next.context_snapshot.?);
        }
    }
}
test "subagent tool progress uses executing key and is absent outside execution" {
    const Fake = struct {
        runtime: *Runtime = undefined,
        calls: usize = 0,
        starts: usize = 0,
        results: usize = 0,
        progress: usize = 0,
        bad: bool = false,
        key: ?p.ToolDisplayKey = null,
        fn call(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls == 1) return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{
                .{ .tool_call = .{ .id = "first", .name = "get_subagent_result", .arguments = "{\"id\":\"child-a\"}" } },
                .{ .tool_call = .{ .id = "second", .name = "other", .arguments = "{}" } },
            } }, .finish = .tool_calls } };
            return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} }, .finish = .stop, .usage = .{ .input_tokens = 30, .output_tokens = 5 } } };
        }
        fn prepare(raw: *anyopaque, _: std.mem.Allocator, call_: p.ToolCall) !Prepared {
            return .{ .payload = raw, .description = call_.name };
        }
        fn execute(raw: *anyopaque, _: std.mem.Allocator, prepared: Prepared, cancel: *const p.Cancellation) !Execution {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.runtime.publishSubagentProgress("child-a", if (std.mem.eql(u8, prepared.description, "other")) "wrong" else "working", cancel);
            return .{ .text = "ok" };
        }
        fn emit(raw: ?*anyopaque, event: Event, _: *const p.Cancellation) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            switch (event) {
                .tool_started => |started| {
                    self.starts += 1;
                    if (started.started_ms == null or started.display_key == null) self.bad = true;
                    if (self.starts == 1) self.key = started.display_key;
                },
                .tool_view => |view| if (view.subagent_progress) |text| {
                    self.progress += 1;
                    const key = self.key orelse {
                        self.bad = true;
                        return;
                    };
                    if (self.starts != 1 or self.results != 0 or !view.ready or
                        !std.mem.eql(u8, view.name, "get_subagent_result") or
                        !std.mem.eql(u8, text, "working") or view.fields.id == null or
                        !std.mem.eql(u8, view.fields.id.?.text, "child-a") or
                        !std.meta.eql(key, view.key)) self.bad = true;
                },
                .tool_result => self.results += 1,
                else => {},
            }
        }
    };
    var fake: Fake = .{};
    var config: cfg.Config = .{ .provider = .{ .base_url = "https://fixture.invalid/v1" }, .model = .{ .name = "fixture", .context_tokens = 65536, .protocol = .chat } };
    config.limits.low_price_input = false;
    config.limits.compaction_enabled = false;
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fake, .call_fn = Fake.call }, .{ .context = &fake, .schemas = &.{}, .prepare_fn = Fake.prepare, .execute_fn = Fake.execute }, .{ .context = &fake, .emit_fn = Fake.emit }, "");
    defer runtime.deinit();
    fake.runtime = &runtime;
    var cancel: p.Cancellation = .{};
    runtime.publishSubagentProgress("child-a", "outside", &cancel);
    const terminal = try runtime.run("exercise tools", &cancel);
    runtime.publishSubagentProgress("child-a", "late", &cancel);
    try std.testing.expectEqual(Status.success, terminal.status);
    try std.testing.expectEqual(@as(usize, 2), fake.starts);
    try std.testing.expectEqual(@as(usize, 2), fake.results);
    try std.testing.expectEqual(@as(usize, 1), fake.progress);
    try std.testing.expect(!fake.bad);
    try std.testing.expectEqualDeep(runtime.contextSnapshot(), terminal.context_snapshot.?);
    try std.testing.expectEqual(@as(u64, 35), terminal.context_snapshot.?.tokens);
}
test "system prompt carries approach, completion and UI constraints with quoted startup memory" {
    const Stub = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            return error.UnexpectedRequest;
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: Prepared, _: *const p.Cancellation) !Execution {
            return error.UnexpectedTool;
        }
    };
    var dummy: u8 = 0;
    var config: cfg.Config = .{ .provider = .{ .base_url = "http://unused.invalid" }, .model = .{ .name = "test", .context_tokens = 65536, .protocol = .chat } };
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &dummy, .call_fn = Stub.call }, .{ .context = &dummy, .schemas = &.{}, .prepare_fn = Stub.prepare, .execute_fn = Stub.execute }, .{}, "first line\n\"quoted\" fact");
    defer runtime.deinit();
    const system = runtime.system;
    for ([_][]const u8{
        "You are ThinAgent, a coding assistant.",
        "Respond in the user's language using plain, natural wording.",
        "Preserve quoted code, identifiers, commands, and error messages exactly.",
        "Use the provided tools when needed",
        "Approach: Reason from the user's actual goal, constraints, and success criteria, rather than assuming existing conventions are required.",
        "Answer simple questions directly; avoid unnecessary process, delegation, abstractions, refactoring, dependencies, or unrelated improvements.",
        "不要把简单的事情复杂化，最简单的方案就是最好的架构。编译速度、运行效率是我们的标准之一",
        "Completion: for requested changes, complete related changes before running proportionate verification within the authorized scope.",
        "Avoid repeating checks after every small edit; check earlier when needed to resolve blockers or validate critical assumptions.",
        "UI: for UI work, let layout, hierarchy, and visual relationships explain the interface.",
        "Authorization: do not modify code unless the user authorizes code changes.",
        "Evidence: read relevant files before overwriting.",
        "Authority: the host enforces permissions and limits.",
        "Context: relative tool paths and bash cwd remain anchored to the startup project.",
        "Memory: keep explicit durable project facts or reusable user preferences,",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, system, needle) != null);
    // The replaced identity must not survive as a duplicate concision clause.
    try std.testing.expect(std.mem.indexOf(u8, system, "a concise coding assistant") == null);
    // Startup memory stays a single JSON-quoted literal, so its newline and quote
    // cannot change the surrounding prompt structure.
    try std.testing.expect(std.mem.indexOf(u8, system, "\"first line\\n\\\"quoted\\\" fact\"") != null);
}
