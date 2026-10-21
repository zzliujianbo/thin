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
const reasoning_defaults = @import("reasoning_defaults.zig");
const thinking = @import("../core/thinking.zig");
const catalog = @import("provider_catalog.zig");
const ProviderId = cfg.providers.Id;
const selections = @import("selection.zig");
const resume_store = @import("resume_store.zig");
const resume_codec = @import("resume_codec.zig");
const checkpoint = @import("../core/checkpoint.zig");
const metadata = @import("model_metadata.zig");
const directory = @import("model_directory.zig");
const model_resolver = @import("model_resolver.zig");
const fs = @import("../platform/filesystem.zig");
const decision_selection = @import("decision_selection.zig");
const image_selection = @import("image_selection.zig");
const image = @import("../core/image.zig");
const settings_preferences = @import("../core/settings.zig");

test {
    _ = @import("llm_session_test.zig");
    _ = @import("global_preferences_test.zig");
    _ = @import("settings_preferences_test.zig");
    _ = @import("decision_model_selection_test.zig");
    _ = @import("image_model_selection_test.zig");
}

const MetadataTokens = [catalog.entries.len]?u32;
const MetadataFetch = *const fn (std.mem.Allocator, std.Io, ProviderId, ?[]const u8) anyerror!metadata.Listing;
const DevFetch = *const fn (std.mem.Allocator, std.Io) anyerror!metadata.Listing;
const official_metadata_timeout_ms = 8000;
const models_dev_timeout_ms = 30000;

