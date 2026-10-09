//! Runtime 无头（headless）行为测试：使用 Fake 替身同时模拟模型、执行器与宿主，验证工具调用、审批、取消、摘要压缩与超时等语义。

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const r = @import("../core/runtime.zig");
const context = @import("../core/context.zig");

/// 1100 字节的长工具输出，用于撑大上下文，从而触发摘要压缩。
const long_output: [1100]u8 = @splat('x');

/// 测试用工具清单：只包含一个 write_file 工具。
const tool_schemas = [_]p.ToolSchema{.{ .name = "write_file", .description = "fixture", .parameters_json = "{\"type\":\"object\"}" }};

/// 测试替身：同时实现模型、执行器与宿主接口。各字段用于配置其行为，并记录调用次数供断言使用。
const Fake = struct {
    /// 普通（非摘要）模型调用次数。
    normal_calls: u32 = 0,
    repeat_tool_id: bool = false,
    /// 摘要请求次数。
    summary_calls: u32 = 0,
    /// 工具实际执行次数，即副作用计数。
    executions: u32 = 0,
    /// 审批请求次数。
    permissions: u32 = 0,
    /// 收到的 finished 终态事件次数，正确情况下应恰好为 1。
    terminals: u32 = 0,
    /// 收到的 compacted 事件次数。
    compactions: u32 = 0,
    /// 模型消息中是否出现过被拒绝（is_error）的 tool_result。
    denied_seen: bool = false,
    /// 完成第几次普通调用之后改为返回纯文本结束。
    stop_after: u32 = 1,
    /// 每次模型响应包含的工具调用数量。
    calls_per_response: usize = 1,
    /// prepare 阶段是否要求审批。
    requires_approval: bool = true,
    /// authorize 返回的审批决定。
    decision: r.Decision = .allow_once,
    /// 工具执行返回的文本。
    output: []const u8 = "written",
    /// 执行工具之后触发取消，用于测试"工具已执行但随后取消"的路径。
    cancel_after_execution: ?*p.Cancellation = null,
    /// 审批回调中触发取消。
    cancel_permission: ?*p.Cancellation = null,
    /// 摘要请求中触发取消。
    cancel_summary: ?*p.Cancellation = null,
    /// 为 true 时摘要响应中夹带工具调用，用于验证它不会被执行。
    bad_summary: bool = false,
    /// 为 true 时模型调用阻塞，直到被取消（用于测试超时）。
    block_model: bool = false,
    /// 为 true 时执行结果标记为清理失败。
    cleanup_failure: bool = false,
    /// 为 true 时在收到 text 事件时模拟宿主断开。
    disconnect_text: bool = false,
    /// 为 true 时在收到 assistant_committed 事件时模拟宿主断开。
    disconnect_committed: bool = false,
    /// 为 true 时不发送文本增量，只提供最终文本。
    omit_deltas: bool = false,
    /// 宿主最近一次收到的已提交文本。
    committed_text: []const u8 = "",
    /// 是否已进入（阻塞的）模型调用。
    entered_model: bool = false,
    /// 指向被测 Runtime，供事件回调读取其 token 估算值。
    current_runtime: ?*r.Runtime = null,
    /// 进入压缩状态前的估算 token 数。
    before_summary_tokens: usize = 0,
    /// 压缩失败后，历史的估算 token 数是否与压缩前一致（即历史被保留）。
    failed_summary_preserved: bool = false,
    /// 首次请求时的 system 提示；之后每次请求都必须与它一致。
    first_system: ?[]const u8 = null,

    /// 返回模型接口，调用分发到 call。
    fn model(self: *Fake) p.Model {
        return .{ .context = self, .call_fn = call };
    }

    /// 返回执行器接口。
    fn executor(self: *Fake) r.Executor {
        return .{ .context = self, .schemas = &tool_schemas, .prepare_fn = prepare, .execute_fn = execute };
    }

    /// 返回宿主接口（事件与审批）。
    fn host(self: *Fake) r.Host {
        return .{ .context = self, .emit_fn = event, .authorize_fn = authorize };
    }

    /// 模拟模型：摘要请求返回固定文本（或非法工具调用）；普通请求先返回工具调用，超过 stop_after 后返回 "done"。
    fn call(ctx: *anyopaque, a: std.mem.Allocator, req: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(ctx));

        // 整个会话的 system 提示必须保持不变，以保证请求前缀稳定。
        if (self.first_system) |system| try std.testing.expectEqualStrings(system, req.system) else self.first_system = req.system;
        try std.testing.expectEqual(@as(usize, 1), req.tools.len);

        if (self.block_model) {
            self.entered_model = true;
            // 阻塞直到 Runtime 发出取消请求（例如任务超时触发的取消）。
            while (!req.cancellation.?.isRequested()) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            return .{ .failure = .{ .kind = .canceled, .message = "canceled fixture" } };
        }

        if (req.purpose == .summary) {
            // 摘要请求：最后一条必须是 user 消息，且历史中须包含原始任务文本。
            self.summary_calls += 1;
            try std.testing.expectEqual(p.Role.user, req.messages[req.messages.len - 1].role);
            var found_task = false;
            for (req.messages) |msg| for (msg.blocks) |block| {
                if (msg.role == .user and block == .text and std.mem.eql(u8, block.text, "Do the task")) found_task = true;
            };
            try std.testing.expect(found_task);

            // 摘要生成过程中触发取消，验证旧历史被保留。
            if (self.cancel_summary) |cancel| cancel.cancel();
            // bad_summary：摘要里夹带工具调用，应被拒绝且不执行。
            if (self.bad_summary) return .{ .success = .{
                .message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "forbidden", .name = "bash", .arguments = "{}" } }} },
                .finish = .tool_calls,
            } };
            return .{ .success = .{
                .message = .{ .role = .assistant, .blocks = &.{.{ .text = "Earlier tool steps completed; continue the requested work." }} },
                .finish = .stop,
                .usage = .{ .output_tokens = 10 },
            } };
        }

        self.normal_calls += 1;
        // 记录历史中出现过的被拒绝工具结果，用于断言拒绝已反馈给模型。
        for (req.messages) |msg| for (msg.blocks) |block| {
            if (block == .tool_result and block.tool_result.is_error) self.denied_seen = true;
        };

        // 达到 stop_after 后返回纯文本结束。
        if (self.normal_calls > self.stop_after) {
            if (!self.omit_deltas) try sink.emit(.{ .text_delta = "done" });
            return .{ .success = .{
                .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} },
                .finish = .stop,
                .usage = .{ .output_tokens = 1 },
            } };
        }

        // 生成指定数量的工具调用；ID 同时包含轮次与序号，便于区分。
        const blocks = try a.alloc(p.Block, self.calls_per_response);
        for (blocks, 0..) |*block, i| block.* = .{ .tool_call = .{
            .id = try std.fmt.allocPrint(a, "call-{d}-{d}", .{ if (self.repeat_tool_id) @as(u32, 1) else self.normal_calls, i }),
            .name = "write_file",
            .arguments = "{}",
        } };
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = blocks }, .finish = .tool_calls, .usage = .{ .output_tokens = 1 } } };
    }

    /// 准备阶段：校验工具名，并返回是否需要审批。
    fn prepare(ctx: *anyopaque, _: std.mem.Allocator, call_: p.ToolCall) !r.Prepared {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, call_.name, "write_file")) return error.UnexpectedTool;
        return .{ .payload = ctx, .description = "write fixture", .requires_approval = self.requires_approval };
    }

    /// 执行工具：执行前先检查取消（已取消则不产生副作用），成功后计数，并按配置返回成功或清理失败。
    fn execute(ctx: *anyopaque, _: std.mem.Allocator, _: r.Prepared, cancel: *const p.Cancellation) !r.Execution {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (cancel.isRequested()) return error.Canceled;
        self.executions += 1;
        if (self.cancel_after_execution) |c| c.cancel();
        return .{ .text = self.output, .cleanup_failed = self.cleanup_failure, .is_error = self.cleanup_failure };
    }

    /// 宿主事件回调：记录计数、已提交文本与压缩状态；配置了 disconnect 时返回 Disconnected，模拟宿主断开。
    fn event(ctx: ?*anyopaque, ev: r.Event, _: *const p.Cancellation) !void {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .assistant_committed => |blocks| {
                if (self.disconnect_committed) return error.Disconnected;
                for (blocks) |block| if (block == .text) {
                    self.committed_text = block.text;
                };
            },
            .finished => self.terminals += 1,
            .compacted => self.compactions += 1,
            // 进入压缩前记录 token 估算值，供后续比较。
            .state => |state| if (state == .compacting) {
                self.before_summary_tokens = self.current_runtime.?.estimatedTokens();
            },
            // 压缩失败后 token 数应与压缩前一致，说明历史未被破坏。
            .compaction_failed => self.failed_summary_preserved = self.before_summary_tokens == self.current_runtime.?.estimatedTokens(),
            .text => if (self.disconnect_text) {
                return error.Disconnected;
            },
            else => {},
        }
    }

    /// 审批回调：计数，可选地触发取消，并返回预设的审批决定。
    fn authorize(ctx: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.permissions += 1;
        if (self.cancel_permission) |cancel| cancel.cancel();
        return self.decision;
    }
};
/// 基础配置：本地 provider 与 fake 模型，上下文窗口为 32768 tokens。
fn configuration() cfg.Config {
    return .{
        .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat },
    };
}
/// 小上下文配置：窗口仅 3000 tokens，输出、摘要与安全余量都缩小，使长任务很快触发压缩。
fn smallConfiguration() cfg.Config {
    var config = configuration();
    config.model.context_tokens = 3000;
    config.limits.max_output_tokens = 100;
    config.limits.summary_tokens = 100;
    config.limits.safety_tokens = 100;
    return config;
}

