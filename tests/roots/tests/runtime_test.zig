//! Runtime 无头（headless）行为测试：使用 Fake 替身同时模拟模型、执行器与宿主，验证工具调用、审批、取消、摘要压缩与超时等语义。

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const r = @import("../core/runtime.zig");
const diagnostics = @import("../core/diagnostics.zig");
const context = @import("../core/context.zig");
const auxiliary = @import("../core/decision.zig");

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
    /// 观察者收到的直接输入提交次数（id 0 仅为直接输入保留）。
    direct_observed: usize = 0,
    /// 宿主收到的直接输入回显次数；应当始终为 0，避免重复显示。
    direct_host_echoes: usize = 0,
    /// 为 true 时要求每次普通模型调用前直接输入已提交。
    check_direct_order: bool = false,
    /// 每次模型响应包含的工具调用数量。
    calls_per_response: usize = 1,
    /// Fake 明确要求逐次审批，用于保留批准、拒绝与取消生命周期覆盖。
    explicit_denial: ?[]const u8 = "Fixture requires explicit approval; not executed.",
    last_result: []const u8 = "",
    /// authorize 返回的审批决定。
    decision: r.Decision = .allow_once,
    /// 工具执行返回的文本。
    output: []const u8 = "written",
    /// 工具返回后触发一次分配失败，验证结果尚未回填时不能谎报“未执行”。
    fail_after_execution: ?*bool = null,
    /// 执行工具之后触发取消，用于测试"工具已执行但随后取消"的路径。
    cancel_after_execution: ?*p.Cancellation = null,
    cancel_execution_number: u32 = 1,
    /// 审批回调中触发取消。
    cancel_permission: ?*p.Cancellation = null,
    /// 摘要请求中触发取消。
    cancel_summary: ?*p.Cancellation = null,
    /// 为 true 时摘要响应中夹带工具调用，用于验证它不会被执行。
    bad_summary: bool = false,
    throw_summary: bool = false,
    summary_usage: ?p.Usage = null,
    cancel_compaction_failure: ?*p.Cancellation = null,
    compaction_error: ?anyerror = null,
    before_summary_context: ?r.ContextSnapshot = null,
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
    emit_reasoning: bool = false,
    /// 宿主最近一次收到的已提交文本。
    committed_text: []const u8 = "",
    /// 是否已进入（阻塞的）模型调用。
    entered_model: std.atomic.Value(bool) = .init(false),
    /// 指向被测 Runtime，供事件回调读取其 token 估算值。
    current_runtime: ?*r.Runtime = null,
    /// 进入压缩状态前的估算 token 数。
    before_summary_tokens: usize = 0,
    /// 压缩失败后，历史的估算 token 数是否与压缩前一致（即历史被保留）。
    failed_summary_preserved: bool = false,
    /// 首次请求时的 system 提示；之后每次请求都必须与它一致。
    first_system: ?[]const u8 = null,
    snapshots: usize = 0,
    last_context: ?r.ContextSnapshot = null,
    last_actual_total: ?u64 = null,
    last_summary_total: ?u64 = null,
    nonzero_usage: bool = false,
    fail_prepare: bool = false,
    preparation_error: ?anyerror = null,
    disconnect_snapshot: ?usize = null,
    file_stats: ?@import("../util/line_stats.zig").File = null,
    last_file_stats: ?@import("../util/line_stats.zig").File = null,
    fitted_result: bool = false,
    last_started_ms: ?u64 = null,
    last_duration_ms: ?u64 = null,
    execution_delay: bool = false,
    execution_error: ?anyerror = null,
    /// When set, permission-id exhaustion asks the host to start a new epoch.
    rebase_permissions: bool = false,
    decision_input: ?auxiliary.Input = null,
    decision_output: auxiliary.Output = .{ .command = .{ .ask = false } },
    decision_failure: ?anyerror = null,
    decision_cancel: ?*p.Cancellation = null,
    decision_calls: usize = 0,

    fn auxiliaryDecide(raw: *anyopaque, _: std.mem.Allocator, _: auxiliary.Input, _: *const p.Cancellation) !auxiliary.Output {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.decision_calls += 1;
        // Must happen before permission and all side effects.
        try std.testing.expectEqual(@as(u32, 0), self.permissions + self.executions);
        if (self.decision_cancel) |cancel| cancel.cancel();
        if (self.decision_failure) |err| return err;
        return self.decision_output;
    }

    fn repeatedAsk(raw: *anyopaque, _: std.mem.Allocator, _: auxiliary.Input, _: *const p.Cancellation) !auxiliary.Output {
        const self: *Fake = @ptrCast(@alignCast(raw));
        try std.testing.expectEqual(self.decision_calls, self.permissions);
        try std.testing.expectEqual(self.decision_calls, self.executions);
        self.decision_calls += 1;
        return .{ .command = .{ .ask = true } };
    }

    fn service(self: *Fake) auxiliary.Service {
        return .{ .context = self, .decide_fn = auxiliaryDecide };
    }

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
        return .{ .context = self, .emit_fn = event, .authorize_fn = authorize, .rebase_permission_fn = if (self.rebase_permissions) rebase else null };
    }

    fn rebase(_: ?*anyopaque) !void {}

    /// 模拟模型：摘要请求返回固定文本（或非法工具调用）；普通请求先返回工具调用，超过 stop_after 后返回 "done"。
    fn call(ctx: *anyopaque, a: std.mem.Allocator, req: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(ctx));

        // 整个会话的 system 提示必须保持不变，以保证请求前缀稳定。
        if (req.purpose == .normal) {
            if (self.first_system) |system| try std.testing.expectEqualStrings(system, req.system) else self.first_system = req.system;
            try std.testing.expectEqual(@as(usize, 1), req.tools.len);
        } else {
            try std.testing.expectEqual(@as(usize, 0), req.tools.len);
            try std.testing.expectEqual(@as(usize, 1), req.messages.len);
            try std.testing.expect(req.messages[0].replay == null);
        }

        if (self.block_model) {
            self.entered_model.store(true, .release);
            // Block until explicit cancellation reaches this individual request.
            var attempts: usize = 0;
            while (!req.cancellation.?.isRequested() and attempts < 5000) : (attempts += 1)
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            if (!req.cancellation.?.isRequested()) return error.FixtureCancellationNotObserved;
            return .{ .failure = .{ .kind = .canceled, .message = "canceled fixture" } };
        }

        const input: ?u64 = if (self.nonzero_usage) @intCast(context.rawTokens(req.system, req.tools, req.messages)) else null;
        if (req.purpose == .summary) {
            // 摘要请求：最后一条必须是 user 消息，且历史中须包含原始任务文本。
            self.summary_calls += 1;
            try std.testing.expectEqual(p.Role.user, req.messages[req.messages.len - 1].role);
            var found_task = false;
            for (req.messages) |msg| for (msg.blocks) |block| {
                if (msg.role == .user and block == .text and std.mem.indexOf(u8, block.text, "Do the task") != null) found_task = true;
            };
            try std.testing.expect(found_task);

            if (self.throw_summary) return error.FixtureSummaryFailed;
            // 摘要生成过程中触发取消，验证旧历史被保留。
            if (self.cancel_summary) |cancel| cancel.cancel();
            // bad_summary：摘要里夹带工具调用，应被拒绝且不执行。
            if (self.bad_summary) return .{ .success = .{
                .message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "forbidden", .name = "bash", .arguments = "{}" } }} },
                .finish = .tool_calls,
                .usage = self.summary_usage orelse .{},
            } };
            return .{ .success = .{
                .message = .{ .role = .assistant, .blocks = &.{.{ .text = "Earlier tool steps completed; continue the requested work." }} },
                .finish = .stop,
                .usage = self.summary_usage orelse .{ .input_tokens = input, .output_tokens = 10 },
            } };
        }

        self.normal_calls += 1;
        // 直接输入必须在首次请求发出前已成为可保存的提交。
        if (self.check_direct_order) try std.testing.expectEqual(@as(usize, 1), self.direct_observed);
        // 记录历史中出现过的被拒绝工具结果，用于断言拒绝已反馈给模型。
        for (req.messages) |msg| for (msg.blocks) |block| {
            if (block == .tool_result and block.tool_result.is_error) self.denied_seen = true;
        };

        // 达到 stop_after 后返回纯文本结束。
        if (self.normal_calls > self.stop_after) {
            if (!self.omit_deltas) {
                if (self.emit_reasoning) try sink.emit(.{ .reasoning_delta = "thinking" });
                try sink.emit(.{ .text_delta = "done" });
            }
            return .{ .success = .{
                .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} },
                .finish = .stop,
                .usage = .{ .input_tokens = input, .output_tokens = 1 },
            } };
        }

        // 生成指定数量的工具调用；ID 同时包含轮次与序号，便于区分。
        const blocks = try a.alloc(p.Block, self.calls_per_response);
        for (blocks, 0..) |*block, i| block.* = .{ .tool_call = .{
            .id = try std.fmt.allocPrint(a, "call-{d}-{d}", .{ if (self.repeat_tool_id) @as(u32, 1) else self.normal_calls, i }),
            .name = "write_file",
            .arguments = "{}",
        } };
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = blocks }, .finish = .tool_calls, .usage = .{ .input_tokens = input, .output_tokens = 1 } } };
    }

    /// 准备阶段：校验工具名，并返回是否需要审批。
    fn prepare(ctx: *anyopaque, _: std.mem.Allocator, call_: p.ToolCall) !r.Prepared {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, call_.name, "write_file")) return error.UnexpectedTool;
        if (self.preparation_error) |err| return err;
        if (self.fail_prepare) return error.InvalidFixtureArguments;
        return .{ .payload = ctx, .description = "write fixture", .explicit_denial = self.explicit_denial, .decision_input = self.decision_input };
    }

    /// 执行工具：执行前先检查取消（已取消则不产生副作用），成功后计数，并按配置返回成功或清理失败。
    fn execute(ctx: *anyopaque, _: std.mem.Allocator, _: r.Prepared, cancel: *const p.Cancellation) !r.Execution {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (cancel.isRequested()) return error.Canceled;
        self.executions += 1;
        if (self.execution_delay) try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
        if (self.execution_error) |err| return err;
        if (self.fail_after_execution) |armed| armed.* = true;
        if (self.cancel_after_execution) |c| {
            if (self.executions >= self.cancel_execution_number) c.cancel();
        }
        return .{ .text = self.output, .cleanup_failed = self.cleanup_failure, .is_error = self.cleanup_failure, .file_stats = self.file_stats };
    }

    /// 宿主事件回调：记录计数、已提交文本与压缩状态；配置了 disconnect 时返回 Disconnected，模拟宿主断开。
    ///
    /// 这里不要写 `try assert`：Runtime.emit 会把回调返回的任何错误重新归类为
    /// Canceled 或 HostDisconnected，断言在回调里失败会被静默吞掉，测试仍然报 OK。
    /// 需要不变量时在测试体里断言，或使用 context_usage_test.zig 的专用夹具。
    fn event(ctx: ?*anyopaque, ev: r.Event, _: *const p.Cancellation) !void {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .assistant_committed => |blocks| {
                if (self.disconnect_committed) return error.Disconnected;
                for (blocks) |block| if (block == .text) {
                    self.committed_text = block.text;
                };
            },
            .context_snapshot => |value| {
                self.snapshots += 1;
                self.last_context = value;
                if (self.disconnect_snapshot == self.snapshots) return error.Disconnected;
            },
            .usage => |usage| {
                self.last_actual_total = usage.value.total();
                if (usage.purpose == .summary) self.last_summary_total = self.last_actual_total;
                if (self.current_runtime) |runtime| {
                    // Like the presentation consumer, update at the usage event,
                    // without adding a new fallible context-event boundary.
                    self.last_context = runtime.contextSnapshot();
                }
            },
            .tool_result => |value| {
                self.last_file_stats = value.result.file_stats;
                self.fitted_result = value.result.truncated;
                self.last_duration_ms = value.result.duration_ms;
                self.last_result = value.result.text;
            },
            .tool_started => |value| self.last_started_ms = value.started_ms,
            // 直接输入仍不得经宿主回显，否则与提交方已绘制的行重复。
            .user_committed => |value| if (value.id == r.direct_input_id) {
                self.direct_host_echoes += 1;
            },
            .finished => self.terminals += 1,
            .compacted => self.compactions += 1,
            // 进入压缩前记录 token 估算值，供后续比较。
            .state => |state| {
                if (state == .compacting) {
                    self.before_summary_tokens = self.current_runtime.?.estimatedTokens();
                    self.before_summary_context = self.current_runtime.?.contextSnapshot();
                }
            },
            // 压缩失败后 token 数应与压缩前一致，说明历史未被破坏。
            .compaction_failed => |err| {
                self.compaction_error = err;
                self.failed_summary_preserved = self.before_summary_tokens == self.current_runtime.?.estimatedTokens();
                // Stop the fixture before another normal call can overwrite
                // the summary's display result; don't change production logic.
                if (self.cancel_compaction_failure) |cancel| cancel.cancel();
            },
            .text => if (self.disconnect_text) {
                return error.Disconnected;
            },
            else => {},
        }
    }

    /// 观察者回调：只统计直接输入的提交信号，不参与授权或显示。
    fn observe(ctx: ?*anyopaque, observation: r.Observation) void {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        if (observation == .event and observation.event == .user_committed and observation.event.user_committed.id == r.direct_input_id) self.direct_observed += 1;
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
        .limits = .{ .low_price_input = false },
    };
}
/// Invert the adaptive reserve for a finite positive test input budget.
fn windowForInputBudget(budget: u32) u32 {
    std.debug.assert(budget > 0);
    const room = @as(u64, budget) + 1;
    const window: u32 = @intCast(room + @min(cfg.Policy.safety_tokens, room / 7));
    std.debug.assert(@as(u64, window) - cfg.Policy.safetyTokens(window) - 1 == budget);
    return window;
}

