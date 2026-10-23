const std = @import("std");
const adapter = @import("anthropic.zig");
const p = @import("../core/protocol.zig");
const j = @import("../util/json.zig");
const c = @import("common.zig");
const scope: p.ReplayScope = .{ .connection = "offline", .model = "fixture", .protocol = .anthropic };
const start = "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":5,\"cache_creation_input_tokens\":3,\"cache_read_input_tokens\":7,\"output_tokens\":0}}}";
fn request() p.Request {
    // Synthetic verified capacity for this fixture model, not a request cap.
    return .{ .scope = scope, .system = "system", .tools = &.{}, .messages = &.{}, .model_output_tokens = 100 };
}

test "anthropic requires known positive frozen model output capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var req = request();
    for ([_]p.Purpose{ .normal, .summary }) |purpose| {
        req.purpose = purpose;
        req.model_output_tokens = null;
        try std.testing.expectError(error.UnknownModelOutputCapacity, adapter.encode(a, req));
        req.model_output_tokens = 0;
        try std.testing.expectError(error.InvalidModelOutputCapacity, adapter.encode(a, req));
        for ([_]u32{ 1, 100, std.math.maxInt(u32) }) |capacity| {
            req.model_output_tokens = capacity;
            const wire = try j.parse(a, try adapter.encode(a, req));
            try std.testing.expectEqual(@as(?u64, capacity), j.uint(j.get(wire, "max_tokens")));
            try std.testing.expect(j.get(wire, "max_completion_tokens") == null);
            try std.testing.expect(j.get(wire, "max_output_tokens") == null);
        }
    }
}
fn end(s: *adapter.Stream, reason: []const u8) !void {
    const data = try std.fmt.allocPrint(s.a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":4}}}}", .{reason});
    try s.feed("", data);
    try s.feed("", "{\"type\":\"message_stop\"}");
}
fn block(s: *adapter.Stream, index: usize, native: []const u8) !void {
    try s.feed("", try std.fmt.allocPrint(s.a, "{{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{s}}}", .{ index, native }));
}
fn stop(s: *adapter.Stream, index: usize) !void {
    try s.feed("", try std.fmt.allocPrint(s.a, "{{\"type\":\"content_block_stop\",\"index\":{d}}}", .{index}));
}
fn delta(s: *adapter.Stream, index: usize, native: []const u8) !void {
    try s.feed("", try std.fmt.allocPrint(s.a, "{{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{s}}}", .{ index, native }));
}

test "anthropic prefix rewrite does not emit empty assistant after thinking only normalization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: p.Message = .{
        .role = .assistant,
        .blocks = &.{.{ .reasoning = "private thinking fixture" }},
        .replay = .{ .scope = scope, .json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"private thinking fixture\",\"signature\":\"stale-fixture\"}]}", .retain_turn = true },
    };
    const normalized = try @import("../core/context.zig").cloneAfterPrefixRewrite(a, original);
    try std.testing.expect(normalized.replay == null and normalized.blocks.len == 0);
    var req = request();
    req.thinking = true;
    req.reasoning_effort = "max";
    req.reasoning_format = .anthropic;
    req.messages = &.{
        .{ .role = .user, .blocks = &.{.{ .text = "prior question" }} },
        normalized,
        .{ .role = .user, .blocks = &.{.{ .text = "next explicit question" }} },
    };
    const encoded = try adapter.encode(a, req);
    const wire = try j.parse(a, encoded);
    const messages = j.get(wire, "messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("user", j.string(j.get(messages[0], "role")).?);
    try std.testing.expectEqual(@as(usize, 2), j.get(messages[0], "content").?.array.items.len);
    try std.testing.expectEqualStrings("adaptive", j.string(j.get(j.get(wire, "thinking").?, "type")).?);
    try std.testing.expectEqualStrings("max", j.string(j.get(j.get(wire, "output_config").?, "effort")).?);
    try std.testing.expect(std.mem.find(u8, encoded, "stale-fixture") == null);
}

