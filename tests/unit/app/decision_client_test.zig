test "decision diagnostics early failure is count zero and route remains lazy" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","reasoning_effort":"high","providers":{"main":{"base_url":"http://main.invalid/v1","models":{"chat":{"context_tokens":32768,"protocol":"chat"}}},"judge":{"base_url":"http://judge.invalid/v1","models":{"mini":{"context_tokens":16384,"protocol":"responses"}}}}},"decision":{"model":"judge/mini"}}
    );
    const optional = parsed.value.decision;
    parsed.value.decision = null;
    try std.testing.expect(try Client.create(a, std.testing.io, parsed.value, &env) == null);
    parsed.value.decision = optional;
    const client = (try Client.create(a, std.testing.io, parsed.value, &env)).?;
    defer client.deinit();
    cfg.release(&parsed);
    try std.testing.expect(client.resolved == null and client.calls == 0);
    try std.testing.expectEqualStrings("judge/mini", client.source.value.decision.?.model);
    try std.testing.expect(client.source.value.model.reasoning_effort == null);
    const Capture = struct {
        records: [4]diag.Record = undefined,
        len: usize = 0,
        fn next(_: ?*anyopaque) u64 {
            return 1;
        }
        fn emit(raw: ?*anyopaque, record: diag.Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.records[self.len] = record;
            self.len += 1;
        }
    };
    var events: Capture = .{};
    client.diagnostics = .{ .context = &events, .emit_fn = Capture.emit, .next_fn = Capture.next };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cancel = p.Cancellation{};
    try std.testing.expectError(error.DecisionUnavailable, client.service().decide(arena.allocator(), .{ .command = .{ .command = "printf fixture" } }, &cancel));
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(?u32, 0), events.records[1].count);
    try std.testing.expectEqual(diag.Result.failed, events.records[1].result.?);
    try std.testing.expect(events.records[1].decision_failure != null);
    cancel.cancel();
    try std.testing.expectError(error.Canceled, client.service().decide(arena.allocator(), .{ .command = .{ .command = "printf fixture" } }, &cancel));
}
test "decision diagnostics fake attempts decode failure and clone sink isolation" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://unused.invalid/v1","api_key":"fake-owned-key","models":{"main":{"context_tokens":32768,"protocol":"chat"},"judge":{"context_tokens":32768,"protocol":"chat"}}}}},"decision":{"model":"p/judge"},"limits":{"request_timeout_ms":4321}}
    );
    defer cfg.release(&parsed);
    const client = (try Client.create(a, std.testing.io, parsed.value, &env)).?;
    defer client.deinit();
    const ready = try client.resolve();
    try std.testing.expectEqualStrings("judge", ready.config.value.model.name);
    try std.testing.expect(ready.config.value.model.reasoning_effort == null);
    try std.testing.expect(parsed.value.limits.low_price_input);
    try std.testing.expect(!ready.config.value.limits.low_price_input);
    try std.testing.expectEqual(@as(u32, 4321), ready.config.value.limits.request_timeout_ms);
    const Fake = struct {
        calls: usize = 0,
        bad: bool = false,
        fn call(raw: *anyopaque, alloc: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqualStrings("judge", request.scope.model);
            try std.testing.expectEqual(@as(usize, 0), request.tools.len);
            try std.testing.expect(request.model_output_tokens == null);
            try std.testing.expectEqualStrings(policy.instruction(.{ .command = .{ .command = "printf fixture" } }), request.system);
            try std.testing.expect(std.mem.indexOf(u8, request.system, policy.ReviewRules.command_risk) != null);
            try std.testing.expect(std.mem.indexOf(u8, request.system, "For command:") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.system, "For refine_outputs:") == null);
            try std.testing.expectEqual(@as(usize, 1), request.messages.len);
            try std.testing.expectEqual(@as(usize, 1), request.messages[0].blocks.len);
            const body = request.messages[0].blocks[0].text;
            const parsed_body = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
            defer parsed_body.deinit();
            const root = parsed_body.value.object;
            try std.testing.expectEqual(@as(usize, 2), root.count());
            try std.testing.expectEqualStrings("command", root.get("operation").?.string);
            const data = root.get("data").?.object;
            try std.testing.expectEqualStrings("printf fixture", data.get("command").?.string);
            if (data.get("risk")) |risk| {
                try std.testing.expectEqual(@as(usize, 2), data.count());
                try std.testing.expect(risk == .null);
            } else try std.testing.expectEqual(@as(usize, 1), data.count());
            for ([_][]const u8{ "timeout", "timing", "deadline", "milliseconds" }) |word| {
                try std.testing.expect(std.mem.indexOf(u8, body, word) == null);
                try std.testing.expect(std.mem.indexOf(u8, request.system, word) == null);
            }
            return .{ .success = .{ .message = try p.textMessage(alloc, .assistant, if (self.bad) "{\"ask\":\"invalid\"}" else "{\"ask\":true}"), .usage = .{ .input_tokens = 100, .output_tokens = 5 }, .finish = .stop } };
        }
    };
    var fake = Fake{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const input: policy.Input = .{ .command = .{ .command = "printf fixture" } };
    var cancel = p.Cancellation{};
    const Capture = struct {
        records: [8]diag.Record = undefined,
        len: usize = 0,
        fn next(_: ?*anyopaque) u64 {
            return 42;
        }
        fn emit(raw: ?*anyopaque, record: diag.Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.records[self.len] = record;
            self.len += 1;
        }
    };
    var capture: Capture = .{};
    const sink: diag.Sink = .{ .context = &capture, .emit_fn = Capture.emit, .next_fn = Capture.next };
    client.diagnostics = sink;
    const child = try client.clone();
    defer child.deinit();
    try std.testing.expectEqual(@as(u64, 0), child.diagnostics.next());
    var span = diag.Span.start(sink, std.testing.io, .{ .stage = .decision_request, .count = 0 });
    const result = try client.callWithSpan(arena.allocator(), ready.config.value, .{ .context = &fake, .call_fn = Fake.call }, input, &cancel, &span);
    span.finish(.ok);
    try std.testing.expectEqual(@as(usize, 3), capture.len);
    try std.testing.expectEqual(diag.Phase.point, capture.records[1].phase);
    try std.testing.expectEqual(@as(?u32, 1), capture.records[1].count);
    try std.testing.expectEqual(capture.records[0].span_id, capture.records[1].span_id);
    try std.testing.expect(result.command.ask);
    try std.testing.expectEqual(@as(u64, 1), client.calls);
    try std.testing.expectEqual(@as(?u64, 100), client.last_usage.input_tokens);
    fake.bad = true;
    var bad_span = diag.Span.start(sink, std.testing.io, .{ .stage = .decision_request, .count = 0 });
    const bad = client.callWithSpan(arena.allocator(), ready.config.value, .{ .context = &fake, .call_fn = Fake.call }, input, &cancel, &bad_span);
    if (bad) |_| return error.ExpectedInvalidDecision else |err| bad_span.fail(err);
    try std.testing.expectEqual(diag.Phase.point, capture.records[4].phase);
    try std.testing.expectEqual(diag.Result.failed, capture.records[5].result.?);
    try std.testing.expect(capture.records[5].error_name != null);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}