/// A prepared actual model is not a fresh catalog choice. Credential swaps
/// preserve its budget, mapping, effective effort and context provenance.
const MetadataJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fetch: MetadataFetch,
    dev_fetch: DevFetch,
    keys: [3]?[]u8 = @splat(null),
    requested: u8 = 0,
    generations: metadata.Generations = @splat(0),
    credential_revisions: [3]u64 = @splat(0),
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

    fn run(self: *MetadataJob) void {
        defer self.done.store(true, .release);
        defer self.wipeKeys();
        for (ProviderId.all) |id| {
            const index: usize = @intCast(@backingInt(id));
            const bit = @as(u8, 1) << @intCast(index);
            if (self.requested & bit == 0 or self.keys[index] == null) continue;
            const values = self.fetch(self.allocator, self.io, id, self.keys[index]) catch |err| {
                if (err == error.Canceled) return;
                continue;
            };
            metadata.mergeOfficial(&self.listing, &values, id) catch continue;
            self.succeeded |= bit;
        }
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
        self.allocator.destroy(self);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    project: []const u8,
    host: r.Host,
    logging: bool = true,
    /// Generated once before activation/logging; never read from the writer.
    session_id: ids.Id,
    store: Store,
    /// Project fd anchors histories/memory only, never thinking preferences.
    project_root: fs.Root,
    preferred_effort: ?presentation.ReasoningEffort = null,
    initial_default_pending: bool = false,
    settings_error: ?anyerror = null,
    settings_notice: ?[]const u8 = null,
    pending: ?std.json.Parsed(cfg.Config) = null,
    app: ?*App = null,
    /// Independently owned replay remains available even without a usable route.
    loaded_checkpoint: ?std.json.Parsed(checkpoint.State) = null,
    loaded_selection: ?selections.Snapshot = null,
    custom_credential_revision: u64 = 0,
    active_custom_revision: u64 = 0,
    /// Separate from the parsed arena; selected config may borrow this name.
    selected_name: ?[]u8 = null,
    /// Latest saved disk model, borrowed from pending or global_config while pending.
    pending_base_model: ?cfg.Model = null,
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
    display_providers: [16]tui.ModelProvider = undefined,
    selected_alias: ?[]u8 = null,
    credential_revisions: [3]u64 = @splat(0),
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
    metadata_fetch: MetadataFetch = metadata.fetch,
    metadata_dev_fetch: DevFetch = metadata.fetchDev,
    metadata_notice: ?[]const u8 = null,
    active_context_official: bool = false,
    display_origins: [64 + directory.max_models + catalog.entries.len]bool = @splat(false),
    display_disabled: [64 + directory.max_models + catalog.entries.len]bool = @splat(false),

    resume_lease: ?resume_store.Lease = null,
    resumed: bool = false,
    /// Another writer or a read-only checkpoint store never blocks viewing.
    read_only: bool = false,
    /// Journal observer wrapped so checkpoint writes stay on the runtime thread.
    inner_observer: r.Observer = .{},
    /// UI thread reads this while the runtime thread records incremental saves.
    /// Zero means the last attempted save succeeded. A nonzero code stays until
    /// a later save publishes a clean generation.
    checkpoint_failure: std.atomic.Value(u16) = .init(0),

    pub const Options = struct { restore_selection: ?ids.Id = null, resume_session: ?ids.Id = null, logging: bool = true, auto_refresh_models: bool = false };

    /// 只做本地初始化；缺少凭证时保持 pending，不发起试探请求。
    pub fn init(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host) !Session {
        return initWithOptions(a, io, environ, project, host, .{});
    }

    pub fn initWithOptions(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host, options: Options) !Session {
        const home = environ.get("HOME") orelse return error.MissingHome;
        if (options.resume_session != null and options.restore_selection != null) return error.InvalidArguments;
        const id = options.resume_session orelse try ids.generate(io);
        var project_root = try fs.Root.open(a, io, project);
        var project_moved = false;
        errdefer if (!project_moved) project_root.deinit();
        var lease: ?resume_store.Lease = if (options.resume_session) |source_id| resume_store.Lease.open(&project_root, source_id, options.logging) catch |err| switch (err) {
            error.SessionInUse, error.AccessDenied, error.ReadOnlyFileSystem, error.UnsafeResumeFile => try resume_store.Lease.open(&project_root, source_id, false),
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
            .logging = options.logging,
            .session_id = id,
            .store = auth_store,
            .project_root = project_root,
            .resume_lease = lease,
            .resumed = options.resume_session != null,
            .read_only = options.logging and if (lease) |owned| !owned.writable else false,
            .metadata_auto = options.auto_refresh_models,
            // Restored sessions do no startup fetch, but regain timed refresh.
            .metadata_next_check_ms = if (restored != null) @as(i64, @intCast(std.Io.Clock.awake.now(io).toMilliseconds())) + 60000 else 0,
            .metadata_login_auto = options.auto_refresh_models,
        };
        lease = null;
        project_moved = true;
        errdefer self.deinit();
        self.loaded_checkpoint = loaded;
        loaded = null;
        self.loaded_selection = restored;
        self.pending = try self.store.loadOrInitialize();
        self.global_config = try cfg.clone(a, self.pending.?.value);
        self.metadata_cache = metadata.load(&self.store.root) catch blk: {
            self.metadata_blocked = true;
            break :blk .{};
        };
        // Capture saved defaults before the project overlay/capability clamp.
        // Only explicit empty-chat model selection may replace this baseline.
        self.pending_base_model = self.pending.?.value.model;
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
        self.display_models = try self.buildModels(config.*, self.global_config.?.value);
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
        const key = cfg.resolveApiKey(a, self.pending.?.value, environ) catch |err| {
            if (err == error.ApiKeyNotFound or err == error.InvalidApiKey) {
                self.settings_notice = "Not logged in; history available, use /login to activate";
                return self;
            }
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
            "Conversation restored; prior tools are NOT rerun"
        else
            "Selection restored; NEW EMPTY CHAT (history not restored)";
    }

    fn prepareLoadedHistory(self: *Session, candidate: *App) !void {
        const loaded = self.loaded_checkpoint orelse return;
        var state = loaded.value;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        // Legacy archives cannot prove their tool prefix. A current decision
        // declaration must not replay old signed thinking under changed tools.
        // Normalize display data before restore, even for a poisoned archive;
        // loading history itself must not require permission to run a task.
        if (state.tool_schema_hash == null and
            (self.global_config.?.value.decision != null or self.global_config.?.value.imageActive()))
        {
            const messages = try scratch.allocator().alloc(@import("../core/protocol.zig").Message, state.messages.len);
            for (state.messages, 0..) |message, i|
                messages[i] = try @import("../core/context.zig").cloneAfterPrefixRewrite(scratch.allocator(), message);
            state.messages = messages;
            state.last_context_tokens = null;
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
        const candidate = try App.initConfiguredAnchoredAuth(self.allocator, self.io, self.environ, &self.project_root, protected, self.host, parsed);
        errdefer candidate.deinit();
        // Pin while the fresh journal still has zero counters. Imported sequence
        // numbers belong to the archive, not to a second pin operation.
        try candidate.pinSessionID(self.session_id);
        candidate.setLogging(self.logging);
        try self.prepareLoadedHistory(candidate);
        return candidate;
    }

    /// 必须等 TUI 取消并 join worker 后再释放；Connection 不得比 Session 活得更久。
    pub fn deinit(self: *Session) void {
        self.releaseLoadedHistory();
        if (self.metadata_job) |job| job.destroy();
        self.freeDisplayModels(self.display_models);
        self.freeDisplayModels(self.display_decision_models);
        self.freeDisplayModels(self.display_image_models);
        if (self.selected_alias) |alias| self.allocator.free(alias);
        if (self.global_config) |*global| cfg.release(global);
        if (self.app) |app| app.deinit();
        if (self.resume_lease) |*lease| lease.deinit();
        if (self.selected_name) |name| self.allocator.free(name);
        if (self.pending) |*pending| cfg.release(pending);
        self.store.deinit();
        self.project_root.deinit();
        self.* = undefined;
    }

    /// main 在进入 TUI 前设置，也应用于之后 /login 创建的候选 App。
    pub fn setLogging(self: *Session, enabled: bool) void {
        self.logging = enabled;
        if (self.app) |app| app.setLogging(enabled);
    }

    pub fn connection(self: *Session) tui.Connection {
        self.installObserver();
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .configure_provider_fn = configureProvider, .select_model_fn = selectModel, .set_effort_fn = setEffort, .cycle_effort_fn = cycleEffort, .setting_fn = setSetting, .preference_fn = setPreference, .decision_fn = setDecision, .image_fn = setImage, .initial_history_fn = initialHistory, .refresh_models_fn = refreshModels, .poll_models_fn = pollModels };
    }

    /// Called once, before any producer exists; never exposed by per-frame state.
    fn initialHistory(raw: *anyopaque) []const @import("../core/protocol.zig").Message {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (self.app) |app| return app.runtime.messages();
        if (self.loaded_checkpoint) |loaded| return loaded.value.messages;
        return &.{};
    }

    /// Joined, normal interactive exit. Checkpoints are also written during the
    /// run; this publishes the final clean generation. A failure never changes
    /// task success; the caller must withhold the command.
    pub fn saveOnExit(self: *Session) !bool {
        if (!self.logging or self.read_only) return false;
        if (initialHistory(self).len == 0) return false;
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
        self.inner_observer = app.journal.observer();
        app.runtime.observer = .{ .context = self, .notify_fn = persistNotify };
    }

    fn persistNotify(ctx: ?*anyopaque, observation: r.Observation) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        self.inner_observer.notify(observation);
        if (!self.logging) return;
        switch (observation) {
            .event => |event| switch (event) {
                // Dirty only once a tool can have side effects. Model calls and
                // compaction keep the previous clean checkpoint resumable.
                .tool_started => self.markCheckpointDirty(),
                .user_committed, .assistant_committed, .compacted, .finished => self.persistBestEffort(true),
                else => {},
            },
            .tool_completed => self.persistBestEffort(true),
            else => {},
        }
    }

    fn markCheckpointDirty(self: *Session) void {
        const lease = &(self.resume_lease orelse return);
        if (!lease.writable) return;
        lease.activate(&self.project_root) catch |err| {
            self.setCheckpointFailure(err);
            // The runtime checks this before execute. Leaving the previous clean
            // generation in place while the tool runs would let resume replay
            // over side effects it never recorded.
            if (self.app) |app| app.runtime.tool_blocked = true;
            return;
        };
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

    /// Reinstall the runtime observer, then publish a clean checkpoint when this
    /// chat already has history. Idle selection changes are not a model turn.
    fn publishCheckpoint(self: *Session) void {
        self.installObserver();
        self.persistBestEffort(false);
    }

    fn persistCheckpoint(self: *Session, during_run: bool) !void {
        if (!self.logging) return;
        const app = self.app orelse return;
        if (app.runtime.messages().len == 0) return;
        if (app.runtime.poisoned) return error.UnsafeToContinue;
        const bytes = try self.encodeCheckpoint(during_run);
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        try self.ensureWritableLease();
        try self.resume_lease.?.save(&self.project_root, bytes);
        self.clearCheckpointFailure();
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
        const config = if (self.app) |app| app.config.value else self.pending.?.value;
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
        return .{
            .runtime = if (self.app) |app| &app.runtime else null,
            .initial_context = if (unselected or config.selection_pending) null else self.initial_context orelse .{ .tokens = 0, .limit = @intCast(config.model.context_tokens) },
            .model = if (unselected) "" else config.model.name,
            .session_id = self.session_id,
            .models = self.display_models,
            .model_providers = self.display_providers[0..provider_count],
            .model_context_official = self.display_origins[0..self.display_models.len],
            .model_disabled = self.display_disabled[0..self.display_models.len],
            .context_official = self.active_context_official,
            .metadata_notice = self.metadata_notice,
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
            .global_settings_available = !self.read_only,
            .reasoning_effort = presentation.ReasoningEffort.fromName(config.model.reasoning_effort),
            .pending_default_effort = if (self.app != null and self.initial_default_pending and config.model.reasoning_effort == null) self.preferred_effort else null,
            .effort_levels = self.capabilitiesFor(config).levels,
            .settings_error = self.settings_error,
            .settings_notice = self.settings_notice,
            .base_url = config.provider.base_url,
            .logging_enabled = self.logging and !self.read_only,
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

    fn refreshModels(raw: *anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.startMetadata(self.configuredMask(self.global_config.?.value), true);
    }

    fn refreshPolicy(self: *const Session) metadata.Policy {
        const limits = self.global_config.?.value.limits;
        return .{ .ttl_ms = limits.model_refresh_ttl_ms, .cooldown_ms = limits.model_refresh_cooldown_ms };
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
        const claim = try metadata.claimAt(&self.store.root, requested | metadata.dev_bit, manual, self.metadataNow(), self.refreshPolicy());
        self.metadata_cache.refresh = claim.cache.refresh;
        job.requested = claim.mask;
        job.generations = claim.generations;
        for (ProviderId.all) |id| {
            const index: usize = @intCast(@backingInt(id));
            if (claim.mask & metadata.bit(id) != 0) job.keys[index] = self.keyFor(id) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null, // Durable failed attempt; never fetch with a null key.
            };
        }
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
        var keys: [3]?[]u8 = @splat(null);
        var transferred = false;
        defer if (!transferred) {
            for (keys) |key| if (key) |bytes| {
                std.crypto.secureZero(u8, bytes);
                self.allocator.free(bytes);
            };
        };
        const claim = try metadata.claimAt(&self.store.root, requested, true, self.metadataNow(), self.refreshPolicy());
        for (ProviderId.all) |id| {
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
        job.keys = keys;
        transferred = true;
        errdefer {
            job.wipeKeys();
            job.requested = previous_mask;
            job.listing = previous_listing;
            job.succeeded = previous_succeeded;
            job.started_ms = previous_started;
            job.credential_revisions = previous_revisions;
            job.generations = previous_generations;
            job.official_published = true;
        }
        job.requested = claim.mask | (previous_mask & metadata.dev_bit);
        // Restart replaces official ownership only; the public task keeps its
        // independent durable claim even if another session has since claimed.
        for (0..3) |index| if (claim.mask & (@as(u8, 1) << @intCast(index)) != 0) {
            job.generations[index] = claim.generations[index];
        };
        job.listing = .{};
        job.succeeded = 0;
        job.done.store(false, .release);
        job.credential_revisions = self.credential_revisions;
        job.official_published = false;
        job.started_ms = @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds());
        job.future = try std.Io.concurrent(self.io, MetadataJob.run, .{job});
        job.manual = true;
        self.metadata_cache.refresh = claim.cache.refresh;
        self.metadata_login_pending &= ~claim.mask;
    }

    /// Owner polling never waits for network. Completion may change only the
    /// candidate catalog; the active Runtime budget is frozen until selection.
    fn pollModels(raw: *anyopaque, idle: bool) bool {
        const self: *Session = @ptrCast(@alignCast(raw));
        const default_changed = self.completeInitialDefault(idle) catch false;
        if (self.metadata_job) |job| {
            official_pending: {
                if (job.future) |*future| {
                    if (job.done.load(.acquire)) {
                        future.await(self.io);
                    } else if (std.Io.Clock.awake.now(self.io).toMilliseconds() - job.started_ms >= official_metadata_timeout_ms) {
                        future.cancel(self.io);
                    } else break :official_pending;
                    job.future = null;
                    job.wipeKeys(); // Also handles cancellation before the worker starts.
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
            if (!idle) return false;
            if (job.future == null and job.official_published and job.dev_future != null and self.metadata_login_pending != 0) {
                const requested = self.metadata_login_pending;
                self.restartOfficialMetadata(job, requested) catch {
                    self.metadata_login_pending &= ~requested; // One attempt per login, never a tight retry loop.
                    self.metadata_notice = "Login saved; official model refresh failed, previous list kept";
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
            var succeeded: u8 = 0;
            if (official_ready) {
                listing = job.listing;
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
                metadata.mergeDev(&listing, &job.dev_listing) catch {
                    self.metadata_notice = if (job.manual) "Metadata cache could not be saved; previous values kept" else null;
                    return true;
                };
            }
            const publication = metadata.commitClaimedAt(&self.store.root, succeeded, listing, job.generations, self.metadataNow()) catch {
                self.metadata_notice = if (job.manual) "Metadata cache could not be saved; previous values kept" else null;
                return true;
            };
            if (official_ready) job.succeeded = publication.accepted & metadata.provider_mask;
            succeeded = publication.accepted & metadata.provider_mask;
            if (dev_ready and publication.accepted & metadata.dev_bit == 0) {
                listing.dev_done = false;
                job.dev_listing.dev_done = false;
            }
            const previous = self.metadata_cache;
            self.metadata_cache = publication.cache;
            const models = self.buildModels(self.mutableConfig().*, self.global_config.?.value) catch {
                self.metadata_cache = previous;
                self.metadata_notice = if (job.manual) "Metadata display could not be updated; previous values kept" else null;
                return true;
            };
            const decision_models = self.buildDecisionModels(self.global_config.?.value) catch {
                self.freeDisplayModels(models);
                self.metadata_cache = previous;
                self.metadata_notice = if (job.manual) "Metadata display could not be updated; previous values kept" else null;
                return true;
            };
            const image_models = self.buildImageModels(self.global_config.?.value) catch {
                self.freeDisplayModels(models);
                self.freeDisplayModels(decision_models);
                self.metadata_cache = previous;
                self.metadata_notice = if (job.manual) "Metadata display could not be updated; previous values kept" else null;
                return true;
            };
            self.freeDisplayModels(self.display_models);
            self.freeDisplayModels(self.display_decision_models);
            self.freeDisplayModels(self.display_image_models);
            self.display_models = models;
            self.display_decision_models = decision_models;
            self.display_image_models = image_models;
            _ = self.completeInitialDefault(idle) catch false;
            const official_requested = job.requested & metadata.provider_mask;
            self.metadata_notice = if (!job.manual) null else if (!finished)
                (if (job.dev_future != null)
                    (if (succeeded != 0) "Official metadata updated; models.dev refresh still running" else "Official metadata failed or became stale; models.dev refresh still running")
                else
                    (if (listing.dev_done) "models.dev updated; official metadata refresh still running" else "models.dev refresh failed; official metadata refresh still running"))
            else if (official_requested == 0)
                (if (job.dev_listing.dev_done) "models.dev metadata refreshed" else "models.dev metadata refresh failed; cached/default values kept")
            else if (job.succeeded == 0)
                "Official metadata refresh failed; cached/default values kept"
            else if (job.succeeded != official_requested)
                "Official metadata partly refreshed; failed sources kept cached/default values"
            else if (job.requested & metadata.dev_bit != 0 and !job.dev_listing.dev_done)
                "Official model list refreshed; models.dev metadata refresh failed"
            else
                "Official model list refreshed; /model shows official or default capacity";
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
        if (tick < self.metadata_next_check_ms) return false;
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
    fn hasLocalCredential(self: *const Session, provider: cfg.Provider) bool {
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
    fn buildModels(self: *Session, _: cfg.Config, global: cfg.Config) ![]cfg.Model {
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
            return models.toOwnedSlice(self.allocator);
        }
        return models.toOwnedSlice(self.allocator);
    }

    /// Resolve the same catalog with auxiliary caps before filtering. A small
    /// reviewer window must not become unusable due to the main safety margin.
    fn buildDecisionModels(self: *Session, global: cfg.Config) ![]cfg.Model {
        var independent = global;
        independent.limits = (global.decision orelse cfg.DecisionConfig{ .model = "" }).modelLimits(global.limits.request_timeout_ms);
        const models = try self.buildModels(independent, independent);
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
        if (models.items.len == self.display_disabled.len) return error.TooManyModels;
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

    fn guardSelection(self: *Session) !void {
        if (self.read_only) return error.ResumeReadOnly;
        // TUI additionally owns the future-joined requirement.
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
            if (self.pending != null) self.pending_base_model = value.value.model;
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
    fn persistSettings(self: *Session, declaration: *std.json.Parsed(cfg.Config), refresh: App.SettingsRefresh) !void {
        try cfg.validate(declaration.value);
        var prepared: ?App.SettingsReplacement = if (self.app) |app| try app.prepareSettingsRefresh(declaration.value, self.environ, refresh) else null;
        defer if (prepared) |*value| value.deinit();
        var pending: ?std.json.Parsed(cfg.Config) = if (self.app == null)
            try decision_selection.activeClone(self.allocator, self.pending.?.value, declaration.value)
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
            self.pending_base_model = self.global_config.?.value.model;
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
        const models = try self.buildModels(owned.value, if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.freeDisplayModels(models);
        const decision_models = try self.buildDecisionModels(if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.freeDisplayModels(decision_models);
        const image_models = try self.buildImageModels(if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.freeDisplayModels(image_models);
        var replacement: ?*App.ConnectionReplacement = null;
        var initial: ?*App = null;
        errdefer if (replacement) |value| value.deinit();
        errdefer if (initial) |value| value.deinit();
        const key = cfg.resolveApiKey(self.allocator, owned.value, self.environ) catch |err| blk: {
            if ((err == error.ApiKeyNotFound or err == error.InvalidApiKey) and self.app == null) break :blk null;
            return err;
        };
        defer if (key) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        };
        if (key != null) {
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
            self.pending_base_model = null;
            if (initial) |value| {
                self.app = value;
            } else {
                self.pending = owned;
                consumed = true;
                if (pending_selection) |snapshot| self.loaded_selection = snapshot;
            }
        }
        if (self.selected_name) |value| self.allocator.free(value);
        self.selected_name = null;
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
        // Login never changes the global default or switches to catalog.first.
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
        const models = try self.buildModels(if (initial) |value| value.config.value else active, baseline.value);
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
            self.pending_base_model = null;
            if (self.selected_name) |old| self.allocator.free(old);
            self.selected_name = null;
            self.app = value;
            self.armInitialDefault();
            if (id) |service| self.active_revision = self.credential_revisions[@intCast(@backingInt(service))] else self.active_custom_revision = self.custom_credential_revision;
            self.initial_context = value.runtime.contextSnapshot();
            self.releaseLoadedHistory();
            self.settings_notice = if (self.resumed) "Conversation restored; prior tools are NOT rerun" else null;
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
        if (!idle or app.runtime.busy.load(.acquire)) return false;
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
        try self.guardSelection();
        const config = self.mutableConfig().*;
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
        try self.guardSelection();
        const name = effort.name() orelse return error.InvalidReasoningEffort;
        const config = self.mutableConfig();
        var candidate = self.effortCandidate(config.*);
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
        if (!sameDeclaration(config.model.reasoning, candidate.model.reasoning)) {
            var declaration = candidate.model.reasoning.?;
            inline for (fields) |field| {
                if (@field(declaration.map, field)) |value| @field(owned_map, field) = try a.dupe(u8, value);
            }
            declaration.map = owned_map;
            candidate.model.reasoning = declaration;
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
        if (self.pending != null and self.pending_base_model == null) self.pending_base_model = config.model;
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
const session_test_config =
    \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","api_key_env":"SESSION_TEST_KEY","models":{"saved":{"protocol":"chat","context_tokens":65536,"output_tokens":4096},"next":{"protocol":"chat","context_tokens":131072,"output_tokens":8192}}},"other":{"base_url":"https://other.invalid/v1","api_key_env":"SESSION_TEST_KEY","models":{"other":{"protocol":"chat","context_tokens":32768,"output_tokens":2048}}}}},"limits":{"low_price_input":false}}
;

const session_test_unavailable =
    \\{"llm":{"default":"other/other","providers":{"archive":{"base_url":"https://archive.invalid/v1","models":{"next":{"protocol":"chat","context_tokens":131072}}},"other":{"base_url":"https://other.invalid/v1","models":{"other":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
;

const session_test_missing_alias =
    \\{"llm":{"default":"other/saved","providers":{"other":{"base_url":"https://other.invalid/v1","api_key_env":"SESSION_TEST_KEY","models":{"saved":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
;

fn hasConversationData(messages: []const @import("../core/protocol.zig").Message) bool {
    if (@import("../core/context.zig").hasSummaryPrefix(messages)) return true;
    for (messages) |message| if (message.role != .context) return true;
    return false;
}

test "global defaults distinguish machine prefixes from summarized or assistant history" {
    const Message = @import("../core/protocol.zig").Message;
    const context = @import("../core/context.zig");
    const machine: Message = .{ .role = .context, .blocks = &.{.{ .text = "owned environment prefix" }} };
    try std.testing.expect(!hasConversationData(&.{machine}));
    const summary: Message = .{ .role = .context, .blocks = &.{.{ .text = context.summary_marker ++ "prior user content" }} };
    try std.testing.expect(hasConversationData(&.{summary}));
    try std.testing.expect(hasConversationData(&.{ machine, .{ .role = .assistant, .blocks = &.{.{ .text = "saved reply" }} } }));
}

fn persistedEffortForTest(session: *Session) !presentation.ReasoningEffort {
    var parsed = try session.store.loadExisting();
    defer cfg.release(&parsed);
    return presentation.ReasoningEffort.fromName(parsed.value.registry.?.reasoning_effort orelse "medium");
}

fn setGlobalEffortForTest(session: *Session, effort: presentation.ReasoningEffort) !void {
    var candidate: ?std.json.Parsed(cfg.Config) = try cfg.clone(session.allocator, session.global_config.?.value);
    defer if (candidate) |*value| cfg.release(value);
    try cfg.setRegistryReasoningEffort(candidate.?.arena.allocator(), &candidate.?.value, effort.name().?);
    try session.persistSelectionDefaults(&candidate);
    session.preferred_effort = effort;
}

fn writeSessionTestConfig(dir: std.Io.Dir, bytes: []const u8) !void {
    dir.createDir(std.testing.io, ".thin", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = bytes });
}

const SessionTestFixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    env: std.process.Environ.Map,

    fn init() !SessionTestFixture {
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const path = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
        const home = try a.dupe(u8, path);
        errdefer a.free(home);
        var env = std.process.Environ.Map.init(a);
        errdefer env.deinit();
        try env.put("HOME", home);
        try writeSessionTestConfig(tmp.dir, session_test_config);
        return .{ .tmp = tmp, .home = home, .env = env };
    }

    fn deinit(self: *SessionTestFixture) void {
        self.env.deinit();
        std.testing.allocator.free(self.home);
        self.tmp.cleanup();
    }

    fn open(self: *SessionTestFixture, options: Session.Options) !Session {
        return Session.initWithOptions(std.testing.allocator, std.testing.io, &self.env, self.home, .{}, options);
    }

    fn saveHistory(self: *SessionTestFixture) !ids.Id {
        var source = try self.open(.{});
        defer source.deinit();
        try source.connection().configure("fake-archive-original");
        try seedSessionTestHistory(&source);
        try std.testing.expect(try source.saveOnExit());
        return source.session_id;
    }
};

fn seedSessionTestHistory(session: *Session) !void {
    const app = session.app.?;
    try app.runtime.restoreCheckpoint(.{
        .system = "archived system, not current capabilities",
        .selector = app.runtime.selector,
        .estimator = .{ .per_mille = 1200 },
        .last_context_tokens = 77,
        .context_tokens = 65536,
        .output_tokens = 4096,
        .output_budget_frozen = true,
        .input_budget_frozen = true,
        .input_price_threshold = 100000,
        .max_input_tokens = 80000,
        .permission_id = 19,
        .messages = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "saved question" }} },
            .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "old-tool", .name = "write_file", .arguments = "{\"path\":\"must-not-run.txt\",\"content\":\"no\"}" } }} },
            .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "old-tool", .text = "old result" } }} },
            .{ .role = .assistant, .blocks = &.{.{ .text = "saved answer" }} },
        },
    });
    app.journal.seq = 13;
    app.journal.turn = 2;
}

fn expectSessionTestHistory(session: *Session) !void {
    const messages = Session.initialHistory(session);
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("saved question", messages[0].blocks[0].text);
    try std.testing.expectEqualStrings("saved answer", messages[3].blocks[0].text);
    try std.testing.expectError(error.FileNotFound, session.project_root.dir.statFile(std.testing.io, "must-not-run.txt", .{}));
}

test "empty HOME hides placeholder selection but retains initialized defaults" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try std.testing.expect(session.loaded_checkpoint == null);
    const state = session.connection().current();
    try std.testing.expectEqualStrings("", state.model);
    try std.testing.expect(state.selection_name == null);
    try std.testing.expect(state.initial_context == null);
    try std.testing.expectEqual(@as(u32, 0), state.context_limit);
    // No active priced model: the UI flag is not the global policy toggle.
    try std.testing.expect(!state.low_price_input);
    try std.testing.expectEqual(@as(usize, 0), state.model_providers.len);
    try std.testing.expectEqualStrings("deepseek-flash", session.pending.?.value.model.name);
    const disk = try session.store.loadExisting();
    defer disk.deinit();
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", disk.value.registry.?.default);
    try std.testing.expectEqualStrings("deepseek-flash", disk.value.model.name);
}

test "provider menu preserves local credential aliases and actual endpoint identity" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"pending/saved","providers":{"pending":{"base_url":"https://pending.invalid/v1","models":{"saved":{"protocol":"chat","context_tokens":65536}}},"proxy-alias":{"base_url":"https://proxy.invalid/v1","kind":"deepseek","api_key":"fake-proxy"},"official-one":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key":"fake-official"},"official-two":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key_env":"MENU_KEY"},"empty-env":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key_env":"EMPTY_MENU_KEY"},"missing-env":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key_env":"MISSING_MENU_KEY"}}},"limits":{"low_price_input":false}}
    );
    try fixture.env.put("MENU_KEY", "fake-env");
    try fixture.env.put("EMPTY_MENU_KEY", "");
    var session = try fixture.open(.{ .logging = false });
    defer session.deinit();
    const state = session.connection().current();
    const providers = state.model_providers;
    try std.testing.expectEqual(@as(usize, 3), providers.len);
    var seen: u8 = 0;
    for (providers) |provider| {
        if (std.mem.eql(u8, provider.name, "proxy-alias")) {
            seen |= 1;
            try std.testing.expect(provider.allow_custom);
        } else if (std.mem.eql(u8, provider.name, "official-one")) {
            seen |= 2;
            try std.testing.expect(!provider.allow_custom);
        } else if (std.mem.eql(u8, provider.name, "official-two")) {
            seen |= 4;
            try std.testing.expect(!provider.allow_custom);
        } else return error.UnexpectedProvider;
    }
    try std.testing.expectEqual(@as(u8, 7), seen);
    // Fresh publication reflects local environment changes without rebuilding
    // model candidates or treating a kind hint as official identity.
    try fixture.env.put("MENU_KEY", "");
    try std.testing.expectEqual(@as(usize, 2), session.connection().current().model_providers.len);
    try std.testing.expectEqual(metadata.bit(.deepseek), session.configuredMask(session.global_config.?.value));
    const proxy = session.global_config.?.value.registry.?.find("proxy-alias").?;
    try std.testing.expect(session.hasLocalCredential(proxy.connection));
    var empty_literal = proxy.connection;
    empty_literal.api_key = "";
    try std.testing.expect(!session.hasLocalCredential(empty_literal));
}

test "new llm pending startup and custom login activate without inference" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{ .logging = false });
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try std.testing.expectEqualStrings("", session.connection().current().model);
    try std.testing.expect(session.connection().current().selection_name == null);
    try std.testing.expectEqual(@as(usize, 0), session.connection().current().model_providers.len);
    try std.testing.expectEqual(@as(usize, 0), Session.initialHistory(&session).len);
    try std.testing.expect(session.settings_notice != null);
    try session.connection().configure("fake-custom-key");
    try std.testing.expectEqualStrings("Bearer fake-custom-key", session.app.?.client.authorization);
    const logged_in = session.connection().current();
    try std.testing.expectEqual(@as(usize, 1), logged_in.model_providers.len);
    try std.testing.expectEqualStrings("archive", logged_in.model_providers[0].name);
    try std.testing.expect(logged_in.model_providers[0].allow_custom);
    try std.testing.expectEqualStrings("archive/saved", logged_in.selection_name.?);
    try std.testing.expectEqualStrings("archive/saved", session.global_config.?.value.registry.?.default);
    try std.testing.expect(!session.app.?.journal.started);
    try std.testing.expect(!try session.saveOnExit());
}

test "resume without key displays and saves history then custom login imports it exactly once" {
    const Counter = struct {
        started: usize = 0,
        fn emit(raw: ?*anyopaque, event: r.Event, _: *const @import("../core/protocol.zig").Cancellation) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (event == .tool_started) self.started += 1;
        }
        fn authorize(_: ?*anyopaque, _: r.Permission, _: *const @import("../core/protocol.zig").Cancellation) !r.Decision {
            return .allow_once;
        }
    };
    var counter: Counter = .{};
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    // Actual new-format fixture removes the saved inline key.
    try writeSessionTestConfig(fixture.tmp.dir, session_test_config);
    var resumed = try Session.initWithOptions(std.testing.allocator, std.testing.io, &fixture.env, fixture.home, .{ .context = &counter, .emit_fn = Counter.emit, .authorize_fn = Counter.authorize }, .{ .resume_session = id });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try std.testing.expect(resumed.loaded_checkpoint != null);
    try expectSessionTestHistory(&resumed);
    try std.testing.expect(try resumed.saveOnExit());
    try resumed.connection().configure("fake-custom-login");
    try std.testing.expect(resumed.loaded_checkpoint == null);
    try std.testing.expect(resumed.loaded_selection == null);
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqual(@as(u64, 13), resumed.app.?.journal.seq);
    try std.testing.expectEqual(@as(u64, 2), resumed.app.?.journal.turn);
    try std.testing.expectEqual(@as(u64, 77), resumed.initial_context.?.tokens);
    try std.testing.expect(resumed.app.?.journal.resumed);
    try resumed.connection().selectModel("archive/saved");
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqual(@as(usize, 0), counter.started);
    try std.testing.expectEqual(@as(u64, 0), resumed.app.?.runtime.permission_id);
}

test "invalid or empty key environment does not block restored history and can login locally" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    for ([_][]const u8{ "", "bad\nkey" }) |value| {
        try writeSessionTestConfig(fixture.tmp.dir,
            \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","api_key_env":"ARCHIVE_TEST_KEY","models":{"saved":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"low_price_input":false}}
        );
        try fixture.env.put("ARCHIVE_TEST_KEY", value);
        var resumed = try fixture.open(.{ .resume_session = id, .logging = false });
        defer resumed.deinit();
        try std.testing.expect(resumed.app == null);
        try std.testing.expect(std.mem.find(u8, resumed.settings_notice.?, "/login") != null);
        try expectSessionTestHistory(&resumed);
        try resumed.connection().configure("fake-valid-replacement");
        try std.testing.expect(resumed.app != null);
        try expectSessionTestHistory(&resumed);
        try std.testing.expect(!try resumed.saveOnExit());
    }
}

