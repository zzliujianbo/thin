//! Isolated generative memory extractor. Never touches Runtime/history/accounts,
//! metadata resolution or Decision/Image selection. Construction does no network.
const std = @import("std");
const diag = @import("../core/diagnostics.zig");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const knowledge = @import("../core/knowledge.zig");
const codec = @import("../core/knowledge_codec.zig");
const context = @import("../core/context.zig");
const thinking = @import("../core/thinking.zig");
const http = @import("../llm/http.zig");
const CredentialSource = @import("../core/codex_auth.zig").CredentialSource;
const common = @import("../llm/common.zig");

pub const Client = struct {
    backing: std.mem.Allocator,
    wiping: cfg.WipingAllocator,
    io: std.Io,
    source: std.json.Parsed(cfg.Config),
    key: ?[]u8 = null,
    transport: ?http.Client = null,
    model_override: ?p.Model = null,
    diagnostics: diag.Sink = .{},
    calls: u64 = 0,
    last_usage: p.Usage = .{},
    last_http_status: ?u16 = null,

    /// config is the actual frozen primary selection (not a declaration to resolve).
    /// Absent credentials/unsupported protocol are lazy extraction failures only.
    pub fn create(a: std.mem.Allocator, io: std.Io, config: cfg.Config, env: *const std.process.Environ.Map) !*Client {
        return createWithCodexSource(a, io, config, env, null);
    }

    pub fn createWithCodexSource(a: std.mem.Allocator, io: std.Io, config: cfg.Config, env: *const std.process.Environ.Map, source: ?CredentialSource) !*Client {
        const self = try a.create(Client);
        self.* = .{ .backing = a, .wiping = .{ .backing = a }, .io = io, .source = undefined };
        const owned = self.wiping.allocator();
        errdefer {
            var wipe: cfg.WipingAllocator = .{ .backing = a };
            wipe.allocator().destroy(self);
        }
        self.source = if (config.selection_pending) try cfg.clonePendingSettings(owned, config) else try cfg.clone(owned, config);
        errdefer cfg.release(&self.source);
        // Retain validated wire/event limits without a separate helper output cap.
        const frozen = &self.source.value;
        const codex = frozen.provider.kind == .openai_codex and std.mem.eql(u8, frozen.provider.base_url, cfg.providers.Id.openai_codex.baseUrl());
        self.key = if (codex) null else cfg.resolveApiKey(owned, frozen.*, env) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        errdefer if (self.key) |key| owned.free(key);
        // initWithEnv snapshots only HTTP/proxy necessities and performs no I/O.
        // An auto route may own a transport now, but cannot call until bound to
        // the primary Runtime's actually confirmed protocol on the helper worker.
        if (!frozen.selection_pending and frozen.model.protocol != .systemone) {
            if (codex) {
                if (source) |credential_source| self.transport = http.Client.initCodexWithEnv(owned, io, frozen, credential_source, env) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => null,
                };
            } else if (self.key) |key| self.transport = http.Client.initWithEnv(owned, io, frozen, key, env) catch |err| switch (err) {
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
        var request: p.Request = .{
            .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = config.model.protocol },
            .codec = try cfg.wireCodec(config, config.model.protocol),
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
        // Validate and reuse the exact frozen wire before counting an inference attempt.
        const wire_payload = try @import("../core/checkpoint.zig").validateRequestHistoryWire(a, request);
        request.wire = wire_payload;
        defer a.free(wire_payload);
        try self.check(cancel);
        var hash = std.hash.Wyhash.init(0);
        hash.update(config.model.name);
        hash.update(@tagName(config.model.protocol));
        var span = diag.Span.start(self.diagnostics, self.io, .{ .stage = .memory_request, .protocol = config.model.protocol, .timeout_ms = config.limits.request_timeout_ms, .route_hash = hash.final(), .count = 1 });
        defer span.finish(.ok);
        return self.extractAttempt(a, out, cancel, model, request, &span) catch |err| {
            span.fail(err);
            return err;
        };
    }

    fn extractAttempt(self: *Client, a: std.mem.Allocator, out: std.mem.Allocator, cancel: *const p.Cancellation, model: p.Model, request: p.Request, span: *diag.Span) ![]const knowledge.Candidate {
        self.calls +|= 1;
        // Streamed usage survives even a thrown cancellation/cleanup failure.
        var sink: UsageSink = .{ .client = self, .cancel = cancel };
        const outcome = model.call(a, request, .{ .context = &sink, .emit_fn = UsageSink.emit }) catch |err| {
            // Record the original local error before preserving public normalization.
            span.fail(err);
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
                span.record.http_status = failure.http_status;
                span.record.model_failure = failure.kind;
                self.check(cancel) catch |err| {
                    span.fail(err);
                    return err;
                };
                const err: anyerror = if (failure.kind == .canceled) error.Canceled else error.MemoryUnavailable;
                span.fail(err);
                return err;
            },
            .success => |success| success,
        };
        common.mergeUsage(&self.last_usage, response.usage);
        try self.check(cancel);
        if (response.refused or response.unsupported_output or response.finish != .stop or response.message.role != .assistant) return error.InvalidMemoryOutput;
        var text: std.ArrayList(u8) = .empty;
        for (response.message.blocks) |block| switch (block) {
            .text => |part| {
                try text.appendSlice(a, part);
            },
            .reasoning => {}, // Explicit metadata only; never extraction evidence.
            else => return error.InvalidMemoryOutput,
        };
        const result = try codec.parse(out, text.items);
        errdefer codec.freeCandidates(out, result);
        try self.check(cancel);
        return result;
    }
};
const UsageSink = struct {
    client: *Client,
    cancel: *const p.Cancellation,
    fn emit(raw: ?*anyopaque, event: p.ModelEvent) !void {
        const self: *UsageSink = @ptrCast(@alignCast(raw.?));
        if (event == .usage) common.mergeUsage(&self.client.last_usage, event.usage);
        try self.client.check(self.cancel);
        switch (event) {
            .tool_delta => return error.InvalidMemoryOutput,
            else => {},
        }
    }
};

// Exercise real wire decoders via a model seam: no sockets, env files or APIs.