test "decision client rejects unknown or zero Anthropic capacity before counting calls" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://unused.invalid/v1","api_key":"fake-owned-key","models":{"main":{"context_tokens":32768,"protocol":"chat"},"judge":{"context_tokens":32768,"protocol":"anthropic"}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&parsed);
    for ([_]?u32{ null, 0, 8192 }) |capacity| {
        const client = (try Client.create(a, std.testing.io, parsed.value, &env)).?;
        defer client.deinit();
        var config = (try client.resolve()).config.value;
        config.model.output_tokens = capacity;
        const FakeCapacity = struct {
            calls: usize = 0,
            fn invoke(raw: *anyopaque, alloc: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
                const self: *@This() = @ptrCast(@alignCast(raw));
                self.calls += 1;
                try std.testing.expectEqual(@as(?u32, 8192), request.model_output_tokens);
                const wire = try @import("../llm/anthropic.zig").encode(alloc, request);
                const json = try std.json.parseFromSlice(std.json.Value, alloc, wire, .{});
                defer json.deinit();
                try std.testing.expectEqual(@as(i64, 8192), json.value.object.get("max_tokens").?.integer);
                return .{ .success = .{ .message = try p.textMessage(alloc, .assistant, "{\"ask\":true}"), .finish = .stop, .usage = .{ .input_tokens = 7, .output_tokens = 1 } } };
            }
        };
        var fake: FakeCapacity = .{};
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var cancel: p.Cancellation = .{};
        const outcome = client.call(arena.allocator(), config, .{ .context = &fake, .call_fn = FakeCapacity.invoke }, .{ .command = .{ .command = "printf fixture" } }, &cancel);
        if (capacity == null or capacity.? == 0) {
            try std.testing.expectError(if (capacity == null) error.UnknownModelOutputCapacity else error.InvalidModelOutputCapacity, outcome);
            try std.testing.expectEqual(@as(usize, 0), fake.calls);
            try std.testing.expectEqual(@as(u64, 0), client.calls);
            try std.testing.expect(client.last_usage.input_tokens == null and client.last_http_status == null);
        } else {
            try std.testing.expect((try outcome).command.ask);
            try std.testing.expectEqual(@as(usize, 1), fake.calls);
            try std.testing.expectEqual(@as(u64, 1), client.calls);
            try std.testing.expectEqual(@as(?u64, 7), client.last_usage.input_tokens);
        }
    }
}
test "SystemOne metadata refresh prepares frozen auxiliary transport without rebuilding or sending" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var store = try Store.open(a, std.testing.io, home);
    defer store.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("AUX_KEY", "fake-aux-frozen-key");
    try env.put("CURL_CA_BUNDLE", "/owned/fake-ca.pem");
    var config = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"protocol":"chat","context_tokens":32768}}},"Zen":{"base_url":"https://opencode.ai/zen/v1","api_key_env":"AUX_KEY","models":{"reviewer/raw-id":{}}}}},"decision":{"model":"Zen/reviewer/raw-id"},"proxy":{"address":"127.0.0.1","port":18973,"models":["Zen/reviewer/raw-id"]}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    try std.testing.expect(client.native == null and client.resolved == null);
    const unresolved_clone = try client.clone();
    defer unresolved_clone.deinit();
    try std.testing.expect(unresolved_clone.native == null and unresolved_clone.resolved == null);
    try std.testing.expectError(error.UnknownModelProtocol, client.resolve());
    try std.testing.expect(client.native == null and client.resolved == null);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    // Later external credentials/trust/proxies cannot alter the owned client.
    try env.put("AUX_KEY", "fake-later-key");
    try env.put("CURL_CA_BUNDLE", "bad\nca");
    try env.put("HTTPS_PROXY", "bad\nproxy");
    const invalid_trust = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer invalid_trust.deinit();
    try std.testing.expect(invalid_trust.native == null and invalid_trust.resolved == null);
    const invalid_clone = try invalid_trust.clone();
    defer invalid_clone.deinit();
    try std.testing.expect(invalid_clone.native == null and invalid_clone.resolved == null);
    const listing = try a.create(metadata.Listing);
    defer a.destroy(listing);
    listing.* = try metadata.parseDev(a,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"reviewer/raw-id":{"api":{"url":"https://opencode.ai/inference/systemone/v1"}}}}}
    );
    defer listing.deinit(a);
    const published = try a.create(metadata.Cache);
    defer a.destroy(published);
    published.* = try metadata.commit(&store.root, 0, listing.*);
    defer published.deinit(a);
    // Failed preparation must release the temporary resolved config and remain
    // unpublished/retryable, not leave a native-null ready state behind.
    for (0..2) |_| {
        try std.testing.expectError(error.InvalidProxyEnvironment, invalid_trust.resolve());
        try std.testing.expect(invalid_trust.native == null and invalid_trust.resolved == null);
        try std.testing.expectEqual(@as(u64, 0), invalid_trust.calls);
    }
    try std.testing.expectError(error.InvalidProxyEnvironment, invalid_clone.resolve());
    try std.testing.expect(invalid_clone.native == null and invalid_clone.resolved == null);
    const ready = try client.resolve();
    try std.testing.expectEqual(p.Protocol.systemone, ready.config.value.model.protocol);
    try std.testing.expect(client.native != null and ready.client == null);
    try std.testing.expectEqualStrings("https://opencode.ai/inference/systemone/v1", ready.config.value.provider.base_url);
    try std.testing.expectEqualStrings("reviewer/raw-id", ready.config.value.model.name);
    try std.testing.expectEqualStrings("Zen/reviewer/raw-id", client.source.value.decision.?.model);
    try std.testing.expectEqualStrings("fake-aux-frozen-key", client.key.?);
    try std.testing.expectEqualStrings("/owned/fake-ca.pem", client.native.?.env.get("CURL_CA_BUNDLE").?);
    try std.testing.expect(client.native.?.env.get("AUX_KEY") == null);
    try std.testing.expect(client.native.?.env.get("HTTPS_PROXY") == null);
    try std.testing.expect(client.native.?.explicit_route);
    try std.testing.expectEqualStrings("http://127.0.0.1:18973", client.native.?.proxy_url.?);
    try std.testing.expect(ready == try client.resolve());
    // An unresolved clone resolves independently from the later metadata; a
    // resolved clone preserves the route with its own native owner/config.
    const unresolved_ready = try unresolved_clone.resolve();
    try std.testing.expectEqual(p.Protocol.systemone, unresolved_ready.config.value.model.protocol);
    try std.testing.expect(unresolved_clone.native != null);
    const resolved_clone = try client.clone();
    defer resolved_clone.deinit();
    try std.testing.expect(resolved_clone.resolved != null and resolved_clone.native != null);
    try std.testing.expect(resolved_clone.resolved.? != ready);
    try std.testing.expectEqualStrings("http://127.0.0.1:18973", resolved_clone.native.?.proxy_url.?);
    try std.testing.expect(resolved_clone.native.?.proxy_url.?.ptr != client.native.?.proxy_url.?.ptr);
    try std.testing.expectEqualStrings("/owned/fake-ca.pem", resolved_clone.native.?.env.get("CURL_CA_BUNDLE").?);
    try std.testing.expectEqual(@as(u64, 0), resolved_clone.calls);
    client.native.?.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, client.resolve());
    try std.testing.expectError(error.CleanupFailed, client.checkCleanup());
    try resolved_clone.checkCleanup();
    try std.testing.expect(client.native.?.poisoned);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}
