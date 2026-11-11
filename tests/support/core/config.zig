const image_test_prefix = "{\"llm\":{\"default\":\"p/main\",\"providers\":{\"p\":{\"base_url\":\"https://fixture.invalid\"}}}";

fn imageAllocationCase(a: std.mem.Allocator) !void {
    inline for (.{ "", ",\"image\":{}", ",\"image\":{\"model\":null}", ",\"image\":{\"model\":\"p/deepseek-flash\"}" }, 0..) |suffix, index| {
        var parsed = try parse(a, image_test_prefix ++ suffix ++ "}");
        defer release(&parsed);
        try std.testing.expectEqual(index == 3, parsed.value.imageActive());
        try std.testing.expect(parsed.value.decision == null);
        try std.testing.expectEqual(index >= 3, parsed.value.image.model != null);
        var copied = try clone(a, parsed.value);
        defer release(&copied);
        if (parsed.value.image.model) |model| {
            try std.testing.expectEqualStrings("p/deepseek-flash", copied.value.image.model.?);
            try std.testing.expect(model.ptr != copied.value.image.model.?.ptr);
        }
        var wiping = WipingAllocator{ .backing = a };
        var out: std.Io.Writer.Allocating = .init(wiping.allocator());
        defer out.deinit();
        writeDisk(copied.value, &out.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        try std.testing.expectEqual(index == 3, std.mem.find(u8, out.written(), "\"image\"") != null);
        var tree = try std.json.parseFromSlice(std.json.Value, wiping.allocator(), out.written(), .{});
        defer tree.deinit();
        if (tree.value.object.get("image")) |value| {
            try std.testing.expectEqual(@as(usize, 1), value.object.count());
            try std.testing.expect(value.object.contains("model"));
        }
        var again = try parse(a, out.written());
        defer release(&again);
        try std.testing.expectEqualDeep(parsed.value.image, again.value.image);
        try std.testing.expectEqualDeep(parsed.value.limits, again.value.limits);
    }
}

fn rejectedImageAllocationCase(a: std.mem.Allocator) !void {
    inline for (.{
        "null",                                   "true",                                 "[]",                                                          "\"Off\"",
        "{\"enabled\":true}",                     "{\"enabled\":true,\"model\":null}",    "{\"model\":\"deepseek-flash\"}",                              "{\"model\":\"/deepseek-flash\"}",
        "{\"model\":\"missing/deepseek-flash\"}", "{\"model\":\"p/\"}",                   "{\"model\":\"p/deepseek-chat\"}",                             "{\"model\":\"p/deepseek-flash-preview\"}",
        "{\"model\":\"p/org/deepseek-flash\"}",   "{\"model\":\"p/DeepSeek-Flash\"}",     "{\"model\":\" p/deepseek-flash\"}",                           "{\"model\":\"p/deepseek-flash \"}",
        "{\"model\":42}",                         "{\"model\":true}",                     "{\"model\":[]}",                                              "{\"model\":{}}",
        "{\"enabled\":null}",                     "{\"enabled\":1}",                      "{\"enabled\":\"false\"}",                                     "{\"enabled\":false,\"enabled\":false}",
        "{\"model\":null,\"model\":null}",        "{\"enabled\":false,\"api_key\":null}", "{\"enabled\":true,\"model\":\"p/deepseek-flash\",\"url\":1}", "{\"request_timeout_ms\":1}",
        "{\"trust\":false}",                      "{\"unknown\":{}}",
    }) |bad| {
        if (parse(a, image_test_prefix ++ ",\"image\":" ++ bad ++ "}")) |value| {
            var parsed = value;
            release(&parsed);
            return error.ExpectedImageRejection;
        } else |err| if (err == error.OutOfMemory) return err;
    }
    if (parse(a, image_test_prefix ++ ",\"image\":{},\"image\":{}}")) |value| {
        var parsed = value;
        release(&parsed);
        return error.ExpectedImageRejection;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.DuplicateField, err);
    }
}

