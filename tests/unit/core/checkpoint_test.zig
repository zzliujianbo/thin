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
test "checkpoint reads retired v2 budget fields without re-emitting them" {
    const a = std.testing.allocator;
    const bytes = try encode(a, fixture(.chat));
    defer a.free(bytes);
    const old = try std.mem.replaceOwned(u8, a, bytes, "\"version\":2,", "\"version\":2,\"max_input_tokens\":123,\"input_margin_tokens\":5000,");
    defer a.free(old);
    const parsed = try decode(a, old);
    defer parsed.deinit();
    const encoded = try encode(a, parsed.value);
    defer a.free(encoded);
    try std.testing.expectEqualStrings(bytes, encoded);
    const bad = try std.mem.replaceOwned(u8, a, old, "\"input_margin_tokens\":5000", "\"input_margin_tokens\":\"bad\"");
    defer a.free(bad);
    try std.testing.expectError(error.InvalidType, decode(a, bad));
}
test "checkpoint keeps display-only tool counters and reads old files without them" {
    const a = std.testing.allocator;
    var state = fixture(.chat);
    const stats = [_]ToolStat{.{ .call_id = "c1", .modified = 2, .added = 12, .removed = 3 }};
    state.tool_stats = &stats;
    const bytes = try encode(a, state);
    defer a.free(bytes);
    var decoded = try decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.value.tool_stats.?.len);
    try std.testing.expectEqualStrings("c1", decoded.value.tool_stats.?[0].call_id);
    try std.testing.expectEqual(@as(u64, 2), decoded.value.tool_stats.?[0].modified);
    try std.testing.expectEqual(@as(u64, 12), decoded.value.tool_stats.?[0].added);
    try std.testing.expectEqual(@as(u64, 3), decoded.value.tool_stats.?[0].removed);
    // The counters are display metadata, never request history.
    try validateRequestHistory(a, fixtureRequest(decoded.value, fixture_config));
    // Older checkpoints never carried the key; they must still resume.
    const base = try encode(a, fixture(.chat));
    defer a.free(base);
    const old = try std.mem.replaceOwned(u8, a, base, ",\"tool_stats\":null", "");
    defer a.free(old);
    try std.testing.expect(old.len < base.len);
    var legacy = try decode(a, old);
    defer legacy.deinit();
    try std.testing.expect(legacy.value.tool_stats == null);
    // A malformed counter row fails closed.
    const bad = try std.mem.replaceOwned(u8, a, bytes, "\"call_id\":\"c1\"", "\"call_id\":\"\"");
    defer a.free(bad);
    try std.testing.expectError(error.InvalidHistory, decode(a, bad));
}
test "checkpoint preserves more than 1024 canonical messages" {
    const a = std.testing.allocator;
    const messages = try a.alloc(p.Message, 1026);
    defer a.free(messages);
    for (messages, 0..) |*message, i| {
        message.* = .{ .role = if (i % 2 == 0) .user else .assistant, .blocks = &.{.{ .text = "finite message" }} };
    }
    var state = fixture(.chat);
    state.messages = messages;
    const bytes = try encode(a, state);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1026), parsed.value.messages.len);
    try std.testing.expectEqualDeep(state.messages, parsed.value.messages);
    try validateRequestHistory(a, fixtureRequest(parsed.value, fixture_config));
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
    try std.testing.expectError(error.InvalidType, decode(a, &deep));
    const old_max_bytes = 16 * 1024 * 1024;
    const huge = try a.alloc(u8, old_max_bytes + 1);
    defer a.free(huge);
    @memset(huge, 'x');
    if (decode(a, huge)) |parsed| {
        parsed.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    var state = fixture(.chat);
    state.version = 1;
    try std.testing.expectError(error.UnsupportedVersion, encode(a, state));
    state.version = 2;
    state.system = huge;
    const encoded = try encode(a, state);
    defer a.free(encoded);
    const loaded = try decode(a, encoded);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(huge, loaded.value.system);
    @memset(huge[0 .. old_max_bytes / 2], '\n');
    state.system = huge[0 .. old_max_bytes / 2];
    const escaped = try encode(a, state);
    defer a.free(escaped);
    try std.testing.expect(escaped.len > old_max_bytes);
}
test "checkpoint JSON preflight grows beyond retired depth and structural counts" {
    const a = std.testing.allocator;
    var nested: [161]u8 = undefined;
    @memset(nested[0..80], '[');
    nested[80] = '0';
    @memset(nested[81..], ']');
    const deep = try strictJson(a, &nested);
    defer deep.deinit();
    try std.testing.expect(deep.value == .array);
    var json: std.Io.Writer.Allocating = .init(a);
    defer json.deinit();
    try json.writer.writeByte('[');
    for (0..65537) |i| {
        if (i != 0) try json.writer.writeByte(',');
        try json.writer.writeAll("{}");
    }
    try json.writer.writeByte(']');
    const wide = try strictJson(a, json.written());
    defer wide.deinit();
    try std.testing.expectEqual(@as(usize, 65537), wide.value.array.items.len);
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
test "checkpoint roles closure global duplicate ids argument objects and growing histories" {
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
    const many_encoded = try encode(a, s);
    defer a.free(many_encoded);
    const many_loaded = try decode(a, many_encoded);
    defer many_loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1025), many_loaded.value.messages.len);
    const blocks = try a.alloc(p.Block, 1025);
    defer a.free(blocks);
    @memset(blocks, .{ .text = "" });
    s.messages = &.{.{ .role = .user, .blocks = blocks }};
    const blocks_encoded = try encode(a, s);
    defer a.free(blocks_encoded);
    const blocks_loaded = try decode(a, blocks_encoded);
    defer blocks_loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1025), blocks_loaded.value.messages[0].blocks.len);
    s.messages = &.{ .{ .role = .user, .blocks = blocks[0..600] }, .{ .role = .user, .blocks = blocks[600..] } };
    const split_encoded = try encode(a, s);
    defer a.free(split_encoded);
    const split_loaded = try decode(a, split_encoded);
    defer split_loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1025), split_loaded.value.messages[0].blocks.len + split_loaded.value.messages[1].blocks.len);
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

