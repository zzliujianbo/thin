//! OpenAI 兼容 HTTP 客户端：发送 Chat Completions / Responses 请求，以 SSE 流式读取结果，
//! 并把 HTTP 错误、超时、取消统一映射为 p.Outcome。
const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const codex_auth = @import("../core/codex_auth.zig");
const codex_base = "https://chatgpt.com/backend-api/codex";
const sse = @import("sse.zig");
const j = @import("../util/json.zig");
const chat = @import("chat.zig");
const responses = @import("responses.zig");
const anthropic = @import("anthropic.zig");
const common = @import("common.zig");
const pool = @import("http_pool.zig");
const curl = @import("decision_http.zig");
const Io = std.Io;
const uncanceled: p.Cancellation = .{};

/// 模型客户端：持有 API 密钥的 Authorization 头副本与底层 std.http.Client。
/// 同一个 Client 的请求在 worker 中串行化（锁等待也可取消/计入预算）；
/// sink 不得重入同一 Client。deinit 仍须等所有调用及 worker 结束。
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// 只读引用，调用方需保证其存活时间长于 Client。
    config: *const cfg.Config,
    /// 独立拷贝的 "Bearer <key>"，deinit 时清零后释放，避免密钥残留。
    authorization: []u8,
    codex_source: ?codex_auth.CredentialSource = null,
    /// 底层 HTTP 客户端，内部连接池随 Client 生命周期存在。
    http: std.http.Client,
    /// Set once cleanupForClose has drained the native pool, so a retained
    /// owner can retry only the unreaped proxy transport.
    http_drained: bool = false,
    /// Guards request ownership and the timestamp, not merely pool traversal.
    request_mutex: Io.Mutex = .init,
    last_request_finish: ?Io.Timestamp = null,
    /// Only explicitly listed identities use curl's verified CONNECT + target
    /// TLS. Direct requests retain the native pool and never read proxy env.
    proxy_http: ?curl.Client = null,
    /// OpenCode routing identity, stable across requests. The application can
    /// replace the local headless fallback with its immutable session ID.
    session_id: ?[32]u8 = null,

    /// 创建客户端并校验密钥。密钥需非空、长度不超过 16KB，且不含控制字符（防止 HTTP 头注入）。
    pub fn init(allocator: std.mem.Allocator, io: Io, config: *const cfg.Config, key: []const u8) !Client {
        var empty = std.process.Environ.Map.init(allocator);
        defer empty.deinit();
        return initWithEnv(allocator, io, config, key, &empty);
    }

    pub fn initWithEnv(allocator: std.mem.Allocator, io: Io, config: *const cfg.Config, key: []const u8, env: *const std.process.Environ.Map) !Client {
        if (config.model.protocol == .systemone or cfg.providers.Id.fromSystemOneUrl(config.provider.base_url) != null) return error.UnsupportedProtocol;
        if (isCodexConfig(config) or std.mem.eql(u8, config.provider.base_url, codex_base)) return error.UnsupportedProtocol;
        // 控制字符会破坏 HTTP 头格式，因此在这里拒绝。
        if (key.len == 0 or key.len > 16384) return error.InvalidApiKey;
        for (key) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidApiKey;
        const kind = config.provider.kind orelse cfg.providers.Id.fromUrl(config.provider.base_url);
        const session_id: ?[32]u8 = if (kind != null and kind.?.usesSessionHeader()) blk: {
            var random: [16]u8 = undefined;
            try io.randomSecure(&random);
            break :blk std.fmt.bytesToHex(random, .lower);
        } else null;
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        errdefer {
            std.crypto.secureZero(u8, authorization);
            allocator.free(authorization);
        }
        const proxy_http: ?curl.Client = if (config.proxyFor(config.selected_provider, config.model.name)) |route| blk: {
            const url = try route.url(allocator);
            defer allocator.free(url);
            break :blk try curl.Client.initRouted(allocator, io, env, url);
        } else null;
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .authorization = authorization,
            .proxy_http = proxy_http,
            .http = .{ .allocator = allocator, .io = io },
            .session_id = session_id,
        };
    }

    pub fn initCodexWithEnv(allocator: std.mem.Allocator, io: Io, config: *const cfg.Config, source: codex_auth.CredentialSource, env: *const std.process.Environ.Map) !Client {
        if (!isCodexConfig(config) or !std.mem.eql(u8, config.provider.base_url, codex_base) or config.model.protocol != .responses) return error.UnsupportedProtocol;
        if (source.acquire_fn == null) return error.MissingCredentialSource;
        const authorization = try allocator.alloc(u8, 0);
        errdefer allocator.free(authorization);
        const proxy_http: ?curl.Client = if (config.proxyFor(config.selected_provider, config.model.name)) |route| blk: {
            const url = try route.url(allocator);
            defer allocator.free(url);
            break :blk try curl.Client.initRouted(allocator, io, env, url);
        } else null;
        return .{ .allocator = allocator, .io = io, .config = config, .authorization = authorization, .codex_source = source, .proxy_http = proxy_http, .http = .{ .allocator = allocator, .io = io } };
    }

    /// Independent mutable client for one child Runtime. The frozen parent
    /// authorization, CA/route transport and session identity are copied; the
    /// key is never re-resolved from a filtered command environment.
    pub fn cloneForConfig(self: *const Client, allocator: std.mem.Allocator, io: Io, config: *const cfg.Config) !Client {
        if (config.model.protocol == .systemone or cfg.providers.Id.fromSystemOneUrl(config.provider.base_url) != null)
            return error.UnsupportedProtocol;
        if (self.codex_source != null) {
            if (!isCodexConfig(config) or !std.mem.eql(u8, config.provider.base_url, codex_base) or config.model.protocol != .responses) return error.UnsupportedProtocol;
        } else {
            if (isCodexConfig(config) or std.mem.eql(u8, config.provider.base_url, codex_base)) return error.UnsupportedProtocol;
            if (!std.mem.startsWith(u8, self.authorization, "Bearer ") or self.authorization.len == "Bearer ".len) return error.InvalidApiKey;
        }
        // The child config must resolve to the same explicit proxy route that
        // this client already froze; never silently switch direct <-> proxied.
        const expected = if (config.proxyFor(config.selected_provider, config.model.name)) |route| try route.url(allocator) else null;
        defer if (expected) |url| allocator.free(url);
        if (expected == null) {
            if (self.proxy_http != null) return error.ProxyRouteChanged;
        } else {
            const transport = if (self.proxy_http) |*value| value else return error.ProxyRouteChanged;
            if (transport.poisoned) return error.CleanupFailed;
            const actual = transport.proxy_url orelse return error.ProxyRouteChanged;
            if (!std.mem.eql(u8, expected.?, actual)) return error.ProxyRouteChanged;
        }
        const authorization = try allocator.dupe(u8, self.authorization);
        errdefer {
            std.crypto.secureZero(u8, authorization);
            allocator.free(authorization);
        }
        const proxy_http: ?curl.Client = if (self.proxy_http) |*transport|
            try curl.Client.initRouted(allocator, io, &transport.env, transport.proxy_url)
        else
            null;
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .authorization = authorization,
            .codex_source = self.codex_source,
            .proxy_http = proxy_http,
            .http = .{ .allocator = allocator, .io = io },
            .session_id = self.session_id,
        };
    }

    /// Narrow idempotent close for a retained child owner. Drains the native
    /// pool once, then attempts the owned proxy transport and refuses to free
    /// the key while that transport still reports an unreaped child. On error
    /// the caller must retain this value and retry; nothing here is lost.
    pub fn cleanupForClose(self: *Client) error{CleanupFailed}!void {
        if (!self.http_drained) {
            self.http.deinit();
            self.http_drained = true;
        }
        if (self.proxy_http) |*transport| {
            transport.deinit();
            if (transport.unreaped_pid != null) return error.CleanupFailed;
        }
        if (self.authorization.len != 0) {
            std.crypto.secureZero(u8, self.authorization);
            self.allocator.free(self.authorization);
            self.authorization = &.{};
        }
    }

    /// 释放连接池与密钥副本。
    pub fn deinit(self: *Client) void {
        self.http.deinit();
        if (self.proxy_http) |*transport| transport.deinit();
        // 先清零再释放，减少密钥在堆内存中残留的时间。
        std.crypto.secureZero(u8, self.authorization);
        self.allocator.free(self.authorization);
    }

    fn requestHeaders(self: *Client, protocol: p.Protocol, credential: ?*const codex_auth.RequestCredential, buffer: *[8]std.http.Header) ![]const std.http.Header {
        buffer[0] = .{ .name = "accept", .value = "text/event-stream" };
        var count: usize = 1;
        if (credential) |auth| {
            buffer[count] = .{ .name = "chatgpt-account-id", .value = auth.account_id };
            buffer[count + 1] = .{ .name = "originator", .value = "thin" };
            buffer[count + 2] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
            count += 3;
            if (self.session_id) |*id| {
                for (id) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidSessionIdentity;
                buffer[count] = .{ .name = "session-id", .value = id };
                buffer[count + 1] = .{ .name = "x-client-request-id", .value = id };
                count += 2;
            }
            return buffer[0..count];
        }
        const kind = self.config.provider.kind orelse cfg.providers.Id.fromUrl(self.config.provider.base_url);
        if (kind != null and kind.?.usesSessionHeader()) {
            const id = if (self.session_id) |*id| id else return error.MissingSessionIdentity;
            for (id) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidSessionIdentity;
            buffer[1] = .{ .name = "x-opencode-session", .value = id };
            count += 1;
        }
        if (protocol == .anthropic) {
            // Reuse the owned, securely wiped key buffer without another copy.
            buffer[count] = .{ .name = "x-api-key", .value = self.authorization["Bearer ".len..] };
            buffer[count + 1] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            count += 2;
        }
        return buffer[0..count];
    }

    /// 返回通用的 p.Model 接口，上层通过 call_fn 调用而不依赖具体实现。
    pub fn model(self: *Client) p.Model {
        return .{ .context = self, .call_fn = invoke };
    }

    /// 执行一次模型请求。在独立的 I/O worker 中完成网络操作，主协程负责轮询取消与超时。
    fn invoke(context: *anyopaque, allocator: std.mem.Allocator, request: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *Client = @ptrCast(@alignCast(context));
        if (request.scope.protocol == .systemone or self.config.model.protocol == .systemone or
            cfg.providers.Id.fromSystemOneUrl(self.config.provider.base_url) != null)
            return failure(.unsupported_protocol, "SystemOne does not support chat generation", null, false);
        // auto 只能是配置层的占位值，进入 HTTP 层前必须已解析为具体协议。
        if (request.scope.protocol == .auto) return error.UnselectedProtocol;
        // 回放作用域必须与当前连接、模型一致，避免把历史 replay 发送到其他端点。
        if (!std.mem.eql(u8, request.scope.connection, self.config.provider.base_url) or
            !std.mem.eql(u8, request.scope.model, self.config.model.name)) return error.ReplayScopeMismatch;
        try self.checkProxyCleanup();
        try self.checkProxyRoute();
        // 开始传输前已取消则直接返回，不启动 worker。
        if (request.cancellation) |cancel| if (cancel.isRequested())
            return failure(.canceled, "Model request canceled before transport", null, false);

        // job 与 worker 共享，必须保证 worker 结束后才能让 job 失效。
        const start = Io.Clock.awake.now(self.io);
        var job = Job{ .client = self, .allocator = allocator, .request = request, .sink = sink, .start = start };
        // 网络 I/O 放入并发任务执行，避免阻塞取消与超时检查。
        var future = try Io.concurrent(self.io, perform, .{&job});
        // 无论从哪个分支返回，都要取消并 join worker，保证 job 与 arena 不会被提前释放。
        defer _ = future.cancel(self.io) catch {};

        // 每 5ms 轮询一次 worker 完成标志，同时检查取消与请求超时。
        while (!job.done.load(.acquire)) {
            if (request.cancellation) |cancel| {
                if (cancel.isRequested()) {
                    _ = future.cancel(self.io) catch {};
                    try self.checkProxyCleanup();
                    var outcome = failure(.canceled, "Model request canceled", null, job.observed.load(.acquire));
                    outcome.failure.usage = job.last_usage;
                    return outcome;
                }
            }
            if (start.untilNow(self.io, .awake).toMilliseconds() >= self.config.limits.request_timeout_ms) {
                _ = future.cancel(self.io) catch {};
                try self.checkProxyCleanup();
                var outcome = failure(.timeout, "Model request exceeded its time limit", null, job.observed.load(.acquire));
                outcome.failure.usage = job.last_usage;
                return outcome;
            }
            // Cancellable waiting: parent cancellation cancels and joins the I/O
            // worker before its result arena or request data may be released.
            Io.sleep(self.io, .fromMilliseconds(5), .awake) catch |err| {
                _ = future.cancel(self.io) catch {};
                try self.checkProxyCleanup();
                if (err != error.Canceled) return err;
                var outcome = failure(.canceled, "Model request canceled", null, job.observed.load(.acquire));
                outcome.failure.usage = job.last_usage;
                return outcome;
            };
        }

        // worker 已结束，取回结果；OOM 原样上抛，取消与其他错误转换为对应的失败类型。
        var outcome = future.await(self.io) catch |err| switch (err) {
            error.OutOfMemory, error.CleanupFailed => return err,
            error.Canceled => failure(.canceled, "Model request canceled", null, job.observed.load(.acquire)),
            error.RequestTimeout => failure(.timeout, "Model request exceeded its time limit", null, job.observed.load(.acquire)),
            else => failure(.transport, "Model transport failed", null, job.observed.load(.acquire)),
        };

        // 失败时仍合并 worker 观察到的最新 usage，保证已消耗的 token 可以被统计。
        if (outcome == .failure) {
            common.mergeUsage(&outcome.failure.usage, job.last_usage);
        }
        return job.complete(outcome);
    }

    /// 一次请求在 I/O worker 与主协程之间共享的状态。
    const Job = struct {
        client: *Client,
        allocator: std.mem.Allocator,
        request: p.Request,
        sink: p.ModelSink,
        start: Io.Timestamp,

        /// worker 结束标志，由 perform 返回前设置，主协程据此停止轮询。
        done: std.atomic.Value(bool) = .init(false),
        /// 是否已向调用方发出过内容事件，用于失败结果判断是否产生过可见输出。
        observed: std.atomic.Value(bool) = .init(false),

        // Written by the I/O worker; read only after joining/canceling it.
        last_usage: p.Usage = .{},

        // One budget, including mutex wait, encoding, connection attempts and
        // backoff. Check in the worker too: completion can race the 5ms poll.
        fn checkBudget(self: *const Job) !void {
            if (self.request.cancellation) |cancel| if (cancel.isRequested()) return error.Canceled;
            if (self.start.untilNow(self.client.io, .awake).toMilliseconds() >= self.client.config.limits.request_timeout_ms)
                return error.RequestTimeout;
        }

        /// A worker can finish between poll ticks, including after child
        /// cleanup. Never publish a late success or discard its paid usage.
        fn complete(self: *const Job, outcome: p.Outcome) p.Outcome {
            self.checkBudget() catch |err| {
                var expired = failure(if (err == error.Canceled) .canceled else .timeout, if (err == error.Canceled) "Model request canceled" else "Model request exceeded its time limit", null, self.observed.load(.acquire));
                expired.failure.usage = self.last_usage;
                common.mergeUsage(&expired.failure.usage, switch (outcome) {
                    .success => |response| response.usage,
                    .failure => |detail| detail.usage,
                });
                return expired;
            };
            return outcome;
        }

        /// 由流解析器调用的事件回调：记录最新 usage 快照，并转发给调用方的 sink。
        fn emit(context: ?*anyopaque, event: p.ModelEvent) !void {
            const self: *Job = @ptrCast(@alignCast(context.?));
            switch (event) {
                .usage => |usage| self.last_usage = usage,
                else => self.observed.store(true, .release),
            }
            try self.sink.emit(event);
        }
    };

    /// Configuration is borrowed read-only. If a caller nevertheless replaces
    /// its route, refuse the stale client rather than silently sending direct.
    fn checkProxyRoute(self: *const Client) !void {
        const route = self.config.proxyFor(self.config.selected_provider, self.config.model.name);
        if (route) |selected| {
            const transport = if (self.proxy_http) |*t| t else return error.ProxyRouteChanged;
            const actual = transport.proxy_url orelse return error.ProxyRouteChanged;
            const expected = try selected.url(self.allocator);
            defer self.allocator.free(expected);
            if (!std.mem.eql(u8, expected, actual)) return error.ProxyRouteChanged;
        } else if (self.proxy_http != null) return error.ProxyRouteChanged;
    }

    fn checkProxyCleanup(self: *const Client) !void {
        if (self.proxy_http) |*transport| if (transport.poisoned) return error.CleanupFailed;
    }

    const ProxyBody = struct {
        job: *Job,
        decoder: *sse.Decoder,
        allocator: std.mem.Allocator,
        error_body: std.ArrayList(u8) = .empty,
        head: ?curl.StreamHead = null,

        fn check(raw: *anyopaque) !void {
            const self: *ProxyBody = @ptrCast(@alignCast(raw));
            try self.job.checkBudget();
        }

        fn write(raw: *anyopaque, head: curl.StreamHead, bytes: []const u8) !void {
            const self: *ProxyBody = @ptrCast(@alignCast(raw));
            try self.job.checkBudget();
            self.head = head;
            if (head.status != 200) {
                if (bytes.len > 65536 - self.error_body.items.len) return error.CurlResponseTooLarge;
                return self.error_body.appendSlice(self.allocator, bytes);
            }
            if (!head.is_sse) return error.ExpectedSse;
            self.decoder.feed(bytes) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => return err,
                else => return error.InvalidModelEvent,
            };
        }
    };

    fn performProxy(job: *Job, transport: *curl.Client, a: std.mem.Allocator, address: []const u8, payload: []const u8, credential: ?*const codex_auth.RequestCredential, authorization: []const u8) !p.Outcome {
        try job.checkBudget();
        try job.client.checkProxyCleanup();
        var header_buffer: [8]std.http.Header = undefined;
        const extra = try job.client.requestHeaders(job.request.scope.protocol, credential, &header_buffer);
        var headers: [9]std.http.Header = undefined;
        @memcpy(headers[0..extra.len], extra);
        var count = extra.len;
        if (job.request.scope.protocol != .anthropic) {
            headers[count] = .{ .name = "authorization", .value = authorization };
            count += 1;
        }
        var stream: Stream = switch (job.request.scope.protocol) {
            .chat => .{ .chat = chat.Stream.init(job.allocator, job.request.scope, .{ .context = job, .emit_fn = Job.emit }) },
            .responses => .{ .responses = responses.Stream.init(job.allocator, job.request.scope, .{ .context = job, .emit_fn = Job.emit }) },
            .anthropic => .{ .anthropic = anthropic.Stream.init(job.allocator, job.request.scope, .{ .context = job, .emit_fn = Job.emit }) },
            .systemone => return error.UnsupportedProtocol,
            .auto => unreachable,
        };
        var decoder = sse.Decoder.init(job.client.allocator, job.client.config.limits.max_event_bytes, .{ .context = &stream, .emit_fn = Stream.feed });
        defer decoder.deinit();
        var body: ProxyBody = .{ .job = job, .decoder = &decoder, .allocator = a };
        const remaining: u32 = @intCast(@max(1, @as(i64, job.client.config.limits.request_timeout_ms) - job.start.untilNow(job.client.io, .awake).toMilliseconds()));
        const head = transport.streamPost(a, address, headers[0..count], payload, @max(1, remaining), job.client.config.limits.max_response_bytes, .{ .context = &body, .write_fn = ProxyBody.write, .check_fn = ProxyBody.check }, job.request.cancellation orelse &uncanceled) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled, error.CleanupFailed, error.RequestTimeout => return err,
            error.Timeout => return error.RequestTimeout,
            error.InvalidHttpHead, error.ExpectedSse, error.InvalidModelEvent, error.CurlResponseTooLarge => return failure(.protocol, "Invalid or oversized proxied model response", if (body.head) |h| h.status else null, stream.observed()),
            else => return failure(.transport, "Model proxy transport failed", if (body.head) |h| h.status else null, stream.observed()),
        };
        if (head.status != 200) return classifyHttpError(job.allocator, head.status, body.error_body.items);
        if (!head.is_sse) return failure(.protocol, "Expected an SSE response", head.status, false);
        decoder.finish() catch return failure(.protocol, "Incomplete SSE event", head.status, stream.observed());
        return stream.finish() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => failure(.protocol, "Model response did not complete safely", head.status, stream.observed()),
        };
    }

    /// Retry acquisition only. std 0.17 request() validates URI/CA and
    /// acquires TCP/TLS (or a pooled connection), but sends no model headers
    /// or body. Never extend this boundary to sendBodyComplete/receiveHead.
    /// HostName.connect may try multiple resolved addresses within one call;
    /// this caps acquisition rounds, not the resolver's address fan-out.
    fn acquireRequest(job: *Job, uri: std.Uri, options: std.http.Client.RequestOptions) !std.http.Client.Request {
        const delays_ms = [_]u32{ 200, 500 };
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            try job.checkBudget();
            return job.client.http.request(.POST, uri, options) catch |err| {
                if (attempt == delays_ms.len or !transientConnectError(err)) return err;
                // Same cancellable worker Io and original invoke deadline.
                // Cancellation joins this sleep before any request data dies.
                try Io.sleep(job.client.io, .fromMilliseconds(delays_ms[attempt]), .awake);
                continue;
            };
        }
    }

    /// 在 I/O worker 中执行完整请求：编码、发送、读取 HTTP 响应，并解析 SSE 流。
    fn perform(job: *Job) !p.Outcome {
        // 无论成功失败都要标记完成，否则主协程会一直轮询。
        defer job.done.store(true, .release);
        const self = job.client;
        try self.request_mutex.lock(self.io);
        defer self.request_mutex.unlock(self.io);
        // 请求体、URL 等临时数据放在 scratch arena 中，函数返回时一并释放。
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const protocol = job.request.scope.protocol;
        try job.checkBudget();
        var credential: ?codex_auth.RequestCredential = null;
        defer if (credential) |*auth| auth.deinit(self.allocator);
        var auth_owned: ?[]u8 = null;
        defer if (auth_owned) |auth| {
            std.crypto.secureZero(u8, auth);
            self.allocator.free(auth);
        };
        if (self.codex_source) |source| {
            if (!isCodexConfig(self.config) or !std.mem.eql(u8, self.config.provider.base_url, codex_base) or protocol != .responses) return error.UnsupportedProtocol;
            const remaining = @as(i64, self.config.limits.request_timeout_ms) - job.start.untilNow(self.io, .awake).toMilliseconds();
            if (remaining <= 0) return error.RequestTimeout;
            credential = try source.acquire(self.allocator, self.config.selected_provider orelse return error.MissingProviderAlias, job.request.cancellation, @intCast(remaining));
            try job.checkBudget();
            try validateHeaderValue(credential.?.access_token);
            try validateHeaderValue(credential.?.account_id);
            auth_owned = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{credential.?.access_token});
        } else if (isCodexConfig(self.config) or std.mem.eql(u8, self.config.provider.base_url, codex_base)) return error.UnsupportedProtocol;
        const authorization = auth_owned orelse self.authorization;

        // 按协议选择编码器：Chat Completions 或 Responses。
        const payload = switch (protocol) {
            .chat => try chat.encode(a, job.request),
            .responses => if (credential != null) try responses.encodeCodex(a, job.request) else try responses.encode(a, job.request),
            .anthropic => try anthropic.encode(a, job.request),
            .systemone => return error.UnsupportedProtocol,
            .auto => unreachable,
        };

        // 去掉 base_url 结尾的斜杠，再拼接各协议固定的端点路径。
        const address = try requestAddress(a, self.config.provider.base_url, protocol);

        if (self.proxy_http) |*transport| return performProxy(job, transport, a, address, payload, if (credential) |*auth| auth else null, authorization);

        // Before acquiring a socket, drop expired/closed/unread idle connections.
        // This sends nothing and never retries a POST. boot includes suspend time.
        try pool.prune(&self.http, self.last_request_finish, Io.Clock.boot.now(self.io));

        // 禁止自动跟随重定向（否则 Authorization 头可能被发送到其他主机）；要求不压缩，便于逐块解析 SSE。
        var header_buffer: [8]std.http.Header = undefined;
        const headers = try self.requestHeaders(protocol, if (credential) |*auth| auth else null, &header_buffer);
        const uri = try std.Uri.parse(address);
        var request = try acquireRequest(job, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = if (protocol == .anthropic) .omit else .{ .override = authorization },
                .user_agent = .{ .override = "thin" },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = headers,
        });
        defer {
            request.deinit(); // Release/destroy socket before recording idle time.
            self.last_request_finish = Io.Clock.boot.now(self.io);
        }

        // 请求体已完整编码，使用固定 Content-Length 而不是分块传输。
        request.transfer_encoding = .{ .content_length = payload.len };
        // The encoder allocated an independent mutable buffer; TLS may modify it.
        try job.checkBudget();
        try request.sendBodyComplete(payload);

        // receiveHead 解析响应头所需的缓冲区（重定向已禁用，只用于读取响应头）。
        var redirect: [1024]u8 = undefined;
        var response = try request.receiveHead(&redirect);
        const status: u16 = @backingInt(response.head.status);
        const content_type = response.head.content_type orelse "";
        // Content-Type 可能带有 charset 等参数，只比较主类型 text/event-stream。
        var types = std.mem.splitScalar(u8, content_type, ';');
        const is_sse = std.ascii.eqlIgnoreCase(std.mem.trim(u8, types.first(), " \t"), "text/event-stream");
        // 响应体读取缓冲区（8KB）。
        var transfer: [8192]u8 = undefined;
        const reader = response.reader(&transfer);

        // 非 200：读取最多 64KB 的错误体后交给分类器；读取失败时不做错误分类。
        if (status != 200) {
            const error_body = reader.allocRemaining(a, .limited(65536)) catch
                return failure(if (status >= 500) .server else .protocol, "API error body could not be read safely", status, false);
            // 错误体未读完（连接中断）时，不能依据残缺内容判断错误类型。
            switch (request.reader.state) {
                .body_remaining_content_length, .body_remaining_chunk_len => return failure(.transport, "Incomplete HTTP error response body", status, false),
                else => {},
            }
            return classifyHttpError(job.allocator, status, error_body);
        }

        // 成功状态码但不是 SSE：端点不符合流式协议预期，直接报协议错误。
        if (!is_sse)
            return failure(.protocol, "Expected an SSE response", status, false);

        // 根据协议创建对应的流解析器，解析器的事件通过 sink 转发出去。
        const sink = p.ModelSink{ .context = job, .emit_fn = Job.emit };
        var stream: Stream = switch (protocol) {
            .chat => .{ .chat = chat.Stream.init(job.allocator, job.request.scope, sink) },
            .responses => .{ .responses = responses.Stream.init(job.allocator, job.request.scope, sink) },
            .anthropic => .{ .anthropic = anthropic.Stream.init(job.allocator, job.request.scope, sink) },
            .systemone => return error.UnsupportedProtocol,
            .auto => unreachable,
        };

        // 单个 SSE 事件大小受 max_event_bytes 限制，防止恶意服务端耗尽内存。
        var decoder = sse.Decoder.init(self.allocator, self.config.limits.max_event_bytes, .{
            .context = &stream,
            .emit_fn = Stream.feed,
        });
        defer decoder.deinit();

        // 读取循环：累计字节数不超过 max_response_bytes。
        var buffer: [8192]u8 = undefined;
        var total: usize = 0;
        while (true) {
            // readVec copies an existing buffered prefix, then can block in
            // another socket read before returning it. Deliver that prefix
            // first, notably for EOF-delimited SSE coalesced with the headers.
            const n = readAvailable(reader, &buffer) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return failure(.transport, "Model stream was interrupted", status, stream.observed()),
            };
            // 0 字节只表示暂时没有数据，不是 EOF。
            if (n == 0) continue;
            // total 始终不超过上限，因此减法不会下溢；先判断再累加。
            if (n > self.config.limits.max_response_bytes - total)
                return failure(.protocol, "Model response exceeds its byte limit", status, stream.observed());
            total += n;
            // 解析错误（格式错误、事件过大）映射为协议错误；OOM 与取消原样上抛。
            decoder.feed(buffer[0..n]) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => return err,
                else => return failure(.protocol, "Malformed or oversized model event", status, stream.observed()),
            };
        }

        // 连接在正文未读完时断开，视为传输错误。
        switch (request.reader.state) {
            .body_remaining_content_length, .body_remaining_chunk_len => return failure(.transport, "Incomplete HTTP response body", status, stream.observed()),
            else => {},
        }

        // 流结束时若仍有未完成的 SSE 事件，说明响应被截断。
        decoder.finish() catch return failure(.protocol, "Incomplete SSE event", status, stream.observed());

        // 由协议流决定最终成功或失败（例如缺少 finish_reason 时失败）。
        return stream.finish() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => failure(.protocol, "Model response did not complete safely", status, stream.observed()),
        };
    }
};