test "Runtime local budget rejection recovers first and established turns for every protocol" {
    for ([_]p.Protocol{ .chat, .responses, .auto }) |protocol| {
        var fake = Fake{ .stop_after = 0 };
        var config = smallConfiguration();
        config.model.protocol = protocol;
        var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
        defer runtime.deinit();
        fake.current_runtime = &runtime;
        var cancel = p.Cancellation{};
        const oversized: [16000]u8 = @splat('x');
        const first = try runtime.run(&oversized, &cancel);
        try std.testing.expectEqual(error.ContextTooLarge, first.detail.?);
        try std.testing.expectEqual(@as(usize, 0), runtime.messages().len);
        try std.testing.expectEqual(@as(u32, 0), fake.normal_calls);
        try std.testing.expectEqual(r.Status.success, (try runtime.run("Do the task", &cancel)).status);
        const before = runtime.messages().len;
        const rejected = try runtime.run(&oversized, &cancel);
        try std.testing.expectEqual(error.ContextTooLarge, rejected.detail.?);
        try std.testing.expectEqual(before, runtime.messages().len);
        try std.testing.expectEqualStrings("Do the task", runtime.messages()[0].blocks[0].text);
        try std.testing.expectEqualStrings("done", runtime.messages()[1].blocks[0].text);
        try std.testing.expectEqual(r.Status.success, (try runtime.run("short", &cancel)).status);
        try std.testing.expectEqual(@as(u32, 2), fake.normal_calls);
        try std.testing.expectEqual(@as(u32, 0), fake.summary_calls);
    }
}

