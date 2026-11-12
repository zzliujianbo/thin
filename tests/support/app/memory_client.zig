const fixture: knowledge.Material = .{ .id = "test", .generation = 1, .created_ms = 100, .sources = &.{.{ .id = 0, .kind = .user, .text = "Prefer Zig." }} };

const Fake = struct {
    calls: usize = 0,
    mode: enum { empty, failure, cancel, tool, thrown, canceled_cleanup, partial_usage, partial, reasoning, oversized, replay } = .empty,
    client: ?*Client = null,
    body_override: ?[]const u8 = null,
    fn invoke(raw: *anyopaque, a: std.mem.Allocator, request: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try std.testing.expectEqual(@as(usize, 0), request.tools.len);
        try std.testing.expectEqual(p.Purpose.normal, request.purpose);
        try std.testing.expectEqual(p.Protocol.chat, request.scope.protocol);
        try std.testing.expectEqualStrings("primary/model", request.scope.model);
        try std.testing.expectEqualStrings("http://primary.invalid/v1", request.scope.connection);
        try std.testing.expectEqual(@as(usize, 1), request.messages.len);
        const client = self.client.?;
        try std.testing.expectEqual(client.source.value.model.output_tokens, request.model_output_tokens);
        try std.testing.expect(client.source.value.limits.low_price_input);
        try std.testing.expectEqual(@as(u32, 1234), client.source.value.limits.request_timeout_ms);
        const usage: p.Usage = .{ .input_tokens = 17, .output_tokens = 3 };
        try sink.emit(.{ .usage = usage });
        if (self.mode == .cancel or self.mode == .canceled_cleanup) @constCast(request.cancellation.?).cancel();
        if (self.mode == .thrown or self.mode == .canceled_cleanup) return error.CleanupFailed;
        if (self.mode == .failure) return .{ .failure = .{ .kind = .output_limit, .message = "synthetic", .usage = usage, .http_status = 429 } };
        if (self.mode == .tool) return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{} }, .finish = .tool_calls, .usage = usage } };
        const body = self.body_override orelse if (self.mode == .partial) "{\"items\":[" else "{\"items\":[]}";
        var msg = try p.textMessage(a, .assistant, body);
        if (self.mode == .reasoning) msg.blocks = try a.dupe(p.Block, &.{ .{ .reasoning = "Do not save this thought" }, .{ .text = body } });
        if (self.mode == .replay) {
            var scope = request.scope;
            scope.model = "wrong";
            msg.replay = .{ .scope = scope, .json = "\xff not JSON" };
        }
        if (self.mode == .oversized) {
            const padding = try a.alloc(u8, 33000);
            @memset(padding, ' ');
            const text = try std.fmt.allocPrint(a, "{s}{{\"items\":[]}}", .{padding});
            try sink.emit(.{ .text_delta = text });
            msg = try p.textMessage(a, .assistant, text);
        }
        return .{ .success = .{ .message = msg, .usage = if (self.mode == .partial_usage) .{ .output_tokens = 4 } else usage, .finish = .stop } };
    }
};

fn testConfig() cfg.Config {
    return .{ .provider = .{ .base_url = "http://primary.invalid/v1", .api_key_env = "SYNTHETIC_MEMORY_KEY" }, .selected_provider = "primary", .model = .{ .name = "primary/model", .protocol = .chat, .context_tokens = 32768, .output_tokens = 8192, .input_price_flat_limit = 32768 }, .limits = .{ .request_timeout_ms = 1234 } };
}

fn windowForInputBudget(budget: u32) u32 {
    std.debug.assert(budget > 0);
    const room = @as(u64, budget) + 1;
    const window: u32 = @intCast(room + @min(cfg.Policy.safety_tokens, room / 7));
    std.debug.assert(@as(u64, window) - cfg.Policy.safetyTokens(window) - 1 == budget);
    return window;
}

fn creationCase(a: std.mem.Allocator) !void {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("SYNTHETIC_MEMORY_KEY", "own-key");
    const client = try Client.create(a, std.testing.io, testConfig(), &env);
    defer client.deinit();
    try std.testing.expectEqual(@as(u64, 0), client.calls);
    try std.testing.expect(client.last_usage.input_tokens == null);
    try std.testing.expectEqualStrings("own-key", client.key.?);
    try env.put("SYNTHETIC_MEMORY_KEY", "replaced");
    try std.testing.expectEqualStrings("Bearer own-key", client.transport.?.authorization);
    try std.testing.expectEqual(testConfig().model.output_tokens, client.source.value.model.output_tokens);
    try std.testing.expectEqualDeep(testConfig().limits, client.source.value.limits);
}

