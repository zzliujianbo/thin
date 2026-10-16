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
const selections = @import("selection.zig");
const resume_store = @import("resume_store.zig");
const resume_codec = @import("resume_codec.zig");
const checkpoint = @import("../core/checkpoint.zig");
const metadata = @import("model_metadata.zig");
const directory = @import("model_directory.zig");
const model_resolver = @import("model_resolver.zig");
const fs = @import("../platform/filesystem.zig");

test {
    _ = @import("llm_session_test.zig");
}

const MetadataTokens = [catalog.entries.len]?u32;
const MetadataFetch = *const fn (std.mem.Allocator, std.Io, ProviderId, ?[]const u8) anyerror!metadata.Listing;
const DevFetch = *const fn (std.mem.Allocator, std.Io) anyerror!metadata.Listing;
const official_metadata_timeout_ms = 8000;
const models_dev_timeout_ms = 30000;

/// A prepared actual model is not a fresh catalog choice. Credential swaps
/// preserve its budget, mapping, effective effort and context provenance.
const RetainedSelection = struct { context_official: bool, notice: ?[]const u8 };

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
    trusted: bool,
    logging: bool = true,
    /// Generated once before activation/logging; never read from the writer.
    session_id: ids.Id,
    store: Store,
    /// Owned by value, so pending-to-/login activation preserves the same fd.
    settings: Settings,
    preferred_effort: ?presentation.ReasoningEffort = null,
    settings_error: ?anyerror = null,
    settings_notice: ?[]const u8 = null,
    pending: ?std.json.Parsed(cfg.Config) = null,
    app: ?*App = null,
    /// Separate from the parsed arena; selected config may borrow this name.
    selected_name: ?[]u8 = null,
    /// Latest saved disk model, borrowed from pending or global_config while pending.
    pending_base_model: ?cfg.Model = null,
    /// Computed before publication; callbacks never read worker-owned history.
    initial_context: ?r.ContextSnapshot = null,
    /// Independent global baseline: explicit empty-chat selections update it;
    /// project effort and selections with history never leak into credential saves.
    global_config: ?std.json.Parsed(cfg.Config) = null,
    display_models: []cfg.Model = &.{},
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
    /// Journal observer wrapped so checkpoint writes stay on the runtime thread.
    inner_observer: r.Observer = .{},
    /// UI thread reads this while the runtime thread records incremental saves.
    /// Zero means the last attempted save succeeded. A nonzero code stays until
    /// a later save publishes a clean generation.
    checkpoint_failure: std.atomic.Value(u16) = .init(0),

    pub const Options = struct { restore_selection: ?ids.Id = null, resume_session: ?ids.Id = null, logging: bool = true, auto_refresh_models: bool = false };

    /// 只做本地初始化；缺少凭证时保持 pending，不发起试探请求。
    pub fn init(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host, trusted: bool) !Session {
        return initWithOptions(a, io, environ, project, host, trusted, .{});
    }

    pub fn initWithOptions(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host, trusted: bool, options: Options) !Session {
        const home = environ.get("HOME") orelse return error.MissingHome;
        if (options.resume_session != null and options.restore_selection != null) return error.InvalidArguments;
        const id = options.resume_session orelse try ids.generate(io);
        var settings = try Settings.open(a, io, project);
        var settings_moved = false;
        errdefer if (!settings_moved) settings.deinit();
        var lease: ?resume_store.Lease = if (options.resume_session) |source_id| try resume_store.Lease.open(&settings.root, source_id, options.logging) else null;
        errdefer if (lease) |*owned| owned.deinit();
        const source_bytes: ?[]u8 = if (lease) |*owned| try owned.load(&settings.root) else null;
        const selection_bytes: ?[]u8 = if (options.restore_selection) |source_id| try loadSelectionBytes(&settings.root, source_id) else null;
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
        const auth_store = if (restored != null) try Store.openExisting(a, io, home) else try Store.open(a, io, home);
        var self: Session = .{
            .allocator = a,
            .io = io,
            .environ = environ,
            .project = project,
            .host = host,
            .trusted = trusted,
            .logging = options.logging,
            .session_id = id,
            .store = auth_store,
            .settings = settings,
            .resume_lease = lease,
            .resumed = options.resume_session != null,
            .metadata_auto = options.auto_refresh_models,
            // Restored sessions do no startup fetch, but regain timed refresh.
            .metadata_next_check_ms = if (restored != null) @as(i64, @intCast(std.Io.Clock.awake.now(io).toMilliseconds())) + 60000 else 0,
            .metadata_login_auto = options.auto_refresh_models,
        };
        lease = null;
        settings_moved = true;
        errdefer self.deinit();
        self.pending = if (restored != null) try self.store.loadExisting() else try self.store.loadOrInitialize();
        self.global_config = try cfg.clone(a, self.pending.?.value);
        self.metadata_cache = metadata.load(&self.store.root) catch blk: {
            self.metadata_blocked = true;
            break :blk .{};
        };
        // Capture saved defaults before the project overlay/capability clamp.
        // Only explicit empty-chat model selection may replace this baseline.
        self.pending_base_model = self.pending.?.value.model;
        if (restored) |snapshot| {
            if (self.global_config.?.value.registry != null) {
                // Credential binding is deliberately model-free. Signed windows
                // are not trusted until authentication AND full state decoding.
                const bound = try self.bindLocalCredential(snapshot);
                if (self.pending) |*old| cfg.release(old);
                self.pending = bound;
            } else try self.restoreSelection(snapshot);
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
            if (config.registry == null) {
                self.applyReasoningMetadata(config);
                metadata.applyOutput(&self.metadata_cache, config);
                model_resolver.applyInputThreshold(&self.metadata_cache, config);
            }
            const capabilities = self.capabilitiesFor(config.*);
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
        }
        const config = &self.pending.?.value;
        if (restored == null) {
            self.display_models = try self.buildModels(config.*, self.global_config.?.value);
            self.selected_alias = try self.aliasFor(config.*);
        }
        if (config.selection_pending and restored == null) {
            self.settings_notice = "Default model unavailable locally; select a configured model";
            return self;
        }
        const key = cfg.resolveApiKey(a, self.pending.?.value, environ) catch |err| {
            if (err == error.ApiKeyNotFound and restored == null) return self;
            return err;
        };
        defer {
            std.crypto.secureZero(u8, key);
            a.free(key);
        }
        // Only small metadata was inspected to resolve the LOCAL credential.
        // Verify the exact immutable bytes before parsing any large state JSON.
        // --restore-selection authenticates the same checkpoint but does not import history.
        if (envelope) |*value| try resume_codec.authenticate(value, key);
        const restored_state = if (source_bytes != null) if (envelope) |value| try checkpoint.decode(a, value.payload) else null else null;
        defer if (restored_state) |value| value.deinit();
        if (restored) |snapshot| {
            if (self.global_config.?.value.registry != null) {
                const tokens = if (restored_state) |state| state.value.context_tokens else null;
                try self.restoreRegistrySelection(snapshot, tokens);
            }
        }
        if (restored_state) |value| {
            if (value.value.context_tokens) |tokens| {
                self.pending.?.value.model.context_tokens = tokens;
                self.active_context_official = value.value.context_official;
            }
            // Only authenticated full checkpoints restore frozen capabilities.
            // A frozen unknown must stay unknown even after the catalog changes.
            if (value.value.output_budget_frozen) {
                self.pending.?.value.model.output_tokens = value.value.output_tokens;
                self.pending.?.value.model.output_source = value.value.output_source;
            }
            if (value.value.input_budget_frozen)
                self.pending.?.value.model.input_price_threshold = value.value.input_price_threshold;
            // Limits remain current declarations; Runtime rejects policy drift.
            try cfg.validate(self.pending.?.value);
        }
        if (restored != null) {
            self.display_models = try self.buildModels(self.pending.?.value, self.global_config.?.value);
            self.selected_alias = try self.aliasFor(self.pending.?.value);
        }
        const parsed = self.pending.?;
        self.pending = null;
        self.pending_base_model = null;
        self.app = try self.prepareApp(parsed);
        self.app.?.setLogging(options.logging);
        try self.app.?.pinSessionID(self.session_id);
        if (restored_state) |value| {
            const app = self.app.?;
            try app.runtime.restoreCheckpoint(value.value);
            app.journal.seq = value.value.journal_seq;
            app.journal.turn = value.value.journal_turn;
            app.journal.resumed = true;
            app.journal.began_ms = std.Io.Clock.awake.now(io).toMilliseconds();
            self.settings_notice = "Conversation restored; prior tools are NOT rerun";
            // Last fallible initialization step: interrupted/poisoned resumed
            // processes leave an active marker, never a misleading old command.
            try self.resume_lease.?.activate(&self.settings.root);
        }
        self.initial_context = self.app.?.runtime.contextSnapshot();
        return self;
    }

    fn restoreSelection(self: *Session, snapshot: selections.Snapshot) !void {
        const global = self.global_config.?.value;
        if (global.registry != null) return self.restoreRegistrySelection(snapshot, null);
        var candidate = global;
        const original_endpoint = selections.endpoint(global.provider.base_url);
        const same_endpoint = std.mem.eql(u8, &snapshot.endpoint, &original_endpoint);
        var key: ?[]u8 = null;
        defer if (key) |value| {
            std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        };
        if (!same_endpoint) {
            const service = snapshot.provider orelse return error.SelectionEndpointUnavailable;
            candidate.provider = catalog.connection(service);
            const fingerprint = selections.endpoint(candidate.provider.base_url);
            if (!std.mem.eql(u8, &snapshot.endpoint, &fingerprint)) return error.SelectionEndpointUnavailable;
            key = try self.keyFor(service);
            candidate.provider.api_key = key;
            candidate.models = &.{};
        } else if ((candidate.provider.kind orelse ProviderId.fromUrl(candidate.provider.base_url)) != snapshot.provider)
            return error.SelectionEndpointUnavailable;

        // Explicit current profiles win. A transient custom ID without a saved
        // profile cannot silently inherit unrelated options on another startup.
        var model: ?cfg.Model = null;
        if (same_endpoint) {
            if (std.mem.eql(u8, global.model.name, snapshot.model())) model = global.model;
            if (model == null) for (global.models) |profile| {
                if (std.mem.eql(u8, profile.name, snapshot.model())) {
                    model = profile;
                    break;
                }
            };
        }
        if (model == null) if (snapshot.provider) |id| {
            if (ProviderId.fromUrl(candidate.provider.base_url) == id) {
                if (metadata.restoreEntry(&self.metadata_cache, id, snapshot.model())) |entry| model = entry.model;
            }
        };
        candidate.model = model orelse return error.SelectionModelUnavailable;
        candidate.model.protocol = snapshot.protocol;
        self.applyReasoningMetadata(&candidate);
        metadata.applyOutput(&self.metadata_cache, &candidate);
        model_resolver.applyInputThreshold(&self.metadata_cache, &candidate);
        const capabilities = self.capabilitiesFor(candidate);
        if (snapshot.effort) |level| {
            if (capabilities.known) {
                if (!capabilities.levels.contains(level)) return error.UnsupportedRestoredEffort;
                candidate.model.reasoning_effort = level.name();
            } else if (presentation.ReasoningEffort.fromName(candidate.model.reasoning_effort) != level)
                return error.RestoredEffortUnavailable;
        } else if (snapshot.effort_hash) |expected| {
            const raw = candidate.model.reasoning_effort orelse return error.RestoredEffortUnavailable;
            const actual = selections.endpoint(raw);
            if (!std.mem.eql(u8, &expected, &actual)) return error.RestoredEffortUnavailable;
        } else candidate.model.reasoning_effort = null;
        var owned = try cfg.clone(self.allocator, candidate);
        errdefer cfg.release(&owned);
        if (self.pending) |*old| cfg.release(old);
        self.pending = owned;
        self.pending_base_model = global.model;
        self.preferred_effort = snapshot.effort;
        self.settings_notice = "Selection restored; NEW EMPTY CHAT (history not restored)";
        // No settings load/initialization/save: restored choices win only here.
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
        if (self.metadata_job) |job| job.destroy();
        self.freeDisplayModels(self.display_models);
        if (self.selected_alias) |alias| self.allocator.free(alias);
        if (self.global_config) |*global| cfg.release(global);
        if (self.app) |app| app.deinit();
        if (self.resume_lease) |*lease| lease.deinit();
        if (self.selected_name) |name| self.allocator.free(name);
        if (self.pending) |*pending| cfg.release(pending);
        self.store.deinit();
        self.settings.deinit();
        self.* = undefined;
    }

    /// main 在进入 TUI 前设置，也应用于之后 /login 创建的候选 App。
    pub fn setLogging(self: *Session, enabled: bool) void {
        self.logging = enabled;
        if (self.app) |app| app.setLogging(enabled);
    }

    pub fn connection(self: *Session) tui.Connection {
        self.installObserver();
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .configure_provider_fn = configureProvider, .select_model_fn = selectModel, .set_effort_fn = setEffort, .initial_history_fn = initialHistory, .refresh_models_fn = refreshModels, .poll_models_fn = pollModels };
    }

    /// Called once, before any producer exists; never exposed by per-frame state.
    fn initialHistory(raw: *anyopaque) []const @import("../core/protocol.zig").Message {
        const self: *Session = @ptrCast(@alignCast(raw));
        return if (self.resumed) self.app.?.runtime.messages() else &.{};
    }

    /// Joined, normal interactive exit. Checkpoints are also written during the
    /// run; this publishes the final clean generation. A failure never changes
    /// task success; the caller must withhold the command.
    pub fn saveOnExit(self: *Session) !bool {
        if (!self.logging) return false;
        const app = self.app orelse return false;
        if (app.runtime.messages().len == 0) return false;
        app.journal.finish();
        const bytes = try self.encodeCheckpoint(false);
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        try resume_store.saveFinal(&self.settings.root, self.session_id, if (self.resume_lease) |*lease| lease else null, bytes);
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
                .assistant_committed, .compacted, .finished => self.persistBestEffort(true),
                else => {},
            },
            .tool_completed => self.persistBestEffort(true),
            else => {},
        }
    }

    fn markCheckpointDirty(self: *Session) void {
        const lease = &(self.resume_lease orelse return);
        if (!lease.writable) return;
        lease.activate(&self.settings.root) catch |err| {
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
        try self.resume_lease.?.save(&self.settings.root, bytes);
        self.clearCheckpointFailure();
    }

    fn ensureWritableLease(self: *Session) !void {
        if (self.resume_lease) |*lease| {
            if (!lease.writable) return error.ResumeReadOnly;
            return;
        }
        self.resume_lease = try resume_store.Lease.create(&self.settings.root, self.session_id);
    }

    fn encodeCheckpoint(self: *Session, during_run: bool) ![]u8 {
        const app = self.app orelse return error.NotConfigured;
        var state = if (during_run) try app.runtime.exportCheckpoint() else try app.runtime.checkpoint();
        state.journal_seq = app.journal.seq;
        state.journal_turn = app.journal.turn;
        state.context_official = self.active_context_official;
        const payload = try checkpoint.encode(self.allocator, state);
        defer {
            std.crypto.secureZero(u8, payload);
            self.allocator.free(payload);
        }
        const selection = try selections.capture(app.config.value);
        const key = try self.restorableKey(selection);
        defer {
            std.crypto.secureZero(u8, key);
            self.allocator.free(key);
        }
        var salt: [16]u8 = undefined;
        try self.io.randomSecure(&salt);
        return resume_codec.encode(self.allocator, self.session_id, &selection, payload, key, salt);
    }

    /// Bind CURRENT disk credentials before advertising a command. Registry
    /// model capabilities are already frozen in the signed checkpoint payload.
    fn restorableKey(self: *Session, selection: selections.Snapshot) ![]u8 {
        var resolver = self.*;
        resolver.global_config = try self.store.loadExisting();
        defer cfg.release(&resolver.global_config.?);
        resolver.pending = null;
        defer if (resolver.pending) |*owned| cfg.release(owned);
        if (resolver.global_config.?.value.registry != null) {
            resolver.pending = try resolver.bindLocalCredential(selection);
        } else try resolver.restoreSelection(selection);
        const key = try cfg.resolveApiKey(self.allocator, resolver.pending.?.value, self.environ);
        errdefer {
            std.crypto.secureZero(u8, key);
            self.allocator.free(key);
        }
        const actual = self.app.?.client.authorization;
        if (!std.mem.startsWith(u8, actual, "Bearer ") or !std.mem.eql(u8, actual["Bearer ".len..], key)) return error.ResumeCredentialChanged;
        return key;
    }

    fn current(raw: *anyopaque) tui.Connection.State {
        const self: *Session = @ptrCast(@alignCast(raw));
        const config = if (self.app) |app| app.config.value else self.pending.?.value;
        for (self.display_models, 0..) |model, index| {
            self.display_origins[index] = false;
            self.display_disabled[index] = false;
            if (config.registry) |registry| {
                self.display_disabled[index] = model.context_tokens == 0;
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
            if (index < config.models.len) continue; // Explicit local profiles always win, including explicit auto.
            self.display_disabled[index] = model.protocol == .auto;
            if (metadata.findEntry(&self.metadata_cache, model.name)) |entry| {
                if (self.officialCapacity(entry)) |tokens|
                    self.display_origins[index] = tokens == model.context_tokens;
            }
        }
        return .{
            .runtime = if (self.app) |app| &app.runtime else null,
            .initial_context = if (config.selection_pending) null else self.initial_context orelse .{ .tokens = 0, .limit = @intCast(config.model.context_tokens) },
            .model = config.model.name,
            .session_id = self.session_id,
            .models = self.display_models,
            .model_context_official = self.display_origins[0..self.display_models.len],
            .model_disabled = self.display_disabled[0..self.display_models.len],
            .context_official = self.active_context_official,
            .metadata_notice = self.metadata_notice,
            .selection_name = self.selected_alias,
            .provider = config.provider.kind orelse ProviderId.fromUrl(config.provider.base_url),
            .configured_providers = self.configuredMask(self.global_config.?.value),
            .allow_custom_models = config.provider.kind == null,
            .context_limit = if (config.selection_pending) 0 else config.model.context_tokens,
            .low_price_input = config.limits.low_price_input,
            .reasoning_effort = presentation.ReasoningEffort.fromName(config.model.reasoning_effort),
            .effort_levels = self.capabilitiesFor(config).levels,
            .settings_error = self.settings_error,
            .settings_notice = self.settings_notice,
            .base_url = config.provider.base_url,
            .tools_trusted = self.trusted,
            .logging_enabled = self.logging,
            // Journal failures already render as REC FAILED. Checkpoint saves use
            // that same channel when the journal itself is still healthy.
            .log_error = (if (self.app) |app| app.journal.failure() else null) orelse self.checkpointError(),
        };
    }

    fn officialCapacity(self: *const Session, entry: catalog.Entry) ?u32 {
        return metadata.capacityFor(&self.metadata_cache, entry);
    }

    fn metadataIndex(config: cfg.Config) ?usize {
        return metadata.reasoningIndex(config);
    }

    fn metadataDeclaration(self: *const Session, config: cfg.Config, index: usize) ?thinking.Declaration {
        return metadata.reasoningDeclaration(&self.metadata_cache, config, index);
    }

    fn applyReasoningMetadata(self: *const Session, config: *cfg.Config) void {
        // Registry selections already own the resolver's field-by-field merge.
        // Accepted maps (including unknown) and manual effort are frozen until
        // a deliberate fresh selection, not re-derived on redraw or Shift+Tab.
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
        self.metadata_cache.attempted = claim.cache.attempted;
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
        self.metadata_cache.attempted = claim.cache.attempted;
        self.metadata_login_pending &= ~claim.mask;
    }

    /// Owner polling never waits for network. Completion may change only the
    /// candidate catalog; the active Runtime budget is frozen until selection.
    fn pollModels(raw: *anyopaque, idle: bool) bool {
        const self: *Session = @ptrCast(@alignCast(raw));
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
            if (!official_ready and !dev_ready) return false;
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
            self.freeDisplayModels(self.display_models);
            self.display_models = models;
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
        if (!idle or !self.metadata_auto or self.metadata_blocked) return false;
        const tick = self.metadataTick();
        if (tick < self.metadata_next_check_ms) return false;
        self.metadata_next_check_ms = tick + 60000;
        const configured = self.configuredMask(self.global_config.?.value);
        if (configured != 0 and metadata.eligible(&self.metadata_cache, configured | metadata.dev_bit, self.metadataNow(), self.refreshPolicy()) != 0) {
            // Recheck eligibility under the cache lock before any worker launch.
            // Failed launches retain their claim; local errors retry only on cadence.
            self.startMetadata(configured, false) catch {};
        }
        return false;
    }

    fn configuredMask(self: *const Session, global: cfg.Config) u8 {
        var mask: u8 = 0;
        if (global.registry) |registry| {
            for (registry.providers) |provider| {
                const id = ProviderId.fromUrl(provider.connection.base_url) orelse continue;
                if (provider.connection.api_key != null or
                    (provider.connection.api_key_env.len != 0 and self.environ.get(provider.connection.api_key_env) != null)) mask |= metadata.bit(id);
            }
            return mask;
        }
        for (ProviderId.all) |id| {
            const legacy = ProviderId.fromUrl(global.provider.base_url) == id and
                (global.provider.api_key != null or (global.provider.api_key_env.len != 0 and self.environ.get(global.provider.api_key_env) != null));
            if (global.credentials.get(id) != null or legacy) mask |= @as(u8, 1) << @intCast(@backingInt(id));
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
    fn buildModels(self: *Session, active: cfg.Config, global: cfg.Config) ![]cfg.Model {
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
        // Keep local profiles first and aligned with the owner's UI flags.
        if (active.models.len > 64) return error.TooManyModels;
        for (active.models) |model| {
            var candidate = active;
            candidate.model = model;
            model_resolver.applyInputThreshold(&self.metadata_cache, &candidate);
            try self.appendDisplayModel(&models, candidate.model);
        }
        const configured = self.configuredMask(global);
        const found = &self.metadata_cache.directory;
        for (found.rows[0..found.count], 0..) |row, index| {
            if (configured & metadata.bit(row.provider) == 0 or row.available != true) continue;
            const entry = metadata.dynamicEntry(&self.metadata_cache, row.provider, found.name(index)) orelse continue;
            try self.appendCandidate(&models, active, entry);
        }
        // A successful official directory is authoritative, including an empty
        // directory. Never resurrect missing presets from an older cache.
        for (catalog.entries, 0..) |entry, index| {
            if (configured & metadata.bit(entry.provider) == 0 or metadata.hasDirectory(&self.metadata_cache, entry.provider)) continue;
            if (self.metadata_cache.available[index] == false) continue;
            try self.appendCandidate(&models, active, entry);
        }
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

    fn appendCandidate(self: *Session, models: *std.ArrayList(cfg.Model), active: cfg.Config, entry: catalog.Entry) !void {
        const active_provider = active.provider.kind orelse ProviderId.fromUrl(active.provider.base_url);
        for (active.models) |profile| {
            if (std.mem.eql(u8, profile.name, entry.selector) or
                (active_provider == entry.provider and std.mem.eql(u8, profile.name, entry.model.name))) return;
        }
        for (models.items) |model| if (std.mem.eql(u8, model.name, entry.selector)) return;
        var model = entry.model;
        model.reasoning = self.declarationForEntry(entry);
        model.reasoning_source = .metadata;
        model.output_tokens = metadata.outputFor(&self.metadata_cache, entry);
        model.output_source = .metadata;
        model.input_price_threshold = metadata.inputPriceThresholdFor(&self.metadata_cache, entry);
        if (self.officialCapacity(entry)) |tokens| model.context_tokens = tokens;
        model.name = entry.selector;
        try self.appendDisplayModel(models, model);
    }

    fn aliasFor(self: *Session, config: cfg.Config) !?[]u8 {
        if (config.registry != null) {
            const provider = config.selected_provider orelse return null;
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ provider, config.model.name });
        }
        // Legacy configs may use an exact official URL without a named kind.
        // Normalize those identities too, but never infer a provider from a
        // model name or a proxy/custom endpoint.
        const id = config.provider.kind orelse ProviderId.fromUrl(config.provider.base_url) orelse return null;
        if (metadata.restoreEntry(&self.metadata_cache, id, config.model.name)) |entry|
            return try self.allocator.dupe(u8, entry.selector);
        // Explicit configured models are not invented catalog selectors.
        return null;
    }

    fn applyPreference(self: *Session, config: *cfg.Config) ?[]const u8 {
        self.applyReasoningMetadata(config);
        const capabilities = self.capabilitiesFor(config.*);
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
        if (global.registry) |registry| {
            // Explicit selected connection wins; a missing env is not permission
            // to fall back to another alias or a legacy credential slot.
            if (self.mutableConfig().selected_provider) |name| {
                if (registry.find(name)) |provider| if (ProviderId.fromUrl(provider.connection.base_url) == id) {
                    var local = global;
                    local.provider = provider.connection;
                    local.credentials = .{};
                    return cfg.resolveApiKey(self.allocator, local, self.environ);
                };
            }
            for (registry.providers) |provider| if (ProviderId.fromUrl(provider.connection.base_url) == id) {
                var local = global;
                local.provider = provider.connection;
                local.credentials = .{};
                return cfg.resolveApiKey(self.allocator, local, self.environ);
            };
            return error.ApiKeyNotFound;
        }
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

    /// Only an empty canonical conversation changes startup defaults. A failed
    /// first reply still has its user message; resumed/compacted history counts.
    /// Prepare an independently owned baseline before any live-state mutation.
    fn selectionDefaults(self: *Session, candidate: cfg.Config) !?std.json.Parsed(cfg.Config) {
        if (self.app) |app| if (app.runtime.messages().len != 0) return null;
        const global = self.global_config.?.value;
        if (global.registry != null) {
            var owned = try cfg.clone(self.allocator, global);
            errdefer cfg.release(&owned);
            try cfg.setRegistryDefault(owned.arena.allocator(), &owned.value, candidate.selected_provider orelse return error.UnknownProvider, candidate.model.name);
            return owned;
        }
        var disk = global;
        disk.provider = candidate.provider;
        disk.model = candidate.model.persisted();
        disk.models = candidate.models;
        // Retain a legacy inline official key in its own slot when changing
        // the primary service. Never materialize an environment value on disk.
        if (ProviderId.fromUrl(global.provider.base_url)) |id| {
            if (disk.credentials.get(id) == null) {
                if (global.provider.api_key) |key| disk.credentials.set(id, key);
            }
        }
        const same_endpoint = std.mem.eql(u8, global.provider.base_url, candidate.provider.base_url) or
            (ProviderId.fromUrl(global.provider.base_url) != null and ProviderId.fromUrl(global.provider.base_url) == ProviderId.fromUrl(candidate.provider.base_url));
        if (same_endpoint) {
            // Active connections may carry a resolved temporary key. Preserve
            // the actual persisted source, including an environment reference.
            disk.provider.api_key = global.provider.api_key;
            disk.provider.api_key_env = global.provider.api_key_env;
        } else if (ProviderId.fromUrl(candidate.provider.base_url)) |id| {
            if (disk.credentials.get(id) == null) return error.ApiKeyNotFound;
            disk.provider.api_key = null;
            disk.provider.api_key_env = "";
        }
        return try cfg.clone(self.allocator, disk);
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

    fn activateSavedCredential(self: *Session, model: cfg.Model, selector: []const u8, retained: RetainedSelection) !bool {
        const app = self.app orelse return false;
        const id = ProviderId.fromUrl(app.config.value.provider.base_url) orelse return false;
        if (self.active_revision == self.credential_revisions[@intCast(@backingInt(id))]) return false;
        var next = model;
        // A retained conversation already established its wire protocol. Do not
        // probe a different protocol merely because its credential changed.
        if (next.protocol == .auto and app.runtime.history.items.len != 0) next.protocol = app.runtime.selector.effective();
        try self.installProviderModel(.{ .provider = id, .selector = selector, .model = next }, retained);
        return true;
    }

    fn selectModel(raw: *anyopaque, name: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        const config = self.mutableConfig();
        if (config.registry != null) return self.selectRegistryModel(name);
        // Reactivate actual options before dispatching to a fresh candidate.
        // Explicit current map/effort choices remain actual selections.
        const current_explicit = (config.model.reasoning_source == .explicit and
            (config.model.reasoning != null or config.model.reasoning_effort != null)) or
            (config.model.output_source == .explicit and config.model.output_tokens != null);
        const current_name = std.mem.eql(u8, name, config.model.name) or
            (self.selected_alias != null and std.mem.eql(u8, name, self.selected_alias.?));
        if (current_name) {
            if (try self.activateSavedCredential(config.model, self.selected_alias orelse name, .{ .context_official = self.active_context_official, .notice = self.settings_notice })) return;
            // A raw current row is the actual transient selection. A qualified
            // catalog selector is a deliberate fresh confirmation and may adopt
            // metadata, unless explicit current controls take precedence.
            if (current_explicit or std.mem.eql(u8, name, config.model.name)) {
                if (self.app) |app| self.initial_context = app.runtime.contextSnapshot();
                return;
            }
        }
        var explicit_profile = false;
        for (config.models) |profile| if (std.mem.eql(u8, profile.name, name)) {
            explicit_profile = true;
            break;
        };
        if (!explicit_profile) {
            if (metadata.findEntry(&self.metadata_cache, name)) |entry| return self.selectProviderModel(entry);
            if (std.mem.findScalar(u8, name, '/')) |slash| {
                if (ProviderId.fromSlug(name[0..slash]) != null) return error.UnsupportedProviderModel;
            }
            // A service hint on a custom endpoint opts into conventions, not
            // permission to redirect a raw-ID selection to the official service.
            if (ProviderId.fromUrl(config.provider.base_url)) |id| {
                if (metadata.dynamicEntry(&self.metadata_cache, id, name)) |entry| return self.selectProviderModel(entry);
                if (!metadata.hasDirectory(&self.metadata_cache, id)) {
                    for (catalog.entries) |entry| {
                        if (entry.provider == id and std.mem.eql(u8, entry.model.name, name) and
                            metadata.findEntry(&self.metadata_cache, entry.selector) != null) return self.selectProviderModel(entry);
                    }
                }
                // Legacy unnamed endpoints retain custom-model entry until an
                // official directory establishes authoritative availability.
                if (config.provider.kind != null or metadata.hasDirectory(&self.metadata_cache, id)) return error.UnsupportedProviderModel;
            }
        }
        // The current picker row represents the ACTUAL transient options, not
        // a same-named startup profile. Re-selecting it must not undo Shift+Tab.
        if (std.mem.eql(u8, name, config.model.name)) {
            if (try self.activateSavedCredential(config.model, name, .{ .context_official = self.active_context_official, .notice = self.settings_notice })) return;
            // Owner-only idle path: preserve the latest actual value even when
            // the picker republishes a same-name no-op connection snapshot.
            if (self.app) |app| self.initial_context = app.runtime.contextSnapshot();
            return;
        }
        var candidate = config.*;
        // Existing wire/context conventions remain explicit defaults. Output
        // capability belongs to one model identity, not to the next raw name.
        candidate.model.name = name;
        candidate.model.output_tokens = null;
        candidate.model.output_source = .explicit;
        for (config.models) |profile| {
            if (std.mem.eql(u8, name, profile.name)) {
                candidate.model = profile;
                break;
            }
        }
        self.applyReasoningMetadata(&candidate);
        metadata.applyOutput(&self.metadata_cache, &candidate);
        model_resolver.applyInputThreshold(&self.metadata_cache, &candidate);
        const capabilities = self.capabilitiesFor(candidate);
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
        if (try self.activateSavedCredential(candidate.model, name, .{ .context_official = false, .notice = preference_notice })) return;
        const owned_name = try self.allocator.dupe(u8, candidate.model.name);
        errdefer self.allocator.free(owned_name);
        const alias = try self.aliasFor(candidate);
        errdefer if (alias) |value| self.allocator.free(value);
        candidate.model.name = owned_name;
        var defaults = try self.selectionDefaults(candidate);
        defer if (defaults) |*value| cfg.release(value);
        const models = try self.buildModels(candidate, if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.freeDisplayModels(models);
        const plan = if (self.app) |app| try app.runtime.planSelection(candidate, false) else null;
        try self.persistSelectionDefaults(&defaults);
        if (self.app) |app| app.runtime.applySelection(plan.?);
        // No fallible operation follows persistence/publication.
        if (self.pending != null and self.pending_base_model == null) self.pending_base_model = config.model;
        const previous = self.selected_name;
        config.model = candidate.model;
        self.selected_name = owned_name;
        if (self.selected_alias) |old| self.allocator.free(old);
        self.selected_alias = alias;
        self.freeDisplayModels(self.display_models);
        self.display_models = models;
        self.settings_notice = preference_notice;
        self.active_context_official = false;
        if (previous) |old| self.allocator.free(old);
        if (self.app) |app| {
            self.initial_context = app.runtime.contextSnapshot();
            app.recordSelection();
        }
        // Publication already happened. A checkpoint miss must not look like a
        // rolled-back model change.
        self.publishCheckpoint();
    }

    /// Own the local connection without resolving any model or borrowing a key
    /// into an object whose release() would wipe the independent global arena.
    fn bindLocalCredential(self: *Session, snapshot: selections.Snapshot) !std.json.Parsed(cfg.Config) {
        const global = self.global_config.?.value;
        const registry = global.registry.?;
        // Old snapshots have no alias: only an unambiguous exact endpoint can
        // identify a local credential authority. Never guess by provider kind.
        var name = snapshot.providerName();
        if (name == null) {
            for (registry.providers) |provider| {
                const fingerprint = selections.endpoint(provider.connection.base_url);
                if (std.mem.eql(u8, &snapshot.endpoint, &fingerprint)) {
                    if (name != null) return error.SelectionEndpointUnavailable;
                    name = provider.name;
                }
            }
        }
        const provider_name = name orelse return error.SelectionEndpointUnavailable;
        const provider = registry.find(provider_name) orelse return error.SelectionEndpointUnavailable;
        const fingerprint = selections.endpoint(provider.connection.base_url);
        if (!std.mem.eql(u8, &snapshot.endpoint, &fingerprint)) return error.SelectionEndpointUnavailable;
        var candidate = global;
        candidate.provider = provider.connection;
        candidate.selected_provider = provider_name;
        candidate.selection_pending = true;
        return cfg.clone(self.allocator, candidate);
    }

    fn restoreRegistrySelection(self: *Session, snapshot: selections.Snapshot, frozen_tokens: ?u32) !void {
        var owned = try self.bindLocalCredential(snapshot);
        errdefer cfg.release(&owned);
        const provider_name = owned.value.selected_provider.?;
        const provider = owned.value.registry.?.find(provider_name).?;
        const patch = provider.patchFor(snapshot.model());
        const current_raw_effort = if (patch) |manual| manual.reasoning_effort else null;
        const resolved = if (frozen_tokens) |tokens| blk: {
            // Unknown raw effort is never guessed. The existing hash check
            // below still requires the current declaration to match exactly.
            const effort = if (snapshot.effort) |level| level.name() else if (snapshot.effort_hash != null) current_raw_effort else null;
            break :blk try model_resolver.resolveFrozen(owned.arena.allocator(), owned.value, &self.metadata_cache, provider_name, snapshot.model(), .{
                .protocol = snapshot.protocol,
                .context_tokens = tokens,
                .effort = effort,
            });
        } else try model_resolver.resolveRoute(owned.arena.allocator(), owned.value, &self.metadata_cache, provider_name, snapshot.model(), snapshot.protocol);
        model_resolver.apply(&owned.value, resolved);
        const capabilities = self.capabilitiesFor(owned.value);
        if (snapshot.effort) |level| {
            if (capabilities.known) {
                if (!capabilities.levels.contains(level)) return error.UnsupportedRestoredEffort;
                owned.value.model.reasoning_effort = level.name();
            } else if (presentation.ReasoningEffort.fromName(if (frozen_tokens != null) current_raw_effort else owned.value.model.reasoning_effort) != level)
                return error.RestoredEffortUnavailable;
        } else if (snapshot.effort_hash) |expected| {
            const effort = owned.value.model.reasoning_effort orelse return error.RestoredEffortUnavailable;
            const actual = selections.endpoint(effort);
            if (!std.mem.eql(u8, &expected, &actual)) return error.RestoredEffortUnavailable;
        } else owned.value.model.reasoning_effort = null;
        if (self.pending) |*old| cfg.release(old);
        self.pending = owned;
        self.preferred_effort = snapshot.effort;
        self.active_context_official = resolved.context_official;
        self.settings_notice = "Selection restored; NEW EMPTY CHAT (history not restored)";
    }

    fn selectRegistryModel(self: *Session, selector: []const u8) !void {
        const previous = self.mutableConfig().*;
        const raw_current = std.mem.eql(u8, selector, previous.model.name);
        const alias_current = self.selected_alias != null and std.mem.eql(u8, selector, self.selected_alias.?);
        const revision_changed = if (ProviderId.fromUrl(previous.provider.base_url)) |id|
            self.active_revision != self.credential_revisions[@intCast(@backingInt(id))]
        else
            false;
        const explicit_current = (previous.model.reasoning_source == .explicit and
            (previous.model.reasoning != null or previous.model.reasoning_effort != null)) or
            (previous.model.output_source == .explicit and previous.model.output_tokens != null);
        const retained = !previous.selection_pending and (raw_current or (alias_current and (revision_changed or explicit_current)));
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
            model_resolver.apply(&owned.value, resolved);
            context_official = resolved.context_official;
            notice = self.applyPreference(&owned.value);
        }
        moved = true;
        try self.publishRegistryModel(owned, context_official, notice, !retained);
    }

    /// Consumes owned on every path. All preparation and disk writes precede
    /// publication; runtime/history are never partly changed on failure.
    fn publishRegistryModel(self: *Session, parsed: std.json.Parsed(cfg.Config), context_official: bool, notice: ?[]const u8, update_default: bool) !void {
        var owned = parsed;
        var consumed = false;
        defer if (!consumed) cfg.release(&owned);
        const alias = try self.aliasFor(owned.value);
        errdefer if (alias) |value| self.allocator.free(value);
        var defaults = if (update_default) try self.selectionDefaults(owned.value) else null;
        defer if (defaults) |*value| cfg.release(value);
        const models = try self.buildModels(owned.value, if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.freeDisplayModels(models);
        var replacement: ?*App.ConnectionReplacement = null;
        var initial: ?*App = null;
        errdefer if (replacement) |value| value.deinit();
        errdefer if (initial) |value| value.deinit();
        const key = cfg.resolveApiKey(self.allocator, owned.value, self.environ) catch |err| blk: {
            if (err == error.ApiKeyNotFound and self.app == null) break :blk null;
            return err;
        };
        defer if (key) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        };
        if (key != null) {
            consumed = true; // App preparation consumes even on error.
            if (self.app) |app| replacement = try app.prepareConnection(owned, self.environ) else initial = try self.prepareApp(owned);
            if (replacement) |value| value.client.session_id = self.session_id;
            if (initial) |value| {
                try value.pinSessionID(self.session_id);
                value.setLogging(self.logging);
            }
        }
        try self.persistSelectionDefaults(&defaults);
        if (replacement) |value| self.app.?.installConnection(value) else {
            if (self.pending) |*value| cfg.release(value);
            self.pending = null;
            self.pending_base_model = null;
            if (initial) |value| self.app = value else {
                self.pending = owned;
                consumed = true;
            }
        }
        if (self.selected_name) |value| self.allocator.free(value);
        self.selected_name = null;
        if (self.selected_alias) |value| self.allocator.free(value);
        self.selected_alias = alias;
        self.freeDisplayModels(self.display_models);
        self.display_models = models;
        self.active_context_official = context_official;
        self.settings_notice = notice;
        if (ProviderId.fromUrl(self.mutableConfig().provider.base_url)) |id|
            self.active_revision = self.credential_revisions[@intCast(@backingInt(id))];
        if (self.app) |app| self.initial_context = app.runtime.contextSnapshot();
        self.publishCheckpoint();
    }

    fn configureRegistryProvider(self: *Session, id: ProviderId, key: []const u8) !void {
        var baseline = try cfg.clone(self.allocator, self.global_config.?.value);
        errdefer cfg.release(&baseline);
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
        const name = target.?;
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
            initial = try self.prepareApp(try cfg.clone(self.allocator, next));
            try initial.?.pinSessionID(self.session_id);
            initial.?.setLogging(self.logging);
        }
        const models = try self.buildModels(if (initial) |value| value.config.value else active, baseline.value);
        errdefer self.freeDisplayModels(models);
        if (self.app) |app| try app.journal.rememberKey(key);
        try self.store.save(baseline.value);
        if (self.global_config) |*old| cfg.release(old);
        self.global_config = baseline;
        self.credential_revisions[@intCast(@backingInt(id))] +%= 1;
        if (initial) |value| {
            if (self.pending) |*old| cfg.release(old);
            self.pending = null;
            self.pending_base_model = null;
            if (self.selected_name) |old| self.allocator.free(old);
            self.selected_name = null;
            self.app = value;
            self.active_revision = self.credential_revisions[@intCast(@backingInt(id))];
            self.initial_context = value.runtime.contextSnapshot();
        }
        self.freeDisplayModels(self.display_models);
        self.display_models = models;
        if (self.metadata_login_auto) self.metadata_login_pending |= metadata.bit(id);
        self.publishCheckpoint();
    }

    fn selectProviderModel(self: *Session, entry: catalog.Entry) !void {
        return self.installProviderModel(entry, null);
    }

    fn installProviderModel(self: *Session, entry: catalog.Entry, retained: ?RetainedSelection) !void {
        // Unknown discovered protocols must never enter paid auto negotiation.
        // Retained explicit auto models are not directory candidates.
        if (retained == null and entry.model.protocol == .auto) return error.UnknownModelProtocol;
        const previous = self.mutableConfig();
        const revision = self.credential_revisions[@intCast(@backingInt(entry.provider))];
        const official = if (retained == null) self.officialCapacity(entry) else null;
        const capacity = official orelse entry.model.context_tokens;
        const context_official = if (retained) |actual| actual.context_official else official != null;
        const declaration = if (retained != null) entry.model.reasoning else self.declarationForEntry(entry);
        const explicit_output = entry.model.output_source == .explicit and entry.model.output_tokens != null;
        const output_tokens = if (retained != null or explicit_output) entry.model.output_tokens else metadata.outputFor(&self.metadata_cache, entry);
        const output_source: cfg.ReasoningSource = if (retained != null or explicit_output) entry.model.output_source else .metadata;
        const input_price_threshold = if (retained != null) entry.model.input_price_threshold else metadata.inputPriceThresholdFor(&self.metadata_cache, entry);
        if (self.app != null and previous.provider.kind == entry.provider and
            std.mem.eql(u8, previous.model.name, entry.model.name) and self.active_revision == revision and
            previous.model.protocol == entry.model.protocol and previous.model.context_tokens == capacity and
            previous.model.output_tokens == output_tokens and previous.model.output_source == output_source and
            previous.model.input_price_threshold == input_price_threshold and
            sameDeclaration(previous.model.reasoning, declaration))
        {
            self.initial_context = self.app.?.runtime.contextSnapshot();
            self.active_context_official = context_official;
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
        if (retained == null and next.model.reasoning == null and next.model.reasoning_effort == null) next.model.reasoning_source = .metadata;
        next.model.context_tokens = capacity;
        next.model.output_tokens = output_tokens;
        next.model.output_source = output_source;
        next.model.input_price_threshold = input_price_threshold;
        next.models = if (same_endpoint) previous.models else &.{};
        const notice = if (retained) |actual| actual.notice else self.applyPreference(&next);
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
        var defaults = try self.selectionDefaults(prepared);
        defer if (defaults) |*value| cfg.release(value);
        const models = try self.buildModels(prepared, if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.freeDisplayModels(models);
        try self.persistSelectionDefaults(&defaults);
        // With history, only installConnection's session selection is updated.
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
        self.freeDisplayModels(self.display_models);
        self.display_models = models;
        self.active_revision = revision;
        self.active_context_official = context_official;
        self.settings_notice = notice;
        self.initial_context = self.app.?.runtime.contextSnapshot();
        self.publishCheckpoint();
    }

    fn configureProvider(raw: *anyopaque, id: ProviderId, key: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        if (self.global_config.?.value.registry != null) return self.configureRegistryProvider(id, key);
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
            if (!same_provider) {
                metadata.applyOutput(&self.metadata_cache, &next);
                model_resolver.applyInputThreshold(&self.metadata_cache, &next);
            }
            notice = self.applyPreference(&next);
            initial = try self.prepareApp(try cfg.clone(self.allocator, next));
            try initial.?.pinSessionID(self.session_id);
            initial.?.setLogging(self.logging);
            alias = try self.aliasFor(initial.?.config.value);
        }
        const active = if (initial) |value| value.config.value else self.mutableConfig().*;
        const models = try self.buildModels(active, baseline.value);
        errdefer self.freeDisplayModels(models);
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
        self.freeDisplayModels(self.display_models);
        self.display_models = models;
        // Saving is local and transactional. Refresh starts later on the owner
        // idle poll, even if this provider was already attempted before login.
        if (self.metadata_login_auto) self.metadata_login_pending |= metadata.bit(id);
        self.publishCheckpoint();
    }

    fn setEffort(raw: *anyopaque, effort: presentation.ReasoningEffort) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        const canonical = effort.canonical();
        const name = canonical.name() orelse return error.InvalidReasoningEffort;
        const config = self.mutableConfig();
        var candidate = config.*;
        self.applyReasoningMetadata(&candidate);
        const capabilities = self.capabilitiesFor(candidate);
        if (!capabilities.levels.contains(canonical)) return error.UnsupportedReasoningEffort;
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
        if (self.app) |app| app.recordSelection();
        self.publishCheckpoint();
    }

    fn configure(raw: *anyopaque, key: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (self.app != null) return error.AlreadyConfigured;
        if (self.pending.?.value.registry != null) {
            const id = ProviderId.fromUrl(self.pending.?.value.provider.base_url) orelse return error.UnsupportedProvider;
            return self.configureRegistryProvider(id, key);
        }
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
        // The fixed encoding above enforces the original setup size limit.
        // This is a trusted pending config, not a disk load: retain its map.
        const owned = try cfg.clone(self.allocator, next);
        const candidate = try self.prepareApp(owned);
        errdefer candidate.deinit();
        try candidate.pinSessionID(self.session_id);
        candidate.setLogging(self.logging);

        // 先完成本地对象构建和落盘，再发布 ready。保存失败不激活半配置会话。
        var disk_config = candidate.config.value;
        if (self.pending_base_model) |baseline| disk_config.model = baseline;
        disk_config.model = disk_config.model.persisted();
        var global = try cfg.clone(self.allocator, disk_config);
        errdefer cfg.release(&global);
        const models = try self.buildModels(candidate.config.value, global.value);
        errdefer self.freeDisplayModels(models);
        try self.store.save(disk_config);
        if (self.global_config) |*old| cfg.release(old);
        self.global_config = global;
        self.freeDisplayModels(self.display_models);
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
        self.publishCheckpoint();
    }
};

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

/// Replace the authenticated selection inside an existing checkpoint and
/// publish a new clean generation. Payload bytes stay as they were.
fn overwriteFixtureSelection(root: *fs.Root, id: ids.Id, snapshot: *const selections.Snapshot, key: []const u8) !void {
    var lease = try resume_store.Lease.open(root, id, true);
    defer lease.deinit();
    const bytes = try lease.load(root);
    defer root.allocator.free(bytes);
    const envelope = try resume_codec.inspect(root.allocator, bytes, id);
    var salt: [16]u8 = undefined;
    @memcpy(&salt, bytes[12..28]);
    const rewritten = try resume_codec.encode(root.allocator, id, snapshot, envelope.payload, key, salt);
    defer root.allocator.free(rewritten);
    try lease.save(root, rewritten);
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
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
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
        const choices = try picker.choicesWithDisabled(a, latest.selection_name orelse latest.model, latest.context_limit, latest.models, latest.model_disabled);
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

test "dynamic official IDs select for all providers and reject unknown protocols without probing" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
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
            try std.testing.expectError(error.UnsupportedProviderModel, session.connection().selectModel(entry.selector));
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

test "explicit raw and qualified profiles override dynamic rows including explicit auto" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-explicit-key");
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go);
    for ([_][]const u8{ "raw-override", "qualified-override", "visible-unknown" }) |name| {
        const row = try session.metadata_cache.directory.upsert(.opencode_go, name);
        row.available = true;
    }
    var active = session.mutableConfig().*;
    active.models = &.{
        .{ .name = "raw-override", .context_tokens = 32768, .protocol = .auto },
        .{ .name = "opencode-go/qualified-override", .context_tokens = 32768, .protocol = .chat },
    };
    const models = try session.buildModels(active, session.global_config.?.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("raw-override", models[0].name);
    try std.testing.expectEqualStrings("opencode-go/qualified-override", models[1].name);
    try std.testing.expectEqualStrings("opencode-go/visible-unknown", models[2].name);
    // Session's state flags align by profile position, not by protocol alone.
    const old_models = session.display_models;
    session.display_models = models;
    session.mutableConfig().models = active.models;
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
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    const config = session.mutableConfig();
    config.provider.base_url = "https://custom.invalid/v1";
    config.provider.kind = null;
    config.model.protocol = .chat;
    config.model.output_tokens = 65536;
    config.model.output_source = .explicit;
    config.models = &.{.{ .name = "custom-declared", .context_tokens = 131072, .protocol = .chat, .output_tokens = 4096 }};
    try session.connection().selectModel("custom-next");
    try std.testing.expect(session.mutableConfig().model.output_tokens == null);
    try session.connection().selectModel("custom-declared");
    try std.testing.expectEqual(@as(?u32, 4096), session.mutableConfig().model.output_tokens);
    try std.testing.expectEqual(.explicit, session.mutableConfig().model.output_source);
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
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-owned-display-key");
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go);
    const row = try session.metadata_cache.directory.upsert(.opencode_go, "owned-cache-name");
    row.available = true;
    row.protocol = .chat;
    var profile_name = "owned-profile".*;
    var effort = "high".*;
    var wire = "custom-wire".*;
    var active = session.mutableConfig().*;
    active.models = &.{.{
        .name = &profile_name,
        .context_tokens = 32768,
        .protocol = .chat,
        .reasoning_effort = &effort,
        .reasoning = .{ .map = .{ .high = &wire } },
    }};
    const models = try session.buildModels(active, session.global_config.?.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    // A movable Session/cache and a released config arena are equivalent to
    // replacing these backing bytes. Published rows must own separate storage.
    @memset(&session.metadata_cache.directory.names, 'X');
    profile_name[0] = 'X';
    effort[0] = 'X';
    wire[0] = 'X';
    try std.testing.expectEqualStrings("opencode-go/owned-cache-name", models[1].name);
    try std.testing.expectEqualStrings("owned-profile", models[0].name);
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
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-go-profile-key");
    try session.connection().configureProvider(.opencode_zen, "fake-zen-profile-key");
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go) | metadata.bit(.opencode_zen);
    for ([_]ProviderId{ .opencode_go, .opencode_zen }) |id| {
        const row = try session.metadata_cache.directory.upsert(id, "shared-profile");
        row.available = true;
        row.protocol = .chat;
    }
    var active = session.mutableConfig().*;
    active.models = &.{.{ .name = "shared-profile", .context_tokens = 32768, .protocol = .chat }};
    const models = try session.buildModels(active, session.global_config.?.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("shared-profile", models[0].name);
    try std.testing.expectEqualStrings("opencode-zen/shared-profile", models[1].name);
}

test "restore selection is read only until an explicit empty conversation model change" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var source = try Session.init(a, std.testing.io, &env, home, .{}, true);
    defer source.deinit();
    const connection = source.connection();
    try connection.configureProvider(.deepseek, "fixture-deepseek-key");
    try connection.configureProvider(.opencode_zen, "fixture-zen-key");
    try connection.configureProvider(.opencode_go, "fixture-go-key");
    // Restore reads a persisted capability source, not removed built-in tables.
    var listing: metadata.Listing = .{};
    for (catalog.entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.model.name, "gpt-5.6-luna"))
            listing.reasoning[index] = .{ .map = .{ .low = "low", .medium = "medium", .high = "high", .xhigh = "xhigh", .max = "max" } };
    }
    source.metadata_cache = try metadata.commit(&source.store.root, metadata.bit(.opencode_go) | metadata.bit(.opencode_zen), listing);
    try connection.selectModel("opencode-go/gpt-5.6-luna");
    const app = source.app.?;
    app.journal.observer().notify(.{ .submitted = "old text must not become new history" });
    try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .user, .blocks = &.{.{ .text = "old text must not become new history" }} });
    try connection.setEffort(.max);
    app.journal.flush();
    try std.testing.expect(app.journal.failure() == null);
    try std.testing.expect(source.checkpointError() == null);
    try std.testing.expectError(error.UnsupportedProviderModel, connection.selectModel("opencode-go/not-a-preset"));
    const snapshot = blk: {
        const checkpoint_bytes = try source.resume_lease.?.load(&source.settings.root);
        defer a.free(checkpoint_bytes);
        const saved = try resume_codec.inspect(a, checkpoint_bytes, source.session_id);
        try std.testing.expectEqual(presentation.ReasoningEffort.max, saved.selection.effort.?);
        try std.testing.expectEqual(ProviderId.opencode_go, saved.selection.provider.?);
        break :blk saved.selection;
    };
    try source.settings.save(.low); // A different new-session default must lose.
    // The owner holds the checkpoint lock. Restore and rewrite run as another opener.
    releaseLease(&source);
    const global_before = try tmp.dir.readFileAlloc(std.testing.io, ".thin/config.json", a, .limited(cfg.max_config_bytes));
    defer a.free(global_before);
    const settings_before = try tmp.dir.readFileAlloc(std.testing.io, ".thin/settings.json", a, .limited(1024));
    defer a.free(settings_before);
    {
        var restored = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .restore_selection = source.session_id, .logging = false });
        defer restored.deinit();
        try std.testing.expect(!std.mem.eql(u8, &source.session_id, &restored.session_id));
        try std.testing.expectEqual(@as(usize, 0), restored.app.?.runtime.messages().len);
        try std.testing.expectEqualStrings("gpt-5.6-luna", restored.app.?.config.value.model.name);
        try std.testing.expectEqual(@import("../core/protocol.zig").Protocol.responses, restored.app.?.config.value.model.protocol);
        try std.testing.expectEqualStrings("max", restored.app.?.config.value.model.reasoning_effort.?);
        try std.testing.expectEqualStrings("Bearer fixture-go-key", restored.app.?.client.authorization);
        try std.testing.expect(!restored.app.?.journal.started);
        try std.testing.expect(std.mem.find(u8, restored.settings_notice.?, "history not restored") != null);
        const before_explicit_selection = try tmp.dir.readFileAlloc(std.testing.io, ".thin/config.json", a, .limited(cfg.max_config_bytes));
        defer a.free(before_explicit_selection);
        try std.testing.expectEqualStrings(global_before, before_explicit_selection);
        try restored.connection().selectModel("opencode-zen/gpt-5.6-luna");
        try std.testing.expectEqualStrings("max", restored.app.?.config.value.model.reasoning_effort.?);
        try std.testing.expectEqualStrings("Bearer fixture-zen-key", restored.app.?.client.authorization);
        restored.app.?.journal.observer().notify(.{ .submitted = "not logged" });
        try std.testing.expect(!restored.app.?.journal.started);
    }
    const global_after = try tmp.dir.readFileAlloc(std.testing.io, ".thin/config.json", a, .limited(cfg.max_config_bytes));
    defer a.free(global_after);
    const settings_after = try tmp.dir.readFileAlloc(std.testing.io, ".thin/settings.json", a, .limited(1024));
    defer a.free(settings_after);
    var changed_defaults = try cfg.parse(a, global_after);
    defer cfg.release(&changed_defaults);
    try std.testing.expectEqual(ProviderId.opencode_zen, changed_defaults.value.provider.kind.?);
    try std.testing.expectEqualStrings("gpt-5.6-luna", changed_defaults.value.model.name);
    try std.testing.expectEqualStrings(settings_before, settings_after);
    for (0..3) |case| {
        var invalid = snapshot;
        switch (case) {
            0 => invalid.endpoint = @splat('0'),
            1 => {
                @memcpy(invalid.model_buffer[0..9], "not-local");
                invalid.model_len = 9;
            },
            2 => invalid.effort = .minimal,
            else => unreachable,
        }
        try overwriteFixtureSelection(&source.settings.root, source.session_id, &invalid, "fixture-go-key");
        const expected = switch (case) {
            0 => error.SelectionEndpointUnavailable,
            1 => error.SelectionModelUnavailable,
            else => error.UnsupportedRestoredEffort,
        };
        try std.testing.expectError(expected, Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .restore_selection = source.session_id }));
    }
    try overwriteFixtureSelection(&source.settings.root, source.session_id, &snapshot, "fixture-go-key");
    try tmp.dir.deleteFile(std.testing.io, ".thin/settings.json");
    {
        var restored = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .restore_selection = source.session_id });
        defer restored.deinit();
        try std.testing.expectEqual(presentation.ReasoningEffort.max, restored.preferred_effort.?);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".thin/settings.json", .{}));
    var disk = try source.store.loadExisting();
    defer cfg.release(&disk);
    disk.value.credentials.opencode_go = null;
    try source.store.save(disk.value);
    try std.testing.expectError(error.ApiKeyNotFound, Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .restore_selection = source.session_id }));
    try std.testing.expectError(error.SelectionNotFound, Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .restore_selection = "ffffffffffffffffffffffffffffffff".* }));
}

