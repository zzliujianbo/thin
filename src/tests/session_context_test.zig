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

const io = std.testing.io;

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

test "agents discovery order is global then git root and skips other directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try mkdir(tmp.dir, "home");
    try mkdir(tmp.dir, "home/.thin");
    try mkdir(tmp.dir, "tree");
    try mkdir(tmp.dir, "tree/repo");
    try mkdir(tmp.dir, "tree/repo/.git");
    try mkdir(tmp.dir, "tree/repo/mid");
    try mkdir(tmp.dir, "tree/repo/mid/leaf");
    try write(tmp.dir, "home/.thin/AGENTS.md", "GLOBAL_BASE\n");
    try write(tmp.dir, "tree/AGENTS.md", "ABOVE_REPO\n");
    try write(tmp.dir, "tree/repo/AGENTS.md", "PROJECT_BASE\n");
    try write(tmp.dir, "tree/repo/mid/AGENTS.md", "MID_LEVEL\n");
    try write(tmp.dir, "tree/repo/mid/leaf/AGENTS.md", "LEAF_LEVEL\n");

    const snap = try session_context.load(a, io, try absolute(a, tmp.dir, "home"), try absolute(a, tmp.dir, "tree/repo/mid/leaf"), "/bin/zsh");
    try std.testing.expect(std.mem.endsWith(u8, snap.cwd, "/tree/repo/mid/leaf"));
    try std.testing.expect(std.mem.endsWith(u8, snap.project_root, "/tree/repo"));
    try std.testing.expect(!std.mem.endsWith(u8, snap.project_root, "/leaf"));
    try std.testing.expectEqualStrings("/bin/zsh", snap.shell);
    try std.testing.expectEqualStrings("GLOBAL_BASE\nPROJECT_BASE\n", snap.agents_text);
    const global_at = std.mem.indexOf(u8, snap.agents, "GLOBAL_BASE").?;
    const project_at = std.mem.indexOf(u8, snap.agents, "PROJECT_BASE").?;
    try std.testing.expect(global_at < project_at);
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "/.thin/AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "/repo/AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "ABOVE_REPO") == null);
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "MID_LEVEL") == null);
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "LEAF_LEVEL") == null);
    try std.testing.expect(!snap.truncated);
}

test "agents override is preferred over the base file in each source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try mkdir(tmp.dir, "home");
    try mkdir(tmp.dir, "home/.thin");
    try mkdir(tmp.dir, "repo");
    try mkdir(tmp.dir, "repo/.git");
    try write(tmp.dir, "home/.thin/AGENTS.override.md", "OVERRIDE_GLOBAL\n");
    try write(tmp.dir, "home/.thin/AGENTS.md", "BASE_GLOBAL\n");
    try write(tmp.dir, "repo/AGENTS.override.md", "OVERRIDE_PROJECT\n");
    try write(tmp.dir, "repo/AGENTS.md", "BASE_PROJECT\n");

    const snap = try session_context.load(a, io, try absolute(a, tmp.dir, "home"), try absolute(a, tmp.dir, "repo"), "bash");
    try std.testing.expectEqualStrings("OVERRIDE_GLOBAL\nOVERRIDE_PROJECT\n", snap.agents_text);
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "AGENTS.override.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "BASE_GLOBAL") == null);
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "BASE_PROJECT") == null);
}

