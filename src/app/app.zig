//! Owns the fixed process configuration and project resources. No terminal I/O.

const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const tools = @import("../tools/tools.zig");
const http = @import("../llm/http.zig");
const r = @import("../core/runtime.zig");
const Journal = @import("journal.zig").Journal;
const reasoning_defaults = @import("reasoning_defaults.zig");
const metadata = @import("model_metadata.zig");
const session_context = @import("../core/session_context.zig");
const model_resolver = @import("model_resolver.zig");
const DecisionClient = @import("decision_client.zig").Client;

fn rememberConfiguredKeys(journal: *Journal, config: cfg.Config, environ: *const std.process.Environ.Map) !void {
    if (config.registry) |registry| for (registry.providers) |provider| {
        if (provider.connection.api_key) |key| try journal.rememberKey(key);
        if (provider.connection.api_key_env.len != 0) {
            if (environ.get(provider.connection.api_key_env)) |key| try journal.rememberKey(key);
        }
    };
}

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
    /// Optional, independently owned auxiliary route. Never archived or inherited
    /// from a restored selection; initialized lazily without startup requests.
    decision_client: ?*DecisionClient = null,

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
        var parsed = cfg.load(a, io, path) catch |err| switch (err) {
            // Use the same new-schema initializer as interactive startup. A
            // truncated nonempty document is rechecked, never overwritten.
            error.FileNotFound, error.UnexpectedEndOfInput => blk: {
                var store = try @import("auth_store.zig").Store.open(a, io, home);
                defer store.deinit();
                break :blk try store.loadOrInitialize();
            },
            else => return err,
        };
        // Derived defaults are not embedded in config.json. Headless entry can
        // reuse a compatible cached profile without creating/fetching metadata.
        // Price thresholds are always derived, even with explicit reasoning/output.
        {
            var cache: metadata.Cache = .{};
            var store: ?@import("auth_store.zig").Store = @import("auth_store.zig").Store.openExisting(a, io, home) catch null;
            if (store) |*value| {
                defer value.deinit();
                cache = metadata.load(&value.root) catch metadata.Cache{};
            }
            model_resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &cache) catch |err| {
                cfg.release(&parsed);
                return err;
            };
        }
        // Only anchor the project here. Empty sessions take model/thinking from
        // global configuration; project settings are neither read nor created.
        var root = fs.Root.open(a, io, project) catch |err| {
            cfg.release(&parsed);
            return err;
        };
        defer root.deinit();
        _ = reasoning_defaults.applyConfigured(&parsed.value);
        return initConfiguredAnchored(a, io, environ, &root, host, trusted, parsed);
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
        if (owned.value.selection_pending) return error.DefaultModelUnavailable;
        try cfg.validate(owned.value);
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
        try rememberConfiguredKeys(&self.journal, self.config.value, environ);
        self.journal.protocol = self.config.value.model.protocol;
        var secret_names: [17][]const u8 = undefined;
        secret_names[0] = self.config.value.provider.api_key_env;
        var secret_count: usize = 1;
        if (self.config.value.registry) |registry| for (registry.providers) |provider| {
            secret_names[secret_count] = provider.connection.api_key_env;
            secret_count += 1;
        };
        self.environment = try tools.commandEnvironmentMany(a, environ, secret_names[0..secret_count]);
        errdefer self.environment.deinit();
        self.executor = .{ .root = &self.root, .memory = &self.memory, .config = &self.config.value, .environment = &self.environment, .auth_path = self.auth_path };
        self.client = try http.Client.initWithEnv(a, io, &self.config.value, key, environ);
        errdefer self.client.deinit();
        self.decision_client = try DecisionClient.create(a, io, self.config.value, environ);
        errdefer if (self.decision_client) |decision| decision.deinit();

        const snapshot = try self.memory.snapshot(a);
        defer a.free(snapshot);
        self.runtime = try r.Runtime.init(a, io, &self.config.value, self.client.model(), self.executor.executor(), host, snapshot, trusted);
        self.runtime.decision_service = if (self.decision_client) |decision| decision.service() else null;
        self.runtime.session_loader = .{ .context = self, .load_fn = loadSessionPolicy };
        self.runtime.observer = self.journal.observer();
        self.recordSelection();
        return self;
    }

    pub const SettingsReplacement = struct {
        config: ?std.json.Parsed(cfg.Config) = null,
        replace_decision: bool,
        changes_tools: bool,
        decision: ?*DecisionClient = null,
        prefix: ?r.Runtime.ToolPrefix = null,

        pub fn deinit(self: *SettingsReplacement) void {
            if (self.decision) |client| client.deinit();
            if (self.prefix) |*prefix| prefix.deinit();
            if (self.config) |*config| cfg.release(config);
        }
    };

    /// Prepare all fallible work before writing global settings. No requests,
    /// primary reconnect or canonical mutations occur here.
    pub fn prepareSettings(self: *App, declaration: cfg.Config, environ: *const std.process.Environ.Map) !SettingsReplacement {
        return self.prepareSettingsRefresh(declaration, environ, false);
    }

    pub fn prepareSettingsRefresh(self: *App, declaration: cfg.Config, environ: *const std.process.Environ.Map, force_decision_refresh: bool) !SettingsReplacement {
        if (self.runtime.busy.load(.acquire)) return error.Busy;
        if (self.runtime.poisoned) return error.UnsafeToContinue;
        if (self.decision_client) |client| {
            const service = client.service();
            if (service.check_fn) |check| try check(service.context);
        }
        const decision_enabled = declaration.decisionActive();
        // Low-price-only edits preserve the auxiliary lifecycle. Explicit
        // reselect forces a fresh independently owned global credential source.
        var before: std.Io.Writer.Allocating = .init(self.allocator);
        defer {
            std.crypto.secureZero(u8, before.written());
            before.deinit();
        }
        var after: std.Io.Writer.Allocating = .init(self.allocator);
        defer {
            std.crypto.secureZero(u8, after.written());
            after.deinit();
        }
        try std.json.Stringify.value(self.config.value.decision, .{}, &before.writer);
        try std.json.Stringify.value(declaration.decision, .{}, &after.writer);
        var result: SettingsReplacement = .{
            .replace_decision = force_decision_refresh or !std.mem.eql(u8, before.written(), after.written()),
            .changes_tools = self.config.value.decisionActive() != decision_enabled,
        };
        errdefer result.deinit();
        result.config = try @import("decision_selection.zig").activeClone(self.allocator, self.config.value, declaration);
        if (result.replace_decision) {
            // Login may have replaced the global declaration since this chat's
            // frozen config was installed. Own the latest auxiliary credentials
            // without rebinding the primary config/client. Redaction may only
            // expand on a failed prepare/save; never publish an unredacted key.
            try rememberConfiguredKeys(&self.journal, declaration, environ);
            result.decision = try DecisionClient.create(self.allocator, self.root.io, declaration, environ);
        }
        if (result.changes_tools and self.runtime.selector.effective() == .anthropic)
            result.prefix = try self.runtime.prepareToolPrefix();
        return result;
    }

    /// Called only after settings save. Owned, idle publication cannot fail.
    pub fn installSettings(self: *App, replacement: *SettingsReplacement) void {
        std.debug.assert(!self.runtime.busy.load(.acquire));
        var previous_config = self.config;
        self.config = replacement.config.?;
        replacement.config = null;
        // Keep the used pool/authorization/proxy storage in its original slot.
        self.client.config = &self.config.value;
        self.runtime.config = &self.config.value;
        self.executor.config = &self.config.value;
        defer cfg.release(&previous_config);
        if (replacement.prefix) |*prefix| {
            self.runtime.installToolPrefix(prefix);
            replacement.prefix = null;
        }
        if (replacement.replace_decision) {
            const previous = self.decision_client;
            self.decision_client = replacement.decision;
            replacement.decision = null;
            self.runtime.decision_service = if (self.decision_client) |client| client.service() else null;
            if (previous) |client| client.deinit();
        }
        self.runtime.executor = self.executor.executor();
        if (replacement.changes_tools) self.runtime.last_context_tokens = null;
    }

    /// Heap-placed until publication: the unused client borrows this config.
    /// No requests may use it before installConnection rebinds App's pointers.
    pub const ConnectionReplacement = struct {
        owner: *App,
        config: std.json.Parsed(cfg.Config),
        client: http.Client,
        decision_client: ?*DecisionClient = null,
        plan: r.Runtime.SelectionPlan,

        pub fn deinit(self: *ConnectionReplacement) void {
            const a = self.owner.allocator;
            self.client.deinit();
            if (self.decision_client) |decision| decision.deinit();
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
        try rememberConfiguredKeys(&self.journal, owned.value, environ);
        const replacement = try self.allocator.create(ConnectionReplacement);
        errdefer self.allocator.destroy(replacement);
        replacement.owner = self;
        replacement.config = owned;
        replacement.plan = plan;
        replacement.client = try http.Client.initWithEnv(self.allocator, self.root.io, &replacement.config.value, key, environ);
        errdefer replacement.client.deinit();
        replacement.decision_client = try DecisionClient.create(self.allocator, self.root.io, replacement.config.value, environ);
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
        const previous_decision = self.decision_client;
        self.decision_client = replacement.decision_client;
        self.runtime.decision_service = if (self.decision_client) |decision| decision.service() else null;
        if (previous_decision) |decision| decision.deinit();
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
        if (self.decision_client) |decision| decision.deinit();
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

test "headless missing and blank configuration use the same new schema without requests" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |blank| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
        var store = try @import("auth_store.zig").Store.open(a, io, home);
        defer store.deinit();
        if (blank) try store.root.writeMode(cfg.file_name, " \t\n", false, 0o600);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        try std.testing.expectError(error.ApiKeyNotFound, App.init(a, io, &env, home, .{}, false));
        var created = try store.loadExisting();
        defer cfg.release(&created);
        try std.testing.expect(created.value.registry != null);
        try std.testing.expectEqualStrings("deepseek/deepseek-flash", created.value.registry.?.default);
        try std.testing.expect(created.value.registry.?.providers[0].connection.api_key == null);
        try std.testing.expectError(error.FileNotFound, store.root.read(a, "settings.json", 0, 1024));
    }
}

