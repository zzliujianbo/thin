//! Owns the fixed process configuration and project resources. No terminal I/O.

const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const tools = @import("../tools/tools.zig");
const http = @import("../llm/http.zig");
const r = @import("../core/runtime.zig");
const Journal = @import("journal.zig").Journal;

/// 应用聚合体：持有配置、项目根目录、记忆存储、工具执行器、HTTP 客户端与 Runtime，
/// 生命周期与进程一致（--print 或 TUI 会话结束时统一释放）。
pub const App = struct {
    allocator: std.mem.Allocator,

    /// 已解析的配置；Parsed 持有 arena，必须通过 cfg.release 擦除后释放。
    config: std.json.Parsed(cfg.Config),

    /// 项目根目录句柄（记忆与工具文件访问的基准）。
    root: fs.Root,
    /// 用户认证文件的绝对路径，普通文件工具不得读取或覆盖它。
    auth_path: []const u8,
    /// 项目记忆存储，指向上面的 root。
    memory: mem.Store,
    /// 可选本地会话留档；首次提交才创建文件，不参与 Runtime 的授权或结果判断。
    journal: Journal,

    /// 供工具子进程使用的环境变量副本（由 tools.commandEnvironment 生成）。
    environment: std.process.Environ.Map,
    /// 工具执行器，内部保存上述字段的指针。
    executor: tools.Tools,
    /// LLM HTTP 客户端，初始化时传入 API key。
    client: http.Client,

    /// Agent 运行时，最后初始化，依赖前面所有字段。
    runtime: r.Runtime,

    /// Heap placement is intentional: Store, Tools, Client and Runtime refer to
    /// these fields, so returning a self-referential value would invalidate them.
    /// 按依赖顺序初始化各组件，并用 errdefer 保证任一步失败时已创建的部分被回滚。
    /// API key 来自配置指定的凭证源；临时副本使用后清零，客户端持有自己的副本。
    pub fn init(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host, trusted: bool) !*App {
        const home = environ.get("HOME") orelse return error.MissingHome;
        const path = try cfg.defaultPath(a, home);
        defer a.free(path);
        const parsed = try cfg.load(a, io, path);
        return initConfigured(a, io, environ, project, host, trusted, parsed);
    }

    /// 接管 parsed（成功或失败均接管），供交互配置准备候选 App；此过程不发送模型请求。
    pub fn initConfigured(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host, trusted: bool, parsed: std.json.Parsed(cfg.Config)) !*App {
        var owned = parsed;
        errdefer cfg.release(&owned);
        const self = try a.create(App);
        errdefer a.destroy(self);
        self.allocator = a;
        self.config = owned;

        const home = environ.get("HOME") orelse return error.MissingHome;
        const configured_path = try cfg.defaultPath(a, home);
        defer a.free(configured_path);
        // 配置加载可能经过 HOME 或文件本身的符号链接。工具根是 realPath，
        // 保护路径也必须指向真实文件，不能只做词法 resolve 后比较两个别名。
        var path_buffer: [4096]u8 = undefined;
        const path_len = try std.Io.Dir.cwd().realPathFile(io, configured_path, &path_buffer);
        self.auth_path = try a.dupe(u8, path_buffer[0..path_len]);
        errdefer a.free(self.auth_path);

        const key = try cfg.resolveApiKey(a, self.config.value, environ);
        defer {
            std.crypto.secureZero(u8, key);
            a.free(key);
        }

        self.root = try fs.Root.open(a, io, project);
        errdefer self.root.deinit();
        self.memory = mem.Store.init(&self.root, self.config.value.limits);
        self.journal = try Journal.init(a, &self.root, key);
        self.journal.protocol = self.config.value.model.protocol;
        errdefer self.journal.deinit();
        self.environment = try tools.commandEnvironment(a, environ, self.config.value.provider.api_key_env);
        errdefer self.environment.deinit();
        self.executor = .{ .root = &self.root, .memory = &self.memory, .config = &self.config.value, .environment = &self.environment, .auth_path = self.auth_path };
        self.client = try http.Client.init(a, io, &self.config.value, key);
        errdefer self.client.deinit();

        const snapshot = try self.memory.snapshot(a);
        defer a.free(snapshot);
        self.runtime = try r.Runtime.init(a, io, &self.config.value, self.client.model(), self.executor.executor(), host, snapshot, trusted);
        self.runtime.observer = self.journal.observer();
        return self;
    }

    /// Interactive owner pins the immutable ID before the first submission.
    /// Headless callers retain lazy ID generation and need not call this.
    pub fn pinSessionID(self: *App, id: [32]u8) !void {
        if (self.runtime.busy.load(.acquire)) return error.Busy;
        try self.journal.pinSessionID(id);
    }

    /// 只在首次提交前设置；关闭不会读取或删除已有日志。
    pub fn setLogging(self: *App, enabled: bool) void {
        std.debug.assert(!self.runtime.busy.load(.acquire));
        self.journal.setEnabled(enabled);
    }

    /// 按创建的逆序释放资源，最后销毁自身。
    pub fn deinit(self: *App) void {
        const a = self.allocator;
        self.runtime.deinit();
        self.journal.deinit();
        self.client.deinit();
        self.environment.deinit();
        self.root.deinit();
        a.free(self.auth_path);
        cfg.release(&self.config);
        a.destroy(self);
    }
};

// 配置加载可经由符号链接，但文件工具必须保护最终实际文件，而非 HOME 的词法别名。
test "App protects actual configuration behind HOME and file symlinks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fake =
        \\{"provider":{"base_url":"http://unused.invalid","api_key":"fake-review-key"},"model":{"name":"fake","context_tokens":32768,"protocol":"chat"}}
    ;
    for ([_]bool{ false, true }) |linked_file| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "home", 0o700));
        var home_dir = try tmp.dir.openDir(io, "home", .{});
        defer home_dir.close(io);
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(home_dir.handle, ".thin", 0o700));
        const target = if (linked_file) "credentials.json" else ".thin/config.json";
        try home_dir.writeFile(io, .{ .sub_path = target, .data = fake });
        if (linked_file) try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("../credentials.json", home_dir.handle, ".thin/config.json"));
        try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("home", tmp.dir.handle, "alias"));
        var buffer: [4096]u8 = undefined;
        const n = try home_dir.realPath(io, &buffer);
        const project = buffer[0..n];
        const alias = try std.fs.path.resolve(a, &.{ project, "../alias" });
        defer a.free(alias);
        for ([_][]const u8{ project, alias }) |home| {
            var env = std.process.Environ.Map.init(a);
            defer env.deinit();
            try env.put("HOME", home);
            const app = try App.init(a, io, &env, project, .{}, false);
            defer app.deinit();
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const allocator = arena.allocator();
            const executor = app.executor.executor();
            const arguments = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{target});
            try std.testing.expectError(error.ProtectedAuthFile, executor.prepare_fn(executor.context, allocator, .{ .id = "read-config", .name = "read_file", .arguments = arguments }));
            var cancel = @import("../core/protocol.zig").Cancellation{};
            for ([_][]const u8{ target, app.auth_path }) |path| {
                try std.testing.expectError(error.ProtectedAuthFile, app.executor.execute(allocator, .{ .read_file = .{ .path = path } }, &cancel));
                try std.testing.expectError(error.ProtectedAuthFile, app.executor.execute(allocator, .{ .write_file = .{ .path = path, .content = "not written", .overwrite = true } }, &cancel));
            }
        }
    }
}
