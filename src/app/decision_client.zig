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

test "decision diagnostics early failure is count zero and route remains lazy" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","reasoning_effort":"high","providers":{"main":{"base_url":"http://main.invalid/v1","models":{"chat":{"context_tokens":32768,"protocol":"chat"}}},"judge":{"base_url":"http://judge.invalid/v1","models":{"mini":{"context_tokens":16384,"protocol":"responses"}}}}},"decision":{"model":"judge/mini"}}
    );
    const optional = parsed.value.decision;
    parsed.value.decision = null;
    try std.testing.expect(try Client.create(a, std.testing.io, parsed.value, &env) == null);
    parsed.value.decision = optional;
    const client = (try Client.create(a, std.testing.io, parsed.value, &env)).?;
    defer client.deinit();
    cfg.release(&parsed);
    try std.testing.expect(client.resolved == null and client.calls == 0);
    try std.testing.expectEqualStrings("judge/mini", client.source.value.decision.?.model);
    try std.testing.expect(client.source.value.model.reasoning_effort == null);
    const Capture = struct {
        records: [4]diag.Record = undefined,
        len: usize = 0,
        fn next(_: ?*anyopaque) u64 {
            return 1;
        }
        fn emit(raw: ?*anyopaque, record: diag.Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.records[self.len] = record;
            self.len += 1;
        }
    };
    var events: Capture = .{};
    client.diagnostics = .{ .context = &events, .emit_fn = Capture.emit, .next_fn = Capture.next };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cancel = p.Cancellation{};
    try std.testing.expectError(error.DecisionUnavailable, client.service().decide(arena.allocator(), .{ .command = .{ .command = "printf fixture" } }, &cancel));
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(?u32, 0), events.records[1].count);
    try std.testing.expectEqual(diag.Result.failed, events.records[1].result.?);
    try std.testing.expect(events.records[1].decision_failure != null);
    cancel.cancel();
    try std.testing.expectError(error.Canceled, client.service().decide(arena.allocator(), .{ .command = .{ .command = "printf fixture" } }, &cancel));
}

