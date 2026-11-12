test "chat output limit explicit reasoning cap preserves usage and requires DONE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |done| {
        var s = Stream.init(a, test_support.chat_scope, .{});
        try s.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"plan\"},\"finish_reason\":\"length\"}],\"usage\":{\"completion_tokens\":4096,\"completion_tokens_details\":{\"reasoning_tokens\":4096}}}");
        if (!done) {
            try std.testing.expectError(error.TruncatedStream, s.finish());
            continue;
        }
        try s.feed("", "[DONE]");
        const f = (try s.finish()).failure;
        try std.testing.expectEqual(p.FailureKind.output_limit, f.kind);
        try std.testing.expect(f.observed_content);
        try std.testing.expectEqual(@as(?u64, 4096), f.usage.output_tokens);
        try std.testing.expectEqual(@as(?u64, 4096), f.usage.reasoning_tokens);
        try std.testing.expect(f.raw_usage_json != null);
        try std.testing.expectError(error.InvalidStreamState, s.finish());
    }
}
test "chat output limit partial tools never commit and counters do not imply cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = Stream.init(a, test_support.chat_scope, .{});
    try s.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"x\",\"function\":{\"name\":\"f\",\"arguments\":\"{\"}}]},\"finish_reason\":\"length\"}]}");
    try s.feed("", "[DONE]");
    try std.testing.expectEqual(p.FailureKind.output_limit, (try s.finish()).failure.kind);
    for ([_][]const u8{ "stop", "content_filter" }) |reason| {
        s = Stream.init(a, test_support.chat_scope, .{});
        try s.feed("", try std.fmt.allocPrint(a, "{{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"text\"}},\"finish_reason\":\"{s}\"}}],\"usage\":{{\"completion_tokens\":4096,\"completion_tokens_details\":{{\"reasoning_tokens\":4096}}}}}}", .{reason}));
        try s.feed("", "[DONE]");
        const out = try s.finish();
        if (c.eq(reason, "stop")) try std.testing.expect(out == .success) else try std.testing.expectEqual(p.FailureKind.model, out.failure.kind);
    }
    s = Stream.init(a, test_support.chat_scope, .{});
    try s.feed("", "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}");
    try std.testing.expectError(error.InvalidStreamState, s.feed("", "{\"choices\":[{\"index\":0,\"delta\":{}}]}"));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
}
test "chat write preview recognizes split names before arguments and revokes changed names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = test_support.Recorder{};
    var stream = Stream.init(arena.allocator(), test_support.chat_scope, recorder.sink());
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"write-0\",\"function\":{\"name\":\"write_\"}}]}}]}");
    try std.testing.expect(!recorder.preview_write);
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"file\"}}]}}]}");
    try std.testing.expect(recorder.preview_write);
    try std.testing.expectEqual(@as(usize, 0), recorder.preview_bytes);
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{}\"}}]}}]}");
    try std.testing.expect(recorder.preview_write);
    try std.testing.expectEqual(@as(usize, 2), recorder.preview_bytes);
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"_other\"}}]}}]}");
    try std.testing.expect(!recorder.preview_write);
    try std.testing.expectEqual(@as(usize, 2), recorder.preview_bytes);
}
test "chat refusal chunks are visible text and retain native replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Capture = struct {
        text: std.ArrayList(u8) = .empty,
        a: std.mem.Allocator,
        fn emit(ctx: ?*anyopaque, event: p.ModelEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .text_delta => |text| try self.text.appendSlice(self.a, text),
                else => return error.UnexpectedEvent,
            }
        }
    };
    var capture = Capture{ .a = arena.allocator() };
    var stream = Stream.init(arena.allocator(), test_support.chat_scope, .{ .context = &capture, .emit_fn = Capture.emit });
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"refusal\":\"Cannot \"}}]}");
    try std.testing.expect(stream.observedContent());
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"refusal\":\"help.\"}}]}");
    try std.testing.expectEqualStrings("Cannot help.", capture.text.items);
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}");
    try stream.feed("", "[DONE]");
    const response = (try stream.finish()).success;
    try std.testing.expect(response.finish == .stop);
    try std.testing.expect(response.refused);
    try std.testing.expect(!response.unsupported_output);
    try std.testing.expectEqual(@as(usize, 1), response.message.blocks.len);
    try std.testing.expectEqualStrings("Cannot help.", response.message.blocks[0].text);
    try std.testing.expect(response.message.replay.?.retain_turn);
    const native = try j.parse(arena.allocator(), response.message.replay.?.json);
    try std.testing.expectEqualStrings("Cannot help.", j.get(native, "refusal").?.string);
    try std.testing.expect(j.get(native, "content").? == .null);
    var req = test_support.request(.chat);
    req.messages = &.{response.message};
    try test_support.contains(try encode(arena.allocator(), req), "\"refusal\":\"Cannot help.\"");
}
test "chat nullable refusal does not reject an ordinary answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stream = Stream.init(arena.allocator(), test_support.chat_scope, .{});
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello\",\"refusal\":null},\"finish_reason\":\"stop\"}]}");
    try stream.feed("", "[DONE]");
    const response = (try stream.finish()).success;
    try std.testing.expectEqualStrings("hello", response.message.blocks[0].text);
}
test "chat normalized safety flags retain legacy call and vendor metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "null", "[]", "{}", "[1]", "\"legacy\"" }, 0..) |legacy, i| {
        var stream = Stream.init(a, test_support.chat_scope, .{});
        try stream.feed("", try std.fmt.allocPrint(a, "{{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"ok\",\"function_call\":{s},\"vendor\":{{\"x\":1}}}},\"finish_reason\":\"stop\"}}]}}", .{legacy}));
        try stream.feed("", "[DONE]");
        const response = (try stream.finish()).success;
        try std.testing.expectEqual(i >= 2, response.unsupported_output);
        try std.testing.expect(!response.refused);
        try std.testing.expectEqualStrings("ok", response.message.blocks[0].text);
        const native = try j.parse(a, response.message.replay.?.json);
        try std.testing.expect(j.get(native, "vendor") != null);
        if (i != 0) try std.testing.expect(j.get(native, "function_call") != null);
        try std.testing.expect(response.message.replay.?.retain_turn);
    }
    var empty = Stream.init(a, test_support.chat_scope, .{});
    try empty.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"refusal\":\"\"},\"finish_reason\":\"stop\"}]}");
    try empty.feed("", "[DONE]");
    try std.testing.expect((try empty.finish()).success.refused);
}
test "chat non-string refusal fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "{}", "[]", "true", "42" }) |value| {
        var stream = Stream.init(arena.allocator(), test_support.chat_scope, .{});
        const data = try std.fmt.allocPrint(arena.allocator(), "{{\"choices\":[{{\"index\":0,\"delta\":{{\"refusal\":{s}}}}}]}}", .{value});
        try std.testing.expectError(error.InvalidEvent, stream.feed("", data));
        try std.testing.expectError(error.InvalidStreamState, stream.finish());
    }
}
test "chat usage snapshots do not lock content and survive model failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder: test_support.Recorder = .{};
    var s = Stream.init(arena.allocator(), test_support.chat_scope, recorder.sink());
    try s.feed("", "{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2}}");
    try s.feed("", "{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4}}");
    try std.testing.expect(!s.observedContent());
    try std.testing.expectEqual(@as(usize, 2), recorder.snapshots);
    try std.testing.expectEqual(@as(?u64, 14), recorder.usage.total());
    try s.feed("", "{\"error\":{\"message\":\"do not echo\"},\"usage\":{\"completion_tokens\":5}}");
    const failure = (try s.finish()).failure;
    try std.testing.expectEqual(@as(?u64, 15), failure.usage.total());
    try std.testing.expect(failure.raw_usage_json != null);
    try std.testing.expectEqual(@as(usize, 0), recorder.drafts);
}
test "chat finish sentinel bounds replay and history association guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var no_reason = Stream.init(a, test_support.chat_scope, .{});
    try no_reason.feed("", "[DONE]");
    try std.testing.expectError(error.TruncatedStream, no_reason.finish());
    var wrong_id = Stream.init(a, test_support.chat_scope, .{});
    try wrong_id.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\"}]}}]}");
    try std.testing.expectError(error.InconsistentToolId, wrong_id.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"b\"}]}}]}"));
    var req = test_support.request(.chat);
    req.messages = &.{.{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "missing", .text = "result" } }} }};
    try std.testing.expectError(error.UnmatchedToolResult, encode(a, req));
    req.messages = &.{.{ .role = .assistant, .blocks = &.{}, .replay = .{ .scope = test_support.chat_scope, .json = "{\"role\":\"system\",\"content\":\"not an assistant\"}" } }};
    try std.testing.expectError(error.InvalidReplay, encode(a, req));
    req.messages = &.{};
    const first = try j.parse(a, try encode(a, req));
    req.messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "new turn" }} }};
    const second = try j.parse(a, try encode(a, req));
    try std.testing.expectEqualStrings(try j.encode(a, j.get(first, "messages").?.array.items[0]), try j.encode(a, j.get(second, "messages").?.array.items[0]));
    try std.testing.expectEqualStrings(try j.encode(a, j.get(first, "tools").?), try j.encode(a, j.get(second, "tools").?));
}
test "thinking actual chat standard and deepseek mapping" {
    const thinking = @import("../core/thinking.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var req = test_support.request(.chat);
    const cases = [_]struct { model: []const u8, effort: ?[]const u8, expected: ?[]const u8, enabled: ?bool }{
        .{ .model = "deepseek-flash", .effort = null, .expected = null, .enabled = null },
        .{ .model = "deepseek-flash", .effort = "off", .expected = null, .enabled = false },
        .{ .model = "deepseek-flash", .effort = "medium", .expected = "high", .enabled = true },
        .{ .model = "deepseek-v4-pro", .effort = "max", .expected = "max", .enabled = true },
    };
    for (cases) |case| {
        const cap = thinking.resolve("https://api.deepseek.com", case.model, .{ .format = .deepseek, .map = .{ .off = "off", .high = "high", .max = "max" } });
        const wire = cap.wire(case.effort);
        req.reasoning_effort = wire.effort;
        req.thinking = wire.thinking;
        req.reasoning_format = cap.format;
        const v = try j.parse(a, try encode(a, req));
        if (case.expected) |expected| try std.testing.expectEqualStrings(expected, try c.text(v, "reasoning_effort")) else try std.testing.expect(j.get(v, "reasoning_effort") == null);
        if (case.enabled) |enabled| try std.testing.expectEqualStrings(if (enabled) "enabled" else "disabled", try c.text(j.get(v, "thinking").?, "type")) else try std.testing.expect(j.get(v, "thinking") == null);
    }
    const cap = thinking.resolve("https://api.openai.com/v1", "gpt-5.2", .{ .map = .{ .off = "none", .high = "high" } });
    req.reasoning_effort = cap.wire("off").effort;
    req.thinking = null;
    req.reasoning_format = cap.format;
    try std.testing.expectEqualStrings("none", try c.text(try j.parse(a, try encode(a, req)), "reasoning_effort"));
    const custom = thinking.resolve("https://proxy", "custom", .{ .map = .{ .high = "custom-wire" } });
    req.reasoning_effort = custom.wire("low").effort;
    try std.testing.expectEqualStrings("custom-wire", try c.text(try j.parse(a, try encode(a, req)), "reasoning_effort"));
}
test "chat real request stable system tools history and summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var req = test_support.request(.chat);
    const history = [_]p.Message{
        .{ .role = .context, .blocks = &.{.{ .text = "context data" }} },
        .{ .role = .user, .blocks = &.{.{ .text = "hello" }} },
        .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "call_a", .name = "lookup", .arguments = "{}" } }} },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "call_a", .text = "result" } }} },
    };
    req.messages = &history;
    const ordinary = try encode(a, req);
    const v = try j.parse(a, ordinary);
    try std.testing.expect(j.get(v, "input") == null);
    const messages = (j.get(v, "messages").?).array.items;
    try std.testing.expectEqualStrings(req.system, try c.text(messages[0], "content"));
    try std.testing.expectEqualStrings("user", try c.text(messages[1], "role"));
    try std.testing.expectEqualStrings("call_a", try c.text(messages[4], "tool_call_id"));
    try std.testing.expect(j.get(v, "reasoning_effort") == null);
    req.purpose = .summary;
    const summary = try j.parse(a, try encode(a, req));
    try std.testing.expectEqualStrings(try j.encode(a, j.get(v, "messages").?), try j.encode(a, j.get(summary, "messages").?));
    try std.testing.expectEqualStrings(try j.encode(a, j.get(v, "tools").?), try j.encode(a, j.get(summary, "tools").?));
    try std.testing.expectEqualStrings("none", try c.text(summary, "tool_choice"));
    req.reasoning_effort = "low";
    const configured = try j.parse(a, try encode(a, req));
    try std.testing.expectEqualStrings("low", try c.text(configured, "reasoning_effort"));
}
test "chat interleaved tools reasoning native replay and late usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = Stream.init(a, test_support.chat_scope, .{});
    try s.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"reasoning_content\":\"plan\",\"signature\":\"opaque\"}}]}");
    try s.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":\"}},{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\"}}]}}]}");
    try s.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"}\"}},{\"index\":0,\"function\":{\"arguments\":\"1}\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    try s.feed("", "{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4,\"total_tokens\":14,\"prompt_tokens_details\":{\"cached_tokens\":8},\"completion_tokens_details\":{\"reasoning_tokens\":2}}}");
    try s.feed("", "[DONE]");
    const out = (try s.finish()).success;
    try std.testing.expect(s.observedContent());
    try std.testing.expectEqual(@as(?u64, 14), out.usage.total());
    try std.testing.expectEqual(@as(?u64, 8), out.usage.cached_input_tokens);
    try std.testing.expectEqualStrings("plan", out.message.blocks[0].reasoning);
    try std.testing.expectEqualStrings("a", out.message.blocks[1].tool_call.id);
    try std.testing.expectEqualStrings("{\"q\":1}", out.message.blocks[1].tool_call.arguments);
    try std.testing.expectEqualStrings("b", out.message.blocks[2].tool_call.id);
    var req = test_support.request(.chat);
    req.messages = &.{out.message};
    const wire = try encode(a, req);
    try test_support.contains(wire, "opaque");
    try test_support.contains(wire, "reasoning_content");
    req.scope.connection = "different";
    try std.testing.expectError(error.ReplayScopeMismatch, encode(a, req));
}
test "chat refuses truncation length malformed arguments duplicate IDs and unknown required fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var truncated = Stream.init(a, test_support.chat_scope, .{});
    try truncated.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}");
    try std.testing.expectError(error.TruncatedStream, truncated.finish());
    for ([_][]const u8{ "length", "content_filter" }) |reason| {
        var s = Stream.init(a, test_support.chat_scope, .{});
        const data = try std.fmt.allocPrint(a, "{{\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}]}}", .{reason});
        try s.feed("", data);
        try s.feed("", "[DONE]");
        try std.testing.expect((try s.finish()) == .failure);
    }
    var bad = Stream.init(a, test_support.chat_scope, .{});
    try bad.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"lookup\",\"arguments\":\"[]\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    try bad.feed("", "[DONE]");
    try std.testing.expectError(error.InvalidToolArguments, bad.finish());
    var duplicate = Stream.init(a, test_support.chat_scope, .{});
    try std.testing.expectError(error.DuplicateToolId, duplicate.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\"},{\"index\":1,\"id\":\"a\"}]}}]}"));
    try std.testing.expectError(error.InvalidStreamState, duplicate.finish());
    var missing = Stream.init(a, test_support.chat_scope, .{});
    try std.testing.expectError(error.InvalidEvent, missing.feed("", "{\"extra\":1}"));
    var unknown = Stream.init(a, test_support.chat_scope, .{});
    try unknown.feed("", "{\"extra\":1,\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_cache_hit_tokens\":7}}");
    try unknown.feed("", "[DONE]");
    const result = (try unknown.finish()).success;
    try std.testing.expectEqual(@as(?u64, null), result.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 7), result.usage.cached_input_tokens);
    var fail = Stream.init(a, test_support.chat_scope, .{});
    try fail.feed("error", "{\"error\":{\"message\":\"secret-key\"}}");
    const failure = (try fail.finish()).failure;
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "secret-key") == null);
}
test "chat omits all output caps with varying model capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var req = test_support.request(.chat);
    for ([_]?u32{ null, 0, 123 }) |capacity| {
        req.model_output_tokens = capacity;
        for ([_]p.Purpose{ .normal, .summary }) |purpose| {
            req.purpose = purpose;
            const wire = try j.parse(a, try encode(a, req));
            inline for (.{ "max_tokens", "max_completion_tokens", "max_output_tokens" }) |key|
                try std.testing.expect(j.get(wire, key) == null);
        }
    }
}
