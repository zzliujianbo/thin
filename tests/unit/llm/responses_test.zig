test "responses normalized safety flags preserve native output and known tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outputs = [_][]const u8{
        "[{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"vendor\":1,\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]",
        "[{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"\"}]}]",
        "[{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_part\",\"value\":1}]}]",
        "[{\"id\":\"x\",\"type\":\"future_item\",\"value\":1}]",
        "[{\"id\":\"f\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"}]",
        "[{\"id\":\"r\",\"type\":\"reasoning\",\"encrypted_content\":\"secret\"}]",
    };
    for (outputs, 0..) |output, i| {
        var s = Stream.init(a, test_support.response_scope, .{});
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"response.completed\",\"response\":{{\"status\":\"completed\",\"output\":{s}}}}}", .{output}));
        const response = (try s.finish()).success;
        try std.testing.expectEqual(i == 1, response.refused);
        try std.testing.expectEqual(i == 2 or i == 3, response.unsupported_output);
        try std.testing.expectEqualStrings(output, response.message.replay.?.json);
        if (i == 0) try std.testing.expectEqualStrings("ok", response.message.blocks[0].text);
        if (i == 4) {
            try std.testing.expect(response.finish == .tool_calls);
            try std.testing.expectEqualStrings("c", response.message.blocks[0].tool_call.id);
        }
        if (i != 4) try std.testing.expect(response.message.replay.?.retain_turn or i == 1);
    }
}
test "responses omits all output caps regardless of model capacity and purpose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var req = test_support.request(.responses);
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
test "codex request fields and terminal done" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var req = test_support.request(.responses);
    req.reasoning_effort = "high";
    const wire = try j.parse(a, try encodeCodex(a, req));
    try std.testing.expectEqualStrings("low", try c.text(j.get(wire, "text").?, "verbosity"));
    try std.testing.expect(j.get(j.get(wire, "reasoning").?, "summary") == null);
    const ordinary = try j.parse(a, try encode(a, req));
    try std.testing.expect(j.get(ordinary, "include") != null);
    try std.testing.expectEqualStrings("reasoning.encrypted_content", (try c.list(j.get(wire, "include").?))[0].string);
    try std.testing.expect(j.get(wire, "parallel_tool_calls").?.bool);
    req.system = " ";
    try std.testing.expectError(error.EmptyInstructions, encodeCodex(a, req));
    var stream = Stream.init(a, test_support.response_scope, .{});
    try stream.feed("", "{\"type\":\"response.done\",\"response\":{\"status\":\"completed\",\"output\":[]}}");
    try std.testing.expect((try stream.finish()) == .success);
    var incomplete = Stream.init(a, test_support.response_scope, .{});
    try incomplete.feed("", "{\"type\":\"response.done\",\"response\":{\"status\":\"incomplete\"}}");
    try std.testing.expect((try incomplete.finish()) == .failure);
}
test "codex done failures retain usage and discard partial tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "failed", "unknown", "incomplete" }) |status| {
        var s = Stream.init(a, test_support.response_scope, .{});
        try s.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"call\",\"name\":\"f\",\"arguments\":\"\"}}");
        try s.feed("", "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc\",\"delta\":\"{\"}");
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"response.done\",\"response\":{{\"status\":\"{s}\",\"incomplete_details\":{{\"reason\":\"max_output_tokens\"}},\"usage\":{{\"output_tokens\":17}}}}}}", .{status}));
        const failure = (try s.finish()).failure;
        try std.testing.expectEqual(if (std.mem.eql(u8, status, "incomplete")) p.FailureKind.output_limit else p.FailureKind.model, failure.kind);
        try std.testing.expectEqual(@as(?u64, 17), failure.usage.output_tokens);
        try std.testing.expect(failure.raw_usage_json != null and failure.observed_content);
    }
}
test "responses output limit explicit cap with reasoning or partial tool never commits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |tool| {
        var s = Stream.init(a, test_support.response_scope, .{});
        if (tool) {
            try s.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"call\",\"name\":\"f\",\"arguments\":\"\"}}");
            try s.feed("", "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc\",\"delta\":\"{\"}");
        } else try s.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"r\"}}");
        try s.feed("response.incomplete", "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"output_tokens\":4096,\"output_tokens_details\":{\"reasoning_tokens\":4096}}}}");
        const f = (try s.finish()).failure;
        try std.testing.expectEqual(p.FailureKind.output_limit, f.kind);
        try std.testing.expect(f.observed_content and f.raw_usage_json != null);
        try std.testing.expectEqual(@as(?u64, 4096), f.usage.output_tokens);
        try std.testing.expectEqual(@as(?u64, 4096), f.usage.reasoning_tokens);
        try std.testing.expectError(error.InvalidStreamState, s.finish());
    }
}
test "responses closed partial tool arguments wait for authoritative terminal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = "{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"call\",\"name\":\"f\",\"arguments\":\"{\"}";
    for ([_]bool{ false, true }) |item_done| {
        for (0..3) |terminal| {
            var s = Stream.init(a, test_support.response_scope, .{});
            try s.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"call\",\"name\":\"f\",\"arguments\":\"\"}}");
            try s.feed("", "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc\",\"delta\":\"{\"}");
            try s.feed("", "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc\",\"arguments\":\"{\"}");
            if (item_done) try s.feed("", "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ native ++ "}");
            switch (terminal) {
                0 => {
                    try s.feed("", "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"output_tokens\":4096}}}");
                    const failure = (try s.finish()).failure;
                    try std.testing.expectEqual(p.FailureKind.output_limit, failure.kind);
                    try std.testing.expectEqual(@as(?u64, 4096), failure.usage.output_tokens);
                    try std.testing.expect(failure.observed_content and failure.raw_usage_json != null);
                },
                1 => {
                    try std.testing.expectError(error.InvalidToolArguments, s.feed("", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[" ++ native ++ "]}}"));
                    try std.testing.expectError(error.InvalidStreamState, s.finish());
                },
                else => try std.testing.expectError(error.TruncatedStream, s.finish()),
            }
        }
    }
}
test "responses output limit requires exact incomplete reason and valid types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{}", "{\"reason\":null}", "{\"reason\":\"unknown\"}", "{\"reason\":\"content_filter\"}" }) |details| {
        var s = Stream.init(a, test_support.response_scope, .{});
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"response.incomplete\",\"response\":{{\"incomplete_details\":{s},\"usage\":{{\"output_tokens\":4096,\"output_tokens_details\":{{\"reasoning_tokens\":4096}}}}}}}}", .{details}));
        try std.testing.expectEqual(p.FailureKind.model, (try s.finish()).failure.kind);
    }
    for ([_][]const u8{ "response.failed", "error" }) |kind| {
        var s = Stream.init(a, test_support.response_scope, .{});
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"{s}\",\"response\":{{\"incomplete_details\":{{\"reason\":\"max_output_tokens\"}}}}}}", .{kind}));
        try std.testing.expectEqual(p.FailureKind.model, (try s.finish()).failure.kind);
    }
    for ([_][]const u8{ "[]", "{\"incomplete_details\":[]}", "{\"incomplete_details\":{\"reason\":7}}", "{\"status\":\"completed\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}", "{\"status\":7,\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}" }) |response| {
        var s = Stream.init(a, test_support.response_scope, .{});
        try std.testing.expectError(error.InvalidEvent, s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"response.incomplete\",\"response\":{s}}}", .{response})));
        try std.testing.expectError(error.InvalidStreamState, s.finish());
    }
    var s = Stream.init(a, test_support.response_scope, .{});
    const cap = "{\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}";
    try std.testing.expectError(error.EventTypeMismatch, s.feed("response.completed", cap));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
    s = Stream.init(a, test_support.response_scope, .{});
    try s.feed("", cap);
    try std.testing.expectError(error.InvalidStreamState, s.feed("", cap));
    try std.testing.expectError(error.InvalidStreamState, s.finish());
}
test "responses usage cumulative snapshots survive incomplete without content lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder: test_support.Recorder = .{};
    var s = Stream.init(arena.allocator(), test_support.response_scope, recorder.sink());
    try s.feed("", "{\"type\":\"response.in_progress\",\"response\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}");
    try std.testing.expect(!s.observedContent());
    try s.feed("", "{\"type\":\"response.incomplete\",\"response\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":4}}}");
    const failure = (try s.finish()).failure;
    try std.testing.expectEqual(@as(?u64, 14), failure.usage.total());
    try std.testing.expectEqual(@as(?u64, 14), recorder.usage.total());
    try std.testing.expectEqual(@as(usize, 2), recorder.snapshots);
    try std.testing.expectEqual(@as(usize, 0), recorder.drafts);
    try std.testing.expect(failure.raw_usage_json != null and !failure.observed_content);
}
test "responses write preview starts with the item name and counts only received arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = test_support.Recorder{};
    var stream = Stream.init(arena.allocator(), test_support.response_scope, recorder.sink());
    try stream.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"item-0\",\"type\":\"function_call\",\"call_id\":\"write-0\",\"name\":\"write_file\",\"arguments\":\"\"}}");
    try std.testing.expect(recorder.preview_write);
    try std.testing.expectEqual(@as(usize, 0), recorder.preview_bytes);
    try stream.feed("", "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"item-0\",\"output_index\":0,\"delta\":\"{}\"}");
    try std.testing.expect(recorder.preview_write);
    try std.testing.expectEqual(@as(usize, 2), recorder.preview_bytes);
    try std.testing.expectEqual(@as(usize, 2), recorder.drafts);
}
test "responses text drafts commit final native order and guard identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = Stream.init(a, test_support.response_scope, .{});
    try s.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"r\",\"type\":\"reasoning\"}}");
    try s.feed("", "{\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"item_id\":\"r\",\"delta\":\"thought\"}");
    try s.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\"}}");
    try s.feed("", "{\"type\":\"response.output_text.delta\",\"output_index\":1,\"item_id\":\"m\",\"delta\":\"hello\"}");
    try s.feed("", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"id\":\"r\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"thought\"}],\"encrypted_content\":\"opaque\"},{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}]}}");
    try s.feed("", "[DONE]");
    const out = (try s.finish()).success;
    try std.testing.expectEqualStrings("thought", out.message.blocks[0].reasoning);
    try std.testing.expectEqualStrings("hello", out.message.blocks[1].text);

    var req = test_support.request(.responses);
    req.messages = &.{out.message};
    _ = try encode(a, req);

    var bad = Stream.init(a, test_support.response_scope, .{});
    try bad.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"a\",\"name\":\"lookup\"}}");
    try std.testing.expectError(error.InconsistentItem, bad.feed("", "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"WRONG\",\"delta\":\"{}\"}"));
    try std.testing.expectError(error.InvalidStreamState, bad.finish());
    var event_mismatch = Stream.init(a, test_support.response_scope, .{});
    try std.testing.expectError(error.EventTypeMismatch, event_mismatch.feed("response.completed", "{\"type\":\"response.created\"}"));
    var unlimited = Stream.init(a, test_support.response_scope, .{});
    for (0..65537) |_| try unlimited.feed("", "{\"type\":\"response.in_progress\"}");
    try unlimited.feed("", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}");
    const unlimited_result = (try unlimited.finish()).success;
    try std.testing.expectEqual(p.Finish.stop, unlimited_result.finish);

    req.messages = &.{ .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "a", .item_id = "fc", .name = "lookup", .arguments = "{}" } }} }, .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "a", .text = "done" } }} } };
    _ = try encode(a, req);
    req.messages = &.{.{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "missing", .text = "done" } }} }};
    try std.testing.expectError(error.UnmatchedToolResult, encode(a, req));
}
test "responses native request opaque replay scope and summary stability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = "[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"OPAQUE\",\"summary\":[]},{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"lookup\",\"arguments\":\"{}\",\"status\":\"completed\"}]";
    var req = test_support.request(.responses);
    req.messages = &.{
        .{ .role = .context, .blocks = &.{.{ .text = "data" }} },
        .{ .role = .assistant, .blocks = &.{}, .replay = .{ .scope = test_support.response_scope, .json = native } },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "call_1", .text = "found" } }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "answer" }} },
    };

    const wire = try encode(a, req);
    const v = try j.parse(a, wire);
    try std.testing.expect(j.get(v, "messages") == null);
    try std.testing.expectEqualStrings(req.system, try c.text(v, "instructions"));
    const input = j.get(v, "input").?.array.items;
    try std.testing.expectEqualStrings("user", try c.text(input[0], "role"));
    try test_support.contains(try j.encode(a, input[0]), "input_text");
    try test_support.contains(try j.encode(a, input[4]), "output_text");
    try std.testing.expectEqualStrings("OPAQUE", try c.text(input[1], "encrypted_content"));
    try std.testing.expectEqualStrings("call_1", try c.text(input[3], "call_id"));
    try std.testing.expect(j.get(v, "previous_response_id") == null and j.get(v, "conversation") == null);
    try std.testing.expect(!j.get(v, "store").?.bool);
    try std.testing.expect(j.get(v, "reasoning") == null);

    req.purpose = .summary;
    const summary = try j.parse(a, try encode(a, req));
    try std.testing.expectEqualStrings(try j.encode(a, j.get(v, "input").?), try j.encode(a, j.get(summary, "input").?));
    try std.testing.expectEqualStrings(try j.encode(a, j.get(v, "tools").?), try j.encode(a, j.get(summary, "tools").?));
    try std.testing.expectEqualStrings(req.system, try c.text(summary, "instructions"));

    req.reasoning_effort = "medium";
    const configured = try j.parse(a, try encode(a, req));
    try std.testing.expectEqualStrings("medium", try c.text(j.get(configured, "reasoning").?, "effort"));

    req.scope.model = "different";
    try std.testing.expectError(error.ReplayScopeMismatch, encode(a, req));
}
test "thinking actual responses mapping and rejects deepseek including unspecified" {
    const thinking = @import("../core/thinking.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var req = test_support.request(.responses);
    const standard = thinking.resolve("https://api.openai.com/v1", "gpt-6-sol", .{ .map = .{ .off = "none", .max = "max" } });
    req.reasoning_effort = standard.wire("off").effort;
    var v = try j.parse(a, try encode(a, req));
    try std.testing.expectEqualStrings("none", try c.text(j.get(v, "reasoning").?, "effort"));
    req.reasoning_effort = standard.wire("max").effort;
    v = try j.parse(a, try encode(a, req));
    try std.testing.expectEqualStrings("max", try c.text(j.get(v, "reasoning").?, "effort"));
    const custom = thinking.resolve("https://proxy", "custom", .{ .map = .{ .high = "own-wire" } });
    req.reasoning_effort = custom.wire("medium").effort;
    v = try j.parse(a, try encode(a, req));
    try std.testing.expectEqualStrings("own-wire", try c.text(j.get(v, "reasoning").?, "effort"));
    req.reasoning_effort = null;
    req.reasoning_format = .deepseek;
    try std.testing.expectError(error.IncompatibleReasoningProtocol, encode(a, req));
    req.reasoning_format = .standard;
    req.thinking = false;
    try std.testing.expectError(error.IncompatibleReasoningProtocol, encode(a, req));
}
test "responses interleaved real IDs authoritative native output and usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = Stream.init(a, test_support.response_scope, .{});
    try s.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_a\",\"call_id\":\"call_a\",\"name\":\"lookup\",\"arguments\":\"\"}}");
    try s.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_b\",\"call_id\":\"call_b\",\"name\":\"lookup\",\"arguments\":\"\"}}");
    try s.feed("", "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"item_id\":\"fc_b\",\"delta\":\"{\"}");
    try s.feed("", "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc_a\",\"delta\":\"{\\\"q\\\":1}\"}");
    try s.feed("", "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"item_id\":\"fc_b\",\"delta\":\"}\"}");
    try s.feed("", "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc_a\",\"arguments\":\"{\\\"q\\\":1}\"}");
    try s.feed("", "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_a\",\"call_id\":\"call_a\",\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":1}\"}}");
    try s.feed("response.completed", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"fc_a\",\"call_id\":\"call_a\",\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":1}\"},{\"type\":\"function_call\",\"id\":\"fc_b\",\"call_id\":\"call_b\",\"name\":\"lookup\",\"arguments\":\"{}\"},{\"type\":\"reasoning\",\"id\":\"rs\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"plan\"}],\"encrypted_content\":\"secret opaque\"},{\"type\":\"message\",\"id\":\"msg\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}],\"usage\":{\"input_tokens\":11,\"output_tokens\":5,\"input_tokens_details\":{\"cached_tokens\":8},\"output_tokens_details\":{\"reasoning_tokens\":3}}}}");
    const out = (try s.finish()).success;

    try std.testing.expectEqual(p.Finish.tool_calls, out.finish);
    try std.testing.expectEqualStrings("call_a", out.message.blocks[0].tool_call.id);
    try std.testing.expectEqualStrings("fc_a", out.message.blocks[0].tool_call.item_id.?);
    try std.testing.expectEqualStrings("call_b", out.message.blocks[1].tool_call.id);
    try std.testing.expectEqualStrings("plan", out.message.blocks[2].reasoning);
    try std.testing.expectEqualStrings("answer", out.message.blocks[3].text);
    try std.testing.expectEqual(@as(?u64, 16), out.usage.total());
    try std.testing.expectEqual(@as(?u64, 8), out.usage.cached_input_tokens);
    try std.testing.expectEqual(@as(?u64, 3), out.usage.reasoning_tokens);
    try test_support.contains(out.message.replay.?.json, "secret opaque");
    try std.testing.expect(s.observedContent());
}
test "responses rejects incomplete truncation contradictions malformed args and duplicate IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "response.incomplete", "response.failed", "error" }) |kind| {
        var s = Stream.init(a, test_support.response_scope, .{});
        try s.feed("", try std.fmt.allocPrint(a, "{{\"type\":\"{s}\",\"message\":\"secret-key\"}}", .{kind}));
        const f = (try s.finish()).failure;
        try std.testing.expect(std.mem.indexOf(u8, f.message, "secret-key") == null);
    }

    var truncated = Stream.init(a, test_support.response_scope, .{});
    try truncated.feed("", "{\"type\":\"response.created\"}");
    try std.testing.expectError(error.TruncatedStream, truncated.finish());

    var missing = Stream.init(a, test_support.response_scope, .{});
    try std.testing.expectError(error.InvalidEvent, missing.feed("", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}"));

    var bad = Stream.init(a, test_support.response_scope, .{});
    try std.testing.expectError(error.InvalidToolArguments, bad.feed("", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"c\",\"name\":\"lookup\",\"arguments\":\"[]\"}]}}"));

    var duplicate = Stream.init(a, test_support.response_scope, .{});
    try std.testing.expectError(error.DuplicateToolId, duplicate.feed("", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"fc1\",\"call_id\":\"c\",\"name\":\"lookup\",\"arguments\":\"{}\"},{\"type\":\"function_call\",\"id\":\"fc2\",\"call_id\":\"c\",\"name\":\"lookup\",\"arguments\":\"{}\"}]}}"));

    var mismatch = Stream.init(a, test_support.response_scope, .{});
    try mismatch.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"c\",\"name\":\"lookup\",\"arguments\":\"\"}}");
    try mismatch.feed("", "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc\",\"delta\":\"{}\"}");
    try std.testing.expectError(error.InconsistentToolArguments, mismatch.feed("", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"c\",\"name\":\"lookup\",\"arguments\":\"{\\\"x\\\":1}\"}]}}"));

    var unknown = Stream.init(a, test_support.response_scope, .{});
    try unknown.feed("", "{\"type\":\"future.informational\",\"extra\":1}");
    try unknown.feed("", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}");
    const out = (try unknown.finish()).success;
    try std.testing.expectEqual(@as(?u64, null), out.usage.total());
}
test "responses refusal drafts survive failure and commit native refusal exactly once" {
    const Drafts = struct {
        a: std.mem.Allocator,
        text: std.ArrayList(u8) = .empty,
        count: usize = 0,

        fn emit(context: ?*anyopaque, event: p.ModelEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (event) {
                .text_delta => |delta| {
                    try self.text.appendSlice(self.a, delta);
                    self.count += 1;
                },
                else => return error.UnexpectedModelEvent,
            }
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |fail| {
        var drafts = Drafts{ .a = a };
        var s = Stream.init(a, test_support.response_scope, .{ .context = &drafts, .emit_fn = Drafts.emit });
        try s.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\"}}");
        try std.testing.expect(!s.observedContent());
        try s.feed("", "{\"type\":\"response.refusal.delta\",\"output_index\":0,\"item_id\":\"m\",\"delta\":\"Cannot \"}");
        try s.feed("", "{\"type\":\"response.refusal.delta\",\"output_index\":0,\"item_id\":\"m\",\"delta\":\"help.\"}");
        try std.testing.expectEqualStrings("Cannot help.", drafts.text.items);
        try std.testing.expectEqual(@as(usize, 2), drafts.count);
        try std.testing.expect(s.observedContent());
        if (fail) {
            try s.feed("", "{\"type\":\"response.failed\"}");
            try std.testing.expect((try s.finish()).failure.observed_content);
        } else {
            // Deliberately differs from the draft to catch concatenation/reuse.
            try s.feed("", "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"Native refusal.\"}]}]}}");
            const out = (try s.finish()).success;
            try std.testing.expectEqual(@as(usize, 1), out.message.blocks.len);
            try std.testing.expectEqualStrings("Native refusal.", out.message.blocks[0].text);
            const native = try j.parse(a, out.message.replay.?.json);
            const content = j.get(native.array.items[0], "content").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), content.len);
            try std.testing.expectEqualStrings("refusal", try c.text(content[0], "type"));
            try std.testing.expectEqualStrings("Native refusal.", try c.text(content[0], "refusal"));
        }
        try std.testing.expectEqualStrings("Cannot help.", drafts.text.items);
        try std.testing.expectEqual(@as(usize, 2), drafts.count);
    }
}
test "responses refusal guards identity kind done and empty observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const added = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\"}}";
    const delta = "{\"type\":\"response.refusal.delta\",\"output_index\":0,\"item_id\":\"m\",\"delta\":\"No\"}";
    var empty = Stream.init(a, test_support.response_scope, .{});
    try empty.feed("", added);
    try empty.feed("", "{\"type\":\"response.refusal.delta\",\"output_index\":0,\"item_id\":\"m\",\"delta\":\"\"}");
    try std.testing.expect(!empty.observedContent());
    try empty.feed("", "{\"type\":\"response.failed\"}");
    try std.testing.expect(!(try empty.finish()).failure.observed_content);

    var wrong_id = Stream.init(a, test_support.response_scope, .{});
    try wrong_id.feed("", added);
    try std.testing.expectError(error.InconsistentItem, wrong_id.feed("", "{\"type\":\"response.refusal.delta\",\"output_index\":0,\"item_id\":\"wrong\",\"delta\":\"No\"}"));
    try std.testing.expectError(error.InvalidStreamState, wrong_id.finish());

    var wrong_index = Stream.init(a, test_support.response_scope, .{});
    try wrong_index.feed("", added);
    try std.testing.expectError(error.InconsistentItem, wrong_index.feed("", "{\"type\":\"response.refusal.delta\",\"output_index\":1,\"item_id\":\"m\",\"delta\":\"No\"}"));

    var done = Stream.init(a, test_support.response_scope, .{});
    try done.feed("", added);
    try done.feed("", "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"No\"}]}}");
    try std.testing.expectError(error.InvalidStreamState, done.feed("", delta));
    try std.testing.expectError(error.InvalidStreamState, done.finish());

    var wrong_kind = Stream.init(a, test_support.response_scope, .{});
    try wrong_kind.feed("", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"reasoning\"}}");
    try std.testing.expectError(error.InconsistentItem, wrong_kind.feed("", delta));
}