fn isCodexConfig(config: *const cfg.Config) bool {
    const kind = config.provider.kind orelse return false;
    return std.mem.eql(u8, @tagName(kind), "openai_codex");
}

fn validateHeaderValue(value: []const u8) !void {
    if (value.len == 0 or value.len > 16384) return error.InvalidCredential;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidCredential;
}

/// Never hold already-buffered SSE bytes hostage to the next socket read.
fn readAvailable(reader: *Io.Reader, destination: []u8) Io.Reader.Error!usize {
    std.debug.assert(destination.len != 0);
    const pending = reader.buffered();
    if (pending.len != 0) {
        const n = @min(pending.len, destination.len);
        @memcpy(destination[0..n], pending[0..n]);
        reader.toss(n);
        return n;
    }
    var vectors = [_][]u8{destination};
    return reader.readVec(&vectors);
}

test "codex rejects missing source and forged endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const kind = std.meta.stringToEnum(cfg.providers.Id, "openai_codex") orelse return;
    var config: cfg.Config = .{ .provider = .{ .base_url = codex_base, .kind = kind }, .selected_provider = "codex", .model = .{ .name = "fixture", .context_tokens = 32768, .protocol = .responses } };
    try std.testing.expectError(error.MissingCredentialSource, Client.initCodexWithEnv(std.testing.allocator, std.testing.io, &config, .{}, &env));
    try std.testing.expectError(error.UnsupportedProtocol, Client.init(std.testing.allocator, std.testing.io, &config, "fake"));
    for ([_][]const u8{
        "https://chatgpt.com.evil/backend-api/codex",
        "https://chatgpt.com/backend-api/codex/",
        "https://chatgpt.com/backend-api/codex?x=1",
        "https://chatgpt.com/backend-api/codex-lookalike",
    }) |address| {
        config.provider.base_url = address;
        try std.testing.expectError(error.UnsupportedProtocol, Client.initCodexWithEnv(std.testing.allocator, std.testing.io, &config, .{}, &env));
    }
}

