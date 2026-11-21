test "buffered catalog GET keeps query and caller authorization only in private config" {
    const a = std.testing.allocator;
    const url = "https://catalog.invalid/models?client_version=1.2&filter=a%2Fb";
    const config = try makeHeaderConfig(a, url, &.{.{ .name = "Authorization", .value = "Bearer synthetic" }}, null, 1250, .buffered, true, null);
    defer wipeFree(a, config);
    for ([_][]const u8{ "request = \"GET\"\n", "url = \"" ++ url ++ "\"\n", "header = \"Authorization: Bearer synthetic\"\n", "proto = \"=https\"\n", "\nno-location\n", "proxy = \"\"\nnoproxy = \"*\"", "max-time = \"1.250\"", "write-out = \"\\n%{http_code}\"" }) |expected|
        try std.testing.expect(std.mem.indexOf(u8, config, expected) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, config, "header = "));
    for ([_][]const u8{ "data-binary", "insecure", "\nlocation\n" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, config, forbidden) == null);
    try std.testing.expectEqualStrings("exec /usr/bin/curl --disable --config -", script);
}

test "buffered OAuth POST preserves form data and distinguishes empty POST from GET" {
    const a = std.testing.allocator;
    const url = "https://auth.invalid/token";
    for ([_][]const u8{ "code=fake%2Btoken&redirect_uri=https%3A%2F%2Fapp.invalid", "" }) |payload| {
        const config = try makeHeaderConfig(a, url, &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }}, payload, 123, .buffered, false, null);
        defer wipeFree(a, config);
        try std.testing.expect(std.mem.indexOf(u8, config, "request = \"POST\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, config, "Content-Type: application/x-www-form-urlencoded") != null);
        try std.testing.expect(std.mem.indexOf(u8, config, "Bearer") == null);
        const prefix = "data-binary = \"";
        const start = (std.mem.indexOf(u8, config, prefix) orelse return error.MissingPayload) + prefix.len;
        try std.testing.expectEqualStrings(payload, config[start..][0..payload.len]);
        try std.testing.expect(std.mem.startsWith(u8, config[start + payload.len ..], "\"\n"));
    }
}

test "buffered request rejects insecure URLs file syntax and header injection before spawn" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var client = try Client.initRouted(a, std.testing.io, &env, null);
    defer client.deinit();
    var cancel: protocol.Cancellation = .{};
    const url = "https://origin.invalid/";
    for ([_][]const u8{ "http://origin.invalid", "file:///fixture", "https://u@origin.invalid/?q", url ++ "?q#frag", url ++ "?x\nlocation", url ++ "?x\\y" }) |bad|
        try std.testing.expectError(error.InvalidUrl, client.request(a, bad, &.{}, null, 1, 0, &cancel));
    for ([_]std.http.Header{ .{ .name = "@file", .value = "x" }, .{ .name = "Authorization", .value = "x\r\nX: y" } }) |h|
        try std.testing.expectError(error.InvalidHeader, client.request(a, url, &.{h}, null, 1, 0, &cancel));
    try std.testing.expectError(error.InvalidPayload, client.request(a, url, &.{}, "@fixture", 1, 0, &cancel));
    const oversized = try a.alloc(u8, 1024 * 1024 + 1);
    defer a.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.InvalidPayload, client.request(a, url, &.{}, oversized, 1, 0, &cancel));
    try std.testing.expectError(error.InvalidTimeout, client.request(a, url, &.{}, null, 0, 0, &cancel));
    cancel.cancel();
    try std.testing.expectError(error.Canceled, client.request(a, "", &.{}, null, 0, 0, &cancel));
    client.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, client.request(a, "", &.{}, null, 0, 0, &cancel));
}

test "bounded wire sink accepts exact body and trailer and rejects overflow without partial copy" {
    const a = std.testing.allocator;
    const wire = "a\x00\xff\n302";
    for (0..wire.len + 1) |split| {
        var writer = WireBuffer{ .a = a, .limit = wire.len };
        defer writer.bytes.deinit(a);
        try bufferChunk(&writer, wire[0..split]);
        try bufferChunk(&writer, wire[split..]);
        const response = try parseResponseBytes(a, fakeResult(wire), writer.bytes.items);
        defer response.deinit(a);
        try std.testing.expectEqual(@as(u16, 302), response.status);
        try std.testing.expectEqualStrings(wire[0..3], response.body);
    }
    var writer = WireBuffer{ .a = a, .limit = 4 };
    defer writer.bytes.deinit(a);
    try bufferChunk(&writer, "x");
    try std.testing.expectError(error.CurlResponseTooLarge, bufferChunk(&writer, "\n200"));
    try std.testing.expectEqualStrings("x", writer.bytes.items);
    writer.bytes.clearRetainingCapacity();
    try bufferChunk(&writer, "\n204");
    const empty = try parseResponseBytes(a, fakeResult("\n204"), writer.bytes.items);
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.body.len);
}