test "concurrent checkpoint writer allows read only history without credentials" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    var writer = try fixture.open(.{ .resume_session = id });
    defer writer.deinit();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_config);
    var reader = try fixture.open(.{ .resume_session = id });
    defer reader.deinit();
    try std.testing.expect(reader.read_only);
    try std.testing.expect(reader.app == null);
    try std.testing.expect(std.mem.find(u8, reader.settings_notice.?, "read-only") != null);
    try expectSessionTestHistory(&reader);
    try std.testing.expect(!try reader.saveOnExit());
    try std.testing.expectError(error.ResumeReadOnly, reader.connection().configure("fake-not-published"));
}

test "changed credential and current budgets do not authenticate or reject checkpoint loading" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","api_key":"fake-rotated-key","models":{"saved":{"protocol":"responses","context_tokens":131072,"output_tokens":16384}}}}},"limits":{"low_price_input":true,"max_input_tokens":12000,"input_margin_tokens":1000}}
    );
    var resumed = try fixture.open(.{ .resume_session = id, .logging = false });
    defer resumed.deinit();
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqualStrings("Bearer fake-rotated-key", resumed.app.?.client.authorization);
    const current_config = resumed.app.?.config.value;
    try std.testing.expectEqual(@as(u32, 131072), current_config.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 16384), current_config.model.output_tokens);
    try std.testing.expect(current_config.model.input_price_threshold == null);
    try std.testing.expectEqual(@as(?u32, 12000), current_config.limits.max_input_tokens);
    try std.testing.expectEqual(@import("../core/protocol.zig").Protocol.responses, current_config.model.protocol);
    try std.testing.expect(!try resumed.saveOnExit());
}

test "missing alias cannot borrow same model credential and preserves historical header" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_missing_alias);
    try fixture.env.put("SESSION_TEST_KEY", "fake-unrelated-key");
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try std.testing.expect(resumed.pending.?.value.selection_pending);
    try std.testing.expectEqualStrings("archive/saved", resumed.connection().current().selection_name.?);
    try std.testing.expectEqualStrings("saved", resumed.connection().current().model);
    try std.testing.expect(resumed.connection().current().provider == null);
    try expectSessionTestHistory(&resumed);
    try std.testing.expect(try resumed.saveOnExit());
    try resumed.connection().selectModel("other/saved");
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqualStrings("other/saved", resumed.global_config.?.value.registry.?.default);
}

test "removed alias rebinds only by an unambiguous exact endpoint" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"renamed/saved","providers":{"renamed":{"base_url":"https://archive.invalid/v1","api_key":"fake-renamed","models":{"saved":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
    );
    var resumed = try fixture.open(.{ .resume_session = id, .logging = false });
    defer resumed.deinit();
    try std.testing.expectEqualStrings("renamed/saved", resumed.connection().current().selection_name.?);
    try std.testing.expectEqualStrings("Bearer fake-renamed", resumed.app.?.client.authorization);
    try expectSessionTestHistory(&resumed);
}

test "unavailable model login saves credential without dropping history or changing default" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_unavailable);
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try resumed.connection().configure("fake-unavailable-model-key");
    try std.testing.expect(resumed.app == null);
    try std.testing.expect(resumed.loaded_checkpoint != null);
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqualStrings("other/other", resumed.global_config.?.value.registry.?.default);
    try std.testing.expectEqualStrings("fake-unavailable-model-key", resumed.global_config.?.value.registry.?.find("archive").?.connection.api_key.?);
    try std.testing.expect(std.mem.find(u8, resumed.settings_notice.?, "/model") != null);
    try resumed.connection().selectModel("archive/next");
    try expectSessionTestHistory(&resumed);
    try std.testing.expect(resumed.loaded_checkpoint == null);
    try std.testing.expectEqualStrings("other/other", resumed.global_config.?.value.registry.?.default);
    try std.testing.expectEqualStrings("archive/next", resumed.connection().current().selection_name.?);
}

test "official provider login imports pending archive without switching global default" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"other/other","providers":{"archive":{"base_url":"https://api.deepseek.com","kind":"deepseek","models":{"saved":{"protocol":"chat","context_tokens":65536}}},"other":{"base_url":"https://other.invalid/v1","models":{"other":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
    );
    var resumed = try fixture.open(.{ .resume_session = id, .logging = false });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try expectSessionTestHistory(&resumed);
    const unchanged_generation = resumed.resume_lease.?.expected;
    try std.testing.expect(!try resumed.saveOnExit());
    try std.testing.expectEqual(unchanged_generation, resumed.resume_lease.?.expected);
    try resumed.connection().configureProvider(.deepseek, "fake-official-login");
    try std.testing.expectEqualStrings("Bearer fake-official-login", resumed.app.?.client.authorization);
    try std.testing.expectEqualStrings("archive/saved", resumed.connection().current().selection_name.?);
    try std.testing.expectEqualStrings("other/other", resumed.global_config.?.value.registry.?.default);
    try std.testing.expect(resumed.loaded_checkpoint == null);
    try expectSessionTestHistory(&resumed);
}

test "missing config initializes latest defaults while retaining unconfigured archive" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try fixture.tmp.dir.deleteFile(std.testing.io, ".thin/config.json");
    var resumed = try fixture.open(.{ .resume_session = id, .logging = false });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try std.testing.expectEqualStrings("archive/saved", resumed.connection().current().selection_name.?);
    try expectSessionTestHistory(&resumed);
    _ = try fixture.tmp.dir.statFile(std.testing.io, ".thin/config.json", .{});
    try std.testing.expect(!try resumed.saveOnExit());
}

