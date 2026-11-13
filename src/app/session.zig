//! 交互会话的应用层所有者：允许先显示 TUI，再通过本地授权配置创建 App。
//! TUI 只看 Connection 回调，不持有配置文件或凭证存储逻辑。

const std = @import("std");
const cfg = @import("../core/config.zig");
const r = @import("../core/runtime.zig");
const diagnostics = @import("../core/diagnostics.zig");
const App = @import("app.zig").App;
const Store = @import("auth_store.zig").Store;
const tui = @import("../ui/tui.zig");
const session_client = @import("../ui/session_client.zig");
const presentation = @import("../presentation.zig");
const ids = @import("session_id.zig");
const reasoning_defaults = @import("reasoning_defaults.zig");
const thinking = @import("../core/thinking.zig");
const catalog = @import("provider_catalog.zig");
const ProviderId = cfg.providers.Id;
const selections = @import("selection.zig");
const resume_store = @import("resume_store.zig");
const session_metadata = @import("../core/session_metadata.zig");
const resume_codec = @import("resume_codec.zig");
const checkpoint = @import("../core/checkpoint.zig");
const metadata = @import("model_metadata.zig");
const model_resolver = @import("model_resolver.zig");
const fs = @import("../platform/filesystem.zig");
const decision_selection = @import("decision_selection.zig");
const image_selection = @import("image_selection.zig");
const proxy_selection = @import("proxy_selection.zig");
const image = @import("../core/image.zig");
const settings_preferences = @import("../core/settings.zig");
const codex_login = @import("../core/codex_login.zig");
const codex_oauth = @import("codex_oauth.zig");
const codex_auth = @import("../core/codex_auth.zig");
const p = @import("../core/protocol.zig");
const memory_status = @import("../core/memory_status.zig");
const background_status = @import("../core/background_status.zig");
const MemoryNotifications = @import("memory_notifications.zig").Queue;

const MetadataFetch = *const fn (std.mem.Allocator, std.Io, ProviderId, ?[]const u8) anyerror!metadata.Listing;
const DevFetch = *const fn (std.mem.Allocator, std.Io) anyerror!metadata.Listing;
/// Codex listing borrows an acquired OAuth credential instead of an API key.
const MetadataCodexFetch = *const fn (std.mem.Allocator, std.Io, *const codex_auth.RequestCredential, ?*const p.Cancellation, u32) anyerror!metadata.Listing;
const official_metadata_timeout_ms = 8000;
const models_dev_timeout_ms = 30000;
const official_refresh_success = "Official model list refreshed";
const public_refresh_success = "models.dev metadata refreshed";

fn metadataNoticeTtl(notice: ?[]const u8) u16 {
    const value = notice orelse return 0;
    return if (std.mem.eql(u8, value, official_refresh_success) or std.mem.eql(u8, value, public_refresh_success)) 3000 else 0;
}

fn codexLoginAlias(registry: ?cfg.Registry, selected: ?[]const u8) []const u8 {
    if (registry) |value| {
        if (selected) |name| {
            if (value.find(name)) |provider| if (Session.isCodexProvider(provider.connection)) return provider.name;
        }
        for (value.providers) |provider| if (Session.isCodexProvider(provider.connection)) return provider.name;
    }
    return ProviderId.openai_codex.slug();
}

const CodexLoginJob = struct {
    io: std.Io,
    manager: *codex_oauth.Manager,
    alias: []u8,
    cancel: p.Cancellation = .{},
    mutex: std.Io.Mutex = .init,
    view: codex_login.View,
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,

    fn pending(raw: ?*anyopaque, prompt: codex_oauth.DevicePrompt) !void {
        const self: *CodexLoginJob = @ptrCast(@alignCast(raw orelse return error.InvalidDevicePrompt));
        if (!std.mem.eql(u8, prompt.verification_url, codex_login.verification_url) or prompt.user_code.len == 0 or prompt.user_code.len > 64) return error.InvalidDevicePrompt;
        for (prompt.user_code) |c| if (c < 0x21 or c > 0x7e) return error.InvalidDevicePrompt;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        @memset(&self.view.code, 0);
        @memcpy(self.view.code[0..prompt.user_code.len], prompt.user_code);
        self.view.code_len = @intCast(prompt.user_code.len);
    }
    fn run(self: *CodexLoginJob) void {
        defer self.done.store(true, .release);
        const result = self.manager.login(self.alias, &self.cancel, .{ .context = self, .pending_fn = pending });
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        @memset(&self.view.code, 0);
        self.view.code_len = 0;
        if (result) |_| {
            self.view.status = .succeeded;
        } else |err| {
            if (err == error.Cancelled or err == error.Canceled or self.cancel.isRequested()) {
                self.view.status = .canceled;
            } else {
                self.view.status = .failed;
                self.view.failure = switch (err) {
                    error.OAuthDeviceExpired, error.OAuthTimeout => .expired,
                    error.InvalidDevicePrompt => .invalid_response,
                    error.OAuthLoginConflict, error.AuthStoreBusy => .busy,
                    error.OAuthCommitFailed => .storage,
                    else => .other,
                };
            }
        }
    }
    fn snapshot(self: *CodexLoginJob) codex_login.View {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.view;
    }
    fn destroy(self: *CodexLoginJob, a: std.mem.Allocator) void {
        self.cancel.cancel();
        if (self.future) |*future| future.await(self.io);
        self.manager.deinit();
        a.free(self.alias);
        a.destroy(self);
    }
};

