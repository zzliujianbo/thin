test "image defaults sparse disk exact selection owned clone and roundtrip" {
    try imageAllocationCase(std.testing.allocator);
}
test "image retired enabled is rejected regardless of value" {
    inline for (.{ "true", "false", "null", "0", "\"false\"" }) |value| {
        if (parse(std.testing.allocator, image_test_prefix ++
            ",\"image\":{\"model\":\"p/deepseek-flash\",\"enabled\":" ++ value ++ "}}")) |parsed_value|
        {
            var parsed = parsed_value;
            release(&parsed);
            return error.ExpectedEnabledRejection;
        } else |err| try std.testing.expectEqual(error.UnknownField, err);
    }
}
test "image rejects invalid owner model types duplicates and unknown fields" {
    try rejectedImageAllocationCase(std.testing.allocator);
}
test "explicit decision protocol round trips with shared timeout" {
    try decisionAllocationCase(std.testing.allocator);
    var parsed = try parse(std.testing.allocator, decision_fixture);
    defer release(&parsed);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeDisk(parsed.value, &out.writer);
    var tree = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer tree.deinit();
    const decision = tree.value.object.get("decision").?.object;
    try std.testing.expect(decision.get("backend") == null);
    try std.testing.expect(decision.get("request_timeout_ms") == null);
    try std.testing.expectEqual(@as(usize, 4), decision.count());
    var again = try parse(std.testing.allocator, out.written());
    defer release(&again);
    try std.testing.expectEqual(protocol.Protocol.systemone, again.value.registry.?.find("p").?.patchFor("org/reviewer").?.protocol.?);
}
test "decision declarations and owned pending clones are allocation failure safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decisionAllocationCase, .{});
}
test "decision rejects removed fields even when disabled without protocol migration" {
    try rejectedDecisionAllocationCase(std.testing.allocator);
    const a = std.testing.allocator;
    const cases = .{
        .{ "{\"model\":\"p/m\",\"unknown\":1}", error.UnknownField },
        .{ "{\"model\":\"p/m\",\"model\":\"p/m\"}", error.DuplicateField },
        .{ "{\"model\":\"p/m\",\"backend\":\"model\",\"backend\":\"systemone\"}", error.DuplicateField },
        .{ "{\"model\":\"p/m\",\"request_timeout_ms\":1,\"request_timeout_ms\":2}", error.DuplicateField },
        .{ "{\"model\":\"p/m\",\"max_state_bytes\":1.5}", error.InvalidNumber },
    };
    inline for (cases) |case| {
        const raw = try std.mem.concat(a, u8, &.{ decision_test_prefix, case[0], "}" });
        defer a.free(raw);
        try std.testing.expectError(case[1], parse(a, raw));
    }
    var parsed = try parse(a, decision_test_prefix ++ "{\"model\":\"p/m\"}}");
    defer release(&parsed);
    try std.testing.expectEqual(protocol.Protocol.chat, parsed.value.registry.?.find("p").?.patchFor("m").?.protocol.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.registry.?.find("p").?.models.len);
}
test "SystemOne has no required generative window but retains field and budget safety" {
    var model: Model = .{ .name = "reviewer", .protocol = .systemone, .context_tokens = 0 };
    try validateModel(model, .{});
    model.reasoning_effort = "off";
    try std.testing.expectError(error.IncompatibleReasoningProtocol, validateModel(model, .{}));
    model.reasoning_effort = null;
    model.reasoning = .{ .map = .{ .high = "high" } };
    try std.testing.expectError(error.IncompatibleReasoningProtocol, validateModel(model, .{}));
    model.reasoning = null;
    model.output_tokens = 0;
    try std.testing.expectError(error.InvalidBudget, validateModel(model, .{}));
    model.output_tokens = null;
    model.context_tokens = 16 * 1024 * 1024 + 1;
    try std.testing.expectError(error.InvalidBudget, validateModel(model, .{}));
    model.context_tokens = 0;
    model.protocol = .chat;
    try std.testing.expectError(error.InvalidBudget, validateModel(model, .{}));
}
test "runtime-only config clones retain derived maps but cannot write disk" {
    var active = testConfig();
    active.model.reasoning = .{ .map = .{ .high = "high" } };
    active.model.reasoning_effort = "high";
    active.model.reasoning_source = .metadata;
    active.model.input_price_threshold = 100000;
    var copied = try clone(std.testing.allocator, active);
    defer release(&copied);
    try std.testing.expectEqualStrings("high", copied.value.model.reasoning.?.map.high.?);
    try std.testing.expectEqualStrings("high", copied.value.model.reasoning_effort.?);
    try std.testing.expectEqual(@as(?u32, 100000), copied.value.model.input_price_threshold);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.MissingRegistry, writeDisk(copied.value, &out.writer));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}
