//! 交互会话的应用层所有者：允许先显示 TUI，再通过本地授权配置创建 App。
//! TUI 只看 Connection 回调，不持有配置文件或凭证存储逻辑。

const std = @import("std");
const cfg = @import("../core/config.zig");
const r = @import("../core/runtime.zig");
const App = @import("app.zig").App;
const Store = @import("auth_store.zig").Store;
const tui = @import("../ui/tui.zig");
const presentation = @import("../presentation.zig");
const ids = @import("session_id.zig");
const Settings = @import("settings_store.zig").Store;
const thinking = @import("../core/thinking.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    project: []const u8,
    host: r.Host,
    trusted: bool,
    logging: bool = true,
    /// Generated once before activation/logging; never read from the writer.
    session_id: ids.Id,
    store: Store,
    /// Owned by value, so pending-to-/auth activation preserves the same fd.
    settings: Settings,
    preferred_effort: ?presentation.ReasoningEffort = null,
    settings_error: ?anyerror = null,
    settings_notice: ?[]const u8 = null,
    pending: ?std.json.Parsed(cfg.Config) = null,
    app: ?*App = null,
    /// Separate from the parsed arena; selected config may borrow this name.
    selected_name: ?[]u8 = null,
    /// Original disk options, borrowed only while pending remains alive.
    pending_base_model: ?cfg.Model = null,
    /// Computed before publication; callbacks never read worker-owned history.
    initial_context: ?r.ContextSnapshot = null,

    /// 只做本地初始化；缺少凭证时保持 pending，不发起试探请求。
    pub fn init(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host, trusted: bool) !Session {
        const home = environ.get("HOME") orelse return error.MissingHome;
        const id = try ids.generate(io);
        var settings = try Settings.open(a, io, project);
        const auth_store = Store.open(a, io, home) catch |err| {
            settings.deinit();
            return err;
        };
        var self: Session = .{
            .allocator = a,
            .io = io,
            .environ = environ,
            .project = project,
            .host = host,
            .trusted = trusted,
            .session_id = id,
            .store = auth_store,
            .settings = settings,
        };
        errdefer self.deinit();
        self.pending = try self.store.loadOrInitialize();
        // Capture GLOBAL defaults before any project overlay or capability
        // clamp. /auth must never persist a repository's transient choice.
        self.pending_base_model = self.pending.?.value.model;
        const config = &self.pending.?.value;
        const capabilities = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning);
        self.preferred_effort = self.settings.loadOrInitialize(capabilities.defaultEffort(config.model.reasoning_effort)) catch |err| blk: {
            self.settings_error = err;
            break :blk null;
        };
        if (self.preferred_effort) |saved| {
            if (capabilities.known) {
                config.model.reasoning_effort = capabilities.effective(saved.name());
                if (presentation.ReasoningEffort.fromName(config.model.reasoning_effort) != saved)
                    self.settings_notice = "Saved thinking level adjusted for this model; preference unchanged";
            } else self.settings_notice = "Saved thinking level not applied: model capabilities unknown";
        } else config.model.reasoning_effort = capabilities.effective(config.model.reasoning_effort);

        const key = cfg.resolveApiKey(a, self.pending.?.value, environ) catch |err| {
            if (err == error.ApiKeyNotFound) return self;
            return err;
        };
        defer {
            std.crypto.secureZero(u8, key);
            a.free(key);
        }
        const parsed = self.pending.?;
        self.pending = null;
        self.pending_base_model = null;
        self.app = try self.prepareApp(parsed);
        try self.app.?.pinSessionID(self.session_id);
        self.initial_context = self.app.?.runtime.contextSnapshot();
        return self;
    }

    /// Consumes parsed on every path. Auth and project roots were opened at
    /// startup; this protection name must remain in their retained namespace.
    fn prepareApp(self: *Session, parsed: std.json.Parsed(cfg.Config)) !*App {
        const protected = std.fs.path.join(self.allocator, &.{ self.store.root.path, cfg.file_name }) catch |err| {
            var owned = parsed;
            cfg.release(&owned);
            return err;
        };
        defer self.allocator.free(protected);
        return App.initConfiguredAnchoredAuth(self.allocator, self.io, self.environ, &self.settings.root, protected, self.host, self.trusted, parsed);
    }

    /// 必须等 TUI 取消并 join worker 后再释放；Connection 不得比 Session 活得更久。
    pub fn deinit(self: *Session) void {
        if (self.app) |app| app.deinit();
        if (self.selected_name) |name| self.allocator.free(name);
        if (self.pending) |*pending| cfg.release(pending);
        self.store.deinit();
        self.settings.deinit();
        self.* = undefined;
    }

    /// main 在进入 TUI 前设置，也应用于之后 /auth 创建的候选 App。
    pub fn setLogging(self: *Session, enabled: bool) void {
        self.logging = enabled;
        if (self.app) |app| app.setLogging(enabled);
    }

    pub fn connection(self: *Session) tui.Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .select_model_fn = selectModel, .set_effort_fn = setEffort };
    }

    fn current(raw: *anyopaque) tui.Connection.State {
        const self: *Session = @ptrCast(@alignCast(raw));
        const config = if (self.app) |app| app.config.value else self.pending.?.value;
        return .{
            .runtime = if (self.app) |app| &app.runtime else null,
            .initial_context = self.initial_context orelse .{ .tokens = 0, .limit = @intCast(config.model.context_tokens) },
            .model = config.model.name,
            .session_id = self.session_id,
            .models = config.models,
            .context_limit = config.model.context_tokens,
            .reasoning_effort = presentation.ReasoningEffort.fromName(config.model.reasoning_effort),
            .effort_levels = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning).levels,
            .settings_error = self.settings_error,
            .settings_notice = self.settings_notice,
            .base_url = config.provider.base_url,
            .tools_trusted = self.trusted,
            .logging_enabled = self.logging,
            .log_error = if (self.app) |app| app.journal.failure() else null,
        };
    }

    fn mutableConfig(self: *Session) *cfg.Config {
        return if (self.app) |app| &app.config.value else &self.pending.?.value;
    }

    fn guardSelection(self: *Session) !void {
        // TUI additionally owns the future-joined requirement.
        if (self.app) |app| {
            if (app.runtime.busy.load(.acquire)) return error.Busy;
            if (app.runtime.poisoned) return error.UnsafeToContinue;
        }
    }

    fn selectModel(raw: *anyopaque, name: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        const config = self.mutableConfig();
        // The current picker row represents the ACTUAL transient options, not
        // a same-named startup profile. Re-selecting it must not undo Shift+Tab.
        if (std.mem.eql(u8, name, config.model.name)) {
            // Owner-only idle path: preserve the latest actual value even when
            // the picker republishes a same-name no-op connection snapshot.
            if (self.app) |app| self.initial_context = app.runtime.contextSnapshot();
            return;
        }
        var candidate = config.*;
        // Unknown names inherit explicit current options, never guessed defaults.
        candidate.model.name = name;
        for (config.models) |profile| {
            if (std.mem.eql(u8, name, profile.name)) {
                candidate.model = profile;
                break;
            }
        }
        const capabilities = thinking.resolve(candidate.provider.base_url, candidate.model.name, candidate.model.reasoning);
        var preference_notice: ?[]const u8 = null;
        if (self.preferred_effort) |saved| {
            if (capabilities.known) {
                candidate.model.reasoning_effort = capabilities.effective(saved.name());
                if (presentation.ReasoningEffort.fromName(candidate.model.reasoning_effort) != saved)
                    preference_notice = "Saved thinking level adjusted for this model; preference unchanged";
            } else preference_notice = "Saved thinking level not applied: model capabilities unknown";
        }
        candidate.model.reasoning_effort = capabilities.effective(candidate.model.reasoning_effort);
        try cfg.validate(candidate);
        const owned_name = try self.allocator.dupe(u8, candidate.model.name);
        errdefer self.allocator.free(owned_name);
        candidate.model.name = owned_name;
        if (self.app) |app| try app.runtime.prepareSelection(candidate.model);
        // No fallible operation follows preparation.
        if (self.pending != null and self.pending_base_model == null) self.pending_base_model = config.model;
        const previous = self.selected_name;
        config.model = candidate.model;
        self.selected_name = owned_name;
        self.settings_notice = preference_notice;
        if (previous) |old| self.allocator.free(old);
        if (self.app) |app| self.initial_context = app.runtime.contextSnapshot();
    }

    fn setEffort(raw: *anyopaque, effort: presentation.ReasoningEffort) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        const canonical = effort.canonical();
        const name = canonical.name() orelse return error.InvalidReasoningEffort;
        const config = self.mutableConfig();
        const capabilities = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning);
        if (!capabilities.levels.contains(canonical)) return error.UnsupportedReasoningEffort;
        var candidate = config.*;
        candidate.model.reasoning_effort = name;
        try cfg.validate(candidate);
        // No effective option, baseline, replay or estimator mutation until
        // the bounded atomic save has succeeded. No fallible work follows it.
        self.settings.save(canonical) catch |err| {
            self.settings_error = err;
            return err;
        };
        if (self.pending != null and self.pending_base_model == null) self.pending_base_model = config.model;
        config.model = candidate.model;
        self.preferred_effort = canonical;
        self.settings_error = null;
        self.settings_notice = null;
    }

    fn configure(raw: *anyopaque, key: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (self.app != null) return error.AlreadyConfigured;
        var next = self.pending.?.value;
        next.provider.api_key_env = "";
        next.provider.api_key = key;
        try cfg.validate(next);

        // 候选配置拥有独立字符串；借用的按键缓冲区在回调返回后会被 TUI 擦除。
        // 固定容量避免增长时释放含密钥的旧缓冲区；退出时擦除整块分配。
        const encoded = try self.allocator.alloc(u8, cfg.max_config_bytes);
        defer {
            std.crypto.secureZero(u8, encoded);
            self.allocator.free(encoded);
        }
        var writer = std.Io.Writer.fixed(encoded);
        std.json.Stringify.value(next, .{}, &writer) catch return error.ConfigTooLarge;
        const owned = try cfg.parse(self.allocator, encoded[0..writer.end]);
        const candidate = try self.prepareApp(owned);
        errdefer candidate.deinit();
        try candidate.pinSessionID(self.session_id);
        candidate.setLogging(self.logging);

        // 先完成本地对象构建和落盘，再发布 ready。保存失败不激活半配置会话。
        var disk_config = candidate.config.value;
        if (self.pending_base_model) |baseline| disk_config.model = baseline;
        try self.store.save(disk_config);
        // Candidate owns its strings independently; drop baseline borrows before
        // releasing pending, and release the separate override after publication.
        self.pending_base_model = null;
        if (self.pending) |*pending| cfg.release(pending);
        self.pending = null;
        if (self.selected_name) |name| self.allocator.free(name);
        self.selected_name = null;
        self.initial_context = candidate.runtime.contextSnapshot();
        self.app = candidate;
    }
};