test "codex clone keeps source and acquires using child alias" {
    const Fake = struct {
        calls: usize = 0,
        fn acquire(ctx: ?*anyopaque, a: std.mem.Allocator, alias: []const u8, _: ?*const p.Cancellation, _: u32) !codex_auth.RequestCredential {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == 1) {
                try std.testing.expectEqualStrings("parent", alias);
            } else {
                try std.testing.expectEqualStrings("child", alias);
            }
            const token = try a.dupe(u8, if (self.calls == 1) "first-access" else "second-access");
            errdefer a.free(token);
            const account = try a.dupe(u8, "account");
            return .{ .access_token = token, .account_id = account };
        }
    };
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const parent_config: cfg.Config = .{ .provider = .{ .base_url = codex_base, .kind = .openai_codex }, .selected_provider = "parent", .model = .{ .name = "fixture", .context_tokens = 17000, .protocol = .responses } };
    var child_config = parent_config;
    child_config.selected_provider = "child";
    var fake: Fake = .{};
    var parent = try Client.initCodexWithEnv(a, std.testing.io, &parent_config, .{ .context = &fake, .acquire_fn = Fake.acquire }, &env);
    defer parent.deinit();
    var child = try parent.cloneForConfig(a, std.testing.io, &child_config);
    defer child.deinit();
    var first = try parent.codex_source.?.acquire(a, parent.config.selected_provider.?, null, 1000);
    defer first.deinit(a);
    var second = try child.codex_source.?.acquire(a, child.config.selected_provider.?, null, 1000);
    defer second.deinit(a);
    try std.testing.expectEqualStrings("first-access", first.access_token);
    try std.testing.expectEqualStrings("second-access", second.access_token);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(child.config == &child_config);
}