test "agents text is capped at 32KiB without reading past the budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try mkdir(tmp.dir, "home");
    try mkdir(tmp.dir, "home/.thin");
    try mkdir(tmp.dir, "repo");
    try mkdir(tmp.dir, "repo/.git");
    const global = try a.alloc(u8, 20_000);
    @memset(global, 'G');
    const project = try a.alloc(u8, 20_000);
    @memset(project, 'P');
    try write(tmp.dir, "home/.thin/AGENTS.md", global);
    try write(tmp.dir, "repo/AGENTS.md", project);

    const split = try session_context.load(a, io, try absolute(a, tmp.dir, "home"), try absolute(a, tmp.dir, "repo"), "bash");
    try std.testing.expect(split.truncated);
    try std.testing.expectEqual(session_context.max_agents_bytes, split.agents_text.len);
    try std.testing.expect(std.mem.allEqual(u8, split.agents_text[0..20_000], 'G'));
    try std.testing.expect(std.mem.allEqual(u8, split.agents_text[20_000..], 'P'));
    try std.testing.expect(std.mem.indexOf(u8, split.agents, "[truncated]\n") != null);

    const huge = try a.alloc(u8, 40_000);
    @memset(huge, 'G');
    try write(tmp.dir, "home/.thin/AGENTS.md", huge);
    const only_global = try session_context.load(a, io, try absolute(a, tmp.dir, "home"), try absolute(a, tmp.dir, "repo"), "bash");
    try std.testing.expect(only_global.truncated);
    try std.testing.expectEqual(session_context.max_agents_bytes, only_global.agents_text.len);
    try std.testing.expect(std.mem.allEqual(u8, only_global.agents_text, 'G'));
    // The project file is nonempty and did not fit. Name it and mark the cut
    // even though none of its bytes were copied. The global section is also
    // truncated, so the project marker is the one after its source header.
    const project_at = std.mem.indexOf(u8, only_global.agents, "source: project\n").?;
    try std.testing.expect(std.mem.indexOf(u8, only_global.agents[project_at..], "[truncated]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, only_global.agents, "PPP") == null);
}

test "exact 32KiB global budget still marks an omitted nonempty project source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try mkdir(tmp.dir, "home");
    try mkdir(tmp.dir, "home/.thin");
    try mkdir(tmp.dir, "repo");
    try mkdir(tmp.dir, "repo/.git");
    const global = try a.alloc(u8, session_context.max_agents_bytes);
    @memset(global, 'G');
    try write(tmp.dir, "home/.thin/AGENTS.md", global);
    try write(tmp.dir, "repo/AGENTS.md", "PROJECT_OMITTED\n");

    const snap = try session_context.load(a, io, try absolute(a, tmp.dir, "home"), try absolute(a, tmp.dir, "repo"), "bash");
    try std.testing.expect(snap.truncated);
    try std.testing.expectEqual(session_context.max_agents_bytes, snap.agents_text.len);
    try std.testing.expect(std.mem.allEqual(u8, snap.agents_text, 'G'));
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "PROJECT_OMITTED") == null);
    const project_at = std.mem.indexOf(u8, snap.agents, "source: project\n").?;
    const mark_at = std.mem.indexOf(u8, snap.agents, "[truncated]\n").?;
    try std.testing.expect(mark_at > project_at);
    // The global file fit exactly, so its own section is not the truncation.
    try std.testing.expect(std.mem.indexOf(u8, snap.agents[0..project_at], "[truncated]") == null);
}

test "unreadable optional agents files are skipped and an override does not fall through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try mkdir(tmp.dir, "home");
    try mkdir(tmp.dir, "home/.thin");
    try mkdir(tmp.dir, "repo");
    try mkdir(tmp.dir, "repo/.git");
    try write(tmp.dir, "home/.thin/AGENTS.override.md", "OVERRIDE_SECRET\n");
    try write(tmp.dir, "home/.thin/AGENTS.md", "GLOBAL_BASE\n");
    try write(tmp.dir, "repo/AGENTS.md", "PROJECT_OK\n");
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(tmp.dir.handle, "home/.thin/AGENTS.override.md", 0, 0));

    const hidden_override = try session_context.load(a, io, try absolute(a, tmp.dir, "home"), try absolute(a, tmp.dir, "repo"), "bash");
    try std.testing.expect(std.mem.indexOf(u8, hidden_override.agents, "OVERRIDE_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_override.agents, "GLOBAL_BASE") == null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_override.agents, "PROJECT_OK") != null);

    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(tmp.dir.handle, "home/.thin/AGENTS.override.md", 0));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(tmp.dir.handle, "home/.thin/AGENTS.md", 0, 0));
    const hidden_global = try session_context.load(a, io, try absolute(a, tmp.dir, "home"), try absolute(a, tmp.dir, "repo"), "bash");
    try std.testing.expect(std.mem.indexOf(u8, hidden_global.agents, "GLOBAL_BASE") == null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_global.agents, "PROJECT_OK") != null);

    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(tmp.dir.handle, "home/.thin/AGENTS.md", 0o644, 0));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(tmp.dir.handle, "repo/AGENTS.md", 0, 0));
    const hidden_project = try session_context.load(a, io, try absolute(a, tmp.dir, "home"), try absolute(a, tmp.dir, "repo"), "bash");
    try std.testing.expect(std.mem.indexOf(u8, hidden_project.agents, "GLOBAL_BASE") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_project.agents, "PROJECT_OK") == null);
    try std.testing.expect(!hidden_project.truncated);
}