test "Runtime rollback after committed compaction uses remapped history" {
    var fake = Fake{ .stop_after = 0 };
    var config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const older: [6000]u8 = @splat('x');
    try std.testing.expectEqual(r.Status.success, (try runtime.run(&older, &cancel)).status);
    config = smallConfiguration();
    config.limits.compaction_trigger_percent = 50;
    config.limits.max_rounds = 1;
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(error.RoundLimit, terminal.detail.?);
    try std.testing.expectEqual(@as(u32, 1), fake.compactions);
    try std.testing.expectEqual(@as(u32, 1), fake.normal_calls);
    try std.testing.expectEqual(@as(usize, 2), runtime.messages().len);
    try std.testing.expectEqual(p.Role.context, runtime.messages()[0].role);
    try std.testing.expectEqualStrings("done", runtime.messages()[1].blocks[0].text);
    try std.testing.expectEqual(r.Status.success, (try runtime.run("short", &cancel)).status);
}

test "Runtime rejects historical tool IDs before execution and history remains encodable" {
    var fake = Fake{ .repeat_tool_id = true, .stop_after = 2 };
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(error.DuplicateToolId, terminal.detail.?);
    try std.testing.expectEqual(@as(u32, 1), fake.executions);
    try std.testing.expectEqual(@as(u32, 1), fake.permissions);
    try std.testing.expectEqual(@as(usize, 3), runtime.messages().len);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("adapter_test_support.zig");
    var req = support.request(.chat);
    req.messages = runtime.messages();
    _ = try @import("../llm/chat.zig").encode(arena.allocator(), req);
    req.scope = support.response_scope;
    _ = try @import("../llm/responses.zig").encode(arena.allocator(), req);
    try std.testing.expectEqual(r.Status.success, (try runtime.run("continue", &cancel)).status);
    try std.testing.expectEqual(@as(u32, 1), fake.executions);
}