test "decision diagnostics fake attempts decode failure and clone sink isolation" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://unused.invalid/v1","api_key":"fake-owned-key","models":{"main":{"context_tokens":32768,"protocol":"chat"},"judge":{"context_tokens":32768,"protocol":"chat"}}}}},"decision":{"model":"p/judge"},"limits":{"request_timeout_ms":4321}}
    );
    defer cfg.release(&parsed);
    const client = (try Client.create(a, std.testing.io, parsed.value, &env)).?;
    defer client.deinit();
    const ready = try client.resolve();
    try std.testing.expectEqualStrings("judge", ready.config.value.model.name);
    try std.testing.expect(ready.config.value.model.reasoning_effort == null);
    try std.testing.expect(parsed.value.limits.low_price_input);
    try std.testing.expect(!ready.config.value.limits.low_price_input);
    try std.testing.expectEqual(@as(u32, 4321), ready.config.value.limits.request_timeout_ms);
    const Fake = struct {
        calls: usize = 0,
        bad: bool = false,
        fn call(raw: *anyopaque, alloc: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqualStrings("judge", request.scope.model);
            try std.testing.expectEqual(@as(usize, 0), request.tools.len);
            try std.testing.expect(request.model_output_tokens == null);
            try std.testing.expectEqualStrings(policy.instruction(.{ .command = .{ .command = "printf fixture" } }), request.system);
            try std.testing.expect(std.mem.indexOf(u8, request.system, policy.ReviewRules.command_risk) != null);
            try std.testing.expect(std.mem.indexOf(u8, request.system, "For command:") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.system, "For refine_outputs:") == null);
            try std.testing.expectEqual(@as(usize, 1), request.messages.len);
            try std.testing.expectEqual(@as(usize, 1), request.messages[0].blocks.len);
            const body = request.messages[0].blocks[0].text;
            const parsed_body = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
            defer parsed_body.deinit();
            const root = parsed_body.value.object;
            try std.testing.expectEqual(@as(usize, 2), root.count());
            try std.testing.expectEqualStrings("command", root.get("operation").?.string);
            const data = root.get("data").?.object;
            try std.testing.expectEqualStrings("printf fixture", data.get("command").?.string);
            if (data.get("risk")) |risk| {
                try std.testing.expectEqual(@as(usize, 2), data.count());
                try std.testing.expect(risk == .null);
            } else try std.testing.expectEqual(@as(usize, 1), data.count());
            for ([_][]const u8{ "timeout", "timing", "deadline", "milliseconds" }) |word| {
                try std.testing.expect(std.mem.indexOf(u8, body, word) == null);
                try std.testing.expect(std.mem.indexOf(u8, request.system, word) == null);
            }
            return .{ .success = .{ .message = try p.textMessage(alloc, .assistant, if (self.bad) "{\"ask\":\"invalid\"}" else "{\"ask\":true}"), .usage = .{ .input_tokens = 100, .output_tokens = 5 }, .finish = .stop } };
        }
    };
    var fake = Fake{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const input: policy.Input = .{ .command = .{ .command = "printf fixture" } };
    var cancel = p.Cancellation{};
    const Capture = struct {
        records: [8]diag.Record = undefined,
        len: usize = 0,
        fn next(_: ?*anyopaque) u64 {
            return 42;
        }
        fn emit(raw: ?*anyopaque, record: diag.Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.records[self.len] = record;
            self.len += 1;
        }
    };
    var capture: Capture = .{};
    const sink: diag.Sink = .{ .context = &capture, .emit_fn = Capture.emit, .next_fn = Capture.next };
    client.diagnostics = sink;
    const child = try client.clone();
    defer child.deinit();
    try std.testing.expectEqual(@as(u64, 0), child.diagnostics.next());
    var span = diag.Span.start(sink, std.testing.io, .{ .stage = .decision_request, .count = 0 });
    const result = try client.callWithSpan(arena.allocator(), ready.config.value, .{ .context = &fake, .call_fn = Fake.call }, input, &cancel, &span);
    span.finish(.ok);
    try std.testing.expectEqual(@as(usize, 3), capture.len);
    try std.testing.expectEqual(diag.Phase.point, capture.records[1].phase);
    try std.testing.expectEqual(@as(?u32, 1), capture.records[1].count);
    try std.testing.expectEqual(capture.records[0].span_id, capture.records[1].span_id);
    try std.testing.expect(result.command.ask);
    try std.testing.expectEqual(@as(u64, 1), client.calls);
    try std.testing.expectEqual(@as(?u64, 100), client.last_usage.input_tokens);
    fake.bad = true;
    var bad_span = diag.Span.start(sink, std.testing.io, .{ .stage = .decision_request, .count = 0 });
    const bad = client.callWithSpan(arena.allocator(), ready.config.value, .{ .context = &fake, .call_fn = Fake.call }, input, &cancel, &bad_span);
    if (bad) |_| return error.ExpectedInvalidDecision else |err| bad_span.fail(err);
    try std.testing.expectEqual(diag.Phase.point, capture.records[4].phase);
    try std.testing.expectEqual(diag.Result.failed, capture.records[5].result.?);
    try std.testing.expect(capture.records[5].error_name != null);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "decision client rejects unknown or zero Anthropic capacity before counting calls" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://unused.invalid/v1","api_key":"fake-owned-key","models":{"main":{"context_tokens":32768,"protocol":"chat"},"judge":{"context_tokens":32768,"protocol":"anthropic"}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&parsed);
    for ([_]?u32{ null, 0, 8192 }) |capacity| {
        const client = (try Client.create(a, std.testing.io, parsed.value, &env)).?;
        defer client.deinit();
        var config = (try client.resolve()).config.value;
        config.model.output_tokens = capacity;
        const FakeCapacity = struct {
            calls: usize = 0,
            fn invoke(raw: *anyopaque, alloc: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
                const self: *@This() = @ptrCast(@alignCast(raw));
                self.calls += 1;
                try std.testing.expectEqual(@as(?u32, 8192), request.model_output_tokens);
                const wire = try @import("../llm/anthropic.zig").encode(alloc, request);
                const json = try std.json.parseFromSlice(std.json.Value, alloc, wire, .{});
                defer json.deinit();
                try std.testing.expectEqual(@as(i64, 8192), json.value.object.get("max_tokens").?.integer);
                return .{ .success = .{ .message = try p.textMessage(alloc, .assistant, "{\"ask\":true}"), .finish = .stop, .usage = .{ .input_tokens = 7, .output_tokens = 1 } } };
            }
        };
        var fake: FakeCapacity = .{};
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var cancel: p.Cancellation = .{};
        const outcome = client.call(arena.allocator(), config, .{ .context = &fake, .call_fn = FakeCapacity.invoke }, .{ .command = .{ .command = "printf fixture" } }, &cancel);
        if (capacity == null or capacity.? == 0) {
            try std.testing.expectError(if (capacity == null) error.UnknownModelOutputCapacity else error.InvalidModelOutputCapacity, outcome);
            try std.testing.expectEqual(@as(usize, 0), fake.calls);
            try std.testing.expectEqual(@as(u64, 0), client.calls);
            try std.testing.expect(client.last_usage.input_tokens == null and client.last_http_status == null);
        } else {
            try std.testing.expect((try outcome).command.ask);
            try std.testing.expectEqual(@as(usize, 1), fake.calls);
            try std.testing.expectEqual(@as(u64, 1), client.calls);
            try std.testing.expectEqual(@as(?u64, 7), client.last_usage.input_tokens);
        }
    }
}