/// A real small model window with exactly 3000 input tokens of room.
fn smallConfiguration() cfg.Config {
    var config = configuration();
    config.model.context_tokens = windowForInputBudget(3000);
    std.debug.assert(context.inputBudget(config) == 3000);
    return config;
}

fn checkpointImportAllocation(a: std.mem.Allocator) !void {
    var fake: Fake = .{};
    var config = configuration();
    var runtime = try r.Runtime.init(a, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "before");
    defer runtime.deinit();
    const initial = runtime.system;
    const state: @import("../core/checkpoint.zig").State = .{
        .system = "restored system",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "prior question" }} }},
        .selector = .init(.chat),
        .estimator = .{},
        .last_context_tokens = 12,
        .permission_id = 7,
    };
    runtime.restoreCheckpoint(state) catch |err| {
        try std.testing.expect(runtime.system.ptr == initial.ptr);
        try std.testing.expectEqual(@as(usize, 0), runtime.messages().len);
        try std.testing.expectEqual(@as(u64, 0), runtime.permission_id);
        return err;
    };
    try std.testing.expectEqualStrings("restored system", runtime.system);
    try std.testing.expectEqualStrings("prior question", runtime.messages()[0].blocks[0].text);
}

// 无头模式：模型调用 -> 工具 -> 模型结束，验证只有一个终态，且消息数为 4。