const decision_fixture =
    \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"http://127.0.0.1:1/v1","api_key":"fake-inline","models":{"main":{"protocol":"chat","context_tokens":32768},"org/reviewer":{"protocol":"systemone"}}}}},"limits":{"request_timeout_ms":123456},"decision":{"model":"p/org/reviewer","enabled":true,"max_input_tokens":8192,"max_state_bytes":16384}}
;

fn decisionAllocationCase(a: std.mem.Allocator) !void {
    var parsed = try parse(a, decision_fixture);
    defer release(&parsed);
    try std.testing.expectEqual(protocol.Protocol.systemone, parsed.value.registry.?.find("p").?.patchFor("org/reviewer").?.protocol.?);
    var copied = try clone(a, parsed.value);
    defer release(&copied);
    copied.value.provider.base_url = "";
    copied.value.selection_pending = true;
    var pending = try clonePendingSettings(a, copied.value);
    defer release(&pending);
    try std.testing.expect(pending.value.selection_pending);
    try std.testing.expectEqualStrings("", pending.value.provider.base_url);
    try std.testing.expectEqual(@as(u32, 123456), pending.value.decision.?.modelLimits(pending.value.limits.request_timeout_ms).request_timeout_ms);
    try std.testing.expectEqual(protocol.Protocol.chat, pending.value.registry.?.find("p").?.patchFor("main").?.protocol.?);
    try std.testing.expectEqualStrings("fake-inline", pending.value.provider.api_key.?);
    var wiping = WipingAllocator{ .backing = a };
    var out: std.Io.Writer.Allocating = .init(wiping.allocator());
    defer out.deinit();
    // This allocating writer maps allocation failures to WriteFailed.
    // Expose OOM to the exhaustive test harness without changing production.
    writeDisk(parsed.value, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    var again = try parse(a, out.written());
    defer release(&again);
    try std.testing.expectEqual(protocol.Protocol.systemone, again.value.registry.?.find("p").?.patchFor("org/reviewer").?.protocol.?);
    try std.testing.expectEqual(@as(u32, 123456), again.value.limits.request_timeout_ms);
}

const decision_test_prefix = "{\"llm\":{\"default\":\"p/m\",\"providers\":{\"p\":{\"base_url\":\"https://fixture.invalid/v1\",\"api_key\":\"fake-inline\",\"models\":{\"m\":{\"protocol\":\"chat\",\"context_tokens\":32768}}}}},\"decision\":";

fn expectUnknownDecisionField(a: std.mem.Allocator, raw: []const u8) !void {
    var parsed = parse(a, raw) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.UnknownField, err);
        return;
    };
    defer release(&parsed);
    return error.TestExpectedError;
}

fn rejectedDecisionAllocationCase(a: std.mem.Allocator) !void {
    for ([_]bool{ true, false }) |enabled| {
        for ([_][]const u8{ "\"model\"", "\"systemone\"", "\"other\"", "null", "17", "1.5" }) |backend| {
            const raw = try std.fmt.allocPrint(std.testing.allocator, "{s}{{\"model\":\"p/m\",\"enabled\":{},\"backend\":{s}}}}}", .{ decision_test_prefix, enabled, backend });
            defer std.testing.allocator.free(raw);
            try expectUnknownDecisionField(a, raw);
        }
        for ([_][]const u8{ "1", "17", "0", "-1", "3600001", "\"1\"", "null", "true", "1.5", "1e100" }) |timeout| {
            const raw = try std.fmt.allocPrint(std.testing.allocator, "{s}{{\"model\":\"p/m\",\"enabled\":{},\"request_timeout_ms\":{s}}}}}", .{ decision_test_prefix, enabled, timeout });
            defer std.testing.allocator.free(raw);
            try expectUnknownDecisionField(a, raw);
        }
    }
}