fn rm(parent: std.Io.Dir, name: [*:0]const u8, directory: bool) void {
    _ = std.c.unlinkat(parent.handle, name, if (directory) 0x200 else 0);
}

test "missing agents files are skipped and a directory without git uses cwd" {
    // The build cache lives inside this repo, so a cache temp dir would climb to
    // the Thin checkout. This fixture sits in /tmp, outside any work tree.
    var scratch = try std.Io.Dir.cwd().openDir(io, "/tmp", .{});
    defer scratch.close(io);
    rm(scratch, "thin-agents-nogit-c229/parent/cwd", true);
    rm(scratch, "thin-agents-nogit-c229/parent/AGENTS.md", false);
    rm(scratch, "thin-agents-nogit-c229/parent", true);
    rm(scratch, "thin-agents-nogit-c229/home", true);
    rm(scratch, "thin-agents-nogit-c229", true);
    try mkdir(scratch, "thin-agents-nogit-c229");
    var tmp = try scratch.openDir(io, "thin-agents-nogit-c229", .{});
    defer {
        tmp.close(io);
        rm(scratch, "thin-agents-nogit-c229/parent/cwd", true);
        rm(scratch, "thin-agents-nogit-c229/parent/AGENTS.md", false);
        rm(scratch, "thin-agents-nogit-c229/parent", true);
        rm(scratch, "thin-agents-nogit-c229/home", true);
        rm(scratch, "thin-agents-nogit-c229", true);
    }
    try mkdir(tmp, "home");
    try mkdir(tmp, "parent");
    try mkdir(tmp, "parent/cwd");
    try write(tmp, "parent/AGENTS.md", "PARENT_ONLY\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try absolute(a, tmp, "parent/cwd");
    const snap = try session_context.load(a, io, try absolute(a, tmp, "home"), cwd, "not a\nshell");
    try std.testing.expectEqualStrings("", snap.agents);
    try std.testing.expectEqualStrings("", snap.agents_text);
    try std.testing.expect(!snap.truncated);
    try std.testing.expectEqualStrings(snap.cwd, snap.project_root);
    try std.testing.expect(std.mem.endsWith(u8, snap.project_root, "/parent/cwd"));
    try std.testing.expectEqualStrings("bash", snap.shell);
    try std.testing.expect(std.mem.indexOf(u8, snap.agents, "PARENT_ONLY") == null);
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
    var runtime = try r.Runtime.init(std.testing.allocator, io, config, .{ .context = &stub_dummy, .call_fn = stubCall }, .{ .context = &stub_dummy, .schemas = &.{}, .prepare_fn = stubPrepare, .execute_fn = stubExecute }, .{}, "", false);
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
        .max_output_tokens = 32,
    };
    return switch (protocol) {
        .chat => chat.encode(a, req),
        .responses => responses.encode(a, req),
        .anthropic => anthropic.encode(a, req),
        .auto => unreachable,
    };
}

