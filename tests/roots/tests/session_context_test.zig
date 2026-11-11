//! AGENTS discovery, session preface injection, and append-only policy updates.

const std = @import("std");
const session_context = @import("../core/session_context.zig");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const r = @import("../core/runtime.zig");
const chat = @import("../llm/chat.zig");
const responses = @import("../llm/responses.zig");
const anthropic = @import("../llm/anthropic.zig");
const App = @import("../app/app.zig").App;
const catalog = @import("../core/skill_catalog.zig");
const fs = @import("../platform/filesystem.zig");
const tools_mod = @import("../tools/tools.zig");
const memory = @import("../tools/memory.zig");

const io = std.testing.io;

extern "c" fn mkfifoat(dirfd: c_int, path: [*:0]const u8, mode: c_uint) c_int;

fn catalogAllocationCase(a: std.mem.Allocator, home: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, "original-prefix");
    catalog.append(a, io, home, &out) catch |err| {
        try std.testing.expectEqualStrings("original-prefix", out.items);
        return err;
    };
    try std.testing.expect(std.mem.startsWith(u8, out.items, "original-prefixAvailable skills"));
}

fn mkdir(dir: std.Io.Dir, name: [*:0]const u8) !void {
    if (std.c.mkdirat(dir.handle, name, 0o700) != 0) return error.FixtureDirectoryFailed;
}

fn absolute(a: std.mem.Allocator, dir: std.Io.Dir, relative: []const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = try dir.realPath(io, &buf);
    return std.fs.path.join(a, &.{ buf[0..n], relative });
}

fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

fn rm(parent: std.Io.Dir, name: [*:0]const u8, directory: bool) void {
    _ = std.c.unlinkat(parent.handle, name, if (directory) std.c.AT.REMOVEDIR else 0);
}

const Box = struct {
    snap: session_context.Snapshot,
    fn load(ctx: *anyopaque, _: std.mem.Allocator) !session_context.Snapshot {
        const self: *Box = @ptrCast(@alignCast(ctx));
        return self.snap;
    }
};

fn stubCall(_: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
    return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "ok" }} }, .finish = .stop, .usage = .{ .input_tokens = 8, .output_tokens = 1 } } };
}
fn stubPrepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
    return error.UnexpectedTool;
}
fn stubExecute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
    return error.UnexpectedTool;
}

var stub_dummy: u8 = 0;

fn openRuntime(config: *const cfg.Config, box: *Box) !r.Runtime {
    var runtime = try r.Runtime.init(std.testing.allocator, io, config, .{ .context = &stub_dummy, .call_fn = stubCall }, .{ .context = &stub_dummy, .schemas = &.{}, .prepare_fn = stubPrepare, .execute_fn = stubExecute }, .{}, "");
    runtime.session_loader = .{ .context = box, .load_fn = Box.load };
    return runtime;
}

fn baseSnap(agents: []const u8) session_context.Snapshot {
    return .{
        .cwd = "/proj/cwd",
        .shell = "/bin/zsh",
        .project_root = "/proj",
        .agents = agents,
        .agents_text = agents,
        .truncated = false,
    };
}

fn textOf(message: p.Message) []const u8 {
    return message.blocks[0].text;
}

fn encodeWire(a: std.mem.Allocator, runtime: *r.Runtime, protocol: p.Protocol) ![]u8 {
    const req = p.Request{
        .scope = .{ .connection = "http://localhost", .model = "fake", .protocol = protocol },
        .system = runtime.system,
        .messages = runtime.messages(),
        .tools = &.{},
        // Synthetic verified capacity for the Anthropic wire-only fixture.
        .model_output_tokens = if (protocol == .anthropic) 32 else null,
    };
    return switch (protocol) {
        .chat => chat.encode(a, req),
        .responses => responses.encode(a, req),
        .anthropic => anthropic.encode(a, req),
        .systemone => error.SystemOneNotChatModel,
        .auto => unreachable,
    };
}

fn countPrefix(messages: []const p.Message, prefix: []const u8) usize {
    var n: usize = 0;
    for (messages) |message| {
        if (message.role == .context and std.mem.startsWith(u8, textOf(message), prefix)) n += 1;
    }
    return n;
}

fn indexOfText(messages: []const p.Message, needle: []const u8) ?usize {
    for (messages, 0..) |message, index| {
        if (message.blocks.len == 1 and message.blocks[0] == .text and std.mem.indexOf(u8, message.blocks[0].text, needle) != null) return index;
    }
    return null;
}

const SummaryGate = struct {
    summaries: u32 = 0,
    saw_policy_after_summary: bool = false,

    fn call(ctx: *anyopaque, _: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *SummaryGate = @ptrCast(@alignCast(ctx));
        if (req.purpose == .summary) {
            self.summaries += 1;
            return .{ .success = .{
                .message = .{ .role = .assistant, .blocks = &.{.{ .text = "Earlier work is done." }} },
                .finish = .stop,
                .usage = .{},
            } };
        }
        if (self.summaries > 0) {
            var saw_rule = false;
            var saw_cwd = false;
            var saw_platform = false;
            for (req.messages) |message| {
                if (message.role != .context or message.blocks.len != 1 or message.blocks[0] != .text) continue;
                if (std.mem.indexOf(u8, message.blocks[0].text, "PROJECT_RULE") != null) saw_rule = true;
                if (std.mem.indexOf(u8, message.blocks[0].text, "cwd: /proj/cwd\n") != null) saw_cwd = true;
                if (session_context.parseEnvironment(message.blocks[0].text)) |env| {
                    if (env.os == .windows and env.arch == .aarch64) saw_platform = true;
                }
            }
            self.saw_policy_after_summary = saw_rule and saw_cwd and saw_platform;
        }
        return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{.{ .text = "ok" }} },
            .finish = .stop,
            .usage = .{},
        } };
    }
};
