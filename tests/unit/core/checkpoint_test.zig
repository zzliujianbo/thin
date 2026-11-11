test "checkpoint DTO excludes OAuth config and preserves frozen context" {
    var config = fixture_config;
    config.provider.codex_oauth = .{ .access_token = "access-canary-private", .refresh_token = "refresh-canary-private", .expires_at_ms = 1 };
    var state = fixture(.responses);
    state.context_tokens = config.model.context_tokens;
    const bytes = try encode(std.testing.allocator, state);
    defer std.testing.allocator.free(bytes);
    for ([_][]const u8{ "access-canary-private", "refresh-canary-private", "codex_oauth" }) |secret| try std.testing.expect(std.mem.indexOf(u8, bytes, secret) == null);
    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(state.context_tokens, decoded.value.context_tokens);
    try std.testing.expectEqual(state.selector.selected, decoded.value.selector.selected);
}
test "checkpoint tagged union exact Chat and Responses roundtrip and opaque replay" {
    inline for (.{ p.Protocol.chat, p.Protocol.responses }) |proto| {
        const original = fixture(proto);
        const bytes = try encode(std.testing.allocator, original);
        defer std.testing.allocator.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"tool_call\":{") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"tool_result\":{") != null);
        const parsed = try decode(std.testing.allocator, bytes);
        defer parsed.deinit();
        try std.testing.expectEqualDeep(original, parsed.value);
        const again = try encode(std.testing.allocator, parsed.value);
        defer std.testing.allocator.free(again);
        try std.testing.expectEqualStrings(bytes, again);
        try validateRequestHistory(std.testing.allocator, fixtureRequest(parsed.value, fixture_config));
    }
}
test "Anthropic checkpoint exact native canonical pairing and signed opaque roundtrip" {
    const a = std.testing.allocator;
    var state = fixture(.chat);
    var config = fixture_config;
    config.model.protocol = .anthropic;
    state.selector.configured = .anthropic;
    state.selector.selected = .anthropic;
    var messages = state.messages[0..4].*;
    state.messages = &messages;
    var blocks = messages[2].blocks[0..3].*;
    messages[2].blocks = &blocks;
    messages[2].replay.?.scope.protocol = .anthropic;
    messages[2].replay.?.json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"signature\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque\"},{\"type\":\"text\",\"text\":\"answer\"},{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"lookup\",\"input\":{}}]}";
    try validateRequestHistory(a, fixtureRequest(state, config));
    const bytes = try encode(a, state);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try validateRequestHistory(a, fixtureRequest(parsed.value, config));
    try std.testing.expectEqualDeep(state, parsed.value);
    blocks[1] = .{ .text = "changed" };
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, config)));
    blocks[1] = .{ .text = "answer" };
    blocks[2].tool_call.item_id = "foreign-item";
    try std.testing.expectError(error.InvalidHistory, validateRequestHistory(a, fixtureRequest(state, config)));
    blocks[2].tool_call.item_id = null;
    messages[2].replay.?.retain_turn = false;
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, config)));
    messages[2].replay.?.retain_turn = true;
    messages[2].replay.?.scope.protocol = .chat;
    try std.testing.expectError(error.ReplayScopeMismatch, validateRequestHistory(a, fixtureRequest(state, config)));
}
test "checkpoint requires every emitted field recursively including nullable defaults" {
    const a = std.testing.allocator;
    const bytes = try encode(a, fixture(.chat));
    defer a.free(bytes);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tree = try strictJson(arena.allocator(), bytes);
    defer tree.deinit();
    try assertRequiredFields(State, arena.allocator(), tree.value);
    // Each removal starts with the current encoder's complete valid DTO.
    const removals = [_][]const u8{
        "\"version\":2,",              "\"context_tokens\":null,", "\"context_official\":false,",
        ",\"initial_attempted\":true", "\"per_mille\":1234",       ",\"replay\":null",
        ",\"item_id\":null",           "\"canceled\":true,",       ",\"retain_turn\":true",
    };
    for (removals) |field| {
        const missing = try std.mem.replaceOwned(u8, a, bytes, field, "");
        defer a.free(missing);
        try std.testing.expect(missing.len < bytes.len);
        try std.testing.expectError(error.MissingField, decode(a, missing));
    }
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try validateStructure(parsed.value);
    try validateRequestHistory(a, fixtureRequest(parsed.value, fixture_config));
}
test "checkpoint display accepts representable stale budgets and provenance but not wrong types" {
    const a = std.testing.allocator;
    var state = fixture(.chat);
    for ([_]u32{ 0, 16 * 1024 * 1024 + 1, std.math.maxInt(u32) }) |tokens| {
        state.context_tokens = tokens;
        state.output_tokens = tokens;
        state.input_price_threshold = tokens;
        state.input_margin_tokens = tokens;
        const bytes = try encode(a, state);
        defer a.free(bytes);
        const parsed = try decode(a, bytes);
        defer parsed.deinit();
        try std.testing.expectEqualDeep(state, parsed.value);
    }
    state.context_tokens = null;
    state.context_official = true;
    const bytes = try encode(a, state);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    for ([_][]const u8{ "\"context_tokens\":\"32768\"", "\"context_tokens\":1.0", "\"context_tokens\":-1", "\"context_tokens\":4294967296" }) |replacement| {
        const bad = try std.mem.replaceOwned(u8, a, bytes, "\"context_tokens\":null", replacement);
        defer a.free(bad);
        try badDecode(bad);
    }
}
test "checkpoint exact capacity provenance roundtrip and config match preserve validation" {
    const a = std.testing.allocator;
    inline for (.{ p.Protocol.chat, p.Protocol.responses }) |proto| {
        for ([_]u32{ 1, 65536, 16 * 1024 * 1024 }) |tokens| {
            for ([_]bool{ false, true }) |official| {
                var state = fixture(proto);
                state.context_tokens = tokens;
                state.context_official = official;
                const bytes = try encode(a, state);
                defer a.free(bytes);
                const parsed = try decode(a, bytes);
                defer parsed.deinit();
                try std.testing.expectEqualDeep(state, parsed.value);
                try validateRequestHistory(a, fixtureRequest(parsed.value, fixture_config));
                var config = fixture_config;
                config.model.context_tokens = tokens;
                try validateRequestHistory(a, fixtureRequest(parsed.value, config));
                state.estimator.per_mille = 999;
                try validateRequestHistory(a, fixtureRequest(state, config));
                state.estimator = parsed.value.estimator;
                state.messages = state.messages[0..3];
                try std.testing.expectError(error.IncompleteToolGroup, validateRequestHistory(a, fixtureRequest(state, config)));
            }
        }
    }
}
test "checkpoint allocation failures clean every owned parse and validation arena" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationRoundtrip, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
test "checkpoint strict duplicate unknown type version UTF8 depth and size" {
    const a = std.testing.allocator;
    const bytes = try encode(a, fixture(.chat));
    defer a.free(bytes);
    for ([_][]const u8{
        "\"version\":2,", "\"unknown\":true,", "\"permission_id\":\"1\",",
    }) |injection| {
        const bad = try std.fmt.allocPrint(a, "{{{s}{s}", .{ injection, bytes[1..] });
        defer a.free(bad);
        try badDecode(bad);
    }
    // Replacing the actual field (rather than injecting a duplicate) catches
    // std.json's permissive integer/string, float/integer and enum conversions.
    for ([_][]const u8{ "\"1\"", "1.0", "true", "1", "null", "-1" }) |v| {
        const bad = try std.mem.replaceOwned(u8, a, bytes, "\"version\":2", tryVersionPrefix(v));
        defer a.free(bad);
        try badDecode(bad);
    }
    const enum_bad = try std.mem.replaceOwned(u8, a, bytes, "\"role\":\"context\"", "\"role\":3");
    defer a.free(enum_bad);
    try badDecode(enum_bad);
    const union_bad = try std.mem.replaceOwned(u8, a, bytes, "\"reasoning\":\"plan\"", "\"reasoning\":\"plan\",\"text\":\"plan\"");
    defer a.free(union_bad);
    try badDecode(union_bad);
    try badDecode("{\"version\":1,\"system\":\"\xff\"}");
    var deep: [130]u8 = undefined;
    @memset(deep[0..65], '[');
    @memset(deep[65..], ']');
    try std.testing.expectError(error.InputLimit, decode(a, &deep));
    const huge = try a.alloc(u8, max_bytes + 1);
    defer a.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(error.InputLimit, decode(a, huge));
    var state = fixture(.chat);
    state.version = 1;
    try std.testing.expectError(error.UnsupportedVersion, encode(a, state));
    state.version = 2;
    state.system = huge;
    try std.testing.expectError(error.InputLimit, encode(a, state));
    // Escaping expands input beyond the limit: the counting pass, not a late
    // post-allocation check, must reject it.
    @memset(huge[0 .. max_bytes / 2], '\n');
    state.system = huge[0 .. max_bytes / 2];
    try std.testing.expectError(error.InputLimit, encode(a, state));
}
test "SystemOne history remains structural data but cannot authorize chat requests" {
    const a = std.testing.allocator;
    var state = fixture(.chat);
    state.selector = llm.Selector.init(.systemone);
    const bytes = try encode(a, state);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(state, parsed.value);
    var config = fixture_config;
    config.model.protocol = .systemone;
    try std.testing.expectError(error.SystemOneNotChatModel, validateRequestHistory(a, fixtureRequest(parsed.value, config)));
}
test "checkpoint loads poison estimator selector independently from pre-send scope checks" {
    const a = std.testing.allocator;
    var s = fixture(.chat);
    s.poisoned = true;
    s.estimator.per_mille = 0;
    s.selector = .{ .configured = .anthropic, .selected = .auto };
    const bytes = try encode(a, s);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(s, parsed.value);
    s = fixture(.chat);
    var config = fixture_config;
    config.provider.base_url = "https://other.invalid";
    try std.testing.expectError(error.ReplayScopeMismatch, validateRequestHistory(a, fixtureRequest(s, config)));
    config = fixture_config;
    config.model.name = "another-model";
    try std.testing.expectError(error.ReplayScopeMismatch, validateRequestHistory(a, fixtureRequest(s, config)));
    s.selector.selected = .responses;
    try std.testing.expectError(error.ReplayScopeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
}
test "checkpoint roles closure global duplicate ids argument objects and bounds" {
    const a = std.testing.allocator;
    var s = fixture(.chat);
    s.messages = s.messages[0..3];
    try std.testing.expectError(error.IncompleteToolGroup, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    const good = fixture(.chat);
    var messages = [_]p.Message{ good.messages[2], good.messages[3], good.messages[2], good.messages[3] };
    s.messages = &messages;
    try std.testing.expectError(error.DuplicateToolId, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    s.messages = &.{good.messages[3]};
    try std.testing.expectError(error.OrphanToolResult, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    for ([_]p.Role{ .user, .context, .tool }) |role| {
        s.messages = &.{.{ .role = role, .blocks = &.{.{ .reasoning = "bad" }} }};
        try std.testing.expectError(error.InvalidHistory, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    }
    s.messages = &.{.{ .role = .tool, .blocks = &.{.{ .text = "bad" }} }};
    try std.testing.expectError(error.InvalidHistory, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    s.messages = &.{.{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "c", .name = "lookup", .arguments = "[]" } }} }};
    try std.testing.expectError(error.InvalidToolArguments, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    const many = try a.alloc(p.Message, 1025);
    defer a.free(many);
    @memset(many, .{ .role = .user, .blocks = &.{} });
    s.messages = many;
    try std.testing.expectError(error.InputLimit, encode(a, s));
    const blocks = try a.alloc(p.Block, 1025);
    defer a.free(blocks);
    @memset(blocks, .{ .text = "" });
    s.messages = &.{.{ .role = .user, .blocks = blocks }};
    try std.testing.expectError(error.InputLimit, encode(a, s));
    s.messages = &.{ .{ .role = .user, .blocks = blocks[0..600] }, .{ .role = .user, .blocks = blocks[600..] } };
    try std.testing.expectError(error.InputLimit, encode(a, s));
}
test "checkpoint accepts out of order Chat arrival without weakening call identity" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stream = chat.Stream.init(arena.allocator(), .{
        .connection = fixture_config.provider.base_url,
        .model = fixture_config.model.name,
        .protocol = .chat,
    }, .{});
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]}}]}");
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"x\\\":1}\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    try stream.feed("", "[DONE]");
    const outcome = try stream.finish();
    const message = switch (outcome) {
        .success => |value| value.message,
        .failure => return error.UnexpectedStreamFailure,
    };
    try std.testing.expectEqualStrings("b", message.blocks[0].tool_call.id);
    var blocks = [_]p.Block{ message.blocks[0], message.blocks[1] };
    var messages = [_]p.Message{
        message,
        .{ .role = .tool, .blocks = &.{
            .{ .tool_result = .{ .call_id = "b", .text = "result b" } },
            .{ .tool_result = .{ .call_id = "a", .text = "result a" } },
        } },
    };
    messages[0].blocks = &blocks;
    var state = fixture(.chat);
    state.messages = &messages;
    try validateRequestHistory(a, fixtureRequest(state, fixture_config));
    const bytes = try encode(a, state);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try validateRequestHistory(a, fixtureRequest(parsed.value, fixture_config));
    try std.testing.expectEqualDeep(state, parsed.value);
    blocks[0].tool_call.arguments = "{\"x\":1}";
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, fixture_config)));
    blocks[0] = message.blocks[0];
    blocks[0].tool_call.name = "different";
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, fixture_config)));
    blocks[0] = message.blocks[0];
    blocks[0].tool_call.id = "missing";
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, fixture_config)));
    blocks[0] = message.blocks[1];
    try std.testing.expectError(error.DuplicateToolId, validateRequestHistory(a, fixtureRequest(state, fixture_config)));
}
test "checkpoint native mismatches and unsupported native forms fail closed" {
    const a = std.testing.allocator;
    inline for (.{ p.Protocol.chat, p.Protocol.responses }) |proto| {
        const original = fixture(proto);
        var s = original;
        var blocks = [_]p.Block{ original.messages[2].blocks[0], .{ .text = "different" }, original.messages[2].blocks[2] };
        var messages = [_]p.Message{ original.messages[2], original.messages[3] };
        messages[0].blocks = &blocks;
        s.messages = &messages;
        try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
        blocks[1] = original.messages[2].blocks[1];
        blocks[0] = .{ .reasoning = "different" };
        try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
        blocks[0] = original.messages[2].blocks[0];
        blocks[2].tool_call.arguments = "{\"changed\":true}";
        try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
        blocks[2] = original.messages[2].blocks[2];
        messages[0].replay.?.retain_turn = false;
        try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
        messages[0].replay.?.retain_turn = true;
        messages[0].replay.?.json = if (proto == .chat) "[]" else "{}";
        if (validateRequestHistory(a, fixtureRequest(s, fixture_config))) |_| return error.ExpectedValidationFailure else |_| {}
    }
    var s = fixture(.responses);
    s.messages = &.{.{ .role = .assistant, .blocks = &.{.{ .reasoning = "native missing" }} }};
    try std.testing.expectError(error.NativeReplayRequired, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
}