const OutputMetadataFixture = struct {
    fn listing(a: std.mem.Allocator, cap: ?u32) !metadata.Listing {
        const limit = if (cap) |n| try std.fmt.allocPrint(a, "{{\"output\":{d}}}", .{n}) else try a.dupe(u8, "{}");
        defer a.free(limit);
        const body = try std.fmt.allocPrint(a, "{{\"deepseek\":{{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{{\"deepseek-flash\":{{\"limit\":{s}}}}}}}}}", .{limit});
        defer a.free(body);
        return metadata.parseDev(a, body);
    }
};

test "model output capability freezes across cache refresh effort auth and authenticated resume including unknown" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]?u32{ null, 65536 }) |original| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        {
            var store = try Store.open(a, io, home);
            defer store.deinit();
            var parsed = try store.loadOrInitialize();
            defer cfg.release(&parsed);
            parsed.value.provider = catalog.connection(.deepseek);
            parsed.value.credentials.deepseek = "fake-output-first";
            parsed.value.model = .{ .name = "deepseek-flash", .context_tokens = 131072, .protocol = .chat, .reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high" } } };
            parsed.value.limits.max_output_tokens = null;
            try store.save(parsed.value);
            _ = try metadata.commit(&store.root, 0, try OutputMetadataFixture.listing(a, original));
        }
        var saved_id: ids.Id = undefined;
        {
            var source = try Session.initWithOptions(a, io, &env, home, .{}, true, .{ .auto_refresh_models = false });
            defer source.deinit();
            try std.testing.expectEqual(original, source.app.?.config.value.model.output_tokens);
            var state = try source.app.?.runtime.checkpoint();
            state.messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "preserved output-budget goal" }} }};
            try source.app.?.runtime.restoreCheckpoint(state);
            source.metadata_cache = try metadata.commit(&source.store.root, 0, try OutputMetadataFixture.listing(a, 131072));
            try std.testing.expectEqual(original, source.app.?.config.value.model.output_tokens);
            try source.connection().setEffort(.low);
            try std.testing.expectEqual(original, source.app.?.config.value.model.output_tokens);
            try source.connection().configureProvider(.deepseek, "fake-output-next");
            try source.connection().selectModel("deepseek-flash");
            try std.testing.expectEqual(original, source.app.?.config.value.model.output_tokens);
            try std.testing.expectEqual(@as(usize, 1), source.app.?.runtime.messages().len);
            saved_id = source.session_id;
            try std.testing.expect(try source.saveOnExit());
        }
        {
            // A fresh headless task may use the new cache, without fetching.
            const app = try App.init(a, io, &env, home, .{}, false);
            defer app.deinit();
            try std.testing.expectEqual(@as(?u32, 131072), app.config.value.model.output_tokens);
            try std.testing.expect(app.config.value.limits.max_output_tokens == null);
        }
        {
            var restored = try Session.initWithOptions(a, io, &env, home, .{}, false, .{ .resume_session = saved_id, .logging = false, .auto_refresh_models = false });
            defer restored.deinit();
            try std.testing.expectEqual(original, restored.app.?.config.value.model.output_tokens);
            try std.testing.expectEqual(@as(usize, 1), restored.app.?.runtime.messages().len);
            try std.testing.expectEqualStrings("preserved output-budget goal", restored.app.?.runtime.messages()[0].blocks[0].text);
        }
    }
}