test "restore selection without key or model remains pending and never imports messages" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_unavailable);
    var selected = try fixture.open(.{ .restore_selection = id });
    defer selected.deinit();
    try std.testing.expect(selected.app == null);
    try std.testing.expect(selected.loaded_checkpoint == null);
    try std.testing.expectEqual(@as(usize, 0), Session.initialHistory(&selected).len);
    try std.testing.expect(selected.pending.?.value.selection_pending);
    try std.testing.expect(!std.mem.eql(u8, &id, &selected.session_id));
    try std.testing.expect(!try selected.saveOnExit());
    try selected.connection().configure("fake-selection-only-key");
    try std.testing.expect(selected.app == null);
    try selected.connection().selectModel("archive/next");
    try std.testing.expectEqual(@as(usize, 0), selected.app.?.runtime.messages().len);
}

test "pending login save failure destroys candidate but retains source history" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_config);
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    const original_history = Session.initialHistory(&resumed).ptr;
    // Another writer changes the config after Session captured its CAS baseline.
    try writeSessionTestConfig(fixture.tmp.dir, session_test_unavailable);
    try std.testing.expectError(error.AuthVersionConflict, resumed.connection().configure("fake-rejected-key"));
    try std.testing.expect(resumed.app == null);
    try std.testing.expect(resumed.loaded_checkpoint != null);
    try std.testing.expect(original_history == Session.initialHistory(&resumed).ptr);
    try expectSessionTestHistory(&resumed);
    try std.testing.expect(resumed.global_config.?.value.registry.?.find("archive").?.connection.api_key == null);
}

test "custom credential rotation activates only on explicit same model reselect" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{ .logging = false });
    defer session.deinit();
    try session.connection().configure("fake-custom-before");
    try seedSessionTestHistory(&session);
    const old_app = session.app.?;
    try session.connection().configure("fake-custom-after");
    try std.testing.expectEqual(old_app, session.app.?);
    try std.testing.expectEqualStrings("Bearer fake-custom-before", session.app.?.client.authorization);
    try std.testing.expectEqualStrings("fake-custom-after", session.global_config.?.value.registry.?.find("archive").?.connection.api_key.?);
    try session.connection().selectModel("archive/saved");
    try std.testing.expectEqualStrings("Bearer fake-custom-after", session.app.?.client.authorization);
    try expectSessionTestHistory(&session);
}

test "custom kind does not authorize official metadata or credential borrowing" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"proxy/saved","providers":{"proxy":{"base_url":"https://proxy.invalid/v1","kind":"deepseek","api_key":"fake-proxy-only","models":{"saved":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"low_price_input":false}}
    );
    var session = try fixture.open(.{ .logging = false });
    defer session.deinit();
    try std.testing.expectEqual(@as(u8, 0), session.configuredMask(session.global_config.?.value));
    try std.testing.expect(session.connection().current().provider == null);
    try std.testing.expect(!session.connection().current().allow_custom_models);
    // Real registry owners do not offer an inherited custom ID which the
    // resolver must reject. Declared custom profiles remain searchable.
    const state = session.connection().current();
    var picker = @import("../ui/model_picker.zig").Picker.init(std.testing.allocator);
    defer picker.deinit();
    picker.provider = state.provider;
    picker.allow_custom = state.allow_custom_models;
    _ = try picker.insert("never-declared", false);
    const unknown = try picker.choicesWithProviders(std.testing.allocator, state.selection_name.?, state.context_limit, state.models, state.model_disabled, state.model_providers);
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
    try std.testing.expectError(error.DefaultModelUnavailable, session.connection().selectModel("proxy/never-declared"));
    try std.testing.expectEqualStrings("saved", session.app.?.config.value.model.name);
    picker.clear();
    _ = try picker.insert("saved", false);
    const declared = try picker.choicesWithProviders(std.testing.allocator, state.selection_name.?, state.context_limit, state.models, state.model_disabled, state.model_providers);
    defer std.testing.allocator.free(declared);
    try std.testing.expectEqual(@as(usize, 1), declared.len);
    try std.testing.expect(!declared[0].inherited);
    try std.testing.expectEqualStrings("proxy/saved", declared[0].name);
    try std.testing.expectError(error.ApiKeyNotFound, session.keyFor(.deepseek));
    try std.testing.expectEqualStrings("Bearer fake-proxy-only", session.app.?.client.authorization);
}

test "custom kind pending resume login stays on the actual endpoint" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","kind":"opencode_zen","models":{"saved":{"protocol":"chat","context_tokens":65536,"output_tokens":4096}}}}},"limits":{"low_price_input":false}}
    );
    var session = try fixture.open(.{ .resume_session = id, .logging = false });
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try std.testing.expect(session.connection().current().provider == null);
    try std.testing.expect(!session.connection().current().allow_custom_models);
    try expectSessionTestHistory(&session);
    try session.connection().configure("fake-proxy-resume-key");
    try expectSessionTestHistory(&session);
    try std.testing.expectEqualStrings("https://archive.invalid/v1", session.app.?.config.value.provider.base_url);
    try std.testing.expectEqualStrings("Bearer fake-proxy-resume-key", session.app.?.client.authorization);
    try std.testing.expectEqual(ProviderId.opencode_zen, session.app.?.config.value.provider.kind.?);
    try std.testing.expect(session.global_config.?.value.registry.?.find("opencode-zen") == null);
    try std.testing.expectEqual(@as(u8, 0), session.metadata_login_pending);
    try std.testing.expect(!session.app.?.journal.started);
}

test "pending model publication saves new archive selection without key" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_config);
    {
        var resumed = try fixture.open(.{ .resume_session = id });
        defer resumed.deinit();
        try resumed.connection().selectModel("archive/next");
        try std.testing.expect(resumed.app == null);
        try std.testing.expectEqualStrings("archive/saved", resumed.global_config.?.value.registry.?.default);
        try std.testing.expect(try resumed.saveOnExit());
    }
    var reopened = try fixture.open(.{ .resume_session = id, .logging = false });
    defer reopened.deinit();
    try std.testing.expectEqualStrings("archive/next", reopened.connection().current().selection_name.?);
    try expectSessionTestHistory(&reopened);
}

/// Read selection out of a clean checkpoint. A missing lease is the old
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

fn releaseLease(session: *Session) void {
    if (session.resume_lease) |*lease| lease.deinit();
    session.resume_lease = null;
}

test "Anthropic displayable session resume preserves signed replay and never executes tools" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const adapter = @import("../llm/anthropic.zig");
    const native = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"private plan\",\"signature\":\"signed fixture\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque fixture\"},{\"type\":\"tool_use\",\"id\":\"saved-call\",\"name\":\"write_file\",\"input\":{\"path\":\"must-not-run.txt\",\"content\":\"no\"}}]}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeSessionTestConfig(tmp.dir,
        \\{"llm":{"default":"opencode-go/claude-haiku-5-5","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"claude-haiku-5-5":{"protocol":"anthropic","context_tokens":32768,"output_tokens":4096}}}}},"limits":{"low_price_input":false}}
    );
    var id: ids.Id = undefined;
    var expected: ?[]u8 = null;
    defer if (expected) |bytes| a.free(bytes);
    const Wire = struct {
        fn encode(allocator: std.mem.Allocator, session: *Session) ![]u8 {
            const app = session.app.?;
            // Wire-only replay fixture has no price directory and never sends.
            var config = app.config.value;
            config.limits.low_price_input = false;
            return adapter.encode(allocator, .{
                .scope = .{ .connection = app.config.value.provider.base_url, .model = app.config.value.model.name, .protocol = .anthropic },
                .system = app.runtime.system,
                .messages = app.runtime.messages(),
                .tools = &.{},
                .max_output_tokens = try @import("../core/context.zig").outputBudget(config, .normal, app.runtime.estimator.tokens(@import("../core/context.zig").rawTokens(app.runtime.system, &.{}, app.runtime.messages()))),
            });
        }
    };
    {
        var source = try Session.init(a, io, &env, home, .{});
        defer source.deinit();
        try source.connection().configureProvider(.opencode_go, "fake-anthropic-resume");
        try source.connection().selectModel("opencode-go/claude-haiku-5-5");
        id = source.session_id;
        const state: checkpoint.State = .{
            .system = "frozen Anthropic system",
            .selector = .{ .configured = .anthropic, .selected = .anthropic, .initial_attempted = true },
            .estimator = .{ .per_mille = 1200 },
            .last_context_tokens = 77,
            .context_tokens = 32768,
            .permission_id = 19,
            .messages = &.{
                .{ .role = .user, .blocks = &.{.{ .text = "original question" }} },
                .{ .role = .assistant, .blocks = &.{
                    .{ .reasoning = "private plan" },
                    .{ .tool_call = .{ .id = "saved-call", .name = "write_file", .arguments = "{\"path\":\"must-not-run.txt\",\"content\":\"no\"}" } },
                }, .replay = .{ .scope = .{ .connection = ProviderId.opencode_go.baseUrl(), .model = "claude-haiku-5-5", .protocol = .anthropic }, .json = native } },
                .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "saved-call", .text = "prior result", .canceled = true, .is_error = true } }} },
                .{ .role = .assistant, .blocks = &.{.{ .text = "original answer" }} },
            },
        };
        try source.app.?.runtime.restoreCheckpoint(state);
        expected = try Wire.encode(a, &source);
        try std.testing.expect(try source.saveOnExit());
    }
    {
        var restored = try Session.initWithOptions(a, io, &env, home, .{}, .{ .resume_session = id, .logging = false });
        defer restored.deinit();
        try std.testing.expectEqual(id, restored.session_id);
        try std.testing.expect(restored.app.?.runtime.selector.selected == .anthropic);
        try std.testing.expectEqualStrings("opencode-go/claude-haiku-5-5", restored.connection().current().selection_name.?);
        try std.testing.expectEqualStrings(native, restored.app.?.runtime.messages()[1].replay.?.json);
        const actual = try Wire.encode(a, &restored);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected.?, actual);
        try std.testing.expect(!restored.resume_lease.?.active);
        try std.testing.expect(!try restored.saveOnExit());
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "must-not-run.txt", .{}));
    }
}

test "closed turn checkpoint is resumable before exit" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var id: ids.Id = undefined;
    {
        var source = try Session.init(a, io, &env, home, .{});
        defer source.deinit();
        try source.connection().configure("fake-incremental-checkpoint");
        id = source.session_id;
        try source.app.?.runtime.restoreCheckpoint(.{
            .system = "saved system",
            .selector = source.app.?.runtime.selector,
            .estimator = .{},
            .last_context_tokens = null,
            .permission_id = 0,
            .messages = &.{
                .{ .role = .user, .blocks = &.{.{ .text = "incremental question" }} },
                .{ .role = .assistant, .blocks = &.{.{ .text = "incremental answer" }} },
            },
        });
        source.app.?.runtime.observer.notify(.{ .event = .{ .assistant_committed = &.{.{ .text = "incremental answer" }} } });
        try std.testing.expect(source.checkpointError() == null);
        try std.testing.expect(source.resume_lease != null);
        try std.testing.expect(!source.resume_lease.?.active);
        var selection_path: [80]u8 = undefined;
        const relative = try std.fmt.bufPrint(&selection_path, ".thin/sessions/{s}.selection.json", .{id});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, relative, .{}));
        releaseLease(&source);
    }
    {
        var resumed = try Session.initWithOptions(a, io, &env, home, .{}, .{ .resume_session = id, .logging = false });
        defer resumed.deinit();
        try std.testing.expectEqual(@as(usize, 2), resumed.app.?.runtime.messages().len);
        try std.testing.expectEqualStrings("incremental question", resumed.app.?.runtime.messages()[0].blocks[0].text);
        try std.testing.expectEqualStrings("incremental answer", resumed.app.?.runtime.messages()[1].blocks[0].text);
        try std.testing.expect(!resumed.resume_lease.?.active);
    }
}

test "checkpoint save conflict reaches UI without changing restored history" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var source = try fixture.open(.{});
    defer source.deinit();
    try source.connection().configure("fake-checkpoint-conflict");
    try seedSessionTestHistory(&source);
    source.publishCheckpoint();
    try std.testing.expect(source.resume_lease != null);
    try std.testing.expect(source.checkpointError() == null);
    source.setCheckpointFailure(error.NoSpaceLeft);
    try std.testing.expectEqual(error.NoSpaceLeft, source.connection().current().log_error.?);
    source.publishCheckpoint();
    try std.testing.expect(source.checkpointError() == null);
    var buffer: [100]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".thin/sessions/{s}.session", .{source.session_id});
    // Simulate a noncooperating writer; publication must retain the disk CAS.
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "externally changed generation" });
    source.publishCheckpoint();
    try std.testing.expectEqual(error.ResumeConflict, source.checkpointError().?);
    try std.testing.expectEqual(error.ResumeConflict, source.connection().current().log_error.?);
    try expectSessionTestHistory(&source);
}

// Independent async/metadata regressions. These are real disk declarations in
// the llm schema, not legacy Config -> registry conversion helpers. Presets have
// no manual patches so refreshed capabilities remain visible in picker rows.
fn writeOfficialMetadataTestConfig(dir: std.Io.Dir, id: ProviderId) !void {
    try writeSessionTestConfig(dir, switch (id) {
        .deepseek =>
        \\{"llm":{"default":"deepseek/deepseek-flash","providers":{"deepseek":{"base_url":"https://api.deepseek.com","kind":"deepseek","chat_max_tokens":true}}},"limits":{"low_price_input":false}}
        ,
        .opencode_go =>
        \\{"llm":{"default":"opencode-go/minimax-m2.7","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","chat_max_tokens":true}}},"limits":{"low_price_input":false}}
        ,
        .opencode_zen =>
        \\{"llm":{"default":"opencode-zen/minimax-m2.7","providers":{"opencode-zen":{"base_url":"https://opencode.ai/zen/v1","kind":"opencode_zen","chat_max_tokens":true}}},"limits":{"low_price_input":false}}
        ,
    });
}

