//! Real Runtime/permission/file/Memory/process integration with a scripted model.
//! All filesystem effects and command inputs are owned temporary fixtures.

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const r = @import("../core/runtime.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const tools_module = @import("../tools/tools.zig");
const j = @import("../util/json.zig");
const t = std.testing;

/// 脚本化模型第一轮的回复：写文件、写 memory、执行受控命令（仅写入标记文件）。
const writes = [_]p.Block{
    .{ .tool_call = .{ .id = "w", .name = "write_file", .arguments = "{\"path\":\"note.txt\",\"content\":\"你好\"}" } },
    .{ .tool_call = .{ .id = "m", .name = "memory", .arguments = "{\"action\":\"write\",\"topic\":\"facts\",\"content\":\"New title\\nfacts\"}" } },
    .{ .tool_call = .{ .id = "b", .name = "bash", .arguments = "{\"command\":\"test -z \\\"${FAKE_KEY+x}${OTHER_KEY+x}\\\" && printf 'ok\\\\n' > command.txt\"}" } },
};

/// 脚本化模型第二轮的回复：读取刚写入的文件并列出 memory，验证实时读取可见。
const reads = [_]p.Block{
    .{ .tool_call = .{ .id = "r", .name = "read_file", .arguments = "{\"path\":\"note.txt\"}" } },
    .{ .tool_call = .{ .id = "l", .name = "memory", .arguments = "{\"action\":\"list\"}" } },
};

/// 脚本化模型与宿主桩：按轮次返回预设回复，并记录权限请求与工具事件数量。
const Fixture = struct {
    /// 是否批准所有需要授权的操作。
    allowed: bool,
    /// 模型已被调用的轮数，决定脚本走哪一步。
    calls: usize = 0,
    /// 收到的权限请求次数。
    permissions: usize = 0,
    started: usize = 0,
    finished: usize = 0,
    /// 首轮 system prompt，用于验证后续轮次保持不变（启动时冻结）。
    first_system: ?[]const u8 = null,

    /// 把 Fixture 包装为 p.Model 接口。
    fn model(self: *Fixture) p.Model {
        return .{ .context = self, .call_fn = call };
    }

    /// 把 Fixture 包装为运行时宿主接口（事件与授权回调）。
    fn host(self: *Fixture) r.Host {
        return .{ .context = self, .emit_fn = event, .authorize_fn = authorize };
    }

    /// 脚本：第 0 轮发起工具调用；第 1 轮检查工具结果（拒绝时应为错误）；第 2 轮仅在批准时校验读取内容。
    fn call(ctx: *anyopaque, a: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        try t.expectEqual(p.Purpose.normal, req.purpose);
        try t.expectEqual(@as(usize, 4), req.tools.len);
        // system prompt 必须在所有轮次保持一致，且不包含运行中写入的 memory。
        if (self.first_system) |first| try t.expectEqualStrings(first, req.system) else self.first_system = req.system;
        try t.expect(std.mem.find(u8, req.system, "New title") == null);

        const step = self.calls;
        self.calls += 1;
        if (step == 0) return reply(&writes, .tool_calls);
        if (step == 1) {
            for ([_][]const u8{ "w", "m", "b" }) |id| {
                const result = try findResult(req.messages, id);
                try t.expectEqual(!self.allowed, result.is_error);
            }
            if (self.allowed) return reply(&reads, .tool_calls);
        } else if (step == 2 and self.allowed) {
            const file = try findResult(req.messages, "r");
            try t.expect(!file.is_error);
            const value = try j.parse(a, file.text);
            try t.expectEqualStrings("你好", j.string(j.get(value, "content")).?);
            const listing = try findResult(req.messages, "l");
            try t.expect(!listing.is_error);
            const listed = try j.parse(a, listing.text);
            try t.expectEqualStrings("facts.md: New title\n", j.string(j.get(listed, "current_snapshot")).?);
        } else return error.UnexpectedModelRound;
        return reply(&.{.{ .text = "done" }}, .stop);
    }

    /// 构造一次成功回复，固定 usage 数值便于断言 token 计费。
    fn reply(blocks: []const p.Block, finish: p.Finish) p.Outcome {
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = blocks }, .finish = finish, .usage = .{ .input_tokens = 100, .output_tokens = 20, .cached_input_tokens = 50 } } };
    }

    /// 在消息历史中按 call_id 查找工具结果，找不到则返回 error.MissingToolResult。
    fn findResult(messages: []const p.Message, id: []const u8) !p.ToolResult {
        for (messages) |message| for (message.blocks) |block| {
            if (block == .tool_result and std.mem.eql(u8, block.tool_result.call_id, id)) return block.tool_result;
        };
        return error.MissingToolResult;
    }

    /// 权限回调：allowed 为 true 时批准一次，否则拒绝。
    fn authorize(ctx: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        self.permissions += 1;
        return if (self.allowed) .allow_once else .deny;
    }

    /// 事件回调：统计工具开始与完成的次数，其余事件忽略。
    fn event(ctx: ?*anyopaque, ev: r.Event, _: *const p.Cancellation) !void {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .tool_started => self.started += 1,
            .finished => self.finished += 1,
            else => {},
        }
    }
};