const MetadataFixture = struct {
    var calls: std.atomic.Value(usize) = .init(0);
    fn fetch(_: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
        _ = calls.fetchAdd(1, .monotonic);
        if (key == null or !std.mem.startsWith(u8, key.?, "fake-")) return error.InvalidFixtureKey;
        var values: metadata.Listing = .{};
        for (catalog.entries, 0..) |entry, index| if (entry.provider == id) {
            values.tokens[index] = 1048576;
            values.available[index] = true;
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

test "legacy official URL picker merges current model with cached catalog and selects the displayed capacity" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("THIN_MODEL_DISPLAY_KEY", "fake-model-display-key");
    {
        var store = try Store.open(a, io, home);
        defer store.deinit();
        var parsed = try store.loadOrInitialize();
        defer cfg.release(&parsed);
        var config = parsed.value;
        config.provider.api_key_env = "THIN_MODEL_DISPLAY_KEY";
        try std.testing.expect(config.provider.kind == null);
        try store.save(config);
        _ = try metadata.claim(&store.root, metadata.bit(.deepseek), false);
        var tokens: MetadataTokens = @splat(null);
        tokens[0] = 1048576;
        tokens[1] = 1048576;
        _ = try metadata.commit(&store.root, metadata.bit(.deepseek), .{ .tokens = tokens });
    }
    var session = try Session.init(a, io, &env, home, .{}, true);
    defer session.deinit();
    const connection = session.connection();
    const before = connection.current();
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", before.selection_name.?);
    try std.testing.expectEqual(@as(u32, 1000000), before.context_limit);
    var picker = @import("../ui/model_picker.zig").Picker.init(a);
    defer picker.deinit();
    picker.provider = before.provider;
    const choices_ = try picker.choices(a, before.selection_name.?, before.context_limit, before.models);
    defer a.free(choices_);
    try std.testing.expectEqual(@as(usize, 2), choices_.len);
    try std.testing.expect(choices_[0].current);
    try std.testing.expectEqual(@as(u32, 1048576), choices_[0].context_tokens);
    const rendered = try picker.rowsWithOrigins(a, before.selection_name.?, before.context_limit, before.models, 80, 10, .{ .current = before.context_official, .models = before.model_context_official });
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expect(std.mem.find(u8, rendered.lines[0], "1.048M tokens; official") != null);
    try std.testing.expectEqual(@as(u32, 1000000), connection.current().context_limit);
    try connection.selectModel(choices_[0].name);
    try std.testing.expectEqual(@as(u32, 1048576), connection.current().context_limit);
    try std.testing.expect(connection.current().context_official);
    try std.testing.expect(!session.app.?.journal.started and session.metadata_job == null);
    var proxy = session.mutableConfig().*;
    proxy.provider.kind = null;
    proxy.provider.base_url = "https://proxy.invalid/v1";
    try std.testing.expect(try session.aliasFor(proxy) == null);
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
    Fixture.calls.store(0, .monotonic);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .auto_refresh_models = true, .logging = false });
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

test "official metadata cooldown preserves active budget and resume pins capacity" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    MetadataFixture.calls.store(0, .monotonic);
    var saved_id: ids.Id = undefined;
    {
        var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .auto_refresh_models = true });
        defer session.deinit();
        session.metadata_fetch = MetadataFixture.fetch;
        session.metadata_dev_fetch = MetadataFixture.dev;
        try std.testing.expect(!Session.pollModels(&session, true));
        try std.testing.expect(session.metadata_job == null); // No key yet: no request/attempt.
        try session.connection().configureProvider(.deepseek, "fake-metadata-key");
        const before = session.connection().current().context_limit;
        try std.testing.expect(Session.pollModels(&session, true));
        try std.testing.expect(session.metadata_job != null);
        MetadataFixture.finish(&session);
        try std.testing.expect(Session.pollModels(&session, true));
        try std.testing.expectEqual(@as(usize, 1), MetadataFixture.calls.load(.monotonic));
        try std.testing.expectEqual(before, session.connection().current().context_limit);
        try std.testing.expect(!session.active_context_official);
        const view = session.connection().current();
        try std.testing.expectEqual(@as(u32, 1048576), view.models[0].context_tokens);
        try std.testing.expect(view.model_context_official[0]);
        try std.testing.expect(!Session.pollModels(&session, true));
        try std.testing.expect(session.metadata_job == null);
        var before_selection = try session.store.loadExisting();
        defer cfg.release(&before_selection);
        try std.testing.expectEqual(before, before_selection.value.model.context_tokens);
        try session.connection().selectModel("deepseek/deepseek-flash");
        try std.testing.expectEqual(@as(u32, 1048576), session.connection().current().context_limit);
        try std.testing.expect(session.active_context_official);
        const saved_cache = session.metadata_cache;
        session.metadata_cache.tokens[0] = 1;
        const small_models = try session.buildModels(session.mutableConfig().*, session.global_config.?.value);
        defer session.freeDisplayModels(small_models);
        try std.testing.expectEqual(@as(u32, 1), small_models[0].context_tokens);
        try std.testing.expectError(error.InvalidBudget, session.connection().selectModel("deepseek/deepseek-flash"));
        try std.testing.expectEqual(@as(u32, 1048576), session.connection().current().context_limit);
        session.metadata_cache = saved_cache;
        var local = session.mutableConfig().*;
        local.models = &.{.{ .name = "deepseek/deepseek-flash", .context_tokens = 262144, .protocol = .chat }};
        const models = try session.buildModels(local, session.global_config.?.value);
        defer session.freeDisplayModels(models);
        try std.testing.expectEqual(@as(u32, 262144), models[0].context_tokens);
        var disk = try session.store.loadExisting();
        defer cfg.release(&disk);
        // Refresh alone is inert; the explicit empty-chat selection saves its budget.
        try std.testing.expectEqual(@as(u32, 1048576), disk.value.model.context_tokens);
        const app = session.app.?;
        var state = try app.runtime.checkpoint();
        state.messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "capacity-marker" }} }};
        try app.runtime.restoreCheckpoint(state);
        saved_id = session.session_id;
        try std.testing.expect(try session.saveOnExit());
        var changed: MetadataTokens = @splat(null);
        changed[0] = 524288;
        _ = try metadata.commit(&session.store.root, metadata.bit(.deepseek), .{ .tokens = changed });
    }
    {
        var resumed = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .resume_session = saved_id, .logging = false, .auto_refresh_models = true });
        defer resumed.deinit();
        resumed.metadata_fetch = MetadataFixture.fail;
        resumed.metadata_dev_fetch = MetadataFixture.dev;
        try std.testing.expectEqual(@as(u32, 1048576), resumed.connection().current().context_limit);
        try std.testing.expect(resumed.active_context_official);
        try std.testing.expect(!Session.pollModels(&resumed, true));
        try std.testing.expect(resumed.metadata_job == null and resumed.metadata_auto);
    }
    {
        var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .auto_refresh_models = true });
        defer again.deinit();
        again.metadata_fetch = MetadataFixture.fail;
        again.metadata_dev_fetch = MetadataFixture.dev;
        try std.testing.expect(!Session.pollModels(&again, true));
        try std.testing.expect(again.metadata_job == null);
        try Session.refreshModels(&again); // Explicit refresh can retry a failed source.
        MetadataFixture.finish(&again);
        try std.testing.expect(Session.pollModels(&again, true));
        try std.testing.expectEqual(@as(?u32, 524288), again.metadata_cache.tokens[0]);
        try std.testing.expect(std.mem.find(u8, again.metadata_notice.?, "failed") != null);
        again.metadata_fetch = MetadataFixture.stall;
        again.metadata_dev_fetch = MetadataFixture.dev;
        try Session.refreshModels(&again);
        again.metadata_job.?.started_ms -= 8001; // Deterministic deadline; do not wait 30 seconds.
        try std.testing.expect(!Session.pollModels(&again, false));
        try std.testing.expect(again.metadata_job.?.future == null);
        for (again.metadata_job.?.keys) |key| try std.testing.expect(key == null);
        try std.testing.expect(Session.pollModels(&again, true));
        try std.testing.expectEqual(@as(?u32, 524288), again.metadata_cache.tokens[0]);
    }
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
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .auto_refresh_models = true });
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

