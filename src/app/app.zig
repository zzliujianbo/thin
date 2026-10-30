//! Owns the fixed process configuration and project resources. No terminal I/O.

const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const tools = @import("../tools/tools.zig");
const http = @import("../llm/http.zig");
const codex_auth = @import("../core/codex_auth.zig");
const CodexManager = @import("codex_oauth.zig").Manager;
const r = @import("../core/runtime.zig");
const Journal = @import("journal.zig").Journal;
const reasoning_defaults = @import("reasoning_defaults.zig");
const metadata = @import("model_metadata.zig");
const session_context = @import("../core/session_context.zig");
const model_resolver = @import("model_resolver.zig");
const DecisionClient = @import("decision_client.zig").Client;
const image = @import("../core/image.zig");
const ImageClient = @import("image_client.zig").Client;
const image_setup = @import("image_setup.zig");
const knowledge = @import("../core/knowledge.zig");
const MemoryCoordinator = @import("memory_service.zig").Coordinator;
const subagent_service = @import("subagent_service.zig");
const SubagentService = subagent_service.SubagentService;
const background_service = @import("background_service.zig");
const BackgroundService = background_service.BackgroundService;

/// Idle replacement owners have never sent a request, and used owners have
/// already joined the worker. An unreapable child is a fail-stop condition,
/// never permission to discard its owner and continue with another client.
fn destroyImageClient(client: *ImageClient) void {
    client.deinit() catch @panic("Image cleanup failed; refusing to discard the owned child");
}

