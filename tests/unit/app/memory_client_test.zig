test "memory client frozen wire limits are independent of decoded JSON and preserve smaller policy" {
    const a = std.testing.allocator;
    var config = testConfig();
    config.limits.max_response_bytes = 48 * 1024;
    config.limits.max_event_bytes = 24 * 1024;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("SYNTHETIC_MEMORY_KEY", "own-key");
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    try std.testing.expectEqual(config.limits.max_response_bytes, client.source.value.limits.max_response_bytes);
    try std.testing.expectEqual(config.limits.max_event_bytes, client.source.value.limits.max_event_bytes);
    try std.testing.expectEqual(config.limits.max_response_bytes, client.transport.?.config.limits.max_response_bytes);
    try std.testing.expectEqual(config.limits.max_event_bytes, client.transport.?.config.limits.max_event_bytes);
    try std.testing.expectEqual(config.model.output_tokens, client.source.value.model.output_tokens);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}
test "memory client zero startup owns frozen config key and independent route OOM" {
    try creationCase(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, creationCase, .{});
}
test "memory client unrequested proxy transport closes cleanly without a child" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("SYNTHETIC_MEMORY_KEY", "own-key");
    var config = testConfig();
    const models = [_][]const u8{"primary/primary/model"};
    config.proxy = .{ .address = "proxy.invalid", .port = 8888, .models = &models };
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    try std.testing.expect(client.transport != null);
    const proxy = if (client.transport) |*transport| if (transport.proxy_http) |*value| value else return error.TestUnexpectedResult else return error.TestUnexpectedResult;
    try std.testing.expect(proxy.unreaped_pid == null and !proxy.poisoned);
}
test "memory request diagnostics preserve success failure decode and cancellation" {
    const Capture = struct {
        records: [32]diag.Record = undefined,
        len: usize = 0,
        seq: u64 = 0,
        fn next(raw: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.seq += 1;
            return self.seq;
        }
        fn emit(raw: ?*anyopaque, record: diag.Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.records[self.len] = record;
            self.len += 1;
        }
    };
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const client = try Client.create(a, std.testing.io, testConfig(), &env);
    defer client.deinit();
    var capture: Capture = .{};
    client.diagnostics = .{ .context = &capture, .emit_fn = Capture.emit, .next_fn = Capture.next };
    var cancel: p.Cancellation = .{};
    try std.testing.expectError(error.MemoryUnavailable, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    var fake: Fake = .{ .client = client };
    client.model_override = .{ .context = &fake, .call_fn = Fake.invoke };
    const items = try Client.extract(client, a, fixture, &cancel);
    defer codec.freeCandidates(a, items);
    try std.testing.expectEqual(diag.Result.ok, capture.records[1].result.?);
    fake.mode = .failure;
    try std.testing.expectError(error.MemoryUnavailable, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(@as(?u16, 429), capture.records[3].http_status);
    try std.testing.expectEqual(diag.Result.failed, capture.records[3].result.?);
    fake.mode = .partial;
    try std.testing.expectError(error.InvalidMemoryOutput, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqualStrings("InvalidMemoryOutput", capture.records[5].error_name.?.name());
    fake.mode = .thrown;
    try std.testing.expectError(error.CleanupFailed, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqualStrings("CleanupFailed", capture.records[7].error_name.?.name());
    fake.mode = .cancel;
    try std.testing.expectError(error.Canceled, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(diag.Result.canceled, capture.records[9].result.?);
    try std.testing.expectEqual(@as(usize, 10), capture.len);
    for (0..5) |i| {
        try std.testing.expectEqual(diag.Phase.begin, capture.records[2 * i].phase);
        try std.testing.expectEqual(diag.Phase.end, capture.records[2 * i + 1].phase);
        try std.testing.expectEqual(capture.records[2 * i].span_id, capture.records[2 * i + 1].span_id);
        try std.testing.expectEqual(@as(?u32, 1), capture.records[2 * i + 1].count);
    }
}
test "memory client fake normal request preserves usage cancellation no tools no partial batch" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const client = try Client.create(a, std.testing.io, testConfig(), &env);
    defer client.deinit();
    try std.testing.expect(client.key == null and client.transport == null);
    var fake: Fake = .{ .client = client };
    client.model_override = .{ .context = &fake, .call_fn = Fake.invoke };
    var cancel: p.Cancellation = .{};
    const items = try Client.extract(client, a, fixture, &cancel);
    defer codec.freeCandidates(a, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
    try std.testing.expectEqual(@as(?u64, 17), client.last_usage.input_tokens);
    fake.mode = .failure;
    try std.testing.expectError(error.MemoryUnavailable, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(@as(?u16, 429), client.last_http_status);
    try std.testing.expectEqual(@as(?u64, 3), client.last_usage.output_tokens);
    for ([_]@TypeOf(fake.mode){ .tool, .partial }) |mode| {
        fake.mode = mode;
        try std.testing.expectError(error.InvalidMemoryOutput, Client.extract(client, a, fixture, &cancel));
    }
    fake.mode = .replay;
    fake.body_override = "{\"items\":[{\"category\":\"preferences\",\"topic\":\"language\",\"content\":\"Prefer Zig.\"}]}";
    const ignored_replay = try Client.extract(client, a, fixture, &cancel);
    defer codec.freeCandidates(a, ignored_replay);
    try std.testing.expectEqual(@as(usize, 1), ignored_replay.len);
    try std.testing.expectEqual(knowledge.Category.preferences, ignored_replay[0].category);
    try std.testing.expectEqualStrings("language", ignored_replay[0].topic);
    try std.testing.expectEqualStrings("Prefer Zig.", ignored_replay[0].content);
    try std.testing.expectEqual(@as(?[]const u8, null), ignored_replay[0].expected_version);
    try std.testing.expectEqual(@as(?u64, null), ignored_replay[0].expires_at_ms);
    fake.body_override = null;
    fake.mode = .oversized;
    const large = try Client.extract(client, a, fixture, &cancel);
    defer codec.freeCandidates(a, large);
    try std.testing.expectEqual(@as(usize, 0), large.len);
    fake.mode = .reasoning;
    const empty = try Client.extract(client, a, fixture, &cancel);
    defer codec.freeCandidates(a, empty);
    fake.mode = .thrown;
    try std.testing.expectError(error.CleanupFailed, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(@as(?u64, 17), client.last_usage.input_tokens);
    fake.mode = .partial_usage;
    const partial_usage = try Client.extract(client, a, fixture, &cancel);
    defer codec.freeCandidates(a, partial_usage);
    try std.testing.expectEqual(@as(?u64, 17), client.last_usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), client.last_usage.output_tokens);
    fake.mode = .canceled_cleanup;
    try std.testing.expectError(error.CleanupFailed, Client.extract(client, a, fixture, &cancel));
    cancel = .{};
    fake.mode = .cancel;
    try std.testing.expectError(error.Canceled, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(@as(?u64, 17), client.last_usage.input_tokens);
    const prior = client.calls;
    try std.testing.expectError(error.Canceled, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(prior, client.calls);
}
test "memory client rejects unknown or zero Anthropic capacity before counting calls" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for ([_]?u32{ null, 0, 8192 }) |capacity| {
        const client = try Client.create(a, std.testing.io, testConfig(), &env);
        defer client.deinit();
        client.source.value.model.protocol = .anthropic;
        client.source.value.model.output_tokens = capacity;
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
                return .{ .success = .{ .message = try p.textMessage(alloc, .assistant, "{\"items\":[]}"), .finish = .stop, .usage = .{ .input_tokens = 7, .output_tokens = 1 } } };
            }
        };
        var fake: FakeCapacity = .{};
        client.model_override = .{ .context = &fake, .call_fn = FakeCapacity.invoke };
        var cancel: p.Cancellation = .{};
        const outcome = Client.extract(client, a, fixture, &cancel);
        if (capacity == null or capacity.? == 0) {
            try std.testing.expectError(if (capacity == null) error.UnknownModelOutputCapacity else error.InvalidModelOutputCapacity, outcome);
            try std.testing.expectEqual(@as(usize, 0), fake.calls);
            try std.testing.expectEqual(@as(u64, 0), client.calls);
            try std.testing.expect(client.last_usage.input_tokens == null and client.last_http_status == null);
        } else {
            const items = try outcome;
            defer codec.freeCandidates(a, items);
            try std.testing.expectEqual(@as(usize, 0), items.len);
            try std.testing.expectEqual(@as(usize, 1), fake.calls);
            try std.testing.expectEqual(@as(u64, 1), client.calls);
            try std.testing.expectEqual(@as(?u64, 7), client.last_usage.input_tokens);
        }
    }
}
test "memory client refuses unresolved native absent credentials and input policy before calls" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const client = try Client.create(a, std.testing.io, testConfig(), &env);
    defer client.deinit();
    var cancel: p.Cancellation = .{};
    try std.testing.expectError(error.MemoryUnavailable, Client.extract(client, a, fixture, &cancel));
    client.source.value.model.protocol = .auto;
    try std.testing.expectError(error.UnknownModelProtocol, Client.extract(client, a, fixture, &cancel));
    client.source.value.model.protocol = .systemone;
    try std.testing.expectError(error.UnsupportedProtocol, Client.extract(client, a, fixture, &cancel));
    client.source.value.model.protocol = .chat;
    var fake: Fake = .{ .client = client };
    client.model_override = .{ .context = &fake, .call_fn = Fake.invoke };
    client.source.value.model.input_price_flat_limit = null;
    try std.testing.expectError(error.UnknownInputPriceThreshold, Client.extract(client, a, fixture, &cancel));
    client.source.value.model.input_price_flat_limit = 1;
    try std.testing.expectError(error.InputBudgetExceeded, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}
test "memory client complete request exact input boundary without output clamp" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const client = try Client.create(a, std.testing.io, testConfig(), &env);
    defer client.deinit();
    var fake: Fake = .{ .client = client };
    client.model_override = .{ .context = &fake, .call_fn = Fake.invoke };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = try codec.encode(arena.allocator(), fixture);
    const messages = [_]p.Message{try p.textMessage(arena.allocator(), .user, body)};
    const estimated: u32 = @intCast(context.rawTokens(codec.instruction, &.{}, &messages));
    client.source.value.limits.max_input_tokens = estimated + client.source.value.limits.input_margin_tokens;
    client.source.value.model.context_tokens = estimated + client.source.value.limits.safety_tokens + 1;
    var cancel: p.Cancellation = .{};
    const empty = try Client.extract(client, a, fixture, &cancel);
    defer codec.freeCandidates(a, empty);
    try context.checkInput(client.source.value, estimated);
    try std.testing.expectEqual(testConfig().model.output_tokens, client.source.value.model.output_tokens);
    client.source.value.limits.max_input_tokens.? -= 1;
    try std.testing.expectError(error.InputBudgetExceeded, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(@as(u64, 1), client.calls);
}
test "memory client decoder CAS authorized update filters unauthorized candidate and OOM" {
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        try casClientCase(std.testing.allocator, protocol);
        // Includes allocation failures in final parse after scratch validation;
        // testing allocator checks rollback, never a partial returned batch.
        try std.testing.checkAllAllocationFailures(std.testing.allocator, casClientCase, .{protocol});
    }
}
test "memory client binds only primary confirmed auto protocol without startup requests" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("SYNTHETIC_MEMORY_KEY", "owned-auto-key");
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        var primary = testConfig();
        primary.model.protocol = .auto;
        const client = try Client.create(a, std.testing.io, primary, &env);
        defer client.deinit();
        try std.testing.expect(client.transport != null);
        try std.testing.expectEqualStrings("Bearer owned-auto-key", client.transport.?.authorization);
        try std.testing.expect(client.transport.?.config == &client.source.value);
        var fake: WireFake = .{};
        client.model_override = .{ .context = &fake, .call_fn = WireFake.invoke };
        var cancel: p.Cancellation = .{};
        try std.testing.expectError(error.UnknownModelProtocol, Client.extract(client, a, fixture, &cancel));
        try std.testing.expectError(error.UnsupportedProtocol, client.bindProtocol(.auto));
        try std.testing.expectError(error.UnsupportedProtocol, client.bindProtocol(.systemone));
        try client.bindProtocol(protocol);
        try client.bindProtocol(protocol);
        try std.testing.expectEqual(@as(u64, 0), client.calls);
        try std.testing.expectEqual(@as(usize, 0), fake.calls);
        try std.testing.expectEqual(p.Protocol.auto, primary.model.protocol);
        try std.testing.expectEqual(protocol, client.transport.?.config.model.protocol);
        const different: p.Protocol = if (protocol == .chat) .responses else .chat;
        try std.testing.expectError(error.ProtocolBindingMismatch, client.bindProtocol(different));
        try std.testing.expectEqual(protocol, client.source.value.model.protocol);
        const items = try Client.extract(client, a, fixture, &cancel);
        defer codec.freeCandidates(a, items);
        try std.testing.expectEqual(@as(usize, 1), items.len);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expectEqual(@as(u64, 1), client.calls);
    }
    const explicit = try Client.create(a, std.testing.io, testConfig(), &env);
    defer explicit.deinit();
    try explicit.bindProtocol(.chat);
    try std.testing.expectError(error.ProtocolBindingMismatch, explicit.bindProtocol(.responses));
    try std.testing.expectEqual(@as(u64, 0), explicit.calls);
}
test "memory client auto binding absent credentials pending selection remain lazy" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = testConfig();
    config.model.protocol = .auto;
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    try client.bindProtocol(.anthropic);
    try std.testing.expect(client.key == null and client.transport == null);
    var cancel: p.Cancellation = .{};
    try std.testing.expectError(error.MemoryUnavailable, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    config.provider.base_url = "";
    config.selection_pending = true;
    const pending = try Client.create(a, std.testing.io, config, &env);
    defer pending.deinit();
    try std.testing.expectError(error.UnknownModelProtocol, pending.bindProtocol(.chat));
    try std.testing.expectError(error.UnknownModelProtocol, pending.service().extract(a, fixture, &cancel));
}
test "memory client rejects Anthropic explicit refusal even with valid evidence JSON" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = testConfig();
    config.model.protocol = .anthropic;
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    var fake: WireFake = .{ .reject = true };
    client.model_override = .{ .context = &fake, .call_fn = WireFake.invoke };
    var cancel: p.Cancellation = .{};
    // The exact same JSON is accepted when the stop reason is end_turn.
    try std.testing.expectError(error.InvalidMemoryOutput, Client.extract(client, a, fixture, &cancel));
    try std.testing.expectEqual(@as(?u64, 13), client.last_usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), client.last_usage.output_tokens);
    fake.reject = false;
    const items = try Client.extract(client, a, fixture, &cancel);
    defer codec.freeCandidates(a, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(u64, 2), client.calls);
}
test "memory client real decoders accept large final JSON and Chat large reasoning replay" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const padding = try a.alloc(u8, 33000);
    defer a.free(padding);
    @memset(padding, ' ');
    const body = try std.fmt.allocPrint(a, "{s}{{\"items\":[]}}", .{padding});
    defer a.free(body);
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        var config = testConfig();
        config.model.protocol = protocol;
        const client = try Client.create(a, std.testing.io, config, &env);
        defer client.deinit();
        var fake: WireFake = .{ .body_override = body };
        client.model_override = .{ .context = &fake, .call_fn = WireFake.invoke };
        var cancel: p.Cancellation = .{};
        const items = try Client.extract(client, a, fixture, &cancel);
        defer codec.freeCandidates(a, items);
        try std.testing.expectEqual(@as(usize, 0), items.len);
        try std.testing.expectEqual(@as(?u64, 13), client.last_usage.input_tokens);
        if (protocol == .chat) {
            fake.body_override = null;
            fake.large_reasoning = true;
            const with_reasoning = try Client.extract(client, a, fixture, &cancel);
            defer codec.freeCandidates(a, with_reasoning);
            try std.testing.expectEqual(@as(usize, 1), with_reasoning.len);
        }
    }
}
test "memory client actual Chat Responses Anthropic decoders valid refused truncated independent usage" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        var config = testConfig();
        config.model.protocol = protocol;
        const client = try Client.create(a, std.testing.io, config, &env);
        defer client.deinit();
        var fake: WireFake = .{};
        client.model_override = .{ .context = &fake, .call_fn = WireFake.invoke };
        var cancel: p.Cancellation = .{};
        const items = try Client.extract(client, a, fixture, &cancel);
        defer codec.freeCandidates(a, items);
        try std.testing.expectEqual(@as(usize, 1), items.len);
        try std.testing.expectEqualStrings("Prefer Zig.", items[0].content);
        try std.testing.expectEqual(@as(?u64, 13), client.last_usage.input_tokens);
        try std.testing.expectEqual(@as(?u64, 4), client.last_usage.output_tokens);
        fake.reject = true;
        try std.testing.expectError(error.InvalidMemoryOutput, Client.extract(client, a, fixture, &cancel));
        fake.reject = false;
        fake.truncated = true;
        try std.testing.expectError(error.MemoryUnavailable, Client.extract(client, a, fixture, &cancel));
        try std.testing.expectEqual(@as(usize, 3), fake.calls);
        try std.testing.expectEqual(@as(u64, 3), client.calls);
    }
}
