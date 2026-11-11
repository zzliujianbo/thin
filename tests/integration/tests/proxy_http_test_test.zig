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
test "proxy: actual SystemOne and generic judge identities independent of primary and environment" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    const a = t.allocator;
    for ([_][]const u8{ "systemone", "chat" }) |decision_protocol| {
        for ([_]bool{ false, true }) |listed| {
            var env = try transportEnv(a, true);
            defer env.deinit();
            if (!listed) {
                try env.put("NO_PROXY", "");
                try env.put("no_proxy", "");
            }
            const base = if (listed) try origin("THIN_PROXY_HTTPS", "https", "127.0.0.1") else try origin("THIN_PROXY_HTTP", "http", "127.0.0.1");
            const text = try std.fmt.allocPrint(a,
                \\{{"llm":{{"default":"main/chat","providers":{{"main":{{"base_url":"{s}/unused","api_key":"fake-primary","models":{{"chat":{{"protocol":"chat","context_tokens":32768}}}}}},"aux":{{"base_url":"{s}/{s}-{s}","api_key":"fake-proxy-key","models":{{"jev":{{"protocol":"{s}","context_tokens":32768}}}}}}}}}},"decision":{{"model":"aux/jev"}},"limits":{{"request_timeout_ms":3000}},"proxy":{{"address":"127.0.0.1","port":{d},"models":["{s}"]}}}}
            , .{ try origin("THIN_PROXY_HTTP", "http", "127.0.0.1"), base, if (std.mem.eql(u8, decision_protocol, "systemone")) "decision" else "judge", if (listed) "listed" else "direct", decision_protocol, try proxyPort(false), if (listed) "aux/jev" else "main/chat" });
            defer a.free(text);
            var parsed = try cfg.parse(a, text);
            defer cfg.release(&parsed);
            const client = (try DecisionClient.create(a, backend.io(), parsed.value, &env)) orelse return error.MissingDecisionClient;
            defer client.deinit();
            var cancellation = p.Cancellation{};
            const out = try client.service().decide(a, .{ .command = .{ .command = "printf fixture" } }, &cancellation);
            defer decision.freeOutput(a, out);
            try t.expect(out.command.ask);
            try t.expect(client.calls == 1);
            const resolved = client.resolved orelse return error.MissingDecisionResolution;
            try t.expect((resolved.client == null) == std.mem.eql(u8, decision_protocol, "systemone"));
            try t.expect((resolved.config.value.model.protocol == .systemone) == std.mem.eql(u8, decision_protocol, "systemone"));
            try t.expectEqual(@as(u32, 3000), resolved.config.value.limits.request_timeout_ms);
            try t.expectEqualStrings("main/chat", client.source.value.registry.?.default);
        }
    }
}