test "login refresh opt out remains offline and explicit profiles survive availability filtering" {
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
    try session.connection().configureProvider(.opencode_go, "fake-go-offline");
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null and session.metadata_login_pending == 0);
    session.metadata_cache.available = @splat(false);
    var active = session.mutableConfig().*;
    active.models = &.{.{ .name = "opencode-go/kimi-k3", .context_tokens = 65536, .protocol = .chat }};
    const models = try session.buildModels(active, session.global_config.?.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("opencode-go/kimi-k3", models[0].name);
    try std.testing.expectEqual(@as(u32, 65536), models[0].context_tokens);
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
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer source.deinit();
    try source.connection().configureProvider(.opencode_go, "fake-provenance-go");
    source.metadata_cache = try metadata.commit(&source.store.root, 0, try metadata.parseDev(a, @embedFile("models_dev_fixture.json")));
    try source.connection().selectModel("opencode-go/gpt-6-luna");
    try source.connection().setEffort(.max);
    try std.testing.expectEqual(cfg.ReasoningSource.metadata, source.app.?.config.value.model.reasoning_source);
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning.?.map.max.?);
    // A rejected preference write must not clear the active derived effort/map.
    const preference = try tmp.dir.readFileAlloc(std.testing.io, ".thin/settings.json", a, .limited(1024));
    defer a.free(preference);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/settings.json", .data = "{\"version\":2,\"reasoning_effort\":\"low\"}" });
    if (source.connection().setEffort(.low)) |_| return error.ExpectedPreferenceFailure else |_| {}
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning.?.map.max.?);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/settings.json", .data = preference });
    {
        var disk = try source.store.loadExisting();
        defer cfg.release(&disk);
        try std.testing.expectEqual(cfg.ReasoningSource.metadata, disk.value.model.reasoning_source);
        try std.testing.expect(disk.value.model.reasoning == null and disk.value.model.reasoning_effort == null);
    }
    const tied =
        \\{"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"gpt-6-luna":{"reasoning":true,"provider":{"npm":"@ai-sdk/openai"}}}},"one":{"npm":"@ai-sdk/openai","models":{"gpt-6-luna":{"reasoning_options":[{"type":"effort","values":["high"]}]}}},"two":{"npm":"@ai-sdk/openai","models":{"gpt-6-luna":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    ;
    source.metadata_cache = try metadata.commit(&source.store.root, 0, try metadata.parseDev(a, tied));
    try std.testing.expect(!source.capabilitiesFor(source.app.?.config.value).known);
    // Until an explicit selection, the active runtime retains its frozen map.
    try std.testing.expect(source.app.?.config.value.model.reasoning != null);
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
        var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
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

test "pending auth retains trusted derived map while saving only cache backed defaults" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer source.deinit();
    var listing: metadata.Listing = .{};
    const index = Session.metadataIndex(source.mutableConfig().*).?;
    listing.reasoning[index] = .{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high", .max = "max" } };
    source.metadata_cache = try metadata.commit(&source.store.root, metadata.bit(.deepseek), listing);
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
    var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer again.deinit();
    try std.testing.expectEqualStrings("max", again.mutableConfig().model.reasoning_effort.?);
    try std.testing.expect(again.capabilitiesFor(again.mutableConfig().*).known);
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
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer source.deinit();
    // Old configs omit reasoning_source; user maps must not be removed by value/name guesses.
    var parsed = try cfg.parse(a,
        \\{"provider":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go"},"model":{"name":"gpt-6-luna","protocol":"responses","context_tokens":32768,"reasoning_effort":"high","reasoning":{"map":{"high":"user-intensive"}}}}
    );
    defer cfg.release(&parsed);
    var config = parsed.value;
    const index = LayeredMetadataFixture.index("opencode-go/gpt-6-luna");
    source.metadata_cache.reasoning[index] = .{ .map = .{ .low = "low" } };
    source.metadata_cache.dev_reasoning[index] = .{ .map = .{ .max = "max" } };
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

test "derived metadata protocol or format mismatch clears stale mapping and effort" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer source.deinit();
    const entry = catalog.find("opencode-go/gpt-6-luna").?;
    const index = LayeredMetadataFixture.index(entry.selector);
    source.metadata_cache.dev_reasoning[index] = .{ .map = .{ .high = "high" } };
    var config: cfg.Config = .{ .provider = catalog.connection(entry.provider), .model = entry.model };
    config.model.reasoning = .{ .map = .{ .max = "max" } };
    config.model.reasoning_effort = "max";
    config.model.reasoning_source = .metadata;
    config.model.protocol = .chat;
    source.applyReasoningMetadata(&config);
    try std.testing.expect(config.model.reasoning == null and config.model.reasoning_effort == null);
    try std.testing.expect(!source.capabilitiesFor(config).known);
    config.model.protocol = .responses;
    source.metadata_cache.dev_reasoning[index] = .{ .format = .anthropic, .map = .{ .high = "high" } };
    source.applyReasoningMetadata(&config);
    try std.testing.expect(!source.capabilitiesFor(config).known);
}

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
    fn index(selector: []const u8) usize {
        for (catalog.entries, 0..) |entry, i| if (std.mem.eql(u8, entry.selector, selector)) return i;
        unreachable;
    }
};

test "dynamic models.dev refresh reaches model picker, cached reload and selection preference without POST" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    LayeredMetadataFixture.official_effort.store(false, .release);
    LayeredMetadataFixture.dev_calls.store(0, .monotonic);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .auto_refresh_models = true, .logging = false });
    defer session.deinit();
    session.metadata_fetch = LayeredMetadataFixture.official;
    session.metadata_dev_fetch = LayeredMetadataFixture.dev;
    try session.connection().configureProvider(.opencode_go, "fake-layered-go");
    session.preferred_effort = .max;
    const active_before = session.app.?.config.value.model;
    try std.testing.expect(Session.pollModels(&session, true)); // First/login-triggered refresh.
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(@as(usize, 1), LayeredMetadataFixture.dev_calls.load(.monotonic));
    try std.testing.expectEqualStrings(active_before.name, session.app.?.config.value.model.name);
    try std.testing.expectEqual(active_before.context_tokens, session.app.?.config.value.model.context_tokens);
    try std.testing.expectEqual(active_before.output_tokens, session.app.?.config.value.model.output_tokens);
    const index = LayeredMetadataFixture.index("opencode-go/claude-haiku-5-5");
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
    try std.testing.expectEqualStrings("disabled", disk.dev_reasoning[index].?.map.off.?);
    {
        var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .auto_refresh_models = true, .logging = false });
        defer again.deinit();
        again.metadata_fetch = MetadataFixture.fail;
        again.metadata_dev_fetch = LayeredMetadataFixture.devFail;
        try std.testing.expect(!Session.pollModels(&again, true));
        try std.testing.expect(again.metadata_job == null); // Persisted attempt suppresses a restart fetch.
        again.preferred_effort = .max;
        // Check cached application without rewriting the shared config behind the
        // still-live first Session (whose auth-store digest protects such writes).
        var candidate = again.mutableConfig().*;
        candidate.model = catalog.find("opencode-go/claude-haiku-5-5").?.model;
        try std.testing.expect(again.applyPreference(&candidate) == null);
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
    try std.testing.expect(session.metadata_cache.reasoning[index].?.map.max == null);
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
    try std.testing.expectEqualStrings("max", (try metadata.load(&session.store.root)).dev_reasoning[index].?.map.max.?);
    try std.testing.expect(std.mem.find(u8, session.metadata_notice.?, "models.dev metadata refresh failed") != null);
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
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    session.metadata_fetch = LayeredMetadataFixture.official;
    session.metadata_dev_fetch = LayeredMetadataFixture.devStall;
    LayeredMetadataFixture.official_effort.store(false, .release);
    try session.connection().configureProvider(.opencode_go, "fake-deadline-go");
    const index = LayeredMetadataFixture.index("opencode-go/claude-haiku-5-5");
    const previous = try metadata.parseDev(a, @embedFile("models_dev_fixture.json"));
    session.metadata_cache = try metadata.commit(&session.store.root, 0, previous);
    try Session.refreshModels(&session);
    const job = session.metadata_job.?;
    try MetadataFixture.waitDone(session.io, &job.done);
    try std.testing.expect(job.future != null); // pollModels owns the actual join.
    job.started_ms -= official_metadata_timeout_ms + 1;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == job and job.dev_future != null);
    try std.testing.expectEqual(@as(?u32, 65536), session.metadata_cache.tokens[index]);
    for (job.keys) |key| try std.testing.expect(key == null);
    // Passing the old shared deadline does not cancel the public catalog.
    job.dev_started_ms -= official_metadata_timeout_ms + 1;
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(job.dev_future != null);
    job.dev_started_ms -= models_dev_timeout_ms;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    const saved = try metadata.load(&session.store.root);
    try std.testing.expectEqual(@as(?u32, 65536), saved.tokens[index]);
    try std.testing.expectEqualStrings("max", saved.dev_reasoning[index].?.map.max.?);
    try std.testing.expect(!Session.pollModels(&session, true)); // No tight automatic retry loop.
    // A user retry can still complete after the cancelled catalog attempt.
    session.metadata_dev_fetch = LayeredMetadataFixture.dev;
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqualStrings("max", session.metadata_cache.dev_reasoning[index].?.map.max.?);
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
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false, .auto_refresh_models = true });
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
    const index = LayeredMetadataFixture.index("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqual(@as(?u32, 65536), session.metadata_cache.tokens[index]);
    try session.connection().configureProvider(.opencode_go, "fake-rotated-go");
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == job and job.future != null);
    try std.testing.expectEqual(public_started, job.dev_started_ms);
    try std.testing.expect(job.dev_future != null); // Existing public download not restarted.
    try MetadataFixture.waitDone(session.io, &job.done);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(?u32, 131072), session.metadata_cache.tokens[index]);
    try std.testing.expectEqual(@as(?u32, 131072), (try metadata.load(&session.store.root)).tokens[index]);
    try std.testing.expect(job.dev_future != null and session.metadata_login_pending == 0);
    job.dev_started_ms -= models_dev_timeout_ms + 1;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
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
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    session.metadata_fetch = MetadataFixture.stall;
    session.metadata_dev_fetch = LayeredMetadataFixture.dev;
    try session.connection().configureProvider(.opencode_go, "fake-stalled-official");
    try Session.refreshModels(&session);
    const job = session.metadata_job.?;
    try MetadataFixture.waitDone(session.io, &job.dev_done);
    try std.testing.expect(job.dev_future != null); // pollModels owns the actual join.
    try std.testing.expect(Session.pollModels(&session, true));
    const index = LayeredMetadataFixture.index("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqualStrings("max", session.metadata_cache.dev_reasoning[index].?.map.max.?);
    try std.testing.expect(job.future != null);
    job.started_ms -= official_metadata_timeout_ms + 1;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    session.metadata_dev_fetch = LayeredMetadataFixture.devStall;
    try Session.refreshModels(&session);
    // deinit must cancel/join both futures and wipe the official key copies.
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
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false, .auto_refresh_models = false });
    defer session.deinit();
    session.metadata_fetch = MetadataFixture.fetch;
    session.metadata_dev_fetch = MetadataFixture.dev;
    MetadataFixture.calls.store(0, .monotonic);
    try session.connection().configureProvider(.deepseek, "fake-stale-first-key");
    const index = LayeredMetadataFixture.index("deepseek/deepseek-flash");
    var previous: metadata.Listing = .{};
    previous.tokens[index] = 65536;
    previous.reasoning[index] = .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } };
    session.metadata_cache = try metadata.commitAt(&session.store.root, metadata.bit(.deepseek), previous, 1000);
    session.metadata_wall_ms = 2000;
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session); // Completed with the old key, not yet published.
    try session.connection().configureProvider(.deepseek, "fake-stale-new-key");
    try std.testing.expect(session.metadata_login_pending == 0); // No automatic re-query permission.
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(@as(?u32, 65536), session.metadata_cache.tokens[index]);
    try std.testing.expectEqualStrings("high", session.metadata_cache.reasoning[index].?.map.high.?);
    try std.testing.expectEqual(@as(?u32, 65536), (try metadata.load(&session.store.root)).tokens[index]);
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
    try std.testing.expectEqual(@as(?u32, 1048576), session.metadata_cache.tokens[index]);
    try std.testing.expectEqual(@as(?u64, 2000), session.metadata_cache.refresh[0].last_success_ms);
    try std.testing.expect(session.metadata_cache.refresh[0].successful);
}

