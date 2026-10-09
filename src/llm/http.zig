//! OpenAI 兼容 HTTP 客户端：发送 Chat Completions / Responses 请求，以 SSE 流式读取结果，
//! 并把 HTTP 错误、超时、取消统一映射为 p.Outcome。
const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const sse = @import("sse.zig");
const j = @import("../util/json.zig");
const chat = @import("chat.zig");
const responses = @import("responses.zig");
const common = @import("common.zig");
const Io = std.Io;

/// 模型客户端：持有 API 密钥的 Authorization 头副本与底层 std.http.Client。
/// 同一个 Client 的 deinit 必须在所有请求结束后调用。
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// 只读引用，调用方需保证其存活时间长于 Client。
    config: *const cfg.Config,
    /// 独立拷贝的 "Bearer <key>"，deinit 时清零后释放，避免密钥残留。
    authorization: []u8,
    /// 底层 HTTP 客户端，内部连接池随 Client 生命周期存在。
    http: std.http.Client,

    /// 创建客户端并校验密钥。密钥需非空、长度不超过 16KB，且不含控制字符（防止 HTTP 头注入）。
    pub fn init(allocator: std.mem.Allocator, io: Io, config: *const cfg.Config, key: []const u8) !Client {
        // 控制字符会破坏 HTTP 头格式，因此在这里拒绝。
        if (key.len == 0 or key.len > 16384) return error.InvalidApiKey;
        for (key) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidApiKey;
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key}),
            .http = .{ .allocator = allocator, .io = io },
        };
    }

    /// 释放连接池与密钥副本。
    pub fn deinit(self: *Client) void {
        self.http.deinit();
        // 先清零再释放，减少密钥在堆内存中残留的时间。
        std.crypto.secureZero(u8, self.authorization);
        self.allocator.free(self.authorization);
    }

    /// 返回通用的 p.Model 接口，上层通过 call_fn 调用而不依赖具体实现。
    pub fn model(self: *Client) p.Model {
        return .{ .context = self, .call_fn = invoke };
    }

    /// 执行一次模型请求。在独立的 I/O worker 中完成网络操作，主协程负责轮询取消与超时。
    fn invoke(context: *anyopaque, allocator: std.mem.Allocator, request: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *Client = @ptrCast(@alignCast(context));
        // auto 只能是配置层的占位值，进入 HTTP 层前必须已解析为具体协议。
        if (request.scope.protocol == .auto) return error.UnselectedProtocol;
        // 回放作用域必须与当前连接、模型一致，避免把历史 replay 发送到其他端点。
        if (!std.mem.eql(u8, request.scope.connection, self.config.provider.base_url) or
            !std.mem.eql(u8, request.scope.model, self.config.model.name)) return error.ReplayScopeMismatch;
        // 开始传输前已取消则直接返回，不启动 worker。
        if (request.cancellation) |cancel| if (cancel.isRequested())
            return failure(.canceled, "Model request canceled before transport", null, false);

        // job 与 worker 共享，必须保证 worker 结束后才能让 job 失效。
        var job = Job{ .client = self, .allocator = allocator, .request = request, .sink = sink };
        // 网络 I/O 放入并发任务执行，避免阻塞取消与超时检查。
        var future = try Io.concurrent(self.io, perform, .{&job});
        // 无论从哪个分支返回，都要取消并 join worker，保证 job 与 arena 不会被提前释放。
        defer _ = future.cancel(self.io) catch {};

        const start = Io.Clock.awake.now(self.io);
        // 每 5ms 轮询一次 worker 完成标志，同时检查取消与请求超时。
        while (!job.done.load(.acquire)) {
            if (request.cancellation) |cancel| {
                if (cancel.isRequested()) {
                    _ = future.cancel(self.io) catch {};
                    var outcome = failure(.canceled, "Model request canceled", null, job.observed.load(.acquire));
                    outcome.failure.usage = job.last_usage;
                    return outcome;
                }
            }
            if (start.untilNow(self.io, .awake).toMilliseconds() >= self.config.limits.request_timeout_ms) {
                _ = future.cancel(self.io) catch {};
                var outcome = failure(.timeout, "Model request exceeded its time limit", null, job.observed.load(.acquire));
                outcome.failure.usage = job.last_usage;
                return outcome;
            }
            // Cancellable waiting: parent cancellation cancels and joins the I/O
            // worker before its result arena or request data may be released.
            Io.sleep(self.io, .fromMilliseconds(5), .awake) catch |err| {
                _ = future.cancel(self.io) catch {};
                if (err != error.Canceled) return err;
                var outcome = failure(.canceled, "Model request canceled", null, job.observed.load(.acquire));
                outcome.failure.usage = job.last_usage;
                return outcome;
            };
        }

        // worker 已结束，取回结果；OOM 原样上抛，取消与其他错误转换为对应的失败类型。
        var outcome = future.await(self.io) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Canceled => failure(.canceled, "Model request canceled", null, job.observed.load(.acquire)),
            else => failure(.transport, "Model transport failed", null, job.observed.load(.acquire)),
        };

        // 失败时仍合并 worker 观察到的最新 usage，保证已消耗的 token 可以被统计。
        if (outcome == .failure) {
            common.mergeUsage(&outcome.failure.usage, job.last_usage);
        }
        return outcome;
    }

    /// 一次请求在 I/O worker 与主协程之间共享的状态。
    const Job = struct {
        client: *Client,
        allocator: std.mem.Allocator,
        request: p.Request,
        sink: p.ModelSink,
        /// worker 结束标志，由 perform 返回前设置，主协程据此停止轮询。
        done: std.atomic.Value(bool) = .init(false),
        /// 是否已向调用方发出过内容事件，用于失败结果判断是否产生过可见输出。
        observed: std.atomic.Value(bool) = .init(false),

        // Written by the I/O worker; read only after joining/canceling it.
        last_usage: p.Usage = .{},

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

    /// 在 I/O worker 中执行完整请求：编码、发送、读取 HTTP 响应，并解析 SSE 流。
    fn perform(job: *Job) !p.Outcome {
        // 无论成功失败都要标记完成，否则主协程会一直轮询。
        defer job.done.store(true, .release);
        const self = job.client;
        // 请求体、URL 等临时数据放在 scratch arena 中，函数返回时一并释放。
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const protocol = job.request.scope.protocol;

        // 按协议选择编码器：Chat Completions 或 Responses。
        const payload = switch (protocol) {
            .chat => try chat.encodeWithOptions(a, job.request, self.config.provider.chat_max_tokens),
            .responses => try responses.encode(a, job.request),
            .auto => unreachable,
        };

        // 去掉 base_url 结尾的斜杠，再拼接各协议固定的端点路径。
        const base = std.mem.trimEnd(u8, self.config.provider.base_url, "/");
        const address = try std.fmt.allocPrint(a, "{s}{s}", .{
            base, if (protocol == .chat) "/chat/completions" else "/responses",
        });

        // 禁止自动跟随重定向（否则 Authorization 头可能被发送到其他主机）；要求不压缩，便于逐块解析 SSE。
        var request = try self.http.request(.POST, try std.Uri.parse(address), .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .{ .override = self.authorization },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
        });
        defer request.deinit();

        // 请求体已完整编码，使用固定 Content-Length 而不是分块传输。
        request.transfer_encoding = .{ .content_length = payload.len };
        // The encoder allocated an independent mutable buffer; TLS may modify it.
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
            // readSliceShort would fill the whole buffer and hide small streaming
            // updates. readVec returns currently available bytes instead.
            var vectors = [_][]u8{&buffer};
            const n = reader.readVec(&vectors) catch |err| switch (err) {
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

/// 按协议分派的流解析器（Chat 或 Responses），对外提供统一的 feed / finish / observed 接口。
const Stream = union(enum) {
    chat: chat.Stream,
    responses: responses.Stream,

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