test "anthropic refusal metadata preserves valid JSON text as normal displayable response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "{\"items\":[]}";
    for ([_][]const u8{ "refusal", "end_turn", "stop_sequence" }) |reason| {
        var stream = adapter.Stream.init(a, scope, .{});
        try stream.feed("", start);
        try block(&stream, 0, "{\"type\":\"text\",\"text\":\"\"}");
        const native = try std.fmt.allocPrint(a, "{{\"type\":\"text_delta\",\"text\":{s}}}", .{try j.encode(a, j.str(body))});
        try delta(&stream, 0, native);
        try stop(&stream, 0);
        try end(&stream, reason);
        const response = (try stream.finish()).success;
        try std.testing.expectEqual(c.eq(reason, "refusal"), response.refused);
        try std.testing.expectEqual(p.Finish.stop, response.finish);
        try std.testing.expectEqualStrings(body, response.message.blocks[0].text);
        try std.testing.expectEqual(@as(?u64, 15), response.usage.input_tokens);
        try std.testing.expectEqual(@as(?u64, 4), response.usage.output_tokens);
        // Refusal metadata is deliberately not persisted into message replay.
        try std.testing.expect(std.mem.find(u8, response.message.replay.?.json, "refused") == null);
    }
}

test "anthropic output limit requires complete message stop and preserves reasoning usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "max_tokens", "pause_turn", "model_context_window_exceeded", "end_turn", "stop_sequence", "refusal" }) |reason| {
        var s = adapter.Stream.init(a, scope, .{});
        try s.feed("", start);
        try block(&s, 0, "{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"signed\"}");
        try stop(&s, 0);
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":4096}}}}", .{reason}));
        try s.feed("", "{\"type\":\"message_stop\"}");
        const out = try s.finish();
        if (c.eq(reason, "max_tokens") or c.eq(reason, "pause_turn") or c.eq(reason, "model_context_window_exceeded")) {
            const f = out.failure;
            const expected: p.FailureKind = if (c.eq(reason, "max_tokens")) .output_limit else if (c.eq(reason, "pause_turn")) .model else .context_limit;
            try std.testing.expectEqual(expected, f.kind);
            try std.testing.expect(f.observed_content and f.raw_usage_json != null);
            try std.testing.expectEqual(@as(?u64, 4096), f.usage.output_tokens);
        } else {
            try std.testing.expect(out == .success);
            try std.testing.expectEqual(c.eq(reason, "refusal"), out.success.refused);
        }
        try std.testing.expectError(error.InvalidStreamState, s.finish());
    }
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":4096}}");
    try std.testing.expectError(error.TruncatedStream, s.finish());
}

test "anthropic output limit never accepts partial tool arguments or later events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"tool_use\",\"id\":\"x\",\"name\":\"f\",\"input\":{}}");
    try delta(&s, 0, "{\"type\":\"input_json_delta\",\"partial_json\":\"{\"}");
    try std.testing.expectError(error.InvalidStreamState, s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}"));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try end(&s, "max_tokens");
    try std.testing.expectError(error.InvalidStreamState, s.feed("", "{\"type\":\"message_stop\"}"));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
}

test "anthropic output limit closed partial tool preserves final reason and usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{", "{\"path\":\"", "{\"path\":1," }) |fragment| {
        for ([_]bool{ false, true }) |limited| {
            var s = adapter.Stream.init(a, scope, .{});
            try s.feed("", start);
            try block(&s, 0, "{\"type\":\"tool_use\",\"id\":\"partial\",\"name\":\"write_file\",\"input\":{}}");
            const text = try j.encode(a, j.str(fragment));
            try delta(&s, 0, try std.fmt.allocPrint(a, "{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}", .{text}));
            // A provider may close a tool block whose JSON was cut by max_tokens.
            // Keep consuming through the authoritative final reason and usage.
            try stop(&s, 0);
            try end(&s, if (limited) "max_tokens" else "tool_use");
            if (limited) {
                const failure = (try s.finish()).failure;
                try std.testing.expectEqual(p.FailureKind.output_limit, failure.kind);
                try std.testing.expectEqual(@as(?u64, 4), failure.usage.output_tokens);
                try std.testing.expect(failure.raw_usage_json != null and failure.observed_content);
            } else try std.testing.expectError(error.UnexpectedEndOfInput, s.finish());
        }
    }
}