fn rememberConfiguredKeys(journal: *Journal, config: cfg.Config, environ: *const std.process.Environ.Map) !void {
    if (config.registry) |registry| for (registry.providers) |provider| {
        if (provider.connection.api_key) |key| try journal.rememberKey(key);
        if (provider.connection.codex_oauth) |credential| {
            try journal.rememberKey(credential.access_token);
            try journal.rememberKey(credential.refresh_token);
        }
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
    /// Stable source owner shared by Codex clients and their clones.
    codex_manager: ?*CodexManager = null,
    /// Optional, independently owned auxiliary route. Never archived or inherited
    /// from a restored selection; initialized lazily without startup requests.
    decision_client: ?*DecisionClient = null,
    image_client: ?*ImageClient = null,
    memory_coordinator: *MemoryCoordinator,
    /// Owns the parent-domain subagent quota and any retained image cleanup
    /// owner. Its service is rebound to Tools on idle settings replacement.
    subagent: SubagentService,
    /// Instance-owned background command registry. This is the only owner: it
    /// survives connection/settings replacement and every executor rebind only
    /// republishes its service value. Its deps are published once, after the
    /// anchored root and the filtered command environment exist.
    background: BackgroundService = .{},

    /// Agent 运行时，最后初始化，依赖前面所有字段。
    runtime: r.Runtime,

    /// Heap placement is intentional: Store, Tools, Client and Runtime refer to
    /// these fields, so returning a self-referential value would invalidate them.
    /// 按依赖顺序初始化各组件，并用 errdefer 保证任一步失败时已创建的部分被回滚。
    /// API key 来自配置指定的凭证源；临时副本使用后清零，客户端持有自己的副本。
    pub fn init(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host) !*App {
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
        return initConfiguredAnchored(a, io, environ, &root, host, parsed);
    }

    /// Duplicate an already anchored project; never re-open its replaceable
    /// pathname during activation. parsed is consumed on success AND failure.
    pub fn initConfiguredAnchored(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, root: *const fs.Root, host: r.Host, parsed: std.json.Parsed(cfg.Config)) !*App {
        return initConfiguredRoot(a, io, environ, root.path, root, null, host, parsed);
    }

    /// Delayed activation must retain the Auth Store's startup pathname in the
    /// SAME lexical namespace as root, not rediscover a replaced HOME path.
    pub fn initConfiguredAnchoredAuth(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, root: *const fs.Root, protected_auth: []const u8, host: r.Host, parsed: std.json.Parsed(cfg.Config)) !*App {
        return initConfiguredRoot(a, io, environ, root.path, root, protected_auth, host, parsed);
    }

    fn initConfiguredRoot(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, anchored: ?*const fs.Root, protected_auth: ?[]const u8, host: r.Host, parsed: std.json.Parsed(cfg.Config)) !*App {
        var owned = parsed;
        errdefer cfg.release(&owned);
        if (owned.value.selection_pending) return error.DefaultModelUnavailable;
        if (owned.value.model.protocol == .systemone) return error.SystemOneNotChatModel;
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

        self.codex_manager = null;
        errdefer if (self.codex_manager) |manager| manager.deinit();
        const key = if (isCodex(self.config.value)) blk: {
            if (self.config.value.provider.codex_oauth == null) return error.ApiKeyNotFound;
            break :blk try a.alloc(u8, 0);
        } else try cfg.resolveApiKey(a, self.config.value, environ);
        defer {
            std.crypto.secureZero(u8, key);
            a.free(key);
        }

        self.root = if (anchored) |root| try root.duplicate() else try fs.Root.open(a, io, project);
        errdefer self.root.deinit();
        try mem.migrateLayout(&self.root);
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
        // Publish the background owner exactly once, now that the anchored root
        // and the minimal command environment are stable App fields. Each start
        // freezes its own cwd dirfd/environment copy; a later connection or
        // settings install must never rebuild or rebind this registry.
        self.background = .{};
        errdefer self.background.deinit();
        self.background.deps = .{
            .allocator = a,
            .io = io,
            .root = &self.root,
            .environment = &self.environment,
        };
        self.executor = .{ .root = &self.root, .memory = &self.memory, .config = &self.config.value, .environment = &self.environment, .auth_path = self.auth_path, .background = self.background.service() };
        self.client = try self.initPrimaryClient(&self.config.value, key, environ);
        errdefer self.client.deinit();
        self.decision_client = try self.createDecisionClient(self.config.value, environ);
        errdefer if (self.decision_client) |decision| decision.deinit();
        self.image_client = try image_setup.create(a, io, self.config.value, environ);
        errdefer if (self.image_client) |client| destroyImageClient(client);
        self.executor.image = self.imageService();

        // The service borrows stable App field addresses. The parent Runtime is
        // assigned below, but its address is stable and no service callback can
        // run before the Runtime is fully initialized.
        self.subagent = .{};
        self.subagent.deps = .{
            .allocator = a,
            .config = &self.config.value,
            .http_client = &self.client,
            .decision = &self.decision_client,
            .image = &self.image_client,
            .root = &self.root,
            .environment = &self.environment,
            .auth_path = self.auth_path,
            .home_path = self.home_path,
            .shell_name = self.shell_name,
            .session_cwd = self.session_cwd,
            .runtime = &self.runtime,
        };
        // Subagent is a default capability: no settings gate, and the child
        // runtime itself is the only recursion boundary (subagent = null).
        self.executor.subagent = self.subagent.service();

        self.memory_coordinator = try self.createMemoryCoordinator(self.config.value, environ);
        errdefer self.memory_coordinator.deinit();
        self.memory_coordinator.bindDiagnostics(self.journal.diagnosticSink());
        if (self.decision_client) |decision| decision.diagnostics = self.journal.diagnosticSink();
        // Only small core is frozen into the initial prefix. Task-local memory
        // is read afresh through bounded hooks, never an ever-growing index.
        var snapshot_wiping: cfg.WipingAllocator = .{ .backing = a };
        var reader = self.memory;
        reader.wait_for_lock = false;
        const snapshot = reader.coreSnapshot(snapshot_wiping.allocator()) catch |err| blk: {
            if (err != error.Busy) return err;
            self.memory_coordinator.reportFailure(err);
            break :blk try snapshot_wiping.allocator().dupe(u8, "");
        };
        defer snapshot_wiping.allocator().free(snapshot);
        // Explicit/local legacy core is untrusted too. Never freeze a known
        // credential into the primary prefix before task retrieval can screen it.
        const safe_snapshot = if (self.journal.containsSecret(snapshot)) blk: {
            self.memory_coordinator.reportFailure(error.SensitiveMemoryMaterial);
            break :blk "";
        } else snapshot;
        self.runtime = try r.Runtime.init(a, io, &self.config.value, self.client.model(), self.executor.executor(), host, safe_snapshot);
        self.runtime.diagnostics = self.journal.diagnosticSink();
        self.runtime.decision_service = if (self.decision_client) |decision| decision.service() else null;
        self.runtime.session_loader = .{ .context = self, .load_fn = loadSessionPolicy };
        self.runtime.observer = self.journal.observer();
        self.runtime.memory_hooks = .{ .context = self, .retrieve_fn = retrieveMemory, .submit_fn = submitMemory, .check_fn = memorySafe };
        self.recordSelection();
        return self;
    }

    pub fn memoryNotice(self: *const App) ?[]const u8 {
        return self.memory_coordinator.notice();
    }

    pub fn memoryView(self: *const App) @import("../core/memory_status.zig").View {
        return self.memory_coordinator.view();
    }

    pub fn drainMemory(self: *App, cancel: *const @import("../core/protocol.zig").Cancellation) void {
        self.memory_coordinator.drain(cancel);
    }

    fn memorySafe(raw: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(raw));
        return !self.memory_coordinator.isPoisoned();
    }

    fn retrieveMemory(raw: *anyopaque, a: std.mem.Allocator, query: []const u8, max_bytes: usize) ![]const u8 {
        const self: *App = @ptrCast(@alignCast(raw));
        return self.memory_coordinator.retrieve(a, query, max_bytes) catch |err| {
            self.memory_coordinator.reportFailure(err);
            return err;
        };
    }

    fn submitMemory(raw: *anyopaque, capture: *const knowledge.Capture, protocol: @import("../core/protocol.zig").Protocol) void {
        const self: *App = @ptrCast(@alignCast(raw));
        if (!self.config.value.memory.auto) return;
        var wiping: cfg.WipingAllocator = .{ .backing = self.allocator };
        var arena = std.heap.ArenaAllocator.init(wiping.allocator());
        defer arena.deinit();
        var filtered: knowledge.Capture = .{ .allocator = arena.allocator(), .omitted_sources = capture.omitted_sources };
        for (capture.sources.items) |source| {
            if (self.journal.containsSecret(source.text)) {
                filtered.omitted_sources += 1;
                continue;
            }
            filtered.add(source.kind, source.text);
        }
        if (capture.incomplete) filtered.incomplete = true;
        _ = self.memory_coordinator.enqueueCopy(&filtered, protocol, self.journal.memoryDiagnosticSink()) catch |err| {
            self.memory_coordinator.reportFailure(err);
        };
    }

    fn imageService(self: *App) ?image.Service {
        if (!self.config.value.imageActive()) return null;
        return .{ .context = self, .inspect_fn = inspectImage, .check_fn = checkImage };
    }

    fn checkImage(raw: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(raw));
        const client = self.image_client orelse return error.ImageModelUnavailable;
        try client.service().checkReady();
    }

    fn inspectImage(raw: *anyopaque, a: std.mem.Allocator, input: image.Input, cancel: *const @import("../core/protocol.zig").Cancellation) !image.Output {
        const self: *App = @ptrCast(@alignCast(raw));
        const client = self.image_client orelse return error.ImageModelUnavailable;
        return client.service().inspect(a, input, cancel);
    }

    /// Owner-only lazy creation; callers must join all source borrowers before App deinit.
    pub fn ensureCodexSource(self: *App, environ: *const std.process.Environ.Map) !codex_auth.CredentialSource {
        if (self.codex_manager == null) {
            if (self.home_path.len == 0) return error.MissingHome;
            self.codex_manager = try CodexManager.init(self.allocator, self.root.io, self.home_path, environ);
        }
        return .{ .context = self, .acquire_fn = acquireCodexCredential };
    }

    fn acquireCodexCredential(ctx: ?*anyopaque, a: std.mem.Allocator, alias: []const u8, cancel: ?*const @import("../core/protocol.zig").Cancellation, timeout: u32) !codex_auth.RequestCredential {
        const self: *App = @ptrCast(@alignCast(ctx orelse return error.MissingCredentialSource));
        const manager = self.codex_manager orelse return error.MissingCredentialSource;
        var credential = try manager.source().acquire(a, alias, cancel, timeout);
        errdefer credential.deinit(a);
        try self.journal.rememberKey(credential.access_token);
        try self.journal.rememberKey(credential.redaction_refresh_token orelse return error.CodexSecretRegistrationUnavailable);
        return credential;
    }

    fn initPrimaryClient(self: *App, config: *const cfg.Config, key: []const u8, environ: *const std.process.Environ.Map) !http.Client {
        if (isCodex(config.*)) return http.Client.initCodexWithEnv(self.allocator, self.root.io, config, try self.ensureCodexSource(environ), environ);
        return http.Client.initWithEnv(self.allocator, self.root.io, config, key, environ);
    }

    fn createDecisionClient(self: *App, config: cfg.Config, environ: *const std.process.Environ.Map) !?*DecisionClient {
        var source: ?codex_auth.CredentialSource = null;
        if (config.decisionActive()) {
            const reference = try cfg.splitDefault(config.decision.?.model);
            if (config.registry) |registry| if (registry.find(reference.provider)) |provider| {
                if (isCodexProvider(provider.connection) and provider.connection.codex_oauth != null)
                    source = try self.ensureCodexSource(environ);
            };
        }
        return DecisionClient.createWithCodexSource(self.allocator, self.root.io, config, environ, source);
    }

    fn createMemoryCoordinator(self: *App, config: cfg.Config, environ: *const std.process.Environ.Map) !*MemoryCoordinator {
        var needs_source = config.memory.auto and isCodex(config);
        if (config.memory.auto and config.decisionActive()) {
            const reference = try cfg.splitDefault(config.decision.?.model);
            if (config.registry) |registry| if (registry.find(reference.provider)) |provider| {
                if (isCodexProvider(provider.connection)) needs_source = true;
            };
        }
        const source: ?codex_auth.CredentialSource = if (needs_source) try self.ensureCodexSource(environ) else null;
        return MemoryCoordinator.createWithCodexSource(self.allocator, self.root.io, &self.root, config, environ, source);
    }

    pub const SettingsRefresh = enum { none, decision, image_model, proxy_models };
    pub const SettingsReplacement = struct {
        config: ?std.json.Parsed(cfg.Config) = null,
        replace_decision: bool,
        replace_image: bool,
        replace_memory: bool = false,
        memory_coordinator: ?*MemoryCoordinator = null,
        changes_tools: bool,
        decision: ?*DecisionClient = null,
        image_client: ?*ImageClient = null,
        prefix: ?r.Runtime.ToolPrefix = null,

        pub fn deinit(self: *SettingsReplacement) void {
            if (self.memory_coordinator) |owner| owner.deinit();
            if (self.decision) |client| client.deinit();
            if (self.image_client) |client| destroyImageClient(client);
            if (self.prefix) |*prefix| prefix.deinit();
            if (self.config) |*config| cfg.release(config);
        }
    };

    /// Prepare all fallible work before writing global settings. No requests,
    /// primary reconnect or canonical mutations occur here.
    pub fn prepareSettings(self: *App, declaration: cfg.Config, environ: *const std.process.Environ.Map) !SettingsReplacement {
        return self.prepareSettingsRefresh(declaration, environ, .none);
    }

    pub fn prepareSettingsRefresh(self: *App, declaration: cfg.Config, environ: *const std.process.Environ.Map, refresh: SettingsRefresh) !SettingsReplacement {
        if (self.runtime.busy.load(.acquire)) return error.Busy;
        if (self.runtime.poisoned or self.memory_coordinator.isPoisoned()) return error.UnsafeToContinue;
        if (self.decision_client) |client| {
            const service = client.service();
            if (service.check_fn) |check| try check(service.context);
        }
        if (self.image_client) |client| if (client.isPoisoned()) return error.UnsafeToContinue;
        const decision_enabled = declaration.decisionActive();
        // Only decision edits, shared request deadlines or explicit reselect
        // replace the auxiliary owner. Primary transport/session stay frozen.
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
        const proxy_refresh = refresh == .proxy_models;
        var result: SettingsReplacement = .{
            // An explicit proxy edit replaces both auxiliary owners so their
            // next request uses the new allowlist. The primary client/config
            // stay frozen; result.config keeps the active proxy below.
            .replace_decision = refresh == .decision or proxy_refresh or
                self.config.value.limits.request_timeout_ms != declaration.limits.request_timeout_ms or
                !std.mem.eql(u8, before.written(), after.written()),
            .replace_image = refresh == .image_model or proxy_refresh or
                self.config.value.limits.request_timeout_ms != declaration.limits.request_timeout_ms or
                !optionalStringEqual(self.config.value.image.model, declaration.image.model),
            .changes_tools = self.config.value.decisionActive() != decision_enabled or
                self.config.value.imageActive() != declaration.imageActive(),
        };
        errdefer result.deinit();
        result.config = try @import("decision_selection.zig").activeClone(self.allocator, self.config.value, declaration);
        result.replace_memory = result.replace_decision or self.config.value.memory.auto != declaration.memory.auto or
            !std.meta.eql(self.config.value.limits, declaration.limits);
        if (result.replace_memory) {
            // The coordinator owns independent extractor/reviewer clients, so it
            // follows the latest auxiliary allowlist even when the active config
            // keep its frozen proxy. This local borrow is valid only for the call;
            // create() clones it, and later ordinary rebuilds reuse the same
            // declaration list instead of reverting to the frozen route.
            var memory_config = result.config.?.value;
            memory_config.proxy = declaration.proxy;
            result.memory_coordinator = try self.createMemoryCoordinator(memory_config, environ);
        }
        if (result.replace_decision) {
            // Login may have replaced the global declaration since this chat's
            // frozen config was installed. Own the latest auxiliary credentials
            // without rebinding the primary config/client. Redaction may only
            // expand on a failed prepare/save; never publish an unredacted key.
            try rememberConfiguredKeys(&self.journal, declaration, environ);
            result.decision = try self.createDecisionClient(declaration, environ);
        }
        if (result.replace_image) {
            try rememberConfiguredKeys(&self.journal, declaration, environ);
            result.image_client = try image_setup.create(self.allocator, self.root.io, declaration, environ);
            if (refresh == .image_model and declaration.imageActive() and result.image_client == null)
                return error.ImageModelUnavailable;
        }
        if (result.changes_tools and self.runtime.selector.effective() == .anthropic)
            result.prefix = try self.runtime.prepareToolPrefix();
        return result;
    }

    /// Called only after settings save; joins the replaced Memory owner.
    pub fn installSettings(self: *App, replacement: *SettingsReplacement) void {
        std.debug.assert(!self.runtime.busy.load(.acquire));
        if (replacement.replace_memory) self.memory_coordinator.cancelAndJoin();
        const memory_poisoned = self.memory_coordinator.isPoisoned();
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
            if (self.decision_client) |decision| decision.diagnostics = self.journal.diagnosticSink();
            replacement.decision = null;
            self.runtime.decision_service = if (self.decision_client) |client| client.service() else null;
            if (previous) |client| client.deinit();
        }
        if (replacement.replace_image) {
            if (self.image_client) |client| destroyImageClient(client);
            self.image_client = replacement.image_client;
            replacement.image_client = null;
        }
        if (replacement.replace_memory) {
            self.memory_coordinator.deinit();
            self.memory_coordinator = replacement.memory_coordinator.?;
            self.memory_coordinator.bindDiagnostics(self.journal.diagnosticSink());
            replacement.memory_coordinator = null;
        }
        self.executor.image = self.imageService();
        self.executor.subagent = self.subagent.service();
        // Rebinding republishes the same instance-owned registry; running jobs
        // keep their frozen cwd/environment and are never touched here.
        self.executor.background = self.background.service();
        self.runtime.executor = self.executor.executor();
        if (memory_poisoned) self.runtime.poisoned = true;
        // Schema edits affect future estimates, not the latest server-reported
        // primary usage (including fresh-session zero or genuinely unknown).
    }

    /// Heap-placed until publication: the unused client borrows this config.
    /// No requests may use it before installConnection rebinds App's pointers.
    pub const ConnectionReplacement = struct {
        owner: *App,
        config: std.json.Parsed(cfg.Config),
        client: http.Client,
        decision_client: ?*DecisionClient = null,
        image_client: ?*ImageClient = null,
        memory_coordinator: *MemoryCoordinator,
        plan: r.Runtime.SelectionPlan,

        pub fn deinit(self: *ConnectionReplacement) void {
            const a = self.owner.allocator;
            self.client.deinit();
            self.memory_coordinator.deinit();
            if (self.decision_client) |decision| decision.deinit();
            if (self.image_client) |client| destroyImageClient(client);
            cfg.release(&self.config);
            a.destroy(self);
        }
    };

    /// Consumes parsed on every path. The current App and canonical history are
    /// unchanged on failure; extending known-key redaction is fail-closed.
    pub fn prepareConnection(self: *App, parsed: std.json.Parsed(cfg.Config), environ: *const std.process.Environ.Map) !*ConnectionReplacement {
        var owned = parsed;
        errdefer cfg.release(&owned);
        if (self.runtime.poisoned or self.memory_coordinator.isPoisoned()) return error.UnsafeToContinue;
        if (owned.value.model.protocol == .systemone) return error.SystemOneNotChatModel;
        const plan = try self.runtime.planSelection(owned.value, true);
        if (!std.meta.eql(owned.value.limits, self.config.value.limits)) return error.ConnectionLimitsChanged;
        const key = if (isCodex(owned.value)) blk: {
            if (owned.value.provider.codex_oauth == null) return error.ApiKeyNotFound;
            break :blk try self.allocator.alloc(u8, 0);
        } else try cfg.resolveApiKey(self.allocator, owned.value, environ);
        defer {
            std.crypto.secureZero(u8, key);
            self.allocator.free(key);
        }
        if (key.len != 0) try self.journal.rememberKey(key);
        try rememberConfiguredKeys(&self.journal, owned.value, environ);
        const replacement = try self.allocator.create(ConnectionReplacement);
        errdefer self.allocator.destroy(replacement);
        replacement.owner = self;
        replacement.config = owned;
        replacement.plan = plan;
        replacement.client = try self.initPrimaryClient(&replacement.config.value, key, environ);
        errdefer replacement.client.deinit();
        replacement.decision_client = try self.createDecisionClient(replacement.config.value, environ);
        errdefer if (replacement.decision_client) |client| client.deinit();
        replacement.image_client = try image_setup.create(self.allocator, self.root.io, replacement.config.value, environ);
        errdefer if (replacement.image_client) |client| destroyImageClient(client);
        replacement.memory_coordinator = try self.createMemoryCoordinator(replacement.config.value, environ);
        return replacement;
    }

    /// Publish the saved connection after canceling and joining the old Memory owner.
    pub fn installConnection(self: *App, replacement: *ConnectionReplacement) void {
        std.debug.assert(replacement.owner == self);
        self.memory_coordinator.cancelAndJoin();
        const memory_poisoned = self.memory_coordinator.isPoisoned();
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
        self.memory_coordinator.deinit();
        self.memory_coordinator = replacement.memory_coordinator;
        self.memory_coordinator.bindDiagnostics(self.journal.diagnosticSink());
        const previous_decision = self.decision_client;
        self.decision_client = replacement.decision_client;
        if (self.decision_client) |decision| decision.diagnostics = self.journal.diagnosticSink();
        self.runtime.decision_service = if (self.decision_client) |decision| decision.service() else null;
        if (previous_decision) |decision| decision.deinit();
        if (self.image_client) |client| destroyImageClient(client);
        self.image_client = replacement.image_client;
        self.executor.image = self.imageService();
        self.executor.subagent = self.subagent.service();
        // A connection install rebinds the same background owner; existing
        // services keep their startup cwd/environment and cleanup policy.
        self.executor.background = self.background.service();
        self.runtime.executor = self.executor.executor();
        if (memory_poisoned) self.runtime.poisoned = true;
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
        // The subagent host borrows this slice; publish the replacement before
        // the next delegated loadPolicy could read the freed old bytes.
        self.subagent.deps.session_cwd = self.session_cwd;
    }

    fn loadSessionPolicy(ctx: *anyopaque, a: std.mem.Allocator) !session_context.Snapshot {
        const self: *App = @ptrCast(@alignCast(ctx));
        return session_context.load(a, self.root.io, self.home_path, self.session_cwd, self.shell_name);
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
        self.memory_coordinator.cancelAndJoin();
        self.subagent.deinit();
        self.runtime.deinit();
        // Foreground tasks and delegated children are joined above. Only then
        // notify every background service to cancel and join the whole set, so
        // no worker can borrow a root/environment that is about to be released.
        self.background.deinit();
        // Interactive exit/model replacement cancels immediately. Headless
        // success explicitly drains with signal handling before destruction.
        self.memory_coordinator.deinit();
        if (self.decision_client) |decision| decision.deinit();
        if (self.image_client) |client| destroyImageClient(client);
        self.journal.deinit();
        self.client.deinit();
        if (self.codex_manager) |manager| manager.deinit();
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

fn isCodexProvider(provider: cfg.Provider) bool {
    return provider.kind == .openai_codex and
        std.mem.eql(u8, provider.base_url, cfg.providers.Id.openai_codex.baseUrl());
}

fn isCodex(config: cfg.Config) bool {
    return isCodexProvider(config.provider);
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
    return b == null;
}

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
        try std.testing.expectError(error.ApiKeyNotFound, App.init(a, io, &env, home, .{}));
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
        , .effort = "off" },
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
        const app = try App.init(a, io, &env, project, .{});
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
        try std.testing.expectError(error.NotDir, App.init(a, io, &env, alias, .{}));
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
            const app = try App.init(a, io, &env, project, .{});
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
    const app = try App.initConfiguredAnchoredAuth(a, io, &env, &root, "/unused/private/config.json", .{}, parsed);
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
    const sink = app.journal.diagnosticSink();
    try std.testing.expect(app.runtime.diagnostics.context == sink.context);
    try std.testing.expect(app.decision_client.?.diagnostics.context == sink.context);
    try std.testing.expect(app.memory_coordinator.diagnostics.context == sink.context);
    if (app.memory_coordinator.extractor) |extractor| try std.testing.expect(extractor.diagnostics.context == sink.context);
    if (app.memory_coordinator.reviewer) |reviewer| try std.testing.expect(reviewer.diagnostics.context == sink.context);
    const checkpoint = try app.runtime.checkpoint();
    try std.testing.expect(!@hasField(@TypeOf(checkpoint), "decision"));
    try std.testing.expect(!@hasField(@TypeOf(checkpoint), "decision_service"));
}