const MetadataFixture = struct {
    var calls: std.atomic.Value(usize) = .init(0);
    fn fetch(_: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
        _ = calls.fetchAdd(1, .monotonic);
        if (key == null or !std.mem.startsWith(u8, key.?, "fake-")) return error.InvalidFixtureKey;
        var values: metadata.Listing = .{};
        values.directory_mask = metadata.bit(id);
        for (catalog.entries) |entry| if (entry.provider == id) {
            const row = try values.directory.upsert(id, entry.model.name);
            row.tokens = 1048576;
            row.available = true;
            row.protocol = entry.model.protocol;
        };
        return values;
    }
    fn fail(_: std.mem.Allocator, _: std.Io, _: ProviderId, _: ?[]const u8) !metadata.Listing {
        return error.FixtureOffline;
    }
    fn stall(_: std.mem.Allocator, io: std.Io, _: ProviderId, _: ?[]const u8) !metadata.Listing {
        try std.Io.sleep(io, .fromSeconds(30), .awake);
        return error.UnexpectedFixtureTimeout;
    }
    /// Offline models.dev stand-in: a successful empty public catalog.
    fn dev(_: std.mem.Allocator, _: std.Io) !metadata.Listing {
        return .{ .dev_done = true };
    }
    fn waitDone(io: std.Io, done: *std.atomic.Value(bool)) !void {
        // Bounded fixture synchronization; leave Future ownership to pollModels.
        const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
        while (!done.load(.acquire)) {
            if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.FixtureCompletionTimeout;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }
    fn finish(session: *Session) void {
        const job = session.metadata_job.?;
        if (job.future) |*future| future.await(session.io);
        job.future = null;
        if (job.dev_future) |*future| future.await(session.io);
        job.dev_future = null;
    }
};

const LayeredMetadataFixture = struct {
    var official_effort: std.atomic.Value(bool) = .init(false);
    var dev_calls: std.atomic.Value(usize) = .init(0);
    fn official(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
        if (id != .opencode_go or key == null or !std.mem.startsWith(u8, key.?, "fake-")) return error.UnexpectedFixtureCredential;
        const body = if (official_effort.load(.acquire))
            "{\"data\":[{\"id\":\"gpt-6-luna\"},{\"id\":\"claude-haiku-5-5\",\"effort\":{\"supported_levels\":[\"high\"]}}]}"
        else
            "{\"data\":[{\"id\":\"gpt-6-luna\",\"context_window\":262144},{\"id\":\"claude-haiku-5-5\",\"context_window\":65536}]}";
        return metadata.parseListing(a, body, id);
    }
    fn dev(a: std.mem.Allocator, _: std.Io) !metadata.Listing {
        _ = dev_calls.fetchAdd(1, .monotonic);
        return metadata.parseDev(a, @embedFile("models_dev_fixture.json"));
    }
    fn devStall(_: std.mem.Allocator, io: std.Io) !metadata.Listing {
        try std.Io.sleep(io, .fromSeconds(60), .awake);
        return error.UnexpectedFixtureTimeout;
    }
    fn devFail(_: std.mem.Allocator, _: std.Io) !metadata.Listing {
        return error.FixtureOffline;
    }
    fn row(records: *const directory.Directory, provider: ProviderId, raw_id: []const u8) directory.Record {
        return records.rows[records.find(provider, raw_id).?];
    }
};

test "initial default adopts late public metadata without cycling or normalizing preference" {
    const Fetch = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn official(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
            try std.testing.expectEqual(ProviderId.opencode_go, id);
            try std.testing.expectEqualStrings("fake-public-effort", key.?);
            return metadata.parseListing(a, "{\"data\":[{\"id\":\"gpt-6-luna\",\"context_window\":131072}]}", id);
        }
        fn public(a: std.mem.Allocator, io: std.Io) !metadata.Listing {
            const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
            while (!release.load(.acquire)) {
                if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.FixtureCompletionTimeout;
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
            return metadata.parseDev(a, @embedFile("models_dev_fixture.json"));
        }
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false, .auto_refresh_models = true });
    defer session.deinit();
    Fetch.release.store(false, .release);
    defer Fetch.release.store(true, .release);
    session.metadata_fetch = Fetch.official;
    session.metadata_dev_fetch = Fetch.public;
    try session.connection().configureProvider(.opencode_go, "fake-public-effort");
    try session.connection().selectModel("opencode-go/gpt-6-luna");
    const before = session.app.?.config.value.model;
    try std.testing.expect(before.reasoning == null);
    try std.testing.expect(Session.pollModels(&session, true));
    const job = session.metadata_job.?;
    if (job.future) |*future| future.await(io);
    job.future = null;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectError(error.ThinkingCapabilitiesLoading, Session.cycleEffort(&session));
    try std.testing.expect(session.app.?.config.value.model.reasoning == null);
    Fetch.release.store(true, .release);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expect(!session.initial_default_pending);
    if (session.settings_notice) |notice| try std.testing.expect(std.mem.find(u8, notice, "not applied") == null);
    try std.testing.expectEqual(presentation.ReasoningEffort.medium, try persistedEffortForTest(&session));
    const config = session.app.?.config.value;
    const next = session.capabilitiesFor(config).levels.clamp(.medium).?;
    try std.testing.expectEqual(presentation.ReasoningEffort.medium, session.preferred_effort.?);
    try std.testing.expectEqual(cfg.ReasoningSource.metadata, config.model.reasoning_source);
    try std.testing.expectEqualStrings(next.name().?, config.model.reasoning_effort.?);
    try std.testing.expect(session.capabilitiesFor(config).levels.contains(next));
    try std.testing.expectEqual(before.context_tokens, config.model.context_tokens);
    try std.testing.expectEqual(before.output_tokens, config.model.output_tokens);
    try std.testing.expectEqual(before.protocol, config.model.protocol);
    // Subsequent refreshes must not replace the now-accepted map.
    const accepted = config.model.reasoning;
    session.metadata_cache = .{};
    try std.testing.expectEqualStrings(next.name().?, session.app.?.config.value.model.reasoning_effort.?);
    _ = try Session.cycleEffort(&session);
    try std.testing.expect(Session.sameDeclaration(accepted, session.app.?.config.value.model.reasoning));
    try std.testing.expect(!session.app.?.journal.started);
}

test "DeepSeek then Go Haiku selection applies global default with early or late capabilities" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |late| {
        for ([_]presentation.ReasoningEffort{ .medium, .high }) |wanted| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path: [4096]u8 = undefined;
            const home = path[0..try tmp.dir.realPath(io, &path)];
            var env = std.process.Environ.Map.init(a);
            defer env.deinit();
            try env.put("HOME", home);
            var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
            defer session.deinit();
            try setGlobalEffortForTest(&session, wanted);
            session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.deepseek), try metadata.parseListing(a,
                \\{"data":[{"id":"deepseek-flash","effort":{"supported_levels":["off","low","high","max"]}}]}
            , .deepseek));
            try session.connection().configureProvider(.deepseek, "fake-haiku-sequence-ds");
            try std.testing.expectEqualStrings("deepseek-flash", session.app.?.config.value.model.name);
            try std.testing.expectEqualStrings("high", session.app.?.config.value.model.reasoning_effort.?);
            const go_unknown = try metadata.parseListing(a,
                \\{"data":[{"id":"claude-haiku-5-5","protocol":"anthropic"}]}
            , .opencode_go);
            const go_known = try metadata.parseListing(a,
                \\{"data":[{"id":"claude-haiku-5-5","protocol":"anthropic","effort":{"format":"anthropic","supported_levels":["off","low","medium","high","max"]}}]}
            , .opencode_go);
            session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), if (late) go_unknown else go_known);
            try session.connection().configureProvider(.opencode_go, "fake-haiku-sequence-go");
            try std.testing.expectEqualStrings("deepseek-flash", session.app.?.config.value.model.name);
            try session.connection().selectModel("opencode-go/claude-haiku-5-5");
            const before = session.app.?.config.value.model;
            if (late) {
                try std.testing.expect(session.initial_default_pending);
                try std.testing.expect(before.reasoning == null and before.reasoning_effort == null);
                try std.testing.expectEqual(wanted, session.connection().current().pending_default_effort.?);
                session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), go_known);
                const borrowed = session.effortCandidate(session.app.?.config.value).model.reasoning.?.map.high.?;
                try std.testing.expect(!(try session.completeInitialDefault(false)));
                session.app.?.runtime.busy.store(true, .release);
                try std.testing.expect(!(try session.completeInitialDefault(true)));
                session.app.?.runtime.busy.store(false, .release);
                try std.testing.expect(try session.completeInitialDefault(true));
                try std.testing.expect(borrowed.ptr != session.app.?.config.value.model.reasoning.?.map.high.?.ptr);
            }
            const model = session.app.?.config.value.model;
            try std.testing.expectEqualStrings(wanted.name().?, model.reasoning_effort.?);
            try std.testing.expectEqual(thinking.Format.anthropic, model.reasoning.?.format);
            try std.testing.expectEqual(wanted, session.connection().current().reasoning_effort);
            try std.testing.expectEqual(wanted, session.app.?.journal.selection.?.effort.?);
            try std.testing.expectEqual(model.protocol, session.app.?.journal.selection.?.protocol);
            try std.testing.expectEqualStrings(model.name, session.app.?.journal.selection.?.model());
            try std.testing.expectEqual(before.context_tokens, model.context_tokens);
            try std.testing.expectEqual(before.output_tokens, model.output_tokens);
            try std.testing.expectEqual(before.protocol, model.protocol);
            try std.testing.expectEqual(before.input_price_threshold, model.input_price_threshold);
            try std.testing.expectEqual(before.input_price_flat_limit, model.input_price_flat_limit);
            try std.testing.expect(!session.initial_default_pending);
            try std.testing.expectEqual(wanted, try persistedEffortForTest(&session));
            var disk = try session.store.loadExisting();
            defer cfg.release(&disk);
            try std.testing.expectEqualStrings("opencode-go/claude-haiku-5-5", disk.value.registry.?.default);
            try std.testing.expect(disk.value.registry.?.find("opencode-go").?.patchFor("claude-haiku-5-5") == null);
            session.metadata_cache = .{};
            try std.testing.expect(!(try session.completeInitialDefault(true)));
            try std.testing.expectEqualStrings(wanted.name().?, session.app.?.config.value.model.reasoning_effort.?);
            try std.testing.expect(!session.app.?.journal.started);
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".thin/settings.json", .{}));
        }
    }
}

test "first activation defaults clamp without changing preference and own late cache maps" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]presentation.ReasoningEffort{ .medium, .off, .high }) |saved| {
        for ([_]bool{ false, true }) |late| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var buffer: [4096]u8 = undefined;
            const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
            var env = std.process.Environ.Map.init(a);
            defer env.deinit();
            try env.put("HOME", home);
            // Login activates the preselected alias. Declare it without a key;
            // selecting an undeclared provider before /login is not onboarding.
            try writeSessionTestConfig(tmp.dir,
                \\{"llm":{"default":"opencode-go/gpt-6-luna","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go"}}},"limits":{"low_price_input":false}}
            );
            var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
            defer session.deinit();
            try setGlobalEffortForTest(&session, saved);
            const listing = try metadata.parseListing(a, "{\"data\":[{\"id\":\"gpt-6-luna\",\"effort\":{\"supported_levels\":[\"off\",\"low\",\"high\",\"max\"]}}]}", .opencode_go);
            if (!late) session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), listing);
            try session.connection().configureProvider(.opencode_go, "fake-default-effort");
            const before = session.app.?.config.value.model;
            if (late) {
                try std.testing.expect(session.initial_default_pending);
                try std.testing.expectEqual(saved, session.connection().current().pending_default_effort.?);
                try std.testing.expect(before.reasoning_effort == null);
                session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), listing);
                const borrowed = session.effortCandidate(session.app.?.config.value).model.reasoning.?.map.high.?;
                try std.testing.expect(!(try session.completeInitialDefault(false)));
                session.app.?.runtime.busy.store(true, .release);
                try std.testing.expect(!(try session.completeInitialDefault(true)));
                session.app.?.runtime.busy.store(false, .release);
                session.read_only = true;
                try std.testing.expect(!(try session.completeInitialDefault(true)));
                session.read_only = false;
                try std.testing.expect(try session.completeInitialDefault(true));
                try std.testing.expect(borrowed.ptr != session.app.?.config.value.model.reasoning.?.map.high.?.ptr);
            }
            const config = session.app.?.config.value;
            const cap = session.capabilitiesFor(config);
            try std.testing.expectEqualStrings(cap.effective(saved.name()).?, config.model.reasoning_effort.?);
            try std.testing.expectEqual(saved, try persistedEffortForTest(&session));
            try std.testing.expect(!session.initial_default_pending);
            try std.testing.expectEqual(before.context_tokens, config.model.context_tokens);
            try std.testing.expectEqual(before.output_tokens, config.model.output_tokens);
            try std.testing.expectEqual(before.protocol, config.model.protocol);
            try std.testing.expectEqual(before.input_price_threshold, config.model.input_price_threshold);
            const accepted = config.model.reasoning;
            session.metadata_cache = .{};
            try std.testing.expect(!(try session.completeInitialDefault(true)));
            try std.testing.expect(Session.sameDeclaration(accepted, session.app.?.config.value.model.reasoning));
            try std.testing.expectEqualStrings(cap.map.high.?, session.app.?.config.value.model.reasoning.?.map.high.?);
            try std.testing.expect(!session.app.?.journal.started);
        }
    }
}