test "anthropic cap truncated thinking signature never becomes replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |limited| {
        var s = adapter.Stream.init(arena.allocator(), scope, .{});
        try s.feed("", start);
        try block(&s, 0, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}");
        try delta(&s, 0, "{\"type\":\"thinking_delta\",\"thinking\":\"unfinished reasoning\"}");
        try stop(&s, 0);
        try end(&s, if (limited) "max_tokens" else "end_turn");
        if (limited) {
            try std.testing.expectEqual(p.FailureKind.output_limit, (try s.finish()).failure.kind);
        } else try std.testing.expectError(error.InvalidReplay, s.finish());
    }
}

test "anthropic fragmented text tool JSON ordinal preview and usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Capture = struct {
        count: usize = 0,
        bytes: usize = 0,
        fn emit(ctx: ?*anyopaque, e: p.ModelEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (e == .tool_delta) {
                try std.testing.expectEqual(@as(usize, 0), e.tool_delta.index);
                try std.testing.expect(e.tool_delta.write_file);
                self.count += 1;
                self.bytes = e.tool_delta.argument_bytes.?;
            }
        }
    };
    var capture = Capture{};
    var s = adapter.Stream.init(arena.allocator(), scope, .{ .context = &capture, .emit_fn = Capture.emit });
    try s.feed("message_start", start);
    try block(&s, 0, "{\"type\":\"text\",\"text\":\"\",\"citations\":[]}");
    try delta(&s, 0, "{\"type\":\"text_delta\",\"text\":\"hel\"}");
    try delta(&s, 0, "{\"type\":\"text_delta\",\"text\":\"lo\"}");
    try stop(&s, 0);
    try block(&s, 1, "{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"write_file\",\"input\":{}}");
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(usize, 0), capture.bytes);
    try delta(&s, 1, "{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":\"}");
    try delta(&s, 1, "{\"type\":\"input_json_delta\",\"partial_json\":\"1}\"}");
    try stop(&s, 1);
    try end(&s, "tool_use");
    const out = (try s.finish()).success;
    try std.testing.expectEqualStrings("hello", out.message.blocks[0].text);
    try std.testing.expectEqualStrings("{\"x\":1}", out.message.blocks[1].tool_call.arguments);
    try std.testing.expectEqual(@as(?u64, 19), out.usage.total());
    try std.testing.expectEqual(@as(usize, 7), capture.bytes);
    try std.testing.expect(out.message.replay.?.retain_turn);
    try std.testing.expect(std.mem.indexOf(u8, out.message.replay.?.json, "citations") != null);
}

test "anthropic signed redacted replay roundtrip nativeBlocks and scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}");
    try delta(&s, 0, "{\"type\":\"thinking_delta\",\"thinking\":\"plan\"}");
    try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"fi\"}");
    try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"nal\"}");
    try stop(&s, 0);
    try block(&s, 1, "{\"type\":\"redacted_thinking\",\"data\":\"opaque\",\"extension\":{\"x\":1}}");
    try stop(&s, 1);
    try end(&s, "end_turn");
    const out = (try s.finish()).success;
    var req = request();
    req.messages = &.{out.message};
    const wire = try j.parse(a, try adapter.encode(a, req));
    const native = j.get(wire, "messages").?.array.items[0];
    const blocks = try adapter.nativeBlocks(a, native);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("plan", blocks[0].reasoning);
    try std.testing.expectEqualStrings(out.message.replay.?.json, try j.encode(a, native));
    try std.testing.expectEqualStrings("final", try c.text(j.get(native, "content").?.array.items[0], "signature"));
    req.scope.connection = "other";
    try std.testing.expectError(error.ReplayScopeMismatch, adapter.encode(a, req));
    req = request();
    req.messages = &.{.{ .role = .assistant, .blocks = &.{.{ .reasoning = "unsigned" }} }};
    try std.testing.expectError(error.MissingNativeReplay, adapter.encode(a, req));
}