test "SystemOne metadata refresh prepares frozen auxiliary transport without rebuilding or sending" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var store = try Store.open(a, std.testing.io, home);
    defer store.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("AUX_KEY", "fake-aux-frozen-key");
    try env.put("CURL_CA_BUNDLE", "/owned/fake-ca.pem");
    var config = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"protocol":"chat","context_tokens":32768}}},"Zen":{"base_url":"https://opencode.ai/zen/v1","api_key_env":"AUX_KEY","models":{"reviewer/raw-id":{}}}}},"decision":{"model":"Zen/reviewer/raw-id"},"proxy":{"address":"127.0.0.1","port":18973,"models":["Zen/reviewer/raw-id"]}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    try std.testing.expect(client.native == null and client.resolved == null);
    const unresolved_clone = try client.clone();
    defer unresolved_clone.deinit();
    try std.testing.expect(unresolved_clone.native == null and unresolved_clone.resolved == null);
    try std.testing.expectError(error.UnknownModelProtocol, client.resolve());
    try std.testing.expect(client.native == null and client.resolved == null);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    // Later external credentials/trust/proxies cannot alter the owned client.
    try env.put("AUX_KEY", "fake-later-key");
    try env.put("CURL_CA_BUNDLE", "bad\nca");
    try env.put("HTTPS_PROXY", "bad\nproxy");
    const invalid_trust = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer invalid_trust.deinit();
    try std.testing.expect(invalid_trust.native == null and invalid_trust.resolved == null);
    const invalid_clone = try invalid_trust.clone();
    defer invalid_clone.deinit();
    try std.testing.expect(invalid_clone.native == null and invalid_clone.resolved == null);
    const listing = try a.create(metadata.Listing);
    defer a.destroy(listing);
    listing.* = try metadata.parseDev(a,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"reviewer/raw-id":{"api":{"url":"https://opencode.ai/inference/systemone/v1"}}}}}
    );
    const published = try a.create(metadata.Cache);
    defer a.destroy(published);
    published.* = try metadata.commit(&store.root, 0, listing.*);
    // Failed preparation must release the temporary resolved config and remain
    // unpublished/retryable, not leave a native-null ready state behind.
    for (0..2) |_| {
        try std.testing.expectError(error.InvalidProxyEnvironment, invalid_trust.resolve());
        try std.testing.expect(invalid_trust.native == null and invalid_trust.resolved == null);
        try std.testing.expectEqual(@as(u64, 0), invalid_trust.calls);
    }
    try std.testing.expectError(error.InvalidProxyEnvironment, invalid_clone.resolve());
    try std.testing.expect(invalid_clone.native == null and invalid_clone.resolved == null);
    const ready = try client.resolve();
    try std.testing.expectEqual(p.Protocol.systemone, ready.config.value.model.protocol);
    try std.testing.expect(client.native != null and ready.client == null);
    try std.testing.expectEqualStrings("https://opencode.ai/inference/systemone/v1", ready.config.value.provider.base_url);
    try std.testing.expectEqualStrings("reviewer/raw-id", ready.config.value.model.name);
    try std.testing.expectEqualStrings("Zen/reviewer/raw-id", client.source.value.decision.?.model);
    try std.testing.expectEqualStrings("fake-aux-frozen-key", client.key.?);
    try std.testing.expectEqualStrings("/owned/fake-ca.pem", client.native.?.env.get("CURL_CA_BUNDLE").?);
    try std.testing.expect(client.native.?.env.get("AUX_KEY") == null);
    try std.testing.expect(client.native.?.env.get("HTTPS_PROXY") == null);
    try std.testing.expect(client.native.?.explicit_route);
    try std.testing.expectEqualStrings("http://127.0.0.1:18973", client.native.?.proxy_url.?);
    try std.testing.expect(ready == try client.resolve());
    // An unresolved clone resolves independently from the later metadata; a
    // resolved clone preserves the route with its own native owner/config.
    const unresolved_ready = try unresolved_clone.resolve();
    try std.testing.expectEqual(p.Protocol.systemone, unresolved_ready.config.value.model.protocol);
    try std.testing.expect(unresolved_clone.native != null);
    const resolved_clone = try client.clone();
    defer resolved_clone.deinit();
    try std.testing.expect(resolved_clone.resolved != null and resolved_clone.native != null);
    try std.testing.expect(resolved_clone.resolved.? != ready);
    try std.testing.expectEqualStrings("http://127.0.0.1:18973", resolved_clone.native.?.proxy_url.?);
    try std.testing.expect(resolved_clone.native.?.proxy_url.?.ptr != client.native.?.proxy_url.?.ptr);
    try std.testing.expectEqualStrings("/owned/fake-ca.pem", resolved_clone.native.?.env.get("CURL_CA_BUNDLE").?);
    try std.testing.expectEqual(@as(u64, 0), resolved_clone.calls);
    client.native.?.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, client.resolve());
    try std.testing.expectError(error.CleanupFailed, client.checkCleanup());
    try resolved_clone.checkCleanup();
    try std.testing.expect(client.native.?.poisoned);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}