test "initial default stops after journal start and never overwrites an accepted effort or map" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-default-journal");
    try session.connection().selectModel("opencode-go/gpt-6-luna");
    const app = session.app.?;
    try std.testing.expect(session.initial_default_pending);
    app.journal.started = true;
    try std.testing.expect(try session.completeInitialDefault(true));
    app.journal.started = false;
    try std.testing.expect(!session.initial_default_pending);
    const listing = try metadata.parseListing(a, "{\"data\":[{\"id\":\"gpt-6-luna\",\"effort\":{\"supported_levels\":[\"low\",\"high\"]}}]}", .opencode_go);
    session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), listing);
    try std.testing.expect(!(try session.completeInitialDefault(true)));
    try std.testing.expect(app.config.value.model.reasoning == null);
    for ([_][]const u8{ "off", "high" }) |effort| {
        session.initial_default_pending = true;
        app.config.value.model.reasoning_effort = effort;
        _ = try session.completeInitialDefault(true);
        try std.testing.expectEqualStrings(effort, app.config.value.model.reasoning_effort.?);
        try std.testing.expect(app.config.value.model.reasoning == null);
    }
    app.config.value.model.reasoning_effort = null;
    app.config.value.model.reasoning = .{ .map = .{ .low = "accepted-low" } };
    session.initial_default_pending = true;
    _ = try session.completeInitialDefault(true);
    try std.testing.expectEqualStrings("accepted-low", app.config.value.model.reasoning.?.map.low.?);
    try std.testing.expect(app.config.value.model.reasoning_effort == null);
    // Stopping automatic initialization must not disable explicit cache adoption.
    app.config.value.model.reasoning = null;
    try std.testing.expectEqual(presentation.ReasoningEffort.low, try Session.cycleEffort(&session));
    try std.testing.expectEqualStrings("low", app.config.value.model.reasoning_effort.?);
}

test "effort action cannot borrow official reasoning for a proxy kind hint" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSessionTestConfig(tmp.dir,
        \\{"llm":{"default":"proxy/deepseek-flash","providers":{"proxy":{"base_url":"https://proxy.invalid/v1","kind":"deepseek","api_key":"fake-proxy-effort","models":{"deepseek-flash":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"low_price_input":false}}
    );
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    const listing = try metadata.parseListing(a, "{\"data\":[{\"id\":\"deepseek-flash\",\"effort\":{\"supported_levels\":[\"low\",\"high\",\"max\"]}}]}", .deepseek);
    session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.deepseek), listing);
    try std.testing.expect(!(try session.completeInitialDefault(true)));
    try std.testing.expectError(error.ThinkingCapabilitiesUnknown, Session.cycleEffort(&session));
    try std.testing.expect(session.app.?.config.value.model.reasoning == null);
    try std.testing.expect(session.app.?.config.value.model.reasoning_effort == null);
    try std.testing.expectEqual(@as(u8, 0), session.connection().current().effort_levels.mask);
    try std.testing.expect(!session.app.?.journal.started);
}

test "timed automatic metadata refresh repeats while active capabilities stay frozen" {
    const Fixture = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn fetch(a: std.mem.Allocator, _: std.Io, _: ProviderId, _: ?[]const u8) !metadata.Listing {
            const call = calls.fetchAdd(1, .monotonic);
            return metadata.parseListing(a, if (call == 0)
                "{\"data\":[{\"id\":\"deepseek-flash\",\"protocol\":\"chat\",\"context_window\":131072}]}"
            else
                "{\"data\":[{\"id\":\"deepseek-flash\",\"protocol\":\"chat\",\"context_window\":262144}]}", .deepseek);
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    Fixture.calls.store(0, .monotonic);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = true, .logging = false });
    defer session.deinit();
    session.metadata_fetch = Fixture.fetch;
    session.metadata_dev_fetch = MetadataFixture.dev;
    session.metadata_wall_ms = 1000000;
    session.metadata_awake_ms = 1000000;
    try session.connection().configureProvider(.deepseek, "fake-timed-refresh");
    const before = session.mutableConfig().*.model;
    const effort = session.connection().current().reasoning_effort;
    try std.testing.expect(Session.pollModels(&session, true)); // Login override.
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(u32, 131072), session.connection().current().models[0].context_tokens);
    session.metadata_wall_ms = 1000000 + session.refreshPolicy().ttl_ms - 1;
    session.metadata_awake_ms = 2000000;
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    session.metadata_wall_ms = session.metadata_wall_ms.? + 1;
    // Wall TTL alone cannot bypass the monotonic owner cadence.
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    session.metadata_awake_ms = 2060000;
    try std.testing.expect(!Session.pollModels(&session, false));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job != null);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 2), Fixture.calls.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 262144), session.connection().current().models[0].context_tokens);
    try std.testing.expectEqual(before.context_tokens, session.mutableConfig().*.model.context_tokens);
    try std.testing.expectEqual(before.output_tokens, session.mutableConfig().*.model.output_tokens);
    try std.testing.expectEqual(effort, session.connection().current().reasoning_effort);
    try std.testing.expect(!session.app.?.journal.started);
}

test "manual metadata refresh filters obsolete credentials even with automatic refresh disabled" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false, .auto_refresh_models = false });
    defer session.deinit();
    session.metadata_fetch = MetadataFixture.fetch;
    session.metadata_dev_fetch = MetadataFixture.dev;
    MetadataFixture.calls.store(0, .monotonic);
    try session.connection().configureProvider(.deepseek, "fake-stale-first-key");
    var previous: metadata.Listing = .{ .directory_mask = metadata.bit(.deepseek) };
    const previous_row = try previous.directory.upsert(.deepseek, "deepseek-flash");
    previous_row.available = true;
    previous_row.protocol = .chat;
    previous_row.tokens = 65536;
    previous_row.reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } });
    session.metadata_cache = try metadata.commitAt(&session.store.root, metadata.bit(.deepseek), previous, 1000);
    session.metadata_wall_ms = 2000;
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session); // Completed with the old key, not yet published.
    try session.connection().configureProvider(.deepseek, "fake-stale-new-key");
    try std.testing.expect(session.metadata_login_pending == 0); // No automatic re-query permission.
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&session.metadata_cache.directory, .deepseek, "deepseek-flash").tokens);
    try std.testing.expectEqualStrings("high", LayeredMetadataFixture.row(&session.metadata_cache.directory, .deepseek, "deepseek-flash").reasoning.?.declaration().map.high.?);
    const stale_disk = try metadata.load(&session.store.root);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&stale_disk.directory, .deepseek, "deepseek-flash").tokens);
    try std.testing.expectEqual(@as(?u64, 1000), session.metadata_cache.refresh[0].last_success_ms);
    try std.testing.expect(!session.metadata_cache.refresh[0].successful);
    try std.testing.expectEqual(@as(?u64, 2000), session.metadata_cache.refresh[3].last_success_ms);
    try std.testing.expect(session.metadata_cache.refresh[3].successful);
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 1), MetadataFixture.calls.load(.monotonic));
    // A new explicit refresh uses the replacement credential and can publish.
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(?u32, 1048576), LayeredMetadataFixture.row(&session.metadata_cache.directory, .deepseek, "deepseek-flash").tokens);
    try std.testing.expectEqual(@as(?u64, 2000), session.metadata_cache.refresh[0].last_success_ms);
    try std.testing.expect(session.metadata_cache.refresh[0].successful);
}

test "models.dev completion survives a stalled official source and owner teardown cancels both" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    session.metadata_fetch = MetadataFixture.stall;
    session.metadata_dev_fetch = LayeredMetadataFixture.dev;
    try session.connection().configureProvider(.opencode_go, "fake-stalled-official");
    try Session.refreshModels(&session);
    const job = session.metadata_job.?;
    try MetadataFixture.waitDone(session.io, &job.dev_done);
    try std.testing.expect(job.dev_future != null); // pollModels owns the actual join.
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqualStrings("max", LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.max.?);
    try std.testing.expect(job.future != null);
    job.started_ms -= official_metadata_timeout_ms + 1;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    session.metadata_dev_fetch = LayeredMetadataFixture.devStall;
    try Session.refreshModels(&session);
    // deinit must cancel/join both futures and wipe the official key copies.
}

test "official results publish while models.dev retains an independent longer deadline" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    session.metadata_fetch = LayeredMetadataFixture.official;
    session.metadata_dev_fetch = LayeredMetadataFixture.devStall;
    LayeredMetadataFixture.official_effort.store(false, .release);
    try session.connection().configureProvider(.opencode_go, "fake-deadline-go");
    const previous = try metadata.parseDev(a, @embedFile("models_dev_fixture.json"));
    session.metadata_cache = try metadata.commit(&session.store.root, 0, previous);
    try Session.refreshModels(&session);
    const job = session.metadata_job.?;
    try MetadataFixture.waitDone(session.io, &job.done);
    try std.testing.expect(job.future != null); // pollModels owns the actual join.
    job.started_ms -= official_metadata_timeout_ms + 1;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == job and job.dev_future != null);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").tokens);
    for (job.keys) |key| try std.testing.expect(key == null);
    // Passing the old shared deadline does not cancel the public catalog.
    job.dev_started_ms -= official_metadata_timeout_ms + 1;
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(job.dev_future != null);
    job.dev_started_ms -= models_dev_timeout_ms;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    const saved = try metadata.load(&session.store.root);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&saved.directory, .opencode_go, "claude-haiku-5-5").tokens);
    try std.testing.expectEqualStrings("max", LayeredMetadataFixture.row(&saved.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.max.?);
    try std.testing.expect(!Session.pollModels(&session, true)); // No tight automatic retry loop.
    // A user retry can still complete after the cancelled catalog attempt.
    session.metadata_dev_fetch = LayeredMetadataFixture.dev;
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqualStrings("max", LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.max.?);
}

test "login with new credentials refreshes official metadata without waiting for stalled models.dev" {
    const Fixture = struct {
        fn official(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
            if (id != .opencode_go) return error.UnexpectedProvider;
            const rotated = std.mem.eql(u8, key orelse return error.MissingFixtureKey, "fake-rotated-go");
            return metadata.parseListing(a, if (rotated)
                "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"context_window\":131072}]}"
            else
                "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"context_window\":65536}]}", id);
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false, .auto_refresh_models = true });
    defer session.deinit();
    session.metadata_fetch = Fixture.official;
    session.metadata_dev_fetch = LayeredMetadataFixture.devStall;
    try session.connection().configureProvider(.opencode_go, "fake-initial-go");
    try std.testing.expect(Session.pollModels(&session, true));
    const job = session.metadata_job.?;
    const public_started = job.dev_started_ms;
    try MetadataFixture.waitDone(session.io, &job.done);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(job.future == null and job.dev_future != null);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").tokens);
    try session.connection().configureProvider(.opencode_go, "fake-rotated-go");
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == job and job.future != null);
    try std.testing.expectEqual(public_started, job.dev_started_ms);
    try std.testing.expect(job.dev_future != null); // Existing public download not restarted.
    try MetadataFixture.waitDone(session.io, &job.done);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(?u32, 131072), LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").tokens);
    const rotated_disk = try metadata.load(&session.store.root);
    try std.testing.expectEqual(@as(?u32, 131072), LayeredMetadataFixture.row(&rotated_disk.directory, .opencode_go, "claude-haiku-5-5").tokens);
    try std.testing.expect(job.dev_future != null and session.metadata_login_pending == 0);
    job.dev_started_ms -= models_dev_timeout_ms + 1;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
}

test "login refreshes only saved provider despite prior attempt and queues behind old credentials" {
    const Fixture = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn fetch(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
            _ = calls.fetchAdd(1, .monotonic);
            if (id != .opencode_go) return error.UnexpectedProvider;
            const k = key orelse return error.MissingFixtureKey;
            if (std.mem.eql(u8, k, "fake-go-fail")) return error.FixtureOffline;
            const body = if (std.mem.eql(u8, k, "fake-go-haiku-only"))
                "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"context_window\":65536}]}"
            else if (std.mem.eql(u8, k, "fake-go-full"))
                "{\"data\":[{\"id\":\"minimax-m2.7\"},{\"id\":\"claude-haiku-5-5\"},{\"id\":\"kimi-k3\"}]}"
            else
                return error.UnexpectedFixtureKey;
            return metadata.parseListing(a, body, id);
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = true });
    defer session.deinit();
    session.metadata_fetch = Fixture.fetch;
    session.metadata_dev_fetch = MetadataFixture.dev;
    Fixture.calls.store(0, .monotonic);
    _ = try metadata.claim(&session.store.root, metadata.bit(.opencode_go), false);
    try session.connection().configureProvider(.opencode_go, "fake-go-full");
    const original = session.connection().current().context_limit;
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(@as(usize, 0), Fixture.calls.load(.monotonic));
    try std.testing.expect(!Session.pollModels(&session, false)); // Owner must be idle.
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(metadata.bit(.opencode_go) | metadata.dev_bit, session.metadata_job.?.requested);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 3), session.connection().current().models.len);
    try std.testing.expectEqual(original, session.connection().current().context_limit);
    try session.connection().configureProvider(.opencode_go, "fake-go-full");
    try std.testing.expect(Session.pollModels(&session, true));
    // A second save must not cancel/join in the key callback, or accept the old
    // worker's list as the result of this new login. Queue the newest key instead.
    try session.connection().configureProvider(.opencode_go, "fake-go-haiku-only");
    try std.testing.expectEqual(metadata.bit(.opencode_go), session.metadata_login_pending);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 3), session.connection().current().models.len);
    try std.testing.expect(Session.pollModels(&session, true));
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    const updated = session.connection().current();
    try std.testing.expectEqual(@as(usize, 1), updated.models.len);
    try std.testing.expectEqualStrings("opencode-go/claude-haiku-5-5", updated.models[0].name);
    try std.testing.expectEqual(@as(u32, 65536), updated.models[0].context_tokens);
    try std.testing.expect(updated.model_context_official[0]);
    try std.testing.expectEqual(original, updated.context_limit);
    try std.testing.expectEqualStrings("minimax-m2.7", updated.model); // No forced model change.
    try session.connection().configureProvider(.opencode_go, "fake-go-fail");
    try std.testing.expect(Session.pollModels(&session, true));
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 1), session.connection().current().models.len);
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null and session.metadata_login_pending == 0);
    try std.testing.expectEqual(@as(usize, 4), Fixture.calls.load(.monotonic));
    try std.testing.expect(std.mem.find(u8, session.metadata_notice.?, "failed") != null);
}