test "owned response and full config storage are zeroed at release" {
    var backing: [4096]u8 = @splat(0xaa);
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const a = fba.allocator();
    const config = try makeHeaderConfig(a, "https://auth.invalid/", &.{}, "{\"code\":\"synthetic\"}", 1, .buffered, true, null);
    const size = config.len;
    wipeFree(a, config);
    try std.testing.expect(std.mem.allEqual(u8, backing[0..size], 0));
    const response = try parseResponse(a, fakeResult("token\n200"));
    response.deinit(a);
    try std.testing.expect(std.mem.allEqual(u8, backing[0..5], 0));

    // Fail a receive-buffer growth without starting a network request. Inspect
    // the fixed allocator's own storage after release, not a dangling slice.
    fba.reset();
    @memset(&backing, 0xaa);
    var wiping = @import("../core/config.zig").WipingAllocator{ .backing = a };
    var sink = WireBuffer{ .a = wiping.allocator(), .limit = std.math.maxInt(usize) };
    try bufferChunk(&sink, "synthetic token");
    try std.testing.expectError(error.OutOfMemory, bufferChunk(&sink, &backing));
    try std.testing.expectEqualStrings("synthetic token", sink.bytes.items);
    const capacity = sink.bytes.capacity;
    sink.bytes.deinit(sink.a);
    try std.testing.expect(std.mem.allEqual(u8, backing[0..capacity], 0));
}

test "curl config quotes backslashes unicode and never interpolates script" {
    const a = std.testing.allocator;
    const key = "test-key-\\\"中文";
    const payload = "{\"text\":\"中文\\u4f60\\n\\\\\"}\n";
    const buffer = try makeConfig(a, "https://example.invalid/api", key, payload, 1250);
    defer wipeFree(a, buffer);
    const config = buffer[0..std.mem.indexOfScalar(u8, buffer, 0).?];
    try std.testing.expectEqualStrings("exec /usr/bin/curl --disable --config -", script);
    try std.testing.expect(std.mem.indexOf(u8, script, key) == null);
    try std.testing.expect(std.mem.indexOf(u8, config, "authorization: Bearer test-key-\\\\\\\"中文") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "max-time = \"1.250\"") != null);
    var lines = std.mem.splitScalar(u8, config, '\n');
    var found = false;
    while (lines.next()) |line| {
        const prefix = "data-binary = ";
        if (std.mem.startsWith(u8, line, prefix)) {
            const decoded = try std.json.parseFromSlice([]const u8, a, line[prefix.len..], .{});
            defer decoded.deinit();
            try std.testing.expectEqualStrings(payload, decoded.value);
            found = true;
        }
    }
    try std.testing.expect(found);
}
test "typical 1 MiB curl config allocation is close to payload size and propagates OOM" {
    const a = std.testing.allocator;
    const payload = try a.alloc(u8, 1024 * 1024);
    defer a.free(payload);
    @memset(payload, 'x');
    const prefix = "{\"text\":\"";
    @memcpy(payload[0..prefix.len], prefix);
    @memcpy(payload[payload.len - 2 ..], "\"}");
    for ([_]bool{ false, true }) |stream|
        try std.testing.checkAllAllocationFailures(a, largeConfigCase, .{ payload, stream });
}

test "curl config emits exact data-binary bytes at maximum payload escape density" {
    const raw = "\"\\\n\r\t";
    const escaped = "\\\"\\\\\\n\\r\\t";
    var payload: [raw.len * 8192]u8 = undefined;
    for (0..8192) |i| @memcpy(payload[i * raw.len ..][0..raw.len], raw);
    for ([_]bool{ false, true }) |stream| {
        const a = std.testing.allocator;
        const config = if (stream)
            try makeStreamConfig(a, "https://origin.invalid/", &.{}, &payload, 1, null, false, null)
        else
            try makeConfig(a, "https://origin.invalid/", "fake", &payload, 1);
        defer wipeFree(a, config);
        const prefix = "\ndata-binary = \"";
        const pos = std.mem.indexOf(u8, config, prefix) orelse return error.MissingPayload;
        var data = config[pos + prefix.len ..];
        for (0..8192) |_| {
            try std.testing.expect(std.mem.startsWith(u8, data, escaped));
            data = data[escaped.len..];
        }
        try std.testing.expect(std.mem.startsWith(u8, data, "\"\nmax-time = "));
    }
}