test "headless global defaults ignore legacy settings and never create project settings" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { json: []const u8, effort: ?[]const u8 }{
        .{ .json =
        \\{"llm":{"default":"fixture/fake","reasoning_effort":"high","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat","reasoning_effort":"off","reasoning":{"map":{"off":"none","medium":"medium","high":"high"}}}}}}},"limits":{"low_price_input":false}}
        , .effort = "high" },
        .{ .json =
        \\{"llm":{"default":"fixture/fake","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat","reasoning_effort":"off","reasoning":{"map":{"off":"none","medium":"medium","high":"high"}}}}}}},"limits":{"low_price_input":false}}
        , .effort = "off" },
        .{ .json =
        \\{"llm":{"default":"fixture/fake","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat","reasoning":{"map":{"off":"none","medium":"medium","high":"high"}}}}}}},"limits":{"low_price_input":false}}
        , .effort = "medium" },
        .{ .json =
        \\{"llm":{"default":"fixture/fake","reasoning_effort":"high","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat","reasoning_effort":"custom"}}}}},"limits":{"low_price_input":false}}
        , .effort = null },
    };
    // No Runtime.run: initialization uses owned config/cache fixtures only and
    // must not contact even the deliberately unresolvable model endpoint.
    for (cases) |case| for ([_]?[]const u8{ null, "{\"version\":1,\"reasoning_effort\":\"low\"}\n", "{broken settings" }) |legacy| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
        var store = try @import("auth_store.zig").Store.open(a, io, home);
        defer store.deinit();
        try store.root.writeMode(cfg.file_name, case.json, false, 0o600);
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
        const project = try std.fs.path.join(a, &.{ home, "project" });
        defer a.free(project);
        var root = try fs.Root.open(a, io, project);
        defer root.deinit();
        if (legacy) |content| {
            try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(root.dir.handle, ".thin", 0o700));
            try root.write(".thin/settings.json", content, false);
        }
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        const app = try App.init(a, io, &env, project, .{}, false);
        defer app.deinit();
        try std.testing.expectEqualStrings("fake", app.config.value.model.name);
        try std.testing.expectEqualStrings("fixture/fake", app.config.value.registry.?.default);
        if (case.effort) |effort| {
            try std.testing.expectEqualStrings(effort, app.config.value.model.reasoning_effort.?);
        } else try std.testing.expect(app.config.value.model.reasoning_effort == null);
        if (legacy) |content| {
            const unchanged = try root.read(a, ".thin/settings.json", 0, 1024);
            defer a.free(unchanged.data);
            try std.testing.expectEqualStrings(content, unchanged.data);
        } else try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
        const unchanged_config = try store.root.read(a, cfg.file_name, 0, 8192);
        defer a.free(unchanged_config.data);
        try std.testing.expectEqualStrings(case.json, unchanged_config.data);

        // App owns a duplicated dirfd after init's local Root has closed. A
        // replacement pathname must never redirect its file operations.
        try std.testing.expectEqual(@as(c_int, 0), std.c.renameat(tmp.dir.handle, "project", tmp.dir.handle, "retired"));
        try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
        try app.root.write("anchored.txt", "original inode", false);
        const anchored = try root.read(a, "anchored.txt", 0, 100);
        defer a.free(anchored.data);
        try std.testing.expectEqualStrings("original inode", anchored.data);
        var replacement = try fs.Root.open(a, io, project);
        defer replacement.deinit();
        try std.testing.expectError(error.FileNotFound, replacement.read(a, "anchored.txt", 0, 100));
        try std.testing.expectError(error.FileNotFound, fs.openDirectory(replacement.dir.handle, ".thin"));
        try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("project", tmp.dir.handle, "project-alias"));
        const alias = try std.fs.path.join(a, &.{ home, "project-alias" });
        defer a.free(alias);
        // Linux O_DIRECTORY | O_NOFOLLOW rejects the symlink as ENOTDIR.
        try std.testing.expectError(error.NotDir, App.init(a, io, &env, alias, .{}, false));
    };
}