test "manual refresh asynchronously discovers new IDs and preserves public protocols through picker selection and reload" {
    const Fixture = struct {
        var requested: std.atomic.Value(u8) = .init(0);
        var public_calls: std.atomic.Value(usize) = .init(0);
        fn official(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
            if (key == null or !std.mem.eql(u8, key.?, "fake-async-directory-key")) return error.InvalidFixtureKey;
            _ = requested.fetchOr(metadata.bit(id), .monotonic);
            return metadata.parseListing(a,
                \\{"data":[{"id":"future-official-id","context_window":131072},{"id":"future-unknown","context_window":65536}]}
            , id);
        }
        fn public(a: std.mem.Allocator, _: std.Io) !metadata.Listing {
            _ = public_calls.fetchAdd(1, .monotonic);
            return metadata.parseDev(a,
                \\{"deepseek":{"npm":"@ai-sdk/deepseek","models":{"future-official-id":{}}},"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"future-official-id":{"provider":{"npm":"@ai-sdk/openai"}}}},"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"future-official-id":{"provider":{"npm":"@ai-sdk/openai"}}}}}
            );
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    session.metadata_fetch = Fixture.official;
    session.metadata_dev_fetch = Fixture.public;
    for (ProviderId.all) |id| try session.connection().configureProvider(id, "fake-async-directory-key");
    Fixture.requested.store(0, .monotonic);
    Fixture.public_calls.store(0, .monotonic);
    const before = session.mutableConfig().model;
    try Session.refreshModels(&session);
    const job = session.metadata_job.?;
    try std.testing.expectEqual(metadata.provider_mask | metadata.dev_bit, job.requested);
    try MetadataFixture.waitDone(session.io, &job.done);
    try MetadataFixture.waitDone(session.io, &job.dev_done);
    // Worker results remain private until owner join and revision filtering.
    try std.testing.expectEqual(@as(usize, 0), session.metadata_cache.directory.count);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(metadata.provider_mask, Fixture.requested.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), Fixture.public_calls.load(.monotonic));
    const state = session.connection().current();
    try std.testing.expectEqual(before.protocol, session.mutableConfig().model.protocol);
    try std.testing.expectEqual(before.context_tokens, state.context_limit);
    try std.testing.expectEqualStrings(before.name, state.model);
    var picker = @import("../ui/model_picker.zig").Picker.init(a);
    defer picker.deinit();
    picker.allow_custom = false;
    const reloaded = try metadata.load(&session.store.root);
    for (ProviderId.all) |id| {
        const selector = try std.fmt.allocPrint(a, "{s}/future-official-id", .{id.slug()});
        defer a.free(selector);
        picker.clear();
        try std.testing.expect(try picker.insert(selector, false));
        const latest = session.connection().current();
        const choices = try picker.choicesWithProviders(a, latest.selection_name orelse latest.model, latest.context_limit, latest.models, latest.model_disabled, latest.model_providers);
        defer a.free(choices);
        try std.testing.expectEqual(@as(usize, 1), choices.len);
        try std.testing.expect(!choices[0].disabled);
        const entry = metadata.findEntry(&reloaded, selector).?;
        try std.testing.expectEqual(if (id == .deepseek) @import("../core/protocol.zig").Protocol.chat else .responses, entry.model.protocol);
        // The picker yields exactly the owner's dynamic qualified selector.
        try session.connection().selectModel(choices[0].name);
        try std.testing.expectEqual(entry.model.protocol, session.mutableConfig().model.protocol);
        try std.testing.expectEqual(@as(u32, 131072), session.mutableConfig().model.context_tokens);
    }
    try std.testing.expectError(error.UnknownModelProtocol, session.connection().selectModel("opencode-go/future-unknown"));
}

test "dynamic models.dev refresh reaches model picker, cached reload and selection preference without POST" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    LayeredMetadataFixture.official_effort.store(false, .release);
    LayeredMetadataFixture.dev_calls.store(0, .monotonic);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = true, .logging = false });
    defer session.deinit();
    session.metadata_fetch = LayeredMetadataFixture.official;
    session.metadata_dev_fetch = LayeredMetadataFixture.dev;
    try session.connection().configureProvider(.opencode_go, "fake-layered-go");
    try setGlobalEffortForTest(&session, .max);
    const active_before = session.app.?.config.value.model;
    try std.testing.expect(Session.pollModels(&session, true)); // First/login-triggered refresh.
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(@as(usize, 1), LayeredMetadataFixture.dev_calls.load(.monotonic));
    try std.testing.expectEqualStrings(active_before.name, session.app.?.config.value.model.name);
    try std.testing.expectEqual(active_before.context_tokens, session.app.?.config.value.model.context_tokens);
    try std.testing.expectEqual(active_before.output_tokens, session.app.?.config.value.model.output_tokens);
    for (session.connection().current().models) |model| {
        if (std.mem.eql(u8, model.name, "opencode-go/claude-haiku-5-5")) {
            try std.testing.expectEqual(thinking.Format.anthropic, model.reasoning.?.format);
            try std.testing.expectEqualStrings("max", model.reasoning.?.map.max.?);
            try std.testing.expect(model.reasoning.?.map.medium == null);
            try std.testing.expectEqual(@as(?u32, 16384), model.output_tokens);
            try std.testing.expectEqual(cfg.ReasoningSource.metadata, model.output_source);
            break;
        }
    } else return error.MissingModelPickerRow;
    const disk = try metadata.load(&session.store.root);
    try std.testing.expectEqualStrings("disabled", LayeredMetadataFixture.row(&disk.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.off.?);
    {
        var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = true, .logging = false });
        defer again.deinit();
        again.metadata_fetch = MetadataFixture.fail;
        again.metadata_dev_fetch = LayeredMetadataFixture.devFail;
        try std.testing.expect(!Session.pollModels(&again, true));
        try std.testing.expect(again.metadata_job == null); // Persisted attempt suppresses a restart fetch.
        again.preferred_effort = .max;
        // Check cached application without rewriting the shared config behind the
        // still-live first Session (whose auth-store digest protects such writes).
        var candidate_arena = std.heap.ArenaAllocator.init(a);
        defer candidate_arena.deinit();
        var candidate = again.global_config.?.value;
        model_resolver.apply(&candidate, try model_resolver.resolve(candidate_arena.allocator(), candidate, &again.metadata_cache, "opencode-go", "claude-haiku-5-5", false));
        try std.testing.expect(again.applyPreference(&candidate, again.preferred_effort, true) == null);
        try std.testing.expectEqualStrings("max", candidate.model.reasoning_effort.?);
        try std.testing.expectEqualStrings("disabled", candidate.model.reasoning.?.map.off.?);
    }
    try session.connection().selectModel("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqualStrings("max", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expect(session.app.?.runtime.messages().len == 0);
    try std.testing.expectEqual(@as(?u32, 16384), session.app.?.config.value.model.output_tokens);
    // Explicit manual refresh retries both sources. Official metadata overrides
    // fallback in picker and applyPreference; refresh alone leaves active options frozen.
    LayeredMetadataFixture.official_effort.store(true, .release);
    try session.connection().refresh_models_fn.?(session.connection().context);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 2), LayeredMetadataFixture.dev_calls.load(.monotonic));
    try std.testing.expectEqualStrings("max", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expect(LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").reasoning.?.declaration().map.max == null);
    // Credential activation keeps actual options, including output capability.
    // A subsequent deliberate catalog confirmation may use the fresh metadata.
    const output_row = session.metadata_cache.directory.find(.opencode_go, "claude-haiku-5-5").?;
    session.metadata_cache.directory.rows[output_row].dev_output_tokens = 32768;
    const frozen_capacity = session.app.?.config.value.model.context_tokens;
    try session.connection().configureProvider(.opencode_go, "fake-layered-rotated-go");
    try session.connection().selectModel("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqualStrings("max", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(frozen_capacity, session.app.?.config.value.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 16384), session.app.?.config.value.model.output_tokens);
    try session.connection().selectModel("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqualStrings("high", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(@as(?u32, 32768), session.app.?.config.value.model.output_tokens);
    // Same protocol/map/capacity is not a no-op if a fresh output limit changed.
    session.metadata_cache.directory.rows[output_row].dev_output_tokens = 65536;
    try session.connection().selectModel("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqual(@as(?u32, 65536), session.app.?.config.value.model.output_tokens);
    var persisted_defaults = try session.store.loadExisting();
    defer cfg.release(&persisted_defaults);
    try std.testing.expect(persisted_defaults.value.model.output_tokens == null);
    try std.testing.expect(persisted_defaults.value.limits.max_output_tokens == null);
    try std.testing.expectEqual(presentation.ReasoningEffort.max, session.preferred_effort.?);
    session.metadata_dev_fetch = LayeredMetadataFixture.devFail;
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    const failed_refresh_disk = try metadata.load(&session.store.root);
    try std.testing.expectEqualStrings("max", LayeredMetadataFixture.row(&failed_refresh_disk.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.max.?);
    try std.testing.expect(std.mem.find(u8, session.metadata_notice.?, "models.dev metadata refresh failed") != null);
}

test "dynamic official IDs select for all providers and reject unknown protocols without probing" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    for (ProviderId.all) |id| try session.connection().configureProvider(id, "fake-dynamic-key");
    session.metadata_cache.directory_mask = metadata.provider_mask;
    for (ProviderId.all) |id| {
        const row = try session.metadata_cache.directory.upsert(id, "new/vendor-model");
        row.available = true;
        row.tokens = 131072;
        row.protocol = if (id == .deepseek) .chat else .responses;
        const unknown = try session.metadata_cache.directory.upsert(id, "new-unknown");
        unknown.available = true;
    }
    const models = try session.buildModels(session.mutableConfig().*, session.global_config.?.value);
    session.freeDisplayModels(session.display_models);
    session.display_models = models;
    var state = session.connection().current();
    try std.testing.expectEqual(@as(usize, 6), state.models.len);
    for (state.models, 0..) |model, index| {
        try std.testing.expectEqual(model.protocol == .auto, state.model_disabled[index]);
    }
    for (ProviderId.all) |id| {
        const selector = try std.fmt.allocPrint(a, "{s}/new/vendor-model", .{id.slug()});
        defer a.free(selector);
        try session.connection().selectModel(selector);
        try std.testing.expectEqual(id, session.mutableConfig().provider.kind.?);
        try std.testing.expectEqualStrings("new/vendor-model", session.mutableConfig().model.name);
        try std.testing.expectEqual(@as(u32, 131072), session.mutableConfig().model.context_tokens);
        try std.testing.expect(session.active_context_official);
        try session.connection().selectModel("new/vendor-model");
        // Missing presets may be restored from history, but are not new choices.
        for (catalog.entries) |entry| if (entry.provider == id) {
            try std.testing.expectError(error.DefaultModelUnavailable, session.connection().selectModel(entry.selector));
            break;
        };
    }
    const before = session.mutableConfig().model;
    try std.testing.expectError(error.UnknownModelProtocol, session.connection().selectModel("opencode-go/new-unknown"));
    // Raw lookup uses the current provider, not a global raw-ID guess.
    const current_id = session.mutableConfig().provider.kind.?;
    if (current_id != .deepseek) try std.testing.expectError(error.UnknownModelProtocol, session.connection().selectModel("new-unknown"));
    try std.testing.expectEqualStrings(before.name, session.mutableConfig().model.name);
    const current_row = &session.metadata_cache.directory.rows[session.metadata_cache.directory.find(current_id, before.name).?];
    current_row.tokens = 65536;
    current_row.protocol = .chat;
    // Reading a refreshed catalog alone never mutates the active connection.
    state = session.connection().current();
    try std.testing.expectEqual(before.protocol, session.mutableConfig().model.protocol);
    try std.testing.expectEqual(before.context_tokens, state.context_limit);
    try session.connection().configureProvider(current_id, "fake-rotated-dynamic-key");
    try session.connection().selectModel(session.selected_alias.?);
    try std.testing.expectEqual(before.protocol, session.mutableConfig().model.protocol);
    try std.testing.expectEqual(before.context_tokens, session.mutableConfig().model.context_tokens);
    state = session.connection().current();
    try std.testing.expectEqual(before.context_tokens, state.context_limit);
}

test "login refresh opt out remains offline and explicit profiles survive availability filtering" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.init(a, std.testing.io, &env, home, .{});
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-go-offline");
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null and session.metadata_login_pending == 0);
    for (session.metadata_cache.directory.rows[0..session.metadata_cache.directory.count]) |*row| {
        if (row.provider == .opencode_go) row.available = false;
    }
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go);
    var explicit = try cfg.parse(a,
        \\{"llm":{"default":"opencode-go/kimi-k3","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"kimi-k3":{"context_tokens":65536,"protocol":"chat"}}}}},"limits":{"low_price_input":false}}
    );
    defer cfg.release(&explicit);
    // An explicit registry patch remains selectable after the official source
    // marks every preset unavailable; opting out must still launch no fetch.
    const models = try session.buildModels(session.mutableConfig().*, explicit.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("opencode-go/kimi-k3", models[0].name);
    try std.testing.expectEqual(@as(u32, 65536), models[0].context_tokens);
}

test "display candidates own names and explicit wires across cache and config replacement" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-owned-display-key");
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go);
    const row = try session.metadata_cache.directory.upsert(.opencode_go, "owned-cache-name");
    row.available = true;
    row.protocol = .chat;
    var profile_name = "owned-profile".*;
    var effort = "high".*;
    var wire = "custom-wire".*;
    var global = session.global_config.?.value;
    // Deliberately stack-backed registry declaration: buildModels must own its
    // published names and wire strings, just as for a released config arena.
    global.registry = .{ .default = "opencode-go/owned-profile", .providers = &.{.{
        .name = "opencode-go",
        .connection = catalog.connection(.opencode_go),
        .models = &.{.{ .name = &profile_name, .patch = .{
            .context_tokens = 32768,
            .protocol = .chat,
            .reasoning_effort = &effort,
            .reasoning = .{ .map = .{ .high = &wire } },
        } }},
    }} };
    const models = try session.buildModels(session.mutableConfig().*, global);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    // A movable Session/cache and a released config arena are equivalent to
    // replacing these backing bytes. Published rows must own separate storage.
    @memset(&session.metadata_cache.directory.names, 'X');
    profile_name[0] = 'X';
    effort[0] = 'X';
    wire[0] = 'X';
    try std.testing.expectEqualStrings("opencode-go/owned-cache-name", models[1].name);
    try std.testing.expectEqualStrings("opencode-go/owned-profile", models[0].name);
    try std.testing.expectEqualStrings("high", models[0].reasoning_effort.?);
    try std.testing.expectEqualStrings("custom-wire", models[0].reasoning.?.map.high.?);
}

test "raw explicit profile hides only the same provider dynamic identity" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-go-profile-key");
    try session.connection().configureProvider(.opencode_zen, "fake-zen-profile-key");
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go) | metadata.bit(.opencode_zen);
    for ([_]ProviderId{ .opencode_go, .opencode_zen }) |id| {
        const row = try session.metadata_cache.directory.upsert(id, "shared-profile");
        row.available = true;
        row.protocol = .chat;
    }
    var explicit = try cfg.parse(a,
        \\{"llm":{"default":"opencode-go/shared-profile","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"shared-profile":{"context_tokens":32768,"protocol":"chat"}}},"opencode-zen":{"base_url":"https://opencode.ai/zen/v1","kind":"opencode_zen"}}},"limits":{"low_price_input":false}}
    );
    defer cfg.release(&explicit);
    const models = try session.buildModels(session.mutableConfig().*, explicit.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("opencode-go/shared-profile", models[0].name);
    try std.testing.expectEqualStrings("opencode-zen/shared-profile", models[1].name);
}

test "explicit user reasoning overrides metadata and survives default persistence" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer source.deinit();
    // A manual registry patch is explicit; value/name similarity to metadata must not erase it.
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"opencode-go/gpt-6-luna","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"gpt-6-luna":{"protocol":"responses","context_tokens":32768,"reasoning_effort":"high","reasoning":{"map":{"high":"user-intensive"}}}}}}},"limits":{"low_price_input":false}}
    );
    defer cfg.release(&parsed);
    try model_resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &source.metadata_cache);
    var config = parsed.value;
    source.metadata_cache.directory_mask |= metadata.bit(.opencode_go);
    const row = try source.metadata_cache.directory.upsert(.opencode_go, "gpt-6-luna");
    row.available = true;
    row.protocol = .responses;
    row.dev_present = true;
    row.dev_protocol = .responses;
    row.reasoning = try @import("model_directory.zig").Profile.from(.{ .map = .{ .low = "low" } });
    row.dev_reasoning = try @import("model_directory.zig").Profile.from(.{ .map = .{ .max = "max" } });
    source.applyReasoningMetadata(&config);
    try std.testing.expectEqual(cfg.ReasoningSource.explicit, config.model.reasoning_source);
    try std.testing.expectEqualStrings("user-intensive", source.capabilitiesFor(config).wire("high").effort.?);
    const persisted = config.model.persisted();
    try std.testing.expectEqualStrings("user-intensive", persisted.reasoning.?.map.high.?);
    try std.testing.expectEqualStrings("high", persisted.reasoning_effort.?);
    var clone = try cfg.clone(a, config);
    defer cfg.release(&clone);
    try std.testing.expectEqualStrings("user-intensive", clone.value.model.reasoning.?.map.high.?);
}

