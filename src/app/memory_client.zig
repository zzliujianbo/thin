//! Isolated generative memory extractor. Never touches Runtime/history/accounts,
//! metadata resolution or Decision/Image selection. Construction does no network.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const knowledge = @import("../core/knowledge.zig");
const codec = @import("../core/knowledge_codec.zig");
const context = @import("../core/context.zig");
const thinking = @import("../core/thinking.zig");
const http = @import("../llm/http.zig");
const common = @import("../llm/common.zig");

pub const Client = struct {
    backing: std.mem.Allocator,
    wiping: cfg.WipingAllocator,
    io: std.Io,
    source: std.json.Parsed(cfg.Config),
    key: ?[]u8 = null,
    transport: ?http.Client = null,
    model_override: ?p.Model = null,
    calls: u64 = 0,
    last_usage: p.Usage = .{},
    last_http_status: ?u16 = null,

    /// config is the actual frozen primary selection (not a declaration to resolve).
    /// Absent credentials/unsupported protocol are lazy extraction failures only.
    pub fn create(a: std.mem.Allocator, io: std.Io, config: cfg.Config, env: *const std.process.Environ.Map) !*Client {
        const self = try a.create(Client);
        self.* = .{ .backing = a, .wiping = .{ .backing = a }, .io = io, .source = undefined };
        const owned = self.wiping.allocator();
        errdefer {
            var wipe: cfg.WipingAllocator = .{ .backing = a };
            wipe.allocator().destroy(self);
        }
        self.source = if (config.selection_pending) try cfg.clonePendingSettings(owned, config) else try cfg.clone(owned, config);
        errdefer cfg.release(&self.source);
        // Decoded JSON bounds are independent of provider output length and SSE
        // framing. Retain validated wire/event limits and codec payload bounds,
        // without imposing a separate helper token allowance.
        const frozen = &self.source.value;
        self.key = cfg.resolveApiKey(owned, frozen.*, env) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        errdefer if (self.key) |key| owned.free(key);
        // initWithEnv snapshots only HTTP/proxy necessities and performs no I/O.
        // An auto route may own a transport now, but cannot call until bound to
        // the primary Runtime's actually confirmed protocol on the helper worker.
        if (!frozen.selection_pending and frozen.model.protocol != .systemone) {
            if (self.key) |key| self.transport = http.Client.initWithEnv(owned, io, frozen, key, env) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
        }
        return self;
    }

    /// Fail-stop: an unreaped curl child must never be discarded. A void
    /// destructor cannot transfer retryable ownership, so terminate before freeing
    /// its config/allocator. This mirrors the application's fail-stop shutdown.
    pub fn deinit(self: *Client) void {
        // Drain the pool, close the proxy transport and free the key in one place:
        // a clean close legitimately marks the curl owner poisoned, so only an
        // actual unreaped child is fatal here.
        if (self.transport) |*transport| transport.cleanupForClose() catch @panic("memory transport cleanup failed");
        const owned = self.wiping.allocator();
        if (self.key) |key| owned.free(key);
        cfg.release(&self.source);
        var wipe: cfg.WipingAllocator = .{ .backing = self.backing };
        wipe.allocator().destroy(self);
    }

    /// Helper-worker only, serialized with extract/deinit. The coordinator must
    /// supply the primary Runtime's confirmed protocol, never a guessed preset.
    /// No probing, allocation, credential resolution or request occurs here.
    pub fn bindProtocol(self: *Client, protocol: p.Protocol) !void {
        if (protocol != .chat and protocol != .responses and protocol != .anthropic) return error.UnsupportedProtocol;
        if (self.source.value.selection_pending) return error.UnknownModelProtocol;
        if (self.source.value.model.protocol == .systemone or cfg.providers.Id.fromSystemOneUrl(self.source.value.provider.base_url) != null) return error.UnsupportedProtocol;
        if (self.transport) |transport| if (transport.proxy_http) |proxy| if (proxy.poisoned or proxy.unreaped_pid != null) return error.CleanupFailed;
        const current = self.source.value.model.protocol;
        if (current == protocol) return;
        if (current != .auto) return error.ProtocolBindingMismatch;
        var candidate = self.source.value;
        candidate.model.protocol = protocol;
        try cfg.validate(candidate);
        // The owned transport references source.value, so its frozen route and
        // request now agree without rebuilding HTTP or retaining the whole env.
        self.source.value.model.protocol = protocol;
    }

    /// The extraction allocator should be a caller-owned (preferably wiping)
    /// arena spanning extraction, Service validation and candidate consumption.
    /// This client allocates its result there; borrowed fake services need not.
    /// Service/coordinator errors do not transfer arena cleanup responsibility.
    pub fn service(self: *Client) knowledge.Service {
        return .{ .context = self, .extract_fn = extract };
    }
    fn check(self: *const Client, cancel: *const p.Cancellation) !void {
        if (self.transport) |transport| if (transport.proxy_http) |proxy| if (proxy.poisoned or proxy.unreaped_pid != null) return error.CleanupFailed;
        if (cancel.isRequested()) return error.Canceled;
        self.io.checkCancel() catch return error.Canceled;
    }
    fn extract(raw: *anyopaque, out: std.mem.Allocator, material: knowledge.Material, cancel: *const p.Cancellation) ![]const knowledge.Candidate {
        const self: *Client = @ptrCast(@alignCast(raw));
        self.last_usage = .{};
        self.last_http_status = null;
        try self.check(cancel);
        const config = self.source.value;
        if (config.model.protocol == .systemone or cfg.providers.Id.fromSystemOneUrl(config.provider.base_url) != null) return error.UnsupportedProtocol;
        // Never probe auto: a protocol fallback could duplicate a paid POST.
        if (config.selection_pending or config.model.protocol == .auto) return error.UnknownModelProtocol;
        const model = self.model_override orelse if (self.transport) |*transport| transport.model() else return error.MemoryUnavailable;
        var wipe: cfg.WipingAllocator = .{ .backing = out };
        var scratch = std.heap.ArenaAllocator.init(wipe.allocator());
        defer scratch.deinit();
        const a = scratch.allocator();
        const body = try codec.encode(a, material);
        try self.check(cancel);
        const messages = [_]p.Message{try p.textMessage(a, .user, body)};
        const estimated = context.rawTokens(codec.instruction, &.{}, &messages);
        try context.checkInput(config, estimated);
        const capabilities = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning);
        const wire = capabilities.wire(config.model.reasoning_effort);
        const request: p.Request = .{
            .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = config.model.protocol },
            .system = codec.instruction,
            .tools = &.{},
            .messages = &messages,
            .model_output_tokens = config.model.output_tokens,
            .reasoning_effort = wire.effort,
            .thinking = wire.thinking,
            .reasoning_format = capabilities.format,
            .purpose = .normal,
            .cancellation = cancel,
        };
        // Validate the actual frozen request before counting an inference attempt.
        try @import("../core/checkpoint.zig").validateRequestHistory(a, request);
        try self.check(cancel);
        self.calls +|= 1;
        // Streamed usage survives even a thrown cancellation/cleanup failure.
        var sink: UsageSink = .{ .client = self, .cancel = cancel };
        const outcome = model.call(a, request, .{ .context = &sink, .emit_fn = UsageSink.emit }) catch |err| {
            // Cleanup ownership failure outranks concurrent cancellation.
            if (err == error.CleanupFailed) return err;
            try self.check(cancel);
            if (err == error.OutOfMemory or err == error.Canceled or err == error.InvalidMemoryOutput) return err;
            return error.MemoryUnavailable;
        };
        const response = switch (outcome) {
            .failure => |failure| {
                common.mergeUsage(&self.last_usage, failure.usage);
                self.last_http_status = failure.http_status;
                try self.check(cancel);
                return if (failure.kind == .canceled) error.Canceled else error.MemoryUnavailable;
            },
            .success => |success| success,
        };
        common.mergeUsage(&self.last_usage, response.usage);
        try self.check(cancel);
        if (response.refused or response.finish != .stop or response.message.role != .assistant) return error.InvalidMemoryOutput;
        if (response.message.replay) |replay| {
            if (replay.scope.protocol != request.scope.protocol or
                !std.mem.eql(u8, replay.scope.connection, request.scope.connection) or
                !std.mem.eql(u8, replay.scope.model, request.scope.model)) return error.InvalidMemoryOutput;
            try checkNative(a, replay);
        }
        var text: std.ArrayList(u8) = .empty;
        for (response.message.blocks) |block| switch (block) {
            .text => |part| {
                if (part.len > codec.max_output_bytes -| text.items.len) return error.InvalidMemoryOutput;
                try text.appendSlice(a, part);
            },
            .reasoning => {}, // Explicit metadata only; never extraction evidence.
            else => return error.InvalidMemoryOutput,
        };
        // Validate into wipeable scratch before publishing a fully owned batch.
        _ = try codec.parse(a, material, text.items);
        try self.check(cancel);
        const result = try codec.parse(out, material, text.items);
        errdefer codec.freeCandidates(out, result);
        try self.check(cancel);
        return result;
    }
};
// Native replay is never sent back or used as evidence. Inspect only explicit
// refusal/type metadata: ordinary text/signatures may contain arbitrary words.
fn checkNative(a: std.mem.Allocator, replay: p.Replay) !void {
    if (replay.json.len > 32768 or !std.unicode.utf8ValidateSlice(replay.json)) return error.InvalidMemoryOutput;
    // Refuse pathological native metadata before the recursive JSON parser.
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (replay.json) |c| {
        if (quoted) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false;
        } else switch (c) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > 16) return error.InvalidMemoryOutput;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidMemoryOutput;
                depth -= 1;
            },
            else => {},
        }
    }
    if (quoted or depth != 0) return error.InvalidMemoryOutput;
    var parsed = std.json.parseFromSlice(std.json.Value, a, replay.json, .{ .duplicate_field_behavior = .@"error" }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidMemoryOutput;
    };
    defer parsed.deinit();
    const value = parsed.value;
    switch (replay.scope.protocol) {
        .chat => {
            if (value != .object) return error.InvalidMemoryOutput;
            try assistantRole(value);
            if (value.object.get("refusal")) |refusal| if (refusal != .null) return error.InvalidMemoryOutput;
            for ([_][]const u8{ "tool_calls", "function_call" }) |key| if (value.object.get(key)) |calls| {
                if (calls != .null and !(calls == .array and calls.array.items.len == 0)) return error.InvalidMemoryOutput;
            };
        },
        .responses => {
            if (value != .array) return error.InvalidMemoryOutput;
            for (value.array.items) |item| {
                if (item != .object) return error.InvalidMemoryOutput;
                const typ = item.object.get("type") orelse return error.InvalidMemoryOutput;
                if (typ != .string) return error.InvalidMemoryOutput;
                if (item.object.get("status")) |status| {
                    if (status != .string or !std.mem.eql(u8, status.string, "completed")) return error.InvalidMemoryOutput;
                }
                if (std.mem.eql(u8, typ.string, "message")) {
                    try assistantRole(item);
                    const parts = item.object.get("content") orelse return error.InvalidMemoryOutput;
                    if (parts != .array) return error.InvalidMemoryOutput;
                    for (parts.array.items) |part| {
                        if (part != .object) return error.InvalidMemoryOutput;
                        const kind = part.object.get("type") orelse return error.InvalidMemoryOutput;
                        if (kind != .string or !std.mem.eql(u8, kind.string, "output_text")) return error.InvalidMemoryOutput;
                    }
                } else if (!std.mem.eql(u8, typ.string, "reasoning")) return error.InvalidMemoryOutput;
            }
        },
        .anthropic => {
            if (value != .object) return error.InvalidMemoryOutput;
            try assistantRole(value);
            if (value.object.get("stop_reason")) |reason| {
                if (reason != .string or (!std.mem.eql(u8, reason.string, "end_turn") and !std.mem.eql(u8, reason.string, "stop_sequence"))) return error.InvalidMemoryOutput;
            }
            const parts = value.object.get("content") orelse return error.InvalidMemoryOutput;
            if (parts != .array) return error.InvalidMemoryOutput;
            for (parts.array.items) |part| {
                if (part != .object) return error.InvalidMemoryOutput;
                const typ = part.object.get("type") orelse return error.InvalidMemoryOutput;
                if (typ != .string or (!std.mem.eql(u8, typ.string, "text") and !std.mem.eql(u8, typ.string, "thinking") and !std.mem.eql(u8, typ.string, "redacted_thinking"))) return error.InvalidMemoryOutput;
            }
        },
        else => return error.InvalidMemoryOutput,
    }
}
test "memory client native metadata rejects tools refusal partial deep duplicates" {
    const a = std.testing.allocator;
    const Case = struct { protocol: p.Protocol, json: []const u8 };
    for ([_]Case{
        .{ .protocol = .chat, .json = "{\"role\":\"assistant\",\"refusal\":\"no\"}" },
        .{ .protocol = .chat, .json = "{\"role\":\"assistant\",\"tool_calls\":[{}]}" },
        .{ .protocol = .chat, .json = "{\"role\":\"assistant\",\"function_call\":{}}" },
        .{ .protocol = .chat, .json = "{\"role\":\"assistant\",\"role\":\"assistant\"}" },
        .{ .protocol = .responses, .json = "[{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"incomplete\",\"content\":[]}]" },
        .{ .protocol = .responses, .json = "[{\"type\":\"function_call\"}]" },
        .{ .protocol = .responses, .json = "[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\"}]}]" },
        .{ .protocol = .anthropic, .json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\"}]}" },
        .{ .protocol = .anthropic, .json = "{\"role\":\"assistant\",\"content\":[],\"stop_reason\":\"refusal\"}" },
    }) |case| try std.testing.expectError(error.InvalidMemoryOutput, checkNative(a, .{ .scope = .{ .connection = "fixture", .model = "fixture", .protocol = case.protocol }, .json = case.json }));
    var deep: [40]u8 = undefined;
    @memset(deep[0..20], '[');
    @memset(deep[20..], ']');
    try std.testing.expectError(error.InvalidMemoryOutput, checkNative(a, .{ .scope = .{ .connection = "fixture", .model = "fixture", .protocol = .responses }, .json = &deep }));
}
fn assistantRole(value: std.json.Value) !void {
    const role = value.object.get("role") orelse return error.InvalidMemoryOutput;
    if (role != .string or !std.mem.eql(u8, role.string, "assistant")) return error.InvalidMemoryOutput;
}
const UsageSink = struct {
    client: *Client,
    cancel: *const p.Cancellation,
    text_bytes: usize = 0,
    fn emit(raw: ?*anyopaque, event: p.ModelEvent) !void {
        const self: *UsageSink = @ptrCast(@alignCast(raw.?));
        if (event == .usage) common.mergeUsage(&self.client.last_usage, event.usage);
        try self.client.check(self.cancel);
        switch (event) {
            .tool_delta => return error.InvalidMemoryOutput,
            .text_delta => |part| {
                if (part.len > codec.max_output_bytes -| self.text_bytes) return error.InvalidMemoryOutput;
                self.text_bytes += part.len;
            },
            else => {},
        }
    }
};

