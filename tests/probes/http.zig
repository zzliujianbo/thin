//! HTTP 探针：使用本地服务（HTTP 和 HTTPS）验证 std.http.Client 的连接复用、POST 请求体、分块传输、截断检测、TLS 证书校验以及流式读取的取消行为。

const std = @import("std");
// 测试断言工具别名。
const t = std.testing;
const h = @import("common.zig");
const Io = h.Io;

/// 拼接基础 URL 与路径，返回新分配的字符串（调用者负责释放）。
fn url(base: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(h.alloc, "{s}{s}", .{ base, path });
}

/// 发送 GET（payload 为 null）或 POST 请求，要求状态码为 200，并返回完整响应体。
/// 如果响应被截断，则返回 error.IncompleteHttpBody。
fn body(client: *std.http.Client, address: []const u8, payload: ?[]const u8) ![]u8 {
    var request = try client.request(if (payload != null) .POST else .GET, try std.Uri.parse(address), .{});
    defer request.deinit();

    if (payload) |data| {
        // 带上请求体时使用定长（content-length）编码。
        request.transfer_encoding = .{ .content_length = data.len };
        // Zig 0.17 permits TLS to encrypt this buffer in place.
        const mutable = try h.alloc.dupe(u8, data);
        defer h.alloc.free(mutable);
        try request.sendBodyComplete(mutable);
    } else try request.sendBodiless();

    // 响应头缓冲区，用于接收 HTTP 头。
    var redirect: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect);
    try t.expectEqual(std.http.Status.ok, response.head.status);

    var transfer: [2048]u8 = undefined;
    const result = try response.reader(&transfer).allocRemaining(h.alloc, .limited(8192));
    errdefer h.alloc.free(result);

    // EOF is not proof of complete HTTP framing. In Zig 0.17, an early EOF in a
    // content-length body can leave a positive remaining count without raising
    // a Reader error. SSE/model completion requires a separate adapter check.
    switch (request.reader.state) {
        .body_remaining_content_length, .body_remaining_chunk_len => return error.IncompleteHttpBody,
        else => {},
    }
    return result;
}

/// 为客户端加载测试用的 CA 证书（环境变量 THIN_PROBE_CA 指定的文件）。
fn trustFixture(client: *std.http.Client) !void {
    // A non-null now prevents Client.request from replacing the explicit test CA
    // bundle with a rescan of the OS trust store on its first TLS connection.
    client.now = Io.Clock.real.now(client.io);
    try client.ca_bundle.addCertsFromFilePathAbsolute(h.alloc, client.io, client.now.?, try h.env("THIN_PROBE_CA"));
}