test "derived reasoning stays in cache and cannot revive after a tied refresh or restart" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer source.deinit();
    try source.connection().configureProvider(.opencode_go, "fake-provenance-go");
    source.metadata_cache = try metadata.commit(&source.store.root, 0, try metadata.parseDev(a, @embedFile("models_dev_fixture.json")));
    try source.connection().selectModel("opencode-go/gpt-6-luna");
    try source.connection().setEffort(.max);
    try std.testing.expectEqual(cfg.ReasoningSource.metadata, source.app.?.config.value.model.reasoning_source);
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning.?.map.max.?);
    // A rejected preference write must not clear the active derived effort/map.
    const preference = try tmp.dir.readFileAlloc(std.testing.io, ".thin/config.json", a, .limited(65536));
    defer a.free(preference);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = "{}" });
    if (source.connection().setEffort(.low)) |_| return error.ExpectedPreferenceFailure else |_| {}
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning.?.map.max.?);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = preference });
    {
        var disk = try source.store.loadExisting();
        defer cfg.release(&disk);
        try std.testing.expectEqualStrings("opencode-go/gpt-6-luna", disk.value.registry.?.default);
        // The derived profile must not be materialized as a manual disk patch.
        try std.testing.expect(disk.value.registry.?.find("opencode-go").?.patchFor("gpt-6-luna") == null);
        try std.testing.expect(disk.value.model.reasoning == null and disk.value.model.reasoning_effort == null);
    }
    const tied =
        \\{"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"gpt-6-luna":{"reasoning":true,"provider":{"npm":"@ai-sdk/openai"}}}},"one":{"npm":"@ai-sdk/openai","models":{"gpt-6-luna":{"reasoning_options":[{"type":"effort","values":["high"]}]}}},"two":{"npm":"@ai-sdk/openai","models":{"gpt-6-luna":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    ;
    source.metadata_cache = try metadata.commit(&source.store.root, 0, try metadata.parseDev(a, tied));
    {
        var candidate_arena = std.heap.ArenaAllocator.init(a);
        defer candidate_arena.deinit();
        var candidate = source.global_config.?.value;
        model_resolver.apply(&candidate, try model_resolver.resolve(candidate_arena.allocator(), candidate, &source.metadata_cache, "opencode-go", "gpt-6-luna", false));
        try std.testing.expect(!source.capabilitiesFor(candidate).known);
    }
    // Until an explicit selection, the active runtime retains its frozen map.
    try std.testing.expect(source.capabilitiesFor(source.app.?.config.value).known);
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning.?.map.max.?);
    try source.connection().selectModel("opencode-go/gpt-6-luna");
    const model = source.app.?.config.value.model;
    try std.testing.expect(model.reasoning == null and model.reasoning_effort == null);
    try std.testing.expectEqual(presentation.ReasoningEffort.max, source.preferred_effort.?);
    for ([_]@import("../core/protocol.zig").Purpose{ .normal, .summary }) |purpose| {
        var base = @import("../tests/adapter_test_support.zig").request(.responses);
        base.purpose = purpose;
        const request = @import("../core/runtime.zig").withReasoning(source.app.?.config.value, base);
        try std.testing.expect(request.reasoning_effort == null and request.thinking == null);
    }
    {
        var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
        defer again.deinit();
        try std.testing.expect(!again.capabilitiesFor(again.mutableConfig().*).known);
        try std.testing.expect(again.mutableConfig().model.reasoning == null);
        try std.testing.expect(again.mutableConfig().model.reasoning_effort == null);
        try std.testing.expectEqual(presentation.ReasoningEffort.max, again.preferred_effort.?);
    }
    // Former preset maps (including Luna/Zen) also stay unknown with no source.
    source.metadata_cache = .{};
    for (catalog.entries) |entry| {
        const config: cfg.Config = .{ .provider = catalog.connection(entry.provider), .model = entry.model };
        try std.testing.expect(!source.capabilitiesFor(config).known);
        try std.testing.expect(source.declarationForEntry(entry) == null);
    }
}

test "official cached effort metadata overrides the models.dev fallback" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.init(a, std.testing.io, &env, home, .{});
    defer session.deinit();

    const entry = catalog.find("opencode-go/gpt-6-luna").?;
    const config: cfg.Config = .{ .provider = catalog.connection(.opencode_go), .model = entry.model };
    session.metadata_cache.directory_mask |= metadata.bit(.opencode_go);
    const row = try session.metadata_cache.directory.upsert(.opencode_go, "gpt-6-luna");
    row.available = true;
    row.protocol = .responses;
    row.reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .standard, .map = .{ .low = "low", .high = "high" } });
    const official = session.capabilitiesFor(config);
    try std.testing.expectEqualStrings("low", official.map.low.?);
    try std.testing.expect(official.map.max == null);
    row.reasoning = null;
    // Dynamic models.dev profiles are used only when official metadata is absent.
    row.dev_present = true;
    row.dev_protocol = .responses;
    row.dev_reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .standard, .map = .{ .low = "low", .max = "max", .off = "none" } });
    const fallback = session.capabilitiesFor(config);
    try std.testing.expectEqualStrings("low", fallback.map.low.?);
    try std.testing.expectEqualStrings("max", fallback.map.max.?);
    try std.testing.expectEqualStrings("none", fallback.map.off.?);
    row.dev_reasoning = null;
    try std.testing.expect(!session.capabilitiesFor(config).known); // Missing metadata stays unknown.
}

test "explicit raw and qualified profiles override dynamic rows including explicit auto" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeSessionTestConfig(tmp.dir,
        \\{"llm":{"default":"opencode-go/minimax-m2.7","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"raw-override":{"context_tokens":32768,"protocol":"auto"},"qualified-override":{"context_tokens":32768,"protocol":"chat"}}}}},"limits":{"low_price_input":false}}
    );
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-explicit-key");
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go);
    for ([_][]const u8{ "raw-override", "qualified-override", "visible-unknown" }) |name| {
        const row = try session.metadata_cache.directory.upsert(.opencode_go, name);
        row.available = true;
    }
    const models = try session.buildModels(session.mutableConfig().*, session.global_config.?.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("opencode-go/raw-override", models[0].name);
    try std.testing.expectEqualStrings("opencode-go/qualified-override", models[1].name);
    try std.testing.expectEqualStrings("opencode-go/visible-unknown", models[2].name);
    // Explicit auto is enabled by its own patch; the discovered unknown row is disabled.
    const old_models = session.display_models;
    session.display_models = models;
    const state = session.connection().current();
    const flags_match = std.mem.eql(bool, &.{ false, false, true }, state.model_disabled);
    session.display_models = old_models;
    try std.testing.expect(flags_match);
    try session.connection().selectModel("opencode-go/qualified-override");
    try std.testing.expectEqual(@import("../core/protocol.zig").Protocol.chat, session.mutableConfig().model.protocol);
}

test "new raw custom model never inherits the previous model output capability" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeSessionTestConfig(tmp.dir,
        \\{"llm":{"default":"custom/previous","providers":{"custom":{"base_url":"https://custom.invalid/v1","models":{"previous":{"protocol":"chat","context_tokens":131072,"output_tokens":65536},"custom-next":{"protocol":"chat","context_tokens":131072},"custom-declared":{"protocol":"chat","context_tokens":131072,"output_tokens":4096}}}}},"limits":{"low_price_input":false}}
    );
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer session.deinit();
    try std.testing.expectEqual(@as(?u32, 65536), session.mutableConfig().model.output_tokens);
    try session.connection().selectModel("custom-next");
    try std.testing.expect(session.mutableConfig().model.output_tokens == null);
    try session.connection().selectModel("custom-declared");
    try std.testing.expectEqual(@as(?u32, 4096), session.mutableConfig().model.output_tokens);
    try std.testing.expectEqual(.explicit, session.mutableConfig().model.output_source);
}

test "pending auth retains trusted derived map while saving only cache backed defaults" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer source.deinit();
    var listing: metadata.Listing = .{};
    listing.directory_mask = metadata.bit(.deepseek);
    const row = try listing.directory.upsert(.deepseek, "deepseek-flash");
    row.available = true;
    row.protocol = .chat;
    row.reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high", .max = "max" } });
    source.metadata_cache = try metadata.commit(&source.store.root, metadata.bit(.deepseek), listing);
    // Cache publication alone does not rewrite the pending resolved snapshot;
    // confirm the qualified candidate through the real new-selection path.
    try source.connection().selectModel("deepseek/deepseek-flash");
    try source.connection().setEffort(.max);
    try source.connection().configure("fake-derived-pending-auth");
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(cfg.ReasoningSource.metadata, source.app.?.config.value.model.reasoning_source);
    const request = @import("../core/runtime.zig").withReasoning(source.app.?.config.value, @import("../tests/adapter_test_support.zig").request(.chat));
    try std.testing.expectEqualStrings("max", request.reasoning_effort.?);
    try std.testing.expect(request.thinking.?);
    var disk = try source.store.loadExisting();
    defer cfg.release(&disk);
    try std.testing.expect(disk.value.model.reasoning == null and disk.value.model.reasoning_effort == null);
    var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer again.deinit();
    try std.testing.expectEqualStrings("max", again.mutableConfig().model.reasoning_effort.?);
    try std.testing.expect(again.capabilitiesFor(again.mutableConfig().*).known);
}

test "derived metadata protocol or format mismatch clears stale mapping and effort" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .logging = false });
    defer source.deinit();
    const entry = catalog.find("opencode-go/gpt-6-luna").?;
    const row = try source.metadata_cache.directory.upsert(.opencode_go, "gpt-6-luna");
    row.dev_present = true;
    row.dev_protocol = .responses;
    row.dev_reasoning = try @import("model_directory.zig").Profile.from(.{ .map = .{ .high = "high" } });
    var config: cfg.Config = .{ .provider = catalog.connection(entry.provider), .model = entry.model };
    config.model.reasoning = .{ .map = .{ .max = "max" } };
    config.model.reasoning_effort = "max";
    config.model.reasoning_source = .metadata;
    config.model.protocol = .chat;
    source.applyReasoningMetadata(&config);
    try std.testing.expect(config.model.reasoning == null and config.model.reasoning_effort == null);
    try std.testing.expect(!source.capabilitiesFor(config).known);
    config.model.protocol = .responses;
    row.dev_reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .anthropic, .map = .{ .high = "high" } });
    source.applyReasoningMetadata(&config);
    try std.testing.expect(!source.capabilitiesFor(config).known);
}