const fixture: knowledge.Material = .{ .id = "test", .generation = 1, .created_ms = 100, .sources = &.{.{ .id = 0, .kind = .user, .text = "Prefer Zig." }} };
const Fake = struct {
    calls: usize = 0,
    mode: enum { empty, failure, cancel, tool, thrown, canceled_cleanup, partial_usage, partial, reasoning, oversized } = .empty,
    client: ?*Client = null,
    fn invoke(raw: *anyopaque, a: std.mem.Allocator, request: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try std.testing.expectEqual(@as(usize, 0), request.tools.len);
        try std.testing.expectEqual(p.Purpose.normal, request.purpose);
        try std.testing.expectEqual(p.Protocol.chat, request.scope.protocol);
        try std.testing.expectEqualStrings("primary/model", request.scope.model);
        try std.testing.expectEqualStrings("http://primary.invalid/v1", request.scope.connection);
        try std.testing.expectEqual(@as(usize, 1), request.messages.len);
        const client = self.client.?;
        try std.testing.expectEqual(client.source.value.model.output_tokens, request.model_output_tokens);
        try std.testing.expect(client.source.value.limits.low_price_input);
        try std.testing.expectEqual(@as(u32, 1234), client.source.value.limits.request_timeout_ms);
        const usage: p.Usage = .{ .input_tokens = 17, .output_tokens = 3 };
        try sink.emit(.{ .usage = usage });
        if (self.mode == .cancel or self.mode == .canceled_cleanup) @constCast(request.cancellation.?).cancel();
        if (self.mode == .thrown or self.mode == .canceled_cleanup) return error.CleanupFailed;
        if (self.mode == .failure) return .{ .failure = .{ .kind = .output_limit, .message = "synthetic", .usage = usage, .http_status = 429 } };
        if (self.mode == .tool) return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{} }, .finish = .tool_calls, .usage = usage } };
        const body = if (self.mode == .partial) "{\"items\":[" else "{\"items\":[]}";
        var msg = try p.textMessage(a, .assistant, body);
        if (self.mode == .reasoning) msg.blocks = try a.dupe(p.Block, &.{ .{ .reasoning = "Do not save this thought" }, .{ .text = body } });
        if (self.mode == .oversized) {
            const text = try a.alloc(u8, codec.max_output_bytes + 1);
            @memset(text, ' ');
            msg = try p.textMessage(a, .assistant, text);
        }
        return .{ .success = .{ .message = msg, .usage = if (self.mode == .partial_usage) .{ .output_tokens = 4 } else usage, .finish = .stop } };
    }
};
fn testConfig() cfg.Config {
    return .{ .provider = .{ .base_url = "http://primary.invalid/v1", .api_key_env = "SYNTHETIC_MEMORY_KEY" }, .selected_provider = "primary", .model = .{ .name = "primary/model", .protocol = .chat, .context_tokens = 32768, .output_tokens = 8192, .input_price_flat_limit = 32768 }, .limits = .{ .request_timeout_ms = 1234 } };
}
fn creationCase(a: std.mem.Allocator) !void {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("SYNTHETIC_MEMORY_KEY", "own-key");
    const client = try Client.create(a, std.testing.io, testConfig(), &env);
    defer client.deinit();
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    try std.testing.expect(client.last_usage.input_tokens == null);
    try std.testing.expectEqualStrings("own-key", client.key.?);
    try env.put("SYNTHETIC_MEMORY_KEY", "replaced");
    try std.testing.expectEqualStrings("Bearer own-key", client.transport.?.authorization);
    try std.testing.expectEqual(testConfig().model.output_tokens, client.source.value.model.output_tokens);
    try std.testing.expectEqual(testConfig().limits.max_response_bytes, client.source.value.limits.max_response_bytes);
    try std.testing.expectEqual(testConfig().limits.max_event_bytes, client.source.value.limits.max_event_bytes);
}
test "memory client frozen wire limits are independent of decoded JSON and preserve smaller policy" {
    const a = std.testing.allocator;
    var config = testConfig();
    config.limits.max_response_bytes = 48 * 1024;
    config.limits.max_event_bytes = 24 * 1024;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("SYNTHETIC_MEMORY_KEY", "own-key");
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    try std.testing.expectEqual(config.limits.max_response_bytes, client.source.value.limits.max_response_bytes);
    try std.testing.expectEqual(config.limits.max_event_bytes, client.source.value.limits.max_event_bytes);
    try std.testing.expectEqual(config.limits.max_response_bytes, client.transport.?.config.limits.max_response_bytes);
    try std.testing.expectEqual(config.limits.max_event_bytes, client.transport.?.config.limits.max_event_bytes);
    try std.testing.expectEqual(config.model.output_tokens, client.source.value.model.output_tokens);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}