/// A prepared actual model is not a fresh catalog choice. Credential swaps
/// preserve its budget, mapping, effective effort and context provenance.
const MetadataJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fetch: MetadataFetch,
    dev_fetch: DevFetch,
    keys: [ProviderId.all.len]?[]u8 = @splat(null),
    // Codex owns no API key: only an exact configured alias is borrowed, and
    // its credential is acquired through this job's own Manager. Both are
    // released after the official future is joined, never from the worker.
    codex_manager: ?*codex_oauth.Manager = null,
    codex_alias: ?[]u8 = null,
    codex_cancel: p.Cancellation = .{},
    codex_fetch: MetadataCodexFetch = metadata.fetchCodexListing,
    /// Private offline seam; production always acquires through the Manager.
    codex_source: ?codex_auth.CredentialSource = null,
    requested: u8 = 0,
    generations: metadata.Generations = @splat(0),
    credential_revisions: [ProviderId.all.len]u64 = @splat(0),
    succeeded: u8 = 0,
    listing: metadata.Listing = .{},
    manual: bool,
    started_ms: i64,
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    // Separate worker storage: neither worker reads/writes the other's results.
    dev_future: ?std.Io.Future(void) = null,
    dev_done: std.atomic.Value(bool) = .init(false),
    dev_listing: metadata.Listing = .{},
    dev_started_ms: i64 = 0,
    official_published: bool = false,
    dev_published: bool = false,
    // Owner-only, first publication/display failure for this whole job. Worker
    // success and later stages (including a login restart) cannot erase it.
    failure_notice: ?[]const u8 = null,

    fn publicationFailed(self: *MetadataJob, notice: []const u8) ?[]const u8 {
        if (self.failure_notice == null) self.failure_notice = notice;
        return if (self.manual) self.failure_notice else null;
    }

    fn run(self: *MetadataJob) void {
        defer self.done.store(true, .release);
        defer self.wipeKeys();
        for (ProviderId.all) |id| {
            // Codex is authenticated discovery, not an API-key listing.
            if (id == .openai_codex) continue;
            const index: usize = @intCast(@backingInt(id));
            const bit = @as(u8, 1) << @intCast(index);
            if (self.requested & bit == 0 or self.keys[index] == null) continue;
            var values = self.fetch(self.allocator, self.io, id, self.keys[index]) catch |err| {
                if (err == error.Canceled) return;
                continue;
            };
            defer values.deinit(self.allocator);
            metadata.mergeOfficial(self.allocator, &self.listing, &values, id) catch continue;
            self.succeeded |= bit;
        }
        self.runCodex();
    }
    fn remainingCodexMs(started_ms: i64, now_ms: i64) ?u32 {
        const elapsed = @max(@as(i128, 0), @as(i128, now_ms) - @as(i128, started_ms));
        if (elapsed >= official_metadata_timeout_ms) return null;
        return @intCast(@as(i128, official_metadata_timeout_ms) - elapsed);
    }
    fn codexRemaining(self: *MetadataJob) ?u32 {
        if (self.codex_cancel.isRequested()) return null;
        return remainingCodexMs(self.started_ms, @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds()));
    }
    /// A failed acquisition — including a credential awaiting reauthentication —
    /// never becomes a listing request, so no send bypasses the stored login.
    fn runCodex(self: *MetadataJob) void {
        if (self.requested & metadata.bit(.openai_codex) == 0) return;
        const alias = self.codex_alias orelse return;
        const source = self.codex_source orelse blk: {
            const manager = self.codex_manager orelse return;
            break :blk manager.source();
        };
        const acquire_ms = self.codexRemaining() orelse return;
        var credential = source.acquire(self.allocator, alias, &self.codex_cancel, acquire_ms) catch return;
        defer credential.deinit(self.allocator);
        const fetch_ms = self.codexRemaining() orelse return;
        var values = self.codex_fetch(self.allocator, self.io, &credential, &self.codex_cancel, fetch_ms) catch return;
        defer values.deinit(self.allocator);
        metadata.mergeOfficial(self.allocator, &self.listing, &values, .openai_codex) catch return;
        self.succeeded |= metadata.bit(.openai_codex);
    }
    /// Owner-only teardown; the caller has already joined the official future.
    fn releaseCodex(self: *MetadataJob) void {
        self.codex_cancel.cancel();
        if (self.codex_manager) |manager| manager.deinit();
        self.codex_manager = null;
        self.codex_source = null;
        if (self.codex_alias) |alias| self.allocator.free(alias);
        self.codex_alias = null;
        self.codex_cancel = .{};
    }
    fn runDev(self: *MetadataJob) void {
        defer self.dev_done.store(true, .release);
        const dev = self.dev_fetch(self.allocator, self.io) catch return;
        self.dev_listing = dev;
    }
    fn wipeKeys(self: *MetadataJob) void {
        for (&self.keys) |*key| if (key.*) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
            key.* = null;
        };
    }
    fn destroy(self: *MetadataJob) void {
        if (self.future) |*future| future.cancel(self.io);
        if (self.dev_future) |*future| future.cancel(self.io);
        self.wipeKeys();
        self.releaseCodex();
        self.listing.deinit(self.allocator);
        self.dev_listing.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    project: []const u8,
    host: r.Host,
    /// Generated once before activation/logging; never read from the writer.
    session_id: ids.Id,
    store: Store,
    /// Project fd anchors histories/memory only, never thinking preferences.
    project_root: fs.Root,
    preferred_effort: ?presentation.ReasoningEffort = null,
    /// Owner-only: spans spawn through the actual future join.
    owner_task_active: bool = false,
    thinking_pending: bool = false,
    initial_default_pending: bool = false,
    settings_error: ?anyerror = null,
    settings_notice: ?[]const u8 = null,
    pending: ?std.json.Parsed(cfg.Config) = null,
    app: ?*App = null,
    /// Heap-stable across Session moves and App/coordinator replacement.
    memory_notifications: ?*MemoryNotifications = null,
    /// Independently owned replay remains available even without a usable route.
    loaded_checkpoint: ?std.json.Parsed(checkpoint.State) = null,
    loaded_selection: ?selections.Snapshot = null,
    custom_credential_revision: u64 = 0,
    active_custom_revision: u64 = 0,
    /// Computed before publication; callbacks never read worker-owned history.
    initial_context: ?r.ContextSnapshot = null,
    /// Empty-chat model/effort selections update this independent global
    /// baseline; selections with history never leak into credential saves.
    global_config: ?std.json.Parsed(cfg.Config) = null,
    display_models: []cfg.Model = &.{},
    /// Independently resolved reviewer candidates; never use primary limits.
    display_decision_models: []cfg.Model = &.{},
    display_image_models: []cfg.Model = &.{},
    // cfg registry parsing/validation rejects more than 16 providers. Names
    // borrow the global registry arena; current() rebuilds after each save.
    display_providers: []tui.ModelProvider = &.{},
    selected_alias: ?[]u8 = null,
    credential_revisions: [ProviderId.all.len]u64 = @splat(0),
    active_revision: u64 = 0,
    metadata_cache: metadata.Cache = .{},
    metadata_auto: bool = false,
    metadata_next_check_ms: i64 = 0,
    // Owner-only clock seams for deterministic offline refresh tests.
    metadata_wall_ms: ?u64 = null,
    metadata_awake_ms: ?i64 = null,
    metadata_login_auto: bool = false,
    metadata_login_pending: u8 = 0,
    metadata_blocked: bool = false,
    metadata_job: ?*MetadataJob = null,
    codex_job: ?*CodexLoginJob = null,
    codex_view: codex_login.View = .{},
    codex_reported: codex_login.View = .{},
    metadata_fetch: MetadataFetch = metadata.fetch,
    metadata_dev_fetch: DevFetch = metadata.fetchDev,
    metadata_codex_fetch: MetadataCodexFetch = metadata.fetchCodexListing,
    /// Private offline seam for the borrowed Codex credential source; the
    /// production path always acquires through an owned Manager.
    metadata_codex_source: ?codex_auth.CredentialSource = null,
    metadata_notice: ?[]const u8 = null,
    /// Identity snapshot only: App publishes process-lifetime static notices.
    /// Never retain or inspect worker-owned mutable Runtime state here.
    last_memory_view: @import("../core/memory_status.zig").View = .{},
    last_subagent_view: @import("../core/subagent_status.zig").View = .{},
    active_context_official: bool = false,
    display_origins: []bool = &.{},
    display_disabled: []bool = &.{},

    resume_lease: ?resume_store.Lease = null,
    saved_title: session_metadata.Title = .{},
    resumed: bool = false,
    /// Another writer or a read-only checkpoint store never blocks viewing.
    read_only: bool = false,
    /// Journal observer wrapped so checkpoint writes stay on the runtime thread.
    inner_observer: r.Observer = .{},
    /// UI thread reads this while the runtime thread records incremental saves.
    /// Zero means the last attempted save succeeded. A nonzero code stays until
    /// a later save publishes a clean generation.
    checkpoint_failure: std.atomic.Value(u16) = .init(0),

    /// `session_id` is the explicit identity of a NEW session (daemon/foreground
    /// worker); resume keeps its own source id and rejects a conflicting value.
    /// `auto_refresh_models` is opt-in and never implied by ownership.
    pub const Options = struct { session_id: ?ids.Id = null, restore_selection: ?ids.Id = null, resume_session: ?ids.Id = null, auto_refresh_models: bool = false };

    /// 只做本地初始化；缺少凭证时保持 pending，不发起试探请求。
    pub fn init(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host) !Session {
        return initWithOptions(a, io, environ, project, host, .{});
    }

    pub fn initWithOptions(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host, options: Options) !Session {
        const home = environ.get("HOME") orelse return error.MissingHome;
        if (options.resume_session != null and options.restore_selection != null) return error.InvalidArguments;
        if (options.session_id) |given| {
            if (!ids.valid(given)) return error.InvalidSessionID;
            if (options.resume_session) |source| if (!std.mem.eql(u8, &source, &given)) return error.InvalidArguments;
            if (options.restore_selection) |source| if (std.mem.eql(u8, &source, &given)) {
                // Restoring a selection into the same id would overwrite the source.
                return error.InvalidArguments;
            };
        }
        const id = options.resume_session orelse options.session_id orelse try ids.generate(io);
        var project_root = try fs.Root.open(a, io, project);
        var project_moved = false;
        errdefer if (!project_moved) project_root.deinit();
        // Resume acquires an execution lease; viewers may fall back to read-only.
        var lease: ?resume_store.Lease = if (options.resume_session) |source_id| resume_store.Lease.open(&project_root, source_id, true) catch |err| switch (err) {
            error.SessionInUse => try resume_store.Lease.open(&project_root, source_id, false),
            error.AccessDenied, error.ReadOnlyFileSystem, error.UnsafeResumeFile => try resume_store.Lease.open(&project_root, source_id, false),
            else => return err,
        } else null;
        errdefer if (lease) |*owned| owned.deinit();
        const source_bytes: ?[]u8 = if (lease) |*owned| try owned.load(&project_root) else null;
        const selection_bytes: ?[]u8 = if (options.restore_selection) |source_id| try loadSelectionBytes(&project_root, source_id) else null;
        defer if (source_bytes) |bytes| {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        };
        defer if (selection_bytes) |bytes| {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        };
        const envelope: ?resume_codec.Envelope = if (source_bytes) |bytes| try resume_codec.inspect(a, bytes, id) else if (selection_bytes) |bytes| try resume_codec.inspect(a, bytes, options.restore_selection.?) else null;
        const restored: ?selections.Snapshot = if (envelope) |value| value.selection else null;
        var loaded: ?std.json.Parsed(checkpoint.State) = if (envelope) |value| try checkpoint.decode(a, value.payload) else null;
        errdefer if (loaded) |value| value.deinit();
        if (source_bytes == null) {
            if (loaded) |value| value.deinit();
            loaded = null;
        }
        const auth_store = try Store.open(a, io, home);
        var self: Session = .{
            .allocator = a,
            .io = io,
            .environ = environ,
            .project = project,
            .host = host,
            .session_id = id,
            .store = auth_store,
            .project_root = project_root,
            .resume_lease = lease,
            .saved_title = if (lease) |*owned| owned.getTitle(&project_root) else .{},
            .resumed = options.resume_session != null,
            // Logging never buys write rights: a non-writable lease can only
            // view history and never activates an App or publishes state.
            .read_only = if (lease) |owned| !owned.writable else false,
            .metadata_auto = options.auto_refresh_models,
            // Restored sessions do no startup fetch, but regain timed refresh.
            .metadata_next_check_ms = if (restored != null) @as(i64, @intCast(std.Io.Clock.awake.now(io).toMilliseconds())) + 60000 else 0,
            .metadata_login_auto = options.auto_refresh_models,
        };
        lease = null;
        project_moved = true;
        errdefer self.deinit();
        self.memory_notifications = try MemoryNotifications.create(a);
        self.loaded_checkpoint = loaded;
        loaded = null;
        self.loaded_selection = restored;
        self.pending = try self.store.loadOrInitialize();
        self.global_config = try cfg.clone(a, self.pending.?.value);
        self.metadata_cache = metadata.load(&self.store.root) catch |err| blk: {
            // A recognized older cache is not a poisoned store: the next claim
            // rebuilds the current format, so startup/first idle poll may refresh.
            // Future, malformed and I/O failures keep the cadence disabled.
            if (err != error.OutdatedMetadataCache) self.metadata_blocked = true;
            break :blk .{};
        };
        if (restored) |snapshot| {
            try self.loadRestoredSelection(snapshot);
        } else {
            const config = &self.pending.?.value;
            if (config.registry != null) {
                model_resolver.applyDefault(self.pending.?.arena.allocator(), config, &self.metadata_cache) catch |err| {
                    if (!model_resolver.isUnresolved(err)) return err;
                    config.selection_pending = true;
                    self.settings_notice = "Default model unavailable locally; select a configured model";
                };
                if (!config.selection_pending) {
                    const provider = config.registry.?.find(config.selected_provider.?).?;
                    const patch = provider.patchFor(config.model.name);
                    if (patch == null or patch.?.context_tokens == null) {
                        if (ProviderId.fromUrl(config.provider.base_url)) |service| {
                            if (metadata.restoreEntry(&self.metadata_cache, service, config.model.name)) |entry|
                                self.active_context_official = self.officialCapacity(entry) != null;
                        }
                    }
                }
            }
            self.preferred_effort = reasoning_defaults.preference(config.*);
            if (self.applyPreference(config, self.preferred_effort, true)) |notice| self.settings_notice = notice;
        }
        const config = &self.pending.?.value;
        self.display_models = try self.buildModels(self.global_config.?.value);
        self.display_decision_models = try self.buildDecisionModels(self.global_config.?.value);
        self.display_image_models = try self.buildImageModels(self.global_config.?.value);
        if (self.selected_alias == null) self.selected_alias = try self.aliasFor(config.*);
        if (self.read_only) {
            self.settings_notice = "Session is open elsewhere or not writable; read-only history";
            return self;
        }
        if (config.model.protocol == .systemone) {
            self.settings_notice = "SystemOne is decision-only; history available, select a chat model";
            return self;
        }
        if (config.selection_pending) return self;
        if (isCodexProvider(config.provider)) {
            if (!self.hasLocalCredential(config.provider)) {
                self.settings_notice = "Not logged in; history available, use /login to activate";
                return self;
            }
        } else {
            const key = cfg.resolveApiKey(a, self.pending.?.value, environ) catch |err| {
                if (err == error.ApiKeyNotFound or err == error.InvalidApiKey) {
                    self.settings_notice = "Not logged in; history available, use /login to activate";
                    return self;
                }
                return err;
            };
            std.crypto.secureZero(u8, key);
            a.free(key);
        }

        const parsed = self.pending.?;
        self.pending = null;
        self.app = try self.prepareApp(parsed);
        self.last_memory_view = self.app.?.memoryView();
        self.armInitialDefault();
        self.releaseLoadedHistory();
        self.initial_context = self.app.?.runtime.contextSnapshot();
        return self;
    }

    fn loadRestoredSelection(self: *Session, snapshot: selections.Snapshot) !void {
        const config = &self.pending.?.value;
        const a = self.pending.?.arena.allocator();
        const registry = config.registry orelse return error.InvalidConfig;
        var name: ?[]const u8 = null;
        if (snapshot.providerName()) |saved| {
            if (registry.find(saved) != null) name = saved;
        }
        // Missing aliases can be rebound only by their exact endpoint, never
        // by service kind or a coincidentally identical model name.
        if (name == null) {
            for (registry.providers) |provider| {
                const fingerprint = selections.endpoint(provider.connection.base_url);
                if (!std.mem.eql(u8, &snapshot.endpoint, &fingerprint)) continue;
                if (name != null) {
                    name = null;
                    break;
                }
                name = provider.name;
            }
        }
        config.selection_pending = true;
        config.model.name = try a.dupe(u8, snapshot.model());
        config.selected_provider = if (name orelse snapshot.providerName()) |value| try a.dupe(u8, value) else null;
        self.selected_alias = if (config.selected_provider) |value|
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ value, snapshot.model() })
        else
            try self.allocator.dupe(u8, snapshot.model());
        self.preferred_effort = snapshot.effort;
        self.settings_notice = "Saved model unavailable locally; history available, use /model";
        const provider_name = name orelse {
            // Do not display the default service as the restored route.
            config.provider = .{ .base_url = "", .api_key_env = "" };
            return;
        };
        config.provider = registry.find(provider_name).?.connection;
        const resolved = model_resolver.resolve(a, config.*, &self.metadata_cache, provider_name, snapshot.model(), false) catch |err| {
            if (err == error.OutOfMemory) return err;
            return;
        };
        model_resolver.apply(config, resolved);
        self.active_context_official = resolved.context_official;
        _ = self.applyPreference(config, self.preferred_effort, false);
        self.settings_notice = if (self.loaded_checkpoint != null)
            session_client.restored_notice
        else
            "Selection restored; NEW EMPTY CHAT (history not restored)";
    }

    fn prepareLoadedHistory(self: *Session, candidate: *App) !void {
        const loaded = self.loaded_checkpoint orelse return;
        var state = loaded.value;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        // A missing schema hash cannot prove the saved tool prefix. Current
        // tool declarations must not replay old signed thinking under changed tools.
        // Normalize display data before restore, even for a poisoned archive;
        // loading history itself must not require permission to run a task.
        if (state.tool_schema_hash == null and
            (self.global_config.?.value.decision != null or self.global_config.?.value.imageActive() or candidate.executor.session_title != null))
        {
            const messages = try scratch.allocator().alloc(@import("../core/protocol.zig").Message, state.messages.len);
            for (state.messages, 0..) |message, i|
                messages[i] = try @import("../core/context.zig").cloneAfterPrefixRewrite(scratch.allocator(), message);
            state.messages = messages;
            // Server-confirmed display usage remains valid as a past statistic,
            // independently of native signed-prefix replay validity.
        }
        try candidate.runtime.restoreCheckpoint(state);
        candidate.journal.seq = loaded.value.journal_seq;
        candidate.journal.turn = loaded.value.journal_turn;
        candidate.journal.resumed = true;
        candidate.journal.began_ms = std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn releaseLoadedHistory(self: *Session) void {
        if (self.loaded_checkpoint) |value| value.deinit();
        self.loaded_checkpoint = null;
        self.loaded_selection = null;
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
        const candidate = try App.initConfiguredAnchoredAuthWithNotifications(self.allocator, self.io, self.environ, &self.project_root, protected, self.host, parsed, self.memory_notifications.?);
        errdefer candidate.deinit();
        // Pin while the fresh journal still has zero counters. Imported sequence
        // numbers belong to the archive, not to a second pin operation.
        try candidate.pinSessionID(self.session_id);
        if (!self.read_only) {
            const title = if (self.app) |app| app.executor.session_title orelse self.saved_title else self.saved_title;
            candidate.enableSessionTitle(title);
        }
        try self.prepareLoadedHistory(candidate);
        return candidate;
    }

    /// 必须等 TUI 取消并 join worker 后再释放；Connection 不得比 Session 活得更久。
    pub fn deinit(self: *Session) void {
        self.last_subagent_view.deinitOwned(self.allocator);
        if (self.codex_job) |job| job.destroy(self.allocator);
        self.codex_job = null;
        self.releaseLoadedHistory();
        if (self.metadata_job) |job| job.destroy();
        self.metadata_cache.deinit(self.allocator);
        self.allocator.free(self.display_providers);
        self.allocator.free(self.display_origins);
        self.allocator.free(self.display_disabled);
        self.freeDisplayModels(self.display_models);
        self.freeDisplayModels(self.display_decision_models);
        self.freeDisplayModels(self.display_image_models);
        if (self.selected_alias) |alias| self.allocator.free(alias);
        if (self.global_config) |*global| cfg.release(global);
        if (self.app) |app| app.deinit();
        // App teardown joins every producer before freeing the shared queue.
        if (self.memory_notifications) |queue| queue.deinit();
        if (self.resume_lease) |*lease| lease.deinit();
        if (self.pending) |*pending| cfg.release(pending);
        self.store.deinit();
        self.project_root.deinit();
        self.* = undefined;
    }

    /// Peek is non-consuming; the remote host takes only after LiveRing accepts
    /// this exact value. The Session has one consumer (local UI or remote host).
    pub fn peekMemoryCompletion(self: *Session) ?memory_status.Terminal {
        return if (self.memory_notifications) |queue| queue.peek() else null;
    }

    /// Returns an owned fixed value without allocating or touching a Job.
    pub fn takeMemoryCompletion(self: *Session) ?memory_status.Terminal {
        return if (self.memory_notifications) |queue| queue.take() else null;
    }

    fn takeMemoryCompletionCallback(raw: *anyopaque) ?memory_status.Terminal {
        const self: *Session = @ptrCast(@alignCast(raw));
        return self.takeMemoryCompletion();
    }

    pub fn backgroundView(self: *Session) background_status.View {
        return if (self.app) |app| app.backgroundView() else .{};
    }

    pub fn peekBackgroundCompletion(self: *Session) ?background_status.Terminal {
        return if (self.app) |app| app.peekBackgroundCompletion() else null;
    }

    pub fn takeBackgroundCompletion(self: *Session, id: background_status.Id) void {
        if (self.app) |app| app.takeBackgroundCompletion(id);
    }

    fn peekBackgroundCallback(raw: *anyopaque) ?background_status.Terminal {
        const self: *Session = @ptrCast(@alignCast(raw));
        return self.peekBackgroundCompletion();
    }

    fn takeBackgroundCallback(raw: *anyopaque, id: background_status.Id) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.takeBackgroundCompletion(id);
    }

    pub fn beginOwnerTask(self: *Session) !void {
        try self.guardSelection();
        if (self.app == null) return error.Unavailable;
        self.owner_task_active = true;
    }

    /// Only the owner, after the future has actually joined, may call this.
    pub fn finishOwnerTask(self: *Session) void {
        if (!self.owner_task_active) return;
        if (self.app) |app| {
            if (self.thinking_pending) {
                if (app.thinking_control.get()) |selection| {
                    app.config.value.model.reasoning_effort = selection.reasoning_effort;
                    app.config.value.model.reasoning = selection.reasoning;
                    app.recordSelection();
                    self.publishCheckpoint();
                }
            }
            app.thinking_control.clear();
        }
        self.thinking_pending = false;
        self.owner_task_active = false;
    }

    fn taskBegin(raw: *anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.beginOwnerTask();
    }

    fn taskJoined(raw: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        self.finishOwnerTask();
    }

    pub fn connection(self: *Session) tui.Connection {
        self.installObserver();
        return .{ .context = self, .task_begin_fn = taskBegin, .task_joined_fn = taskJoined, .current_fn = current, .configure_fn = configure, .configure_provider_fn = configureProvider, .select_model_fn = selectModel, .set_effort_fn = setEffort, .cycle_effort_fn = cycleEffort, .setting_fn = setSetting, .preference_fn = setPreference, .decision_fn = setDecision, .image_fn = setImage, .proxy_fn = setProxyModel, .proxy_address_fn = setProxyAddress, .initial_history_fn = initialHistory, .refresh_models_fn = refreshModels, .poll_models_fn = pollModels, .codex_login_fn = codexLogin, .take_memory_completion_fn = takeMemoryCompletionCallback, .peek_background_fn = peekBackgroundCallback, .take_background_fn = takeBackgroundCallback };
    }

    /// Called once, before any producer exists; never exposed by per-frame state.
    fn initialHistory(raw: *anyopaque) []const @import("../core/protocol.zig").Message {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (self.app) |app| return app.runtime.messages();
        if (self.loaded_checkpoint) |loaded| return loaded.value.messages;
        return &.{};
    }

    /// Display-only row counters that belong to the restored messages. Same
    /// startup-only contract as `initialHistory`: no producer may exist yet.
    pub fn displayStats(self: *const Session) []const checkpoint.ToolStat {
        if (self.app) |app| return app.runtime.displayStats();
        if (self.loaded_checkpoint) |loaded| return loaded.value.tool_stats orelse &.{};
        return &.{};
    }

    /// Joined, normal interactive exit. Checkpoints are also written during the
    /// run; this publishes the final clean generation. A failure never changes
    /// task success; the caller must withhold the command.
    pub fn saveOnExit(self: *Session) !bool {
        if (self.read_only) return false;
        if (!hasConversationData(initialHistory(self))) return false;
        if (self.app) |app| app.journal.finish();
        const bytes = try self.encodeCheckpoint(false);
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        try resume_store.saveFinal(&self.project_root, self.session_id, if (self.resume_lease) |*lease| lease else null, bytes);
        return true;
    }

    fn installObserver(self: *Session) void {
        const app = self.app orelse return;
        if (app.runtime.observer.context == @as(*anyopaque, self)) return;
        if (app.runtime.busy.load(.acquire)) return;
        app.runtime.diagnostics = app.journal.diagnosticSink();
        self.inner_observer = app.journal.observer();
        app.runtime.observer = .{ .context = self, .notify_fn = persistNotify };
    }

    fn persistNotify(ctx: ?*anyopaque, observation: r.Observation) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        self.inner_observer.notify(observation);
        switch (observation) {
            .event => |event| switch (event) {
                .user_committed, .assistant_committed, .compacted, .finished => self.persistBestEffort(true),
                else => {},
            },
            .tool_completed => self.persistBestEffort(true),
            else => {},
        }
    }

    fn persistBestEffort(self: *Session, during_run: bool) void {
        self.persistCheckpoint(during_run) catch |err| switch (err) {
            error.IncompleteToolGroup => {},
            else => self.setCheckpointFailure(err),
        };
    }

    fn setCheckpointFailure(self: *Session, err: anyerror) void {
        self.checkpoint_failure.store(@intFromError(err), .release);
    }

    fn clearCheckpointFailure(self: *Session) void {
        self.checkpoint_failure.store(0, .release);
    }

    fn checkpointError(self: *const Session) ?anyerror {
        const code = self.checkpoint_failure.load(.acquire);
        return if (code == 0) null else @errorFromInt(code);
    }

    /// Reinstall the runtime observer, then publish a checkpoint when this
    /// chat already has history. Idle selection changes are not a model turn.
    fn publishCheckpoint(self: *Session) void {
        self.installObserver();
        self.persistBestEffort(false);
    }

    fn persistCheckpoint(self: *Session, during_run: bool) !void {
        const sink = if (self.app) |app| app.journal.diagnosticSink() else diagnostics.Sink{};
        var span = diagnostics.Span.start(sink, self.io, .{ .stage = .checkpoint });
        defer span.finish(.ok);
        self.persistCheckpointInner(during_run) catch |err| {
            span.fail(err);
            return err;
        };
    }

    fn persistCheckpointInner(self: *Session, during_run: bool) !void {
        const app = self.app orelse return;
        if (!hasConversationData(app.runtime.messages())) return;
        if (app.runtime.poisoned) return error.UnsafeToContinue;
        const bytes = try self.encodeCheckpoint(during_run);
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        try self.ensureWritableLease();
        try self.resume_lease.?.save(&self.project_root, bytes);
        self.clearCheckpointFailure();
        self.persistTitleBestEffort();
    }

    fn persistTitleBestEffort(self: *Session) void {
        const lease = if (self.resume_lease) |*value| value else return;
        if (!lease.writable or lease.expected == null) return;
        var title = if (self.app) |app| app.executor.session_title orelse self.saved_title else self.saved_title;
        if (title.text().len == 0) {
            for (initialHistory(self)) |message| {
                if (message.role != .user) continue;
                for (message.blocks) |block| switch (block) {
                    .text => |text| {
                        title = session_metadata.Title.fromText(text);
                        if (title.text().len != 0) break;
                    },
                    else => {},
                };
                break;
            }
            if (self.app) |app| if (app.executor.session_title != null) {
                app.executor.session_title = title;
            };
        }
        if (title.text().len == 0 or session_metadata.Title.eql(title, self.saved_title)) return;
        lease.saveTitle(&self.project_root, title) catch |err| {
            self.setCheckpointFailure(err);
            return;
        };
        self.saved_title = title;
    }

    fn ensureWritableLease(self: *Session) !void {
        if (self.resume_lease) |*lease| {
            if (!lease.writable) return error.ResumeReadOnly;
            return;
        }
        self.resume_lease = try resume_store.Lease.create(&self.project_root, self.session_id);
    }

    fn encodeCheckpoint(self: *Session, during_run: bool) ![]u8 {
        var state: checkpoint.State = undefined;
        const selection = if (self.app) |app| blk: {
            state = if (during_run) try app.runtime.exportCheckpoint() else try app.runtime.checkpoint();
            state.journal_seq = app.journal.seq;
            state.journal_turn = app.journal.turn;
            state.context_official = self.active_context_official;
            break :blk try selections.capture(app.config.value);
        } else blk: {
            state = (self.loaded_checkpoint orelse return error.NotConfigured).value;
            break :blk self.loaded_selection orelse return error.NotConfigured;
        };
        const payload = try checkpoint.encode(self.allocator, state);
        defer {
            std.crypto.secureZero(u8, payload);
            self.allocator.free(payload);
        }
        return resume_codec.encode(self.allocator, self.session_id, &selection, payload);
    }

    fn current(raw: *anyopaque) tui.Connection.State {
        const self: *Session = @ptrCast(@alignCast(raw));
        const base = if (self.app) |app| app.config.value else self.pending.?.value;
        const config = self.pendingThinkingConfig(base);
        const unselected = self.app == null and self.loaded_checkpoint == null;
        var provider_count: usize = 0;
        if (self.global_config.?.value.registry) |registry| {
            // This is the validated registry bound, not a truncation policy.
            std.debug.assert(registry.providers.len <= self.display_providers.len);
            for (registry.providers) |provider| {
                if (!self.hasLocalCredential(provider.connection)) continue;
                self.display_providers[provider_count] = .{
                    .name = provider.name,
                    .allow_custom = allowsCustomModels(provider.connection),
                };
                provider_count += 1;
            }
        }
        for (self.display_models, 0..) |model, index| {
            self.display_origins[index] = false;
            self.display_disabled[index] = model.protocol == .systemone;
            if (config.registry) |registry| {
                // Resolver leaves undeclared/unknown protocols at zero context;
                // an explicitly declared auto remains valid for primary Chat/Responses probing.
                self.display_disabled[index] = model.protocol == .systemone or model.context_tokens == 0;
                if (std.mem.findScalar(u8, model.name, '/')) |slash| {
                    if (registry.find(model.name[0..slash])) |provider| {
                        const raw_id = model.name[slash + 1 ..];
                        const patch = provider.patchFor(raw_id);
                        if (patch == null or patch.?.context_tokens == null) {
                            if (ProviderId.fromUrl(provider.connection.base_url)) |id| {
                                if (metadata.restoreEntry(&self.metadata_cache, id, raw_id)) |entry| {
                                    if (self.officialCapacity(entry)) |tokens|
                                        self.display_origins[index] = tokens == model.context_tokens;
                                }
                            }
                        }
                    }
                }
                continue;
            }
        }
        const initial_context: ?r.ContextSnapshot = if (unselected or config.selection_pending) null else self.initial_context orelse blk: {
            // This is only a display statistic; loading it cannot activate a route.
            // A checkpoint's missing usage is unknown, unlike a fresh known zero.
            const tokens: ?u64 = if (self.loaded_checkpoint) |loaded| loaded.value.last_context_tokens else 0;
            break :blk .{ .tokens = tokens orelse 0, .limit = @intCast(config.model.context_tokens), .known = tokens != null };
        };
        return .{
            .codex_login = self.codexLoginView(),
            .runtime = if (self.app) |app| &app.runtime else null,
            .initial_context = initial_context,
            .model = if (unselected) "" else config.model.name,
            .session_id = self.session_id,
            .models = self.display_models,
            .model_providers = self.display_providers[0..provider_count],
            .model_context_official = self.display_origins[0..self.display_models.len],
            .model_disabled = self.display_disabled[0..self.display_models.len],
            .context_official = self.active_context_official,
            .metadata_notice = self.metadata_notice,
            .metadata_notice_ttl_ms = metadataNoticeTtl(self.metadata_notice),
            .selection_name = if (unselected) null else self.selected_alias,
            // Login identity must agree with credential/metadata routing. A kind
            // hint on a proxy does not turn that endpoint into an official host.
            .provider = ProviderId.fromUrl(config.provider.base_url),
            .configured_providers = self.configuredMask(self.global_config.?.value),
            // Registry-backed IDs need a declared or exact metadata profile;
            // an unknown raw ID cannot inherit another model's capabilities.
            .allow_custom_models = config.registry == null and allowsCustomModels(config.provider),
            .context_limit = if (unselected or config.selection_pending) 0 else config.model.context_tokens,
            // L reports active protection against a known price step, not
            // the global switch. Flat/unknown/pending models have no marker.
            .low_price_input = self.app != null and !unselected and !config.selection_pending and config.limits.low_price_input and config.model.input_price_threshold != null,
            .limits = config.limits,
            .low_price_input_enabled = config.limits.low_price_input,
            .decision_enabled = config.decisionActive(),
            .decision_models = self.display_decision_models,
            .decision_model = if (config.decision) |value| (if (value.enabled) value.model else null) else null,
            .image_enabled = config.imageActive(),
            .image_models = self.display_image_models,
            .image_model = if (config.imageActive()) config.image.model else null,
            // Publish the current global declaration, not the frozen primary
            // route: an explicit proxy edit applies to helpers immediately and
            // to the primary only in a later session.
            .proxy_configured = self.global_config.?.value.proxy != null,
            .proxy_models = if (self.global_config.?.value.proxy) |value| value.models else &.{},
            // Host/port are public routing facts for the settings editor; the
            // endpoint itself is never credential material.
            .proxy_address = if (self.global_config.?.value.proxy) |value| value.address else null,
            .proxy_port = if (self.global_config.?.value.proxy) |value| value.port else 0,
            .memory_auto = config.memory.auto,
            .memory = if (self.app) |app| app.memoryView() else .{},
            .background = self.backgroundView(),
            .subagents = if (self.app) |app| app.subagentView() else .{},
            .subagents_supported = true,
            .global_settings_available = !self.read_only,
            .reasoning_effort = presentation.ReasoningEffort.fromName(config.model.reasoning_effort),
            .pending_default_effort = if (self.app != null and self.initial_default_pending and config.model.reasoning_effort == null) self.preferred_effort else null,
            .effort_levels = self.capabilitiesFor(config).levels,
            .settings_error = self.settings_error,
            .settings_notice = self.settings_notice,
            .base_url = config.provider.base_url,
            // Journal failures already render as REC FAILED. Checkpoint saves use
            // that same channel when the journal itself is still healthy.
            .log_error = (if (self.app) |app| app.journal.failure() else null) orelse self.checkpointError(),
        };
    }

    fn officialCapacity(self: *const Session, entry: catalog.Entry) ?u32 {
        return metadata.capacityFor(&self.metadata_cache, entry);
    }

    fn applyReasoningMetadata(self: *const Session, config: *cfg.Config) void {
        // Registry selections already own the resolver's field-by-field merge.
        // Accepted maps (including unknown) and manual effort are frozen on
        // redraw/refresh. An explicit effort action may resolve a missing map.
        if (config.registry != null) return;
        metadata.applyReasoning(&self.metadata_cache, config);
    }

    fn capabilitiesFor(self: *const Session, config: cfg.Config) thinking.Capabilities {
        var effective = config;
        self.applyReasoningMetadata(&effective);
        return thinking.resolve(effective.provider.base_url, effective.model.name, effective.model.reasoning);
    }

    fn declarationForEntry(self: *const Session, entry: catalog.Entry) ?thinking.Declaration {
        // Credential reactivation also passes explicit custom models through
        // this entry path. Their declarations must not be treated as presets.
        if (entry.model.reasoning_source == .explicit and entry.model.reasoning != null) return entry.model.reasoning;
        return metadata.entryDeclaration(&self.metadata_cache, entry);
    }

    fn sameDeclaration(a: ?thinking.Declaration, b: ?thinking.Declaration) bool {
        if (a == null or b == null) return a == null and b == null;
        if (a.?.format != b.?.format) return false;
        inline for (.{ "off", "minimal", "low", "medium", "high", "xhigh", "max" }) |field| {
            const left = @field(a.?.map, field);
            const right = @field(b.?.map, field);
            if (left == null or right == null) {
                if (left != null or right != null) return false;
            } else if (!std.mem.eql(u8, left.?, right.?)) return false;
        }
        return true;
    }

    /// Owner-thread only. A login worker owns no Session or UI pointers.
    pub fn startCodexLogin(self: *Session) !void {
        try self.guardSelection();
        if (self.codex_job != null) return error.Busy;
        const generation = std.math.add(u64, self.codex_view.generation, 1) catch return error.Unavailable;
        const home = self.environ.get("HOME") orelse return error.MissingHome;
        const alias = try self.allocator.dupe(u8, codexLoginAlias(self.global_config.?.value.registry, self.mutableConfig().selected_provider));
        errdefer self.allocator.free(alias);
        const manager = try codex_oauth.Manager.init(self.allocator, self.io, home, self.environ);
        errdefer manager.deinit();
        const job = try self.allocator.create(CodexLoginJob);
        errdefer self.allocator.destroy(job);
        job.* = .{ .io = self.io, .manager = manager, .alias = alias, .view = .{ .generation = generation, .status = .pending } };
        job.future = try std.Io.concurrent(self.io, CodexLoginJob.run, .{job});
        self.codex_job = job;
        self.codex_view = .{ .generation = generation, .status = .pending };
    }

    pub fn cancelCodexLogin(self: *Session, generation: u64) !void {
        const job = self.codex_job orelse return error.InvalidSequence;
        if (generation != job.view.generation) return error.InvalidSequence;
        job.cancel.cancel();
    }

    pub fn codexLoginView(self: *Session) codex_login.View {
        return if (self.codex_job) |job| job.snapshot() else self.codex_view;
    }

    /// Reload the committed declaration without replacing a live runtime or its
    /// frozen model. Pending history remains owned until a candidate is ready.
    fn reloadCodexLogin(self: *Session) !void {
        var latest = try self.store.loadExisting();
        errdefer cfg.release(&latest);
        const active = self.mutableConfig().*;
        var next: ?std.json.Parsed(cfg.Config) = null;
        errdefer if (next) |*value| cfg.release(value);
        var initial: ?*App = null;
        errdefer if (initial) |value| value.deinit();
        if (self.app == null) {
            var merged = active;
            merged.registry = latest.value.registry;
            if (active.selected_provider) |name| {
                if (latest.value.registry) |registry| if (registry.find(name)) |provider| {
                    merged.provider = provider.connection;
                };
            }
            next = try cfg.clone(self.allocator, merged);
            if (!merged.selection_pending and isCodexProvider(merged.provider) and merged.provider.codex_oauth != null) {
                const parsed = next.?;
                next = null;
                initial = try self.prepareApp(parsed);
            }
        }
        const models = try self.buildModels(latest.value);
        errdefer self.freeDisplayModels(models);
        const decisions = try self.buildDecisionModels(latest.value);
        errdefer self.freeDisplayModels(decisions);
        const images = try self.buildImageModels(latest.value);
        errdefer self.freeDisplayModels(images);
        if (self.global_config) |*old| cfg.release(old);
        self.global_config = latest;
        if (self.app == null) {
            if (self.pending) |*old| cfg.release(old);
            self.pending = next;
            if (initial) |app| {
                self.app = app;
                self.last_memory_view = app.memoryView();
                self.armInitialDefault();
                self.initial_context = app.runtime.contextSnapshot();
                self.releaseLoadedHistory();
                self.settings_notice = if (self.resumed) session_client.restored_notice else null;
            }
        }
        self.freeDisplayModels(self.display_models);
        self.freeDisplayModels(self.display_decision_models);
        self.freeDisplayModels(self.display_image_models);
        self.display_models = models;
        self.display_decision_models = decisions;
        self.display_image_models = images;
        self.credential_revisions[@intCast(@backingInt(ProviderId.openai_codex))] +%= 1;
        // The saved login refreshes exactly this provider's authenticated list
        // plus the public catalog; other sources keep their own claim cadence.
        // A running job defers only the official bit to its pending restart.
        const codex_metadata: u8 = if (self.codexMetadataAlias() != null) metadata.bit(.openai_codex) else 0;
        if (self.metadata_job == null) self.startMetadata(codex_metadata | metadata.dev_bit, true) catch {
            self.metadata_notice = "Login saved; model metadata refresh failed";
        } else if (codex_metadata != 0) self.metadata_login_pending |= codex_metadata;
    }

    /// Never waits for network; completion joins only after worker publication.
    pub fn pollCodexLogin(self: *Session) !bool {
        if (self.codex_job) |job| {
            if (job.done.load(.acquire)) {
                if (self.owner_task_active or (if (self.app) |app| app.runtime.busy.load(.acquire) else false)) {
                    const view = job.snapshot();
                    const changed = !std.meta.eql(view, self.codex_reported);
                    self.codex_reported = view;
                    return changed;
                }
                if (job.future) |*future| future.await(self.io);
                job.future = null;
                self.codex_view = job.snapshot();
                self.codex_job = null;
                job.destroy(self.allocator);
                if (self.codex_view.status == .succeeded) self.reloadCodexLogin() catch {
                    self.settings_notice = "Login saved; local configuration reload failed";
                };
            }
        }
        const view = self.codexLoginView();
        const changed = !std.meta.eql(view, self.codex_reported);
        self.codex_reported = view;
        return changed;
    }

    fn codexLogin(raw: *anyopaque, action: codex_login.Action, generation: u64) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        switch (action) {
            .start => try self.startCodexLogin(),
            .cancel => try self.cancelCodexLogin(generation),
        }
    }

    fn refreshModels(raw: *anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.startMetadata(self.configuredMask(self.global_config.?.value), true);
    }

    fn refreshPolicy(_: *const Session) metadata.Policy {
        return .{ .ttl_ms = cfg.Policy.model_refresh_ttl_ms, .cooldown_ms = cfg.Policy.model_refresh_cooldown_ms };
    }

    fn metadataNow(self: *const Session) u64 {
        return self.metadata_wall_ms orelse metadata.wallNow(self.io);
    }

    fn metadataTick(self: *const Session) i64 {
        return self.metadata_awake_ms orelse @as(i64, @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds()));
    }

    fn startMetadata(self: *Session, requested: u8, manual: bool) !void {
        try self.guardSelection();
        if (self.metadata_job != null) return error.MetadataRefreshBusy;
        if (requested == 0) return error.NoOfficialProvider;
        const job = try self.allocator.create(MetadataJob);
        job.* = .{ .allocator = self.allocator, .io = self.io, .fetch = self.metadata_fetch, .dev_fetch = self.metadata_dev_fetch, .manual = manual, .started_ms = @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds()), .credential_revisions = self.credential_revisions };
        errdefer job.destroy();
        // Claim before credential lookup: unrelated unavailable aliases must
        // neither gate the public source nor consume fresh official credentials.
        // Claim before launching: first-run failures/timeouts must not create an
        // automatic retry on every start, and concurrent sessions share the claim.
        var claim = try metadata.claimAt(&self.store.root, requested | metadata.dev_bit, manual, self.metadataNow(), self.refreshPolicy());
        defer claim.cache.deinit(self.allocator);
        // A successful claim means storage is a valid current-format cache again,
        // so an earlier unreadable-cache block no longer applies. Failures above
        // return before this point and keep the cadence disabled.
        self.metadata_blocked = false;
        self.metadata_cache.refresh = claim.cache.refresh;
        job.requested = claim.mask;
        job.generations = claim.generations;
        for (ProviderId.all) |id| {
            // Codex borrows an OAuth request credential below, never a key.
            if (id == .openai_codex) continue;
            const index: usize = @intCast(@backingInt(id));
            if (claim.mask & metadata.bit(id) != 0) job.keys[index] = self.keyFor(id) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null, // Durable failed attempt; never fetch with a null key.
            };
        }
        self.prepareCodexMetadata(job) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {}, // No exact alias/login or local store: this source is skipped.
        };
        if (claim.mask == 0) {
            job.destroy();
            return;
        }
        if (claim.mask & metadata.provider_mask != 0)
            job.future = try std.Io.concurrent(self.io, MetadataJob.run, .{job});
        if (claim.mask & metadata.dev_bit != 0) {
            job.dev_started_ms = @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds());
            job.dev_future = try std.Io.concurrent(self.io, MetadataJob.runDev, .{job});
        }
        self.metadata_job = job;
        self.metadata_login_pending &= ~claim.mask;
        self.metadata_notice = null;
    }

    /// Reuse a joined official slot after a login while the independent public
    /// source is still running. No public task is cancelled or restarted here.
    fn restartOfficialMetadata(self: *Session, job: *MetadataJob, requested: u8) !void {
        std.debug.assert(job.future == null and job.official_published);
        var keys: [ProviderId.all.len]?[]u8 = @splat(null);
        var transferred = false;
        defer if (!transferred) {
            for (keys) |key| if (key) |bytes| {
                std.crypto.secureZero(u8, bytes);
                self.allocator.free(bytes);
            };
        };
        var claim = try metadata.claimAt(&self.store.root, requested, true, self.metadataNow(), self.refreshPolicy());
        defer claim.cache.deinit(self.allocator);
        for (ProviderId.all) |id| {
            // Codex is repopulated from its own Manager after this join.
            if (id == .openai_codex) continue;
            if (claim.mask & metadata.bit(id) != 0) keys[@intCast(@backingInt(id))] = self.keyFor(id) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
        }
        const previous_mask = job.requested;
        const previous_listing = job.listing;
        const previous_succeeded = job.succeeded;
        const previous_started = job.started_ms;
        const previous_revisions = job.credential_revisions;
        const previous_generations = job.generations;
        job.wipeKeys();
        // The official future is joined, so the previous exact alias, Manager
        // and cancellation are released before a fresh source is prepared.
        job.releaseCodex();
        job.keys = keys;
        transferred = true;
        errdefer {
            job.wipeKeys();
            job.releaseCodex();
            job.requested = previous_mask;
            job.listing = previous_listing;
            job.succeeded = previous_succeeded;
            job.started_ms = previous_started;
            job.credential_revisions = previous_revisions;
            job.generations = previous_generations;
            job.official_published = true;
        }
        job.requested = claim.mask | (previous_mask & metadata.dev_bit);
        try self.prepareCodexMetadata(job);
        // Restart replaces official ownership only; the public task keeps its
        // independent durable claim even if another session has since claimed.
        for (0..ProviderId.all.len) |index| if (claim.mask & (@as(u8, 1) << @intCast(index)) != 0) {
            job.generations[index] = claim.generations[index];
        };
        job.listing = .{};
        job.succeeded = 0;
        job.done.store(false, .release);
        job.credential_revisions = self.credential_revisions;
        job.official_published = false;
        job.started_ms = @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds());
        job.future = try std.Io.concurrent(self.io, MetadataJob.run, .{job});
        var old_listing = previous_listing;
        old_listing.deinit(self.allocator);
        job.manual = true;
        self.metadata_cache.refresh = claim.cache.refresh;
        self.metadata_login_pending &= ~claim.mask;
    }

    fn memoryViewChanged(self: *Session, view: @import("../core/memory_status.zig").View) bool {
        const changed = !std.meta.eql(self.last_memory_view, view);
        self.last_memory_view = view;
        return changed;
    }

    /// Owner polling never waits for network. Notice publication only dirties
    /// presentation; the active Runtime budget stays frozen until selection.
    fn pollModels(raw: *anyopaque, reported_idle: bool) bool {
        const self: *Session = @ptrCast(@alignCast(raw));
        const idle = reported_idle and !self.owner_task_active;
        const memory_view = if (self.app) |app| app.memoryView() else @import("../core/memory_status.zig").View{};
        const memory_changed = self.memoryViewChanged(memory_view);
        const subagent_view = if (self.app) |app| app.subagentView() else @import("../core/subagent_status.zig").View{};
        const subagent_changed = !@import("../core/subagent_status.zig").View.eql(self.last_subagent_view, subagent_view);
        if (subagent_changed) {
            if (subagent_view.clone(self.allocator)) |copy| {
                self.last_subagent_view.deinitOwned(self.allocator);
                self.last_subagent_view = copy;
            } else |_| {}
        }
        const login_changed = self.pollCodexLogin() catch false;
        const default_changed = (self.completeInitialDefault(idle) catch false) or memory_changed or subagent_changed or login_changed;
        if (self.metadata_job) |job| {
            official_pending: {
                if (job.future) |*future| {
                    if (job.done.load(.acquire)) {
                        future.await(self.io);
                    } else if (std.Io.Clock.awake.now(self.io).toMilliseconds() - job.started_ms >= official_metadata_timeout_ms) {
                        // Stop the borrowed credential acquisition/listing first;
                        // the join below owns both waits.
                        job.codex_cancel.cancel();
                        future.cancel(self.io);
                    } else break :official_pending;
                    job.future = null;
                    job.wipeKeys(); // Also handles cancellation before the worker starts.
                    // The worker is joined, so its Manager/alias can be released;
                    // a queued login restart prepares a fresh source of its own.
                    job.releaseCodex();
                }
            }
            dev_pending: {
                if (job.dev_future) |*future| {
                    if (job.dev_done.load(.acquire)) {
                        future.await(self.io);
                    } else if (std.Io.Clock.awake.now(self.io).toMilliseconds() - job.dev_started_ms >= models_dev_timeout_ms) {
                        future.cancel(self.io);
                    } else break :dev_pending;
                    job.dev_future = null;
                }
            }
            if (!idle) return default_changed;
            if (job.future == null and job.official_published and job.dev_future != null and self.metadata_login_pending != 0) {
                const requested = self.metadata_login_pending;
                self.restartOfficialMetadata(job, requested) catch {
                    self.metadata_login_pending &= ~requested; // One attempt per login, never a tight retry loop.
                    self.metadata_notice = job.failure_notice orelse "Login saved; official model refresh failed, previous list kept";
                };
                return true;
            }
            const finished = job.future == null and job.dev_future == null;
            defer if (finished) {
                self.metadata_job = null;
                job.destroy();
            };
            const official_ready = job.future == null and !job.official_published;
            const dev_ready = job.dev_future == null and !job.dev_published;
            if (!official_ready and !dev_ready) return default_changed;
            var listing: metadata.Listing = .{};
            defer listing.deinit(self.allocator);
            var succeeded: u8 = 0;
            if (official_ready) {
                listing.directory_mask = job.listing.directory_mask;
                listing.dev_done = job.listing.dev_done;
                listing.directory = job.listing.directory.clone(self.allocator) catch {
                    self.metadata_notice = job.publicationFailed("Metadata cache could not be saved; previous values kept");
                    return true;
                };
                // Filtering is independent of automatic login refresh. Even
                // with auto refresh disabled, a manual job may use an old key.
                succeeded = job.succeeded;
                for (ProviderId.all) |id| {
                    const index: usize = @intCast(@backingInt(id));
                    if (job.credential_revisions[index] != self.credential_revisions[index]) succeeded &= ~metadata.bit(id);
                }
                job.succeeded = succeeded;
                job.official_published = true;
            }
            if (dev_ready) {
                job.dev_published = true;
                metadata.mergeDev(self.allocator, &listing, &job.dev_listing) catch {
                    self.metadata_notice = job.publicationFailed("Metadata cache could not be saved; previous values kept");
                    return true;
                };
            }
            const publication = metadata.commitClaimedAt(&self.store.root, succeeded, listing, job.generations, self.metadataNow()) catch {
                self.metadata_notice = job.publicationFailed("Metadata cache could not be saved; previous values kept");
                return true;
            };
            if (official_ready) job.succeeded = publication.accepted & metadata.provider_mask;
            succeeded = publication.accepted & metadata.provider_mask;
            if (dev_ready and publication.accepted & metadata.dev_bit == 0) {
                listing.dev_done = false;
                job.dev_listing.dev_done = false;
            }
            var previous = self.metadata_cache;
            self.metadata_cache = publication.cache;
            const models = self.buildModels(self.global_config.?.value) catch {
                self.metadata_cache.deinit(self.allocator);
                self.metadata_cache = previous;
                self.metadata_notice = job.publicationFailed("Metadata display could not be updated; previous values kept");
                return true;
            };
            const decision_models = self.buildDecisionModels(self.global_config.?.value) catch {
                self.freeDisplayModels(models);
                self.metadata_cache.deinit(self.allocator);
                self.metadata_cache = previous;
                self.metadata_notice = job.publicationFailed("Metadata display could not be updated; previous values kept");
                return true;
            };
            const image_models = self.buildImageModels(self.global_config.?.value) catch {
                self.freeDisplayModels(models);
                self.freeDisplayModels(decision_models);
                self.metadata_cache.deinit(self.allocator);
                self.metadata_cache = previous;
                self.metadata_notice = job.publicationFailed("Metadata display could not be updated; previous values kept");
                return true;
            };
            previous.deinit(self.allocator);
            self.freeDisplayModels(self.display_models);
            self.freeDisplayModels(self.display_decision_models);
            self.freeDisplayModels(self.display_image_models);
            self.display_models = models;
            self.display_decision_models = decision_models;
            self.display_image_models = image_models;
            _ = self.completeInitialDefault(idle) catch false;
            const official_requested = job.requested & metadata.provider_mask;
            self.metadata_notice = if (!job.manual) null else if (job.failure_notice) |notice| notice else if (!finished)
                (if (job.dev_future != null)
                    (if (succeeded != 0) "Official metadata updated; models.dev refresh still running" else "Official metadata failed or became stale; models.dev refresh still running")
                else
                    (if (listing.dev_done) "models.dev updated; official metadata refresh still running" else "models.dev refresh failed; official metadata refresh still running"))
            else if (official_requested == 0)
                (if (job.dev_listing.dev_done) public_refresh_success else "models.dev metadata refresh failed; cached/default values kept")
            else if (job.succeeded == 0)
                "Official metadata refresh failed; cached/default values kept"
            else if (job.succeeded != official_requested)
                "Official metadata partly refreshed; failed sources kept cached/default values"
            else if (job.requested & metadata.dev_bit != 0 and !job.dev_listing.dev_done)
                "Official model list refreshed; models.dev metadata refresh failed"
            else
                official_refresh_success;
            return true;
        }
        if (idle and self.metadata_login_pending != 0) {
            const requested = self.metadata_login_pending;
            self.metadata_login_pending = 0; // One attempt per successful login, not a retry loop.
            self.startMetadata(requested, true) catch {
                self.metadata_notice = "Login saved; official model refresh failed, previous list kept";
            };
            return true;
        }
        if (!idle or !self.metadata_auto or self.metadata_blocked) return default_changed;
        const tick = self.metadataTick();
        if (tick < self.metadata_next_check_ms) return default_changed;
        self.metadata_next_check_ms = tick + 60000;
        const configured = self.configuredMask(self.global_config.?.value);
        if (configured != 0 and metadata.eligible(&self.metadata_cache, configured | metadata.dev_bit, self.metadataNow(), self.refreshPolicy()) != 0) {
            // Recheck eligibility under the cache lock before any worker launch.
            // Failed launches retain their claim; local errors retry only on cadence.
            self.startMetadata(configured, false) catch {};
        }
        return default_changed;
    }

    fn allowsCustomModels(provider: cfg.Provider) bool {
        return provider.kind == null or ProviderId.fromUrl(provider.base_url) == null;
    }

    // Presence only: never copy credentials into presentation state or probe an
    // endpoint. An empty literal or environment value is not a local login.
    fn isCodexProvider(provider: cfg.Provider) bool {
        return provider.kind == .openai_codex and std.mem.eql(u8, provider.base_url, ProviderId.openai_codex.baseUrl());
    }

    /// Authenticated discovery requires the exact official URL and a typed
    /// OAuth declaration; a bare API key never becomes a Codex source.
    fn codexMetadataProvider(provider: cfg.Provider) bool {
        return provider.codex_oauth != null and ProviderId.fromUrl(provider.base_url) == ProviderId.openai_codex;
    }

    fn hasLocalCredential(self: *const Session, provider: cfg.Provider) bool {
        if (isCodexProvider(provider)) return provider.codex_oauth != null;
        if (provider.api_key) |key| if (key.len != 0) return true;
        if (provider.api_key_env.len != 0) {
            if (self.environ.get(provider.api_key_env)) |key| return key.len != 0;
        }
        return false;
    }

    fn configuredMask(self: *const Session, global: cfg.Config) u8 {
        var mask: u8 = 0;
        if (global.registry) |registry| {
            for (registry.providers) |provider| {
                const id = ProviderId.fromUrl(provider.connection.base_url) orelse continue;
                if (self.hasLocalCredential(provider.connection)) mask |= metadata.bit(id);
            }
            return mask;
        }
        return mask;
    }

    fn freeDisplayModel(self: *const Session, model: cfg.Model) void {
        self.allocator.free(model.name);
        if (model.reasoning_effort) |effort| self.allocator.free(effort);
        if (model.reasoning) |declaration| {
            inline for (@typeInfo(thinking.LevelMap).@"struct".field_names) |field| {
                if (@field(declaration.map, field)) |wire| self.allocator.free(wire);
            }
        }
    }

    fn freeDisplayModels(self: *const Session, models: []cfg.Model) void {
        for (models) |model| self.freeDisplayModel(model);
        self.allocator.free(models);
    }

    fn appendDisplayModel(self: *Session, models: *std.ArrayList(cfg.Model), model: cfg.Model) !void {
        var owned = model;
        owned.name = try self.allocator.dupe(u8, model.name);
        owned.reasoning_effort = null;
        owned.reasoning = null;
        errdefer self.freeDisplayModel(owned);
        if (model.reasoning_effort) |effort| owned.reasoning_effort = try self.allocator.dupe(u8, effort);
        if (model.reasoning) |declaration| {
            owned.reasoning = declaration;
            owned.reasoning.?.map = .{};
            inline for (@typeInfo(thinking.LevelMap).@"struct".field_names) |field| {
                if (@field(declaration.map, field)) |wire| {
                    @field(owned.reasoning.?.map, field) = try self.allocator.dupe(u8, wire);
                }
            }
        }
        try models.append(self.allocator, owned);
    }

    /// The returned rows own every string. Session moves, cache replacement and
    /// config-arena release cannot invalidate a published candidate snapshot.
    fn buildModels(self: *Session, global: cfg.Config) ![]cfg.Model {
        var models: std.ArrayList(cfg.Model) = .empty;
        errdefer {
            for (models.items) |model| self.freeDisplayModel(model);
            models.deinit(self.allocator);
        }
        if (global.registry) |registry| {
            for (registry.providers) |provider| {
                for (provider.models) |profile| try self.appendRegistryCandidate(&models, global, provider.name, profile.name);
                const id = ProviderId.fromUrl(provider.connection.base_url) orelse continue;
                const found = &self.metadata_cache.directory;
                for (found.rows[0..found.count], 0..) |row, index| {
                    if (row.provider == id and row.available == true)
                        try self.appendRegistryCandidate(&models, global, provider.name, found.name(index));
                }
                if (!metadata.hasDirectory(&self.metadata_cache, id)) for (catalog.entries) |entry| {
                    if (entry.provider == id and metadata.findEntry(&self.metadata_cache, entry.selector) != null)
                        try self.appendRegistryCandidate(&models, global, provider.name, entry.model.name);
                };
            }
        }
        if (global.registry) |registry| {
            if (registry.providers.len > self.display_providers.len) self.display_providers = try self.allocator.realloc(self.display_providers, registry.providers.len);
        }
        if (models.items.len > self.display_origins.len) self.display_origins = try self.allocator.realloc(self.display_origins, models.items.len);
        if (models.items.len > self.display_disabled.len) self.display_disabled = try self.allocator.realloc(self.display_disabled, models.items.len);
        return models.toOwnedSlice(self.allocator);
    }

    /// Resolve the same catalog with auxiliary caps before filtering. A small
    /// reviewer window must not become unusable due to the main safety margin.
    fn buildDecisionModels(self: *Session, global: cfg.Config) ![]cfg.Model {
        var independent = global;
        independent.limits = (global.decision orelse cfg.DecisionConfig{ .model = "" }).modelLimits(global.limits.request_timeout_ms);
        const models = try self.buildModels(independent);
        var count: usize = 0;
        for (models) |model| {
            const ref = cfg.splitDefault(model.name) catch unreachable;
            const provider = independent.registry.?.find(ref.provider).?;
            if (decision_selection.genericCandidate(independent, model) and self.hasLocalCredential(provider.connection)) {
                models[count] = model;
                count += 1;
            } else self.freeDisplayModel(model);
        }
        errdefer {
            for (models[0..count]) |model| self.freeDisplayModel(model);
            self.allocator.free(models);
        }
        return self.allocator.realloc(models, count);
    }

    /// Image has a fixed documented Chat request; it does not borrow the main
    /// model's generative protocol/window eligibility or low-price budget.
    fn buildImageModels(self: *Session, global: cfg.Config) ![]cfg.Model {
        var models: std.ArrayList(cfg.Model) = .empty;
        errdefer {
            for (models.items) |model| self.freeDisplayModel(model);
            models.deinit(self.allocator);
        }
        if (global.registry) |registry| for (registry.providers) |provider| {
            if (!self.hasLocalCredential(provider.connection) or
                !image_selection.available(global, &self.metadata_cache, provider.name)) continue;
            const name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ provider.name, image.model_id });
            defer self.allocator.free(name);
            try self.appendDisplayModel(&models, .{ .name = name, .protocol = .chat, .context_tokens = 0 });
        };
        return models.toOwnedSlice(self.allocator);
    }

    fn appendRegistryCandidate(self: *Session, models: *std.ArrayList(cfg.Model), global: cfg.Config, provider: []const u8, raw_id: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const selector = try std.fmt.allocPrint(a, "{s}/{s}", .{ provider, raw_id });
        for (models.items) |model| if (std.mem.eql(u8, model.name, selector)) return;
        const resolved = model_resolver.resolve(a, global, &self.metadata_cache, provider, raw_id, false) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try self.appendDisplayModel(models, .{ .name = selector, .context_tokens = 0, .protocol = .auto });
                return;
            },
        };
        var model = resolved.model;
        model.name = selector;
        try self.appendDisplayModel(models, model);
    }

    fn aliasFor(self: *Session, config: cfg.Config) !?[]u8 {
        if (config.registry != null) {
            const provider = config.selected_provider orelse return null;
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ provider, config.model.name });
        }
        return null;
    }

    fn applyPreference(self: *Session, config: *cfg.Config, wanted: ?presentation.ReasoningEffort, from_global: bool) ?[]const u8 {
        self.applyReasoningMetadata(config);
        const override = from_global and if (config.registry) |registry| registry.reasoning_effort != null else false;
        return reasoning_defaults.apply(config, wanted, override);
    }

    fn keyFor(self: *Session, id: ProviderId) ![]u8 {
        if (id == .openai_codex) return error.ApiKeyNotFound;
        const global = self.global_config.?.value;
        if (global.registry) |registry| {
            // Explicit selected connection wins; a missing env is not permission
            // to fall back to another alias or a legacy credential slot.
            if (self.mutableConfig().selected_provider) |name| {
                if (registry.find(name)) |provider| if (ProviderId.fromUrl(provider.connection.base_url) == id) {
                    var local = global;
                    local.provider = provider.connection;
                    return cfg.resolveApiKey(self.allocator, local, self.environ);
                };
            }
            for (registry.providers) |provider| if (ProviderId.fromUrl(provider.connection.base_url) == id) {
                var local = global;
                local.provider = provider.connection;
                return cfg.resolveApiKey(self.allocator, local, self.environ);
            };
            return error.ApiKeyNotFound;
        }
        return error.ApiKeyNotFound;
    }

    fn mutableConfig(self: *Session) *cfg.Config {
        return if (self.app) |app| &app.config.value else &self.pending.?.value;
    }

    /// Codex metadata reuses keyFor's protected latest-config lookup: the
    /// selected connection wins and a missing login never falls back to another
    /// alias. Only the exact alias is copied; the token stays in its Store.
    fn codexMetadataAlias(self: *Session) ?[]const u8 {
        const registry = self.global_config.?.value.registry orelse return null;
        if (self.mutableConfig().selected_provider) |name| {
            if (registry.find(name)) |provider| if (codexMetadataProvider(provider.connection)) return provider.name;
        }
        for (registry.providers) |provider| if (codexMetadataProvider(provider.connection)) return provider.name;
        return null;
    }

    /// Prepare the Codex source only when Codex itself was claimed and its
    /// typed login is present. Nothing is prepared for an API-key provider.
    fn prepareCodexMetadata(self: *Session, job: *MetadataJob) !void {
        if (job.requested & metadata.bit(.openai_codex) == 0) return;
        const name = self.codexMetadataAlias() orelse return;
        var manager: ?*codex_oauth.Manager = null;
        if (self.metadata_codex_source == null) {
            const home = self.environ.get("HOME") orelse return error.MissingHome;
            manager = codex_oauth.Manager.init(self.allocator, self.io, home, self.environ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null, // Unavailable local auth storage gains no source.
            };
        }
        const alias = self.allocator.dupe(u8, name) catch |err| {
            if (manager) |owned| owned.deinit();
            return err;
        };
        job.codex_manager = manager;
        job.codex_source = self.metadata_codex_source;
        job.codex_alias = alias;
        job.codex_fetch = self.metadata_codex_fetch;
        job.codex_cancel = .{};
    }

    fn guardSelection(self: *Session) !void {
        if (self.read_only) return error.ResumeReadOnly;
        if (self.owner_task_active) return error.Busy;
        if (self.app) |app| {
            if (app.runtime.busy.load(.acquire)) return error.Busy;
            if (app.runtime.poisoned) return error.UnsafeToContinue;
        }
    }

    /// Only conversations without user data change startup defaults. Machine
    /// prefixes do not count; failed first turns and lossy summaries still do.
    /// Prepare an independently owned baseline before any live-state mutation.
    fn selectionDefaults(self: *Session, candidate: cfg.Config) !?std.json.Parsed(cfg.Config) {
        if (self.loaded_checkpoint != null) return null;
        if (self.app) |app| if (hasConversationData(app.runtime.messages())) return null;
        var owned = try cfg.clone(self.allocator, self.global_config.?.value);
        errdefer cfg.release(&owned);
        try cfg.setRegistryDefault(owned.arena.allocator(), &owned.value, candidate.selected_provider orelse return error.UnknownProvider, candidate.model.name);
        return owned;
    }

    /// Last fallible step of selection; a conflict/write failure publishes
    /// neither defaults nor Runtime state. Consumes the candidate on success.
    fn persistSelectionDefaults(self: *Session, candidate: *?std.json.Parsed(cfg.Config)) !void {
        if (candidate.*) |value| {
            try self.store.save(value.value);
            if (self.global_config) |*old| cfg.release(old);
            self.global_config = value;
            candidate.* = null;
        }
    }

    fn setSetting(raw: *anyopaque, setting: tui.Connection.Setting, enabled: bool) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        // Persist only the owned declaration, never resolved/history metadata.
        var declaration = try cfg.clone(self.allocator, self.global_config.?.value);
        defer cfg.release(&declaration);
        switch (setting) {
            .low_price_input => declaration.value.limits.low_price_input = enabled,
            .decision_enabled => {
                if (declaration.value.decision) |*value| value.enabled = enabled else return error.DecisionNotConfigured;
            },
        }
        try self.persistSettings(&declaration, .none);
    }

    fn setPreference(raw: *anyopaque, key: settings_preferences.Key, value: ?u32) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        var declaration = try cfg.clone(self.allocator, self.global_config.?.value);
        defer cfg.release(&declaration);
        try settings_preferences.apply(&declaration.value, key, value);
        try self.persistSettings(&declaration, .none);
    }

    fn setDecision(raw: *anyopaque, choice: tui.Connection.DecisionChoice) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        // Revalidate at the owner, not merely in a previously drawn picker.
        // No unknown raw IDs, other aliases or now-missing credentials may save.
        switch (choice) {
            .model => |name| {
                const ref = try cfg.splitDefault(name);
                const registry = self.global_config.?.value.registry orelse return error.MissingRegistry;
                const provider = registry.find(ref.provider) orelse return error.UnknownProvider;
                if (!self.hasLocalCredential(provider.connection)) return error.ApiKeyNotFound;
                var found = false;
                // Rebuild membership from current metadata/declaration and
                // credentials rather than trusting a stale published row.
                const candidates = try self.buildDecisionModels(self.global_config.?.value);
                defer self.freeDisplayModels(candidates);
                for (candidates) |model| {
                    if (std.mem.eql(u8, name, model.name) and decision_selection.genericCandidate(self.global_config.?.value, model)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnknownDecisionModel;
            },
            else => {},
        }
        var declaration = try cfg.clone(self.allocator, self.global_config.?.value);
        defer cfg.release(&declaration);
        if (!try decision_selection.apply(declaration.arena.allocator(), &declaration.value, switch (choice) {
            .off => .off,
            .model => |name| .{ .model = name },
        })) return;
        try self.persistSettings(&declaration, .decision);
    }

    fn setImage(raw: *anyopaque, choice: tui.Connection.DecisionChoice) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        switch (choice) {
            .model => |name| {
                const candidates = try self.buildImageModels(self.global_config.?.value);
                defer self.freeDisplayModels(candidates);
                var found = false;
                for (candidates) |model| if (std.mem.eql(u8, name, model.name)) {
                    found = true;
                    break;
                };
                if (!found) return error.UnknownImageModel;
            },
            .off => {},
        }
        var declaration = try cfg.clone(self.allocator, self.global_config.?.value);
        defer cfg.release(&declaration);
        if (!try image_selection.apply(declaration.arena.allocator(), &declaration.value, switch (choice) {
            .off => .off,
            .model => |name| .{ .model = name },
        })) return;
        try self.persistSettings(&declaration, .image_model);
    }

    /// Save is the final fallible operation. Swapping with the caller keeps its
    /// deferred release responsible for wiping the previous global declaration.
    fn setProxyModel(raw: *anyopaque, name: []const u8, enabled: bool) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        // Address/port belong to the global declaration; never invent a route.
        if (self.global_config.?.value.proxy == null) return error.ProxyNotConfigured;
        var declaration = try cfg.clone(self.allocator, self.global_config.?.value);
        defer cfg.release(&declaration);
        // Duplicate add and absent removal are intentional no-write no-ops.
        if (!try proxy_selection.apply(declaration.arena.allocator(), &declaration.value, name, enabled)) return;
        if (enabled) try self.validateProxyMember(name);
        try self.persistSettings(&declaration, .proxy_models);
    }

    /// Settings-editor endpoint save. Empty input disables the proxy; a new
    /// host/port keeps the current exact allowlist. The active primary client
    /// stays frozen, while auxiliary owners follow the latest declaration.
    fn setProxyAddress(raw: *anyopaque, address: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        var declaration = try cfg.clone(self.allocator, self.global_config.?.value);
        defer cfg.release(&declaration);
        // Identical endpoint and already-off are intentional no-write no-ops.
        if (!try proxy_selection.applyAddress(declaration.arena.allocator(), &declaration.value, address)) return;
        try self.persistSettings(&declaration, .proxy_models);
    }

    /// Owner-side revalidation: the exact declared/available row, its own alias
    /// and a present local credential. SystemOne and unknown windows are real
    /// declarations, so generic auxiliary eligibility must not filter them.
    fn validateProxyMember(self: *Session, name: []const u8) !void {
        const global = self.global_config.?.value;
        const reference = try cfg.splitDefault(name);
        const provider = (global.registry orelse return error.MissingRegistry).find(reference.provider) orelse return error.UnknownProvider;
        if (!self.hasLocalCredential(provider.connection)) return error.ApiKeyNotFound;
        const candidates = try self.buildModels(global);
        defer self.freeDisplayModels(candidates);
        for (candidates) |model| if (std.mem.eql(u8, name, model.name)) return;
        return error.UnknownProxyModel;
    }

    fn persistSettings(self: *Session, declaration: *std.json.Parsed(cfg.Config), refresh: App.SettingsRefresh) !void {
        try cfg.validate(declaration.value);
        var prepared: ?App.SettingsReplacement = if (self.app) |app| try app.prepareSettingsRefresh(declaration.value, self.environ, refresh) else null;
        defer if (prepared) |*value| value.deinit();
        var pending: ?std.json.Parsed(cfg.Config) = if (self.app == null)
            // A pending snapshot is not an active route, so an explicit proxy
            // save may update it; ordinary saves keep its previous route.
            try proxy_selection.pendingClone(self.allocator, self.pending.?.value, declaration.value, refresh == .proxy_models)
        else
            null;
        defer if (pending) |*value| cfg.release(value);
        try self.store.save(declaration.value);
        std.mem.swap(std.json.Parsed(cfg.Config), &self.global_config.?, declaration);
        if (prepared) |*value| {
            self.app.?.installSettings(value);
            self.initial_context = self.app.?.runtime.contextSnapshot();
        } else {
            std.mem.swap(std.json.Parsed(cfg.Config), &self.pending.?, &pending.?);
        }
        self.publishCheckpoint();
    }

    fn selectModel(raw: *anyopaque, name: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        return self.selectRegistryModel(name);
    }

    fn selectRegistryModel(self: *Session, selector: []const u8) !void {
        const previous = self.mutableConfig().*;
        // Even a frozen historical SystemOne selection is display-only. Never
        // let the retained-selection shortcut activate it as primary chat.
        if (previous.model.protocol == .systemone and
            (std.mem.eql(u8, selector, previous.model.name) or
                (self.selected_alias != null and std.mem.eql(u8, selector, self.selected_alias.?))))
            return error.SystemOneNotChatModel;
        const raw_current = std.mem.eql(u8, selector, previous.model.name);
        const alias_current = self.selected_alias != null and std.mem.eql(u8, selector, self.selected_alias.?);
        const revision_changed = if (ProviderId.fromUrl(previous.provider.base_url)) |id|
            self.active_revision != self.credential_revisions[@intCast(@backingInt(id))]
        else
            self.active_custom_revision != self.custom_credential_revision;
        const explicit_current = (previous.model.reasoning_source == .explicit and
            (previous.model.reasoning != null or previous.model.reasoning_effort != null)) or
            (previous.model.output_source == .explicit and previous.model.output_tokens != null);
        const retained = !previous.selection_pending and (raw_current or (alias_current and (revision_changed or explicit_current)));
        if (retained and !revision_changed) if (self.app) |app| {
            // Reselecting the exact active model is not an account switch:
            // keep its native replay, transport and latest actual usage.
            self.initial_context = app.runtime.contextSnapshot();
            self.publishCheckpoint();
            return;
        };
        const qualified_slash: ?usize = if (std.mem.findScalar(u8, selector, '/')) |slash|
            if (self.global_config.?.value.registry.?.find(selector[0..slash]) != null) slash else null
        else
            null;
        const provider_name = if (retained) previous.selected_provider orelse return error.UnknownProvider else if (qualified_slash) |slash|
            selector[0..slash]
        else
            previous.selected_provider orelse return error.UnknownProvider;
        const raw_id = if (retained) previous.model.name else if (qualified_slash) |slash| selector[slash + 1 ..] else selector;
        var owned = try cfg.clone(self.allocator, self.global_config.?.value);
        var moved = false;
        defer if (!moved) cfg.release(&owned);
        var context_official = self.active_context_official;
        var notice = self.settings_notice;
        var wanted = self.preferred_effort;
        if (retained) {
            // Clone ACTUAL frozen options, not a new catalog model. Rebind only
            // the key source from the independently saved declaration.
            const actual = try cfg.clone(self.allocator, previous);
            cfg.release(&owned);
            owned = actual;
            const declaration = self.global_config.?.value.registry.?.find(provider_name) orelse return error.UnknownProvider;
            // Keep borrowed key pointers OUT of the object we will release:
            // release() wipes its primary key, not merely its arena storage.
            var candidate = owned.value;
            candidate.provider = declaration.connection;
            const rebound = try cfg.clone(self.allocator, candidate);
            cfg.release(&owned);
            owned = rebound;
            if (owned.value.model.protocol == .auto) if (self.app) |app| {
                if (app.runtime.messages().len != 0) owned.value.model.protocol = app.runtime.selector.effective();
            };
        } else {
            const resolved = try model_resolver.resolve(owned.arena.allocator(), owned.value, &self.metadata_cache, provider_name, raw_id, false);
            if (resolved.model.protocol == .systemone) return error.SystemOneNotChatModel;
            model_resolver.apply(&owned.value, resolved);
            context_official = resolved.context_official;
            wanted = reasoning_defaults.preference(owned.value);
            notice = self.applyPreference(&owned.value, wanted, true);
        }
        moved = true;
        try self.publishRegistryModel(owned, context_official, notice, !retained, wanted);
    }

    /// Consumes owned on every path. All preparation and disk writes precede
    /// publication; runtime/history are never partly changed on failure.
    fn publishRegistryModel(self: *Session, parsed: std.json.Parsed(cfg.Config), context_official: bool, notice: ?[]const u8, update_default: bool, wanted: ?presentation.ReasoningEffort) !void {
        var owned = parsed;
        var consumed = false;
        defer if (!consumed) cfg.release(&owned);
        if (owned.value.model.protocol == .systemone) return error.SystemOneNotChatModel;
        const alias = try self.aliasFor(owned.value);
        errdefer if (alias) |value| self.allocator.free(value);
        const pending_selection = if (self.loaded_checkpoint != null) try selections.capture(owned.value) else null;
        var defaults = if (update_default) try self.selectionDefaults(owned.value) else null;
        defer if (defaults) |*value| cfg.release(value);
        const models = try self.buildModels(if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.freeDisplayModels(models);
        const decision_models = try self.buildDecisionModels(if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.freeDisplayModels(decision_models);
        const image_models = try self.buildImageModels(if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.freeDisplayModels(image_models);
        var replacement: ?*App.ConnectionReplacement = null;
        var initial: ?*App = null;
        errdefer if (replacement) |value| value.deinit();
        errdefer if (initial) |value| value.deinit();
        const codex = isCodexProvider(owned.value.provider);
        const key: ?[]u8 = if (codex) null else cfg.resolveApiKey(self.allocator, owned.value, self.environ) catch |err| blk: {
            if ((err == error.ApiKeyNotFound or err == error.InvalidApiKey) and self.app == null) break :blk null;
            return err;
        };
        const credential_available = if (codex) self.hasLocalCredential(owned.value.provider) else key != null;
        if (codex and !credential_available and self.app != null) return error.ApiKeyNotFound;
        defer if (key) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        };
        if (credential_available) {
            if (self.app) |app| {
                consumed = true; // App preparation consumes even on error.
                replacement = try app.prepareConnection(owned, self.environ);
            } else {
                // Clone below owns any declaration borrowed from the cache.
                self.applyInitialDefault(&owned.value, wanted);
                const initial_owned = try cfg.clone(self.allocator, owned.value);
                cfg.release(&owned);
                consumed = true;
                initial = try self.prepareApp(initial_owned);
            }
            if (replacement) |value| value.client.session_id = self.session_id;
        }
        try self.persistSelectionDefaults(&defaults);
        if (replacement) |value| self.app.?.installConnection(value) else {
            if (self.pending) |*value| cfg.release(value);
            self.pending = null;
            if (initial) |value| {
                self.app = value;
                self.last_memory_view = value.memoryView();
            } else {
                self.pending = owned;
                consumed = true;
                if (pending_selection) |snapshot| self.loaded_selection = snapshot;
            }
        }
        if (self.selected_alias) |value| self.allocator.free(value);
        self.selected_alias = alias;
        self.freeDisplayModels(self.display_models);
        self.display_models = models;
        self.freeDisplayModels(self.display_decision_models);
        self.display_decision_models = decision_models;
        self.freeDisplayModels(self.display_image_models);
        self.display_image_models = image_models;
        self.active_context_official = context_official;
        self.preferred_effort = wanted;
        // A replacement is also a new model selection: metadata may arrive
        // after DeepSeek has already initialized its own default.
        if (update_default or initial != null) self.armInitialDefault();
        self.settings_notice = if (self.app == null) "Not logged in; history available, use /login to activate" else notice;
        if (ProviderId.fromUrl(self.mutableConfig().provider.base_url)) |id|
            self.active_revision = self.credential_revisions[@intCast(@backingInt(id))]
        else
            self.active_custom_revision = self.custom_credential_revision;
        if (self.app) |app| {
            self.initial_context = app.runtime.contextSnapshot();
            self.releaseLoadedHistory();
        }
        self.publishCheckpoint();
    }

    fn configureRegistryProvider(self: *Session, id: ProviderId, key: []const u8) !void {
        var baseline = try cfg.clone(self.allocator, self.global_config.?.value);
        defer cfg.release(&baseline);
        const registry = baseline.value.registry.?;
        const active = self.mutableConfig().*;
        var target: ?[]const u8 = null;
        if (active.selected_provider) |name| if (registry.find(name)) |provider| {
            if (ProviderId.fromUrl(provider.connection.base_url) == id) target = provider.name;
        };
        if (target == null) for (registry.providers) |provider| {
            if (ProviderId.fromUrl(provider.connection.base_url) == id) {
                if (target != null) return error.AmbiguousProvider;
                target = provider.name;
            }
        };
        if (target == null) {
            const canonical = id.slug();
            if (registry.find(canonical) != null) return error.ProviderNameConflict;
            const a = baseline.arena.allocator();
            const providers = try a.alloc(cfg.NamedProvider, registry.providers.len + 1);
            @memcpy(providers[0..registry.providers.len], registry.providers);
            providers[registry.providers.len] = .{
                .name = try a.dupe(u8, canonical),
                .connection = catalog.connection(id),
                .models = &.{},
            };
            baseline.value.registry.?.providers = providers;
            target = providers[registry.providers.len].name;
        }
        try self.saveRegistryCredential(baseline.value, target.?, key);
    }

    fn configureRegistryAlias(self: *Session, name: []const u8, key: []const u8) !void {
        try self.saveRegistryCredential(self.global_config.?.value, name, key);
    }

    fn saveRegistryCredential(self: *Session, source: cfg.Config, name: []const u8, key: []const u8) !void {
        var baseline = try cfg.clone(self.allocator, source);
        errdefer cfg.release(&baseline);
        const active = self.mutableConfig().*;
        const id = ProviderId.fromUrl((baseline.value.registry.?.find(name) orelse return error.UnknownProvider).connection.base_url);
        try cfg.setRegistryCredential(baseline.arena.allocator(), &baseline.value, name, key);
        try cfg.validate(baseline.value);
        // Login never changes the global default or the current model selection.
        // Pending startup may activate only its already-resolved exact model.
        var initial: ?*App = null;
        errdefer if (initial) |value| value.deinit();
        if (self.app == null and !active.selection_pending and active.selected_provider != null and std.mem.eql(u8, active.selected_provider.?, name)) {
            var next = active;
            next.registry = baseline.value.registry;
            next.provider = baseline.value.registry.?.find(name).?.connection;
            self.applyInitialDefault(&next, self.preferred_effort);
            initial = try self.prepareApp(try cfg.clone(self.allocator, next));
        }
        const models = try self.buildModels(baseline.value);
        errdefer self.freeDisplayModels(models);
        const decision_models = try self.buildDecisionModels(baseline.value);
        errdefer self.freeDisplayModels(decision_models);
        const image_models = try self.buildImageModels(baseline.value);
        errdefer self.freeDisplayModels(image_models);
        if (self.app) |app| try app.journal.rememberKey(key);
        try self.store.save(baseline.value);
        if (self.global_config) |*old| cfg.release(old);
        self.global_config = baseline;
        if (id) |service| self.credential_revisions[@intCast(@backingInt(service))] +%= 1 else self.custom_credential_revision +%= 1;
        if (initial) |value| {
            if (self.pending) |*old| cfg.release(old);
            self.pending = null;
            self.app = value;
            self.last_memory_view = value.memoryView();
            self.armInitialDefault();
            if (id) |service| self.active_revision = self.credential_revisions[@intCast(@backingInt(service))] else self.active_custom_revision = self.custom_credential_revision;
            self.initial_context = value.runtime.contextSnapshot();
            self.releaseLoadedHistory();
            self.settings_notice = if (self.resumed) session_client.restored_notice else null;
        }
        self.freeDisplayModels(self.display_models);
        self.display_models = models;
        self.freeDisplayModels(self.display_decision_models);
        self.display_decision_models = decision_models;
        self.freeDisplayModels(self.display_image_models);
        self.display_image_models = image_models;
        if (self.metadata_login_auto) if (id) |service| {
            self.metadata_login_pending |= metadata.bit(service);
        };
        if (self.app == null and active.selection_pending)
            self.settings_notice = "Credential saved; saved model unavailable locally, use /model";
        self.publishCheckpoint();
    }

    fn configureProvider(raw: *anyopaque, id: ProviderId, key: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        return self.configureRegistryProvider(id, key);
    }

    fn pendingThinkingConfig(self: *const Session, base: cfg.Config) cfg.Config {
        var result = base;
        if (self.thinking_pending) if (self.app) |app| {
            if (app.thinking_control.get()) |selection| {
                result.model.reasoning_effort = selection.reasoning_effort;
                result.model.reasoning = selection.reasoning;
            }
        };
        return result;
    }

    fn guardEffort(self: *Session) !void {
        if (self.read_only) return error.ResumeReadOnly;
        // Poison is checked at begin and after join; the worker owns it while
        // running, so reading it here would race the worker.
        if (!self.owner_task_active) try self.guardSelection();
    }

    /// Cache-only opt-in: discover a missing map on an explicit effort action,
    /// never replace an already accepted map or re-resolve unrelated budgets.
    fn effortCandidate(self: *const Session, config: cfg.Config) cfg.Config {
        var candidate = config;
        if (candidate.model.reasoning == null)
            metadata.applyReasoning(&self.metadata_cache, &candidate)
        else
            self.applyReasoningMetadata(&candidate);
        return candidate;
    }

    /// Defaults are logical preferences, never authority to invent wire options.
    fn applyInitialDefault(self: *Session, config: *cfg.Config, wanted: ?presentation.ReasoningEffort) void {
        if (self.loaded_checkpoint != null or self.resumed) return;
        var candidate = self.effortCandidate(config.*);
        const capabilities = self.capabilitiesFor(candidate);
        if (!capabilities.known) return;
        if (wanted) |saved|
            candidate.model.reasoning_effort = capabilities.effective(saved.name());
        config.model = candidate.model;
    }

    fn armInitialDefault(self: *Session) void {
        const app = self.app orelse return;
        self.initial_default_pending = self.loaded_checkpoint == null and !self.resumed and
            !app.journal.started and !hasConversationData(app.runtime.messages()) and
            app.config.value.model.reasoning == null and
            app.config.value.model.reasoning_effort == null and self.preferred_effort != null;
    }

    /// One successful adoption, only before the first request/history. Do not
    /// normalize the saved preference: medium can legitimately clamp to high.
    fn completeInitialDefault(self: *Session, idle: bool) !bool {
        if (!self.initial_default_pending or self.read_only) return false;
        const app = self.app orelse return false;
        // Join/idle ownership precedes every read of the mutable journal.
        if (!idle or self.owner_task_active or app.runtime.busy.load(.acquire)) return false;
        const config = &app.config.value;
        if (app.journal.started or hasConversationData(app.runtime.messages()) or
            config.model.reasoning_effort != null or config.model.reasoning != null)
        {
            self.initial_default_pending = false;
            return true;
        }
        var candidate = self.effortCandidate(config.*);
        const capabilities = self.capabilitiesFor(candidate);
        if (!capabilities.known) return false;
        const saved = self.preferred_effort orelse return false;
        candidate.model.reasoning_effort = capabilities.effective(saved.name());
        try cfg.validate(candidate);
        // Cache entries may be replaced on the very next poll. Publish only
        // after all strings have independent active-arena ownership.
        const a = app.config.arena.allocator();
        var map: thinking.LevelMap = .{};
        const fields = @typeInfo(thinking.LevelMap).@"struct".field_names;
        errdefer inline for (fields) |field| {
            if (@field(map, field)) |value| a.free(value);
        };
        var declaration = candidate.model.reasoning.?;
        inline for (fields) |field| {
            if (@field(declaration.map, field)) |value| @field(map, field) = try a.dupe(u8, value);
        }
        declaration.map = map;
        candidate.model.reasoning = declaration;
        config.model = candidate.model;
        app.recordSelection();
        self.initial_default_pending = false;
        if (self.settings_notice) |notice| {
            if (std.mem.eql(u8, notice, "Saved thinking level not applied: model capabilities unknown")) {
                self.settings_notice = if (presentation.ReasoningEffort.fromName(config.model.reasoning_effort) != saved)
                    "Saved thinking level adjusted for this model; preference unchanged"
                else
                    null;
            }
        }
        return true;
    }

    fn cycleEffort(raw: *anyopaque) !presentation.ReasoningEffort {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardEffort();
        const config = self.pendingThinkingConfig(self.mutableConfig().*);
        const current_effort = presentation.ReasoningEffort.fromName(config.model.reasoning_effort);
        const capabilities = self.capabilitiesFor(self.effortCandidate(config));
        const next = capabilities.levels.next(current_effort) orelse {
            if (ProviderId.fromUrl(config.provider.base_url) != null and
                (self.metadata_job != null or self.metadata_login_pending != 0))
                return error.ThinkingCapabilitiesLoading;
            return error.ThinkingCapabilitiesUnknown;
        };
        if (next != current_effort) try setEffort(raw, next);
        return next;
    }

    fn setEffort(raw: *anyopaque, effort: presentation.ReasoningEffort) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardEffort();
        const name = effort.name() orelse return error.InvalidReasoningEffort;
        const config = self.mutableConfig();
        const base = self.pendingThinkingConfig(config.*);
        var candidate = self.effortCandidate(base);
        const capabilities = self.capabilitiesFor(candidate);
        if (!capabilities.levels.contains(effort)) return error.UnsupportedReasoningEffort;
        candidate.model.reasoning_effort = name;
        try cfg.validate(candidate);
        // Cache storage is movable and later refreshes can replace it. Own any
        // newly adopted map in the active configuration's existing arena before
        // the save; failed saves leave the published model untouched.
        const a = if (self.app) |app| app.config.arena.allocator() else self.pending.?.arena.allocator();
        var owned_map: thinking.LevelMap = .{};
        const fields = @typeInfo(thinking.LevelMap).@"struct".field_names;
        errdefer inline for (0..fields.len) |i| {
            if (@field(owned_map, fields[fields.len - 1 - i])) |value| a.free(value);
        };
        if (!sameDeclaration(base.model.reasoning, candidate.model.reasoning)) {
            var declaration = candidate.model.reasoning.?;
            inline for (fields) |field| {
                if (@field(declaration.map, field)) |value| @field(owned_map, field) = try a.dupe(u8, value);
            }
            declaration.map = owned_map;
            candidate.model.reasoning = declaration;
        }
        if (self.owner_task_active) {
            const app = self.app orelse return error.Unavailable;
            app.thinking_control.publish(.{ .reasoning_effort = candidate.model.reasoning_effort, .reasoning = candidate.model.reasoning });
            self.thinking_pending = true;
            self.preferred_effort = effort;
            self.initial_default_pending = false;
            self.settings_error = null;
            self.settings_notice = null;
            return;
        }
        // No effective option, baseline, replay or estimator mutation until
        // the bounded atomic save has succeeded. No fallible work follows it.
        var global = try self.selectionDefaults(candidate);
        defer if (global) |*value| cfg.release(value);
        if (global) |*value| {
            try cfg.setRegistryReasoningEffort(value.arena.allocator(), &value.value, name);
            self.persistSelectionDefaults(&global) catch |err| {
                self.settings_error = err;
                return err;
            };
        }
        config.model = candidate.model;
        self.preferred_effort = effort;
        self.initial_default_pending = false;
        self.settings_error = null;
        self.settings_notice = null;
        if (self.app) |app| app.recordSelection();
        self.publishCheckpoint();
    }

    fn configure(raw: *anyopaque, key: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        const name = self.mutableConfig().selected_provider orelse return error.UnknownProvider;
        try self.configureRegistryAlias(name, key);
    }
};