// 验证：显式批准时工具真实执行，文件、命令输出与 memory 写入均生效，且启动快照保持冻结。
test "headless real tools: explicit approval, frozen startup Memory and live reads" {
    try scenario(true);
}

// 验证：全部拒绝时不产生任何文件或 memory 副作用。
test "headless real tools: denying all mutations creates no files or Memory" {
    try scenario(false);
}

/// 运行一次完整场景：临时目录作为工具根，Fixture 驱动运行时；allowed 决定是否批准所有修改。
fn scenario(allowed: bool) !void {
    const a = t.allocator;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();

    const config = cfg.Config{ .provider = .{ .base_url = "http://unused.invalid", .api_key_env = "FAKE_KEY" }, .model = .{ .name = "scripted", .context_tokens = 32768, .protocol = .chat } };
    var memory = mem.Store.init(&root, config.limits);

    // 启动时 memory 快照为空，且 .thin 目录尚未创建。
    const snapshot = try memory.snapshot(a);
    defer a.free(snapshot);
    try t.expectEqualStrings("", snapshot);
    try t.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));

    // 测试密钥只放在父进程环境中，验证 commandEnvironment 不会把它们传给子进程。
    var source = std.process.Environ.Map.init(a);
    defer source.deinit();
    try source.put("FAKE_KEY", "fake-never-child");
    try source.put("OTHER_KEY", "also-never-child");
    try source.put("HOME", root.path);
    var environment = try tools_module.commandEnvironment(a, &source, config.provider.api_key_env);
    defer environment.deinit();

    var tools = tools_module.Tools{ .root = &root, .memory = &memory, .config = &config, .environment = &environment };

    var fixture = Fixture{ .allowed = allowed };

    // 运行时使用脚本化模型与真实工具执行器，宿主回调由 Fixture 提供。
    var runtime = try r.Runtime.init(a, io, &config, fixture.model(), tools.executor(), fixture.host(), snapshot, false);
    defer runtime.deinit();

    var cancel = p.Cancellation{};

    const terminal = try runtime.run("Run the owned local fixture", &cancel);
    try t.expectEqual(r.Status.success, terminal.status);
    try t.expectEqual(@as(usize, 3), fixture.permissions);
    try t.expectEqual(@as(usize, 1), fixture.finished);
    try t.expectEqual(@as(usize, if (allowed) 5 else 0), fixture.started);
    try t.expectEqual(@as(?u64, if (allowed) 300 else 200), terminal.usage.normal.input_tokens);

    // 批准时验证文件、命令与 memory 的实际落盘内容。
    if (allowed) {
        const file = try root.read(a, "note.txt", 0, 100);
        defer a.free(file.data);
        try t.expectEqualStrings("你好", file.data);
        const command = try root.read(a, "command.txt", 0, 100);
        defer a.free(command.data);
        try t.expectEqualStrings("ok\n", command.data);
        const entry = try memory.read(a, "facts");
        defer a.free(entry.content);
        defer a.free(entry.version);
        try t.expectEqualStrings("New title\nfacts", entry.content);
    } else {
        // 拒绝时所有副作用都必须不存在。
        try t.expectError(error.FileNotFound, root.read(a, "note.txt", 0, 100));
        try t.expectError(error.FileNotFound, root.read(a, "command.txt", 0, 100));
        try t.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    }
}

// trusted 会话里：危险 bash 仍要审批；拒绝不执行；批准才执行。普通命令不询问。
test "trusted runtime asks before dangerous bash and still runs ordinary bash" {
    try bashTrust("rm -rf marker", .deny, true, false);
    try bashTrust("rm -rf marker", .allow_once, true, true);
    try bashTrust("printf ok > safe.txt", .deny, false, true);
}