test "memory client zero startup owns frozen config key and independent route OOM" {
    try creationCase(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, creationCase, .{});
}
test "memory client unrequested proxy transport closes cleanly without a child" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("SYNTHETIC_MEMORY_KEY", "own-key");
    var config = testConfig();
    const models = [_][]const u8{"primary/primary/model"};
    config.proxy = .{ .address = "proxy.invalid", .port = 8888, .models = &models };
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    try std.testing.expect(client.transport != null);
    const proxy = if (client.transport) |*transport| if (transport.proxy_http) |*value| value else return error.TestUnexpectedResult else return error.TestUnexpectedResult;
    try std.testing.expect(proxy.unreaped_pid == null and !proxy.poisoned);
}
test "memory client fake normal request preserves usage cancellation no tools no partial batch" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const client = try Client.create(a, std.testing.io, testConfig(), &env);
    defer client.deinit();
    try std.testing.expect(client.key == null and client.transport == null);
    var fake: Fake = .{ .client = client };
    client.model_override = .{ .context = &fake, .call_fn = Fake.invoke };
    var cancel: p.Cancellation = .{};
    const items = try client.service().extract(a, fixture, &cancel);
    defer codec.freeCandidates(a, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
    try std.testing.expectEqual(@as(?u64, 17), client.last_usage.input_tokens);
    fake.mode = .failure;
    try std.testing.expectError(error.MemoryUnavailable, client.service().extract(a, fixture, &cancel));
    try std.testing.expectEqual(@as(?u16, 429), client.last_http_status);
    try std.testing.expectEqual(@as(?u64, 3), client.last_usage.output_tokens);
    for ([_]@TypeOf(fake.mode){ .tool, .partial, .oversized }) |mode| {
        fake.mode = mode;
        try std.testing.expectError(error.InvalidMemoryOutput, client.service().extract(a, fixture, &cancel));
    }
    fake.mode = .reasoning;
    const empty = try client.service().extract(a, fixture, &cancel);
    defer codec.freeCandidates(a, empty);
    fake.mode = .thrown;
    try std.testing.expectError(error.CleanupFailed, client.service().extract(a, fixture, &cancel));
    try std.testing.expectEqual(@as(?u64, 17), client.last_usage.input_tokens);
    fake.mode = .partial_usage;
    const partial_usage = try client.service().extract(a, fixture, &cancel);
    defer codec.freeCandidates(a, partial_usage);
    try std.testing.expectEqual(@as(?u64, 17), client.last_usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), client.last_usage.output_tokens);
    fake.mode = .canceled_cleanup;
    try std.testing.expectError(error.CleanupFailed, client.service().extract(a, fixture, &cancel));
    cancel = .{};
    fake.mode = .cancel;
    try std.testing.expectError(error.Canceled, client.service().extract(a, fixture, &cancel));
    try std.testing.expectEqual(@as(?u64, 17), client.last_usage.input_tokens);
    const prior = client.calls;
    try std.testing.expectError(error.Canceled, client.service().extract(a, fixture, &cancel));
    try std.testing.expectEqual(prior, client.calls);
}
test "memory client rejects unknown or zero Anthropic capacity before counting calls" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for ([_]?u32{ null, 0, 8192 }) |capacity| {
        const client = try Client.create(a, std.testing.io, testConfig(), &env);
        defer client.deinit();
        client.source.value.model.protocol = .anthropic;
        client.source.value.model.output_tokens = capacity;
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
                return .{ .success = .{ .message = try p.textMessage(alloc, .assistant, "{\"items\":[]}"), .finish = .stop, .usage = .{ .input_tokens = 7, .output_tokens = 1 } } };
            }
        };
        var fake: FakeCapacity = .{};
        client.model_override = .{ .context = &fake, .call_fn = FakeCapacity.invoke };
        var cancel: p.Cancellation = .{};
        const outcome = client.service().extract(a, fixture, &cancel);
        if (capacity == null or capacity.? == 0) {
            try std.testing.expectError(if (capacity == null) error.UnknownModelOutputCapacity else error.InvalidModelOutputCapacity, outcome);
            try std.testing.expectEqual(@as(usize, 0), fake.calls);
            try std.testing.expectEqual(@as(u64, 0), client.calls);
            try std.testing.expect(client.last_usage.input_tokens == null and client.last_http_status == null);
        } else {
            const items = try outcome;
            defer codec.freeCandidates(a, items);
            try std.testing.expectEqual(@as(usize, 0), items.len);
            try std.testing.expectEqual(@as(usize, 1), fake.calls);
            try std.testing.expectEqual(@as(u64, 1), client.calls);
            try std.testing.expectEqual(@as(?u64, 7), client.last_usage.input_tokens);
        }
    }
}