test "SystemOne creation stays lazy without capabilities or key and never passes credential env to curl" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://inert.invalid/v1"},"aux":{"base_url":"https://opencode.ai/inference/systemone/v1","api_key_env":"SYSTEMONE_KEY"}}},"decision":{"model":"aux/native-reviewer"}}
    );
    defer cfg.release(&config);
    const missing = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer missing.deinit();
    try std.testing.expect(missing.resolved == null and missing.native == null);
    var cancel = p.Cancellation{};
    const input: policy.Input = .{ .command = .{ .command = "printf fixture" } };
    try std.testing.expectError(error.DecisionUnavailable, missing.service().decide(a, input, &cancel));
    try std.testing.expectEqual(p.Protocol.systemone, missing.resolved.?.config.value.model.protocol);
    try std.testing.expect(missing.resolved.?.client == null and missing.native != null);
    const diagnostic = missing.last_failure.?;
    try std.testing.expectEqual(policy.Diagnostic.Stage.credentials, diagnostic.stage);
    try std.testing.expectEqual(policy.Diagnostic.Backend.systemone, diagnostic.backend);
    try std.testing.expectEqual(policy.Diagnostic.Operation.command, diagnostic.operation);
    try std.testing.expectEqualStrings("ApiKeyNotFound", diagnostic.causeName());
    try std.testing.expect(diagnostic.http_status == null and diagnostic.transport_exit_code == null);
    const empty = try missing.service().decide(a, .{ .refine_outputs = &.{} }, &cancel);
    policy.freeOutput(a, empty);
    try std.testing.expect(missing.last_failure == null);
    try std.testing.expectEqual(@as(u64, 0), missing.calls);
    try env.put("SYSTEMONE_KEY", "fake-explicit-native-only");
    try env.put("PRIVATE_OTHER_KEY", "fake-must-not-reach-curl");
    const ready = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer ready.deinit();
    try std.testing.expectEqualStrings("fake-explicit-native-only", ready.key.?);
    try std.testing.expect(ready.native == null and ready.resolved == null);
    _ = try ready.resolve();
    try std.testing.expect(ready.native.?.env.get("SYSTEMONE_KEY") == null);
    try std.testing.expect(ready.native.?.env.get("PRIVATE_OTHER_KEY") == null);
    ready.native.?.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, ready.service().decide(a, input, &cancel));
    try std.testing.expectEqual(@as(u64, 0), ready.calls);
    cancel.cancel();
    // Sticky poison also wins when the subsequent caller is already canceled.
    try std.testing.expectError(error.CleanupFailed, ready.service().decide(a, input, &cancel));
    // Ambient proxies never select inference routes, including malformed ones.
    try env.put("HTTPS_PROXY", "bad\nproxy");
    const direct = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer direct.deinit();
    try std.testing.expect(direct.native == null and direct.resolved == null);
    try std.testing.expectError(error.Canceled, direct.service().decide(std.testing.failing_allocator, input, &cancel));
    try std.testing.expect(direct.native == null and direct.resolved == null and direct.calls == 0);
    _ = try direct.resolve();
    try std.testing.expect(direct.native != null and direct.native.?.explicit_route and direct.native.?.proxy_url == null);
    // Invalid explicit trust roots pause auxiliary use, not history/startup.
    try env.put("CURL_CA_BUNDLE", "bad\nca");
    const unavailable = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer unavailable.deinit();
    try std.testing.expect(unavailable.native == null and unavailable.resolved == null);
    var uncanceled = p.Cancellation{};
    try std.testing.expectError(error.DecisionUnavailable, unavailable.service().decide(a, input, &uncanceled));
    try std.testing.expectEqual(policy.Diagnostic.Stage.resolve, unavailable.last_failure.?.stage);
    try std.testing.expectEqualStrings("InvalidProxyEnvironment", unavailable.last_failure.?.causeName());
    try std.testing.expect(unavailable.native == null and unavailable.resolved == null and unavailable.calls == 0);
}