test "anthropic summary tool result adjacency canceled and history guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const history = [_]p.Message{
        .{ .role = .assistant, .blocks = &.{ .{ .tool_call = .{ .id = "a", .name = "f", .arguments = "{}" } }, .{ .tool_call = .{ .id = "b", .name = "f", .arguments = "{}" } } } },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "a", .text = "canceled", .canceled = true } }} },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "b", .text = "ok" } }} },
    };
    var req = request();
    req.messages = &history;
    req.purpose = .summary;
    const v = try j.parse(a, try adapter.encode(a, req));
    try std.testing.expectEqualStrings("none", try c.text(j.get(v, "tool_choice").?, "type"));
    try std.testing.expect(j.get(v, "max_tokens") != null and j.get(v, "max_output_tokens") == null and j.get(v, "reasoning_effort") == null);
    const messages = j.get(v, "messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    const results = j.get(messages[1], "content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(j.get(results[0], "is_error").?.bool);
    req.messages = history[0..2];
    try std.testing.expectError(error.UnmatchedToolCall, adapter.encode(a, req));
    req.messages = history[1..];
    try std.testing.expectError(error.UnmatchedToolResult, adapter.encode(a, req));
    req.messages = &.{ history[0], .{ .role = .user, .blocks = &.{.{ .text = "interrupt" }} } };
    try std.testing.expectError(error.UnmatchedToolCall, adapter.encode(a, req));
    req.messages = &.{};
    req.reasoning_effort = "low";
    try std.testing.expectError(error.IncompatibleReasoningProtocol, adapter.encode(a, req));
    req.reasoning_format = .anthropic;
    req.thinking = true;
    const adaptive = try j.parse(a, try adapter.encode(a, req));
    try std.testing.expectEqualStrings("adaptive", try c.text(j.get(adaptive, "thinking").?, "type"));
    try std.testing.expectEqualStrings("low", try c.text(j.get(adaptive, "output_config").?, "effort"));
    req.reasoning_effort = null;
    req.thinking = false;
    const disabled = try j.parse(a, try adapter.encode(a, req));
    try std.testing.expectEqualStrings("disabled", try c.text(j.get(disabled, "thinking").?, "type"));
    req.thinking = null;
    req.reasoning_effort = null;
    const plain = try j.parse(a, try adapter.encode(a, req));
    try std.testing.expect(j.get(plain, "thinking") == null and j.get(plain, "output_config") == null);
    req.reasoning_format = .standard;
    req.thinking = false;
    try std.testing.expectError(error.IncompatibleReasoningProtocol, adapter.encode(a, req));
}

test "anthropic errors truncation invalid sequence duplicate IDs bounds and sink poison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = adapter.Stream.init(a, scope, .{});
    try std.testing.expectError(error.InvalidStreamState, s.feed("", "{\"type\":\"message_stop\"}"));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try std.testing.expectError(error.TruncatedStream, s.finish());
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try s.feed("", "{\"type\":\"error\",\"error\":{\"message\":\"SECRET\"}}");
    const failure = (try s.finish()).failure;
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "SECRET") == null);
    try std.testing.expectEqual(@as(?u64, 15), failure.usage.input_tokens);
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"tool_use\",\"id\":\"same\",\"name\":\"f\",\"input\":{}}");
    try stop(&s, 0);
    try std.testing.expectError(error.DuplicateToolId, block(&s, 1, "{\"type\":\"tool_use\",\"id\":\"same\",\"name\":\"f\",\"input\":{}}"));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
    s = adapter.Stream.init(a, scope, .{});
    s.bytes = c.max_bytes;
    try std.testing.expectError(error.InputLimit, s.feed("", start));
    const Reject = struct {
        fn emit(_: ?*anyopaque, _: p.ModelEvent) !void {
            return error.SinkFailed;
        }
    };
    s = adapter.Stream.init(a, scope, .{ .emit_fn = Reject.emit });
    try std.testing.expectError(error.SinkFailed, s.feed("", start));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
    for ([_][]const u8{ "max_tokens", "pause_turn", "model_context_window_exceeded" }) |reason| {
        s = adapter.Stream.init(a, scope, .{});
        try s.feed("", start);
        try end(&s, reason);
        const failed = (try s.finish()).failure;
        try std.testing.expectEqual(if (c.eq(reason, "max_tokens")) p.FailureKind.output_limit else if (c.eq(reason, "model_context_window_exceeded")) p.FailureKind.context_limit else p.FailureKind.model, failed.kind);
    }
}