test "codex perform gates credential acquisition on request budget and cancellation" {
    const Fake = struct {
        calls: usize = 0,
        remaining: u32 = 0,
        alias: []const u8 = "",
        fn acquire(ctx: ?*anyopaque, _: std.mem.Allocator, alias: []const u8, _: ?*const p.Cancellation, remaining: u32) !codex_auth.RequestCredential {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.alias = alias;
            self.remaining = remaining;
            return error.LocalCaptureOnly;
        }
    };
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = codex_base, .kind = .openai_codex }, .selected_provider = "capture-alias", .model = .{ .name = "fixture", .context_tokens = 32768, .protocol = .responses }, .limits = .{ .request_timeout_ms = 60000 } };
    var fake: Fake = .{};
    var client = try Client.initCodexWithEnv(a, std.testing.io, &config, .{ .context = &fake, .acquire_fn = Fake.acquire }, &env);
    defer client.deinit();
    var cancel: p.Cancellation = .{};
    var request = @import("../tests/adapter_test_support.zig").request(.responses);
    request.cancellation = &cancel;
    var job: Client.Job = .{ .client = &client, .allocator = a, .request = request, .sink = .{}, .start = Io.Clock.awake.now(std.testing.io) };

    cancel.cancel();
    try std.testing.expectError(error.Canceled, Client.perform(&job));
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    job.done.store(false, .release);
    job.request.cancellation = null;
    job.start = Io.Clock.awake.now(std.testing.io).subDuration(.fromMilliseconds(60000));
    try std.testing.expectError(error.RequestTimeout, Client.perform(&job));
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    job.done.store(false, .release);
    job.start = Io.Clock.awake.now(std.testing.io).subDuration(.fromMilliseconds(1000));
    try std.testing.expectError(error.LocalCaptureOnly, Client.perform(&job));
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("capture-alias", fake.alias);
    try std.testing.expect(fake.remaining > 0 and fake.remaining < config.limits.request_timeout_ms);
}