test "transport validation rejects controls URL ambiguity and config metasyntax" {
    const a = std.testing.allocator;
    const payload = "{}";
    for ([_][]const u8{ "file:///etc/passwd", "https://u:p@example.invalid/", "https://example.invalid/?", "https://example.invalid/#", "https://example.invalid/\n", "https://", "https://example.invalid\\evil/" }) |url| {
        try std.testing.expectError(error.InvalidUrl, makeConfig(a, url, "fake", payload, 1000));
    }
    for ([_][]const u8{ "", "key\r\nheader: injection", "key\x00", "key\x7f", "key\xc2\x85" }) |key| {
        try std.testing.expectError(error.InvalidKey, makeConfig(a, "https://example.invalid/", key, payload, 1000));
    }
    for ([_][]const u8{ "", "@/etc/passwd", "\x00", "\x08", "\x0c", "\xff" }) |body| {
        try std.testing.expectError(error.InvalidPayload, makeConfig(a, "https://example.invalid/", "fake", body, 1000));
    }
    try std.testing.expectError(error.InvalidTimeout, makeConfig(a, "http://example.invalid/", "fake", payload, 0));
    const config = try makeConfig(a, "http://127.0.0.1:1234/api", "fake", "{\n\t\"ok\":true\r\n}", 1);
    defer wipeFree(a, config);
}
test "transport response exact suffix status errors overflow and incomplete rejection" {
    const a = std.testing.allocator;
    const original = "{\"text\":\"\\u4f60中文\"}\x00\xff\n";
    const response = try parseResponse(a, fakeResult(original ++ "\n200"));
    defer response.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings(original, response.body);
    const denied = try parseResponse(a, fakeResult("denied\n403"));
    defer denied.deinit(a);
    try std.testing.expectEqual(@as(u16, 403), denied.status);
    for ([_][]const u8{ "", "200", "body200", "x\n20", "x\n2a0", "x\n000", "x\n200\n" }) |bytes| {
        try std.testing.expectError(error.TransportFailure, parseResponse(a, fakeResult(bytes)));
    }
    var result = fakeResult("partial\n200");
    result.truncated = true;
    try std.testing.expectError(error.TransportFailure, parseResponse(a, result));
    result.truncated = false;
    result.term = .{ .exited = 18 };
    try std.testing.expectError(error.TransportFailure, parseResponse(a, result));
    result.term = null;
    try std.testing.expectError(error.TransportFailure, parseResponse(a, result));
    result.timed_out = true;
    try std.testing.expectError(error.Timeout, parseResponse(a, result));
    result.cleanup_failed = true;
    try std.testing.expectError(error.CleanupFailed, parseResponse(a, result));
    // The response body crosses the retired 64 KiB cap; status framing and
    // byte accounting remain strict independently of body size.
    const large = try a.alloc(u8, 65537 + 4);
    defer a.free(large);
    @memset(large, 'x');
    @memcpy(large[large.len - 4 ..], "\n200");
    const response_large = try parseResponse(a, fakeResult(large));
    defer response_large.deinit(a);
    try std.testing.expectEqualStrings(large[0 .. large.len - 4], response_large.body);
    var mismatched = fakeResult(large);
    mismatched.stdout_bytes -= 1;
    try std.testing.expectError(error.TransportFailure, parseResponse(a, mismatched));
}
test "transport environment allowlist cancellation and poison reject before spawn" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "http://127.0.0.1:1");
    try env.put("no_proxy", "localhost,127.0.0.1");
    try env.put("CURL_CA_BUNDLE", "/fixture/ephemeral-ca.pem");
    try env.put("LD_PRELOAD", "/fake/preload");
    try env.put("HOME", "/fake/home");
    try env.put("CURL_CONFIG", "/fake/config");
    try env.put("API_KEY", "fake-secret");
    var client = try Client.init(a, std.testing.io, &env);
    defer client.deinit();
    try std.testing.expectEqual(@as(usize, 5), client.env.count());
    try std.testing.expectEqualStrings("/fixture/ephemeral-ca.pem", client.env.get("CURL_CA_BUNDLE").?);
    try std.testing.expectEqualStrings("/usr/bin:/bin", client.env.get("PATH").?);
    try std.testing.expectEqualStrings("C", client.env.get("LC_ALL").?);
    try std.testing.expectEqualStrings("localhost,127.0.0.1", client.env.get("no_proxy").?);
    var cancel: protocol.Cancellation = .{};
    cancel.cancel();
    // Invalid request is deliberate: cancellation/poison must win first.
    try std.testing.expectError(error.Canceled, client.post(a, "", "", "", 0, &cancel));
    client.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, client.post(a, "", "", "", 0, &cancel));
    try env.put("HTTP_PROXY", "http://bad\nproxy");
    try std.testing.expectError(error.InvalidProxyEnvironment, Client.init(a, std.testing.io, &env));
}
test "transport anonymous input begins at zero CLOEXEC and wipes then truncates" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const config = try makeConfig(a, "https://example.invalid/", "fake-test-key", "{}", 100);
    defer wipeFree(a, config);
    var input = try Input.init(config);
    const duplicate = c.fcntl(input.fd, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (duplicate < 0) {
        input.deinit(std.testing.io);
        return error.TestDuplicateFailed;
    }
    defer _ = c.close(duplicate);
    const cloexec: c_int = 1;
    const flags = c.fcntl(input.fd, c.F.GETFD);
    var bytes: [6]u8 = undefined;
    const n = c.read(input.fd, &bytes, bytes.len);
    input.deinit(std.testing.io);
    try std.testing.expect(flags & cloexec != 0);
    try std.testing.expectEqual(@as(isize, 6), n);
    try std.testing.expectEqualStrings("silent", &bytes);
    const end = c.lseek(duplicate, 0, c.SEEK.END);
    try std.testing.expectEqual(c.E.SUCCESS, c.errno(end));
    try std.testing.expectEqual(@as(c.off_t, 0), end);
}
test "transport cleanup failure without PID is sticky even over cancellation" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var client = try Client.init(a, std.testing.io, &env);
    defer client.deinit();
    var cancel: protocol.Cancellation = .{};
    cancel.cancel();
    var result = fakeResult("{}\n200");
    result.cleanup_failed = true;
    try std.testing.expectError(error.CleanupFailed, client.acceptResult(a, result, &cancel));
    try std.testing.expect(client.poisoned and client.unreaped_pid == null);
    try std.testing.expectError(error.CleanupFailed, client.post(a, "", "", "", 0, &cancel));
}
test "transport deinit reaps only its owned direct child and clears PID" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var client = try Client.init(a, std.testing.io, &env);
    defer client.deinit();
    const pid = c.fork();
    if (pid < 0) return error.TestForkFailed;
    if (pid == 0) c._exit(0);
    // Transfer ownership before any fallible assertion. Deferred deinit owns
    // cleanup, including on failure; never use a cached PGID/PID after reap.
    client.unreaped_pid = pid;
    var result = fakeResult("{}\n200");
    result.unreaped_pid = pid;
    var cancel: protocol.Cancellation = .{};
    try std.testing.expectError(error.CleanupFailed, client.acceptResult(a, result, &cancel));
    try std.testing.expect(client.poisoned);
    client.deinit();
    try std.testing.expectEqual(@as(?c.pid_t, null), client.unreaped_pid);
    var status: c_int = undefined;
    const rc = c.waitpid(pid, &status, c.W.NOHANG);
    try std.testing.expect(rc < 0 and c.errno(rc) == .CHILD);
}
test "transport config environment and response allocation failures preserve ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "curl stream origin headers interim responses and every split deliver exact body" {
    const wire = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nX_Valid: yes\r\n\r\ndata: 中文\n\n";
    for (0..wire.len + 1) |split| {
        var sink: StreamTestSink = .{};
        defer sink.data.deinit(std.testing.allocator);
        var parser: StreamParser = .{ .body_limit = 100, .sink = .{ .context = &sink, .write_fn = StreamTestSink.write } };
        try StreamParser.write(&parser, wire[0..split]);
        try StreamParser.write(&parser, wire[split..]);
        try std.testing.expectEqual(@as(u16, 200), parser.head.?.status);
        try std.testing.expect(parser.head.?.is_sse);
        try std.testing.expectEqualStrings("data: 中文\n\n", sink.data.items);
    }
}
test "only Codex accepts a missing stream media type, never an explicitly wrong type" {
    for ([_][]const u8{ "", "Content-Type:\r\n", "Content-Type: application/json\r\n", "Content-Type: text/event-stream\r\n" }, 0..) |header, i| {
        var sink: StreamTestSink = .{};
        defer sink.data.deinit(std.testing.allocator);
        var parser: StreamParser = .{ .body_limit = 100, .sink = .{ .context = &sink, .write_fn = StreamTestSink.write } };
        try StreamParser.write(&parser, "HTTP/1.1 200 OK\r\n");
        try StreamParser.write(&parser, header);
        try StreamParser.write(&parser, "\r\nx");
        const head = sink.head.?;
        try std.testing.expectEqual(i == 0 or i == 3, head.acceptsStream(.codex_responses));
        for ([_]protocol.WireCodec{ .responses, .chat, .anthropic }) |codec|
            try std.testing.expectEqual(i == 3, head.acceptsStream(codec));
    }
}

