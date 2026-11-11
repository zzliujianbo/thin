//! Optional auxiliary model. Owns its route/key independently of chat selection;
//! no startup network, tools, protocol fallback or primary usage calibration.
const std = @import("std");
const diag = @import("../core/diagnostics.zig");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const policy = @import("../core/decision.zig");
const context = @import("../core/context.zig");
const thinking = @import("../core/thinking.zig");
const http = @import("../llm/http.zig");
const CredentialSource = @import("../core/codex_auth.zig").CredentialSource;
const systemone = @import("../core/systemone.zig");
const native_http = @import("../llm/decision_http.zig");
const resolver = @import("model_resolver.zig");
const metadata = @import("model_metadata.zig");
const Store = @import("auth_store.zig").Store;

fn isCodex(provider: cfg.Provider) bool {
    return provider.kind == .openai_codex and std.mem.eql(u8, provider.base_url, cfg.providers.Id.openai_codex.baseUrl());
}

// A no-op must not bypass transport-only validation. Config resolution has
// already validated the URL syntax; the appended endpoint has a separate
// transport length bound, and frozen environment keys need UTF-8/C1 checks.
fn nativeShortcutSafe(endpoint: []const u8, key: []const u8, payload: []const u8) bool {
    if (endpoint.len > 8192 or key.len == 0 or key.len > 16384 or payload.len > 256 * 1024) return false;
    var it = (std.unicode.Utf8View.init(key) catch return false).iterator();
    while (it.nextCodepoint()) |cp| if (cp < 32 or (cp >= 127 and cp <= 159)) return false;
    return true;
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    source: std.json.Parsed(cfg.Config),
    home: []u8,
    transport_env: std.process.Environ.Map,
    key: ?[]u8 = null,
    codex_source: ?CredentialSource = null,
    resolved: ?*Resolved = null,
    native: ?native_http.Client = null,
    // Auxiliary statistics never enter Runtime.account or its estimator.
    diagnostics: diag.Sink = .{},
    calls: u64 = 0,
    last_usage: p.Usage = .{},
    last_http_status: ?u16 = null,
    diagnostic: policy.Diagnostic = .{},
    last_failure: ?policy.Diagnostic = null,

    const Resolved = struct {
        config: std.json.Parsed(cfg.Config),
        client: ?http.Client = null,
    };

    pub fn create(a: std.mem.Allocator, io: std.Io, config: cfg.Config, env: *const std.process.Environ.Map) !?*Client {
        return createWithCodexSource(a, io, config, env, null);
    }

    pub fn createWithCodexSource(a: std.mem.Allocator, io: std.Io, config: cfg.Config, env: *const std.process.Environ.Map, codex_source: ?CredentialSource) !?*Client {
        if (!config.decisionActive()) return null;
        const declaration = config.decision.?;
        const self = try a.create(Client);
        errdefer a.destroy(self);
        var owned = try cfg.clone(a, config);
        errdefer cfg.release(&owned);
        const home = try a.dupe(u8, env.get("HOME") orelse "");
        errdefer a.free(home);
        const reference = try cfg.splitDefault(declaration.model);
        const provider = (config.registry orelse return error.MissingRegistry).find(reference.provider) orelse return error.DefaultProviderUnavailable;
        var credentials = config;
        credentials.provider = provider.connection;
        // Missing credentials block a decision, not archive viewing/startup.
        const key = if (isCodex(provider.connection)) null else cfg.resolveApiKey(a, credentials, env) catch |err| switch (err) {
            error.ApiKeyNotFound, error.InvalidApiKey => null,
            else => return err,
        };
        errdefer if (key) |secret| {
            std.crypto.secureZero(u8, secret);
            a.free(secret);
        };
        var transport_env = std.process.Environ.Map.init(a);
        errdefer transport_env.deinit();
        if (env.get("CURL_CA_BUNDLE")) |ca| {
            // A malformed auxiliary trust environment pauses only its use.
            if (ca.len <= 8192) try transport_env.put("CURL_CA_BUNDLE", ca) else try transport_env.put("CURL_CA_BUNDLE", "\n");
        }
        // No metadata lookup, protocol selection or transport preparation until
        // first use; malformed auxiliary trust must not block archive viewing.
        self.* = .{ .allocator = a, .io = io, .source = owned, .home = home, .transport_env = transport_env, .key = key, .codex_source = codex_source };
        return self;
    }

    pub fn deinit(self: *Client) void {
        const a = self.allocator;
        if (self.native) |*native| native.deinit();
        if (self.resolved) |resolved| {
            if (resolved.client) |*client| client.deinit();
            cfg.release(&resolved.config);
            a.destroy(resolved);
        }
        if (self.key) |key| {
            std.crypto.secureZero(u8, key);
            a.free(key);
        }
        a.free(self.home);
        self.transport_env.deinit();
        cfg.release(&self.source);
        a.destroy(self);
    }

    pub fn service(self: *Client) policy.Service {
        return .{ .context = self, .decide_fn = decide, .check_fn = checkService, .diagnostic_fn = failureDiagnostic };
    }

    /// Narrow idempotent close for a retained child owner. Every mutable
    /// transport is drained first; an unreaped proxy/native child leaves this
    /// owner intact for a later retry instead of freeing its configuration/key.
    pub fn cleanupForClose(self: *Client) error{CleanupFailed}!void {
        const a = self.allocator;
        if (self.native) |*native| {
            native.deinit();
            if (native.unreaped_pid != null) return error.CleanupFailed;
        }
        if (self.resolved) |ready| if (ready.client) |*client| try client.cleanupForClose();
        if (self.resolved) |resolved| {
            cfg.release(&resolved.config);
            a.destroy(resolved);
            self.resolved = null;
        }
        if (self.key) |key| {
            std.crypto.secureZero(u8, key);
            a.free(key);
            self.key = null;
        }
        a.free(self.home);
        self.home = &.{};
        self.transport_env.deinit();
        self.transport_env = std.process.Environ.Map.init(a);
        cfg.release(&self.source);
        a.destroy(self);
    }

    /// Independent auxiliary owner for a child Runtime. Frozen declaration,
    /// key, filtered CA transport and route are copied. A resolved declaration
    /// reuses its frozen config to build a private HTTP client; an unresolved
    /// one keeps the same lazy resolution policy and performs no probe here.
    /// Mutable transports are never shared.
    pub fn clone(self: *const Client) !*Client {
        const a = self.allocator;
        const io = self.io;
        try self.checkCleanup();
        const copy = try a.create(Client);
        errdefer a.destroy(copy);

        var source = try cfg.clone(a, self.source.value);
        errdefer cfg.release(&source);
        const home = try a.dupe(u8, self.home);
        errdefer a.free(home);
        const key: ?[]u8 = if (self.key) |value| try a.dupe(u8, value) else null;
        errdefer if (key) |value| {
            std.crypto.secureZero(u8, value);
            a.free(value);
        };

        var transport_env = std.process.Environ.Map.init(a);
        errdefer transport_env.deinit();
        var env_it = self.transport_env.iterator();
        while (env_it.next()) |entry| try transport_env.put(entry.key_ptr.*, entry.value_ptr.*);

        var native: ?native_http.Client = null;
        errdefer if (native) |*value| value.deinit();
        var resolved: ?*Resolved = null;
        if (self.resolved) |parent| {
            const state = try a.create(Resolved);
            errdefer a.destroy(state);
            state.client = null;
            state.config = try cfg.clone(a, parent.config.value);
            errdefer cfg.release(&state.config);
            if (state.config.value.model.protocol == .systemone) {
                // Rebuild the already resolved frozen route, never share it.
                const parent_native = self.native orelse return error.DecisionUnavailable;
                native = try native_http.Client.initRouted(a, io, &transport_env, parent_native.proxy_url);
            } else {
                if (isCodex(state.config.value.provider)) {
                    state.client = try http.Client.initCodexWithEnv(a, io, &state.config.value, self.codex_source orelse return error.DecisionUnavailable, &transport_env);
                } else {
                    const frozen_key = key orelse return error.DecisionUnavailable;
                    state.client = try http.Client.initWithEnv(a, io, &state.config.value, frozen_key, &transport_env);
                }
            }
            resolved = state;
        }

        copy.* = .{
            .allocator = a,
            .io = io,
            .source = source,
            .home = home,
            .transport_env = transport_env,
            .key = key,
            .codex_source = self.codex_source,
            .resolved = resolved,
            .native = native,
        };
        return copy;
    }

    fn loadCache(a: std.mem.Allocator, io: std.Io, home: []const u8, cache: *metadata.Cache) void {
        cache.* = .{};
        if (home.len == 0) return;
        if (Store.openExisting(a, io, home)) |opened| {
            var store = opened;
            defer store.deinit();
            cache.* = metadata.load(&store.root) catch .{};
        } else |_| {}
    }

    fn resolve(self: *Client) !*Resolved {
        try self.checkCleanup();
        if (self.resolved) |ready| return ready;
        const a = self.allocator;
        const declared = self.source.value.decision.?;
        const reference = try cfg.splitDefault(declared.model);
        const state = try a.create(Resolved);
        errdefer a.destroy(state);
        state.config = try cfg.clone(a, self.source.value);
        errdefer cfg.release(&state.config);
        const config = &state.config.value;
        // Picker and actual reviewer resolve with the same independent caps.
        config.limits = declared.modelLimits(self.source.value.limits.request_timeout_ms);
        const cache = try a.create(metadata.Cache);
        defer a.destroy(cache);
        loadCache(a, self.io, self.home, cache);
        const selection = try resolver.resolve(state.config.arena.allocator(), config.*, cache, reference.provider, reference.model, false);
        resolver.apply(config, selection);
        if (config.model.protocol == .auto) return error.UnknownModelProtocol;
        // No applyConfigured/global logical preference: only this model's own
        // explicit declaration/capability can provide wire reasoning settings.
        try cfg.validate(config.*);
        state.client = null;
        var prepared_native: ?native_http.Client = null;
        errdefer if (prepared_native) |*native| native.deinit();
        if (config.model.protocol != .systemone) {
            self.diagnostic.stage = .credentials;
            if (isCodex(config.provider)) {
                if (config.provider.codex_oauth == null) return error.ApiKeyNotFound;
                const source = self.codex_source orelse return error.ApiKeyNotFound;
                self.diagnostic.stage = .resolve;
                state.client = try http.Client.initCodexWithEnv(a, self.io, config, source, &self.transport_env);
            } else {
                const key = self.key orelse return error.ApiKeyNotFound;
                self.diagnostic.stage = .resolve;
                state.client = try http.Client.initWithEnv(a, self.io, config, key, &self.transport_env);
            }
        } else if (isCodex(config.provider)) {
            return error.UnsupportedProtocol;
        } else if (self.native == null) {
            // Prepare from the frozen scope/environment without replacing any
            // existing transport. Nothing is published on preparation failure.
            const proxy_url = if (self.source.value.proxyFor(reference.provider, reference.model)) |route| try route.url(a) else null;
            defer if (proxy_url) |url| a.free(url);
            prepared_native = try native_http.Client.initRouted(a, self.io, &self.transport_env, proxy_url);
        }
        if (prepared_native) |native| self.native = native;
        self.resolved = state;
        return state;
    }

    fn checkService(raw: *anyopaque) !void {
        const self: *Client = @ptrCast(@alignCast(raw));
        try self.checkCleanup();
    }

    fn checkCleanup(self: *const Client) !void {
        if (self.native) |native| if (native.poisoned) return error.CleanupFailed;
        if (self.resolved) |ready| if (ready.client) |client| if (client.proxy_http) |transport| if (transport.poisoned) return error.CleanupFailed;
    }

    fn failureDiagnostic(raw: *anyopaque) ?policy.Diagnostic {
        const self: *Client = @ptrCast(@alignCast(raw));
        return self.last_failure;
    }

    fn decide(raw: *anyopaque, a: std.mem.Allocator, input: policy.Input, cancel: *const p.Cancellation) !policy.Output {
        const self: *Client = @ptrCast(@alignCast(raw));
        self.last_usage = .{};
        self.last_http_status = null;
        self.last_failure = null;
        self.diagnostic = .{ .stage = .resolve, .operation = input };
        const before = self.calls;
        var span = diag.Span.start(self.diagnostics, self.io, .{ .stage = .decision_request, .operation = input, .timeout_ms = self.source.value.limits.request_timeout_ms, .count = 0 });
        defer span.finish(.ok);
        const output = self.decideInner(a, input, cancel, &span) catch |err| {
            if (err != error.Canceled) {
                self.diagnostic.setError(err);
                self.diagnostic.http_status = self.last_http_status;
                if (self.diagnostic.stage == .transport) if (self.native) |native| {
                    if (native.last_error) |cause| self.diagnostic.setError(cause);
                    self.diagnostic.transport_exit_code = native.last_exit_code;
                };
                self.last_failure = self.diagnostic;
            }
            span.record.count = if (self.calls != before) 1 else 0;
            span.record.backend = self.diagnostic.backend;
            span.record.http_status = self.last_http_status;
            var detail = self.diagnostic;
            if (err == error.Canceled) detail.setError(err);
            span.record.decision_failure = detail;
            if (self.resolved) |resolved| span.record.protocol = resolved.config.value.model.protocol;
            span.fail(err);
            // Preserve public resolve errors while retaining their local cause.
            // This path never retries a failed or uncertain review.
            if (self.diagnostic.stage == .resolve or self.diagnostic.stage == .credentials)
                return if (err == error.OutOfMemory or err == error.CleanupFailed or err == error.Canceled) err else error.DecisionUnavailable;
            return err;
        };
        span.record.count = if (self.calls != before) 1 else 0;
        span.record.backend = self.diagnostic.backend;
        if (self.resolved) |resolved| span.record.protocol = resolved.config.value.model.protocol;
        self.last_failure = null;
        return output;
    }

    fn decideInner(self: *Client, a: std.mem.Allocator, input: policy.Input, cancel: *const p.Cancellation, span: *diag.Span) !policy.Output {
        try self.checkCleanup();
        if (cancel.isRequested()) return error.Canceled;
        const ready = try self.resolve();
        const config = ready.config.value;
        self.diagnostic.backend = if (config.model.protocol == .systemone) .systemone else .generative;
        var hash = std.hash.Wyhash.init(0);
        hash.update(config.model.name);
        hash.update(@tagName(config.model.protocol));
        span.record.protocol = config.model.protocol;
        span.record.backend = self.diagnostic.backend;
        span.record.timeout_ms = config.limits.request_timeout_ms;
        span.record.route_hash = hash.final();
        if (config.model.protocol == .systemone)
            return self.callNative(a, config, input, cancel, span);
        return self.callWithSpan(a, config, ready.client.?.model(), input, cancel, span);
    }

    fn callNative(self: *Client, output_allocator: std.mem.Allocator, config: cfg.Config, input: policy.Input, cancel: *const p.Cancellation, span: *diag.Span) !policy.Output {
        const transport = if (self.native) |*native| native else return error.DecisionUnavailable;
        if (transport.poisoned) return error.CleanupFailed;
        if (cancel.isRequested()) return error.Canceled;
        if (input == .refine_outputs and input.refine_outputs.len == 0)
            return .{ .refine_outputs = try output_allocator.alloc(policy.RefineItem, 0) };
        self.diagnostic.stage = .credentials;
        const key = self.key orelse return error.ApiKeyNotFound;
        self.diagnostic.stage = .encode;
        const declared = self.source.value.decision.?;
        // Native routing comes only from the independently resolved protocol;
        // SystemOne never borrows generative capabilities or the primary key.
        var scratch = std.heap.ArenaAllocator.init(output_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const payload = try systemone.encodeRequest(a, config.model.name, input, declared.max_state_bytes);
        const endpoint = try std.fmt.allocPrint(a, "{s}/systemone", .{std.mem.trimEnd(u8, config.provider.base_url, "/")});
        if (cancel.isRequested()) return error.Canceled;
        if (input == .refine_outputs and nativeShortcutSafe(endpoint, key, payload)) {
            self.diagnostic.stage = .decode;
            if (try systemone.unchangedRefinement(output_allocator, input.refine_outputs)) |output| {
                if (cancel.isRequested()) {
                    policy.freeOutput(output_allocator, output);
                    return error.Canceled;
                }
                return output;
            }
        }
        self.calls +|= 1;
        attempt(span);
        self.diagnostic.stage = .transport;
        const response = try transport.post(a, endpoint, key, payload, config.limits.request_timeout_ms, cancel);
        self.last_http_status = response.status;
        self.diagnostic.stage = .http;
        if (response.status != 200) return error.DecisionUnavailable;
        self.diagnostic.stage = .decode;
        const result = try systemone.parseResponse(output_allocator, input, response.body);
        self.last_usage = result.usage;
        if (cancel.isRequested()) {
            policy.freeOutput(output_allocator, result.output);
            return error.Canceled;
        }
        return result.output;
    }

    fn call(self: *Client, output_allocator: std.mem.Allocator, config: cfg.Config, model: p.Model, input: policy.Input, cancel: *const p.Cancellation) !policy.Output {
        return self.callWithSpan(output_allocator, config, model, input, cancel, null);
    }

    fn attempt(span: ?*diag.Span) void {
        const s = span orelse return;
        s.record.count = 1;
        if (s.record.span_id == 0) return;
        var point = s.record;
        point.phase = .point;
        // An attempted call is not proof that bytes were sent.
        s.sink.emit(point);
    }

    fn callWithSpan(self: *Client, output_allocator: std.mem.Allocator, config: cfg.Config, model: p.Model, input: policy.Input, cancel: *const p.Cancellation, span: ?*diag.Span) !policy.Output {
        if (cancel.isRequested()) return error.Canceled;
        var scratch = std.heap.ArenaAllocator.init(output_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        self.diagnostic.stage = .encode;
        const body = try policy.encodeInput(a, input);
        const messages = [_]p.Message{try p.textMessage(a, .user, body)};
        const system = policy.instruction(input);
        const estimated = context.rawTokens(system, &.{}, &messages);
        try context.checkInput(config, estimated);
        const capabilities = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning);
        const wire = capabilities.wire(config.model.reasoning_effort);
        const request: p.Request = .{
            .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = config.model.protocol },
            .system = system,
            .tools = &.{},
            .messages = &messages,
            .model_output_tokens = config.model.output_tokens,
            .reasoning_effort = wire.effort,
            .thinking = wire.thinking,
            .reasoning_format = capabilities.format,
            .cancellation = cancel,
        };
        // Local wire/capability failures are not attempted inference calls.
        try @import("../core/checkpoint.zig").validateRequestHistory(a, request);
        if (cancel.isRequested()) return error.Canceled;
        self.calls +|= 1;
        attempt(span);
        self.diagnostic.stage = .transport;
        const result = try model.call(a, request, .{});
        if (cancel.isRequested()) return error.Canceled;
        const response = switch (result) {
            .failure => |failure| {
                self.last_usage = failure.usage;
                self.last_http_status = failure.http_status;
                self.diagnostic.model_failure = failure.kind;
                if (failure.http_status != null) self.diagnostic.stage = .http;
                return if (failure.kind == .canceled) error.Canceled else error.DecisionUnavailable;
            },
            .success => |success| success,
        };
        self.last_usage = response.usage;
        self.diagnostic.stage = .decode;
        if (response.finish != .stop or response.message.role != .assistant) return error.InvalidDecision;
        var text: std.ArrayList(u8) = .empty;
        for (response.message.blocks) |block| switch (block) {
            .text => |part| {
                if (part.len > 65536 -| text.items.len) return error.InvalidDecision;
                try text.appendSlice(a, part);
            },
            .reasoning => {},
            else => return error.InvalidDecision,
        };
        return policy.parseOutput(output_allocator, input, text.items);
    }
};
