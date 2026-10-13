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
const catalog = @import("provider_catalog.zig");
const ProviderId = cfg.providers.Id;

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
    /// Independent global baseline: project effort and transient selections
    /// must never leak into a later credential save.
    global_config: ?std.json.Parsed(cfg.Config) = null,
    display_models: []cfg.Model = &.{},
    selected_alias: ?[]u8 = null,
    credential_revisions: [3]u64 = @splat(0),
    active_revision: u64 = 0,

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
        self.global_config = try cfg.clone(a, self.pending.?.value);
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

        self.display_models = try self.buildModels(config.*, self.global_config.?.value);
        self.selected_alias = try self.aliasFor(config.*);
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
        self.allocator.free(self.display_models);
        if (self.selected_alias) |alias| self.allocator.free(alias);
        if (self.global_config) |*global| cfg.release(global);
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
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .configure_provider_fn = configureProvider, .select_model_fn = selectModel, .set_effort_fn = setEffort };
    }

    fn current(raw: *anyopaque) tui.Connection.State {
        const self: *Session = @ptrCast(@alignCast(raw));
        const config = if (self.app) |app| app.config.value else self.pending.?.value;
        return .{
            .runtime = if (self.app) |app| &app.runtime else null,
            .initial_context = self.initial_context orelse .{ .tokens = 0, .limit = @intCast(config.model.context_tokens) },
            .model = config.model.name,
            .session_id = self.session_id,
            .models = self.display_models,
            .selection_name = self.selected_alias,
            .provider = config.provider.kind orelse ProviderId.fromUrl(config.provider.base_url),
            .configured_providers = self.configuredMask(self.global_config.?.value),
            .allow_custom_models = config.provider.kind == null,
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

    fn configuredMask(self: *const Session, global: cfg.Config) u8 {
        var mask: u8 = 0;
        for (ProviderId.all) |id| {
            const legacy = ProviderId.fromUrl(global.provider.base_url) == id and
                (global.provider.api_key != null or (global.provider.api_key_env.len != 0 and self.environ.get(global.provider.api_key_env) != null));
            if (global.credentials.get(id) != null or legacy) mask |= @as(u8, 1) << @intCast(@backingInt(id));
        }
        return mask;
    }

    fn buildModels(self: *Session, active: cfg.Config, global: cfg.Config) ![]cfg.Model {
        var models: std.ArrayList(cfg.Model) = .empty;
        errdefer models.deinit(self.allocator);
        // At most 64 explicit profiles plus seven built-in local presets.
        try models.appendSlice(self.allocator, active.models);
        const configured = self.configuredMask(global);
        for (catalog.entries) |entry| {
            if (configured & (@as(u8, 1) << @intCast(@backingInt(entry.provider))) == 0) continue;
            var duplicate = false;
            for (active.models) |profile| if (std.mem.eql(u8, profile.name, entry.selector)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue; // An explicit local profile wins a name collision.
            var model = entry.model;
            model.name = entry.selector;
            try models.append(self.allocator, model);
        }
        return models.toOwnedSlice(self.allocator);
    }

    fn aliasFor(self: *Session, config: cfg.Config) !?[]u8 {
        const id = config.provider.kind orelse return null;
        for (catalog.entries) |entry| {
            if (entry.provider == id and std.mem.eql(u8, entry.model.name, config.model.name))
                return try self.allocator.dupe(u8, entry.selector);
        }
        // Explicit configured models are not invented catalog selectors.
        return null;
    }

    fn applyPreference(self: *Session, config: *cfg.Config) ?[]const u8 {
        const capabilities = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning);
        if (self.preferred_effort) |saved| {
            if (!capabilities.known) return "Saved thinking level not applied: model capabilities unknown";
            config.model.reasoning_effort = capabilities.effective(saved.name());
            if (presentation.ReasoningEffort.fromName(config.model.reasoning_effort) != saved)
                return "Saved thinking level adjusted for this model; preference unchanged";
        } else config.model.reasoning_effort = capabilities.effective(config.model.reasoning_effort);
        return null;
    }

    fn keyFor(self: *Session, id: ProviderId) ![]u8 {
        const global = self.global_config.?.value;
        if (global.credentials.get(id)) |key| return self.allocator.dupe(u8, key);
        if (ProviderId.fromUrl(global.provider.base_url) == id) return cfg.resolveApiKey(self.allocator, global, self.environ);
        return error.ApiKeyNotFound;
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

    fn activateSavedCredential(self: *Session, model: cfg.Model, selector: []const u8) !bool {
        const app = self.app orelse return false;
        const id = ProviderId.fromUrl(app.config.value.provider.base_url) orelse return false;
        if (self.active_revision == self.credential_revisions[@intCast(@backingInt(id))]) return false;
        var next = model;
        // A retained conversation already established its wire protocol. Do not
        // probe a different protocol merely because its credential changed.
        if (next.protocol == .auto and app.runtime.history.items.len != 0) next.protocol = app.runtime.selector.effective();
        try self.selectProviderModel(.{ .provider = id, .selector = selector, .model = next });
        return true;
    }

    fn selectModel(raw: *anyopaque, name: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        const config = self.mutableConfig();
        var explicit_profile = false;
        for (config.models) |profile| if (std.mem.eql(u8, profile.name, name)) {
            explicit_profile = true;
            break;
        };
        if (!explicit_profile) {
            if (catalog.find(name)) |entry| return self.selectProviderModel(entry);
            if (std.mem.findScalar(u8, name, '/')) |slash| {
                if (ProviderId.fromSlug(name[0..slash]) != null) return error.UnsupportedProviderModel;
            }
            if (config.provider.kind) |id| {
                for (catalog.entries) |entry| {
                    if (entry.provider == id and std.mem.eql(u8, entry.model.name, name)) return self.selectProviderModel(entry);
                }
                if (!std.mem.eql(u8, name, config.model.name)) return error.UnsupportedProviderModel;
            }
        }
        // The current picker row represents the ACTUAL transient options, not
        // a same-named startup profile. Re-selecting it must not undo Shift+Tab.
        if (std.mem.eql(u8, name, config.model.name)) {
            if (try self.activateSavedCredential(config.model, name)) return;
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
        if (try self.activateSavedCredential(candidate.model, name)) return;
        const owned_name = try self.allocator.dupe(u8, candidate.model.name);
        errdefer self.allocator.free(owned_name);
        const alias = try self.aliasFor(candidate);
        errdefer if (alias) |value| self.allocator.free(value);
        candidate.model.name = owned_name;
        const models = try self.buildModels(candidate, self.global_config.?.value);
        errdefer self.allocator.free(models);
        if (self.app) |app| try app.runtime.prepareSelection(candidate.model);
        // No fallible operation follows preparation.
        if (self.pending != null and self.pending_base_model == null) self.pending_base_model = config.model;
        const previous = self.selected_name;
        config.model = candidate.model;
        self.selected_name = owned_name;
        if (self.selected_alias) |old| self.allocator.free(old);
        self.selected_alias = alias;
        self.allocator.free(self.display_models);
        self.display_models = models;
        self.settings_notice = preference_notice;
        if (previous) |old| self.allocator.free(old);
        if (self.app) |app| self.initial_context = app.runtime.contextSnapshot();
    }

    fn selectProviderModel(self: *Session, entry: catalog.Entry) !void {
        const previous = self.mutableConfig();
        const revision = self.credential_revisions[@intCast(@backingInt(entry.provider))];
        if (self.app != null and previous.provider.kind == entry.provider and
            std.mem.eql(u8, previous.model.name, entry.model.name) and self.active_revision == revision)
        {
            self.initial_context = self.app.?.runtime.contextSnapshot();
            return;
        }
        const key = try self.keyFor(entry.provider);
        defer {
            std.crypto.secureZero(u8, key);
            self.allocator.free(key);
        }
        var next = previous.*;
        const same_endpoint = ProviderId.fromUrl(previous.provider.base_url) == entry.provider;
        next.provider = if (same_endpoint) previous.provider else catalog.connection(entry.provider);
        next.provider.kind = entry.provider;
        next.provider.api_key_env = "";
        next.provider.api_key = key;
        next.credentials = self.global_config.?.value.credentials;
        next.model = entry.model;
        next.models = if (same_endpoint) previous.models else &.{};
        const notice = self.applyPreference(&next);
        const alias = try self.allocator.dupe(u8, entry.selector);
        errdefer self.allocator.free(alias);
        const owned = try cfg.clone(self.allocator, next);
        // Both preparation paths consume owned, including failures.
        var replacement: ?*App.ConnectionReplacement = null;
        var initial: ?*App = null;
        if (self.app) |app| replacement = try app.prepareConnection(owned, self.environ) else initial = try self.prepareApp(owned);
        errdefer if (replacement) |value| value.deinit();
        errdefer if (initial) |value| value.deinit();
        if (replacement) |value| value.client.session_id = self.session_id;
        if (initial) |value| {
            try value.pinSessionID(self.session_id);
            value.setLogging(self.logging);
        }
        const prepared = if (replacement) |value| value.config.value else initial.?.config.value;
        const models = try self.buildModels(prepared, self.global_config.?.value);
        // No persistence: provider/model selection remains session-local.
        if (replacement) |value| self.app.?.installConnection(value) else {
            self.pending_base_model = null;
            if (self.pending) |*value| cfg.release(value);
            self.pending = null;
            self.app = initial.?;
        }
        if (self.selected_name) |name| self.allocator.free(name);
        self.selected_name = null;
        if (self.selected_alias) |old| self.allocator.free(old);
        self.selected_alias = alias;
        self.allocator.free(self.display_models);
        self.display_models = models;
        self.active_revision = revision;
        self.settings_notice = notice;
        self.initial_context = self.app.?.runtime.contextSnapshot();
    }

    fn configureProvider(raw: *anyopaque, id: ProviderId, key: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        var disk = self.global_config.?.value;
        const same_provider = ProviderId.fromUrl(disk.provider.base_url) == id;
        disk.credentials.set(id, key);
        // For the global primary service, migrate its explicit key source to
        // that service's slot; never accidentally retain a stale key/env winner.
        if (same_provider) {
            disk.provider.api_key = null;
            disk.provider.api_key_env = "";
        }
        if (self.app == null) {
            if (same_provider) {
                // Authentication is not a request to overwrite global model
                // defaults, explicit profiles or endpoint options.
                disk.provider.kind = id;
            } else {
                disk.provider = catalog.connection(id);
                disk.model = catalog.first(id).model;
                disk.models = &.{};
            }
        }
        var baseline = try cfg.clone(self.allocator, disk);
        errdefer cfg.release(&baseline);
        var initial: ?*App = null;
        errdefer if (initial) |value| value.deinit();
        var alias: ?[]u8 = null;
        errdefer if (alias) |value| self.allocator.free(value);
        var notice: ?[]const u8 = null;
        if (self.app == null) {
            // Retain a same-endpoint pending /model choice separately from the
            // unchanged global baseline that is about to be saved.
            var next = if (same_provider) self.pending.?.value else baseline.value;
            next.provider = baseline.value.provider;
            next.credentials = baseline.value.credentials;
            notice = self.applyPreference(&next);
            initial = try self.prepareApp(try cfg.clone(self.allocator, next));
            try initial.?.pinSessionID(self.session_id);
            initial.?.setLogging(self.logging);
            alias = try self.aliasFor(initial.?.config.value);
        }
        const active = if (initial) |value| value.config.value else self.mutableConfig().*;
        const models = try self.buildModels(active, baseline.value);
        errdefer self.allocator.free(models);
        if (self.app) |app| try app.journal.rememberKey(key);
        try self.store.save(baseline.value);
        // All remaining work is infallible; save failure preserves the running
        // connection, global baseline, selection and project preference.
        if (self.global_config) |*old| cfg.release(old);
        self.global_config = baseline;
        self.credential_revisions[@intCast(@backingInt(id))] +%= 1;
        if (initial) |value| {
            self.pending_base_model = null;
            if (self.pending) |*pending| cfg.release(pending);
            self.pending = null;
            if (self.selected_name) |name| self.allocator.free(name);
            self.selected_name = null;
            if (self.selected_alias) |old| self.allocator.free(old);
            self.selected_alias = alias;
            self.app = value;
            self.active_revision = self.credential_revisions[@intCast(@backingInt(id))];
            self.settings_notice = notice;
            self.initial_context = value.runtime.contextSnapshot();
        }
        self.allocator.free(self.display_models);
        self.display_models = models;
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
        var global = try cfg.clone(self.allocator, disk_config);
        errdefer cfg.release(&global);
        const models = try self.buildModels(candidate.config.value, global.value);
        errdefer self.allocator.free(models);
        try self.store.save(disk_config);
        if (self.global_config) |*old| cfg.release(old);
        self.global_config = global;
        self.allocator.free(self.display_models);
        self.display_models = models;
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

test "provider credentials stay separate and connection swaps preserve session ownership" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.init(a, std.testing.io, &env, home, .{}, true);
    defer session.deinit();
    const connection = session.connection();
    const id = session.session_id;
    const preference = session.preferred_effort;
    try connection.configureProvider(.deepseek, "fake-deepseek-owner");
    const app = session.app.?;
    const system = app.runtime.system.ptr;
    var baseline = try cfg.clone(a, session.global_config.?.value);
    defer cfg.release(&baseline);
    try connection.configureProvider(.opencode_zen, "fake-zen-owner");
    try connection.configureProvider(.opencode_go, "fake-go-owner");
    try std.testing.expectEqual(@as(u8, 7), connection.current().configured_providers);
    try std.testing.expect(session.app.? == app);
    try std.testing.expectEqual(ProviderId.deepseek, app.config.value.provider.kind.?);
    var disk = try session.store.loadOrInitialize();
    defer cfg.release(&disk);
    try std.testing.expectEqualStrings("fake-deepseek-owner", disk.value.credentials.deepseek.?);
    try std.testing.expectEqualStrings("fake-zen-owner", disk.value.credentials.opencode_zen.?);
    try std.testing.expectEqualStrings("fake-go-owner", disk.value.credentials.opencode_go.?);
    try std.testing.expectEqualStrings(baseline.value.model.name, disk.value.model.name);
    try connection.selectModel("opencode-zen/minimax-m2.7");
    try std.testing.expectEqualStrings(ProviderId.opencode_zen.baseUrl(), app.config.value.provider.base_url);
    try connection.selectModel("opencode-go/minimax-m2.7");
    try std.testing.expectEqualStrings(ProviderId.opencode_go.baseUrl(), app.config.value.provider.base_url);
    try std.testing.expectEqualStrings("opencode-go/minimax-m2.7", connection.current().selection_name.?);
    try std.testing.expectEqualStrings("Bearer fake-go-owner", app.client.authorization);
    // Same model name and protocol, but a new credential must invalidate native
    // replay without dropping canonical text or tool call/result identity.
    const p = @import("../core/protocol.zig");
    const arena = app.runtime.arena.allocator();
    const blocks = try arena.dupe(p.Block, &.{ .{ .reasoning = "private native reasoning" }, .{ .text = "canonical answer" }, .{ .tool_call = .{ .id = "call-1", .name = "read_file", .arguments = "{}", .item_id = "native-item-1" } } });
    try app.runtime.history.append(arena, .{ .role = .assistant, .blocks = blocks, .replay = .{ .scope = .{ .connection = ProviderId.opencode_go.baseUrl(), .model = "minimax-m2.7", .protocol = .chat }, .json = "[]" } });
    try app.runtime.history.append(arena, .{ .role = .tool, .blocks = try arena.dupe(p.Block, &.{.{ .tool_result = .{ .call_id = "call-1", .text = "canonical result" } }}) });
    app.runtime.last_context_tokens = 1200;
    try connection.configureProvider(.opencode_go, "fake-go-rotated");
    try std.testing.expectEqualStrings("Bearer fake-go-owner", app.client.authorization);
    try std.testing.expectEqual(@as(?u64, 1200), app.runtime.last_context_tokens);
    try connection.selectModel("opencode-go/minimax-m2.7");
    try std.testing.expect(session.app.? == app and app.runtime.system.ptr == system);
    try std.testing.expectEqualStrings("Bearer fake-go-rotated", app.client.authorization);
    try std.testing.expectEqualSlices(u8, &id, &app.client.session_id.?);
    try std.testing.expectEqualSlices(u8, &id, &connection.current().session_id.?);
    try std.testing.expect(app.runtime.config == &app.config.value and app.executor.config == &app.config.value and app.client.config == &app.config.value);
    try std.testing.expectEqual(@intFromPtr(&app.client), @intFromPtr(app.runtime.model.context));
    try std.testing.expect(app.runtime.last_context_tokens == null);
    try std.testing.expectEqual(@as(usize, 2), app.runtime.history.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.runtime.history.items[0].blocks.len);
    try std.testing.expect(app.runtime.history.items[0].replay == null);
    try std.testing.expectEqualStrings("canonical answer", app.runtime.history.items[0].blocks[0].text);
    try std.testing.expect(app.runtime.history.items[0].blocks[1].tool_call.item_id == null);
    try std.testing.expectEqualStrings("call-1", app.runtime.history.items[1].blocks[0].tool_result.call_id);
    try std.testing.expectEqual(preference, session.preferred_effort);
    try std.testing.expect(app.runtime.trusted and !app.journal.started);
    try std.testing.expectError(error.UnsupportedProviderModel, connection.selectModel("opencode-go/claude-haiku-5-5"));
}

test "same provider authentication preserves pending choice and global model defaults" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    {
        var store = try Store.open(a, std.testing.io, home);
        defer store.deinit();
        var parsed = try store.loadOrInitialize();
        defer cfg.release(&parsed);
        var original = parsed.value;
        original.model = .{ .name = "configured-original", .context_tokens = 65536, .protocol = .chat, .reasoning_effort = "low", .reasoning = testReasoning() };
        original.models = &.{.{ .name = "configured-next", .context_tokens = 131072, .protocol = .chat, .reasoning = testReasoning() }};
        try store.save(original);
    }
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.init(a, std.testing.io, &env, home, .{}, false);
    defer session.deinit();
    const connection = session.connection();
    try connection.selectModel("configured-next");
    try connection.setEffort(.high);
    try connection.configureProvider(.deepseek, "fake-preserved-choice");
    try std.testing.expectEqualStrings("configured-next", connection.current().model);
    try std.testing.expectEqual(presentation.ReasoningEffort.high, connection.current().reasoning_effort);
    try std.testing.expectEqual(@as(u32, 131072), connection.current().context_limit);
    var disk = try session.store.loadOrInitialize();
    defer cfg.release(&disk);
    try std.testing.expectEqualStrings("configured-original", disk.value.model.name);
    try std.testing.expectEqualStrings("low", disk.value.model.reasoning_effort.?);
    try std.testing.expectEqual(@as(usize, 1), disk.value.models.len);
    try std.testing.expectEqualStrings("configured-next", disk.value.models[0].name);
    try std.testing.expectEqualStrings("fake-preserved-choice", disk.value.credentials.deepseek.?);
    const current = connection.current();
    try std.testing.expect(current.selection_name == null);
    try connection.selectModel(current.model); // The displayed current row is a no-op.
    try connection.configureProvider(.deepseek, "fake-preserved-rotated");
    try std.testing.expectEqualStrings("Bearer fake-preserved-choice", session.app.?.client.authorization);
    try connection.selectModel(connection.current().model);
    try std.testing.expectEqualStrings("Bearer fake-preserved-rotated", session.app.?.client.authorization);
    try std.testing.expectEqualStrings("configured-next", connection.current().model);
    try std.testing.expectEqual(presentation.ReasoningEffort.high, connection.current().reasoning_effort);
    try std.testing.expectEqual(@as(usize, 1), session.app.?.config.value.models.len);
}

test "provider save conflict and pure selection plans leave live state unchanged" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.init(a, std.testing.io, &env, home, .{}, false);
    defer session.deinit();
    const connection = session.connection();
    try connection.configureProvider(.deepseek, "fake-original-owner");
    const app = session.app.?;
    app.runtime.last_context_tokens = 99;
    var next = app.config.value;
    next.provider = catalog.connection(.opencode_go);
    next.model = catalog.first(.opencode_go).model;
    const plan = try app.runtime.planSelection(next, true);
    try std.testing.expect(plan.discard_replay and plan.invalidate_context);
    try std.testing.expectEqual(@as(?u64, 99), app.runtime.last_context_tokens);
    const models = connection.current().models.ptr;
    try session.store.root.writeMode(cfg.file_name, "{}\n", true, 0o600);
    try std.testing.expectError(error.AuthVersionConflict, connection.configureProvider(.opencode_zen, "fake-failed-save"));
    try std.testing.expect(session.app.? == app and connection.current().models.ptr == models);
    try std.testing.expect(session.global_config.?.value.credentials.opencode_zen == null);
    try std.testing.expectEqualStrings("Bearer fake-original-owner", app.client.authorization);
    try std.testing.expectEqual(@as(?u64, 99), app.runtime.last_context_tokens);
    app.runtime.busy.store(true, .release);
    try std.testing.expectError(error.Busy, connection.configureProvider(.opencode_go, "fake-never-used"));
    app.runtime.busy.store(false, .release);
}

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