// New-format fixtures only: no legacy credentials/profiles conversion layer.

fn hasConversationData(messages: []const @import("../core/protocol.zig").Message) bool {
    if (@import("../core/context.zig").hasSummaryPrefix(messages)) return true;
    for (messages) |message| if (message.role != .context) return true;
    return false;
}

/// Read selection out of a checkpoint. A missing lease is the old
/// "no snapshot" error so restore callers keep a stable name.
fn loadSelectionBytes(root: *fs.Root, id: ids.Id) ![]u8 {
    var lease = resume_store.Lease.open(root, id, false) catch |err| switch (err) {
        error.ResumeNotFound, error.FileNotFound => return error.SelectionNotFound,
        else => return err,
    };
    defer lease.deinit();
    return lease.load(root) catch |err| switch (err) {
        error.ResumeNotFound => error.SelectionNotFound,
        else => return err,
    };
}

// Independent async/metadata regressions. These are real disk declarations in
// the llm schema, not legacy Config -> registry conversion helpers. Presets have
// no manual patches so refreshed capabilities remain visible in picker rows.

// Controlled publication stages: both fetches are local and complete before
// polling. A cancellable, data-free future holds the second stage pending; no
// test mutates storage that a fetch worker could still be using.

// These Go fixtures model public reasoning, independently of its listing.