test "decision creation and unresolved clone allocate no metadata cache" {
    const Gate = struct {
        cache_attempts: usize = 0,
        deny: bool = true,
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (len == @sizeOf(metadata.Cache)) {
                self.cache_attempts += 1;
                if (self.deny) return null;
            }
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var gate: Gate = .{};
    const a: std.mem.Allocator = .{ .ptr = &gate, .vtable = &.{ .alloc = Gate.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = Gate.free } };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // This is only a frozen string: no directory lookup occurs at creation.
    try env.put("HOME", "/synthetic/never-opened-decision-home");
    var config = try cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key":"fake-key","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"systemone"}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    const child = try client.clone();
    defer child.deinit();
    try std.testing.expectEqual(@as(usize, 0), gate.cache_attempts);
    try std.testing.expect(client.native == null and client.resolved == null and child.native == null and child.resolved == null);
    // resolve allocates its cache before loadCache could open the directory.
    try std.testing.expectError(error.OutOfMemory, client.resolve());
    try std.testing.expectEqual(@as(usize, 1), gate.cache_attempts);
    try std.testing.expect(client.native == null and client.resolved == null);
    gate.deny = false;
    const ready = try client.resolve();
    try std.testing.expect(client.native != null and client.resolved.? == ready);
    try std.testing.expectEqual(@as(usize, 2), gate.cache_attempts);
    try std.testing.expect(try client.resolve() == ready);
    try std.testing.expectEqual(@as(usize, 2), gate.cache_attempts);
}