const WireFake = struct {
    body_override: ?[]const u8 = null,
    reject: bool = false,
    truncated: bool = false,
    large_reasoning: bool = false,
    calls: usize = 0,
    fn invoke(raw: *anyopaque, a: std.mem.Allocator, req: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try std.testing.expectEqual(@as(usize, 0), req.tools.len);
        try std.testing.expectEqual(testConfig().model.output_tokens, req.model_output_tokens);
        const body = self.body_override orelse "{\"items\":[{\"category\":\"preferences\",\"topic\":\"language\",\"content\":\"Prefer Zig.\",\"source_id\":0}],\"note\":\"metadata\"}";
        const quoted = try std.json.Stringify.valueAlloc(a, body, .{});
        switch (req.scope.protocol) {
            .chat => {
                var stream = @import("../llm/chat.zig").Stream.init(a, req.scope, sink);
                if (self.large_reasoning) {
                    const reasoning = try a.alloc(u8, 33000);
                    @memset(reasoning, 'x');
                    const encoded = try std.json.Stringify.valueAlloc(a, reasoning, .{});
                    try stream.feed("", try std.fmt.allocPrint(a, "{{\"choices\":[{{\"index\":0,\"delta\":{{\"reasoning_content\":{s}}}}}]}}", .{encoded}));
                }
                try stream.feed("", try std.fmt.allocPrint(a, "{{\"choices\":[{{\"index\":0,\"delta\":{{\"{s}\":{s}}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":13,\"completion_tokens\":4}}}}", .{ if (self.reject) "refusal" else "content", quoted }));
                if (!self.truncated) try stream.feed("", "[DONE]");
                return stream.finish();
            },
            .responses => {
                var stream = @import("../llm/responses.zig").Stream.init(a, req.scope, sink);
                if (!self.truncated) try stream.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"response.completed\",\"response\":{{\"status\":\"completed\",\"output\":[{{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"{s}\",\"{s}\":{s}}}]}}],\"usage\":{{\"input_tokens\":13,\"output_tokens\":4}}}}}}", .{ if (self.reject) "refusal" else "output_text", if (self.reject) "refusal" else "text", quoted }));
                return stream.finish();
            },
            .anthropic => {
                var stream = @import("../llm/anthropic.zig").Stream.init(a, req.scope, sink);
                try stream.feed("message_start", "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":13,\"output_tokens\":0}}}");
                try stream.feed("content_block_start", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}");
                // Even a syntactically/evidentially valid JSON body is not a
                // candidate batch when the actual stop reason was refusal.
                try stream.feed("content_block_delta", try std.fmt.allocPrint(a, "{{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}", .{quoted}));
                try stream.feed("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}");
                try stream.feed("message_delta", try std.fmt.allocPrint(a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":4}}}}", .{if (self.reject) "refusal" else "end_turn"}));
                if (!self.truncated) try stream.feed("message_stop", "{\"type\":\"message_stop\"}");
                return stream.finish();
            },
            else => unreachable,
        }
    }
};

const cas_version = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

const cas_body = "{\"items\":[{\"category\":\"preferences\",\"topic\":\"editor\",\"content\":\"Prefer Zig.\"},{\"category\":\"preferences\",\"topic\":\"language\",\"content\":\"Prefer Zig.\",\"expected_version\":\"" ++ cas_version ++ "\"}]}";

fn casClientCase(out: std.mem.Allocator, protocol: p.Protocol) !void {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = testConfig();
    config.model.protocol = protocol;
    const client = try Client.create(a, std.testing.io, config, &env);
    defer client.deinit();
    var fake: WireFake = .{ .body_override = cas_body };
    client.model_override = .{ .context = &fake, .call_fn = WireFake.invoke };
    var cancel: p.Cancellation = .{};
    var material = fixture;
    const related: knowledge.Related = .{ .category = .preferences, .topic = "language", .content = "Old", .version = cas_version };
    material.related = &.{related};
    // The returned candidates are owned by the caller.
    const items = try Client.extract(client, out, material, &cancel);
    defer codec.freeCandidates(out, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings(cas_version, items[1].expected_version.?);
    try std.testing.expectEqual(@as(?u64, 13), client.last_usage.input_tokens);
    for (0..4) |case| {
        var r = related;
        switch (case) {
            0 => {},
            1 => r.category = .project,
            2 => r.topic = "other",
            3 => r.version = "1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            else => unreachable,
        }
        material.related = if (case == 0) &.{} else &.{r};
        var task_arena = std.heap.ArenaAllocator.init(out);
        defer task_arena.deinit();
        const filtered = try client.service().extract(task_arena.allocator(), material, &cancel);
        try std.testing.expectEqual(@as(usize, 1), filtered.len);
        try std.testing.expectEqualStrings("editor", filtered[0].topic);
    }
    try std.testing.expectEqual(@as(usize, 5), fake.calls);
}