const BashProbe = struct {
    command: []const u8,
    decision: r.Decision,
    calls: usize = 0,
    permissions: usize = 0,
    started: usize = 0,
    is_error: bool = false,
    result: [384]u8 = undefined,
    result_len: usize = 0,

    fn model(self: *BashProbe) p.Model {
        return .{ .context = self, .call_fn = call };
    }
    fn host(self: *BashProbe) r.Host {
        return .{ .context = self, .emit_fn = event, .authorize_fn = authorize };
    }
    fn call(ctx: *anyopaque, a: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *BashProbe = @ptrCast(@alignCast(ctx));
        const step = self.calls;
        self.calls += 1;
        if (step == 0) {
            const encoded = try std.json.Stringify.valueAlloc(a, self.command, .{});
            const arguments = try std.fmt.allocPrint(a, "{{\"command\":{s}}}", .{encoded});
            const blocks = try a.alloc(p.Block, 1);
            blocks[0] = .{ .tool_call = .{ .id = "b", .name = "bash", .arguments = arguments } };
            return .{ .success = .{ .message = .{ .role = .assistant, .blocks = blocks }, .finish = .tool_calls, .usage = .{ .input_tokens = 10, .output_tokens = 1 } } };
        }
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} }, .finish = .stop, .usage = .{ .input_tokens = 10, .output_tokens = 1 } } };
    }
    fn authorize(ctx: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        const self: *BashProbe = @ptrCast(@alignCast(ctx.?));
        self.permissions += 1;
        return self.decision;
    }
    fn event(ctx: ?*anyopaque, ev: r.Event, _: *const p.Cancellation) !void {
        const self: *BashProbe = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .tool_started => self.started += 1,
            .tool_result => |value| {
                self.is_error = value.result.is_error;
                const n = @min(self.result.len, value.result.text.len);
                @memcpy(self.result[0..n], value.result.text[0..n]);
                self.result_len = n;
            },
            else => {},
        }
    }
};

fn bashTrust(command: []const u8, decision: r.Decision, ask: bool, run: bool) !void {
    const a = t.allocator;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();
    const config = cfg.Config{ .provider = .{ .base_url = "http://unused.invalid", .api_key_env = "FAKE_KEY" }, .model = .{ .name = "scripted", .context_tokens = 32768, .protocol = .chat } };
    var memory = mem.Store.init(&root, config.limits);
    var source = std.process.Environ.Map.init(a);
    defer source.deinit();
    try source.put("PATH", "/usr/bin:/bin");
    try source.put("HOME", root.path);
    var environment = try tools_module.commandEnvironment(a, &source, config.provider.api_key_env);
    defer environment.deinit();
    try root.write("marker", "keep", false);

    var tools = tools_module.Tools{ .root = &root, .memory = &memory, .config = &config, .environment = &environment };
    var probe = BashProbe{ .command = command, .decision = decision };
    var runtime = try r.Runtime.init(a, io, &config, probe.model(), tools.executor(), probe.host(), "", true);
    defer runtime.deinit();
    var cancel = p.Cancellation{};
    const terminal = try runtime.run("classify this command", &cancel);
    try t.expectEqual(r.Status.success, terminal.status);
    try t.expect(runtime.trusted);
    try t.expectEqual(@as(usize, if (ask) 1 else 0), probe.permissions);
    try t.expectEqual(@as(usize, if (run) 1 else 0), probe.started);
    const removes_marker = std.mem.startsWith(u8, command, "rm ");
    if (run and removes_marker) {
        try t.expectError(error.FileNotFound, root.read(a, "marker", 0, 16));
        try t.expect(!probe.is_error);
    } else {
        const kept = try root.read(a, "marker", 0, 16);
        defer a.free(kept.data);
        try t.expectEqualStrings("keep", kept.data);
    }
    if (!run) {
        try t.expect(probe.is_error);
        try t.expect(std.mem.indexOf(u8, probe.result[0..probe.result_len], "Dangerous bash command was not executed") != null);
        try t.expect(std.mem.indexOf(u8, probe.result[0..probe.result_len], "recursive delete") != null);
    }
    if (std.mem.indexOf(u8, command, "safe.txt") != null) {
        const written = try root.read(a, "safe.txt", 0, 16);
        defer a.free(written.data);
        try t.expectEqualStrings("ok", written.data);
        try t.expect(!probe.is_error);
    }
}