test "native no-op validates bounds copies and frees after cancellation" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key":"fake-key","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"systemone"}}}}},"decision":{"model":"p/judge","max_state_bytes":16384}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    const Capture = struct {
        records: [4]diag.Record = undefined,
        len: usize = 0,
        fn next(_: ?*anyopaque) u64 {
            return 9;
        }
        fn emit(raw: ?*anyopaque, record: diag.Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.records[self.len] = record;
            self.len += 1;
        }
    };
    var capture: Capture = .{};
    client.diagnostics = .{ .context = &capture, .next_fn = Capture.next, .emit_fn = Capture.emit };
    const items = [_]policy.RefineItem{
        .{ .id = "original-a", .text = "诊断\ntick\nerror" },
        .{ .id = "original-b", .text = "```\ntick\ntick\ntick\n```" },
    };
    var cancel: p.Cancellation = .{};
    const output = try client.service().decide(a, .{ .refine_outputs = &items }, &cancel);
    defer policy.freeOutput(a, output);
    for (items, output.refine_outputs) |item, copy| {
        try std.testing.expectEqualStrings(item.id, copy.id);
        try std.testing.expectEqualStrings(item.text, copy.text);
        try std.testing.expect(item.id.ptr != copy.id.ptr and item.text.ptr != copy.text.ptr);
    }
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    try std.testing.expect(client.native != null and client.resolved != null and client.last_failure == null and client.last_http_status == null);
    inline for (@typeInfo(p.Usage).@"struct".field_names) |name| try std.testing.expect(@field(client.last_usage, name) == null);
    try std.testing.expectEqual(@as(usize, 2), capture.len);
    try std.testing.expectEqual(@as(?u32, 0), capture.records[1].count);
    try std.testing.expectEqual(diag.Result.ok, capture.records[1].result.?);
    try std.testing.expectEqual(policy.Diagnostic.Backend.systemone, capture.records[1].backend.?);
    client.diagnostics = .{};

    const bad_inputs = [_]policy.Input{
        .{ .refine_outputs = &.{ .{ .id = "same", .text = "x" }, .{ .id = "same", .text = "y" } } },
        .{ .refine_outputs = &.{.{ .id = "", .text = "x" }} },
        .{ .refine_outputs = &.{.{ .id = "id", .text = "\xff" }} },
        .{ .refine_outputs = &.{.{ .id = "\xff", .text = "valid" }} },
        .{ .refine_outputs = &.{.{ .id = "id", .text = "" }} },
        .{ .refine_outputs = &.{
            .{ .id = "0", .text = "x" }, .{ .id = "1", .text = "x" }, .{ .id = "2", .text = "x" },
            .{ .id = "3", .text = "x" }, .{ .id = "4", .text = "x" }, .{ .id = "5", .text = "x" },
            .{ .id = "6", .text = "x" }, .{ .id = "7", .text = "x" }, .{ .id = "8", .text = "x" },
        } },
    };
    for (bad_inputs) |input| try std.testing.expectError(error.InvalidDecisionInput, client.service().decide(a, input, &cancel));
    const too_long: [8193]u8 = @splat('x');
    try std.testing.expectError(error.InvalidDecisionOutput, client.service().decide(a, .{ .refine_outputs = &.{.{ .id = "long", .text = &too_long }} }, &cancel));
    const exact = try client.service().decide(a, .{ .refine_outputs = &.{.{ .id = "long", .text = too_long[0..8192] }} }, &cancel);
    defer policy.freeOutput(a, exact);
    try std.testing.expectEqual(@as(usize, 8192), exact.refine_outputs[0].text.len);
    const escaped: [8200]u8 = @splat('"');
    try std.testing.expectError(error.DecisionInputTooLarge, client.service().decide(a, .{ .refine_outputs = &.{.{ .id = "escaped", .text = &escaped }} }, &cancel));
    try std.testing.expectEqual(@as(u64, 0), client.calls);

    const Allocation = struct {
        fn run(output_allocator: std.mem.Allocator, subject: *Client) !void {
            var token: p.Cancellation = .{};
            const result = try subject.service().decide(output_allocator, .{ .refine_outputs = &.{
                .{ .id = "owned-a", .text = "tick\nerror" },
                .{ .id = "owned-b", .text = "```\ntick\ntick\ntick" },
            } }, &token);
            policy.freeOutput(output_allocator, result);
        }
    };
    var stable_vtable = a.vtable.*;
    stable_vtable.resize = std.mem.Allocator.noResize;
    stable_vtable.remap = std.mem.Allocator.noRemap;
    const stable: std.mem.Allocator = .{ .ptr = a.ptr, .vtable = &stable_vtable };
    try std.testing.checkAllAllocationFailures(stable, Allocation.run, .{client});
    try std.testing.expectEqual(@as(u64, 0), client.calls);

    // Trigger cancellation precisely while allocating the returned text.
    const text = "diagnostic text unique to cancellation fixture";
    const CancelAllocator = struct {
        cancel: *p.Cancellation,
        triggered: bool = false,
        matching_frees: usize = 0,
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = std.testing.allocator.rawAlloc(len, alignment, ra);
            if (result != null and len == text.len) {
                self.triggered = true;
                self.cancel.cancel();
            }
            return result;
        }
        fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (bytes.len == text.len) self.matching_frees += 1;
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var during: p.Cancellation = .{};
    var observer: CancelAllocator = .{ .cancel = &during };
    const observed: std.mem.Allocator = .{ .ptr = &observer, .vtable = &.{ .alloc = CancelAllocator.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = CancelAllocator.free } };
    try std.testing.expectError(error.Canceled, client.service().decide(observed, .{ .refine_outputs = &.{.{ .id = "canceled-copy", .text = text }} }, &during));
    try std.testing.expect(observer.triggered and observer.matching_frees == 1);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}