test "codex refresh redaction material is absent from headers and body" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = codex_base, .kind = .openai_codex }, .selected_provider = "codex", .model = .{ .name = "fixture", .context_tokens = 17000, .protocol = .responses } };
    const Fake = struct {
        fn acquire(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: ?*const p.Cancellation, _: u32) !codex_auth.RequestCredential {
            return error.Unused;
        }
    };
    var client = try Client.initCodexWithEnv(a, std.testing.io, &config, .{ .acquire_fn = Fake.acquire }, &env);
    defer client.deinit();
    const canary = "refresh-secret-canary";
    var credential: codex_auth.RequestCredential = .{ .access_token = try a.dupe(u8, "access"), .account_id = try a.dupe(u8, "account"), .redaction_refresh_token = try a.dupe(u8, canary) };
    defer credential.deinit(a);
    var header_buffer: [8]std.http.Header = undefined;
    const headers = try client.requestHeaders(.responses, &credential, &header_buffer);
    for (headers) |header| {
        try std.testing.expect(std.mem.indexOf(u8, header.name, canary) == null);
        try std.testing.expect(std.mem.indexOf(u8, header.value, canary) == null);
    }
    const authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{credential.access_token});
    defer a.free(authorization);
    try std.testing.expect(std.mem.indexOf(u8, authorization, canary) == null);
    const req = @import("../tests/adapter_test_support.zig").request(.responses);
    const body = try responses.encodeCodex(a, req);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, canary) == null);
}