// 验证：两次 GET 应复用同一连接（connection id 相同），且 POST 的 JSON 原样回显。
test "probe: HTTP GET reuses a connection and POST preserves JSON" {
    var threaded = h.backend();
    defer threaded.deinit();
    var client = std.http.Client{ .allocator = h.alloc, .io = threaded.io() };
    defer client.deinit();
    const address = try url(try h.env("THIN_PROBE_HTTP_URL"), "/health");
    defer h.alloc.free(address);

    const first = try body(&client, address, null);
    defer h.alloc.free(first);
    const second = try body(&client, address, null);
    defer h.alloc.free(second);

    const Reply = struct { ok: bool, connection: u64 };
    const a = try std.json.parseFromSlice(Reply, h.alloc, first, .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(Reply, h.alloc, second, .{});
    defer b.deinit();
    try t.expect(a.value.ok and b.value.ok);
    try t.expectEqual(a.value.connection, b.value.connection);

    const echo = try url(try h.env("THIN_PROBE_HTTP_URL"), "/echo");
    defer h.alloc.free(echo);
    const payload = "{\"message\":\"中文\",\"stream\":true}";
    const echoed = try body(&client, echo, payload);
    defer h.alloc.free(echoed);
    try t.expectEqualStrings(payload, echoed);
}

// 验证：分块传输中，被切开的 UTF-8 字符和 SSE 字节流仍完整且合法。
test "probe: chunked HTTP delivers intact split UTF-8 and SSE bytes" {
    var threaded = h.backend();
    defer threaded.deinit();
    var client = std.http.Client{ .allocator = h.alloc, .io = threaded.io() };
    defer client.deinit();
    const address = try url(try h.env("THIN_PROBE_HTTP_URL"), "/stream");
    defer h.alloc.free(address);
    const result = try body(&client, address, null);
    defer h.alloc.free(result);
    try t.expectEqualStrings("event: delta\r\ndata: {\"text\":\"你\"}\r\n\r\ndata: [DONE]\n\n", result);
    try t.expect(std.unicode.utf8ValidateSlice(result));
    // This validates the byte transport, not a production SSE event parser.
}

// 验证：服务端实际截断的响应体必须报错，而不能被当作成功完成。
test "probe: truncated HTTP body is an error, not a successful completion" {
    var threaded = h.backend();
    defer threaded.deinit();
    var client = std.http.Client{ .allocator = h.alloc, .io = threaded.io() };
    defer client.deinit();
    const address = try url(try h.env("THIN_PROBE_HTTP_URL"), "/abrupt");
    defer h.alloc.free(address);
    try t.expectError(error.IncompleteHttpBody, body(&client, address, null));
}

// 验证：显式 CA 下证书通过；空 CA 或主机名不匹配时必须拒绝握手。
test "probe: TLS accepts the explicit CA and rejects untrusted or wrong-host certificates" {
    var threaded = h.backend();
    defer threaded.deinit();
    const io = threaded.io();
    const good = try url(try h.env("THIN_PROBE_HTTPS_URL"), "/health");
    defer h.alloc.free(good);

    var trusted = std.http.Client{ .allocator = h.alloc, .io = io };
    defer trusted.deinit();
    try trustFixture(&trusted);
    const result = try body(&trusted, good, null);
    defer h.alloc.free(result);

    try t.expect(std.mem.find(u8, result, "\"ok\":true") != null);
    const echo = try url(try h.env("THIN_PROBE_HTTPS_URL"), "/echo");
    defer h.alloc.free(echo);
    const payload = "{\"message\":\"TLS 中文\"}";
    const echoed = try body(&trusted, echo, payload);
    defer h.alloc.free(echoed);
    try t.expectEqualStrings(payload, echoed);

    // Explicitly empty CA bundle: no system trust-store mutation or verify bypass.
    var untrusted = std.http.Client{ .allocator = h.alloc, .io = io, .now = Io.Clock.real.now(io) };
    defer untrusted.deinit();
    try t.expectError(error.TlsInitializationFailed, body(&untrusted, good, null));

    const wrong = try url(try h.env("THIN_PROBE_WRONG_HOST_URL"), "/health");
    defer h.alloc.free(wrong);
    try t.expectError(error.TlsInitializationFailed, body(&trusted, wrong, null));
}

/// 读取一个字节后会阻塞在第二个字节上（服务端故意不发送），用于模拟停滞的流。
/// 无论如何退出，都会通过 cleaned 标志通知清理已完成。
fn stalledRead(client: *std.http.Client, address: []const u8, ready: *h.Flag, cleaned: *h.Flag) !void {
    defer cleaned.store(true, .release);
    var request = try client.request(.GET, try std.Uri.parse(address), .{});
    defer request.deinit();
    try request.sendBodiless();

    var redirect: [512]u8 = undefined;
    var response = try request.receiveHead(&redirect);
    var transfer: [512]u8 = undefined;
    const reader = response.reader(&transfer);
    try t.expectEqual(@as(u8, 'x'), try reader.takeByte());

    ready.store(true, .release);
    _ = try reader.takeByte(); // Server deliberately never sends this byte.
    return error.UnexpectedStreamContinuation;
}

/// 在 HTTP（secure=false）或 HTTPS（secure=true）上取消停滞的流，并验证取消快速、清理执行、客户端仍可复用。
fn cancelStream(secure: bool) !void {
    var threaded = h.backend();
    defer threaded.deinit();
    const io = threaded.io();
    var client = std.http.Client{ .allocator = h.alloc, .io = io };
    defer client.deinit();
    if (secure) try trustFixture(&client);

    const address = try url(try h.env(if (secure) "THIN_PROBE_HTTPS_URL" else "THIN_PROBE_HTTP_URL"), "/stall");
    defer h.alloc.free(address);
    // 在后台任务中启动流读取，主任务之后会取消它。
    var ready = h.Flag.init(false);
    var cleaned = h.Flag.init(false);
    var future = try Io.concurrent(io, stalledRead, .{ &client, address, &ready, &cleaned });
    defer future.cancel(io) catch {};

    try h.waitFlag(io, &ready, 5000);
    // The first byte was consumed while the response is still open; another task
    // remains runnable. No model/SSE completion was required for this progress.
    try Io.sleep(io, .fromMilliseconds(20), .awake);
    try t.expect(!cleaned.load(.acquire));

    const started = Io.Clock.awake.now(io);
    // 取消应该失败；正常结果为 Canceled 或 ReadFailed，并打印耗时供观察。
    if (future.cancel(io)) |_| return error.ExpectedCancellation else |err| {
        // Io.Reader can wrap the transport's Canceled as ReadFailed.
        try t.expect(err == error.Canceled or err == error.ReadFailed);
        std.debug.print("STREAM_CANCEL tls={} error={s} elapsed_ms={d}\n", .{ secure, @errorName(err), started.untilNow(io, .awake).toMilliseconds() });
    }

    try t.expect(cleaned.load(.acquire));
    try t.expect(started.untilNow(io, .awake).toMilliseconds() < 2000);

    const health = try url(try h.env("THIN_PROBE_HTTP_URL"), "/health");
    defer h.alloc.free(health);
    const recovered = try body(&client, health, null);
    defer h.alloc.free(recovered);
}

// 验证：HTTP 停滞流可以被取消，且同一客户端之后仍能正常发请求。
test "probe: stalled HTTP stream cancels and the client can be reused" {
    try cancelStream(false);
}

// 验证：HTTPS 停滞流可以被取消，并且请求的清理（defer）会被执行。
test "probe: stalled HTTPS stream cancels and runs request cleanup" {
    try cancelStream(true);
}