test "memory auto strict defaults sparse disk and roundtrip" {
    const a = std.testing.allocator;
    inline for (.{ "", ",\"memory\":{}", ",\"memory\":{\"auto\":true}", ",\"memory\":{\"auto\":false}" }, 0..) |suffix, index| {
        var parsed = try parse(a, image_test_prefix ++ suffix ++ "}");
        defer release(&parsed);
        try std.testing.expectEqual(index != 3, parsed.value.memory.auto);
        var copied = try clone(a, parsed.value);
        defer release(&copied);
        try std.testing.expectEqualDeep(parsed.value.memory, copied.value.memory);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try writeDisk(copied.value, &out.writer);
        var tree = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
        defer tree.deinit();
        try std.testing.expectEqual(index == 3, tree.value.object.contains("memory"));
        if (tree.value.object.get("memory")) |memory| {
            try std.testing.expectEqual(@as(usize, 1), memory.object.count());
            try std.testing.expect(!memory.object.get("auto").?.bool);
        }
        var again = try parse(a, out.written());
        defer release(&again);
        try std.testing.expectEqualDeep(parsed.value.memory, again.value.memory);
    }
    inline for (.{ "null", "true", "0", "\"auto\"", "[]", "{\"auto\":null}", "{\"auto\":0}", "{\"auto\":\"true\"}", "{\"auto\":[]}", "{\"auto\":{}}" }) |bad| {
        try std.testing.expectError(error.UnexpectedToken, parse(a, image_test_prefix ++ ",\"memory\":" ++ bad ++ "}"));
    }
    inline for (.{ "enabled", "reviewer", "model", "Auto" }) |field| {
        try std.testing.expectError(error.UnknownField, parse(a, image_test_prefix ++ ",\"memory\":{\"" ++ field ++ "\":true}}"));
    }
    try std.testing.expectError(error.DuplicateField, parse(a, image_test_prefix ++ ",\"memory\":{\"auto\":true,\"auto\":false}}"));
    try std.testing.expectError(error.DuplicateField, parse(a, image_test_prefix ++ ",\"memory\":{},\"memory\":{}}"));
}
test "memory config allocation failures release parse clone and disk candidates" {
    try checkConfigAllocationFailures(memoryAllocationCase);
}
test "current config round trips and rejects removed subagent field" {
    const a = std.testing.allocator;
    var parsed = try parse(a, image_test_prefix ++ "}");
    defer release(&parsed);
    try std.testing.expectEqualStrings("p/main", parsed.value.registry.?.default);
    var copied = try clone(a, parsed.value);
    defer release(&copied);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeDisk(copied.value, &out.writer);
    var again = try parse(a, out.written());
    defer release(&again);
    try std.testing.expectEqualDeep(parsed.value.limits, again.value.limits);
    try std.testing.expectEqualDeep(parsed.value.memory, again.value.memory);
    inline for (.{ "{}", "{\"enabled\":false}", "{\"enabled\":true}", "null" }) |value| {
        try std.testing.expectError(error.UnknownField, parse(a, image_test_prefix ++ ",\"subagent\":" ++ value ++ "}"));
    }
    try std.testing.expectError(error.DuplicateField, parse(a, image_test_prefix ++ ",\"subagent\":{},\"subagent\":{}}"));
}
test "current config allocation failures release parse clone and disk candidates" {
    try checkConfigAllocationFailures(currentConfigAllocationCase);
}
test "low price input defaults enabled and explicit optout survives disk roundtrip" {
    const a = std.testing.allocator;
    const prefixes = [_][]const u8{
        "{\"llm\":{\"default\":\"local/m\",\"providers\":{\"local\":{\"base_url\":\"https://fixture.invalid/v1\",\"models\":{\"m\":{\"protocol\":\"chat\",\"context_tokens\":32768}}}}},\"limits\":",
    };
    for (prefixes) |prefix| for ([_][]const u8{ "{}", "{\"low_price_input\":true}", "{\"low_price_input\":false}" }) |limits| {
        const raw = try std.mem.concat(a, u8, &.{ prefix, limits, "}" });
        defer a.free(raw);
        var parsed = try parse(a, raw);
        defer release(&parsed);
        const enabled = std.mem.find(u8, limits, "false") == null;
        try std.testing.expectEqual(enabled, parsed.value.limits.low_price_input);
        // Unknown price metadata does not prevent parsing or selection.
        try std.testing.expect(parsed.value.model.input_price_threshold == null);
        var cloned = try clone(a, parsed.value);
        defer release(&cloned);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try writeDisk(cloned.value, &out.writer);
        var again = try parse(a, out.written());
        defer release(&again);
        try std.testing.expectEqual(enabled, again.value.limits.low_price_input);
    };
}
test "thinking declarations strict owned config validation and protocol incompatibility" {
    const t = std.testing;
    var parsed = try parse(t.allocator,
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"https://proxy/v1","models":{"custom":{"context_tokens":32768,"reasoning":{"map":{"off":"disabled","high":"own-wire"}}}}}}}}
    );
    defer release(&parsed);
    try t.expectEqualStrings("own-wire", parsed.value.registry.?.find("p").?.patchFor("custom").?.reasoning.?.map.high.?);
    try t.expectError(error.MissingField, parse(t.allocator,
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"https://proxy/v1","models":{"custom":{"reasoning":{}}}}}}}
    ));
    try t.expectError(error.InvalidReasoningMap, parse(t.allocator,
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"https://proxy/v1","models":{"custom":{"reasoning":{"map":{}}}}}}}}
    ));
    try t.expectError(error.UnknownField, parse(t.allocator,
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"https://proxy/v1","models":{"custom":{"reasoning":{"map":{"ultra":"x"}}}}}}}}
    ));
    var config = parsed.value;
    config.model.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } };
    config.model.protocol = .responses;
    try t.expectError(error.IncompatibleReasoningProtocol, validate(config));
    config.model.protocol = .auto;
    try validate(config);
    config.provider.base_url = "https://api.deepseek.com";
    config.model = .{ .name = "deepseek-flash", .context_tokens = 32768, .protocol = .responses };
    try t.expectError(error.IncompatibleReasoningProtocol, validate(config));
}
test "Anthropic config is explicit and rejects foreign thinking controls" {
    var parsed = try parse(std.testing.allocator,
        \\{"llm":{"default":"p/claude-haiku-5-5","providers":{"p":{"base_url":"https://opencode.ai/inference/go/v1","models":{"claude-haiku-5-5":{"context_tokens":32768,"protocol":"anthropic"}}}}}}
    );
    defer release(&parsed);
    const patch = parsed.value.registry.?.find("p").?.patchFor("claude-haiku-5-5").?;
    try std.testing.expect(patch.protocol.? == .anthropic);
    try validate(parsed.value);
    var config = parsed.value;
    config.model = patch.apply(config.model);
    config.model.reasoning_effort = "high";
    try std.testing.expectError(error.UnsupportedAnthropicReasoning, validate(config));
    config.model.reasoning = .{ .format = .anthropic, .map = .{ .off = "disabled", .low = "low", .high = "high" } };
    try validate(config);
    config.model.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } };
    try std.testing.expectError(error.IncompatibleReasoningProtocol, validate(config));
}
test "Codex credentials roundtrip owned clone and allocation failures" {
    try codexConfigAllocationCase(std.testing.allocator);
    const Stable = struct {
        fn run(a: std.mem.Allocator) !void {
            var wiping = WipingAllocator{ .backing = a };
            try codexConfigAllocationCase(wiping.allocator());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Stable.run, .{});
}
test "Codex identity and credential sources are strict" {
    const a = std.testing.allocator;
    var p: Provider = .{ .base_url = providers.Id.openai_codex.baseUrl(), .kind = .openai_codex };
    try validateKeySource(p); // An unconfigured connection can start login.
    p.codex_oauth = .{ .access_token = "access", .refresh_token = "refresh", .expires_at_ms = 1 };
    try validateKeySource(p);
    p.api_key = "key";
    try std.testing.expectError(error.AmbiguousApiKey, validateKeySource(p));
    p.api_key = null;
    p.api_key_env = "KEY";
    try std.testing.expectError(error.AmbiguousApiKey, validateKeySource(p));
    p.api_key_env = "";
    p.base_url = "https://chatgpt.com/backend-api/codex/";
    try std.testing.expectError(error.InvalidCodexProvider, validateKeySource(p));
    p.base_url = providers.Id.openai_codex.baseUrl();
    p.kind = null;
    try std.testing.expectError(error.InvalidCodexProvider, validateKeySource(p));
    p.kind = .openai_codex;
    p.codex_oauth.?.expires_at_ms = 0;
    try std.testing.expectError(error.InvalidCodexCredential, validateKeySource(p));
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var parsed = try parse(a, codex_fixture);
    defer release(&parsed);
    try std.testing.expectError(error.ApiKeyNotFound, resolveApiKey(a, parsed.value, &env));
}
test "Codex pending refresh survives disk and clone" {
    const a = std.testing.allocator;
    const raw = try std.mem.replaceOwned(u8, a, codex_fixture, "\"expires_at_ms\":123456789", "\"expires_at_ms\":123456789,\"refresh_pending\":true");
    defer a.free(raw);
    var parsed = try parse(a, raw);
    defer release(&parsed);
    try std.testing.expect(parsed.value.provider.codex_oauth.?.refresh_pending);
    var copied = try clone(a, parsed.value);
    defer release(&copied);
    try std.testing.expect(copied.value.provider.codex_oauth.?.refresh_pending);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeDisk(copied.value, &out.writer);
    var again = try parse(a, out.written());
    defer release(&again);
    try std.testing.expect(again.value.provider.codex_oauth.?.refresh_pending);
}
test "Codex disk parser rejects malformed credentials" {
    const prefix = "{\"llm\":{\"default\":\"p/m\",\"providers\":{\"p\":{\"base_url\":\"https://chatgpt.com/backend-api/codex\",\"kind\":\"openai_codex\",\"codex_oauth\":";
    inline for (.{
        "{}",                                                                                            "[]",                                                                                          "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_at_ms\":1.5}",
        "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_at_ms\":1,\"extra\":1}",              "{\"access_token\":\"a\",\"access_token\":\"b\",\"refresh_token\":\"r\",\"expires_at_ms\":1}", "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_at_ms\":1,\"refresh_pending\":\"true\"}",
        "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_at_ms\":1,\"refresh_pending\":null}",
    }) |bad| {
        const raw = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, bad, "}}}}" });
        defer std.testing.allocator.free(raw);
        if (parse(std.testing.allocator, raw)) |value| {
            var unexpected = value;
            release(&unexpected);
            return error.ExpectedInvalidCodexCredential;
        } else |_| {}
    }
}
test "official services without an explicit credential source never borrow keys" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("DEEPSEEK_API_KEY", "fake-unselected");
    var c = testConfig();
    c.provider.api_key_env = "";
    for (providers.Id.all) |id| {
        c.provider.base_url = id.baseUrl();
        c.provider.kind = if (id == .openai_codex) id else null;
        try std.testing.expectError(error.ApiKeyNotFound, resolveApiKey(a, c, &env));
    }
    c.provider.kind = .deepseek;
    c.provider.base_url = providers.Id.opencode_go.baseUrl();
    try std.testing.expectError(error.ProviderEndpointMismatch, validate(c));
}
test "minimal JSON uses defaults and owns strings" {
    const a = std.testing.allocator;
    const input = try a.dupe(u8, fixture);
    const parsed = try parse(a, input);
    defer parsed.deinit();

    // 先覆盖并释放输入，若字符串仍指向输入缓冲区，下面的断言会失败。
    @memset(input, 'x');
    a.free(input);

    try std.testing.expectEqualStrings("test-model", parsed.value.model.name);
    try std.testing.expectEqualStrings("TEST_KEY", parsed.value.provider.api_key_env);
    try std.testing.expectEqual(@as(u32, 300000), parsed.value.limits.command_timeout_ms);
    try std.testing.expectEqual(@as(u32, 65536), parsed.value.limits.read_bytes);
    try std.testing.expectEqual(@as(u32, 32768), parsed.value.limits.output_bytes);
    try std.testing.expectEqual(protocol.Protocol.auto, parsed.value.model.protocol);
}
test "explicit protocol reasoning and limits overrides own their strings" {
    const a = std.testing.allocator;
    const input = try a.dupe(u8,
        \\{"llm":{"default":"p/custom","providers":{"p":{"base_url":"http://localhost:8080/v1","api_key_env":"KEY","models":{"custom":{"context_tokens":65536,"protocol":"responses","reasoning_effort":"high"}}}}},"limits":{"max_rounds":10}}
    );
    const parsed = try parse(a, input);
    defer parsed.deinit();
    @memset(input, 'x');
    a.free(input);

    const patch = parsed.value.registry.?.find("p").?.patchFor("custom").?;
    try std.testing.expectEqual(protocol.Protocol.responses, patch.protocol.?);
    try std.testing.expectEqualStrings("high", patch.reasoning_effort.?);
    try std.testing.expectEqual(@as(?u16, 10), parsed.value.limits.max_rounds);
}
test "round limits missing null and legacy numbers survive config serialization" {
    const a = std.testing.allocator;
    const prefix = "{\"llm\":{\"default\":\"local/fake\",\"providers\":{\"local\":{\"base_url\":\"http://localhost\"}}},\"limits\":";
    const cases = [_]struct { json: []const u8, expected: ?u16 }{
        .{ .json = "{}", .expected = null },
        .{ .json = "{\"max_rounds\":null}", .expected = null },
        .{ .json = "{\"max_rounds\":1}", .expected = 1 },
        .{ .json = "{\"max_rounds\":50}", .expected = 50 },
        .{ .json = "{\"max_rounds\":4096}", .expected = 4096 },
    };
    try std.testing.expectEqual(@as(?u16, null), testConfig().limits.max_rounds);
    for (cases) |case| {
        const input = try std.mem.concat(a, u8, &.{ prefix, case.json, "}" });
        defer a.free(input);
        var parsed = try parse(a, input);
        defer release(&parsed);
        try std.testing.expectEqual(case.expected, parsed.value.limits.max_rounds);
        var copied = try clone(a, parsed.value);
        defer release(&copied);
        try std.testing.expectEqual(case.expected, copied.value.limits.max_rounds);
        var disk: std.Io.Writer.Allocating = .init(a);
        defer disk.deinit();
        try writeDisk(parsed.value, &disk.writer);
        var restored = try parse(a, disk.written());
        defer release(&restored);
        try std.testing.expectEqual(case.expected, restored.value.limits.max_rounds);
    }
    for ([_][]const u8{ "{\"max_rounds\":0}", "{\"max_rounds\":4097}" }) |limits| {
        const input = try std.mem.concat(a, u8, &.{ prefix, limits, "}" });
        defer a.free(input);
        try std.testing.expectError(error.InvalidLimit, parse(a, input));
    }
}
test "strict JSON rejects missing unknown duplicate and TOML fields" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingField, parse(a, "{}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"provider\":{}}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"unknown\":1}"));

    // Former root fields are rejected even when they contain a plausible key.
    try std.testing.expectError(error.UnknownField, parse(a, "{\"provider\":{\"api_key\":\"fake-key\"}}"));
    try std.testing.expectError(error.DuplicateField, parse(a, "{\"provider\":{\"base_url\":\"x\",\"base_url\":\"y\"}}"));
    try std.testing.expectError(error.UnexpectedToken, parse(a, "[provider]\nbase_url = 'https://example.invalid'"));
}
test "reject invalid URL and header injection" {
    var c = testConfig();
    for ([_][]const u8{ "", "ftp://host", "https:///v1", "https://u:p@host/v1", "https://host?key=x", "https://host#x", "https://host\r\nX: y", "https://host/%0d%0a", "https://host\\evil", "https://host:0", "https://ho%40st", "https://host/%xx" }) |url| {
        c.provider.base_url = url;
        try std.testing.expectError(error.InvalidBaseUrl, validate(c));
    }

    c = testConfig();
    c.provider.api_key_env = "KEY\r\nX";
    try std.testing.expectError(error.InvalidApiKeyEnv, validate(c));

    c = testConfig();
    c.model.name = "\r\n";
    try std.testing.expectError(error.InvalidModel, validate(c));
    c.model.name = "";
    try std.testing.expectError(error.InvalidModel, validate(c));
}
test "budget ratios and bounded limits" {
    var c = testConfig();
    // Input preflight retains physical context safety without an output policy.
    c.model.context_tokens = 6144;
    try validate(c);
    c.model.context_tokens = c.limits.safety_tokens + 1;
    try std.testing.expectError(error.InvalidBudget, validate(c));

    c = testConfig();
    // A declared model output capability remains positive, independently of context.
    c.model.output_tokens = 0;
    try std.testing.expectError(error.InvalidBudget, validate(c));
    c = testConfig();

    // 压缩目标不能不低于触发阈值。
    c.limits.compaction_target_percent = 80;
    try std.testing.expectError(error.InvalidCompactionRatio, validate(c));
    c = testConfig();
    c.limits.compaction_trigger_percent = 100;
    try std.testing.expectError(error.InvalidCompactionRatio, validate(c));

    // Numeric zero is invalid; false intentionally disables automatic compaction.
    inline for (@typeInfo(Limits).@"struct".field_names) |field| {
        if (comptime std.mem.eql(u8, field, "index_bytes")) continue;
        c = testConfig();
        if (@TypeOf(@field(c.limits, field)) == bool) {
            @field(c.limits, field) = false;
            try validate(c);
        } else {
            @field(c.limits, field) = 0;
            try std.testing.expectError(error.InvalidLimit, validate(c));
        }
    }

    // 超过硬上限的大小字段必须报错。index_bytes is retained only for
    // configuration compatibility and deliberately has no total budget.
    inline for (.{ "core_bytes", "read_bytes", "shard_bytes", "max_response_bytes" }) |field| {
        c = testConfig();
        @field(c.limits, field) = std.math.maxInt(u32);
        try std.testing.expectError(error.InvalidLimit, validate(c));
    }
    c = testConfig();
    c.limits.index_bytes = std.math.maxInt(u32);
    try validate(c);
    c = testConfig();

    c.limits.command_timeout_ms = c.limits.command_max_timeout_ms + 1;
    try std.testing.expectError(error.InvalidLimit, validate(c));
}
test "load owns data after file removal and enforces 64 KiB" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = fixture });
    const path = try tmp.dir.realPathFileAlloc(io, file_name, a);
    defer a.free(path);
    const parsed = try load(a, io, path);
    defer parsed.deinit();

    // 删除文件后，已解析的字符串仍然有效，说明数据已被复制。
    try tmp.dir.deleteFile(io, file_name);
    try std.testing.expectEqualStrings("https://example.invalid/v1", parsed.value.provider.base_url);
    try std.testing.expectEqualStrings("test-model", parsed.value.model.name);

    // 超过 64 KiB 一个字节，应当被拒绝。
    const oversized = try a.alloc(u8, max_config_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    @memcpy(oversized[0..fixture.len], fixture);
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = oversized });
    try std.testing.expectError(error.ConfigTooLarge, load(a, io, path));

    // 恰好 64 KiB 的文件应当可以正常加载（前面是合法 JSON，后面用空白补齐）。
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = oversized[0..max_config_bytes] });
    const exact = try load(a, io, path);
    defer exact.deinit();
}
test "fake environment returns independent key and credential-free errors" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const c = testConfig();
    try std.testing.expectError(error.ApiKeyNotFound, resolveApiKey(a, c, &env));

    for ([_][]const u8{ "", "   ", "secret\r\nAuthorization: x", "secret\x00" }) |bad| {
        try env.put("TEST_KEY", bad);
        try std.testing.expectError(error.InvalidApiKey, resolveApiKey(a, c, &env));
    }

    try env.put("TEST_KEY", "fake-secret");
    const key = try resolveApiKey(a, c, &env);
    defer a.free(key);

    // 修改环境变量后，已返回的 key 副本不应受影响。
    try env.put("TEST_KEY", "replacement");
    try std.testing.expectEqualStrings("fake-secret", key);
}
test "fixed default path uses supplied home only" {
    const path = try defaultPath(std.testing.allocator, "/fake-home");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/fake-home/.thin/config.json", path);
    try std.testing.expectError(error.InvalidHome, defaultPath(std.testing.allocator, ""));
}
test "inline missing ambiguous and invalid API key sources" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var c = testConfig();
    c.provider.api_key_env = "";
    try validate(c);
    try std.testing.expectError(error.ApiKeyNotFound, resolveApiKey(a, c, &env));
    c.provider.api_key = "fake-inline";
    try validate(c);
    const key = try resolveApiKey(a, c, &env);
    defer {
        std.crypto.secureZero(u8, key);
        a.free(key);
    }
    try std.testing.expectEqualStrings("fake-inline", key);
    try std.testing.expect(key.ptr != c.provider.api_key.?.ptr);
    c.provider.api_key_env = "TEST_KEY";
    try std.testing.expectError(error.AmbiguousApiKey, validate(c));
    try std.testing.expectError(error.AmbiguousApiKey, resolveApiKey(a, c, &env));
    c.provider.api_key_env = "";
    for ([_][]const u8{ "", " ", "fake\r\n", "fake\x00", "fake\x7f" }) |bad| {
        c.provider.api_key = bad;
        try std.testing.expectError(error.InvalidApiKey, validate(c));
        try std.testing.expectError(error.InvalidApiKey, resolveApiKey(a, c, &env));
    }
    const big = try a.alloc(u8, 16385);
    defer a.free(big);
    @memset(big, 'f');
    c.provider.api_key = big;
    try std.testing.expectError(error.InvalidApiKey, validate(c));
    c.provider.api_key = big[0..16384];
    try validate(c);
}
test "credential and image parser cleanup and release zero owned allocations" {
    const Observer = struct {
        backing: std.mem.Allocator,
        dirty_free: bool = false,
        frees: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = WipingAllocator.resize, .remap = WipingAllocator.remap, .free = free } };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawAlloc(len, alignment, ra);
        }

        fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (bytes) |byte| if (byte != 0) {
                self.dirty_free = true;
                break;
            };
            self.frees += 1;
            self.backing.rawFree(bytes, alignment, ra);
        }
    };
    var observer = Observer{ .backing = std.testing.allocator };
    const inline_json =
        \\{"llm":{"default":"p/test","providers":{"p":{"base_url":"https://example.invalid","api_key":"fake-inline"}}}}
    ;
    var parsed = try parse(observer.allocator(), inline_json);
    try std.testing.expectEqualStrings("fake-inline", parsed.value.provider.api_key.?);
    var copied = try clone(observer.allocator(), parsed.value);
    try std.testing.expectEqualStrings("fake-inline", copied.value.provider.api_key.?);
    release(&copied);
    release(&parsed);
    try std.testing.expectError(error.UnknownField, parse(observer.allocator(),
        \\{"provider":{"base_url":"https://example.invalid","api_key":"fake-inline","unknown":1}}
    ));
    try std.testing.expectError(error.InvalidApiKey, parse(observer.allocator(),
        \\{"llm":{"default":"p/test","providers":{"p":{"base_url":"https://example.invalid","api_key":"fake\ninline"}}}}
    ));
    var registry_parsed = try parse(observer.allocator(),
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://example.invalid"},"backup":{"base_url":"https://backup.invalid","api_key":"fake-backup"}}}}
    );
    release(&registry_parsed);
    try std.testing.expectError(error.InvalidApiKey, parse(observer.allocator(),
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://example.invalid"},"backup":{"base_url":"https://backup.invalid","api_key":"fake\nbackup"}}}}
    ));
    // Observe production allocations inside each OOM attempt, not the testing
    // harness's own non-secret allocation bookkeeping.
    const FailureCase = struct {
        fn run(a: std.mem.Allocator) !void {
            var watched = Observer{ .backing = a };
            decisionAllocationCase(watched.allocator()) catch |err| {
                try std.testing.expect(!watched.dirty_free);
                return err;
            };
            try std.testing.expect(!watched.dirty_free);
        }

        fn image(a: std.mem.Allocator) !void {
            var watched = Observer{ .backing = a };
            imageAllocationCase(watched.allocator()) catch |err| {
                try std.testing.expect(!watched.dirty_free);
                return err;
            };
            try std.testing.expect(watched.frees > 0);
            try std.testing.expect(!watched.dirty_free);
        }

        fn rejectImage(a: std.mem.Allocator) !void {
            var watched = Observer{ .backing = a };
            rejectedImageAllocationCase(watched.allocator()) catch |err| {
                try std.testing.expect(!watched.dirty_free);
                return err;
            };
            try std.testing.expect(watched.frees > 0);
            try std.testing.expect(!watched.dirty_free);
        }

        fn reject(a: std.mem.Allocator) !void {
            var watched = Observer{ .backing = a };
            // Test-input construction bypasses the observer; only production
            // parse allocations belong to the final rawFree wiping contract.
            rejectedDecisionAllocationCase(watched.allocator()) catch |err| {
                try std.testing.expect(!watched.dirty_free);
                return err;
            };
            try std.testing.expect(watched.frees > 0);
            try std.testing.expect(!watched.dirty_free);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.image, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.rejectImage, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.run, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FailureCase.reject, .{});
    try std.testing.expect(observer.frees > 0);
    try std.testing.expect(!observer.dirty_free);
}
test "proxy endpoint parses host forms and borrows the input" {
    const ipv4 = " 127.0.0.1:8080\t";
    const parsed4 = (try parseProxyEndpoint(ipv4)).?;
    try std.testing.expectEqualStrings("127.0.0.1", parsed4.address);
    try std.testing.expectEqual(@as(u16, 8080), parsed4.port);
    // The address is a slice of the caller's bytes, not a copy.
    try std.testing.expect(parsed4.address.ptr == ipv4.ptr + 1);

    const dns = try parseProxyEndpoint("proxy.example.invalid.:3128");
    try std.testing.expectEqualStrings("proxy.example.invalid.", dns.?.address);
    try std.testing.expectEqual(@as(u16, 3128), dns.?.port);

    // Only bracketed IPv6 literals are accepted, and the brackets are removed.
    const v6raw = "[::1]:65535";
    const v6 = (try parseProxyEndpoint(v6raw)).?;
    try std.testing.expectEqualStrings("::1", v6.address);
    try std.testing.expectEqual(@as(u16, 65535), v6.port);
    try std.testing.expect(v6.address.ptr == v6raw.ptr + 1);

    // All-whitespace (including a stripped control-only input) disables a proxy.
    try std.testing.expect((try parseProxyEndpoint("")) == null);
    try std.testing.expect((try parseProxyEndpoint(" \t\r\n")) == null);
    // Whitespace at the exact bound is still a clear, not an overflow.
    const exact_blank: [max_proxy_endpoint_bytes]u8 = @splat(' ');
    try std.testing.expect((try parseProxyEndpoint(&exact_blank)) == null);
}
test "proxy endpoint rejects malformed, unbounded and non-host forms" {
    try std.testing.expectError(error.InvalidProxyPort, parseProxyEndpoint("127.0.0.1:0"));
    try std.testing.expectError(error.InvalidProxyPort, parseProxyEndpoint("127.0.0.1:65536"));
    try std.testing.expectError(error.InvalidProxyPort, parseProxyEndpoint("127.0.0.1:"));
    try std.testing.expectError(error.InvalidProxyPort, parseProxyEndpoint("127.0.0.1:-1"));
    try std.testing.expectError(error.InvalidProxyPort, parseProxyEndpoint("127.0.0.1:80x"));
    // Schemes, userinfo and paths are not endpoints.
    try std.testing.expectError(error.InvalidProxyAddress, parseProxyEndpoint("http://127.0.0.1:8080"));
    try std.testing.expectError(error.InvalidProxyAddress, parseProxyEndpoint("user:secret@127.0.0.1:8080"));
    try std.testing.expectError(error.InvalidProxyPort, parseProxyEndpoint("127.0.0.1:8080/v1"));
    // Unbracketed IPv6, zone identifiers and bracketed non-IPv6 are refused.
    try std.testing.expectError(error.InvalidProxyAddress, parseProxyEndpoint("::1:8080"));
    try std.testing.expectError(error.InvalidProxyAddress, parseProxyEndpoint("[fe80::1%25eth0]:8080"));
    try std.testing.expectError(error.InvalidProxyAddress, parseProxyEndpoint("[127.0.0.1]:8080"));
    try std.testing.expectError(error.InvalidProxyAddress, parseProxyEndpoint("bad\nhost:80"));
    try std.testing.expectError(error.InvalidProxyAddress, parseProxyEndpoint("host name:80"));
    const oversized: [max_proxy_endpoint_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.InputTooLarge, parseProxyEndpoint(&oversized));
    // Raw-byte bound applies before trimming, so whitespace cannot dodge it.
    const oversized_blank: [max_proxy_endpoint_bytes + 1]u8 = @splat(' ');
    try std.testing.expectError(error.InputTooLarge, parseProxyEndpoint(&oversized_blank));
}