test "credential reactivation keeps raw effort frozen budget and retained effective protocol" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |with_map| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [4096]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        {
            var store = try Store.open(a, std.testing.io, home);
            defer store.deinit();
            var parsed = try store.loadOrInitialize();
            defer cfg.release(&parsed);
            parsed.value.provider = catalog.connection(.opencode_go);
            parsed.value.credentials.opencode_go = "fake-retained-first-key";
            parsed.value.model = .{ .name = "gpt-5.6-luna", .context_tokens = 65536, .protocol = .auto, .reasoning_effort = if (with_map) "high" else "raw-user-effort", .reasoning = if (with_map) .{ .map = .{ .high = "user-high" } } else null };
            try store.save(parsed.value);
        }
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
        defer session.deinit();
        const index = LayeredMetadataFixture.index("opencode-go/gpt-5.6-luna");
        session.metadata_cache.tokens[index] = 131072; // Refreshed candidate must not replace actual budget.
        session.active_context_official = with_map;
        const p = @import("../core/protocol.zig");
        try session.app.?.runtime.restoreCheckpoint(.{ .system = "saved", .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "retained question" }} }}, .selector = .{ .configured = .auto, .selected = .chat, .initial_attempted = true }, .estimator = .{}, .last_context_tokens = 1024, .context_tokens = 65536, .permission_id = 0 });
        for ([_][]const u8{ "gpt-5.6-luna", "opencode-go/gpt-5.6-luna" }) |name| {
            try session.connection().configureProvider(.opencode_go, "fake-retained-next-key");
            try session.connection().selectModel(name);
            const model = session.app.?.config.value.model;
            try std.testing.expectEqual(@as(u32, 65536), model.context_tokens);
            try std.testing.expectEqual(with_map, session.active_context_official);
            try std.testing.expectEqual(p.Protocol.chat, session.app.?.runtime.selector.effective());
            try std.testing.expectEqualStrings(if (with_map) "high" else "raw-user-effort", model.reasoning_effort.?);
            try std.testing.expectEqualStrings("Bearer fake-retained-next-key", session.app.?.client.authorization);
            try std.testing.expectEqual(@as(usize, 1), session.app.?.runtime.messages().len);
            if (with_map) try std.testing.expectEqualStrings("user-high", model.reasoning.?.map.high.?) else try std.testing.expect(model.reasoning == null);
        }
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
    var session = try Session.init(a, std.testing.io, &env, home, .{}, true);
    defer session.deinit();

    const entry = catalog.find("opencode-go/gpt-6-luna").?;
    const config: cfg.Config = .{ .provider = catalog.connection(.opencode_go), .model = entry.model };
    const index = Session.metadataIndex(config).?;
    session.metadata_cache.reasoning[index] = .{ .format = .standard, .map = .{ .low = "official-low", .high = "official-high" } };
    const official = session.capabilitiesFor(config);
    try std.testing.expectEqualStrings("official-low", official.map.low.?);
    try std.testing.expect(official.map.max == null);
    session.metadata_cache.reasoning[index] = null;
    // Dynamic models.dev profiles are used only when official metadata is absent.
    session.metadata_cache.dev_reasoning[index] = .{ .format = .standard, .map = .{ .low = "dev-low", .max = "max", .off = "none" } };
    const fallback = session.capabilitiesFor(config);
    try std.testing.expectEqualStrings("dev-low", fallback.map.low.?);
    try std.testing.expectEqualStrings("max", fallback.map.max.?);
    try std.testing.expectEqualStrings("none", fallback.map.off.?);
    session.metadata_cache.dev_reasoning[index] = null;
    try std.testing.expect(!session.capabilitiesFor(config).known); // Missing metadata stays unknown.
}

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
    const haiku_index = for (catalog.entries, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.selector, "opencode-go/claude-haiku-5-5")) break i;
    } else unreachable;
    session.metadata_cache.dev_reasoning[haiku_index] = .{ .format = .anthropic, .map = .{ .off = "disabled", .low = "low", .medium = "medium", .high = "high", .xhigh = "xhigh", .max = "max" } };
    try connection.selectModel("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqualStrings("opencode-go/claude-haiku-5-5", connection.current().selection_name.?);
    try std.testing.expect(app.config.value.model.protocol == .anthropic);
    try std.testing.expect(app.runtime.selector.selected == .anthropic);
    try std.testing.expectEqual(preference.?, presentation.ReasoningEffort.fromName(app.config.value.model.reasoning_effort));
    try std.testing.expectEqualStrings("Bearer fake-go-rotated", app.client.authorization);
    try std.testing.expectEqual(@as(usize, 2), app.runtime.messages().len);
    try std.testing.expectEqual(preference, session.preferred_effort);
    try std.testing.expect(!app.journal.started);
    try std.testing.expectError(error.UnsupportedProviderModel, connection.selectModel("opencode-go/unlisted-claude"));
}