test "codex header values reject control characters" {
    for ([_][]const u8{ "", "bad\rvalue", "bad\nvalue", "bad\x00value", "bad\x7fvalue" }) |value| {
        try std.testing.expectError(error.InvalidCredential, validateHeaderValue(value));
    }
    try validateHeaderValue("valid-token_123");
}

test "SSE buffered prefix returns before a subsequent failing transport read" {
    var payload = "data: owned-first-event\n\n".*;
    var reader = Io.Reader.failing;
    reader.buffer = &payload;
    reader.end = payload.len;
    var buffer: [8192]u8 = undefined;
    const n = try readAvailable(&reader, &buffer);
    try std.testing.expectEqualStrings(&payload, buffer[0..n]);
    try std.testing.expectEqual(@as(usize, 0), reader.bufferedLen());
    try std.testing.expectError(error.ReadFailed, readAvailable(&reader, &buffer));
}

test "SSE buffered prefix respects destination bounds and logical consumption" {
    var reader: Io.Reader = .fixed("owned");
    var buffer: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try readAvailable(&reader, &buffer));
    try std.testing.expectEqualStrings("own", &buffer);
    const n = try readAvailable(&reader, &buffer);
    try std.testing.expectEqualStrings("ed", buffer[0..n]);
    try std.testing.expectError(error.EndOfStream, readAvailable(&reader, &buffer));
}

/// Deliberate allowlist from Zig 0.17 HostName.ConnectError. DNS
/// NameServerFailure is ambiguous (no temporary/permanent distinction), and
/// TLS rejects collapse into TlsInitializationFailed: neither is safe to guess.
fn transientConnectError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused, error.ConnectionResetByPeer, error.NetworkUnreachable, error.HostUnreachable, error.NetworkDown => true,
        else => false,
    };
}

test "connection retry focused: transient allowlist rejects TLS DNS and configuration ambiguity" {
    for ([_]anyerror{ error.ConnectionRefused, error.ConnectionResetByPeer, error.NetworkUnreachable, error.HostUnreachable, error.NetworkDown }) |err|
        try std.testing.expect(transientConnectError(err));
    for ([_]anyerror{
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure,
        error.InvalidHostName,         error.UriMissingHost,
        error.UnsupportedUriScheme,    error.NameServerFailure,
        error.UnknownHostName,         error.AccessDenied,
        error.OutOfMemory,             error.Canceled,
        error.Unexpected,              error.Timeout,
    }) |err| try std.testing.expect(!transientConnectError(err));
}

test {
    _ = @import("../http_retry_test.zig");
}

/// Keep persisted connection identity stable. Go uses its documented inference
/// routes; custom endpoints are never rewritten by provider hint or model ID.
fn requestAddress(a: std.mem.Allocator, base_url: []const u8, protocol: p.Protocol) ![]u8 {
    if (protocol == .systemone or cfg.providers.Id.fromSystemOneUrl(base_url) != null) return error.UnsupportedProtocol;
    const normalized = std.mem.trimEnd(u8, base_url, "/");
    const base = blk: {
        if (cfg.providers.Id.fromUrl(normalized)) |id| switch (id) {
            .opencode_go => break :blk "https://opencode.ai/inference/go/v1",
            .opencode_zen => if (protocol == .anthropic) {
                break :blk "https://opencode.ai/inference/v1";
            },
            else => {},
        };
        break :blk normalized;
    };
    const suffix = switch (protocol) {
        .chat => "/chat/completions",
        .responses => "/responses",
        .anthropic => "/messages",
        .systemone => return error.UnsupportedProtocol,
        .auto => return error.UnselectedProtocol,
    };
    return std.fmt.allocPrint(a, "{s}{s}", .{ base, suffix });
}