test "environment preface is injected before the user turn for chat responses and anthropic" {
    var config = cfg.Config{
        .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat },
    };
    var box = Box{ .snap = baseSnap("source: global\npath: /home/u/.thin/AGENTS.md\nGLOBAL_RULE\n") };
    var runtime = try openRuntime(&config, &box);
    defer runtime.deinit();
    var cancel = p.Cancellation{};
    const system = runtime.system;
    try std.testing.expectEqual(r.Status.success, (try runtime.run("hello-user", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 4), runtime.messages().len);
    try std.testing.expect(std.mem.startsWith(u8, textOf(runtime.messages()[0]), "agents\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[0]), "GLOBAL_RULE") != null);
    try std.testing.expect(std.mem.startsWith(u8, textOf(runtime.messages()[1]), "environment\n"));
    try std.testing.expect(std.mem.startsWith(u8, textOf(runtime.messages()[1]), "environment update\n") == false);
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[1]), "cwd: /proj/cwd\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[1]), "shell: /bin/zsh\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[1]), "project_root: /proj\n") != null);
    try std.testing.expectEqualStrings("hello-user", textOf(runtime.messages()[2]));
    try std.testing.expect(runtime.system.ptr == system.ptr);
    try std.testing.expect(std.mem.indexOf(u8, runtime.system, "/proj/cwd") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        const bytes = try encodeWire(a, &runtime, protocol);
        const preface = std.mem.indexOf(u8, bytes, "cwd: /proj/cwd").?;
        const rule = std.mem.indexOf(u8, bytes, "GLOBAL_RULE").?;
        const user = std.mem.indexOf(u8, bytes, "hello-user").?;
        try std.testing.expect(rule < preface);
        try std.testing.expect(preface < user);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "/bin/zsh") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "project_root: /proj") != null);
    }
}

test "cwd change appends a new preface and does not mutate the original messages" {
    var config = cfg.Config{
        .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat },
    };
    var box = Box{ .snap = baseSnap("source: project\npath: /proj/AGENTS.md\nKEEP\n") };
    var runtime = try openRuntime(&config, &box);
    defer runtime.deinit();
    var cancel = p.Cancellation{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("first", &cancel)).status);
    const original_agents = try std.testing.allocator.dupe(u8, textOf(runtime.messages()[0]));
    defer std.testing.allocator.free(original_agents);
    const original_env = try std.testing.allocator.dupe(u8, textOf(runtime.messages()[1]));
    defer std.testing.allocator.free(original_env);
    const system = try std.testing.allocator.dupe(u8, runtime.system);
    defer std.testing.allocator.free(system);

    try std.testing.expectEqual(r.Status.success, (try runtime.run("same", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 6), runtime.messages().len);
    try std.testing.expectEqualStrings(original_agents, textOf(runtime.messages()[0]));
    try std.testing.expectEqualStrings(original_env, textOf(runtime.messages()[1]));

    box.snap.cwd = "/proj/other";
    box.snap.project_root = "/other";
    box.snap.agents = "source: project\npath: /other/AGENTS.md\nNEXT\n";
    try std.testing.expectEqual(r.Status.success, (try runtime.run("moved", &cancel)).status);
    try std.testing.expectEqualStrings(original_agents, textOf(runtime.messages()[0]));
    try std.testing.expectEqualStrings(original_env, textOf(runtime.messages()[1]));
    try std.testing.expectEqualStrings(system, runtime.system);
    try std.testing.expect(std.mem.startsWith(u8, textOf(runtime.messages()[6]), "agents update\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[6]), "NEXT") != null);
    try std.testing.expect(std.mem.startsWith(u8, textOf(runtime.messages()[7]), "environment update\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[7]), "cwd: /proj/other\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[7]), "project_root: /other\n") != null);
    try std.testing.expectEqualStrings("moved", textOf(runtime.messages()[8]));
    try std.testing.expect(std.mem.indexOf(u8, original_env, "/proj/other") == null);
    try std.testing.expect(std.mem.indexOf(u8, original_agents, "NEXT") == null);
}

test "a directory change before the first turn rebuilds the fresh prefix" {
    var config = cfg.Config{
        .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat },
    };
    var box = Box{ .snap = baseSnap("") };
    box.snap.cwd = "/proj/later";
    var runtime = try openRuntime(&config, &box);
    defer runtime.deinit();
    var cancel = p.Cancellation{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("only", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 3), runtime.messages().len);
    try std.testing.expect(std.mem.startsWith(u8, textOf(runtime.messages()[0]), "environment\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[0]), "cwd: /proj/later\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[0]), "environment update") == null);
}