fn memoryAllocationCase(a: std.mem.Allocator) !void {
    inline for (.{ "{}", "{\"auto\":false}" }) |memory| {
        var parsed = try parse(a, image_test_prefix ++ ",\"memory\":" ++ memory ++ "}");
        defer release(&parsed);
        var copied = try clone(a, parsed.value);
        defer release(&copied);
        try std.testing.expectEqualDeep(parsed.value.memory, copied.value.memory);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        writeDisk(copied.value, &out.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        var again = try parse(a, out.written());
        defer release(&again);
        try std.testing.expectEqualDeep(copied.value.memory, again.value.memory);
    }
}

fn checkConfigAllocationFailures(comptime case: anytype) !void {
    const Stable = struct {
        fn run(a: std.mem.Allocator) !void {
            var wiping: WipingAllocator = .{ .backing = a };
            try case(wiping.allocator());
        }
    };
    // Strict exhaustive matrix over a deterministic allocation sequence.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Stable.run, .{});

    // The uninterrupted run gives the allocation-sequence upper bound.
    var nofail = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try Stable.run(nofail.allocator());
    const bound = nofail.alloc_index;
    try std.testing.expectEqual(nofail.allocated_bytes, nofail.freed_bytes);
    try std.testing.expect(bound > 0);

    var resized_then_oom: usize = 0;
    for (0..bound) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (case(failing.allocator())) |_| {
            // Fewer allocations are allowed: a successful remap can save one.
            try std.testing.expect(!failing.has_induced_failure);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            if (failing.resize_index > 0) resized_then_oom += 1;
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    // Prove the normal path still reaches OOM after a real remap succeeded.
    try std.testing.expect(resized_then_oom > 0);
}

fn currentConfigAllocationCase(a: std.mem.Allocator) !void {
    var parsed = try parse(a, image_test_prefix ++ "}");
    defer release(&parsed);
    var copied = try clone(a, parsed.value);
    defer release(&copied);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    writeDisk(copied.value, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    var again = try parse(a, out.written());
    defer release(&again);
    try std.testing.expectEqualDeep(parsed.value.limits, again.value.limits);
}

const codex_fixture =
    \\{"llm":{"default":"codex/model","providers":{"codex":{"base_url":"https://chatgpt.com/backend-api/codex","kind":"openai_codex","codex_oauth":{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_at_ms":123456789}}}}}
;

fn codexConfigAllocationCase(a: std.mem.Allocator) !void {
    var parsed = try parse(a, codex_fixture);
    defer release(&parsed);
    var copied = try clone(a, parsed.value);
    defer release(&copied);
    const original = parsed.value.provider.codex_oauth.?;
    const clone_credential = copied.value.provider.codex_oauth.?;
    try std.testing.expectEqualStrings(original.access_token, clone_credential.access_token);
    try std.testing.expect(original.access_token.ptr != clone_credential.access_token.ptr);
    try std.testing.expect(original.refresh_token.ptr != clone_credential.refresh_token.ptr);
    var wiping = WipingAllocator{ .backing = a };
    var out: std.Io.Writer.Allocating = .init(wiping.allocator());
    defer out.deinit();
    writeDisk(copied.value, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    var again = try parse(a, out.written());
    defer release(&again);
    try std.testing.expectEqualStrings("fixture-refresh", again.value.provider.codex_oauth.?.refresh_token);
    try std.testing.expectEqual(@as(i64, 123456789), again.value.provider.codex_oauth.?.expires_at_ms);
    try std.testing.expect(!original.refresh_pending);
    try std.testing.expect(!clone_credential.refresh_pending);
    try std.testing.expect(!again.value.provider.codex_oauth.?.refresh_pending);
}

const fixture =
    \\{"llm":{"default":"local/test-model","providers":{"local":{"base_url":"https://example.invalid/v1","api_key_env":"TEST_KEY"}}}}
;

fn testConfig() Config {
    return .{ .provider = .{ .base_url = "https://example.invalid/v1", .api_key_env = "TEST_KEY" }, .model = .{ .name = "test-model", .context_tokens = 32768 } };
}
