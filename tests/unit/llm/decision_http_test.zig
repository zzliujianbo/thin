test "decision config quotes backslashes unicode and never interpolates script" {
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
test "decision validation rejects controls URL ambiguity and config metasyntax" {
    const payload = "{}";
    for ([_][]const u8{ "file:///etc/passwd", "https://u:p@example.invalid/", "https://example.invalid/?", "https://example.invalid/#", "https://example.invalid/\n", "https://", "https://example.invalid\\evil/" }) |url| {
        try std.testing.expectError(error.InvalidUrl, validate(url, "fake", payload, 1000));
    }
    for ([_][]const u8{ "", "key\r\nheader: injection", "key\x00", "key\x7f", "key\xc2\x85" }) |key| {
        try std.testing.expectError(error.InvalidKey, validate("https://example.invalid/", key, payload, 1000));
    }
    for ([_][]const u8{ "", "@/etc/passwd", "\x00", "\x08", "\x0c", "\xff" }) |body| {
        try std.testing.expectError(error.InvalidPayload, validate("https://example.invalid/", "fake", body, 1000));
    }
    try std.testing.expectError(error.InvalidTimeout, validate("http://example.invalid/", "fake", payload, 0));
    try validate("http://127.0.0.1:1234/api", "fake", "{\n\t\"ok\":true\r\n}", 1);
}
test "decision response exact suffix status errors overflow and incomplete rejection" {
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
        try std.testing.expectError(error.DecisionTransport, parseResponse(a, fakeResult(bytes)));
    }
    var result = fakeResult("partial\n200");
    result.truncated = true;
    try std.testing.expectError(error.DecisionTransport, parseResponse(a, result));
    result.truncated = false;
    result.term = .{ .exited = 18 };
    try std.testing.expectError(error.DecisionTransport, parseResponse(a, result));
    result.term = null;
    try std.testing.expectError(error.DecisionTransport, parseResponse(a, result));
    result.timed_out = true;
    try std.testing.expectError(error.Timeout, parseResponse(a, result));
    result.cleanup_failed = true;
    try std.testing.expectError(error.CleanupFailed, parseResponse(a, result));
    const oversized = try a.alloc(u8, max_body + 5);
    defer a.free(oversized);
    @memset(oversized, 'x');
    @memcpy(oversized[oversized.len - 4 ..], "\n200");
    try std.testing.expectError(error.DecisionTransport, parseResponse(a, fakeResult(oversized)));
    @memcpy(oversized[max_body..][0..4], "\n200");
    const at_limit = try parseResponse(a, fakeResult(oversized[0 .. max_body + 4]));
    defer at_limit.deinit(a);
    try std.testing.expectEqual(@as(usize, max_body), at_limit.body.len);
}
test "decision environment allowlist cancellation and poison reject before spawn" {
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
test "decision anonymous input begins at zero CLOEXEC and wipes then truncates" {
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
test "decision cleanup failure without PID is sticky even over cancellation" {
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
test "decision deinit reaps only its owned direct child and clears PID" {
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
test "decision config environment and response allocation failures preserve ownership" {
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