test "current catalog model reactivation preserves explicit wire mapping for name and selector" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    {
        var store = try Store.open(a, std.testing.io, home);
        defer store.deinit();
        var initial = try store.loadOrInitialize();
        defer cfg.release(&initial);
        initial.value.provider.kind = .deepseek;
        initial.value.credentials.deepseek = "fake-explicit-initial-key";
        initial.value.model.reasoning_effort = "high";
        initial.value.model.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .high = "user-high" } };
        try store.save(initial.value);
    }
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    const connection = session.connection();
    for ([_]bool{ false, true }) |use_selector| {
        const key = if (use_selector) "fake-explicit-selector-key" else "fake-explicit-name-key";
        try connection.configureProvider(.deepseek, key);
        try connection.selectModel(if (use_selector) "deepseek/deepseek-flash" else "deepseek-flash");
        try std.testing.expectEqualStrings("user-high", session.app.?.config.value.model.reasoning.?.map.high.?);
        try std.testing.expectEqual(cfg.ReasoningSource.explicit, session.app.?.config.value.model.reasoning_source);
        const authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{key});
        defer a.free(authorization);
        try std.testing.expectEqualStrings(authorization, session.app.?.client.authorization);
        var disk = try session.store.loadExisting();
        defer cfg.release(&disk);
        try std.testing.expectEqualStrings("user-high", disk.value.model.reasoning.?.map.high.?);
        try std.testing.expectEqualStrings("high", disk.value.model.reasoning_effort.?);
    }
    var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer again.deinit();
    try std.testing.expectEqualStrings("user-high", again.mutableConfig().model.reasoning.?.map.high.?);
}