fn testReasoning() thinking.Declaration {
    return .{ .map = .{ .off = "none", .minimal = "minimal", .low = "low", .medium = "medium", .high = "high", .xhigh = "xhigh", .max = "max" } };
}

// 全部使用临时 HOME/项目与假密钥；仅构造 HTTP 客户端，绝不调用它。
test "pending session activates locally without a request and protects auth from tools" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buffer);
    const home = path_buffer[0..path_len];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.init(a, io, &env, home, .{}, true);
    defer session.deinit();
    session.pending.?.value.model.reasoning_effort = "high";
    // This direct test-fixture mutation represents the global startup value.
    session.pending_base_model = session.pending.?.value.model;
    const connection = session.connection();
    const initial_id = connection.current().session_id.?;
    try std.testing.expect(ids.valid(initial_id));
    try std.testing.expectEqual(presentation.ReasoningEffort.high, connection.current().reasoning_effort);
    try std.testing.expect(connection.current().runtime == null);
    try std.testing.expect(connection.current().initial_context.?.known);
    try std.testing.expectEqual(@as(u64, 0), connection.current().initial_context.?.tokens);
    try std.testing.expect(connection.current().tools_trusted);
    try connection.configure("fake-inline-session-key");
    try std.testing.expectEqualSlices(u8, &initial_id, &connection.current().session_id.?);
    try std.testing.expectEqualSlices(u8, &initial_id, &session.app.?.journal.store.pinned_id.?);
    try std.testing.expect(connection.current().runtime != null);
    try std.testing.expectEqual(presentation.ReasoningEffort.high, connection.current().reasoning_effort);
    try std.testing.expectEqualDeep(session.app.?.runtime.contextSnapshot(), connection.current().initial_context.?);
    try std.testing.expectEqual(@as(u64, 0), connection.current().initial_context.?.tokens);
    try std.testing.expect(session.app.?.runtime.estimatedTokens() > 0);
    try std.testing.expect(connection.current().runtime.?.trusted);
    try std.testing.expect(connection.current().tools_trusted);
    try std.testing.expect(std.mem.find(u8, session.app.?.runtime.system, "fake-inline-session-key") == null);
    try std.testing.expectEqual(@as(usize, 0), session.app.?.runtime.messages().len);
    try std.testing.expectError(error.AlreadyConfigured, connection.configure("replacement"));

    // 重开会话可使用已保存的内联凭证；仍然不发送网络请求。
    var reopened = try Session.init(a, io, &env, home, .{}, true);
    defer reopened.deinit();
    try std.testing.expect(reopened.connection().current().runtime != null);
    try std.testing.expectEqual(presentation.ReasoningEffort.high, reopened.connection().current().reasoning_effort);
    try std.testing.expect(reopened.connection().current().runtime.?.trusted);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const call: @import("../core/protocol.zig").ToolCall = .{
        .id = "read-auth",
        .name = "read_file",
        .arguments = "{\"path\":\".thin/config.json\"}",
    };
    const executor = session.app.?.executor.executor();
    try std.testing.expectError(error.ProtectedAuthFile, executor.prepare_fn(executor.context, arena.allocator(), call));
    const aliases = [_][]const u8{ ".thin//./config.json", session.app.?.auth_path };
    for (aliases) |path| {
        var cancel = @import("../core/protocol.zig").Cancellation{};
        try std.testing.expectError(error.ProtectedAuthFile, session.app.?.executor.execute(arena.allocator(), .{ .read_file = .{ .path = path } }, &cancel));
        try std.testing.expectError(error.ProtectedAuthFile, session.app.?.executor.execute(arena.allocator(), .{ .write_file = .{ .path = path, .content = "no", .overwrite = true } }, &cancel));
    }
}