test "anthropic partial cache usage replacements malformed and overflowing counters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"cache_read_input_tokens\":11,\"output_tokens\":4}}");
    try s.feed("", "{\"type\":\"message_stop\"}");
    const out = (try s.finish()).success;
    try std.testing.expectEqual(@as(?u64, 19), out.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 23), out.usage.total());
    const raw = try j.parse(a, out.raw_usage_json.?);
    try std.testing.expectEqual(@as(?u64, 5), j.uint(j.get(raw, "input_tokens")));
    for ([_][]const u8{ "null", "-1", "1.5", "\"2\"", "18446744073709551616", "18446744073709551615" }) |n| {
        s = adapter.Stream.init(a, scope, .{});
        try s.feed("", start);
        const data = try std.fmt.allocPrint(a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"input_tokens\":{s}}}}}", .{n});
        try std.testing.expectError(error.InvalidUsage, s.feed("", data));
        try std.testing.expectError(error.InvalidStreamState, s.finish());
    }
}

fn allocationFixture(a: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    var s = adapter.Stream.init(t, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"text\",\"text\":\"hello\"}");
    try stop(&s, 0);
    try block(&s, 1, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"YW\"}");
    try delta(&s, 1, "{\"type\":\"signature_delta\",\"signature\":\"Jj\"}");
    try delta(&s, 1, "{\"type\":\"signature_delta\",\"signature\":\"ZA==\"}");
    try stop(&s, 1);
    try end(&s, "end_turn");
    var req = request();
    req.messages = &.{(try s.finish()).success.message};
    _ = try adapter.encode(t, req);
}
test "anthropic block grammar unknown native types and unfinished tools fail closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"role\":\"assistant\",\"content\":[{\"type\":\"image\",\"source\":{}}]}",
        "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"secret\",\"signature\":\"\"}]}",
        "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"x\",\"name\":\"f\",\"input\":[]}]}",
    }) |json| {
        if (adapter.nativeBlocks(a, try j.parse(a, json))) |_| return error.ExpectedFailure else |_| {}
    }
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"text\",\"text\":\"\"}");
    try std.testing.expectError(error.InconsistentItem, delta(&s, 1, "{\"type\":\"text_delta\",\"text\":\"x\"}"));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"text\",\"text\":\"\"}");
    try std.testing.expectError(error.InvalidDelta, delta(&s, 0, "{\"type\":\"citations_delta\"}"));
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"tool_use\",\"id\":\"x\",\"name\":\"f\",\"input\":{}}");
    try delta(&s, 0, "{\"type\":\"input_json_delta\",\"partial_json\":\"{\"}");
    try stop(&s, 0);
    try end(&s, "tool_use");
    try std.testing.expectError(error.UnexpectedEndOfInput, s.finish());
    try std.testing.expectError(error.InvalidStreamState, s.finish());
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"tool_use\",\"id\":\"x\",\"name\":\"f\",\"input\":{}}");
    try stop(&s, 0);
    try end(&s, "end_turn");
    try std.testing.expectError(error.InvalidFinish, s.finish());
}

test "anthropic cumulative usage-only deltas require a stable final reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"tool_use\",\"id\":\"x\",\"name\":\"f\",\"input\":{}}");
    try delta(&s, 0, "{\"type\":\"input_json_delta\",\"partial_json\":\"\"}");
    try stop(&s, 0);
    try s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":null},\"usage\":{\"output_tokens\":2}}");
    try s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":4}}");
    try s.feed("", "{\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"output_tokens\":5}}");
    try s.feed("", "{\"type\":\"message_stop\"}");
    const out = (try s.finish()).success;
    try std.testing.expectEqual(@as(?u64, 20), out.usage.total());
    try std.testing.expectEqualStrings("{}", out.message.blocks[0].tool_call.arguments);
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":null}}");
    try std.testing.expectError(error.TruncatedStream, s.feed("", "{\"type\":\"message_stop\"}"));
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}");
    try std.testing.expectError(error.InvalidFinish, s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}"));
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try s.feed("", "{\"type\":\"message_delta\",\"delta\":{}}");
    try std.testing.expectError(error.InvalidStreamState, block(&s, 0, "{\"type\":\"text\",\"text\":\"late\"}"));
}