// 无头模式：模型调用 -> 工具 -> 模型结束，验证只有一个终态，且消息数为 4。
test "headless Runtime completes model-tool-model and emits one terminal" {
    var fake = Fake{};
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "core", false);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expectEqual(@as(u32, 2), fake.normal_calls);
    try std.testing.expectEqual(@as(u32, 1), fake.executions);
    try std.testing.expectEqual(@as(u32, 1), fake.terminals);
    try std.testing.expectEqual(@as(u32, 1), fake.permissions);
    try std.testing.expectEqual(@as(usize, 4), runtime.messages().len);

    // 无头模式不上报输入 token 数，因此应为 null。
    try std.testing.expectEqual(@as(?u64, null), terminal.usage.normal.input_tokens);
}

// 拒绝或取消审批时工具都不得执行；取消后历史仍应通过边界检查。
test "denied and canceled approval have no tool side effects" {
    var fake = Fake{ .decision = .deny };
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expectEqual(@as(u32, 0), fake.executions);
    try std.testing.expect(fake.denied_seen);

    // 延长工具阶段而不重置 ID 序号，保证跨轮历史 ID 唯一。
    fake.stop_after = fake.normal_calls + 1;
    fake.cancel_permission = &cancel;
    const canceled = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.canceled, canceled.status);
    try std.testing.expectEqual(@as(u32, 0), fake.executions);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 检查消息历史结构是否合法（边界校验）。
    _ = try context.boundaries(arena.allocator(), runtime.messages());
}

// 信任（trust_process）只对当前 Runtime 生效，新建的 Runtime 不继承该信任。
test "trust lasts for this Runtime but is not inherited by a new one" {
    var fake = Fake{ .decision = .trust_process, .stop_after = 2 };
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    _ = try runtime.run("Do the task", &cancel);
    // 同一 Runtime 中只请求一次审批，但两次工具都执行。
    try std.testing.expectEqual(@as(u32, 1), fake.permissions);
    try std.testing.expectEqual(@as(u32, 2), fake.executions);

    var fresh = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
    defer fresh.deinit();
    try std.testing.expect(!fresh.trusted);
}

// 取消时，已提交的所有工具调用都必须有对应结果，且不重放已执行的副作用。
test "cancellation closes all committed tool calls without replaying side effects" {
    var cancel = p.Cancellation{};
    var fake = Fake{ .calls_per_response = 2, .cancel_after_execution = &cancel };
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", true);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.canceled, terminal.status);
    try std.testing.expectEqual(@as(u32, 1), fake.executions);
    try std.testing.expectEqual(@as(u32, 1), fake.normal_calls);
    try std.testing.expectEqual(@as(u32, 1), fake.terminals);

    const messages = runtime.messages();
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    // 第 4 条消息是被取消的工具调用的结果。
    try std.testing.expect(messages[3].blocks[0].tool_result.canceled);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 检查消息历史结构是否合法（边界校验）。
    _ = try context.boundaries(arena.allocator(), messages);
}

// 清理失败必须使 Runtime 进入失败状态，后续运行直接失败，不能误报为取消成功。
test "cleanup failure poisons the Runtime rather than reporting cancellation success" {
    var fake = Fake{ .cleanup_failure = true };
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", true);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.failed, terminal.status);
    try std.testing.expectEqual(error.CleanupFailed, terminal.detail.?);

    const later = try runtime.run("again", &cancel);
    try std.testing.expectEqual(r.Status.failed, later.status);
    // 第二次运行不应再执行工具。
    try std.testing.expectEqual(@as(u32, 1), fake.executions);
}