test "SystemOne creation stays lazy without capabilities or key and never passes credential env to curl" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://inert.invalid/v1"},"aux":{"base_url":"https://opencode.ai/inference/systemone/v1","api_key_env":"SYSTEMONE_KEY"}}},"decision":{"model":"aux/native-reviewer"}}
    );
    defer cfg.release(&config);
    const missing = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer missing.deinit();
    try std.testing.expect(missing.resolved == null and missing.native == null);
    var cancel = p.Cancellation{};
    const input: policy.Input = .{ .command = .{ .command = "printf fixture" } };
    try std.testing.expectError(error.DecisionUnavailable, missing.service().decide(a, input, &cancel));
    try std.testing.expectEqual(p.Protocol.systemone, missing.resolved.?.config.value.model.protocol);
    try std.testing.expect(missing.resolved.?.client == null and missing.native != null);
    const diagnostic = missing.last_failure.?;
    try std.testing.expectEqual(policy.Diagnostic.Stage.credentials, diagnostic.stage);
    try std.testing.expectEqual(policy.Diagnostic.Backend.systemone, diagnostic.backend);
    try std.testing.expectEqual(policy.Diagnostic.Operation.command, diagnostic.operation);
    try std.testing.expectEqualStrings("ApiKeyNotFound", diagnostic.causeName());
    try std.testing.expect(diagnostic.http_status == null and diagnostic.transport_exit_code == null);
    const empty = try missing.service().decide(a, .{ .refine_outputs = &.{} }, &cancel);
    policy.freeOutput(a, empty);
    try std.testing.expect(missing.last_failure == null);
    try std.testing.expectEqual(@as(u64, 0), missing.calls);
    try env.put("SYSTEMONE_KEY", "fake-explicit-native-only");
    try env.put("PRIVATE_OTHER_KEY", "fake-must-not-reach-curl");
    const ready = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer ready.deinit();
    try std.testing.expectEqualStrings("fake-explicit-native-only", ready.key.?);
    try std.testing.expect(ready.native == null and ready.resolved == null);
    _ = try ready.resolve();
    try std.testing.expect(ready.native.?.env.get("SYSTEMONE_KEY") == null);
    try std.testing.expect(ready.native.?.env.get("PRIVATE_OTHER_KEY") == null);
    ready.native.?.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, ready.service().decide(a, input, &cancel));
    try std.testing.expectEqual(@as(u64, 0), ready.calls);
    cancel.cancel();
    // Sticky poison also wins when the subsequent caller is already canceled.
    try std.testing.expectError(error.CleanupFailed, ready.service().decide(a, input, &cancel));
    // Ambient proxies never select inference routes, including malformed ones.
    try env.put("HTTPS_PROXY", "bad\nproxy");
    const direct = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer direct.deinit();
    try std.testing.expect(direct.native == null and direct.resolved == null);
    try std.testing.expectError(error.Canceled, direct.service().decide(std.testing.failing_allocator, input, &cancel));
    try std.testing.expect(direct.native == null and direct.resolved == null and direct.calls == 0);
    _ = try direct.resolve();
    try std.testing.expect(direct.native != null and direct.native.?.explicit_route and direct.native.?.proxy_url == null);
    // Invalid explicit trust roots pause auxiliary use, not history/startup.
    try env.put("CURL_CA_BUNDLE", "bad\nca");
    const unavailable = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer unavailable.deinit();
    try std.testing.expect(unavailable.native == null and unavailable.resolved == null);
    var uncanceled = p.Cancellation{};
    try std.testing.expectError(error.DecisionUnavailable, unavailable.service().decide(a, input, &uncanceled));
    try std.testing.expectEqual(policy.Diagnostic.Stage.resolve, unavailable.last_failure.?.stage);
    try std.testing.expectEqualStrings("InvalidProxyEnvironment", unavailable.last_failure.?.causeName());
    try std.testing.expect(unavailable.native == null and unavailable.resolved == null and unavailable.calls == 0);
}
test "decision creation and unresolved clone allocate no metadata cache" {
    const Gate = struct {
        cache_attempts: usize = 0,
        deny: bool = true,
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (len == @sizeOf(metadata.Cache)) {
                self.cache_attempts += 1;
                if (self.deny) return null;
            }
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var gate: Gate = .{};
    const a: std.mem.Allocator = .{ .ptr = &gate, .vtable = &.{ .alloc = Gate.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = Gate.free } };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // This is only a frozen string: no directory lookup occurs at creation.
    try env.put("HOME", "/synthetic/never-opened-decision-home");
    var config = try cfg.parse(std.testing.allocator,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key":"fake-key","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"systemone"}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    const child = try client.clone();
    defer child.deinit();
    try std.testing.expectEqual(@as(usize, 0), gate.cache_attempts);
    try std.testing.expect(client.native == null and client.resolved == null and child.native == null and child.resolved == null);
    // resolve allocates its cache before loadCache could open the directory.
    try std.testing.expectError(error.OutOfMemory, client.resolve());
    try std.testing.expectEqual(@as(usize, 1), gate.cache_attempts);
    try std.testing.expect(client.native == null and client.resolved == null);
    gate.deny = false;
    const ready = try client.resolve();
    try std.testing.expect(client.native != null and client.resolved.? == ready);
    try std.testing.expectEqual(@as(usize, 2), gate.cache_attempts);
    try std.testing.expect(try client.resolve() == ready);
    try std.testing.expectEqual(@as(usize, 2), gate.cache_attempts);
}
test "native no-op grows payloads validates identities copies and frees after cancellation" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key":"fake-key","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"systemone"}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    const Capture = struct {
        records: [4]diag.Record = undefined,
        len: usize = 0,
        fn next(_: ?*anyopaque) u64 {
            return 9;
        }
        fn emit(raw: ?*anyopaque, record: diag.Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.records[self.len] = record;
            self.len += 1;
        }
    };
    var capture: Capture = .{};
    client.diagnostics = .{ .context = &capture, .next_fn = Capture.next, .emit_fn = Capture.emit };
    const items = [_]policy.RefineItem{
        .{ .id = "original-a", .text = "诊断\ntick\nerror" },
        .{ .id = "original-b", .text = "```\ntick\ntick\ntick\n```" },
    };
    var cancel: p.Cancellation = .{};
    const output = try client.service().decide(a, .{ .refine_outputs = &items }, &cancel);
    defer policy.freeOutput(a, output);
    for (items, output.refine_outputs) |item, copy| {
        try std.testing.expectEqualStrings(item.id, copy.id);
        try std.testing.expectEqualStrings(item.text, copy.text);
        try std.testing.expect(item.id.ptr != copy.id.ptr and item.text.ptr != copy.text.ptr);
    }
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    try std.testing.expect(client.native != null and client.resolved != null and client.last_failure == null and client.last_http_status == null);
    inline for (@typeInfo(p.Usage).@"struct".field_names) |name| try std.testing.expect(@field(client.last_usage, name) == null);
    try std.testing.expectEqual(@as(usize, 2), capture.len);
    try std.testing.expectEqual(@as(?u32, 0), capture.records[1].count);
    try std.testing.expectEqual(diag.Result.ok, capture.records[1].result.?);
    try std.testing.expectEqual(policy.Diagnostic.Backend.systemone, capture.records[1].backend.?);
    client.diagnostics = .{};

    const bad_inputs = [_]policy.Input{
        .{ .refine_outputs = &.{ .{ .id = "same", .text = "x" }, .{ .id = "same", .text = "y" } } },
        .{ .refine_outputs = &.{.{ .id = "", .text = "x" }} },
        .{ .refine_outputs = &.{.{ .id = "id", .text = "\xff" }} },
        .{ .refine_outputs = &.{.{ .id = "\xff", .text = "valid" }} },
        .{ .refine_outputs = &.{.{ .id = "id", .text = "" }} },
    };
    for (bad_inputs) |input| try std.testing.expectError(error.InvalidDecisionInput, client.service().decide(a, input, &cancel));
    const large = try a.alloc(u8, 65537);
    defer a.free(large);
    @memset(large, 'x');
    const exact = try client.service().decide(a, .{ .refine_outputs = &.{.{ .id = "long", .text = large }} }, &cancel);
    defer policy.freeOutput(a, exact);
    try std.testing.expectEqualStrings(large, exact.refine_outputs[0].text);
    var many: [9]policy.RefineItem = undefined;
    var ids: [9][1]u8 = undefined;
    for (&many, &ids, 0..) |*item, *id, i| {
        id[0] = @intCast('0' + i);
        item.* = .{ .id = id, .text = "unchanged" };
    }
    const many_output = try client.service().decide(a, .{ .refine_outputs = &many }, &cancel);
    defer policy.freeOutput(a, many_output);
    try std.testing.expectEqual(@as(usize, 9), many_output.refine_outputs.len);
    const escaped: [8200]u8 = @splat('"');
    const escaped_output = try client.service().decide(a, .{ .refine_outputs = &.{.{ .id = "escaped", .text = &escaped }} }, &cancel);
    defer policy.freeOutput(a, escaped_output);
    try std.testing.expectEqualStrings(&escaped, escaped_output.refine_outputs[0].text);
    try std.testing.expectEqual(@as(u64, 0), client.calls);

    const Allocation = struct {
        fn run(output_allocator: std.mem.Allocator, subject: *Client) !void {
            var token: p.Cancellation = .{};
            const result = try subject.service().decide(output_allocator, .{ .refine_outputs = &.{
                .{ .id = "owned-a", .text = "tick\nerror" },
                .{ .id = "owned-b", .text = "```\ntick\ntick\ntick" },
            } }, &token);
            policy.freeOutput(output_allocator, result);
        }
    };
    var stable_vtable = a.vtable.*;
    stable_vtable.resize = std.mem.Allocator.noResize;
    stable_vtable.remap = std.mem.Allocator.noRemap;
    const stable: std.mem.Allocator = .{ .ptr = a.ptr, .vtable = &stable_vtable };
    try std.testing.checkAllAllocationFailures(stable, Allocation.run, .{client});
    try std.testing.expectEqual(@as(u64, 0), client.calls);

    // Trigger cancellation precisely while allocating the returned text.
    const text = "diagnostic text unique to cancellation fixture";
    const CancelAllocator = struct {
        cancel: *p.Cancellation,
        triggered: bool = false,
        matching_frees: usize = 0,
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = std.testing.allocator.rawAlloc(len, alignment, ra);
            if (result != null and len == text.len) {
                self.triggered = true;
                self.cancel.cancel();
            }
            return result;
        }
        fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (bytes.len == text.len) self.matching_frees += 1;
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var during: p.Cancellation = .{};
    var observer: CancelAllocator = .{ .cancel = &during };
    const observed: std.mem.Allocator = .{ .ptr = &observer, .vtable = &.{ .alloc = CancelAllocator.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = CancelAllocator.free } };
    try std.testing.expectError(error.Canceled, client.service().decide(observed, .{ .refine_outputs = &.{.{ .id = "canceled-copy", .text = text }} }, &during));
    try std.testing.expect(observer.triggered and observer.matching_frees == 1);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}
