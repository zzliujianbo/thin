test "proxy: Chat Responses Anthropic headers scope summary and delta-tail handshake" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try transportEnv(t.allocator, true);
    defer env.deinit();
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        var c = try config(a, @tagName(protocol), protocol, false, false);
        const before = c.provider.base_url;
        var client = try Client.initWithEnv(t.allocator, backend.io(), &c, "fake-proxy-key", &env);
        defer client.deinit();
        var rec = Recorder{ .io = backend.io(), .marker = if (protocol == .chat) try envValue("THIN_PROXY_DELTA_MARKER") else null };
        var req = request(c, protocol);
        const out = try successful(try client.model().call(a, req, rec.sink()));
        try t.expect(out.finish == .stop and rec.text == 2);
        try t.expectEqualStrings(before, c.provider.base_url);
        try t.expectEqualStrings(before, req.scope.connection);
        try t.expectEqualStrings("raw/id", req.scope.model);
        req.purpose = .summary;
        _ = try successful(try client.model().call(a, req, .{}));
        // Proxy selection never changes canonical replay scope validation.
        req.scope.connection = "http://127.0.0.1:1/not-the-scope";
        try t.expectError(error.ReplayScopeMismatch, client.model().call(a, req, .{}));
    }
}
test "proxy: exact alias isolation and native direct ignores environment proxies" {
    var backend = Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try transportEnv(t.allocator, true);
    defer env.deinit();
    // An empty bypass list is essential here: a buggy environment-driven
    // transport must reach the rejecting proxy rather than bypass it.
    try env.put("NO_PROXY", "");
    try env.put("no_proxy", "");
    var c = try config(a, "alias-direct", .chat, true, false);
    // Same exact endpoint/raw-ID, only the alias changes selection.
    try t.expect(c.proxyFor("listed", "raw/id") != null);
    try t.expect(c.proxyFor("other", "raw/id") == null);
    try t.expect(c.proxyFor("listed", "raw/id-suffix") == null);
    try t.expect(c.proxyFor(null, "raw/id") == null);
    var client = try Client.initWithEnv(t.allocator, backend.io(), &c, "fake-proxy-key", &env);
    defer client.deinit();
    _ = try successful(try client.model().call(a, request(c, .chat), .{}));
    // A listed alias with the *same* HTTP endpoint must use the forward proxy,
    // which rejects this owned route. It cannot silently go direct.
    c.selected_provider = "listed";
    var listed = try Client.initWithEnv(t.allocator, backend.io(), &c, "fake-proxy-key", &env);
    defer listed.deinit();
    try t.expect((try listed.model().call(a, request(c, .chat), .{})) == .failure);
}
test "proxy: absent config selects uppercase environment proxy by scheme and honors NO_PROXY" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const proxy = try origin("THIN_ENV_PROXY", "http", "127.0.0.1");
    const down = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{try proxyPort(true)});
    const Case = struct { name: []const u8, http: bool = false, bypass: bool = false, wrong_ca: bool = false, mismatch: bool = false };
    for ([_]Case{
        .{ .name = "env-http", .http = true },
        .{ .name = "env-bypass", .http = true, .bypass = true },
        .{ .name = "env-https" },
        .{ .name = "env-wrong-ca", .wrong_ca = true },
        .{ .name = "env-hostname", .mismatch = true },
    }) |case| {
        var c = try config(a, case.name, .chat, case.http, case.mismatch);
        c.proxy = null;
        var env = std.process.Environ.Map.init(t.allocator);
        defer env.deinit();
        try env.put("HOME", try envValue("HOME"));
        try env.put("CURL_CA_BUNDLE", try envValue(if (case.wrong_ca) "THIN_PROXY_WRONG_CA" else "THIN_PROXY_CA"));
        // Only the matching uppercase variable can reach the recording proxy.
        try env.put("HTTP_PROXY", if (case.http) proxy else down);
        try env.put("HTTPS_PROXY", if (case.http) down else proxy);
        try env.put("NO_PROXY", if (case.bypass) "127.0.0.1" else "127.0.0.2");
        var client = try Client.initWithEnv(t.allocator, backend.io(), &c, "fake-proxy-key", &env);
        defer client.deinit();
        const out = try client.model().call(a, request(c, .chat), .{});
        if (case.wrong_ca or case.mismatch) {
            try t.expect(out == .failure);
        } else {
            try t.expect((try successful(out)).finish == .stop);
        }
    }
}
test "proxy: down wrong CA hostname fail closed and partial streams never succeed or replay" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "down", "wrong-ca", "hostname", "disconnect", "timeout", "cancel" }) |scenario| {
        const down = std.mem.eql(u8, scenario, "down");
        const timeout = std.mem.eql(u8, scenario, "timeout");
        const canceling = std.mem.eql(u8, scenario, "cancel");
        var c = try config(a, scenario, .chat, false, std.mem.eql(u8, scenario, "hostname"));
        if (down) c.proxy.?.port = try proxyPort(true);
        if (timeout) c.limits.request_timeout_ms = 350;
        var env = try transportEnv(t.allocator, !std.mem.eql(u8, scenario, "wrong-ca"));
        defer env.deinit();
        var client = try Client.initWithEnv(t.allocator, backend.io(), &c, "fake-proxy-key", &env);
        defer client.deinit();
        var cancellation = p.Cancellation{};
        var req = request(c, .chat);
        req.cancellation = &cancellation;
        // Cancel only inside a delta callback: proves origin arrival, not a timer.
        var rec = Recorder{ .io = backend.io(), .cancel = if (canceling) &cancellation else null };
        const out = try client.model().call(a, req, rec.sink());
        try t.expect(out == .failure);
        if (timeout) try t.expect(out.failure.kind == .timeout);
        if (canceling) try t.expect(out.failure.kind == .canceled and rec.text > 0);
        if (std.mem.eql(u8, scenario, "disconnect") or timeout) try t.expect(rec.tool > 0);
    }
}