/// 按协议分派的流解析器，对外提供统一的 feed / finish / observed 接口。
const Stream = union(enum) {
    chat: chat.Stream,
    responses: responses.Stream,
    anthropic: anthropic.Stream,

    /// SSE 解码器的回调入口，通过 inline else 分派到当前协议的实现。
    fn feed(context: *anyopaque, event: []const u8, data: []const u8) !void {
        const self: *Stream = @ptrCast(@alignCast(context));
        switch (self.*) {
            inline else => |*s| try s.feed(event, data),
        }
    }
    /// 结束当前协议的流并生成最终结果。
    fn finish(self: *Stream) !p.Outcome {
        return switch (self.*) {
            inline else => |*s| try s.finish(),
        };
    }
    /// 是否已观察到内容或工具调用增量。
    fn observed(self: *const Stream) bool {
        return switch (self.*) {
            inline else => |*s| s.observedContent(),
        };
    }
};

/// 构造失败结果。message 必须是静态字符串或不含上游敏感内容的文本，避免泄露 API 返回的原始信息。
fn failure(kind: p.FailureKind, message: []const u8, status: ?u16, observed: bool) p.Outcome {
    return .{ .failure = .{ .kind = kind, .message = message, .http_status = status, .observed_content = observed } };
}

test "SystemOne cannot enter chat HTTP via protocol endpoint or stale client" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedProtocol, requestAddress(a, "http://127.0.0.1:1", .systemone));
    for ([_]p.Protocol{ .auto, .chat, .responses, .anthropic, .systemone }) |api| {
        try std.testing.expectError(error.UnsupportedProtocol, requestAddress(a, "https://opencode.ai/inference/systemone/v1/", api));
    }
    var config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1:1" }, .model = .{ .name = "reviewer", .protocol = .systemone, .context_tokens = 0 } };
    try std.testing.expectError(error.UnsupportedProtocol, Client.init(a, std.testing.io, &config, "fake"));
    // Early rejection must precede worker/clock/proxy access, even if a caller
    // bypassed init or mutated the config after constructing a chat client.
    var client: Client = undefined;
    client.config = &config;
    const request: p.Request = .{
        .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .chat },
        .system = "",
        .tools = &.{},
        .messages = &.{},
    };
    const result = try client.model().call(a, request, .{});
    try std.testing.expectEqual(p.FailureKind.unsupported_protocol, result.failure.kind);
    config.model.protocol = .chat;
    config.provider.base_url = "https://opencode.ai/inference/systemone/v1";
    const endpoint = try client.model().call(a, request, .{});
    try std.testing.expectEqual(p.FailureKind.unsupported_protocol, endpoint.failure.kind);
}

test "completed worker cannot publish late tools or hide usage at the final deadline gate" {
    var config: cfg.Config = .{ .provider = .{ .base_url = "https://example.invalid/v1" }, .model = .{ .name = "fixture", .context_tokens = 32768 }, .limits = .{ .request_timeout_ms = 1 } };
    var client = try Client.init(std.testing.allocator, std.testing.io, &config, "fake");
    defer client.deinit();
    var cancel: p.Cancellation = .{};
    var job: Client.Job = .{
        .client = &client,
        .allocator = std.testing.allocator,
        .request = .{ .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .chat }, .system = "fixed", .tools = &.{}, .messages = &.{}, .cancellation = &cancel },
        .sink = .{},
        .start = Io.Clock.awake.now(std.testing.io),
        .last_usage = .{ .output_tokens = 2 },
    };
    const response: p.Outcome = .{ .success = .{
        .message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "complete", .name = "lookup", .arguments = "{}" } }} },
        .finish = .tool_calls,
        .usage = .{ .input_tokens = 7, .output_tokens = 3 },
    } };
    try Io.sleep(std.testing.io, .fromMilliseconds(3), .awake);
    job.done.store(true, .release); // The polling loop would not run again.
    const late = job.complete(response);
    try std.testing.expect(late == .failure and late.failure.kind == .timeout);
    try std.testing.expectEqual(@as(?u64, 7), late.failure.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 3), late.failure.usage.output_tokens);
    cancel.cancel();
    try std.testing.expect(job.complete(response).failure.kind == .canceled);
}

test "model proxy route cannot silently reuse a stale direct client after alias change" {
    var config: cfg.Config = .{
        .provider = .{ .base_url = "https://example.invalid/v1" },
        .selected_provider = "other",
        .model = .{ .name = "vendor/id", .context_tokens = 32768 },
        .proxy = .{ .address = "127.0.0.1", .port = 7890, .models = &.{"listed/vendor/id"} },
    };
    var client = try Client.init(std.testing.allocator, std.testing.io, &config, "fake");
    defer client.deinit();
    try client.checkProxyRoute();
    config.selected_provider = "listed";
    try std.testing.expectError(error.ProxyRouteChanged, client.checkProxyRoute());
    var listed = try Client.init(std.testing.allocator, std.testing.io, &config, "fake");
    defer listed.deinit();
    try listed.checkProxyRoute();
    config.proxy.?.port = 7891;
    try std.testing.expectError(error.ProxyRouteChanged, listed.checkProxyRoute());
    config.selected_provider = "other";
    try std.testing.expectError(error.ProxyRouteChanged, listed.checkProxyRoute());
}

test "OpenCode routing headers are stable explicit and absent on other services" {
    for (cfg.providers.Id.all) |id| {
        if (std.mem.eql(u8, @tagName(id), "openai_codex")) continue;
        const config: cfg.Config = .{ .provider = .{ .base_url = id.baseUrl(), .kind = id }, .model = .{ .name = "fixture", .context_tokens = 32768 } };
        var client = try Client.init(std.testing.allocator, std.testing.io, &config, "fake-key");
        defer client.deinit();
        var headers: [8]std.http.Header = undefined;
        const first = try client.requestHeaders(.chat, null, &headers);
        try std.testing.expectEqual(@as(usize, if (id.usesSessionHeader()) 2 else 1), first.len);
        if (id.usesSessionHeader()) {
            const generated = client.session_id.?;
            try std.testing.expectEqualStrings("x-opencode-session", first[1].name);
            try std.testing.expectEqualStrings(&generated, first[1].value);
            try std.testing.expectEqualStrings(&generated, (try client.requestHeaders(.chat, null, &headers))[1].value);
        }
        client.session_id = @splat('a');
        const pinned = try client.requestHeaders(.chat, null, &headers);
        if (id.usesSessionHeader()) {
            try std.testing.expectEqualStrings(&@as([32]u8, @splat('a')), pinned[1].value);
            client.session_id = @splat('\n');
            try std.testing.expectError(error.InvalidSessionIdentity, client.requestHeaders(.chat, null, &headers));
            client.session_id = null;
            try std.testing.expectError(error.MissingSessionIdentity, client.requestHeaders(.chat, null, &headers));
        } else try std.testing.expectEqual(@as(usize, 1), pinned.len);
    }
}