test "native no-op does not bypass transport-only key checks" {
    const a = std.testing.allocator;
    try std.testing.expect(nativeShortcutSafe("http://fixture.invalid/systemone", "key", "{}"));
    try std.testing.expect(!nativeShortcutSafe("http://fixture.invalid/systemone", "bad\xff", "{}"));
    try std.testing.expect(!nativeShortcutSafe("http://fixture.invalid/systemone", "bad\xc2\x85", "{}"));
    const long_endpoint: [8193]u8 = @splat('x');
    try std.testing.expect(!nativeShortcutSafe(&long_endpoint, "key", "{}"));
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("AUX_KEY", "bad\xff");
    var config = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key_env":"AUX_KEY","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"systemone"}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    var cancel: p.Cancellation = .{};
    try std.testing.expectError(error.InvalidKey, client.service().decide(a, .{ .refine_outputs = &.{.{ .id = "id", .text = "diagnostic" }} }, &cancel));
    try std.testing.expectEqual(@as(u64, 1), client.calls);
    try std.testing.expectEqual(policy.Diagnostic.Stage.transport, client.last_failure.?.stage);
}
test "unresolved native poison and cleanup retain the owner" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key":"fake-key","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"systemone"}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    var destroyed = false;
    defer if (!destroyed) client.deinit();
    client.native = try native_http.Client.initRouted(a, std.testing.io, &env, null);
    client.native.?.poisoned = true;
    client.native.?.unreaped_pid = 1; // Invalid sentinel, never an actual process.
    var cancel: p.Cancellation = .{};
    cancel.cancel();
    try std.testing.expectError(error.CleanupFailed, client.service().decide(a, .{ .refine_outputs = &.{.{ .id = "id", .text = "diagnostic" }} }, &cancel));
    try std.testing.expectError(error.CleanupFailed, client.resolve());
    try std.testing.expectError(error.CleanupFailed, client.clone());
    try std.testing.expect(client.native.?.poisoned and client.resolved == null and client.calls == 0);
    try std.testing.expectError(error.CleanupFailed, client.cleanupForClose());
    try std.testing.expect(client.native.?.unreaped_pid == 1 and client.key != null and client.resolved == null);
    client.native.?.unreaped_pid = null;
    try client.cleanupForClose();
    destroyed = true;
}
test "generative refinement still invokes the model for a native no-op" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://fixture.invalid/v1","api_key":"fake-key","models":{"main":{"protocol":"chat","context_tokens":32768},"judge":{"protocol":"chat","context_tokens":32768}}}}},"decision":{"model":"p/judge"}}
    );
    defer cfg.release(&config);
    const client = (try Client.create(a, std.testing.io, config.value, &env)).?;
    defer client.deinit();
    const ready = try client.resolve();
    const Fake = struct {
        calls: usize = 0,
        fn invoke(raw: *anyopaque, allocator: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .success = .{ .message = try p.textMessage(allocator, .assistant, "{\"items\":[{\"id\":\"id\",\"text\":\"short\"}]}"), .finish = .stop } };
        }
    };
    var fake: Fake = .{};
    var cancel: p.Cancellation = .{};
    const result = try client.call(a, ready.config.value, .{ .context = &fake, .call_fn = Fake.invoke }, .{ .refine_outputs = &.{.{ .id = "id", .text = "long diagnostic" }} }, &cancel);
    defer policy.freeOutput(a, result);
    try std.testing.expectEqualStrings("short", result.refine_outputs[0].text);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(u64, 1), client.calls);
}
test "resolved decision clone rebuilds a private client and keeps the frozen config" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CURL_CA_BUNDLE", "/owned/decision-ca.pem");
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"context_tokens":32768,"protocol":"chat"}}},"judge":{"base_url":"http://judge.invalid/v1","api_key":"fake-judge-key","models":{"mini":{"context_tokens":16384,"protocol":"chat"}}}}},"decision":{"model":"judge/mini"}}
    );
    defer cfg.release(&parsed);
    const parent = (try Client.create(a, std.testing.io, parsed.value, &env)).?;
    defer parent.deinit();
    const ready = try parent.resolve();
    try std.testing.expect(ready.client != null);
    parent.calls = 7;
    parent.last_usage.input_tokens = 100;
    const clone = try parent.clone();
    defer clone.deinit();
    try std.testing.expect(clone.resolved != null);
    try std.testing.expect(clone.resolved.?.client != null);
    const parent_http = if (ready.client) |*client| client else unreachable;
    const clone_http = if (clone.resolved.?.client) |*client| client else unreachable;
    try std.testing.expect(&clone_http.http != &parent_http.http);
    try std.testing.expect(&clone_http.request_mutex != &parent_http.request_mutex);
    try std.testing.expect(clone_http.config != parent_http.config);
    try std.testing.expectEqualStrings("mini", clone.resolved.?.config.value.model.name);
    try std.testing.expectEqualStrings("fake-judge-key", clone.key.?);
    try std.testing.expectEqualStrings("/owned/decision-ca.pem", clone.transport_env.get("CURL_CA_BUNDLE").?);
    try std.testing.expectEqual(@as(u64, 0), clone.calls);
    try std.testing.expect(clone.last_usage.input_tokens == null and parent.last_usage.input_tokens == 100);
}