test "anthropic message delta optional stop metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { fields: []const u8, reason: []const u8 }{
        .{ .fields = "", .reason = "end_turn" },
        .{ .fields = ",\"stop_details\":null,\"container\":null", .reason = "end_turn" },
        .{ .fields = ",\"stop_details\":{\"type\":\"refusal\",\"category\":\"fixture\",\"explanation\":\"fixture\"},\"container\":{\"id\":\"container-fixture\",\"expires_at\":\"2030-01-01T00:00:00Z\",\"skills\":null}", .reason = "refusal" },
    }) |example| {
        var s = adapter.Stream.init(a, scope, .{});
        try s.feed("", start);
        try block(&s, 0, "{\"type\":\"text\",\"text\":\"\"}");
        try delta(&s, 0, "{\"type\":\"text_delta\",\"text\":\"OK\"}");
        try stop(&s, 0);
        try s.feed("message_delta", try std.fmt.allocPrint(a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":null,\"stop_sequence\":null{s}}},\"usage\":{{\"output_tokens\":2}}}}", .{example.fields}));
        try s.feed("message_delta", try std.fmt.allocPrint(a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\",\"stop_sequence\":null{s}}},\"usage\":{{\"input_tokens\":8,\"output_tokens\":4}}}}", .{ example.reason, example.fields }));
        try s.feed("message_stop", "{\"type\":\"message_stop\"}");
        const out = (try s.finish()).success;
        try std.testing.expectEqual(.stop, out.finish);
        try std.testing.expectEqualStrings("OK", out.message.blocks[0].text);
        try std.testing.expectEqual(@as(?u64, 22), out.usage.total());
        // These are response metadata, not assistant content or replay controls.
        try std.testing.expect(std.mem.indexOf(u8, out.message.replay.?.json, "stop_details") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.message.replay.?.json, "container-fixture") == null);
    }
}

test "anthropic message delta optional metadata rejects malformed shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "stop_details", "container" }) |field| {
        for ([_][]const u8{ "true", "0", "\"invalid\"", "[]" }) |value| {
            var s = adapter.Stream.init(a, scope, .{});
            try s.feed("", start);
            const payload = try std.fmt.allocPrint(a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\",\"{s}\":{s}}}}}", .{ field, value });
            try std.testing.expectError(error.InvalidEvent, s.feed("", payload));
            try std.testing.expectError(error.InvalidStreamState, s.finish());
        }
    }
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try std.testing.expectError(error.InvalidEvent, s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_details\":null,\"container\":null,\"tool_calls\":[]}}"));
}

test "anthropic message delta optional metadata preserves completion guards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const metadata_only = "{\"type\":\"message_delta\",\"delta\":{\"stop_details\":null,\"container\":null}}";
    const completed = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_details\":null,\"container\":null}}";
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try s.feed("", metadata_only);
    try std.testing.expectError(error.TruncatedStream, s.feed("", "{\"type\":\"message_stop\"}"));
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try s.feed("", completed);
    try std.testing.expectError(error.TruncatedStream, s.finish());
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"text\",\"text\":\"draft\"}");
    try std.testing.expectError(error.InvalidStreamState, s.feed("", completed));
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try s.feed("", completed);
    try std.testing.expectError(error.InvalidFinish, s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_details\":null,\"container\":null}}"));
    for ([_][]const u8{ "max_tokens", "pause_turn", "model_context_window_exceeded" }) |reason| {
        s = adapter.Stream.init(a, scope, .{});
        try s.feed("", start);
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\",\"stop_details\":null,\"container\":null}}}}", .{reason}));
        try s.feed("", "{\"type\":\"message_stop\"}");
        try std.testing.expect((try s.finish()) == .failure);
    }
}