test "memory client refuses unresolved native absent credentials and input policy before calls" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const client = try Client.create(a, std.testing.io, testConfig(), &env);
    defer client.deinit();
    var cancel: p.Cancellation = .{};
    try std.testing.expectError(error.MemoryUnavailable, client.service().extract(a, fixture, &cancel));
    client.source.value.model.protocol = .auto;
    try std.testing.expectError(error.UnknownModelProtocol, client.service().extract(a, fixture, &cancel));
    client.source.value.model.protocol = .systemone;
    try std.testing.expectError(error.UnsupportedProtocol, client.service().extract(a, fixture, &cancel));
    client.source.value.model.protocol = .chat;
    var fake: Fake = .{ .client = client };
    client.model_override = .{ .context = &fake, .call_fn = Fake.invoke };
    client.source.value.model.input_price_flat_limit = null;
    try std.testing.expectError(error.UnknownInputPriceThreshold, client.service().extract(a, fixture, &cancel));
    client.source.value.model.input_price_flat_limit = 1;
    try std.testing.expectError(error.InputBudgetExceeded, client.service().extract(a, fixture, &cancel));
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}

test "memory client complete request exact input boundary without output clamp" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const client = try Client.create(a, std.testing.io, testConfig(), &env);
    defer client.deinit();
    var fake: Fake = .{ .client = client };
    client.model_override = .{ .context = &fake, .call_fn = Fake.invoke };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = try codec.encode(arena.allocator(), fixture);
    const messages = [_]p.Message{try p.textMessage(arena.allocator(), .user, body)};
    const estimated: u32 = @intCast(context.rawTokens(codec.instruction, &.{}, &messages));
    client.source.value.limits.max_input_tokens = estimated + client.source.value.limits.input_margin_tokens;
    client.source.value.model.context_tokens = estimated + client.source.value.limits.safety_tokens + 1;
    var cancel: p.Cancellation = .{};
    const empty = try client.service().extract(a, fixture, &cancel);
    defer codec.freeCandidates(a, empty);
    try context.checkInput(client.source.value, estimated);
    try std.testing.expectEqual(testConfig().model.output_tokens, client.source.value.model.output_tokens);
    client.source.value.limits.max_input_tokens.? -= 1;
    try std.testing.expectError(error.InputBudgetExceeded, client.service().extract(a, fixture, &cancel));
    try std.testing.expectEqual(@as(u64, 1), client.calls);
}

