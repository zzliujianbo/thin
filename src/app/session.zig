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
const selections = @import("selection_store.zig");
const resume_store = @import("resume_store.zig");
const resume_codec = @import("resume_codec.zig");
const checkpoint = @import("../core/checkpoint.zig");
const metadata = @import("model_metadata.zig");

const MetadataTokens = [catalog.entries.len]?u32;
const MetadataFetch = *const fn (std.mem.Allocator, std.Io, ProviderId, ?[]const u8) anyerror!metadata.Listing;
const DevFetch = *const fn (std.mem.Allocator, std.Io) anyerror!metadata.Listing;
const MetadataJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fetch: MetadataFetch,
    dev_fetch: DevFetch,
    keys: [3]?[]u8 = @splat(null),
    requested: u8 = 0,
    succeeded: u8 = 0,
    listing: metadata.Listing = .{},
    manual: bool,
    started_ms: i64,
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,

    fn run(self: *MetadataJob) void {
        defer self.done.store(true, .release);
        defer self.wipeKeys();
        for (ProviderId.all) |id| {
            const index: usize = @intCast(@backingInt(id));
            const bit = @as(u8, 1) << @intCast(index);
            if (self.requested & bit == 0) continue;
            const values = self.fetch(self.allocator, self.io, id, self.keys[index]) catch |err| {
                if (err == error.Canceled) return;
                continue;
            };
            self.succeeded |= bit;
            for (catalog.entries, 0..) |entry, i| if (entry.provider == id) {
                self.listing.tokens[i] = values.tokens[i];
                self.listing.available[i] = values.available[i];
                self.listing.reasoning[i] = values.reasoning[i];
            };
        }
        // Public models.dev data is independent of provider keys and never blocks
        // the official results above; a failed or cancelled fetch keeps the cache.
        if (self.requested & metadata.dev_bit != 0) {
            if (self.dev_fetch(self.allocator, self.io)) |dev| {
                self.listing.dev = dev.dev;
                self.listing.dev_done = true;
            } else |err| if (err == error.Canceled) return;
        }
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
    metadata_login_auto: bool = false,
    metadata_login_pending: u8 = 0,
    metadata_blocked: bool = false,
    metadata_job: ?*MetadataJob = null,
    metadata_fetch: MetadataFetch = metadata.fetch,
    metadata_dev_fetch: DevFetch = metadata.fetchDev,
    metadata_notice: ?[]const u8 = null,
    active_context_official: bool = false,
    display_origins: [64 + catalog.entries.len]bool = @splat(false),

    resume_lease: ?resume_store.Lease = null,
    resumed: bool = false,

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
        defer if (source_bytes) |bytes| {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        };
        const envelope: ?resume_codec.Envelope = if (source_bytes) |bytes| try resume_codec.inspect(a, bytes, id) else null;
        const restored: ?selections.Snapshot = if (envelope) |value| value.selection else if (options.restore_selection) |source_id| try selections.load(&settings.root, source_id) else null;
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
            .metadata_auto = options.auto_refresh_models and restored == null,
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
            try self.restoreSelection(snapshot);
        } else {
            const config = &self.pending.?.value;
            self.applyReasoningMetadata(config);
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
        self.display_models = try self.buildModels(config.*, self.global_config.?.value);
        self.selected_alias = try self.aliasFor(config.*);
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
        if (envelope) |*value| try resume_codec.authenticate(value, key);
        const restored_state = if (envelope) |value| try checkpoint.decode(a, value.payload) else null;
        defer if (restored_state) |value| value.deinit();
        if (restored_state) |value| {
            if (value.value.context_tokens) |tokens| {
                self.pending.?.value.model.context_tokens = tokens;
                try cfg.validate(self.pending.?.value);
                self.active_context_official = value.value.context_official;
            }
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
            if (options.logging) app.journal.selection_writer.expected = try selections.existingDigest(&self.settings.root, id);
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
        if (model == null) for (catalog.entries) |entry| {
            if (snapshot.provider == entry.provider and ProviderId.fromUrl(candidate.provider.base_url) == entry.provider and std.mem.eql(u8, entry.model.name, snapshot.model())) {
                model = entry.model;
                break;
            }
        };
        candidate.model = model orelse return error.SelectionModelUnavailable;
        candidate.model.protocol = snapshot.protocol;
        self.applyReasoningMetadata(&candidate);
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
        self.allocator.free(self.display_models);
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
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .configure_provider_fn = configureProvider, .select_model_fn = selectModel, .set_effort_fn = setEffort, .initial_history_fn = initialHistory, .refresh_models_fn = refreshModels, .poll_models_fn = pollModels };
    }

    /// Called once, before any producer exists; never exposed by per-frame state.
    fn initialHistory(raw: *anyopaque) []const @import("../core/protocol.zig").Message {
        const self: *Session = @ptrCast(@alignCast(raw));
        return if (self.resumed) self.app.?.runtime.messages() else &.{};
    }

    /// Joined, normal interactive exit only. Not an autosave/crash-recovery log.
    /// A failure never changes task success; the caller must withhold the command.
    pub fn saveOnExit(self: *Session) !bool {
        if (!self.logging) return false;
        const app = self.app orelse return false;
        if (app.runtime.messages().len == 0) return false;
        app.journal.finish();
        var state = try app.runtime.checkpoint();
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
        const bytes = try resume_codec.encode(self.allocator, self.session_id, &selection, payload, key, salt);
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        try resume_store.saveFinal(&self.settings.root, self.session_id, if (self.resume_lease) |*lease| lease else null, bytes);
        return true;
    }

    /// Re-resolve against CURRENT disk options before advertising a command.
    /// A transient unknown model or a rotated-but-not-activated credential must
    /// not produce an apparently usable checkpoint under the old connection.
    fn restorableKey(self: *Session, selection: selections.Snapshot) ![]u8 {
        var resolver = self.*;
        resolver.global_config = try self.store.loadExisting();
        defer cfg.release(&resolver.global_config.?);
        resolver.pending = null;
        defer if (resolver.pending) |*owned| cfg.release(owned);
        try resolver.restoreSelection(selection);
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
            if (index < config.models.len) continue; // Explicit local profiles always win.
            if (catalog.find(model.name)) |entry| {
                if (self.officialCapacity(entry)) |tokens|
                    self.display_origins[index] = tokens == model.context_tokens;
            }
        }
        return .{
            .runtime = if (self.app) |app| &app.runtime else null,
            .initial_context = self.initial_context orelse .{ .tokens = 0, .limit = @intCast(config.model.context_tokens) },
            .model = config.model.name,
            .session_id = self.session_id,
            .models = self.display_models,
            .model_context_official = self.display_origins[0..self.display_models.len],
            .context_official = self.active_context_official,
            .metadata_notice = self.metadata_notice,
            .selection_name = self.selected_alias,
            .provider = config.provider.kind orelse ProviderId.fromUrl(config.provider.base_url),
            .configured_providers = self.configuredMask(self.global_config.?.value),
            .allow_custom_models = config.provider.kind == null,
            .context_limit = config.model.context_tokens,
            .reasoning_effort = presentation.ReasoningEffort.fromName(config.model.reasoning_effort),
            .effort_levels = self.capabilitiesFor(config).levels,
            .settings_error = self.settings_error,
            .settings_notice = self.settings_notice,
            .base_url = config.provider.base_url,
            .tools_trusted = self.trusted,
            .logging_enabled = self.logging,
            .log_error = if (self.app) |app| app.journal.failure() else null,
        };
    }

    fn officialCapacity(self: *const Session, entry: catalog.Entry) ?u32 {
        for (catalog.entries, 0..) |known, index| {
            if (known.provider != entry.provider or !std.mem.eql(u8, known.selector, entry.selector) or
                !std.mem.eql(u8, known.model.name, entry.model.name)) continue;
            // A small official capacity is still authoritative. Show it; model
            // selection must fail budget validation rather than invent a larger
            // fallback when the configured output reserve would not fit.
            return self.metadata_cache.tokens[index];
        }
        return null;
    }

    fn metadataIndex(config: cfg.Config) ?usize {
        const id = config.provider.kind orelse ProviderId.fromUrl(config.provider.base_url) orelse return null;
        for (catalog.entries, 0..) |entry, index| {
            if (entry.provider != id) continue;
            if (std.mem.eql(u8, entry.model.name, config.model.name) or std.mem.eql(u8, entry.selector, config.model.name)) return index;
        }
        return null;
    }

    fn applyReasoningMetadata(self: *const Session, config: *cfg.Config) void {
        if (metadataIndex(config.*)) |index| {
            if (self.metadata_cache.reasoning[index]) |declaration| {
                config.model.reasoning = declaration;
            } else if (config.model.reasoning == null) {
                const entry = catalog.entries[index];
                // A models.dev profile is protocol-specific; a changed local protocol gets no guess.
                config.model.reasoning = if (entry.model.protocol == config.model.protocol)
                    self.metadata_cache.dev_reasoning[index] orelse entry.model.reasoning
                else
                    entry.model.reasoning;
            }
        }
    }

    fn capabilitiesFor(self: *const Session, config: cfg.Config) thinking.Capabilities {
        var effective = config;
        self.applyReasoningMetadata(&effective);
        return thinking.resolve(effective.provider.base_url, effective.model.name, effective.model.reasoning);
    }

    fn declarationForEntry(self: *const Session, entry: catalog.Entry) ?thinking.Declaration {
        for (catalog.entries, 0..) |known, index| {
            if (known.provider == entry.provider and std.mem.eql(u8, known.selector, entry.selector))
                return self.metadata_cache.reasoning[index] orelse self.metadata_cache.dev_reasoning[index] orelse entry.model.reasoning;
        }
        return entry.model.reasoning;
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

    fn startMetadata(self: *Session, requested: u8, manual: bool) !void {
        try self.guardSelection();
        if (self.metadata_job != null) return error.MetadataRefreshBusy;
        if (requested == 0) return error.NoOfficialProvider;
        const job = try self.allocator.create(MetadataJob);
        job.* = .{ .allocator = self.allocator, .io = self.io, .fetch = self.metadata_fetch, .dev_fetch = self.metadata_dev_fetch, .manual = manual, .started_ms = @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds()) };
        errdefer job.destroy();
        for (ProviderId.all) |id| {
            const index: usize = @intCast(@backingInt(id));
            if (requested & (@as(u8, 1) << @intCast(index)) != 0) job.keys[index] = try self.keyFor(id);
        }
        // Claim before launching: first-run failures/timeouts must not create an
        // automatic retry on every start, and concurrent sessions share the claim.
        const claim = try metadata.claim(&self.store.root, requested | metadata.dev_bit, manual);
        self.metadata_cache.attempted = claim.cache.attempted;
        job.requested = claim.mask;
        if (claim.mask == 0) {
            job.destroy();
            return;
        }
        job.future = try std.Io.concurrent(self.io, MetadataJob.run, .{job});
        self.metadata_job = job;
        self.metadata_login_pending &= ~claim.mask;
        self.metadata_notice = null;
    }

    /// Owner polling never waits for network. Completion may change only the
    /// candidate catalog; the active Runtime budget is frozen until selection.
    fn pollModels(raw: *anyopaque, idle: bool) bool {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (self.metadata_job) |job| {
            if (job.future) |*future| {
                if (job.done.load(.acquire)) {
                    future.await(self.io);
                } else if (std.Io.Clock.awake.now(self.io).toMilliseconds() - job.started_ms >= 8000) {
                    future.cancel(self.io);
                } else return false;
                job.future = null;
                job.wipeKeys(); // Also handles cancellation before the worker starts.
            }
            if (!idle) return false;
            defer {
                self.metadata_job = null;
                job.destroy();
            }
            // A login during an older job queues a fresh read with the new key.
            // Do not publish the obsolete provider result over that intention.
            const cache = metadata.commit(&self.store.root, job.succeeded & ~self.metadata_login_pending, job.listing) catch {
                self.metadata_notice = if (job.manual) "Metadata cache could not be saved; previous values kept" else null;
                return true;
            };
            const previous = self.metadata_cache;
            self.metadata_cache = cache;
            const models = self.buildModels(self.mutableConfig().*, self.global_config.?.value) catch {
                self.metadata_cache = previous;
                self.metadata_notice = if (job.manual) "Metadata display could not be updated; previous values kept" else null;
                return true;
            };
            self.allocator.free(self.display_models);
            self.display_models = models;
            const official_requested = job.requested & metadata.provider_mask;
            self.metadata_notice = if (!job.manual) null else if (official_requested == 0)
                (if (job.listing.dev_done) "models.dev metadata refreshed" else "models.dev metadata refresh failed; cached/default values kept")
            else if (job.succeeded == 0)
                "Official metadata refresh failed; cached/default values kept"
            else if (job.succeeded != official_requested)
                "Official metadata partly refreshed; failed sources kept cached/default values"
            else if (job.requested & metadata.dev_bit != 0 and !job.listing.dev_done)
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
        const configured = self.configuredMask(self.global_config.?.value);
        // models.dev is fetched once after the first configured-provider attempt, even
        // when older caches already recorded official attempts without it.
        if (idle and self.metadata_auto and !self.metadata_blocked and configured != 0 and
            (configured & ~self.metadata_cache.attempted != 0 or self.metadata_cache.attempted & metadata.dev_bit == 0))
        {
            self.startMetadata(configured, false) catch {
                self.metadata_blocked = true;
            };
        }
        return false;
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
        // Explicit local profiles plus bounded, officially mapped candidates.
        try models.appendSlice(self.allocator, active.models);
        const configured = self.configuredMask(global);
        for (catalog.entries, 0..) |entry, index| {
            if (configured & (@as(u8, 1) << @intCast(@backingInt(entry.provider))) == 0) continue;
            if (self.metadata_cache.available[index] == false) continue;
            var duplicate = false;
            for (active.models) |profile| if (std.mem.eql(u8, profile.name, entry.selector)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue; // An explicit local profile wins a name collision.
            var model = entry.model;
            if (self.metadata_cache.reasoning[index]) |declaration| {
                model.reasoning = declaration;
            } else if (self.metadata_cache.dev_reasoning[index]) |declaration| {
                model.reasoning = declaration;
            }
            if (self.officialCapacity(entry)) |tokens| model.context_tokens = tokens;
            model.name = entry.selector;
            try models.append(self.allocator, model);
        }
        return models.toOwnedSlice(self.allocator);
    }

    fn aliasFor(self: *Session, config: cfg.Config) !?[]u8 {
        // Legacy configs may use an exact official URL without a named kind.
        // Normalize those identities too, but never infer a provider from a
        // model name or a proxy/custom endpoint.
        const id = config.provider.kind orelse ProviderId.fromUrl(config.provider.base_url) orelse return null;
        for (catalog.entries) |entry| {
            if (entry.provider == id and std.mem.eql(u8, entry.model.name, config.model.name))
                return try self.allocator.dupe(u8, entry.selector);
        }
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
        var disk = global;
        disk.provider = candidate.provider;
        disk.model = candidate.model;
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
        self.applyReasoningMetadata(&candidate);
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
        if (try self.activateSavedCredential(candidate.model, name)) return;
        const owned_name = try self.allocator.dupe(u8, candidate.model.name);
        errdefer self.allocator.free(owned_name);
        const alias = try self.aliasFor(candidate);
        errdefer if (alias) |value| self.allocator.free(value);
        candidate.model.name = owned_name;
        var defaults = try self.selectionDefaults(candidate);
        defer if (defaults) |*value| cfg.release(value);
        const models = try self.buildModels(candidate, if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.allocator.free(models);
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
        self.allocator.free(self.display_models);
        self.display_models = models;
        self.settings_notice = preference_notice;
        self.active_context_official = false;
        if (previous) |old| self.allocator.free(old);
        if (self.app) |app| {
            self.initial_context = app.runtime.contextSnapshot();
            app.recordSelection();
        }
    }

    fn selectProviderModel(self: *Session, entry: catalog.Entry) !void {
        const previous = self.mutableConfig();
        const revision = self.credential_revisions[@intCast(@backingInt(entry.provider))];
        const official = self.officialCapacity(entry);
        const capacity = official orelse entry.model.context_tokens;
        if (self.app != null and previous.provider.kind == entry.provider and
            std.mem.eql(u8, previous.model.name, entry.model.name) and self.active_revision == revision and
            previous.model.context_tokens == capacity and sameDeclaration(previous.model.reasoning, self.declarationForEntry(entry)))
        {
            self.initial_context = self.app.?.runtime.contextSnapshot();
            self.active_context_official = official != null;
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
        next.model.reasoning = self.declarationForEntry(entry);
        next.model.context_tokens = capacity;
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
        var defaults = try self.selectionDefaults(prepared);
        defer if (defaults) |*value| cfg.release(value);
        const models = try self.buildModels(prepared, if (defaults) |value| value.value else self.global_config.?.value);
        errdefer self.allocator.free(models);
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
        self.allocator.free(self.display_models);
        self.display_models = models;
        self.active_revision = revision;
        self.active_context_official = official != null;
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
        // Saving is local and transactional. Refresh starts later on the owner
        // idle poll, even if this provider was already attempted before login.
        if (self.metadata_login_auto) self.metadata_login_pending |= metadata.bit(id);
    }

    fn setEffort(raw: *anyopaque, effort: presentation.ReasoningEffort) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try self.guardSelection();
        const canonical = effort.canonical();
        const name = canonical.name() orelse return error.InvalidReasoningEffort;
        const config = self.mutableConfig();
        self.applyReasoningMetadata(config);
        const capabilities = self.capabilitiesFor(config.*);
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
        if (self.app) |app| app.recordSelection();
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

fn overwriteFixtureSelection(root: *@import("../platform/filesystem.zig").Root, id: ids.Id, snapshot: *const selections.Snapshot) !void {
    var buffer: [selections.max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try selections.encode(&writer, id, snapshot);
    var path: [96]u8 = undefined;
    const relative = try std.fmt.bufPrint(&path, ".thin/sessions/{s}.selection.json", .{id});
    try root.writeMode(relative, writer.buffered(), true, 0o600);
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
    try connection.selectModel("opencode-go/gpt-5.6-luna");
    const app = source.app.?;
    app.journal.observer().notify(.{ .submitted = "old text must not become new history" });
    try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .user, .blocks = &.{.{ .text = "old text must not become new history" }} });
    try connection.setEffort(.max);
    app.journal.flush();
    try std.testing.expect(app.journal.failure() == null);
    try std.testing.expectError(error.UnsupportedProviderModel, connection.selectModel("opencode-go/not-a-preset"));
    const snapshot = try selections.load(&source.settings.root, source.session_id);
    try std.testing.expectEqual(presentation.ReasoningEffort.max, snapshot.effort.?);
    try std.testing.expectEqual(ProviderId.opencode_go, snapshot.provider.?);
    try source.settings.save(.low); // A different new-session default must lose.
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
        try overwriteFixtureSelection(&source.settings.root, source.session_id, &invalid);
        const expected = switch (case) {
            0 => error.SelectionEndpointUnavailable,
            1 => error.SelectionModelUnavailable,
            else => error.UnsupportedRestoredEffort,
        };
        try std.testing.expectError(expected, Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .restore_selection = source.session_id }));
    }
    try overwriteFixtureSelection(&source.settings.root, source.session_id, &snapshot);
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
    fn finish(session: *Session) void {
        const job = session.metadata_job.?;
        job.future.?.await(session.io);
        job.future = null;
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

test "official metadata first attempt caches once without changing active budget and resume pins capacity" {
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
        defer a.free(small_models);
        try std.testing.expectEqual(@as(u32, 1), small_models[0].context_tokens);
        try std.testing.expectError(error.InvalidBudget, session.connection().selectModel("deepseek/deepseek-flash"));
        try std.testing.expectEqual(@as(u32, 1048576), session.connection().current().context_limit);
        session.metadata_cache = saved_cache;
        var local = session.mutableConfig().*;
        local.models = &.{.{ .name = "deepseek/deepseek-flash", .context_tokens = 262144, .protocol = .chat }};
        const models = try session.buildModels(local, session.global_config.?.value);
        defer a.free(models);
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
        try std.testing.expect(resumed.metadata_job == null and !resumed.metadata_auto);
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
    defer a.free(models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("opencode-go/kimi-k3", models[0].name);
    try std.testing.expectEqual(@as(u32, 65536), models[0].context_tokens);
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
            return adapter.encode(allocator, .{
                .scope = .{ .connection = app.config.value.provider.base_url, .model = app.config.value.model.name, .protocol = .anthropic },
                .system = app.runtime.system,
                .messages = app.runtime.messages(),
                .tools = &.{},
                .max_output_tokens = app.config.value.limits.max_output_tokens,
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
    for ([_]bool{ false, true }) |existing_sidecar| {
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
            if (existing_sidecar) source.app.?.journal.observer().notify(.{ .submitted = "saved question" });
            try std.testing.expect(try source.saveOnExit());
        }
        // No-log selection changes must neither create nor overwrite a sidecar.
        {
            var readonly = try Session.initWithOptions(a, io, &env, home, .{}, true, .{ .resume_session = id, .logging = false });
            defer readonly.deinit();
            const before = try selections.existingDigest(&readonly.settings.root, id);
            try readonly.connection().selectModel("deepseek/deepseek-v4-pro");
            readonly.app.?.journal.flush();
            try std.testing.expect(readonly.app.?.journal.worker == null);
            try std.testing.expect(!try readonly.saveOnExit());
            try std.testing.expectEqual(before, try selections.existingDigest(&readonly.settings.root, id));
        }
        {
            var restored = try Session.initWithOptions(a, io, &env, home, .{}, true, .{ .resume_session = id });
            defer restored.deinit();
            try std.testing.expect(restored.app.?.journal.worker == null);
            try restored.connection().selectModel("deepseek/deepseek-v4-pro");
            restored.app.?.journal.flush();
            try std.testing.expect(restored.app.?.journal.failure() == null);
            try std.testing.expect(!restored.app.?.journal.started);
            const snapshot = try selections.load(&restored.settings.root, id);
            try std.testing.expectEqualStrings("deepseek-v4-pro", snapshot.model());
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