test "curl stream bounds and ambiguous malformed headers fail closed" {
    const heads = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\ncontent-type: text/plain\r\n\r\n",
        "HTTP/1.1 101 Switching\r\n\r\n",
        "HTTP/1.1 999 Strange\r\n\r\n",
        "HTTP/1.1 200 OK\r\n folded: no\r\n\r\n",
        "HTTP/1.1 200 OK\r\nX: a\x00b\r\n\r\n",
    };
    var sink: StreamTestSink = .{};
    defer sink.data.deinit(std.testing.allocator);
    for (heads) |head| {
        var parser: StreamParser = .{ .body_limit = 2, .sink = .{ .context = &sink, .write_fn = StreamTestSink.write } };
        try std.testing.expectError(error.InvalidHttpHead, StreamParser.write(&parser, head));
    }
    var parser: StreamParser = .{ .body_limit = 2, .sink = .{ .context = &sink, .write_fn = StreamTestSink.write } };
    try std.testing.expectError(error.CurlResponseTooLarge, StreamParser.write(&parser, "HTTP/1.1 200 OK\r\n\r\nabc"));
    try std.testing.expectEqual(@as(usize, 0), sink.data.items.len);
    var huge: [65537]u8 = @splat('x');
    var large: StreamParser = .{ .body_limit = 2, .sink = .{ .context = &sink, .write_fn = StreamTestSink.write } };
    try std.testing.expectError(error.InvalidHttpHead, StreamParser.write(&large, &huge));
}
test "system model proxy selects by scheme and freezes only safe environment" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "http://127.0.0.1:1");
    try env.put("https_proxy", "http://127.0.0.1:2");
    try env.put("HTTP_PROXY", "http://127.0.0.1:3");
    try env.put("REQUEST_METHOD", "GET");
    try env.put("ALL_PROXY", "http://127.0.0.1:4");
    try env.put("NO_PROXY", "localhost");
    try std.testing.expect(Client.systemProxy(&env, "http://example.test") == null);
    var client = try Client.initModel(a, std.testing.io, &env, "https://example.test", null, true);
    defer client.deinit();
    try env.put("https_proxy", "http://name:secret@example.test");
    try std.testing.expectError(error.InvalidProxyEnvironment, Client.initModel(a, std.testing.io, &env, "https://example.test", null, true));
    var clone = try client.cloneRoute(a, std.testing.io);
    defer clone.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:2", clone.env.get("https_proxy").?);
    try std.testing.expectEqualStrings("localhost", clone.env.get("no_proxy").?);
    try std.testing.expect(clone.env.get("ALL_PROXY") == null and clone.env.get("http_proxy") == null);
}

test "explicit inference routes ignore ambient proxy and no_proxy and clone trust roots" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "bad\nproxy");
    try env.put("NO_PROXY", "*");
    try env.put("CURL_CA_BUNDLE", "/owned/fake-ca");
    var direct = try Client.initRouted(std.testing.allocator, std.testing.io, &env, null);
    defer direct.deinit();
    try std.testing.expect(direct.explicit_route and direct.proxy_url == null);
    try std.testing.expect(direct.env.get("HTTPS_PROXY") == null and direct.env.get("NO_PROXY") == null);
    const config = try makeConfigRouted(std.testing.allocator, "https://origin.invalid/", "fake", "{}", 1000, true, null);
    defer wipeFree(std.testing.allocator, config);
    try std.testing.expect(std.mem.indexOf(u8, config, "proxy = \"\"\nnoproxy = \"*\"") != null);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, streamAllocationCase, .{});
}