// Exercise real wire decoders via a model seam: no sockets, env files or APIs.
const WireFake = struct {
    body_override: ?[]const u8 = null,
    reject: bool = false,
    truncated: bool = false,
    calls: usize = 0,
    fn invoke(raw: *anyopaque, a: std.mem.Allocator, req: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try std.testing.expectEqual(@as(usize, 0), req.tools.len);
        try std.testing.expectEqual(testConfig().model.output_tokens, req.model_output_tokens);
        const body = self.body_override orelse "{\"items\":[{\"category\":\"preferences\",\"topic\":\"language\",\"content\":\"Prefer Zig.\",\"source_id\":0,\"quote\":\"Prefer Zig.\"}]}";
        const quoted = try std.json.Stringify.valueAlloc(a, body, .{});
        switch (req.scope.protocol) {
            .chat => {
                var stream = @import("../llm/chat.zig").Stream.init(a, req.scope, sink);
                try stream.feed("", try std.fmt.allocPrint(a, "{{\"choices\":[{{\"index\":0,\"delta\":{{\"{s}\":{s}}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":13,\"completion_tokens\":4}}}}", .{ if (self.reject) "refusal" else "content", quoted }));
                if (!self.truncated) try stream.feed("", "[DONE]");
                return stream.finish();
            },
            .responses => {
                var stream = @import("../llm/responses.zig").Stream.init(a, req.scope, sink);
                if (!self.truncated) try stream.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"response.completed\",\"response\":{{\"status\":\"completed\",\"output\":[{{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"{s}\",\"{s}\":{s}}}]}}],\"usage\":{{\"input_tokens\":13,\"output_tokens\":4}}}}}}", .{ if (self.reject) "refusal" else "output_text", if (self.reject) "refusal" else "text", quoted }));
                return stream.finish();
            },
            .anthropic => {
                var stream = @import("../llm/anthropic.zig").Stream.init(a, req.scope, sink);
                try stream.feed("message_start", "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":13,\"output_tokens\":0}}}");
                try stream.feed("content_block_start", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}");
                // Even a syntactically/evidentially valid JSON body is not a
                // candidate batch when the actual stop reason was refusal.
                try stream.feed("content_block_delta", try std.fmt.allocPrint(a, "{{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}", .{quoted}));
                try stream.feed("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}");
                try stream.feed("message_delta", try std.fmt.allocPrint(a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":4}}}}", .{if (self.reject) "refusal" else "end_turn"}));
                if (!self.truncated) try stream.feed("message_stop", "{\"type\":\"message_stop\"}");
                return stream.finish();
            },
            else => unreachable,
        }
    }
};
const cas_version = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const cas_body = "{\"items\":[{\"category\":\"preferences\",\"topic\":\"editor\",\"content\":\"Prefer Zig.\",\"source_id\":0,\"quote\":\"Prefer Zig.\"},{\"category\":\"preferences\",\"topic\":\"language\",\"content\":\"Prefer Zig.\",\"source_id\":0,\"quote\":\"Prefer Zig.\",\"expected_version\":\"" ++ cas_version ++ "\"}]}";
fn casClientCase(out: std.mem.Allocator, protocol: p.Protocol) !void {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = testConfig();
    config.model.protocol = protocol;
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    var fake: WireFake = .{ .body_override = cas_body };
    client.model_override = .{ .context = &fake, .call_fn = WireFake.invoke };
    var cancel: p.Cancellation = .{};
    var material = fixture;
    const related: knowledge.Related = .{ .category = .preferences, .topic = "language", .content = "Old", .version = cas_version };
    material.related = &.{related};
    // Both scratch validation and final owned parse must succeed before return.
    const items = try client.service().extract(out, material, &cancel);
    defer codec.freeCandidates(out, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings(cas_version, items[1].expected_version.?);
    try std.testing.expectEqual(@as(?u64, 13), client.last_usage.input_tokens);
    for (0..4) |case| {
        var r = related;
        switch (case) {
            0 => {},
            1 => r.category = .project,
            2 => r.topic = "other",
            3 => r.version = "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            else => unreachable,
        }
        material.related = if (case == 0) &.{} else &.{r};
        // A fully valid create precedes the unauthorized update. No prefix is
        // returned from either parse or the Service's second validation.
        const result = client.service().extract(out, material, &cancel);
        if (result) |partial| {
            codec.freeCandidates(out, partial);
            return error.TestUnexpectedResult;
        } else |err| {
            if (err == error.OutOfMemory) return err;
            try std.testing.expectEqual(error.InvalidMemoryVersion, err);
        }
    }
    try std.testing.expectEqual(@as(usize, 5), fake.calls);
}
test "memory client decoder CAS authorized update unauthorized whole batch and double parse OOM" {
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        try casClientCase(std.testing.allocator, protocol);
        // Includes allocation failures in final parse after scratch validation;
        // testing allocator checks rollback, never a partial returned batch.
        try std.testing.checkAllAllocationFailures(std.testing.allocator, casClientCase, .{protocol});
    }
}

