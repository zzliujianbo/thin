test "model API URLs identify SystemOne without SDK or name inference" {
    const a = std.testing.allocator;
    var result = try parseDirectory(a,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"shared":{"api":{"url":"https://opencode.ai/inference/systemone/v1"},"limit":{"context":100000,"output":32000},"cost":{"input":1,"output":2},"reasoning_options":[{"type":"effort","values":["high"]}]},"no-window":{"api":{"url":"https://opencode.ai/inference/systemone/v1/"}},"jev-name-only":{},"bad-url":{"api":{"url":"https://opencode.ai.example/inference/systemone/v1"}},"bad-shape":{"api":"https://opencode.ai/inference/systemone/v1"},"bad-value":{"api":{"url":false}},"no-url":{"api":{}},"unrecognized":{"api":{"url":"https://opencode.ai/inference/systemone/v1","unknown":true}}}},"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"shared":{}}}}
    );
    defer result.deinit(a);
    for ([_][]const u8{ "shared", "no-window" }) |name| {
        const row = result.rows[result.find(.opencode_zen, name).?];
        try std.testing.expectEqual(protocol.Protocol.systemone, row.dev_protocol);
        try std.testing.expect(row.dev_reasoning == null);
        try std.testing.expect(row.dev_output_tokens == null);
        try std.testing.expect(row.dev_context_tokens == null);
        try std.testing.expect(row.dev_input_price_threshold == null);
        try std.testing.expect(row.dev_input_price_flat_limit == null);
    }
    try std.testing.expectEqual(protocol.Protocol.chat, result.rows[result.find(.opencode_go, "shared").?].dev_protocol);
    try std.testing.expectEqual(protocol.Protocol.chat, result.rows[result.find(.opencode_zen, "jev-name-only").?].dev_protocol);
    for ([_][]const u8{ "bad-shape", "bad-value", "unrecognized" }) |name| {
        try std.testing.expectEqual(protocol.Protocol.auto, result.rows[result.find(.opencode_zen, name).?].dev_protocol);
    }
    // Neither an empty descriptor nor an untrusted URL may override a known
    // SDK with SystemOne or redirect credentials to the metadata URL.
    for ([_][]const u8{ "bad-url", "no-url" }) |name| {
        try std.testing.expectEqual(protocol.Protocol.chat, result.rows[result.find(.opencode_zen, name).?].dev_protocol);
    }
    try std.testing.expectError(error.InvalidModelsDev, parseDirectory(a,
        \\{"opencode":{"models":{"x":{"api":{"url":"https://opencode.ai/inference/systemone/v1","url":"https://opencode.ai/inference/systemone/v1"}}}}}
    ));
    try std.testing.expectError(error.InvalidModelsDev, parseDirectory(a,
        \\{"opencode":{"models":{"x":{"api":{},"api":{}}}}}
    ));
}
test "API SDK and ID annotations preserve native and ordinary protocol sources" {
    var result = try parseDirectory(std.testing.allocator,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"native":{"api":{"id":"native","npm":"@ai-sdk/openai-compatible","url":"https://opencode.ai/inference/systemone/v1"}},"ordinary":{"api":{"id":"ordinary","npm":"@ai-sdk/anthropic","url":"https://vendor.invalid/v1"},"limit":{"context":32768}},"inherited":{"api":{"id":"inherited","url":"https://vendor.invalid/v1"},"limit":{"context":32768}},"unknown":{"api":{"npm":"@ai-sdk/unknown"}},"malformed":{"api":{"url":"not-an-absolute-url"}}}}}
    );
    defer result.deinit(std.testing.allocator);
    const native = result.rows[result.find(.opencode_zen, "native").?];
    try std.testing.expectEqual(protocol.Protocol.systemone, native.dev_protocol);
    try std.testing.expect(native.dev_context_tokens == null);
    try std.testing.expectEqual(protocol.Protocol.anthropic, result.rows[result.find(.opencode_zen, "ordinary").?].dev_protocol);
    const inherited = result.rows[result.find(.opencode_zen, "inherited").?];
    try std.testing.expectEqual(protocol.Protocol.chat, inherited.dev_protocol);
    try std.testing.expectEqual(@as(?u32, 32768), inherited.dev_context_tokens);
    for ([_][]const u8{ "unknown", "malformed" }) |name| {
        try std.testing.expectEqual(protocol.Protocol.auto, result.rows[result.find(.opencode_zen, name).?].dev_protocol);
    }
}
test "models.dev parser keeps catalog IDs, derives SDK protocols, and isolates bad option values" {
    const t = std.testing;
    const body =
        \\{"opencode-go":{"id":"opencode-go","npm":"@ai-sdk/openai-compatible","models":{"gpt-6-luna":{"id":"gpt-6-luna","reasoning_options":[{"type":"effort","values":["none","low","medium","high","xhigh","max"]}],"provider":{"npm":"@ai-sdk/openai"}},"claude-haiku-5-5":{"id":"claude-haiku-5-5","reasoning_options":[],"provider":{"npm":"@ai-sdk/anthropic"}},"unlisted":{"id":"unlisted","reasoning_options":[{"type":"effort","values":["low"]}]}}},"anthropic":{"id":"anthropic","npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"id":"claude-haiku-5-5","reasoning_options":[{"type":"toggle"},{"type":"effort","values":["low","medium","high","xhigh","max","extreme"]}]}}}}
    ;
    var parsed = try parseDirectory(t.allocator, body);
    defer parsed.deinit(t.allocator);
    const luna = parsed.rows[parsed.find(.opencode_go, "gpt-6-luna").?].dev_reasoning.?.declaration();
    try t.expectEqual(thinking.Format.standard, luna.format);
    try t.expectEqualStrings("none", luna.map.off.?);
    const haiku = parsed.rows[parsed.find(.opencode_go, "claude-haiku-5-5").?];
    // The exact Go row has no usable option; the anthropic-provider row is not
    // used because "extreme" makes that whole option set unusable.
    try t.expect(haiku.dev_reasoning == null);
    try t.expectEqual(protocol.Protocol.responses, protocolFor("@ai-sdk/openai"));
    try t.expectEqual(protocol.Protocol.chat, protocolFor("@ai-sdk/openai-compatible"));
    try t.expectEqual(protocol.Protocol.anthropic, protocolFor("@ai-sdk/anthropic"));
    try t.expectEqual(protocol.Protocol.auto, protocolFor("@ai-sdk/google"));
}
test "models.dev foreign rows never create presets or fill conflicting exact routes" {
    const a = std.testing.allocator;
    var absent = try parseDirectory(a,
        \\{"foreign":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"limit":{"context":1000000,"output":8192},"cost":{"input":1,"output":2},"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high"]}]}}}}
    );
    defer absent.deinit(a);
    try std.testing.expect(absent.find(.opencode_go, "claude-haiku-5-5") == null);
    var conflict = try parseDirectory(a,
        \\{"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"claude-haiku-5-5":{}}},"foreign":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high"]}]}}}}
    );
    defer conflict.deinit(a);
    const exact = conflict.rows[conflict.find(.opencode_go, "claude-haiku-5-5").?];
    try std.testing.expectEqual(protocol.Protocol.chat, exact.dev_protocol);
    try std.testing.expect(exact.dev_reasoning == null);
}
test "models.dev malformed toggle values do not authorize exact profiles" {
    const a = std.testing.allocator;

    for ([_][]const u8{ "42", "null", "[]", "[false]", "[\"high\",false]", "[\"high\",\"high\"]" }) |bad_values| {
        const bad = try std.mem.concat(a, u8, &.{
            \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"claude-haiku-5-5":{"reasoning_options":[{"type":"toggle","values":
            ,
            bad_values,
            \\},{"type":"effort","values":["high"]}]}}}}
            ,
        });
        defer a.free(bad);
        var bad_directory = try parseDirectory(a, bad);
        defer bad_directory.deinit(a);
        try std.testing.expect(bad_directory.rows[bad_directory.find(.opencode_go, "claude-haiku-5-5").?].dev_reasoning == null);
    }
}
test "supported providers retain independent exact profiles for the full raw ID" {
    var result = try parseDirectory(std.testing.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"nested/raw":{"reasoning_options":[{"type":"effort","values":["low"]}]},"empty":{}}},"opencode":{"npm":"@ai-sdk/anthropic","models":{"nested/raw":{"reasoning_options":[{"type":"effort","values":["high"]}]},"empty":{"reasoning_options":[{"type":"effort","values":["high"]}]}}}}
    );
    defer result.deinit(std.testing.allocator);
    const go = result.rows[result.find(.opencode_go, "nested/raw").?].dev_reasoning.?.declaration();
    const zen = result.rows[result.find(.opencode_zen, "nested/raw").?].dev_reasoning.?.declaration();
    try std.testing.expectEqualStrings("low", go.map.low.?);
    try std.testing.expect(go.map.high == null);
    try std.testing.expectEqualStrings("high", zen.map.high.?);
    try std.testing.expect(result.rows[result.find(.opencode_go, "empty").?].dev_reasoning == null);
    try std.testing.expect(result.find(.opencode_go, "raw") == null);
}
test "unknown option kinds do not poison an exact effort profile" {
    var result = try parseDirectory(std.testing.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"x":{"reasoning_options":[{"values":{"arbitrary":[false,{},42]},"type":"budget_tokens"},{"type":"future","values":["alien",false]},{"type":"toggle"},{"type":"effort","values":["low","high"]}]},"bad":{"reasoning_options":[{"type":"effort","values":["high","future"]}]},"dupe":{"reasoning_options":[{"type":"effort","values":["high"]},{"type":"effort","values":["low"]}]}}}}
    );
    defer result.deinit(std.testing.allocator);
    const declaration = result.rows[result.find(.opencode_go, "x").?].dev_reasoning.?.declaration();
    try std.testing.expectEqualStrings("disabled", declaration.map.off.?);
    try std.testing.expectEqualStrings("high", declaration.map.high.?);
    for ([_][]const u8{ "bad", "dupe" }) |name| try std.testing.expect(result.rows[result.find(.opencode_go, name).?].dev_reasoning == null);
    try std.testing.expectError(error.InvalidModelsDev, parseDirectory(std.testing.allocator,
        \\{"opencode-go":{"models":{"x":{"reasoning_options":[{"values":["high"],"values":["low"],"type":"effort"}]}}}}
    ));
}
test "models.dev directory retains new IDs and protocols independently of options" {
    const t = std.testing;
    const body =
        \\{"opencode-go":{"models":{"new/plain":{},"new-response":{"provider":{"npm":"@ai-sdk/openai"}},"new-anthropic":{"provider":{"npm":"@ai-sdk/anthropic"},"reasoning":true},"bad-options":{"reasoning_options":[false]},"empty-options":{"reasoning_options":[]},"empty-provider":{"provider":{}},"invalid-provider":{"provider":false},"invalid-npm":{"provider":{"npm":42}},"null-npm":{"provider":{"npm":null}},"empty-npm":{"provider":{"npm":""}},"unknown-npm":{"provider":{"npm":"future-sdk"}}},"npm":"@ai-sdk/openai-compatible"},"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"new/plain":{}}},"opencode":{"npm":"@ai-sdk/anthropic","models":{"new/plain":{}}},"other":{"npm":"@ai-sdk/openai","models":{"third-party":{}}}}
    ;
    var parsed = try parseDirectory(t.allocator, body);
    defer parsed.deinit(t.allocator);
    try t.expectEqual(@as(usize, 13), parsed.count);
    for ([_][]const u8{ "new/plain", "bad-options", "empty-options", "empty-provider" }) |name| {
        const row = parsed.rows[parsed.find(.opencode_go, name).?];
        try t.expectEqual(protocol.Protocol.chat, row.dev_protocol);
        try t.expect(row.dev_present and row.dev_reasoning == null);
        try t.expectEqual(protocol.Protocol.auto, row.protocol);
        try t.expect(row.available == null and row.tokens == null and row.reasoning == null);
    }
    try t.expectEqual(protocol.Protocol.responses, parsed.rows[parsed.find(.opencode_go, "new-response").?].dev_protocol);
    const anthropic = parsed.rows[parsed.find(.opencode_go, "new-anthropic").?];
    try t.expectEqual(protocol.Protocol.anthropic, anthropic.dev_protocol);
    try t.expect(anthropic.dev_reasoning == null);
    for ([_][]const u8{ "invalid-provider", "invalid-npm", "null-npm", "empty-npm", "unknown-npm" }) |name| {
        const row = parsed.rows[parsed.find(.opencode_go, name).?];
        try t.expect(row.dev_present and row.dev_protocol == .auto and row.dev_reasoning == null);
    }
    try t.expectEqual(protocol.Protocol.chat, parsed.rows[parsed.find(.deepseek, "new/plain").?].dev_protocol);
    try t.expectEqual(protocol.Protocol.anthropic, parsed.rows[parsed.find(.opencode_zen, "new/plain").?].dev_protocol);
    try t.expectEqualStrings("opencode-zen/new/plain", parsed.selector(parsed.find(.opencode_zen, "new/plain").?));
    try t.expect(parsed.find(.opencode_go, "new") == null);
    try t.expect(parsed.find(.opencode_go, "NEW/plain") == null);
    try t.expect(parsed.find(.opencode_go, "third-party") == null);
}
test "models.dev exact profiles cannot be filled or overridden by foreign rows" {
    const t = std.testing;
    const body =
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"fresh":{},"exact":{"reasoning_options":[{"type":"effort","values":["low"]}]},"blocked":{"provider":{"npm":null}},"tie":{},"wrong-protocol":{}}},"one":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["low","high","max"]}]},"exact":{"reasoning_options":[{"type":"effort","values":["high"]}]},"blocked":{"reasoning_options":[{"type":"effort","values":["high"]}]},"tie":{"reasoning_options":[{"type":"effort","values":["low"]}]}}},"two":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"effort","values":["max","high","low"]},{"type":"toggle"}]},"exact":{"reasoning_options":[{"type":"effort","values":["high"]}]},"tie":{"reasoning_options":[{"type":"effort","values":["high"]}]}}},"minority":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"effort","values":["medium","high"]}]}}},"wrong":{"npm":"@ai-sdk/openai","models":{"wrong-protocol":{"reasoning_options":[{"type":"effort","values":["medium"]}]}}},"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"format-check":{}}},"standard":{"npm":"@ai-sdk/openai-compatible","models":{"format-check":{"reasoning_options":[{"type":"effort","values":["none","high"]}]}}}}
    ;
    var parsed = try parseDirectory(t.allocator, body);
    defer parsed.deinit(t.allocator);
    try t.expect(parsed.rows[parsed.find(.opencode_go, "fresh").?].dev_reasoning == null);
    const exact = parsed.rows[parsed.find(.opencode_go, "exact").?].dev_reasoning.?.declaration();
    try t.expectEqualStrings("low", exact.map.low.?);
    try t.expect(exact.map.high == null);
    for ([_][]const u8{ "blocked", "tie", "wrong-protocol" }) |name| {
        try t.expect(parsed.rows[parsed.find(.opencode_go, name).?].dev_reasoning == null);
    }
    try t.expect(parsed.rows[parsed.find(.deepseek, "format-check").?].dev_reasoning == null);
    var fixture = try parseDirectory(t.allocator, @embedFile("models_dev_fixture.json"));
    defer fixture.deinit(t.allocator);
    const haiku = fixture.rows[fixture.find(.opencode_go, "claude-haiku-5-5").?];
    try t.expectEqual(protocol.Protocol.anthropic, haiku.dev_protocol);
    const own = haiku.dev_reasoning.?.declaration();
    try t.expectEqualStrings("disabled", own.map.off.?);
    try t.expectEqualStrings("max", own.map.max.?);
    try t.expect(own.map.medium == null);
}
test "models.dev new model keys and recognized schema duplicates are rejected" {
    const t = std.testing;
    for ([_][]const u8{
        \\{"opencode-go":{"models":{"fresh":{},"fresh":{}}}}
        ,
        \\{"opencode-go":{},"opencode-go":{}}
        ,
        \\{"opencode-go":{"npm":"a","npm":"b"}}
        ,
        \\{"opencode-go":{"models":{},"models":{}}}
        ,
        \\{"opencode-go":{"models":{"fresh":{"provider":{},"provider":{}}}}}
        ,
        \\{"opencode-go":{"models":{"fresh":{"provider":{"npm":"a","npm":"b"}}}}}
        ,
        \\{"opencode-go":{"models":{"fresh":{"reasoning_options":[],"reasoning_options":[]}}}}
        ,
    }) |body| {
        try t.expectError(error.InvalidModelsDev, parseDirectory(t.allocator, body));
    }
    for ([_][]const u8{
        \\{"opencode-go":{"models":{"":{}}}}
        ,
        \\{"opencode-go":{"models":{"   ":{}}}}
        ,
        \\{"opencode-go":{"models":{"bad\n":{}}}}
        ,
    }) |body| try t.expectError(error.InvalidMetadata, parseDirectory(t.allocator, body));
}
test "unrelated provider IDs do not inherit the supported directory key limit" {
    const t = std.testing;
    const long_id: [257]u8 = @splat('x');
    for ([_][]const u8{ &long_id, "", "bad\nname" }) |foreign_id| {
        var bytes: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try writer.writeAll("{\"opencode\":{\"npm\":\"@ai-sdk/openai\",\"models\":{\"gpt-5.2\":{\"reasoning_options\":[{\"type\":\"effort\",\"values\":[\"high\"]}]}}},\"other\":{\"models\":{");
        try std.json.Stringify.value(foreign_id, .{}, &writer);
        try writer.writeAll(":{}}}}");
        const body = bytes[0..writer.end];
        var result = try parseDirectory(t.allocator, body);
        defer result.deinit(t.allocator);
        try t.expectEqual(@as(usize, 1), result.count);
        const row = result.rows[result.find(.opencode_zen, "gpt-5.2").?];
        try t.expectEqual(protocol.Protocol.responses, row.dev_protocol);
        try t.expectEqualStrings("high", row.dev_reasoning.?.declaration().map.high.?);
    }
}
test "models.dev directory grows beyond former model capacity" {
    const a = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, "{\"opencode-go\":{\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{");
    for (0..1537) |i| {
        if (i != 0) try body.append(a, ',');
        var buf: [64]u8 = undefined;
        try body.appendSlice(a, try std.fmt.bufPrint(&buf, "\"fresh-{d}\":{{}}", .{i}));
    }
    try body.appendSlice(a, "}}}");
    var parsed = try parseDirectory(a, body.items);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(usize, 1537), parsed.count);
}
test "models.dev scan grows beyond former supported-provider record limit" {
    const a = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, "{\"opencode-go\":{\"models\":{");
    for (0..65537) |i| {
        if (i != 0) try body.append(a, ',');
        var buf: [64]u8 = undefined;
        try body.appendSlice(a, try std.fmt.bufPrint(&buf, "\"fresh-{d}\":{{}}", .{i}));
    }
    try body.appendSlice(a, "}}}");
    var parsed = try parseDirectory(a, body.items);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(usize, 65537), parsed.count);
}
test "models.dev absent and unknown provider adapters never borrow a protocol" {
    const body =
        \\{"opencode-go":{"models":{"fresh":{}}},"opencode":{"npm":"unknown-sdk","models":{"fresh":{}}},"other":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    ;
    var parsed = try parseDirectory(std.testing.allocator, body);
    defer parsed.deinit(std.testing.allocator);
    for ([_]providers.Id{ .opencode_go, .opencode_zen }) |id| {
        const row = parsed.rows[parsed.find(id, "fresh").?];
        try std.testing.expect(row.dev_present and row.dev_protocol == .auto and row.dev_reasoning == null);
    }
}
test "models.dev directory allocation failures release parser scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, directoryAllocationCheck, .{});
}
test "models.dev complete flat price schedules differ from missing or malformed pricing" {
    const a = std.testing.allocator;
    const Case = struct { cost: []const u8, flat: ?u32 = null, step: ?u32 = null };
    for ([_]Case{
        .{ .cost = "{\"input\":1,\"output\":2}", .flat = 1000000 },
        .{ .cost = "{\"input\":0,\"output\":0,\"tiers\":[]}", .flat = 1000000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"cache_read\":0.1,\"cache_write\":0.2,\"reasoning\":2,\"input_audio\":3,\"output_audio\":4}", .flat = 1000000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"context_over_200k\":{\"input\":2,\"output\":3}}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"future_price_schedule\":{}}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"cache_read\":{\"input\":3}}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"cache_read\":0.1,\"cache_read\":0.2}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1,\"output\":2,\"cache_read\":0.5,\"tier\":{\"type\":\"context\",\"size\":100000}}]}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"context_over_200k\":{},\"tiers\":[{\"input\":2,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .step = 100000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":1,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .flat = 1000000 },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":2,\"output\":2,\"tier\":{\"type\":\"context\",\"size\":100000}}]}", .step = 100000 },
        .{ .cost = "null" },
        .{ .cost = "{}" },
        .{ .cost = "{\"input\":1}" },
        .{ .cost = "{\"input\":-1,\"output\":2}" },
        .{ .cost = "{\"input\":1e100001,\"output\":2}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":null}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":2}]}" },
        .{ .cost = "{\"input\":1,\"output\":2,\"tiers\":[{\"input\":2,\"output\":3,\"tier\":{\"type\":\"future\",\"size\":100000}}]}" },
    }) |case| {
        const body = try std.mem.concat(a, u8, &.{ "{\"opencode-go\":{\"npm\":\"@ai-sdk/anthropic\",\"models\":{\"flat\":{\"limit\":{\"context\":1000000},\"cost\":", case.cost, "}}}}" });
        defer a.free(body);
        var result = try parseDirectory(a, body);
        defer result.deinit(a);
        try std.testing.expectEqual(case.step, result.rows[0].dev_input_price_threshold);
        try std.testing.expectEqual(case.flat, result.rows[0].dev_input_price_flat_limit);
    }
    var incomplete = try parseDirectory(a,
        \\{"opencode-go":{"models":{"flat":{"limit":{"context":1000000},"cost":{"input":1,"output":2}}}},"opencode":{"npm":"@ai-sdk/openai","models":{"flat":{"cost":{"input":1,"output":2}}}}}
    );
    defer incomplete.deinit(a);
    for (incomplete.rows[0..incomplete.count]) |row| {
        try std.testing.expect(row.dev_input_price_threshold == null);
        try std.testing.expect(row.dev_input_price_flat_limit == null);
    }
}
test "models.dev malformed options and explicit invalid adapters are model-local unknowns" {
    const body =
        \\{"opencode-go":{"npm":"@ai-sdk/openai","models":{"gpt-6-luna":{"provider":{"npm":42},"reasoning_options":[{"type":"effort","values":["low"]}]},"claude-haiku-5-5":{"provider":{"npm":"@ai-sdk/anthropic"},"reasoning_options":[false,null,12]},"mimo-v2.5":{"reasoning":true}}}}
    ;
    var parsed = try parseDirectory(std.testing.allocator, body);
    defer parsed.deinit(std.testing.allocator);
    for ([_][]const u8{ "gpt-6-luna", "claude-haiku-5-5", "mimo-v2.5" }) |name| {
        try std.testing.expect(parsed.rows[parsed.find(.opencode_go, name).?].dev_reasoning == null);
    }
}