test "Anthropic exact routing and separate native authentication headers" {
    const cases = [_]struct { base: []const u8, expected: []const u8 }{
        .{ .base = "https://opencode.ai/zen/go/v1", .expected = "https://opencode.ai/inference/go/v1/messages" },
        .{ .base = "https://opencode.ai/inference/go/v1/", .expected = "https://opencode.ai/inference/go/v1/messages" },
        .{ .base = "https://opencode.ai/zen/v1", .expected = "https://opencode.ai/inference/v1/messages" },
        .{ .base = "https://api.anthropic.com/v1", .expected = "https://api.anthropic.com/v1/messages" },
        .{ .base = "https://proxy.invalid/v1", .expected = "https://proxy.invalid/v1/messages" },
        .{ .base = "https://opencode.ai.evil/zen/go/v1", .expected = "https://opencode.ai.evil/zen/go/v1/messages" },
    };
    for (cases) |case| {
        const address = try requestAddress(std.testing.allocator, case.base, .anthropic);
        defer std.testing.allocator.free(address);
        try std.testing.expectEqualStrings(case.expected, address);
        const config: cfg.Config = .{ .provider = .{ .base_url = case.base }, .model = .{ .name = "fixture", .context_tokens = 32768, .protocol = .anthropic } };
        var client = try Client.init(std.testing.allocator, std.testing.io, &config, "fake-key");
        defer client.deinit();
        var buffer: [8]std.http.Header = undefined;
        const headers = try client.requestHeaders(.anthropic, null, &buffer);
        const has_session = cfg.providers.Id.fromUrl(case.base) != null;
        try std.testing.expectEqual(@as(usize, if (has_session) 4 else 3), headers.len);
        try std.testing.expectEqualStrings("x-api-key", headers[headers.len - 2].name);
        try std.testing.expectEqualStrings("fake-key", headers[headers.len - 2].value);
        try std.testing.expectEqualStrings("anthropic-version", headers[headers.len - 1].name);
        try std.testing.expectEqualStrings("2023-06-01", headers[headers.len - 1].value);
    }
    const old = try requestAddress(std.testing.allocator, cfg.providers.Id.opencode_go.baseUrl(), .chat);
    defer std.testing.allocator.free(old);
    try std.testing.expectEqualStrings("https://opencode.ai/inference/go/v1/chat/completions", old);
}

/// 把非 200 的响应体转换为失败结果，同时尽量保留错误响应中携带的 usage 与原始 JSON。
pub fn classifyHttpError(allocator: std.mem.Allocator, status: u16, bytes: []const u8) p.Outcome {
    // 响应体不是合法 JSON 时按 null 处理，仍然可以依据 HTTP 状态码分类。
    const value = common.parse(allocator, bytes) catch .null;
    const detail = j.get(value, "error") orelse .null;
    var outcome = classifyFields(status, detail);

    // usage 可能位于顶层或 error 对象内；根据字段名判断是 Chat 还是 Responses 格式。
    if (j.get(value, "usage") orelse j.get(detail, "usage")) |usage| {
        if (usage == .object) {
            const is_responses = j.get(usage, "input_tokens") != null or j.get(usage, "output_tokens") != null or
                j.get(usage, "input_tokens_details") != null or j.get(usage, "output_tokens_details") != null;
            outcome.failure.usage = common.usage(usage, is_responses);
            outcome.failure.raw_usage_json = j.encode(allocator, usage) catch null;
        }
    }
    return outcome;
}

/// 依据 HTTP 状态码、error.code 与 error.param 判定失败类型。
fn classifyFields(status: u16, detail: j.Value) p.Outcome {
    const code = j.string(j.get(detail, "code")) orelse "";
    const param = j.string(j.get(detail, "param"));

    // param 缺失，或指向 endpoint/protocol，才视为端点协议相关的错误。
    const endpoint_param = param == null or std.mem.eql(u8, param.?, "endpoint") or std.mem.eql(u8, param.?, "protocol");

    // 只有服务端明确声明不支持该协议时，才返回 unsupported_protocol 以允许降级。
    if ((status == 400 or status == 404 or status == 405) and endpoint_param and
        (std.mem.eql(u8, code, "unsupported_protocol") or std.mem.eql(u8, code, "unsupported_endpoint")))
        return failure(.unsupported_protocol, "Endpoint explicitly reports unsupported protocol", status, false);

    // Never infer fallback from arbitrary error prose or a generic HTTP status.
    if (status == 401 or status == 403) return failure(.authentication, "API authentication failed", status, false);
    if (status == 429) return failure(.rate_limit, "API rate limit exceeded", status, false);
    if (status >= 500) return failure(.server, "API server error", status, false);
    if (std.mem.eql(u8, code, "context_length_exceeded")) return failure(.context_limit, "Model context limit exceeded", status, false);
    if (std.mem.eql(u8, code, "model_not_found")) return failure(.model, "Configured model was not found", status, false);
    return failure(.invalid_argument, "API rejected the request; check configuration and protocol", status, false);
}

// 验证：只有端点明确给出不支持协议的证据时才允许自动降级；错误文本不得回显密钥。
test "auto fallback requires explicit machine-readable endpoint evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(p.FailureKind.unsupported_protocol, classifyHttpError(a, 404, "{\"error\":{\"code\":\"unsupported_endpoint\"}}").failure.kind);
    try std.testing.expectEqual(p.FailureKind.invalid_argument, classifyHttpError(a, 404, "{\"error\":{\"message\":\"not supported fake-secret\"}}").failure.kind);
    try std.testing.expectEqual(p.FailureKind.authentication, classifyHttpError(a, 401, "{\"error\":{\"code\":\"unsupported_protocol\"}}").failure.kind);
    try std.testing.expectEqual(p.FailureKind.server, classifyHttpError(a, 500, "{\"error\":{\"code\":\"unsupported_protocol\"}}").failure.kind);

    const r = classifyHttpError(a, 400, "{\"error\":{\"code\":\"unsupported_protocol\",\"param\":\"response_format\"}}");
    try std.testing.expectEqual(p.FailureKind.invalid_argument, r.failure.kind);
    try std.testing.expect(std.mem.find(u8, r.failure.message, "fake-secret") == null);
}
