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