test "memory client binds only primary confirmed auto protocol without startup requests" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("SYNTHETIC_MEMORY_KEY", "owned-auto-key");
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        var primary = testConfig();
        primary.model.protocol = .auto;
        const client = try Client.create(a, std.testing.io, primary, &env);
        defer client.deinit();
        try std.testing.expect(client.transport != null);
        try std.testing.expectEqualStrings("Bearer owned-auto-key", client.transport.?.authorization);
        try std.testing.expect(client.transport.?.config == &client.source.value);
        var fake: WireFake = .{};
        client.model_override = .{ .context = &fake, .call_fn = WireFake.invoke };
        var cancel: p.Cancellation = .{};
        try std.testing.expectError(error.UnknownModelProtocol, client.service().extract(a, fixture, &cancel));
        try std.testing.expectError(error.UnsupportedProtocol, client.bindProtocol(.auto));
        try std.testing.expectError(error.UnsupportedProtocol, client.bindProtocol(.systemone));
        try client.bindProtocol(protocol);
        try client.bindProtocol(protocol);
        try std.testing.expectEqual(@as(u64, 0), client.calls);
        try std.testing.expectEqual(@as(usize, 0), fake.calls);
        try std.testing.expectEqual(p.Protocol.auto, primary.model.protocol);
        try std.testing.expectEqual(protocol, client.transport.?.config.model.protocol);
        const different: p.Protocol = if (protocol == .chat) .responses else .chat;
        try std.testing.expectError(error.ProtocolBindingMismatch, client.bindProtocol(different));
        try std.testing.expectEqual(protocol, client.source.value.model.protocol);
        const items = try client.service().extract(a, fixture, &cancel);
        defer codec.freeCandidates(a, items);
        try std.testing.expectEqual(@as(usize, 1), items.len);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expectEqual(@as(u64, 1), client.calls);
    }
    const explicit = try Client.create(a, std.testing.io, testConfig(), &env);
    defer explicit.deinit();
    try explicit.bindProtocol(.chat);
    try std.testing.expectError(error.ProtocolBindingMismatch, explicit.bindProtocol(.responses));
    try std.testing.expectEqual(@as(u64, 0), explicit.calls);
}
test "memory client auto binding absent credentials pending selection remain lazy" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = testConfig();
    config.model.protocol = .auto;
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    try client.bindProtocol(.anthropic);
    try std.testing.expect(client.key == null and client.transport == null);
    var cancel: p.Cancellation = .{};
    try std.testing.expectError(error.MemoryUnavailable, client.service().extract(a, fixture, &cancel));
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    config.provider.base_url = "";
    config.selection_pending = true;
    const pending = try Client.create(a, std.testing.io, config, &env);
    defer pending.deinit();
    try std.testing.expectError(error.UnknownModelProtocol, pending.bindProtocol(.chat));
    try std.testing.expectError(error.UnknownModelProtocol, pending.service().extract(a, fixture, &cancel));
}
test "memory client rejects Anthropic explicit refusal even with valid evidence JSON" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = testConfig();
    config.model.protocol = .anthropic;
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    var fake: WireFake = .{ .reject = true };
    client.model_override = .{ .context = &fake, .call_fn = WireFake.invoke };
    var cancel: p.Cancellation = .{};
    // The exact same JSON is accepted when the stop reason is end_turn.
    try std.testing.expectError(error.InvalidMemoryOutput, client.service().extract(a, fixture, &cancel));
    try std.testing.expectEqual(@as(?u64, 13), client.last_usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), client.last_usage.output_tokens);
    fake.reject = false;
    const items = try client.service().extract(a, fixture, &cancel);
    defer codec.freeCandidates(a, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(u64, 2), client.calls);
}
test "memory client actual Chat Responses Anthropic decoders valid refused truncated independent usage" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        var config = testConfig();
        config.model.protocol = protocol;
        const client = try Client.create(a, std.testing.io, config, &env);
        defer client.deinit();
        var fake: WireFake = .{};
        client.model_override = .{ .context = &fake, .call_fn = WireFake.invoke };
        var cancel: p.Cancellation = .{};
        const items = try client.service().extract(a, fixture, &cancel);
        defer codec.freeCandidates(a, items);
        try std.testing.expectEqual(@as(usize, 1), items.len);
        try std.testing.expectEqualStrings("Prefer Zig.", items[0].content);
        try std.testing.expectEqual(@as(?u64, 13), client.last_usage.input_tokens);
        try std.testing.expectEqual(@as(?u64, 4), client.last_usage.output_tokens);
        fake.reject = true;
        try std.testing.expectError(error.InvalidMemoryOutput, client.service().extract(a, fixture, &cancel));
        fake.reject = false;
        fake.truncated = true;
        try std.testing.expectError(error.MemoryUnavailable, client.service().extract(a, fixture, &cancel));
        try std.testing.expectEqual(@as(usize, 3), fake.calls);
        try std.testing.expectEqual(@as(u64, 3), client.calls);
    }
}