test "checkpoint native JSON iterative clone and encode preserve 20000 nesting levels" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit(); // Arena teardown never walks the nested Value tree.
    const a = scratch.allocator();
    const depth = 20000;
    const number = "184467440737095516160123456789";
    const inner = "{\"large\":" ++ number ++ ",\"text\\\"key\":\"中文\\n\\\"\\\\\",\"ordered\":[true,null,1]}";
    const golden = try a.alloc(u8, depth * 2 + inner.len);
    @memset(golden[0..depth], '[');
    @memcpy(golden[depth..][0..inner.len], inner);
    @memset(golden[depth + inner.len ..], ']');
    try std.testing.expect(depth > 64);

    // common.parse includes the dynamically allocated scanner preflight.
    const source = try common.parse(a, golden);
    const cloned = try common.clone(a, source);
    var leaf = cloned;
    for (0..depth) |_| {
        try std.testing.expect(leaf == .array);
        try std.testing.expectEqual(@as(usize, 1), leaf.array.items.len);
        leaf = leaf.array.items[0];
    }
    try std.testing.expect(leaf == .object);
    try std.testing.expectEqualStrings("large", leaf.object.keys()[0]);
    try std.testing.expectEqualStrings("text\"key", leaf.object.keys()[1]);
    const large = leaf.object.get("large").?;
    try std.testing.expect(large == .number_string);
    try std.testing.expectEqualStrings(number, large.number_string);
    try std.testing.expectEqualStrings("中文\n\"\\", leaf.object.get("text\"key").?.string);
    const encoded = try j.encode(a, cloned);
    try std.testing.expectEqualStrings(golden, encoded);
}

test "checkpoint native JSON iterative clone and encode clean up every small allocation failure" {
    const Harness = struct {
        // Only the small, fixed-depth success fixture reaches this recursive
        // test-only cleanup. Failed clones must clean up inside common.clone.
        fn release(a: Allocator, value: j.Value) void {
            switch (value) {
                .string, .number_string => |text| a.free(text),
                .array => |array_value| {
                    var items = array_value;
                    for (items.items) |child| release(a, child);
                    items.deinit();
                },
                .object => |object_value| {
                    var fields = object_value;
                    for (fields.keys(), fields.values()) |key, child| {
                        a.free(key);
                        release(a, child);
                    }
                    fields.deinit(a);
                },
                else => {},
            }
        }

        fn expectSame(source: j.Value, cloned: j.Value) !void {
            try std.testing.expectEqual(std.meta.activeTag(source), std.meta.activeTag(cloned));
            switch (source) {
                .array => |items| {
                    try std.testing.expectEqual(items.items.len, cloned.array.items.len);
                    for (items.items, cloned.array.items) |original, copy| try expectSame(original, copy);
                },
                .object => |fields| {
                    try std.testing.expectEqual(fields.count(), cloned.object.count());
                    for (fields.keys(), cloned.object.keys()) |original, copy| try std.testing.expectEqualStrings(original, copy);
                    for (fields.values(), cloned.object.values()) |original, copy| try expectSame(original, copy);
                },
                .string => |text| try std.testing.expectEqualStrings(text, cloned.string),
                .number_string => |text| try std.testing.expectEqualStrings(text, cloned.number_string),
                .null => {},
                inline else => |scalar, tag| try std.testing.expectEqual(scalar, @field(cloned, @tagName(tag))),
            }
        }

        fn run(a: Allocator, source: j.Value, expected: []const u8) !void {
            // Use the passed failing allocator directly, not an arena wrapper:
            // task/ledger growth, strings, maps and arrays must all be injectable.
            const cloned = try common.clone(a, source);
            defer release(a, cloned);
            try expectSame(source, cloned);
            const encoded = try j.encode(a, cloned);
            defer a.free(encoded);
            try std.testing.expectEqualStrings(expected, encoded);
        }
    };
    const golden = "{\"first\":[null,true,7,-7,{\"text\":\"中文\\n\\\"\\\\\",\"large\":184467440737095516160123456789}],\"last\":\"tail\",\"empty\":{}}";
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const source = try common.parse(source_arena.allocator(), golden);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{ source, golden });
}
