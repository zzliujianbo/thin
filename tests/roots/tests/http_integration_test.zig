//! HTTP 客户端集成测试：通过 127.0.0.1 本地固定夹具服务器验证 Chat/Responses 流解析、工具回放、协议回退、错误分类、超时与取消。不访问外部网络。

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const Client = @import("../llm/http.zig").Client;
const Selector = @import("../llm/llm.zig").Selector;
const idle_pool = @import("../llm/http_pool.zig");
const t = std.testing;
const Io = std.Io;

/// 固定的单工具 schema，用于验证请求体中的 tools 字段。
const tools = [_]p.ToolSchema{.{ .name = "lookup", .description = "Local fixture only", .parameters_json = "{\"type\":\"object\",\"properties\":{}}" }};

/// 固定的初始用户消息。
const initial = [_]p.Message{.{ .role = .user, .blocks = &.{.{ .text = "hello fixture" }} }};

/// 根据 fixture 基础地址与场景名构造配置；场景名拼接在 URL 路径中，由夹具服务器分派。
fn config(a: std.mem.Allocator, scenario: []const u8, protocol: p.Protocol) !cfg.Config {
    return configBase(a, scenario, protocol, "THIN_HTTP_FIXTURE_URL", "http");
}

fn configBase(a: std.mem.Allocator, scenario: []const u8, protocol: p.Protocol, env_name: []const u8, scheme: []const u8) !cfg.Config {
    const base = std.testing.environ.getPosix(env_name) orelse return error.MissingFixtureEnvironment;

    // Accept only a literal IPv4 loopback authority, never DNS/userinfo/redirects.
    const uri = try std.Uri.parse(base);
    const host = uri.host orelse return error.UnsafeFixtureUrl;
    const host_text = switch (host) {
        .raw, .percent_encoded => |s| s,
    };

    // 拒绝：非 http scheme、非 127.0.0.1 主机、缺端口，以及带 userinfo/query/fragment/路径的 URL。
    if (!std.mem.eql(u8, uri.scheme, scheme) or !std.mem.eql(u8, host_text, "127.0.0.1") or
        uri.port == null or uri.port == 0 or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or !uri.path.isEmpty()) return error.UnsafeFixtureUrl;

    return .{ .provider = .{ .base_url = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, scenario }), .api_key_env = "THIN_FAKE_KEY" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = protocol }, .limits = .{ .low_price_input = false, .request_timeout_ms = 10000 } };
}

/// 构造固定内容的请求，使每次调用的 scope 与 system 保持一致，便于对比。
fn request(c: cfg.Config, protocol: p.Protocol) p.Request {
    return .{ .scope = .{ .connection = c.provider.base_url, .model = c.model.name, .protocol = protocol }, .system = "fixed fixture system", .tools = &tools, .messages = &initial };
}

/// 记录流式事件：文本写入固定 128 字节缓冲（超出则报错），并累计推理与工具参数的字节数及 usage。
const Recorder = struct {
    /// 固定容量的文本缓冲，避免测试中动态分配。
    text: [128]u8 = undefined,
    len: usize = 0,
    /// 推理增量的字节数（只计数，不保存内容）。
    reasoning: usize = 0,
    /// 工具参数增量的字节数。
    tool: usize = 0,
    /// 最近一次收到的 usage。
    usage: p.Usage = .{},

    /// 事件回调：按类型分别处理。
    fn emit(ctx: ?*anyopaque, event: p.ModelEvent) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .text_delta => |s| {
                if (s.len > self.text.len - self.len) return error.TooMuchText;
                @memcpy(self.text[self.len..][0..s.len], s);
                self.len += s.len;
            },
            .reasoning_delta => |s| self.reasoning += s.len,
            .tool_delta => |d| self.tool += d.arguments.len,
            .usage => |u| self.usage = u,
        }
    }

    /// 包装为 p.ModelSink 接口。
    fn sink(self: *Recorder) p.ModelSink {
        return .{ .context = self, .emit_fn = emit };
    }
};

/// 断言调用成功并返回 Response；失败时打印分类与信息，便于定位夹具问题。
fn success(out: p.Outcome) !p.Response {
    if (out == .failure) {
        std.debug.print("unexpected fixture failure: {s}: {s}\n", .{ @tagName(out.failure.kind), out.failure.message });
        return error.ExpectedSuccess;
    }
    return out.success;
}

// 验证：Chat 与 Responses 在 UTF-8 字符和 CRLF 被切分时仍能正确解析文本、推理增量以及迟到的 usage。

// 验证：工具调用的真实 call id 与 Responses 的 item id 被保留并回放；summary 请求也不会破坏协议状态。

// 验证：显式的 unsupported endpoint 错误只回退一次并固定为 Chat，之后的调用不再回退。

// 验证：401/429/404/400/503 等普通 HTTP 错误被正确分类，且不触发协议回退。

// 验证：缺少终止事件、截断、非法 JSON、未完成以及重定向等异常都以失败结束（fail closed），不会伪装成成功。

fn failedPoll(_: []std.c.pollfd) c_int {
    return -1; // Deterministic EINTR/inspection failure: drop idle, not retry.
}

// Two genuine requests on one Client. The server also checks same/different
// sockets and exact counts, so successful replay cannot conceal a duplicate POST.

// Parent's timeout/cancel must join a worker waiting for the request mutex,
// without unlocking someone else's ownership or sending a queued POST.

/// 150ms 后触发取消，用于模拟客户端在请求中途被取消。
fn cancelLater(io: Io, cancel: *p.Cancellation) !void {
    try Io.sleep(io, .fromMilliseconds(150), .awake);
    cancel.cancel();
}

// 验证：响应头或响应体停滞时超时返回 timeout，主动取消返回 canceled，且超时/取消后同一 Client 仍能成功完成请求。
