//! Owns the fixed process configuration and project resources. No terminal I/O.

const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const tools = @import("../tools/tools.zig");
const http = @import("../llm/http.zig");
const r = @import("../core/runtime.zig");
const Journal = @import("journal.zig").Journal;
const Settings = @import("settings_store.zig").Store;
const thinking = @import("../core/thinking.zig");
const metadata = @import("model_metadata.zig");
const session_context = @import("../core/session_context.zig");

/// 应用聚合体：持有配置、项目根目录、记忆存储、工具执行器、HTTP 客户端与 Runtime，
/// 生命周期与进程一致（--print 或 TUI 会话结束时统一释放）。
pub const App = struct {
    allocator: std.mem.Allocator,

    /// 已解析的配置；Parsed 持有 arena，必须通过 cfg.release 擦除后释放。
    config: std.json.Parsed(cfg.Config),

    /// 项目根目录句柄（记忆与工具文件访问的基准）。
    root: fs.Root,
    /// HOME directory used to find `<HOME>/.thin/AGENTS.md`. Empty skips that source.
    home_path: []u8,
    /// Shell reported in the session preface. Captured from SHELL at startup.
    shell_name: []u8,
    /// Working directory reported to the model. Starts as the startup project.
    /// setWorkingDirectory changes the next turn's preface without editing earlier messages.
    session_cwd: []u8,
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
        var parsed = try cfg.load(a, io, path);
        // Derived defaults are not embedded in config.json. Headless entry can
        // reuse a compatible cached profile without creating/fetching metadata.
        if ((parsed.value.model.reasoning_source != .explicit or parsed.value.model.reasoning == null) and metadata.reasoningIndex(parsed.value) != null) {
            var store: ?@import("auth_store.zig").Store = @import("auth_store.zig").Store.openExisting(a, io, home) catch null;
            if (store) |*value| {
                defer value.deinit();
                const cache = metadata.load(&value.root) catch metadata.Cache{};
                metadata.applyReasoning(&cache, &parsed.value);
            }
        }
        // Headless entry creates the same missing project default as the TUI,
        // without changing the global configuration on disk.
        var settings = Settings.open(a, io, project) catch |err| {
            cfg.release(&parsed);
            return err;
        };
        defer settings.deinit();
        const capabilities = thinking.resolve(parsed.value.provider.base_url, parsed.value.model.name, parsed.value.model.reasoning);
        const saved = settings.loadOrInitialize(capabilities.defaultEffort(parsed.value.model.reasoning_effort)) catch |err| {
            cfg.release(&parsed);
            return err;
        };
        if (capabilities.known) parsed.value.model.reasoning_effort = capabilities.effective(saved.name());
        return initConfiguredAnchored(a, io, environ, &settings.root, host, trusted, parsed);
    }

    /// 接管 parsed（成功或失败均接管），供交互配置准备候选 App；此过程不发送模型请求。
    pub fn initConfigured(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host, trusted: bool, parsed: std.json.Parsed(cfg.Config)) !*App {
        return initConfiguredRoot(a, io, environ, project, null, null, host, trusted, parsed);
    }

    /// Duplicate an already anchored project; never re-open its replaceable
    /// pathname during activation. parsed is consumed on success AND failure.
    pub fn initConfiguredAnchored(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, root: *const fs.Root, host: r.Host, trusted: bool, parsed: std.json.Parsed(cfg.Config)) !*App {
        return initConfiguredRoot(a, io, environ, root.path, root, null, host, trusted, parsed);
    }

    /// Delayed activation must retain the Auth Store's startup pathname in the
    /// SAME lexical namespace as root, not rediscover a replaced HOME path.
    pub fn initConfiguredAnchoredAuth(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, root: *const fs.Root, protected_auth: []const u8, host: r.Host, trusted: bool, parsed: std.json.Parsed(cfg.Config)) !*App {
        return initConfiguredRoot(a, io, environ, root.path, root, protected_auth, host, trusted, parsed);
    }

    fn initConfiguredRoot(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, anchored: ?*const fs.Root, protected_auth: ?[]const u8, host: r.Host, trusted: bool, parsed: std.json.Parsed(cfg.Config)) !*App {
        var owned = parsed;
        errdefer cfg.release(&owned);
        const self = try a.create(App);
        errdefer a.destroy(self);
        self.allocator = a;
        self.config = owned;

        self.auth_path = if (protected_auth) |path| try a.dupe(u8, path) else blk: {
            const home = environ.get("HOME") orelse return error.MissingHome;
            const configured_path = try cfg.defaultPath(a, home);
            defer a.free(configured_path);
            // Ordinary loading may follow HOME/file aliases; preserve actual
            // canonical protection. Delayed anchored activation uses the
            // explicit startup namespace instead of this pathname lookup.
            var path_buffer: [4096]u8 = undefined;
            const path_len = try std.Io.Dir.cwd().realPathFile(io, configured_path, &path_buffer);
            break :blk try a.dupe(u8, path_buffer[0..path_len]);
        };
        errdefer a.free(self.auth_path);

        const key = try cfg.resolveApiKey(a, self.config.value, environ);
        defer {
            std.crypto.secureZero(u8, key);
            a.free(key);
        }

        self.root = if (anchored) |root| try root.duplicate() else try fs.Root.open(a, io, project);
        errdefer self.root.deinit();
        self.home_path = if (environ.get("HOME")) |home| try a.dupe(u8, home) else try a.dupe(u8, "");
        errdefer a.free(self.home_path);
        self.shell_name = try a.dupe(u8, session_context.shellName(environ.get("SHELL")));
        errdefer a.free(self.shell_name);
        self.session_cwd = try a.dupe(u8, self.root.path);
        errdefer a.free(self.session_cwd);
        self.memory = mem.Store.init(&self.root, self.config.value.limits);
        self.journal = try Journal.init(a, &self.root, key);
        errdefer self.journal.deinit();
        for (cfg.providers.Id.all) |id| if (self.config.value.credentials.get(id)) |saved| try self.journal.rememberKey(saved);
        self.journal.protocol = self.config.value.model.protocol;
        self.environment = try tools.commandEnvironment(a, environ, self.config.value.provider.api_key_env);
        errdefer self.environment.deinit();
        self.executor = .{ .root = &self.root, .memory = &self.memory, .config = &self.config.value, .environment = &self.environment, .auth_path = self.auth_path };
        self.client = try http.Client.init(a, io, &self.config.value, key);
        errdefer self.client.deinit();

        const snapshot = try self.memory.snapshot(a);
        defer a.free(snapshot);
        self.runtime = try r.Runtime.init(a, io, &self.config.value, self.client.model(), self.executor.executor(), host, snapshot, trusted);
        self.runtime.session_loader = .{ .context = self, .load_fn = loadSessionPolicy };
        self.runtime.observer = self.journal.observer();
        self.recordSelection();
        return self;
    }

    /// Heap-placed until publication: the unused client borrows this config.
    /// No requests may use it before installConnection rebinds App's pointers.
    pub const ConnectionReplacement = struct {
        owner: *App,
        config: std.json.Parsed(cfg.Config),
        client: http.Client,
        plan: r.Runtime.SelectionPlan,

        pub fn deinit(self: *ConnectionReplacement) void {
            const a = self.owner.allocator;
            self.client.deinit();
            cfg.release(&self.config);
            a.destroy(self);
        }
    };

    /// Consumes parsed on every path. The current App and canonical history are
    /// unchanged on failure; extending known-key redaction is fail-closed.
    pub fn prepareConnection(self: *App, parsed: std.json.Parsed(cfg.Config), environ: *const std.process.Environ.Map) !*ConnectionReplacement {
        var owned = parsed;
        errdefer cfg.release(&owned);
        const plan = try self.runtime.planSelection(owned.value, true);
        if (!std.meta.eql(owned.value.limits, self.config.value.limits)) return error.ConnectionLimitsChanged;
        const key = try cfg.resolveApiKey(self.allocator, owned.value, environ);
        defer {
            std.crypto.secureZero(u8, key);
            self.allocator.free(key);
        }
        try self.journal.rememberKey(key);
        for (cfg.providers.Id.all) |id| if (owned.value.credentials.get(id)) |saved| try self.journal.rememberKey(saved);
        const replacement = try self.allocator.create(ConnectionReplacement);
        errdefer self.allocator.destroy(replacement);
        replacement.owner = self;
        replacement.config = owned;
        replacement.plan = plan;
        replacement.client = try http.Client.init(self.allocator, self.root.io, &replacement.config.value, key);
        return replacement;
    }

    /// Owner has joined/drained the worker. There are no allocations, requests,
    /// storage writes or fallible operations after this publication boundary.
    pub fn installConnection(self: *App, replacement: *ConnectionReplacement) void {
        std.debug.assert(replacement.owner == self);
        self.runtime.applySelection(replacement.plan);
        var previous = self.config;
        // Never relocate a used pool: destroy it in its original App slot.
        self.client.deinit();
        self.config = replacement.config;
        self.client = replacement.client;
        self.client.config = &self.config.value;
        self.runtime.config = &self.config.value;
        self.executor.config = &self.config.value;
        self.runtime.model = self.client.model();
        self.recordSelection();
        self.allocator.destroy(replacement);
        cfg.release(&previous);
    }

    /// Interactive owner pins the immutable ID before the first submission.
    /// Headless callers retain lazy ID generation and need not call this.
    pub fn pinSessionID(self: *App, id: [32]u8) !void {
        if (self.runtime.busy.load(.acquire)) return error.Busy;
        try self.journal.pinSessionID(id);
        self.client.session_id = id;
    }

    /// Point the session preface at a new working directory. The startup tool
    /// root stays put. The next run appends a context message when the resolved
    /// cwd, shell, project root, or AGENTS text differs. A change before the
    /// first run rebuilds the fresh prefix instead of appending an update.
    pub fn setWorkingDirectory(self: *App, cwd: []const u8) !void {
        if (self.runtime.busy.load(.acquire)) return error.Busy;
        var opened = try fs.Root.open(self.allocator, self.root.io, cwd);
        defer opened.deinit();
        const path = try self.allocator.dupe(u8, opened.path);
        self.allocator.free(self.session_cwd);
        self.session_cwd = path;
    }

    fn loadSessionPolicy(ctx: *anyopaque, a: std.mem.Allocator) !session_context.Snapshot {
        const self: *App = @ptrCast(@alignCast(ctx));
        return session_context.load(a, self.root.io, self.home_path, self.session_cwd, self.shell_name);
    }

    /// 只在首次提交前设置；关闭不会读取或删除已有日志。
    pub fn setLogging(self: *App, enabled: bool) void {
        std.debug.assert(!self.runtime.busy.load(.acquire));
        self.journal.setEnabled(enabled);
    }

    /// Owner-only fixed-size publication; no allocation or disk wait after
    /// successful selection publication, and no borrowed old config bytes.
    pub fn recordSelection(self: *App) void {
        self.journal.protocol = self.config.value.model.protocol;
        self.journal.setSelection(@import("selection.zig").capture(self.config.value));
    }

    /// 按创建的逆序释放资源，最后销毁自身。
    pub fn deinit(self: *App) void {
        const a = self.allocator;
        self.runtime.deinit();
        self.journal.deinit();
        self.client.deinit();
        self.environment.deinit();
        self.root.deinit();
        a.free(self.session_cwd);
        a.free(self.shell_name);
        a.free(self.home_path);
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