test "same provider authentication preserves newly saved empty conversation defaults" {
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
    try std.testing.expectEqualStrings("configured-next", disk.value.model.name);
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

test "resume session preserves identity context counters and no-log without executing anything" {
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
        var source = try Session.init(a, io, &env, home, .{}, true);
        defer source.deinit();
        try source.connection().configure("fake-resume-source");
        try std.testing.expect(!try source.saveOnExit());
        id = source.session_id;
        var state: checkpoint.State = .{
            .system = "frozen original system",
            .selector = source.app.?.runtime.selector,
            .estimator = .{ .per_mille = 1200 },
            .last_context_tokens = 77,
            .permission_id = 19,
            .messages = &.{
                .{ .role = .user, .blocks = &.{.{ .text = "original question" }} },
                .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "saved-call", .name = "write_file", .arguments = "{\"path\":\"must-not-run.txt\",\"content\":\"no\"}" } }} },
                .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "saved-call", .text = "prior result", .canceled = true, .is_error = true } }} },
                .{ .role = .assistant, .blocks = &.{.{ .text = "original answer" }} },
            },
        };
        state.selector.initial_attempted = true;
        try source.app.?.runtime.restoreCheckpoint(state);
        source.app.?.journal.seq = 13;
        source.app.?.journal.turn = 2;
        try std.testing.expect(try source.saveOnExit());
    }
    {
        var restored = try Session.initWithOptions(a, io, &env, home, .{}, false, .{ .resume_session = id, .logging = false });
        defer restored.deinit();
        try std.testing.expectEqual(id, restored.session_id);
        try std.testing.expectEqualStrings("frozen original system", restored.app.?.runtime.system);
        try std.testing.expectEqual(@as(usize, 4), restored.app.?.runtime.messages().len);
        try std.testing.expectEqual(@as(u64, 13), restored.app.?.journal.seq);
        try std.testing.expectEqual(@as(u64, 2), restored.app.?.journal.turn);
        try std.testing.expectEqual(@as(u64, 77), restored.initial_context.?.tokens);
        try std.testing.expect(!restored.app.?.runtime.trusted);
        try std.testing.expect(!restored.app.?.journal.started);
        try std.testing.expect(!restored.resume_lease.?.active);
        try std.testing.expect(!try restored.saveOnExit());
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "must-not-run.txt", .{}));
    }
    // Wrong locally resolved credential must fail before activating the marker.
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/config.json", .data = "{\"provider\":{\"base_url\":\"https://api.deepseek.com\",\"api_key\":\"wrong-fake-key\"},\"model\":{\"name\":\"deepseek-flash\",\"context_tokens\":1048576,\"protocol\":\"auto\"}}" });
    try std.testing.expectError(error.ResumeAuthenticationFailed, Session.initWithOptions(a, io, &env, home, .{}, true, .{ .resume_session = id }));
    {
        var root = try @import("../platform/filesystem.zig").Root.open(a, io, home);
        defer root.deinit();
        var readable = try resume_store.Lease.open(&root, id, false);
        defer readable.deinit();
    }
}