test "native no-op does not bypass transport-only key checks" {
    const a = std.testing.allocator;
    try std.testing.expect(nativeShortcutSafe("http://fixture.invalid/systemone", "key", "{}"));
    try std.testing.expect(!nativeShortcutSafe("http://fixture.invalid/systemone", "bad\xff", "{}"));
    try std.testing.expect(!nativeShortcutSafe("http://fixture.invalid/systemone", "bad\xc2\x85", "{}"));
    const long_endpoint: [8193]u8 = @splat('x');
    try std.testing.expect(!nativeShortcutSafe(&long_endpoint, "key", "{}"));
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("AUX_KEY", "bad\xff");
    var config = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key_env":"AUX_KEY","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"systemone"}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    var cancel: p.Cancellation = .{};
    try std.testing.expectError(error.InvalidKey, client.service().decide(a, .{ .refine_outputs = &.{.{ .id = "id", .text = "diagnostic" }} }, &cancel));
    try std.testing.expectEqual(@as(u64, 1), client.calls);
    try std.testing.expectEqual(policy.Diagnostic.Stage.transport, client.last_failure.?.stage);
}

test "unresolved native poison and cleanup retain the owner" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key":"fake-key","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"systemone"}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    var destroyed = false;
    defer if (!destroyed) client.deinit();
    client.native = try native_http.Client.initRouted(a, std.testing.io, &env, null);
    client.native.?.poisoned = true;
    client.native.?.unreaped_pid = 1; // Invalid sentinel, never an actual process.
    var cancel: p.Cancellation = .{};
    cancel.cancel();
    try std.testing.expectError(error.CleanupFailed, client.service().decide(a, .{ .refine_outputs = &.{.{ .id = "id", .text = "diagnostic" }} }, &cancel));
    try std.testing.expectError(error.CleanupFailed, client.resolve());
    try std.testing.expectError(error.CleanupFailed, client.clone());
    try std.testing.expect(client.native.?.poisoned and client.resolved == null and client.calls == 0);
    try std.testing.expectError(error.CleanupFailed, client.cleanupForClose());
    try std.testing.expect(client.native.?.unreaped_pid == 1 and client.key != null and client.resolved == null);
    client.native.?.unreaped_pid = null;
    try client.cleanupForClose();
    destroyed = true;
}

