//! Optional auxiliary model. Owns its route/key independently of chat selection;
//! no startup network, tools, protocol fallback or primary usage calibration.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const policy = @import("../core/decision.zig");
const context = @import("../core/context.zig");
const thinking = @import("../core/thinking.zig");
const http = @import("../llm/http.zig");
const systemone = @import("../core/systemone.zig");
const native_http = @import("../llm/decision_http.zig");
const resolver = @import("model_resolver.zig");
const metadata = @import("model_metadata.zig");
const Store = @import("auth_store.zig").Store;

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    source: std.json.Parsed(cfg.Config),
    home: []u8,
    transport_env: std.process.Environ.Map,
    key: ?[]u8 = null,
    resolved: ?*Resolved = null,
    native: ?native_http.Client = null,
    // Auxiliary statistics never enter Runtime.account or its estimator.
    calls: u64 = 0,
    last_usage: p.Usage = .{},
    last_http_status: ?u16 = null,

    const Resolved = struct {
        config: std.json.Parsed(cfg.Config),
        client: http.Client,
    };

    pub fn create(a: std.mem.Allocator, io: std.Io, config: cfg.Config, env: *const std.process.Environ.Map) !?*Client {
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
        const key = cfg.resolveApiKey(a, credentials, env) catch |err| switch (err) {
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
        const proxy_url = if (config.proxyFor(reference.provider, reference.model)) |route| try route.url(a) else null;
        defer if (proxy_url) |url| a.free(url);
        const native: ?native_http.Client = if (declaration.backend == .systemone)
            native_http.Client.initRouted(a, io, env, proxy_url) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null, // An unusable auxiliary environment cannot block archive viewing.
            }
        else
            null;
        self.* = .{ .allocator = a, .io = io, .source = owned, .home = home, .transport_env = transport_env, .key = key, .native = native };
        return self;
    }

    pub fn deinit(self: *Client) void {
        const a = self.allocator;
        if (self.native) |*native| native.deinit();
        if (self.resolved) |resolved| {
            resolved.client.deinit();
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
        return .{ .context = self, .decide_fn = decide, .check_fn = checkService };
    }

    fn resolve(self: *Client) !*Resolved {
        if (self.resolved) |ready| return ready;
        const key = self.key orelse return error.DecisionUnavailable;
        const a = self.allocator;
        const declared = self.source.value.decision.?;
        const reference = try cfg.splitDefault(declared.model);
        const state = try a.create(Resolved);
        errdefer a.destroy(state);
        state.config = try cfg.clone(a, self.source.value);
        errdefer cfg.release(&state.config);
        const config = &state.config.value;
        // Auxiliary caps are explicit and independent of primary price policy.
        config.limits = .{
            .low_price_input = false,
            .input_margin_tokens = 1,
            .safety_tokens = 256,
            .max_input_tokens = declared.max_input_tokens,
            .max_output_tokens = declared.max_output_tokens,
            .request_timeout_ms = declared.request_timeout_ms,
            .max_response_bytes = 128 * 1024,
            .max_event_bytes = 64 * 1024,
        };
        const cache = try a.create(metadata.Cache);
        defer a.destroy(cache);
        cache.* = .{};
        if (self.home.len != 0) {
            if (Store.openExisting(a, self.io, self.home)) |opened| {
                var store = opened;
                defer store.deinit();
                cache.* = metadata.load(&store.root) catch .{};
            } else |_| {}
        }
        const selection = try resolver.resolve(state.config.arena.allocator(), config.*, cache, reference.provider, reference.model, false);
        resolver.apply(config, selection);
        if (config.model.protocol == .auto) return error.UnknownModelProtocol;
        // No applyConfigured/global logical preference: only this model's own
        // explicit declaration/capability can provide wire reasoning settings.
        try cfg.validate(config.*);
        state.client = try http.Client.initWithEnv(a, self.io, config, key, &self.transport_env);
        self.resolved = state;
        return state;
    }

    fn checkService(raw: *anyopaque) !void {
        const self: *Client = @ptrCast(@alignCast(raw));
        try self.checkCleanup();
    }

    fn checkCleanup(self: *const Client) !void {
        if (self.native) |native| if (native.poisoned) return error.CleanupFailed;
        if (self.resolved) |ready| if (ready.client.proxy_http) |transport| if (transport.poisoned) return error.CleanupFailed;
    }

    fn decide(raw: *anyopaque, a: std.mem.Allocator, input: policy.Input, cancel: *const p.Cancellation) !policy.Output {
        const self: *Client = @ptrCast(@alignCast(raw));
        self.last_usage = .{};
        self.last_http_status = null;
        try self.checkCleanup();
        if (cancel.isRequested()) return error.Canceled;
        if (self.source.value.decision.?.backend == .systemone)
            return self.callNative(a, input, cancel);
        const ready = self.resolve() catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.DecisionUnavailable;
        };
        return self.call(a, ready.config.value, ready.client.model(), input, cancel);
    }

    fn callNative(self: *Client, output_allocator: std.mem.Allocator, input: policy.Input, cancel: *const p.Cancellation) !policy.Output {
        const transport = if (self.native) |*native| native else return error.DecisionUnavailable;
        if (transport.poisoned) return error.CleanupFailed;
        if (cancel.isRequested()) return error.Canceled;
        if (input == .refine_outputs and input.refine_outputs.len == 0)
            return .{ .refine_outputs = try output_allocator.alloc(policy.RefineItem, 0) };
        const key = self.key orelse return error.DecisionUnavailable;
        const declared = self.source.value.decision.?;
        const reference = try cfg.splitDefault(declared.model);
        const provider = self.source.value.registry.?.find(reference.provider) orelse return error.DecisionUnavailable;
        // This backend deliberately never resolves a primary Model, metadata
        // window, reasoning setting or Chat wire route for a SystemOne model.
        var scratch = std.heap.ArenaAllocator.init(output_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const payload = try systemone.encodeRequest(a, reference.model, input, declared.max_state_bytes);
        const endpoint = try std.fmt.allocPrint(a, "{s}/systemone", .{std.mem.trimEnd(u8, provider.connection.base_url, "/")});
        if (cancel.isRequested()) return error.Canceled;
        self.calls +|= 1;
        const response = try transport.post(a, endpoint, key, payload, declared.request_timeout_ms, cancel);
        self.last_http_status = response.status;
        if (response.status != 200) return error.DecisionUnavailable;
        const result = try systemone.parseResponse(output_allocator, input, response.body);
        self.last_usage = result.usage;
        if (cancel.isRequested()) {
            policy.freeOutput(output_allocator, result.output);
            return error.Canceled;
        }
        return result.output;
    }

    fn call(self: *Client, output_allocator: std.mem.Allocator, config: cfg.Config, model: p.Model, input: policy.Input, cancel: *const p.Cancellation) !policy.Output {
        if (cancel.isRequested()) return error.Canceled;
        var scratch = std.heap.ArenaAllocator.init(output_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const body = try policy.encodeInput(a, input);
        const messages = [_]p.Message{try p.textMessage(a, .user, body)};
        const system = policy.instruction();
        const estimated = context.rawTokens(system, &.{}, &messages);
        const capabilities = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning);
        const wire = capabilities.wire(config.model.reasoning_effort);
        const request: p.Request = .{
            .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = config.model.protocol },
            .system = system,
            .tools = &.{},
            .messages = &messages,
            .max_output_tokens = try context.outputBudget(config, .normal, estimated),
            .reasoning_effort = wire.effort,
            .thinking = wire.thinking,
            .reasoning_format = capabilities.format,
            .cancellation = cancel,
        };
        if (cancel.isRequested()) return error.Canceled;
        self.calls +|= 1;
        const result = try model.call(a, request, .{});
        if (cancel.isRequested()) return error.Canceled;
        const response = switch (result) {
            .failure => |failure| {
                self.last_usage = failure.usage;
                self.last_http_status = failure.http_status;
                return if (failure.kind == .canceled) error.Canceled else error.DecisionUnavailable;
            },
            .success => |success| success,
        };
        self.last_usage = response.usage;
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

test "decision client is optional, lazy and owns route across chat replacement" {
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
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cancel = p.Cancellation{};
    try std.testing.expectError(error.DecisionUnavailable, client.service().decide(arena.allocator(), .{ .memory_write = .{ .topic = "style", .content = "Prefer concise reports." } }, &cancel));
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    cancel.cancel();
    try std.testing.expectError(error.Canceled, client.service().decide(arena.allocator(), .{ .memory_write = .{ .topic = "style", .content = "Prefer concise reports." } }, &cancel));
}

test "decision client fake wire has own caps no tools and validates output without primary accounting" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://unused.invalid/v1","api_key":"fake-owned-key","models":{"main":{"context_tokens":32768,"protocol":"chat"},"judge":{"context_tokens":32768,"protocol":"chat"}}}}},"decision":{"model":"p/judge","max_output_tokens":256}}
    );
    defer cfg.release(&parsed);
    const client = (try Client.create(a, std.testing.io, parsed.value, &env)).?;
    defer client.deinit();
    const ready = try client.resolve();
    try std.testing.expectEqualStrings("judge", ready.config.value.model.name);
    try std.testing.expect(ready.config.value.model.reasoning_effort == null);
    try std.testing.expect(parsed.value.limits.low_price_input);
    try std.testing.expect(!ready.config.value.limits.low_price_input);
    const Fake = struct {
        calls: usize = 0,
        bad: bool = false,
        fn call(raw: *anyopaque, alloc: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqualStrings("judge", request.scope.model);
            try std.testing.expectEqual(@as(usize, 0), request.tools.len);
            try std.testing.expectEqual(@as(u32, 256), request.max_output_tokens);
            return .{ .success = .{ .message = try p.textMessage(alloc, .assistant, if (self.bad) "{\"write\":true,\"extra\":false}" else "{\"write\":true}"), .usage = .{ .input_tokens = 100, .output_tokens = 5 }, .finish = .stop } };
        }
    };
    var fake = Fake{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const input: policy.Input = .{ .memory_write = .{ .topic = "style", .content = "Prefer concise reports." } };
    var cancel = p.Cancellation{};
    const result = try client.call(arena.allocator(), ready.config.value, .{ .context = &fake, .call_fn = Fake.call }, input, &cancel);
    try std.testing.expect(result.memory_write);
    try std.testing.expectEqual(@as(u64, 1), client.calls);
    try std.testing.expectEqual(@as(?u64, 100), client.last_usage.input_tokens);
    fake.bad = true;
    const bad = client.call(arena.allocator(), ready.config.value, .{ .context = &fake, .call_fn = Fake.call }, input, &cancel);
    if (bad) |_| return error.ExpectedInvalidDecision else |_| {}
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "SystemOne creation stays lazy without capabilities or key and never passes credential env to curl" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://inert.invalid/v1"},"aux":{"base_url":"https://opencode.ai/inference/systemone/v1","api_key_env":"SYSTEMONE_KEY"}}},"decision":{"model":"aux/jev-1.13-free","backend":"systemone"}}
    );
    defer cfg.release(&config);
    const missing = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer missing.deinit();
    try std.testing.expect(missing.resolved == null and missing.native != null);
    var cancel = p.Cancellation{};
    const input: policy.Input = .{ .memory_write = .{ .topic = "style", .content = "concise" } };
    try std.testing.expectError(error.DecisionUnavailable, missing.service().decide(a, input, &cancel));
    const empty = try missing.service().decide(a, .{ .refine_outputs = &.{} }, &cancel);
    policy.freeOutput(a, empty);
    try std.testing.expectEqual(@as(u64, 0), missing.calls);
    try env.put("SYSTEMONE_KEY", "fake-explicit-native-only");
    try env.put("PRIVATE_OTHER_KEY", "fake-must-not-reach-curl");
    const ready = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer ready.deinit();
    try std.testing.expectEqualStrings("fake-explicit-native-only", ready.key.?);
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
    try std.testing.expect(direct.native != null and direct.native.?.explicit_route and direct.native.?.proxy_url == null);
    try std.testing.expectError(error.Canceled, direct.service().decide(a, input, &cancel));
    // Invalid explicit trust roots pause auxiliary use, not history/startup.
    try env.put("CURL_CA_BUNDLE", "bad\nca");
    const unavailable = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer unavailable.deinit();
    try std.testing.expect(unavailable.native == null);
}