test "restored preface is kept until the session policy changes" {
    var config = cfg.Config{
        .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat },
    };
    var box = Box{ .snap = baseSnap("") };
    var runtime = try openRuntime(&config, &box);
    defer runtime.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const saved = try session_context.formatEnvironment(arena.allocator(), session_context.environmentOf(box.snap), false);
    var state = try runtime.checkpoint();
    state.messages = &.{
        .{ .role = .context, .blocks = &.{.{ .text = saved }} },
        .{ .role = .user, .blocks = &.{.{ .text = "earlier" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} },
    };
    try runtime.restoreCheckpoint(state);
    var cancel = p.Cancellation{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("next", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 5), runtime.messages().len);
    try std.testing.expectEqualStrings(saved, textOf(runtime.messages()[0]));
    try std.testing.expectEqualStrings("earlier", textOf(runtime.messages()[1]));
    try std.testing.expectEqualStrings("next", textOf(runtime.messages()[3]));

    box.snap.cwd = "/proj/resumed";
    try std.testing.expectEqual(r.Status.success, (try runtime.run("after", &cancel)).status);
    try std.testing.expectEqualStrings(saved, textOf(runtime.messages()[0]));
    try std.testing.expect(std.mem.startsWith(u8, textOf(runtime.messages()[5]), "environment update\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(runtime.messages()[5]), "cwd: /proj/resumed\n") != null);
    try std.testing.expectEqualStrings("after", textOf(runtime.messages()[6]));
}

test "app wires agents discovery and appends when the working directory changes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try mkdir(tmp.dir, "home");
    try mkdir(tmp.dir, "home/.thin");
    try mkdir(tmp.dir, "tree");
    try mkdir(tmp.dir, "tree/repo");
    try mkdir(tmp.dir, "tree/repo/.git");
    try mkdir(tmp.dir, "tree/repo/mid");
    try mkdir(tmp.dir, "tree/other");
    try mkdir(tmp.dir, "tree/other/.git");
    const fake =
        \\{"provider":{"base_url":"http://unused.invalid","api_key":"fake-review-key"},"model":{"name":"fake","context_tokens":32768,"protocol":"chat"}}
    ;
    try write(tmp.dir, "home/.thin/config.json", fake);
    try write(tmp.dir, "home/.thin/AGENTS.override.md", "APP_GLOBAL\n");
    try write(tmp.dir, "home/.thin/AGENTS.md", "APP_GLOBAL_BASE\n");
    try write(tmp.dir, "tree/AGENTS.md", "APP_ABOVE\n");
    try write(tmp.dir, "tree/repo/AGENTS.md", "APP_PROJECT\n");
    try write(tmp.dir, "tree/repo/mid/AGENTS.md", "APP_MID\n");
    try write(tmp.dir, "tree/other/AGENTS.override.md", "APP_OTHER\n");

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const home = try absolute(a, tmp.dir, "home");
    defer a.free(home);
    try env.put("HOME", home);
    try env.put("SHELL", "/bin/zsh");
    const project = try absolute(a, tmp.dir, "tree/repo/mid");
    defer a.free(project);
    const app = try App.init(a, io, &env, project, .{}, false);
    defer app.deinit();
    app.runtime.model = .{ .context = &stub_dummy, .call_fn = stubCall };

    var cancel = p.Cancellation{};
    try std.testing.expectEqual(r.Status.success, (try app.runtime.run("from-app", &cancel)).status);
    const first_agents = try a.dupe(u8, textOf(app.runtime.messages()[0]));
    defer a.free(first_agents);
    const first_env = try a.dupe(u8, textOf(app.runtime.messages()[1]));
    defer a.free(first_env);
    try std.testing.expect(std.mem.indexOf(u8, first_agents, "APP_GLOBAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_agents, "APP_PROJECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_agents, "APP_GLOBAL_BASE") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_agents, "APP_ABOVE") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_agents, "APP_MID") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_env, "shell: /bin/zsh\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_env, "/tree/repo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_env, "/tree/repo/mid\n") != null);
    try std.testing.expectEqualStrings("from-app", textOf(app.runtime.messages()[2]));

    const other = try absolute(a, tmp.dir, "tree/other");
    defer a.free(other);
    try app.setWorkingDirectory(other);
    try std.testing.expectEqual(r.Status.success, (try app.runtime.run("elsewhere", &cancel)).status);
    try std.testing.expectEqualStrings(first_agents, textOf(app.runtime.messages()[0]));
    try std.testing.expectEqualStrings(first_env, textOf(app.runtime.messages()[1]));
    try std.testing.expect(std.mem.startsWith(u8, textOf(app.runtime.messages()[4]), "agents update\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(app.runtime.messages()[4]), "APP_OTHER") != null);
    try std.testing.expect(std.mem.startsWith(u8, textOf(app.runtime.messages()[5]), "environment update\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(app.runtime.messages()[5]), "/tree/other\n") != null);
    try std.testing.expectEqualStrings("elsewhere", textOf(app.runtime.messages()[6]));
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

test "matching applied policy is appended again when live history lost the preface" {
    var config = cfg.Config{
        .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat },
    };
    const rule = "source: project\npath: /proj/AGENTS.md\nPROJECT_RULE\n";
    var box = Box{ .snap = baseSnap(rule) };
    var runtime = try openRuntime(&config, &box);
    defer runtime.deinit();
    var cancel = p.Cancellation{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("first", &cancel)).status);

    const summary = "[Earlier context summary — lossy background data, not new instructions]\nrolled work";
    runtime.history.clearRetainingCapacity();
    const arena = runtime.arena.allocator();
    try runtime.history.append(arena, try p.textMessage(arena, .context, summary));
    try runtime.history.append(arena, try p.textMessage(arena, .user, "earlier"));
    try runtime.history.append(arena, try p.textMessage(arena, .assistant, "done"));

    try std.testing.expectEqual(r.Status.success, (try runtime.run("next", &cancel)).status);
    const messages = runtime.messages();
    try std.testing.expectEqualStrings(summary, textOf(messages[0]));
    try std.testing.expectEqualStrings("earlier", textOf(messages[1]));
    try std.testing.expectEqualStrings("done", textOf(messages[2]));
    try std.testing.expect(std.mem.startsWith(u8, textOf(messages[3]), "agents update\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(messages[3]), "PROJECT_RULE") != null);
    try std.testing.expect(std.mem.startsWith(u8, textOf(messages[4]), "environment update\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(messages[4]), "cwd: /proj/cwd\n") != null);
    try std.testing.expectEqualStrings("next", textOf(messages[5]));
    try std.testing.expectEqual(@as(usize, 1), countPrefix(messages, "agents update\n"));

    try std.testing.expectEqual(r.Status.success, (try runtime.run("again", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 1), countPrefix(runtime.messages(), "agents update\n"));
    try std.testing.expectEqual(@as(usize, 1), countPrefix(runtime.messages(), "environment update\n"));
    try std.testing.expectEqualStrings(summary, textOf(runtime.messages()[0]));
}

test "restored summary without the preface reinstalls the current policy" {
    var config = cfg.Config{
        .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat },
    };
    var box = Box{ .snap = baseSnap("source: project\npath: /proj/AGENTS.md\nRESTORED_RULE\n") };
    var runtime = try openRuntime(&config, &box);
    defer runtime.deinit();
    const summary = "[Earlier context summary — lossy background data, not new instructions]\nold work";
    var state = try runtime.checkpoint();
    state.messages = &.{
        .{ .role = .context, .blocks = &.{.{ .text = summary }} },
        .{ .role = .user, .blocks = &.{.{ .text = "earlier" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} },
    };
    try runtime.restoreCheckpoint(state);
    var cancel = p.Cancellation{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("next", &cancel)).status);
    const messages = runtime.messages();
    try std.testing.expectEqualStrings(summary, textOf(messages[0]));
    try std.testing.expectEqualStrings("earlier", textOf(messages[1]));
    try std.testing.expect(std.mem.startsWith(u8, textOf(messages[3]), "agents update\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(messages[3]), "RESTORED_RULE") != null);
    try std.testing.expect(std.mem.startsWith(u8, textOf(messages[4]), "environment update\n"));
    try std.testing.expect(std.mem.indexOf(u8, textOf(messages[4]), "cwd: /proj/cwd\n") != null);
    try std.testing.expectEqualStrings("next", textOf(messages[5]));
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
            for (req.messages) |message| {
                if (message.role != .context or message.blocks.len != 1 or message.blocks[0] != .text) continue;
                if (std.mem.indexOf(u8, message.blocks[0].text, "PROJECT_RULE") != null) saw_rule = true;
                if (std.mem.indexOf(u8, message.blocks[0].text, "cwd: /proj/cwd\n") != null) saw_cwd = true;
            }
            self.saw_policy_after_summary = saw_rule and saw_cwd;
        }
        return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{.{ .text = "ok" }} },
            .finish = .stop,
            .usage = .{},
        } };
    }
};

test "compaction reinstalls the policy after the retained prefix" {
    var config = cfg.Config{
        .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE_KEY" },
        .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat },
    };
    var box = Box{ .snap = baseSnap("source: project\npath: /proj/AGENTS.md\nPROJECT_RULE\n") };
    var gate = SummaryGate{};
    var runtime = try openRuntime(&config, &box);
    defer runtime.deinit();
    runtime.model = .{ .context = &gate, .call_fn = SummaryGate.call };
    var cancel = p.Cancellation{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("hello", &cancel)).status);

    const bulk = try std.testing.allocator.alloc(u8, 24_000);
    defer std.testing.allocator.free(bulk);
    @memset(bulk, 'B');
    const arena = runtime.arena.allocator();
    try runtime.history.append(arena, try p.textMessage(arena, .user, bulk));
    try runtime.history.append(arena, try p.textMessage(arena, .assistant, "retained-tail"));

    config.model.context_tokens = 20000;
    config.limits.max_output_tokens = 400;
    config.limits.summary_tokens = 200;
    config.limits.safety_tokens = 200;
    config.limits.compaction_trigger_percent = 40;
    config.limits.compaction_target_percent = 20;

    try std.testing.expectEqual(r.Status.success, (try runtime.run("next-goal", &cancel)).status);
    try std.testing.expectEqual(@as(u32, 1), gate.summaries);
    try std.testing.expect(gate.saw_policy_after_summary);
    const messages = runtime.messages();
    try std.testing.expect(std.mem.startsWith(u8, textOf(messages[0]), "[Earlier context summary"));
    const tail = indexOfText(messages, "retained-tail").?;
    const goal = indexOfText(messages, "next-goal").?;
    const agents = indexOfText(messages, "agents update\n").?;
    const env = indexOfText(messages, "environment update\n").?;
    try std.testing.expect(tail < goal and goal < agents and agents < env);
    try std.testing.expect(std.mem.indexOf(u8, textOf(messages[agents]), "PROJECT_RULE") != null);
    try std.testing.expect(std.mem.indexOf(u8, textOf(messages[env]), "cwd: /proj/cwd\n") != null);
    try std.testing.expectEqual(@as(usize, 0), countPrefix(messages, "agents\n"));

    try std.testing.expectEqual(r.Status.success, (try runtime.run("later", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 1), countPrefix(runtime.messages(), "agents update\n"));
    try std.testing.expectEqual(@as(usize, 1), countPrefix(runtime.messages(), "environment update\n"));
}