test "generative refinement still invokes the model for a native no-op" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key":"fake-key","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"chat","context_tokens":32768}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    const ready = try client.resolve();
    const Fake = struct {
        calls: usize = 0,
        fn invoke(raw: *anyopaque, allocator: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .success = .{ .message = try p.textMessage(allocator, .assistant, "{\"items\":[{\"id\":\"id\",\"text\":\"short\"}]}"), .finish = .stop } };
        }
    };
    var fake: Fake = .{};
    var cancel: p.Cancellation = .{};
    const result = try client.call(a, ready.config.value, .{ .context = &fake, .call_fn = Fake.invoke }, .{ .refine_outputs = &.{.{ .id = "id", .text = "long diagnostic" }} }, &cancel);
    defer policy.freeOutput(a, result);
    try std.testing.expectEqualStrings("short", result.refine_outputs[0].text);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(u64, 1), client.calls);
}

test "resolved decision clone rebuilds a private client and keeps the frozen config" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CURL_CA_BUNDLE", "/owned/decision-ca.pem");
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"context_tokens":32768,"protocol":"chat"}}},"judge":{"base_url":"http://judge.invalid/v1","api_key":"fake-judge-key","models":{"mini":{"context_tokens":16384,"protocol":"chat"}}}}},"decision":{"model":"judge/mini"}}
    );
    defer cfg.release(&parsed);
    const parent = (try Client.create(a, std.testing.io, parsed.value, &env)).?;
    defer parent.deinit();
    const ready = try parent.resolve();
    try std.testing.expect(ready.client != null);
    parent.calls = 7;
    parent.last_usage.input_tokens = 100;
    const clone = try parent.clone();
    defer clone.deinit();
    try std.testing.expect(clone.resolved != null);
    try std.testing.expect(clone.resolved.?.client != null);
    const parent_http = if (ready.client) |*client| client else unreachable;
    const clone_http = if (clone.resolved.?.client) |*client| client else unreachable;
    try std.testing.expect(&clone_http.http != &parent_http.http);
    try std.testing.expect(&clone_http.request_mutex != &parent_http.request_mutex);
    try std.testing.expect(clone_http.config != parent_http.config);
    try std.testing.expectEqualStrings("mini", clone.resolved.?.config.value.model.name);
    try std.testing.expectEqualStrings("fake-judge-key", clone.key.?);
    try std.testing.expectEqualStrings("/owned/decision-ca.pem", clone.transport_env.get("CURL_CA_BUNDLE").?);
    try std.testing.expectEqual(@as(u64, 0), clone.calls);
    try std.testing.expect(clone.last_usage.input_tokens == null and parent.last_usage.input_tokens == 100);
}
