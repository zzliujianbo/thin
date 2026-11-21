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
        var http: Http = .{ .client = &client, .url = url };
        for ([_]bool{ false, true }) |is_refresh| {
            var job = try Io.concurrent(io, rejectOAuthConnection, .{ io, &server, mode == .bypass });
            defer job.cancel(io) catch {};
            if (is_refresh) {
                try std.testing.expectError(error.TransportFailure, refreshWith(http.transport(), a, io, "synthetic-refresh", null, 3000));
            } else {
                try std.testing.expectError(error.TransportFailure, exchangeWith(http.transport(), a, io, "synthetic-code", "synthetic-verifier", null, 3000));
            }
            // A pre-spawn failure cannot leave this test waiting in accept().
            try job.cancel(io);
        }
    }
}

test "browser PKCE uses fresh verifier and state and registered authorize parameters" {
    const a = std.testing.allocator;
    var first: BrowserAuth = undefined;
    try first.init(std.testing.io);
    defer first.deinit();
    var second: BrowserAuth = undefined;
    try second.init(std.testing.io);
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, &first.state, &second.state));
    try std.testing.expect(!std.mem.eql(u8, &first.verifier, &second.verifier));
    // RFC 7636 Appendix B known-answer pair, independent of production hash/encoding.
    first.verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".*;
    const url = try first.authorizeUrl(a);
    defer wipeFree(a, url);
    const expected = try std.mem.concat(a, u8, &.{
        "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann" ++
            "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid+profile+email+offline_access" ++
            "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=",
        &first.state,
        "&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=thin",
    });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, url);
}

test "callback requires registered literal redirect and unique matching decoded fields" {
    const a = std.testing.allocator;
    const state = "0123456789abcdef0123456789abcdef";
    const flow: BrowserAuth = .{ .state = state.*, .verifier = undefined };
    const prefix = redirect_uri ++ "?";
    const query = "code=x&state=" ++ state;
    const valid = try a.dupe(u8, prefix ++ "scope=openid+profile&st%61te=" ++ state ++ "&%63ode=a%2Bb%26c%3Dd%25");
    defer wipeFree(a, valid);
    try std.testing.expectEqualStrings("a+b&c=d%", try flow.callbackCode(a, valid));
    for ([_][]const u8{
        "x",                                             query,                                                "http://127.0.0.1:1455/auth/callback?" ++ query,  "https://localhost:1455/auth/callback?" ++ query,
        "http://localhost:1456/auth/callback?" ++ query, "http://user@localhost:1455/auth/callback?" ++ query, "http://localhost:1455/auth/callback/?" ++ query, "http://localhost:1455/auth/%63allback?" ++ query,
        prefix ++ "code=a",                              prefix ++ "state=" ++ state,                          prefix ++ "code=&state=" ++ state,                prefix ++ "code=a&state=other",
        prefix ++ query ++ "&%73tate=" ++ state,         prefix ++ query ++ "&cod%65=x",                       prefix ++ query ++ "&x=1&x=2",                    prefix ++ query ++ "#",
        prefix ++ query ++ "#fragment",                  prefix ++ query ++ "&error=access_denied",            prefix ++ query ++ "&x=%",                        prefix ++ query ++ "&x=%0",
        prefix ++ query ++ "&x=%GG",                     prefix ++ query ++ "&%xx=x",                          prefix ++ query ++ "&x=%00",                      prefix ++ query ++ "&x=%0d%0a",
        prefix ++ query ++ "&x=%7f",                     prefix ++ query ++ "\n",                              prefix ++ query ++ "&",                           prefix ++ query ++ "&bare",
        prefix ++ query ++ "&=missing",                  prefix ++ query ++ " ",
    }) |bad| {
        const owned = try a.dupe(u8, bad);
        defer wipeFree(a, owned);
        try std.testing.expectError(error.InvalidOAuthCallback, flow.callbackCode(a, owned));
    }
    var limit: [max_callback_bytes + 1]u8 = @splat('x');
    const start = prefix ++ "state=" ++ state ++ "&code=";
    @memcpy(limit[0..start.len], start);
    try std.testing.expectError(error.InvalidOAuthCallback, flow.callbackCode(a, &limit));
    try std.testing.expectEqual(max_callback_bytes - start.len, (try flow.callbackCode(a, limit[0..max_callback_bytes])).len);
}

test "exchange form binds decoded code verifier and exact redirect in a single POST" {
    const a = std.testing.allocator;
    var fake: Fake = .{
        .expected_form = "grant_type=authorization_code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code=a%2Bb%26c%3Dd%25&code_verifier=v_-.&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
        .responses = &.{.{ .status = 200, .body = "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":60}" }},
    };
    var canceled: p.Cancellation = .{};
    canceled.cancel();
    try std.testing.expectError(error.Canceled, exchangeWith(fake.transport(), a, std.testing.io, "a+b&c=d%", "v_-.", &canceled, 5000));
    try std.testing.expectEqual(@as(usize, 0), fake.index);
    var result = try exchangeWith(fake.transport(), a, std.testing.io, "a+b&c=d%", "v_-.", null, 5000);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fake.index);
    try std.testing.expectEqual(@as(i64, 61000), result.expires_at_ms);
    try std.testing.expectEqualStrings("refresh", result.refresh_token);
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
test "refresh rejects missing rotation" {
    const a = std.testing.allocator;
    var fake: Fake = .{ .responses = &.{.{ .status = 200, .body = "{\"access_token\":\"new\",\"expires_in\":5}" }} };
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