// 长工具任务中触发一次摘要压缩后仍能继续运行，并保留原始任务消息。
test "Runtime rolls a single summary within a long plain tool task and continues" {
    var fake = Fake{ .stop_after = 8, .output = &long_output };
    const config = smallConfiguration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", true);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expect(fake.summary_calls > 0);
    try std.testing.expectEqual(fake.summary_calls, fake.compactions);
    try std.testing.expectEqual(@as(u32, 8), fake.executions);

    var summaries: usize = 0;
    // 历史中应恰好只有一条 context（摘要）消息。
    for (runtime.messages()) |message| if (message.role == .context) {
        summaries += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), summaries);

    // 受保护的原始任务消息应仍然指向 "Do the task"。
    try std.testing.expectEqualStrings("Do the task", runtime.messages()[runtime.protected_index].blocks[0].text);
    try std.testing.expectEqual(fake.summary_calls, terminal.usage.summary_calls);
}

// 摘要中的工具调用不得被执行；摘要失败时历史必须保持不变。
test "summary tool calls are never executed and failure preserves history" {
    var fake = Fake{ .stop_after = 20, .output = &long_output, .bad_summary = true };
    var config = smallConfiguration();
    config.limits.max_rounds = 6;
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", true);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.failed, terminal.status);
    try std.testing.expect(fake.summary_calls > 0);
    try std.testing.expect(fake.failed_summary_preserved);
    try std.testing.expectEqual(@as(u32, 0), fake.compactions);

    // 每次普通调用的工具都应执行，摘要里的工具调用不计入。
    try std.testing.expectEqual(fake.normal_calls, fake.executions);
}

// 摘要过程中取消：保留旧历史，且不再继续发起模型调用。
test "cancel during summary preserves old history and does not resume model calls" {
    var cancel = p.Cancellation{};
    var fake = Fake{ .stop_after = 20, .output = &long_output, .cancel_summary = &cancel };
    const config = smallConfiguration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", true);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.canceled, terminal.status);
    try std.testing.expectEqual(@as(u32, 1), fake.summary_calls);
    try std.testing.expectEqual(@as(u32, 0), fake.compactions);
    try std.testing.expectEqual(fake.before_summary_tokens, runtime.estimatedTokens());
    try std.testing.expectEqual(@as(u32, 1), fake.terminals);
}

// 任务超时必须能打断阻塞中的模型调用，且与是否有输出无关。
test "task deadline reaches a blocked model independently of output" {
    var fake = Fake{ .block_model = true };
    var config = configuration();
    config.limits.task_timeout_ms = 100;
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.failed, terminal.status);
    try std.testing.expectEqual(error.TaskTimeout, terminal.detail.?);
    try std.testing.expect(fake.entered_model);
    try std.testing.expectEqual(@as(u32, 1), fake.terminals);
}

// 只有最终文本（没有增量）时，宿主仍能收到已提交文本，且不会发生原生回放。
test "canonical final-only output reaches the host without native replay" {
    var fake = Fake{ .stop_after = 0, .omit_deltas = true };
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expectEqualStrings("done", fake.committed_text);
}

// 发布已提交的工具批次时宿主断开，仍需闭合所有工具调用，且不执行任何工具。
test "disconnect publishing a committed tool batch still closes every call" {
    var fake = Fake{ .disconnect_committed = true };
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.failed, terminal.status);
    try std.testing.expectEqual(@as(u32, 0), fake.executions);
    try std.testing.expectEqual(@as(usize, 3), runtime.messages().len);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 检查消息历史结构是否合法（边界校验）。
    _ = try context.boundaries(arena.allocator(), runtime.messages());
}

// Runtime 忙时拒绝新的提交；宿主断开时停止执行，并报告 HostDisconnected。
test "busy rejects submit and a disconnected host stops the execution" {
    var fake = Fake{ .stop_after = 0, .disconnect_text = true };
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "", false);
    defer runtime.deinit();
    fake.current_runtime = &runtime;
    var cancel = p.Cancellation{};

    // 手动置位 busy，模拟另一个任务正在运行。
    runtime.busy.store(true, .release);
    try std.testing.expectError(error.Busy, runtime.run("Do the task", &cancel));

    // 清除 busy 后再次提交应能正常运行。
    runtime.busy.store(false, .release);
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.failed, terminal.status);
    try std.testing.expectEqual(error.HostDisconnected, terminal.detail.?);
    try std.testing.expectEqual(@as(u32, 1), fake.terminals);
}