test "Anthropic authenticated session resume preserves signed replay and never executes tools" {
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
        var source = try Session.init(a, io, &env, home, .{}, true);
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
        var restored = try Session.initWithOptions(a, io, &env, home, .{}, false, .{ .resume_session = id, .logging = false });
        defer restored.deinit();
        try std.testing.expectEqual(id, restored.session_id);
        try std.testing.expect(restored.app.?.runtime.selector.selected == .anthropic);
        try std.testing.expectEqualStrings("opencode-go/claude-haiku-5-5", restored.connection().current().selection_name.?);
        try std.testing.expectEqualStrings(native, restored.app.?.runtime.messages()[1].replay.?.json);
        const actual = try Wire.encode(a, &restored);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected.?, actual);
        try std.testing.expect(!restored.app.?.runtime.trusted);
        try std.testing.expect(!restored.resume_lease.?.active);
        try std.testing.expect(!try restored.saveOnExit());
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "must-not-run.txt", .{}));
    }
}

test "resumed selection changes persist without a new submission and no-log stays read only" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |prior_submission| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        var id: ids.Id = undefined;
        {
            var source = try Session.init(a, io, &env, home, .{}, true);
            defer source.deinit();
            try source.connection().configure("fake-resume-selection");
            id = source.session_id;
            try source.app.?.runtime.restoreCheckpoint(.{
                .system = "saved system",
                .selector = source.app.?.runtime.selector,
                .estimator = .{},
                .last_context_tokens = null,
                .permission_id = 0,
                .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "saved question" }} }},
            });
            if (prior_submission) source.app.?.journal.observer().notify(.{ .submitted = "saved question" });
            try std.testing.expect(try source.saveOnExit());
        }
        // No-log selection changes must not replace the checkpoint generation.
        {
            var readonly = try Session.initWithOptions(a, io, &env, home, .{}, true, .{ .resume_session = id, .logging = false });
            defer readonly.deinit();
            const before = readonly.resume_lease.?.expected;
            try readonly.connection().selectModel("deepseek/deepseek-v4-pro");
            readonly.app.?.journal.flush();
            try std.testing.expect(readonly.app.?.journal.worker == null);
            try std.testing.expect(!try readonly.saveOnExit());
            try std.testing.expectEqual(before, readonly.resume_lease.?.expected);
            const unchanged = try readonly.resume_lease.?.load(&readonly.settings.root);
            defer a.free(unchanged);
        }
        {
            var restored = try Session.initWithOptions(a, io, &env, home, .{}, true, .{ .resume_session = id });
            defer restored.deinit();
            try std.testing.expect(restored.app.?.journal.worker == null);
            try restored.connection().selectModel("deepseek/deepseek-v4-pro");
            restored.app.?.journal.flush();
            try std.testing.expect(restored.app.?.journal.failure() == null);
            try std.testing.expect(restored.checkpointError() == null);
            try std.testing.expect(!restored.app.?.journal.started);
            const checkpoint_bytes = try restored.resume_lease.?.load(&restored.settings.root);
            defer a.free(checkpoint_bytes);
            const saved = try resume_codec.inspect(a, checkpoint_bytes, id);
            try std.testing.expectEqualStrings("deepseek-v4-pro", saved.selection.model());
            try std.testing.expect(try restored.saveOnExit());
        }
        {
            var selection = try Session.initWithOptions(a, io, &env, home, .{}, true, .{ .restore_selection = id, .logging = false });
            defer selection.deinit();
            try std.testing.expectEqualStrings("deepseek-v4-pro", selection.app.?.config.value.model.name);
            try std.testing.expectEqual(@as(usize, 0), selection.app.?.runtime.messages().len);
        }
        {
            var conversation = try Session.initWithOptions(a, io, &env, home, .{}, true, .{ .resume_session = id, .logging = false });
            defer conversation.deinit();
            try std.testing.expectEqualStrings("deepseek-v4-pro", conversation.app.?.config.value.model.name);
            try std.testing.expectEqual(@as(usize, 1), conversation.app.?.runtime.messages().len);
        }
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
        var source = try Session.init(a, io, &env, home, .{}, true);
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
        var resumed = try Session.initWithOptions(a, io, &env, home, .{}, false, .{ .resume_session = id, .logging = false });
        defer resumed.deinit();
        try std.testing.expectEqual(@as(usize, 2), resumed.app.?.runtime.messages().len);
        try std.testing.expectEqualStrings("incremental question", resumed.app.?.runtime.messages()[0].blocks[0].text);
        try std.testing.expectEqualStrings("incremental answer", resumed.app.?.runtime.messages()[1].blocks[0].text);
        try std.testing.expect(!resumed.resume_lease.?.active);
    }
}

test "tool start leaves the checkpoint dirty until the result is published" {
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
        var source = try Session.init(a, io, &env, home, .{}, true);
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
        try std.testing.expect(!source.resume_lease.?.active);
        source.app.?.runtime.observer.notify(.{ .event = .{ .tool_started = .{ .id = 1, .name = "read_file" } } });
        try std.testing.expect(source.resume_lease.?.active);
        try std.testing.expect(source.checkpointError() == null);
        releaseLease(&source);
    }
    try std.testing.expectError(error.ResumeNotClosed, Session.initWithOptions(a, io, &env, home, .{}, true, .{ .resume_session = id }));
}

test "dirty marker failure blocks the tool and checkpoint write failure reaches the UI" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var source = try Session.init(a, io, &env, home, .{}, true);
    defer source.deinit();
    try source.connection().configure("fake-incremental-checkpoint");
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
    try std.testing.expect(!source.resume_lease.?.active);

    source.setCheckpointFailure(error.NoSpaceLeft);
    try std.testing.expectEqual(error.NoSpaceLeft, source.connection().current().log_error.?);
    source.app.?.runtime.observer.notify(.{ .event = .{ .assistant_committed = &.{.{ .text = "incremental answer" }} } });
    source.app.?.journal.flush();
    try std.testing.expect(source.app.?.journal.failure() == null);
    try std.testing.expect(source.checkpointError() == null);
    try std.testing.expect(source.connection().current().log_error == null);

    var lock_name: [64]u8 = undefined;
    const lock_path = try std.fmt.bufPrintSentinel(&lock_name, "{s}.resume-lock", .{source.session_id}, 0);
    const readonly = fs.linux.openat(source.resume_lease.?.directory_fd, lock_path, fs.linux.nofollow | fs.linux.cloexec, 0);
    try std.testing.expect(readonly >= 0);
    fs.closeFd(source.resume_lease.?.lock_fd);
    source.resume_lease.?.lock_fd = readonly;
    source.app.?.runtime.observer.notify(.{ .event = .{ .tool_started = .{ .id = 4, .name = "bash" } } });
    try std.testing.expect(source.checkpointError() != null);
    try std.testing.expect(source.app.?.runtime.tool_blocked);
    try std.testing.expect(!source.resume_lease.?.active);
    source.app.?.journal.flush();
    try std.testing.expect(source.app.?.journal.failure() == null);
    try std.testing.expectEqual(source.checkpointError(), source.connection().current().log_error);

    // Restore a writable lock so the directory-permission failure is the one recorded.
    const writable = fs.linux.openat(source.resume_lease.?.directory_fd, lock_path, 2 | fs.linux.nofollow | fs.linux.cloexec, 0);
    try std.testing.expect(writable >= 0);
    fs.closeFd(source.resume_lease.?.lock_fd);
    source.resume_lease.?.lock_fd = writable;
    source.app.?.runtime.tool_blocked = false;
    defer _ = std.c.fchmodat(tmp.dir.handle, ".thin/sessions", 0o700, 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(tmp.dir.handle, ".thin/sessions", 0o555, 0));
    source.app.?.runtime.observer.notify(.{ .event = .{ .finished = .{ .status = .success } } });
    source.app.?.journal.flush();
    try std.testing.expect(source.app.?.journal.failure() == null);
    try std.testing.expect(source.checkpointError() != null);
    try std.testing.expectEqual(source.checkpointError(), source.connection().current().log_error);
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

test "pending selection owns names and auth preserves the latest saved model options" {
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
    session.pending.?.value.models = &.{.{ .name = "configured", .context_tokens = 65536, .protocol = .chat, .reasoning_effort = "low", .reasoning = testReasoning() }};
    try Session.selectModel(&session, "configured");
    try std.testing.expectEqual(@as(u32, 65536), session.connection().current().context_limit);
    // The unknown initial model persists the logical default medium without
    // inventing a supported level; the explicit profile can now apply it.
    try std.testing.expectEqual(presentation.ReasoningEffort.medium, session.connection().current().reasoning_effort);
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
    try std.testing.expectEqualStrings("transient-again", disk.value.model.name);
    try std.testing.expectEqual(@as(usize, 1), disk.value.models.len);
    try std.testing.expectEqual(@import("../core/protocol.zig").Protocol.chat, disk.value.model.protocol);
    try std.testing.expectEqual(@as(u32, 65536), disk.value.model.context_tokens);
    // Shift+Tab remains a project preference, independent of model defaults.
    try std.testing.expectEqualStrings("medium", disk.value.model.reasoning_effort.?);
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