// 拒绝或取消审批时工具都不得执行；取消后历史仍应通过边界检查。

// 明确要求批准的操作逐次询问；拒绝文案原样回给模型。

// 普通操作无需询问，即使宿主回调会拒绝也不进入审批。

// 取消时，已提交的所有工具调用都必须有对应结果，且不重放已执行的副作用。

// 清理失败必须使 Runtime 进入失败状态，后续运行直接失败，不能误报为取消成功。

fn throwingCleanupFailure(prepare_failure: bool) !void {
    var fake: Fake = .{
        .calls_per_response = 2,
        .explicit_denial = null,
        .preparation_error = if (prepare_failure) error.CleanupFailed else null,
        .execution_error = if (prepare_failure) null else error.CleanupFailed,
    };
    const config = configuration();
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, fake.model(), fake.executor(), fake.host(), "");
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("Do the task", &cancel);
    try std.testing.expectEqual(r.Status.failed, terminal.status);
    try std.testing.expectEqual(error.CleanupFailed, terminal.detail.?);
    try std.testing.expect(runtime.poisoned);
    try std.testing.expectEqual(@as(u32, 1), fake.normal_calls);
    try std.testing.expectEqual(@as(u32, if (prepare_failure) 0 else 1), fake.executions);
    const messages = runtime.messages();
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("call-1-0", messages[2].blocks[0].tool_result.call_id);
    try std.testing.expect(messages[2].blocks[0].tool_result.is_error);
    try std.testing.expectEqualStrings("CleanupFailed", messages[2].blocks[0].tool_result.text);
    try std.testing.expectEqualStrings("call-1-1", messages[3].blocks[0].tool_result.call_id);
    try std.testing.expect(messages[3].blocks[0].tool_result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, messages[3].blocks[0].tool_result.text, "Not executed") != null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try context.boundaries(arena.allocator(), messages);
    const later = try runtime.run("must not start", &cancel);
    try std.testing.expectEqual(r.Status.failed, later.status);
    try std.testing.expectEqual(error.CleanupFailed, later.detail.?);
    try std.testing.expectEqual(@as(u32, 1), fake.normal_calls);
    try std.testing.expectEqual(@as(u32, if (prepare_failure) 0 else 1), fake.executions);
}