// 配置加载可经由符号链接，但文件工具必须保护最终实际文件，而非 HOME 的词法别名。
test {
    _ = @import("llm_app_test.zig");
}

test "App protects actual configuration behind HOME and file symlinks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fake =
        \\{"llm":{"default":"fixture/fake","providers":{"fixture":{"base_url":"http://unused.invalid","api_key":"fake-review-key","models":{"fake":{"context_tokens":32768,"protocol":"chat"}}}}}}
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
        // Retired global settings are not a second configuration source.
        try home_dir.writeFile(io, .{ .sub_path = ".thin/settings.json", .data = "{broken legacy preferences" });
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
            try std.testing.expect(app.config.value.limits.low_price_input and !app.config.value.decisionActive());
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

test "App unavailable decision key never blocks startup and chat replacement keeps independent reference" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root.path);
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"context_tokens":32768,"protocol":"chat"},"alternate":{"context_tokens":32768,"protocol":"chat"}}},"judge":{"base_url":"http://judge.invalid/v1","api_key_env":"MISSING_JUDGE_KEY","models":{"mini":{"context_tokens":16384,"protocol":"responses"}}}}},"decision":{"model":"judge/mini"}}
    );
    model_resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &.{}) catch |err| {
        cfg.release(&parsed);
        return err;
    };
    const app = try App.initConfiguredAnchoredAuth(a, io, &env, &root, "/unused/private/config.json", .{}, false, parsed);
    defer app.deinit();
    try std.testing.expect(app.decision_client != null and app.runtime.decision_service != null);
    try std.testing.expect(app.decision_client.?.resolved == null and app.decision_client.?.calls == 0);
    const previous = app.decision_client.?;
    var candidate = try cfg.clone(a, app.config.value);
    candidate.value.model.name = "alternate";
    const replacement = try app.prepareConnection(candidate, &env);
    app.installConnection(replacement);
    try std.testing.expectEqualStrings("alternate", app.config.value.model.name);
    try std.testing.expect(app.decision_client.? != previous);
    try std.testing.expectEqualStrings("judge/mini", app.decision_client.?.source.value.decision.?.model);
    try std.testing.expect(app.runtime.decision_service.?.context == @as(*anyopaque, @ptrCast(app.decision_client.?)));
    const checkpoint = try app.runtime.checkpoint();
    try std.testing.expect(!@hasField(@TypeOf(checkpoint), "decision"));
    try std.testing.expect(!@hasField(@TypeOf(checkpoint), "decision_service"));
}