test "transient pending selection owns names and auth saves original options" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    const home = buffer[0..n];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.init(a, io, &env, home, .{}, false);
    defer session.deinit();
    var original = session.pending_base_model.?;
    const original_name = try a.dupe(u8, original.name);
    defer a.free(original_name);
    original.name = original_name;
    const original_effort = if (original.reasoning_effort) |value| try a.dupe(u8, value) else null;
    defer if (original_effort) |value| a.free(value);
    original.reasoning_effort = original_effort;
    session.pending.?.value.models = &.{.{ .name = "configured", .context_tokens = 65536, .protocol = .chat, .reasoning_effort = "low", .reasoning = testReasoning() }};
    try Session.selectModel(&session, "configured");
    try std.testing.expectEqual(@as(u32, 65536), session.connection().current().context_limit);
    // First entry persisted a project default (deepseek-flash: medium -> high),
    // which now overrides the same-named profile's declared "low".
    try std.testing.expectEqual(presentation.ReasoningEffort.high, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(@as(usize, 1), session.connection().current().models.len);
    try Session.setEffort(&session, .medium);
    try Session.selectModel(&session, "configured");
    try std.testing.expectEqual(presentation.ReasoningEffort.medium, session.connection().current().reasoning_effort);
    try std.testing.expectError(error.InvalidReasoningEffort, Session.setEffort(&session, .unspecified));
    try std.testing.expectError(error.InvalidReasoningEffort, Session.setEffort(&session, .unknown));
    var caller_name = [_]u8{ 't', 'e', 'm', 'p' };
    try Session.selectModel(&session, &caller_name);
    @memset(&caller_name, 0);
    try std.testing.expectEqualStrings("temp", session.connection().current().model);
    try Session.selectModel(&session, "transient-again");
    try Session.setEffort(&session, .xhigh);
    try std.testing.expectEqual(presentation.ReasoningEffort.xhigh, session.connection().current().reasoning_effort);
    // Failure before preparation/publication must keep both the override and baseline.
    var empty: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&empty);
    session.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, Session.selectModel(&session, "not-published"));
    session.allocator = a;
    try std.testing.expectEqualStrings("transient-again", session.connection().current().model);
    try Session.configure(&session, "fake-transient-key");
    const app = session.app.?;
    try std.testing.expectEqualStrings("transient-again", app.config.value.model.name);
    try std.testing.expectEqualStrings("xhigh", app.config.value.model.reasoning_effort.?);
    try std.testing.expect(app.runtime.config == &app.config.value);
    try std.testing.expect(app.client.config == &app.config.value);
    try std.testing.expect(session.selected_name == null);
    try std.testing.expect(session.pending_base_model == null);
    var disk = try session.store.loadOrInitialize();
    defer cfg.release(&disk);
    try std.testing.expectEqualStrings(original.name, disk.value.model.name);
    try std.testing.expectEqual(@as(usize, 1), disk.value.models.len);
    try std.testing.expectEqual(original.protocol, disk.value.model.protocol);
    try std.testing.expectEqual(original.context_tokens, disk.value.model.context_tokens);
    if (original.reasoning_effort) |effort| {
        try std.testing.expectEqualStrings(effort, disk.value.model.reasoning_effort.?);
    } else try std.testing.expect(disk.value.model.reasoning_effort == null);
    app.runtime.busy.store(true, .release);
    try std.testing.expectError(error.Busy, Session.selectModel(&session, "busy"));
    try std.testing.expectError(error.Busy, Session.setEffort(&session, .low));
    app.runtime.busy.store(false, .release);
    app.runtime.poisoned = true;
    try std.testing.expectError(error.UnsafeToContinue, Session.selectModel(&session, "poisoned"));
    try std.testing.expectError(error.UnsafeToContinue, Session.setEffort(&session, .low));
    app.runtime.poisoned = false;
    app.runtime.estimator.per_mille = 2300;
    const old_selector = app.runtime.selector;
    session.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, Session.selectModel(&session, "active-oom"));
    session.allocator = a;
    try std.testing.expectEqualStrings("transient-again", app.config.value.model.name);
    try std.testing.expectEqual(@as(u64, 2300), app.runtime.estimator.per_mille);
    try std.testing.expectEqualDeep(old_selector, app.runtime.selector);
    try Session.setEffort(&session, .medium);
    try std.testing.expectEqual(@as(u64, 2300), app.runtime.estimator.per_mille);
    var active_name = [_]u8{ 'l', 'i', 'v', 'e' };
    try Session.selectModel(&session, &active_name);
    @memset(&active_name, 0);
    try std.testing.expectEqualStrings("live", app.config.value.model.name);
    try std.testing.expectEqual(@as(usize, 0), app.runtime.messages().len);
    try Session.setEffort(&session, .none);
    try std.testing.expectEqualStrings("off", app.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(presentation.ReasoningEffort.off, (try session.settings.load()).?);
}

test "configuration conflict does not publish an app" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buffer);
    const home = path_buffer[0..path_len];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.init(a, io, &env, home, .{}, false);
    defer session.deinit();
    // 模拟用户在 TUI 输入期间从另一进程修改配置；不得被保存动作覆盖。
    session.pending.?.value.model.reasoning = testReasoning();
    try Session.selectModel(&session, "conflicting-transient");
    try Session.setEffort(&session, .high);
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/config.json", .data = "changed externally" });
    if (session.connection().configure("fake-key")) |_| {
        return error.ExpectedConflict;
    } else |_| {}
    try std.testing.expect(session.connection().current().runtime == null);
    try std.testing.expectEqualStrings("conflicting-transient", session.connection().current().model);
    try std.testing.expect(session.pending_base_model != null);
    const bytes = try tmp.dir.readFileAlloc(io, ".thin/config.json", a, .limited(1024));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("changed externally", bytes);
}