// 长工具任务中触发一次摘要压缩后仍能继续运行，并保留原始任务消息。

// 摘要中的工具调用不得被执行；摘要失败时历史必须保持不变。

// 摘要过程中取消：保留旧历史，且不再继续发起模型调用。

// 任务超时必须能打断阻塞中的模型调用，且与是否有输出无关。

// 只有最终文本（没有增量）时，宿主仍能收到已提交文本，且不会发生原生回放。

// 发布已提交的工具批次时宿主断开，仍需闭合所有工具调用，且不执行任何工具。

fn seedManualHistory(runtime: *r.Runtime) !void {
    try runtime.restoreCheckpoint(.{
        .system = "fixture",
        .messages = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "old goal" }} },
            .{ .role = .assistant, .blocks = &.{.{ .text = &long_output }} },
            .{ .role = .user, .blocks = &.{.{ .text = "Do the task" }} },
            .{ .role = .assistant, .blocks = &.{.{ .text = "latest answer" }} },
        },
        .selector = .init(.chat),
        .estimator = .{},
        .last_context_tokens = 500,
        .permission_id = 0,
    });
    // Deliberately not the latest user: failures must restore this exact value.
    runtime.protected_index = 0;
}

const OutputLimitFixture = struct {
    normal: usize = 0,
    summaries: usize = 0,
    executions: usize = 0,
    finished: usize = 0,
    limited: bool = true,

    fn call(raw: *anyopaque, _: std.mem.Allocator, request: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (request.purpose == .summary) self.summaries += 1 else self.normal += 1;
        // Upstream output-limit reports remain meaningful with no local cap.
        try std.testing.expectEqual(@as(?u32, null), request.model_output_tokens);
        try std.testing.expectEqualStrings("max", request.reasoning_effort.?);
        if (!self.limited) return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "continued" }} }, .finish = .stop } };
        try sink.emit(.{ .reasoning_delta = "reasoning-only preview" });
        return .{ .failure = .{ .kind = .output_limit, .message = "output token limit reached", .observed_content = true, .usage = .{ .input_tokens = 45871, .output_tokens = 4096, .reasoning_tokens = 4096 } } };
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.executions += 1;
        return error.UnexpectedTool;
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.executions += 1;
        return error.UnexpectedTool;
    }
    fn event(raw: ?*anyopaque, value: r.Event, _: *const p.Cancellation) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (value == .finished) self.finished += 1;
    }
    fn config() cfg.Config {
        var result = configuration();
        result.model.context_tokens = 131072;
        result.model.reasoning_effort = "max";
        result.model.reasoning = .{ .format = .standard, .map = .{ .max = "max" } };
        return result;
    }
};

const ManualCapture = struct {
    submitted: usize = 0,
    finished: usize = 0,
    command_seen: bool = false,

    fn notify(raw: ?*anyopaque, observation: r.Observation) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        switch (observation) {
            .submitted => |text| {
                self.submitted += 1;
                self.command_seen = std.mem.eql(u8, text, "/compact");
            },
            .event => |event| if (event == .finished) {
                self.finished += 1;
            },
            else => {},
        }
    }
};

// Runtime 忙时拒绝新的提交；宿主断开时停止执行，并报告 HostDisconnected。