test "anthropic signature fragments preserve initial bytes order and independent empty thinking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"YW\",\"extension\":1}");
    try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"\"}");
    try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"Jj\"}");
    try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"ZA==\"}");
    // Fragments must not overwrite the native start value before block stop.
    try std.testing.expectEqualStrings("YW", try c.text(s.open.?.native, "signature"));
    try stop(&s, 0);
    try block(&s, 1, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}");
    try delta(&s, 1, "{\"type\":\"thinking_delta\",\"thinking\":\"\"}");
    try delta(&s, 1, "{\"type\":\"signature_delta\",\"signature\":\"eH\"}");
    try delta(&s, 1, "{\"type\":\"signature_delta\",\"signature\":\"k=\"}");
    try delta(&s, 1, "{\"type\":\"signature_delta\",\"signature\":\"\"}");
    try stop(&s, 1);
    try block(&s, 2, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"eg==\"}");
    try stop(&s, 2);
    try end(&s, "end_turn");
    const out = (try s.finish()).success;
    try std.testing.expectEqual(@as(usize, 1), out.message.blocks.len);
    try std.testing.expectEqualStrings("plan", out.message.blocks[0].reasoning);
    try std.testing.expect(out.message.replay.?.retain_turn);
    const native = try j.parse(a, out.message.replay.?.json);
    const content = j.get(native, "content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), content.len);
    for (content, [_][]const u8{ "YWJjZA==", "eHk=", "eg==" }, 0..) |b, signature, index| {
        try std.testing.expectEqualStrings(signature, try c.text(b, "signature"));
        if (index != 0) try std.testing.expectEqualStrings("", try c.text(b, "thinking"));
    }
    try std.testing.expectEqual(@as(u64, 1), j.uint(j.get(content[0], "extension")).?);
    var req = request();
    req.messages = &.{out.message};
    const wire = try j.parse(a, try adapter.encode(a, req));
    const sent = j.get(wire, "messages").?.array.items[0];
    try std.testing.expectEqualStrings(out.message.replay.?.json, try j.encode(a, sent));
}

test "anthropic signature bounds poison and empty fragments remain bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}");
    try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"\"}");
    try std.testing.expect(!s.observedContent());
    // White-box length seam isolates the collector cap from the stricter
    // whole-SSE byte cap, without allocating a 16 MiB fixture.
    s.open.?.signature.len = c.max_bytes - 1;
    try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"A\"}");
    try std.testing.expectEqual(c.max_bytes, s.open.?.signature.len);
    try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"\"}");
    try std.testing.expectError(error.InputLimit, delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"B\"}"));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
    s = adapter.Stream.init(a, scope, .{});
    try s.feed("", start);
    try block(&s, 0, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}");
    s.events = 65536;
    try std.testing.expectError(error.InputLimit, delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"\"}"));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
}

test "anthropic fragmented signatures never authorize incomplete or capped replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..4) |stage| {
        var s = adapter.Stream.init(a, scope, .{});
        try s.feed("", start);
        try block(&s, 0, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"YW\"}");
        try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"Jj\"}");
        try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"ZA==\"}");
        try std.testing.expect(s.observedContent());
        if (stage > 0) try stop(&s, 0);
        if (stage > 1) try s.feed("", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}");
        if (stage > 2) try s.feed("", "{\"type\":\"message_stop\"}");
        if (stage < 3) {
            try std.testing.expectError(error.TruncatedStream, s.finish());
        } else {
            const out = try s.finish();
            try std.testing.expect(out == .failure);
            try std.testing.expectEqual(p.FailureKind.output_limit, out.failure.kind);
            try std.testing.expect(out.failure.observed_content);
        }
    }
}

test "anthropic signature fragments reject wrong block index and late deltas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |closed| {
        var s = adapter.Stream.init(a, scope, .{});
        try s.feed("", start);
        try block(&s, 0, "{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"YW\"}");
        try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"JjZA==\"}");
        if (closed) try stop(&s, 0);
        try std.testing.expectError(error.InconsistentItem, delta(&s, if (closed) 0 else 1, "{\"type\":\"signature_delta\",\"signature\":\"late\"}"));
        try std.testing.expectError(error.InvalidStreamState, s.finish());
    }
}

test "anthropic empty signature fragments cannot create replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "plan" }) |thinking| {
        var s = adapter.Stream.init(a, scope, .{});
        try s.feed("", start);
        try block(&s, 0, try std.fmt.allocPrint(a, "{{\"type\":\"thinking\",\"thinking\":\"{s}\",\"signature\":\"\"}}", .{thinking}));
        try delta(&s, 0, "{\"type\":\"signature_delta\",\"signature\":\"\"}");
        try stop(&s, 0);
        try end(&s, "end_turn");
        try std.testing.expectError(error.InvalidReplay, s.finish());
    }
}

test "anthropic arena allocation failures propagate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}
