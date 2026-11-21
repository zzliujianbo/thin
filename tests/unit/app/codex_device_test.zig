test "OAuth POST uses configured proxy independent of models or HTTPS proxy with NO_PROXY" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    for ([_]enum { configured, system, bypass }{ .configured, .system, .bypass }) |mode| {
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        const port = server.socket.address.getPort();
        const url = try std.fmt.allocPrint(a, "https://127.0.0.1:{d}/oauth/token", .{port});
        defer a.free(url);
        const proxy: cfg.ProxyConfig = .{ .address = "127.0.0.1", .port = port }; // empty models
        const proxy_url = try proxy.url(a);
        defer a.free(proxy_url);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HTTPS_PROXY", if (mode == .configured) "not a proxy URL" else proxy_url);
        try env.put("NO_PROXY", if (mode == .system) "" else "*");
        var client = try initClient(a, io, &env, if (mode == .configured) proxy else null);
        defer client.deinit();
        // Even a route regression can only reach this test's own loopback port.
        var http: Http = .{ .client = &client, .urls = .{ url, url, url } };
        var job = try Io.concurrent(io, rejectOAuthConnection, .{ io, &server, mode == .bypass });
        defer job.cancel(io) catch {};
        try std.testing.expectError(error.TransportFailure, refreshWith(http.transport(), a, io, "synthetic-refresh", null, 3000));
        // A pre-spawn failure cannot leave this test waiting in accept().
        try job.cancel(io);
    }
}

test "device begin and poll exchange use owned values" {
    const a = std.testing.allocator;
    var fake: Fake = .{ .responses = &.{ .{ .status = 200, .body = "{\"device_auth_id\":\"id\",\"user_code\":\"code\",\"interval\":\"5\"}" }, .{ .status = 403, .body = "{}" }, .{ .status = 200, .body = "{\"authorization_code\":\"a+b\",\"code_verifier\":\"v\"}" }, .{ .status = 200, .body = "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":60}" } } };
    var device = try beginWith(fake.transport(), a, std.testing.io, null, 5000);
    defer device.deinit(a);
    try std.testing.expectEqual(@as(u32, 5000), device.interval_ms);
    try std.testing.expect((try pollWith(fake.transport(), a, std.testing.io, &device, null, 5000)) == .pending);
    var result = try pollWith(fake.transport(), a, std.testing.io, &device, null, 5000);
    try std.testing.expect(result == .success);
    defer result.success.deinit(a);
    try std.testing.expectEqual(@as(i64, 61000), result.success.expires_at_ms);
    try std.testing.expectEqualStrings("refresh", result.success.refresh_token);
}
test "refresh preserves complete rotated response despite cancellation" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var fake: Fake = .{ .responses = &.{.{ .status = 200, .body = "{\"access_token\":\"new\",\"refresh_token\":\"rotated\",\"expires_in\":1}" }}, .cancel_on_response = &cancel };
    var result = try refreshWith(fake.transport(), a, std.testing.io, "old", &cancel, 5000);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("rotated", result.refresh_token);
    try std.testing.expect(cancel.isRequested());
}
test "token fields and depth fail closed" {
    const a = std.testing.allocator;
    const body = try a.dupe(u8, "{\"access_token\":\"a\",\"expires_in\":1}");
    defer wipeFree(a, body);
    try std.testing.expectError(error.InvalidResponse, parseToken(a, .{ .status = 200, .body = body }, 0));
    try std.testing.expectError(error.InvalidResponse, checkDepth("[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]"));
}
test "token parser enforces access and refresh length limits" {
    const a = std.testing.allocator;
    const token = try a.alloc(u8, max_token + 1);
    defer wipeFree(a, token);
    @memset(token, 'a');
    for ([_]bool{ false, true }) |oversize_access| {
        const access = if (oversize_access) token else token[0..max_token];
        const refresh_token = if (oversize_access) token[0..max_token] else token;
        const body = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"refresh_token\":\"{s}\",\"expires_in\":1}}", .{ access, refresh_token });
        defer wipeFree(a, body);
        try std.testing.expectError(error.InvalidResponse, parseToken(a, .{ .status = 200, .body = body }, 0));
    }
    const body = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"refresh_token\":\"{s}\",\"expires_in\":1}}", .{ token[0..max_token], token[0..max_token] });
    defer wipeFree(a, body);
    var result = try parseToken(a, .{ .status = 200, .body = body }, 0);
    defer result.deinit(a);
    try std.testing.expectEqual(max_token, result.access_token.len);
    try std.testing.expectEqual(max_token, result.refresh_token.len);
}
test "poll error classifications and missing rotation" {
    const a = std.testing.allocator;
    var fake: Fake = .{ .responses = &.{
        .{ .status = 400, .body = "{\"error\":\"slow_down\"}" },
        .{ .status = 403, .body = "{\"error\":\"access_denied\"}" },
        .{ .status = 200, .body = "{\"access_token\":\"new\",\"expires_in\":5}" },
    } };
    var device: DeviceState = .{ .device_auth_id = try a.dupe(u8, "id"), .user_code = try a.dupe(u8, "code"), .interval_ms = 1000, .expires_at_ms = 9000 };
    defer device.deinit(a);
    try std.testing.expect((try pollWith(fake.transport(), a, std.testing.io, &device, null, 5000)) == .slow_down);
    try std.testing.expectError(error.DeviceDenied, pollWith(fake.transport(), a, std.testing.io, &device, null, 5000));
    try std.testing.expectError(error.InvalidResponse, refreshWith(fake.transport(), a, std.testing.io, "old", null, 5000));
}
test "account routing claim and form encoding" {
    const a = std.testing.allocator;
    const id = try accountId(a, "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWJjIn19.sig");
    defer wipeFree(a, id);
    try std.testing.expectEqualStrings("abc", id);
    const form = try formEncode(a, &.{.{ "x", "a+b c" }});
    defer wipeFree(a, form);
    try std.testing.expectEqualStrings("x=a%2Bb+c", form);
}
