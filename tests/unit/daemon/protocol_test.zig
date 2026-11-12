test "subagent tool progress roundtrip and malformed wire" {
    const a = std.testing.allocator;
    const values = [_]?[]const u8{ null, "", "first\n第二行\t\x01" };
    for (values) |value| {
        const event: r.Event = .{ .tool_view = .{
            .key = .{ .generation = std.math.maxInt(u64), .index = 3 },
            .name = "subagent",
            .fields = .{ .id = .{ .text = "job-7" } },
            .subagent_progress = value,
        } };
        const bytes = try encodeEvent(a, event);
        defer a.free(bytes);
        var decoded = try decodeEvent(a, bytes);
        defer decoded.deinit();
        const view = decoded.event.tool_view;
        try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), view.key.generation);
        try std.testing.expectEqual(@as(usize, 3), view.key.index);
        try std.testing.expectEqualStrings("job-7", view.fields.id.?.text);
        if (value) |expected| try std.testing.expectEqualStrings(expected, view.subagent_progress.?) else try std.testing.expect(view.subagent_progress == null);
        try expectEventRoundTrip(a, event);
    }
    const long = try a.alloc(u8, 2050);
    defer a.free(long);
    @memset(long, 'x');
    const complete = try encodeEvent(a, .{ .tool_view = .{ .key = .{ .generation = 1, .index = 0 }, .name = "subagent", .subagent_progress = long } });
    defer a.free(complete);
    var decoded_long = try decodeEvent(a, complete);
    defer decoded_long.deinit();
    try std.testing.expect(!decoded_long.display_truncated);
    try std.testing.expectEqualStrings(long, decoded_long.event.tool_view.subagent_progress.?);
    for ([_][]const u8{
        "{\"t\":\"tool_view\",\"name\":\"x\",\"gen\":1,\"idx\":0,\"display\":null,\"sprog\":1}",
        "{\"t\":\"tool_view\",\"name\":\"x\",\"gen\":1,\"idx\":0,\"display\":null,\"sprog\":{}}",
        "{\"t\":\"tool_view\",\"name\":\"x\",\"gen\":1.0,\"idx\":0,\"display\":null,\"sprog\":null}",
        "{\"t\":\"tool_view\",\"name\":\"x\",\"gen\":1,\"idx\":0.0,\"display\":null,\"sprog\":null}",
        "{\"t\":\"tool_view\",\"name\":\"x\",\"gen\":1,\"idx\":0,\"sprog\":null,\"sprog\":\"duplicate\"}",
        "{\"t\":\"tool_view\",\"name\":\"x\",\"gen\":1,\"idx\":0,\"sprog\":null} trailing",
    }) |json| try std.testing.expectError(error.BadRequest, decodeEvent(a, json));
}
test "every runtime display event round-trips through the wire" {
    const a = std.testing.allocator;
    const high = std.math.maxInt(u64);
    const blocks = [_]p.Block{
        .{ .text = "answer" },
        .{ .reasoning = "because" },
        .{ .tool_call = .{ .id = "call-1", .name = "bash", .arguments = "{\"command\":\"ls\"}", .item_id = "item-9" } },
        .{ .tool_result = .{ .call_id = "call-1", .text = "ok", .is_error = true, .canceled = true, .truncated = true } },
    };
    const fields = preview.Snapshot{
        .path = .{ .text = "src/a.zig", .truncated = true },
        .command = .{ .text = "zig build" },
        .action = .{ .text = "run" },
        .topic = .{ .text = "build" },
        .task = .{ .text = "inspect release paths" },
        .id = .{ .text = "job-3" },
    };
    const events = [_]r.Event{
        .{ .state = .awaiting_permission },
        .{ .context_snapshot = .{ .tokens = 1234, .limit = 65536, .known = false } },
        .{ .text = "visible" },
        .{ .reasoning = "thinking" },
        .{ .assistant_committed = &blocks },
        .{ .user_committed = .{ .id = high, .text = "hi" } },
        .{ .permission_cleared = high },
        .{ .tool_preview = .{ .index = 2, .arguments = "{\"path\":\"x\"}", .write_file = true, .argument_bytes = 4096 } },
        .{ .tool_views = .{ .generation = high, .phase = .commit } },
        .{ .tool_view = .{
            .key = .{ .generation = high, .index = 7 },
            .name = "write_file",
            .fields = fields,
            .write_progress = .{ .added = 12, .deleted = 3 },
            .ready = true,
        } },
        .{ .permission = .{ .id = high, .tool_name = "bash", .description = "rm -rf build" } },
        .{ .tool_started = .{
            .id = high,
            .name = "read_file",
            .started_ms = high,
            .display_key = .{ .generation = high, .index = 1 },
        } },
        .{ .tool_result = .{
            .id = 9,
            .name = "write_file",
            .display_key = .{ .generation = 3, .index = 5 },
            .result = .{
                .text = "written",
                .is_error = true,
                .canceled = true,
                .truncated = true,
                .cleanup_failed = true,
                .memory_evidence = false,
                .file_stats = .{ .read = 40, .partial = true, .changes = .{ .modified = 1, .added = 2, .removed = 3 } },
                .duration_ms = high,
            },
        } },
        .{ .usage = .{
            .purpose = .summary,
            .protocol = .anthropic,
            .value = .{ .input_tokens = high, .output_tokens = 2, .cached_input_tokens = 3, .cache_write_tokens = 4, .reasoning_tokens = 5, .total_tokens = 6 },
        } },
        .{ .fallback = .responses },
        .{ .compacted = .{ .before = 100, .after = 10 } },
        .{ .compaction_failed = error.InputBudgetSummaryFailed },
        .{ .finished = .{
            .status = .paused,
            .detail = error.InputBudgetExceeded,
            .model_failure = .output_limit,
            .http_status = 429,
            .usage = .{
                .normal_calls = 3,
                .summary_calls = 1,
                .normal = .{ .input_tokens = 1, .output_tokens = 2, .cached_input_tokens = 3, .cache_write_tokens = 4, .reasoning_tokens = 5, .total_tokens = 6 },
                .summary = .{ .input_tokens = 7, .output_tokens = 8, .cached_input_tokens = 9, .cache_write_tokens = 10, .reasoning_tokens = 11, .total_tokens = 12 },
            },
            .context_snapshot = .{ .tokens = 42, .limit = 1000, .known = true },
        } },
    };
    for (events) |event| try expectEventRoundTrip(a, event);
}
test "tool_view decodes its display fields instead of an unsupported event" {
    const a = std.testing.allocator;
    const json =
        "{\"t\":\"tool_view\",\"name\":\"bash\",\"gen\":18446744073709551615,\"idx\":3,\"ready\":true," ++
        "\"fields\":{\"path\":{\"text\":\"src/a.zig\",\"trunc\":true},\"command\":{\"text\":\"zig build\",\"trunc\":false}," ++
        "\"action\":null,\"topic\":null,\"task\":null,\"id\":null}," ++
        "\"display\":null,\"wprog\":{\"added\":4,\"deleted\":null}}";
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    const view = decoded.event.tool_view;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), view.key.generation);
    try std.testing.expectEqual(@as(usize, 3), view.key.index);
    try std.testing.expect(view.ready);
    try std.testing.expectEqualStrings("src/a.zig", view.fields.path.?.text);
    try std.testing.expect(view.fields.path.?.truncated);
    try std.testing.expectEqualStrings("zig build", view.fields.command.?.text);
    try std.testing.expect(!view.fields.command.?.truncated);
    try std.testing.expect(view.fields.action == null);
    try std.testing.expectEqual(@as(?u64, 4), view.write_progress.?.added);
    try std.testing.expectEqual(@as(?u64, null), view.write_progress.?.deleted);
}
test "u64 values above i64.max survive number_string decoding" {
    const a = std.testing.allocator;
    const high = std.math.maxInt(u64);
    var request = try parseRequest(a, "{\"v\":5,\"id\":18446744073709551615,\"op\":\"ping\"}");
    defer request.deinit();
    try std.testing.expectEqual(high, request.id);
    try std.testing.expectEqual(Op.ping, request.op);

    // Quoted digits, floats, exponents and negatives are not integers.
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":5,\"id\":\"18446744073709551615\",\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":5,\"id\":1.0,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":5,\"id\":1e3,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":5,\"id\":-1,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":5,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":5,\"id\":0,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":5,\"id\":1,\"op\":\"ping\",\"op\":\"list\"}"));

    const encoded = try encodeEvent(a, .{ .tool_started = .{
        .id = high,
        .name = "bash",
        .started_ms = high,
        .display_key = .{ .generation = high, .index = 1 },
    } });
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "18446744073709551615") != null);
    var decoded = try decodeEvent(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(high, decoded.event.tool_started.id);
    try std.testing.expectEqual(@as(?u64, high), decoded.event.tool_started.started_ms);
    try std.testing.expectEqual(high, decoded.event.tool_started.display_key.?.generation);
}
test "numeric and enum request fields reject wrong types instead of defaulting" {
    const a = std.testing.allocator;
    var request = try parseRequest(a, "{\"v\":5,\"id\":2,\"op\":\"effort\",\"epoch\":\"7\",\"level\":true}");
    defer request.deinit();
    try std.testing.expectError(error.BadRequest, request.u64Field("epoch"));
    try std.testing.expectError(error.BadRequest, request.u64Field("absent"));
    try std.testing.expectEqual(@as(?u64, null), try request.optionalU64("absent"));
    try std.testing.expectError(error.BadRequest, request.optionalU64("epoch"));
    try std.testing.expectError(error.BadRequest, request.stringEnum(Op, "epoch"));
    try std.testing.expectError(error.BadRequest, request.boolField("epoch", true));
    try std.testing.expectEqual(true, try request.boolField("level", false));
    try std.testing.expectEqual(true, try request.requiredBool("level"));
}
test "proxy_address accepts an empty clear and maps endpoint rejections to invalid_input" {
    const a = std.testing.allocator;
    var cleared = try parseRequest(a, "{\"v\":5,\"id\":9,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"\"}");
    defer cleared.deinit();
    try std.testing.expectEqual(Op.proxy_address, cleared.op);
    try std.testing.expectEqualStrings("", try cleared.stringField("value", 320));

    // A missing, null or non-string `value` is a bad request, never a clear.
    for ([_][]const u8{
        "{\"v\":5,\"id\":10,\"op\":\"proxy_address\",\"epoch\":1}",
        "{\"v\":5,\"id\":11,\"op\":\"proxy_address\",\"epoch\":1,\"value\":null}",
        "{\"v\":5,\"id\":12,\"op\":\"proxy_address\",\"epoch\":1,\"value\":8080}",
    }) |json| {
        var request = try parseRequest(a, json);
        defer request.deinit();
        try std.testing.expectError(error.BadRequest, request.stringField("value", 320));
    }

    try std.testing.expectEqual(ErrorCode.invalid_input, errorCode(error.InvalidProxyAddress));
    try std.testing.expectEqual(ErrorCode.invalid_input, errorCode(error.InvalidProxyPort));
    try std.testing.expectEqual(ErrorCode.input_too_large, errorCode(error.InputTooLarge));
}
test "proxy_model request keeps the full u64 epoch and rejects loose parameters" {
    const a = std.testing.allocator;
    const high: u64 = @as(u64, std.math.maxInt(i64)) + 7;
    const body = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":3,\"op\":\"proxy_model\",\"epoch\":{d},\"name\":\"opencode-go/deepseek-v3\",\"enabled\":true}}", .{ version, high });
    defer a.free(body);
    var request = try parseRequest(a, body);
    defer request.deinit();
    try std.testing.expectEqual(Op.proxy_model, request.op);
    // An epoch above i64.max is exact, never truncated through a signed parse.
    try std.testing.expectEqual(high, try request.u64Field("epoch"));
    // The name is the complete provider/raw-model id, slash included.
    try std.testing.expectEqualStrings("opencode-go/deepseek-v3", try request.stringField("name", max_name));
    try std.testing.expectEqual(true, try request.requiredBool("enabled"));

    // Absent, stringly or numeric enable flags are bad requests, not defaults.
    var loose = try parseRequest(a, "{\"v\":5,\"id\":4,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\"}");
    defer loose.deinit();
    try std.testing.expectError(error.BadRequest, loose.requiredBool("enabled"));
    var stringly = try parseRequest(a, "{\"v\":5,\"id\":5,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":\"true\"}");
    defer stringly.deinit();
    try std.testing.expectError(error.BadRequest, stringly.requiredBool("enabled"));
    var numeric_epoch = try parseRequest(a, "{\"v\":5,\"id\":6,\"op\":\"proxy_model\",\"epoch\":\"1\",\"name\":\"p/m\",\"enabled\":false}");
    defer numeric_epoch.deinit();
    try std.testing.expectError(error.BadRequest, numeric_epoch.u64Field("epoch"));
}
test "decode rejects duplicate keys, deep nesting, quoted numbers and bad kinds" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"state\",\"phase\":\"calling_model\",\"phase\":\"compacting\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"permission\",\"id\":\"7\",\"name\":\"bash\",\"desc\":\"x\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"permission\",\"id\":7,\"name\":\"bash\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"tool_started\",\"name\":\"bash\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"tool_started\",\"id\":1.5,\"name\":\"bash\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"unknown_kind\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"v\":1}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, ""));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "\xff"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "[]"));

    var deep = std.ArrayList(u8).empty;
    defer deep.deinit(a);
    try deep.appendSlice(a, "{\"t\":\"text\",\"v\":");
    for (0..128) |_| try deep.append(a, '[');
    for (0..128) |_| try deep.append(a, ']');
    try deep.append(a, '}');
    try std.testing.expectError(error.BadRequest, decodeEvent(a, deep.items));
}
test "event metadata markers control epoch and canonical completeness" {
    const a = std.testing.allocator;
    const json = try encodeEventMeta(a, .{ .text = "partial" }, .{ .epoch = 42, .truncated = true, .canonical_complete = false });
    defer a.free(json);
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 42), decoded.epoch);
    try std.testing.expect(decoded.display_truncated);
    try std.testing.expect(!decoded.canonical_complete);
    const again = try encodeEventMeta(a, decoded.event, .{
        .epoch = decoded.epoch,
        .truncated = decoded.display_truncated,
        .canonical_complete = decoded.canonical_complete,
    });
    defer a.free(again);
    try std.testing.expectEqualStrings(json, again);
}
test "assistant decoding retains blocks beyond former cap" {
    const a = std.testing.allocator;
    const json = try manyBlocksJson(a, 257);
    defer a.free(json);
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 257), decoded.event.assistant_committed.len);
    try std.testing.expect(decoded.canonical_complete);
    try std.testing.expect(!decoded.display_truncated);
}
test "assistant encoding retains blocks beyond former cap" {
    const a = std.testing.allocator;
    const blocks = try a.alloc(p.Block, 257);
    defer a.free(blocks);
    for (blocks) |*block| block.* = .{ .text = "b" };
    const json = try encodeEvent(a, .{ .assistant_committed = blocks });
    defer a.free(json);
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 257), decoded.event.assistant_committed.len);
    try std.testing.expect(decoded.canonical_complete);
    try std.testing.expect(!decoded.display_truncated);
}
test "assistant decoding owns blocks in the document arena under allocation failure" {
    const a = std.testing.allocator;
    const json = try manyBlocksJson(a, 3);
    defer a.free(json);
    try std.testing.checkAllAllocationFailures(a, decodeAssistantOwned, .{json});
}
test "decoded blocks borrow their document after the wire buffer changes" {
    const a = std.testing.allocator;
    const wire = try a.dupe(u8,
        \\{"t":"assistant","epoch":9,"blocks":[{"k":"text","v":"answer"},{"k":"reasoning","v":"because"},{"k":"tool_call","id":"call-1","name":"search","args":"q=1","item":"item-1"},{"k":"tool_result","id":"call-1","v":"done","is_error":true,"canceled":true,"trunc":true}]}
    );
    defer a.free(wire);
    var decoded = try decodeEvent(a, wire);
    defer decoded.deinit();
    @memset(wire, 0);

    try std.testing.expectEqual(@as(u64, 9), decoded.epoch);
    try std.testing.expect(!decoded.display_truncated);
    try std.testing.expect(decoded.canonical_complete);
    const blocks = decoded.event.assistant_committed;
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqualStrings("answer", blocks[0].text);
    try std.testing.expectEqualStrings("because", blocks[1].reasoning);
    try std.testing.expectEqualStrings("call-1", blocks[2].tool_call.id);
    try std.testing.expectEqualStrings("search", blocks[2].tool_call.name);
    try std.testing.expectEqualStrings("q=1", blocks[2].tool_call.arguments);
    try std.testing.expectEqualStrings("item-1", blocks[2].tool_call.item_id.?);
    try std.testing.expectEqualStrings("call-1", blocks[3].tool_result.call_id);
    try std.testing.expectEqualStrings("done", blocks[3].tool_result.text);
    try std.testing.expect(blocks[3].tool_result.is_error);
    try std.testing.expect(blocks[3].tool_result.canceled);
    try std.testing.expect(blocks[3].tool_result.truncated);
    const document_blocks = decoded.doc.value.object.get("blocks").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), document_blocks.len);
    try std.testing.expect(blocks[0].text.ptr == document_blocks[0].object.get("v").?.string.ptr);
    try std.testing.expect(blocks[2].tool_call.arguments.ptr == document_blocks[2].object.get("args").?.string.ptr);
}
test "assistant block errors release the document arena" {
    const a = std.testing.allocator;
    try std.testing.expectError(
        error.BadRequest,
        decodeEvent(a, "{\"t\":\"assistant\",\"blocks\":[{\"k\":\"text\",\"v\":\"a\"},{\"k\":\"nope\"}]}"),
    );
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"assistant\"}"));
}
test "terminal events require complete usage and keep tool timing and keys" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"finished\",\"status\":\"success\",\"usage\":{}}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"usage\",\"purpose\":\"normal\",\"protocol\":\"chat\"}"));
    const json =
        "{\"t\":\"tool_result\",\"id\":9,\"name\":\"bash\",\"v\":\"done\",\"is_error\":false,\"canceled\":false," ++
        "\"trunc\":false,\"cleanup\":false,\"ms\":18446744073709551615," ++
        "\"key\":{\"gen\":18446744073709551615,\"idx\":2},\"display\":null,\"mem_ev\":true,\"opts\":null}";
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    const result = decoded.event.tool_result;
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), result.result.duration_ms);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), result.display_key.?.generation);
    try std.testing.expectEqual(@as(usize, 2), result.display_key.?.index);
}
test "login key copy is wiped before the request arena is released" {
    const a = std.testing.allocator;
    var request = try parseRequest(a, "{\"v\":5,\"id\":1,\"op\":\"login\",\"key\":\"sk-secret\"}");
    defer request.deinit();
    const secret = request.field("key").?.string;
    try std.testing.expectEqualStrings("sk-secret", secret);
    request.wipeSecrets();
    for (secret) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
test "event encoding round-trips display text and drops inbox pointers" {
    const a = std.testing.allocator;
    const encoded = try encodeEvent(a, .{ .permission = .{ .id = 3, .tool_name = "bash", .description = "rm -rf x" } });
    defer a.free(encoded);
    var decoded = try decodeEvent(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 3), decoded.event.permission.id);
    try std.testing.expectEqualStrings("bash", decoded.event.permission.tool_name);
    try std.testing.expect(decoded.event.permission.interrupt == null);
}
test "background terminal and captions have strict owned wire values" {
    const a = std.testing.allocator;
    const terminal: background.Terminal = .{ .id = background.Id.from("job-1"), .command = background.Command.from("echo 中文"), .result = .failed, .duration_ms = 42, .exit_code = 7, .failure = .exit };
    const wire = try encodeEvent(a, .{ .background_completed = terminal });
    defer a.free(wire);
    var decoded = try decodeEvent(a, wire);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("echo 中文", decoded.event.background_completed.command.slice());
    try std.testing.expectEqual(@as(?u8, 7), decoded.event.background_completed.exit_code);
    const invalid = [_][]const u8{
        "{\"t\":\"background_completed\",\"id\":\"x\",\"command\":\"a\",\"result\":\"success\",\"duration_ms\":1,\"exit_code\":null,\"signal\":null}",
        "{\"t\":\"background_completed\",\"id\":\"x\",\"command\":\"a\\n\",\"result\":\"success\",\"duration_ms\":1,\"exit_code\":null,\"signal\":null,\"failure\":null}",
        "{\"t\":\"background_completed\",\"id\":\"x\",\"command\":\"a\",\"result\":\"success\",\"duration_ms\":1,\"exit_code\":256,\"signal\":null,\"failure\":null}",
        "{\"t\":\"background_completed\",\"id\":\"x\",\"command\":\"a\",\"result\":\"success\",\"duration_ms\":1,\"exit_code\":null,\"signal\":null,\"failure\":null,\"extra\":0}",
        "{\"t\":\"tool_view\",\"name\":\"bash\",\"gen\":1,\"idx\":0}",
        "{\"t\":\"tool_view\",\"name\":\"bash\",\"gen\":1,\"idx\":0,\"display\":{\"action\":\"start\",\"id\":null}}",
    };
    for (invalid) |json| try std.testing.expectError(error.BadRequest, decodeEvent(a, json));
    const view: r.Event = .{ .tool_view = .{ .key = .{ .generation = 1, .index = 0 }, .name = "bash", .display = .{ .action = .start, .command = background.Command.from("echo ok") } } };
    const view_wire = try encodeEvent(a, view);
    defer a.free(view_wire);
    var view_decoded = try decodeEvent(a, view_wire);
    defer view_decoded.deinit();
    try std.testing.expectEqualStrings("echo ok", view_decoded.event.tool_view.display.?.command.?.slice());
}
test "tool caption and execution wire round trips and rejects malformed fields" {
    const a = std.testing.allocator;
    const caption: background.Caption = .{ .action = .start, .id = background.Id.from("job-1"), .command = background.Command.from("echo ok") };
    const events = [_]r.Event{
        .{ .tool_view = .{ .key = .{ .generation = std.math.maxInt(u64), .index = 0 }, .name = "bash", .display = caption } },
        .{ .tool_result = .{ .id = 9, .name = "bash", .result = .{ .text = "done", .display = caption } } },
    };
    for (events) |event| {
        const wire = try encodeEvent(a, event);
        defer a.free(wire);
        var decoded = try decodeEvent(a, wire);
        defer decoded.deinit();
        const actual = switch (decoded.event) {
            .tool_view => |v| v.display.?,
            .tool_result => |v| v.result.display.?,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(caption.action, actual.action);
        try std.testing.expectEqualStrings("job-1", actual.id.?.slice());
        try std.testing.expectEqualStrings("echo ok", actual.command.?.slice());
    }
    const invalid = [_][]const u8{
        "{\"t\":\"tool_result\",\"id\":1,\"name\":\"bash\",\"v\":\"ok\"}",
        "{\"t\":\"tool_result\",\"id\":1,\"name\":\"bash\",\"v\":\"ok\",\"display\":{\"action\":\"start\",\"id\":null}}",
        "{\"t\":\"tool_result\",\"id\":1,\"name\":\"bash\",\"v\":\"ok\",\"display\":{\"action\":\"start\",\"id\":null,\"command\":null,\"extra\":0}}",
        "{\"t\":\"tool_result\",\"id\":1,\"name\":\"bash\",\"v\":\"ok\",\"display\":null,\"extra\":0}",
        "{\"t\":\"tool_view\",\"name\":\"bash\",\"gen\":1,\"idx\":0,\"display\":null,\"extra\":0}",
        "{\"t\":\"tool_view\",\"name\":\"bash\",\"gen\":1,\"idx\":0,\"display\":null,\"seq\":-1}",
        "{\"t\":\"tool_view\",\"name\":\"bash\",\"gen\":1,\"idx\":0,\"display\":{\"action\":\"start\",\"id\":null,\"command\":null,\"command\":null}}",
    };
    for (invalid) |json| try std.testing.expectError(error.BadRequest, decodeEvent(a, json));
    const long_id: [65]u8 = @splat('x');
    const long_command: [513]u8 = @splat('x');
    const long_id_wire = try std.fmt.allocPrint(a, "{{\"t\":\"tool_result\",\"id\":1,\"name\":\"bash\",\"v\":\"ok\",\"display\":{{\"action\":\"start\",\"id\":\"{s}\",\"command\":null}}}}", .{&long_id});
    defer a.free(long_id_wire);
    try std.testing.expectError(error.BadRequest, decodeEvent(a, long_id_wire));
    const long_command_wire = try std.fmt.allocPrint(a, "{{\"t\":\"tool_result\",\"id\":1,\"name\":\"bash\",\"v\":\"ok\",\"display\":{{\"action\":\"start\",\"id\":null,\"command\":\"{s}\"}}}}", .{&long_command});
    defer a.free(long_command_wire);
    try std.testing.expectError(error.BadRequest, decodeEvent(a, long_command_wire));
    var sequenced = try decodeEvent(a, "{\"t\":\"tool_result\",\"id\":1,\"name\":\"bash\",\"v\":\"ok\",\"display\":null,\"seq\":18446744073709551615,\"epoch\":1,\"disp_trunc\":false,\"canon_complete\":true}");
    sequenced.deinit();
}
test "wire version 5 is required and older packets are rejected" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u16, 5), version);
    var accepted = try parseRequest(a, "{\"v\":5,\"id\":1,\"op\":\"ping\"}");
    accepted.deinit();
    // No compatibility path for old or future peers.
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":1,\"id\":1,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":2,\"id\":1,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":3,\"id\":1,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":4,\"id\":1,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":6,\"id\":1,\"op\":\"ping\"}"));
    // Every reply envelope carries the same exact version.
    var out = Out.init(a);
    defer out.deinit();
    try out.ok(1);
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try parseWholeReply(a, bytes);
    defer doc.deinit();
    try std.testing.expectEqual(@as(i64, version), doc.value.object.get("v").?.integer);
}
test "implicit root builder handles empty roots nested values and allocation failure" {
    const Helper = struct {
        fn build(a: std.mem.Allocator) !void {
            var out = Out.init(a);
            defer out.deinit();
            try out.buf.append(a, '{');
            try out.field("v", version);
            try out.beginObject("nested");
            try out.beginArray("items");
            try out.beginObjectElement();
            try out.field("name", "first");
            try out.endObject();
            try out.beginObjectElement();
            try out.field("name", "second");
            try out.endObject();
            try out.endArray();
            try out.endObject();
            try out.field("after", true);
            const bytes = try out.finish();
            defer a.free(bytes);
            var doc = try parseWholeReply(a, bytes);
            defer doc.deinit();
            const root = doc.value.object;
            try std.testing.expectEqual(@as(i64, version), root.get("v").?.integer);
            try std.testing.expect(root.get("after").?.bool);
            const items = root.get("nested").?.object.get("items").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), items.len);
            try std.testing.expectEqualStrings("second", items[1].object.get("name").?.string);
        }
    };
    const a = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(a, Helper.build, .{});
    var empty = Out.init(a);
    defer empty.deinit();
    try empty.buf.append(a, '{');
    const bytes = try empty.finish();
    defer a.free(bytes);
    try std.testing.expectEqualStrings("{}", bytes);
    // Force the new root-state allocation to fail after the opening brace.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var root = Out.init(a);
    defer root.deinit();
    try root.buf.append(a, '{');
    root.a = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, root.field("v", version));
    try std.testing.expectEqualStrings("{", root.buf.items);
    try std.testing.expectEqual(@as(usize, 0), root.comma.items.len);
    root.a = a;
}
test "response builder rejects unbalanced output and oversized keys" {
    const a = std.testing.allocator;
    var out = Out.init(a);
    defer out.deinit();
    try out.ok(9);
    try out.field("epoch", @as(u64, 5));
    const bytes = try out.finish();
    defer a.free(bytes);
    const expected = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":9,\"ok\":true,\"epoch\":5}}", .{version});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, bytes);
}
test "error envelope from fail plus finish parses as one whole JSON object" {
    const a = std.testing.allocator;
    var out = Out.init(a);
    defer out.deinit();
    try out.fail(21, .unsupported);
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try parseWholeReply(a, bytes);
    defer doc.deinit();
    const root = doc.value.object;
    try std.testing.expectEqual(@as(i64, version), root.get("v").?.integer);
    try std.testing.expectEqual(@as(i64, 21), root.get("id").?.integer);
    try std.testing.expectEqual(false, root.get("ok").?.bool);
    try std.testing.expectEqualStrings("unsupported", root.get("err").?.string);
    // Exactly one root object: a stray closing brace would leave trailing bytes.
    try std.testing.expectEqualStrings("}", bytes[bytes.len - 1 ..]);
    try std.testing.expectEqual(@as(usize, 4), root.count());
}
test "array elements keep separators for repeated scalars and nested objects" {
    const a = std.testing.allocator;
    var out = Out.init(a);
    defer out.deinit();
    try out.ok(3);
    try out.beginArray("names");
    try out.arrayValue("first");
    try out.arrayValue("second");
    try out.arrayValue("third");
    try out.endArray();
    try out.beginArray("objects");
    for ([_][]const u8{ "a", "b" }) |name| {
        try out.beginObjectElement();
        try out.field("name", name);
        try out.endObject();
    }
    try out.endArray();
    try out.beginArray("empty");
    try out.endArray();
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try parseWholeReply(a, bytes);
    defer doc.deinit();
    const root = doc.value.object;
    const names = root.get("names").?.array;
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("first", names.items[0].string);
    try std.testing.expectEqualStrings("third", names.items[2].string);
    const objects = root.get("objects").?.array;
    try std.testing.expectEqual(@as(usize, 2), objects.items.len);
    try std.testing.expectEqualStrings("a", objects.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("b", objects.items[1].object.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 0), root.get("empty").?.array.items.len);
}
test "snapshot previews stay comma-separated and parse as one whole frame" {
    const a = std.testing.allocator;
    var out = Out.init(a);
    defer out.deinit();
    try out.ok(31);
    // Two elements: a single preview would pass even without a separator.
    const previews = [_]QueuePreview{
        .{ .id = 7, .kind = .steering, .text = "first \"quoted\" 中文" },
        .{ .id = 8, .kind = .follow_up, .text = "second" },
    };
    const session: ids.Id = @splat('a');
    try encodeSnapshot(&out, .{
        .session = session,
        .project = "/tmp/project",
        .owner = .daemon,
        .epoch = 5,
        .attached = true,
        .pending_permission = 77,
        .previews = &previews,
    });
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try parseWholeReply(a, bytes);
    defer doc.deinit();
    const snapshot = doc.value.object.get("snapshot").?.object;
    try std.testing.expectEqual(@as(i64, 5), snapshot.get("epoch").?.integer);
    try std.testing.expect(snapshot.get("attached").?.bool);
    try std.testing.expectEqual(@as(i64, 77), snapshot.get("pending").?.integer);
    const list = snapshot.get("previews").?.array;
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(i64, 7), list.items[0].object.get("id").?.integer);
    try std.testing.expectEqualStrings("steering", list.items[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("first \"quoted\" 中文", list.items[0].object.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 8), list.items[1].object.get("id").?.integer);
    try std.testing.expectEqualStrings("follow_up", list.items[1].object.get("kind").?.string);
    try std.testing.expectEqualStrings("second", list.items[1].object.get("text").?.string);
}
test "response builder preserves payload beyond old frame limit" {
    const a = std.testing.allocator;
    const big = try a.alloc(u8, 1024 * 1024 + 123);
    defer a.free(big);
    @memset(big, 'x');
    var out = Out.init(a);
    defer out.deinit();
    try out.ok(11);
    try out.field("payload", big);
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try parseWholeReply(a, bytes);
    defer doc.deinit();
    try std.testing.expectEqualStrings(big, doc.value.object.get("payload").?.string);
}
test "private startup exit codes roundtrip and never widen" {
    const cases = [_]struct { code: u8, err: anyerror }{
        .{ .code = 70, .err = error.SelectionNotFound },
        .{ .code = 71, .err = error.ResumeNotFound },
        .{ .code = 72, .err = error.InvalidResumeLength },
        .{ .code = 73, .err = error.InvalidJson },
        .{ .code = 74, .err = error.UnsupportedVersion },
        .{ .code = 75, .err = error.ResumeConflict },
        .{ .code = 76, .err = error.ResumeNotClosed },
        .{ .code = 77, .err = error.SessionInUse },
        .{ .code = 78, .err = error.UnsafeResumeFile },
        .{ .code = 79, .err = error.ResumeReadOnly },
        .{ .code = 80, .err = error.ResumeAuthenticationFailed },
        .{ .code = 81, .err = error.ApiKeyNotFound },
        .{ .code = 82, .err = error.SelectionEndpointUnavailable },
    };
    for (cases) |case| {
        try std.testing.expectEqual(@as(?u8, case.code), startupExitCode(case.err));
        try std.testing.expectEqual(case.err, startupError(case.code).?);
    }
    // Reserved but unassigned codes and everything outside the band stay null.
    try std.testing.expect(startupError(0) == null);
    try std.testing.expect(startupError(1) == null);
    try std.testing.expect(startupError(69) == null);
    try std.testing.expect(startupError(83) == null);
    try std.testing.expect(startupError(130) == null);
    try std.testing.expect(startupError(143) == null);
    try std.testing.expect(startupError(255) == null);
    // Ordinary failures keep their normal error identity: never a private code.
    try std.testing.expectEqual(@as(?u8, null), startupExitCode(error.OutOfMemory));
    try std.testing.expectEqual(@as(?u8, null), startupExitCode(error.CleanupFailed));
    try std.testing.expectEqual(@as(?u8, null), startupExitCode(error.ParentGone));
    try std.testing.expectEqual(@as(?u8, null), startupExitCode(error.Canceled));
    // The private boot mapping never widens the public v1 IPC category: a
    // SelectionNotFound failure keeps its pre-existing internal classification.
    try std.testing.expectEqual(.internal, errorCode(error.SelectionNotFound));
}
test "wire error codes keep unsupported distinct from internal" {
    try std.testing.expectEqual(.unsupported, errorCode(error.Unsupported));
    // Everything unlisted still falls back to the internal category.
    try std.testing.expectEqual(.internal, errorCode(error.CleanupFailed));
}
test "memory completion wire roundtrip owns bounded terminal values and full u64" {
    const a = std.testing.allocator;
    var terminal: memory_status.Terminal = .{ .id = std.math.maxInt(u64), .result = .failed, .failure = .storage, .saved_count = std.math.maxInt(u32) };
    terminal.summary.append("中文 · saved");
    const wire = try encodeEventMeta(a, .{ .memory_completed = terminal }, .{ .epoch = std.math.maxInt(u64) });
    defer a.free(wire);
    var decoded = try decodeEvent(a, wire);
    const owned = decoded.event.memory_completed;
    try std.testing.expectEqual(std.math.maxInt(u64), decoded.epoch);
    decoded.deinit();
    try std.testing.expectEqual(terminal.id, owned.id);
    try std.testing.expectEqual(terminal.result, owned.result);
    try std.testing.expectEqual(terminal.failure, owned.failure);
    try std.testing.expectEqual(terminal.saved_count, owned.saved_count);
    try std.testing.expectEqualStrings(terminal.summary.text(), owned.summary.text());

    // Exact capacity and a multi-byte ending remain lossless.
    var boundary: memory_status.Terminal = .{ .id = 9007199254740993, .result = .saved };
    const ascii: [253]u8 = @splat('x');
    boundary.summary.append(&ascii);
    boundary.summary.append("中"); // separate entries need a four-byte separator
    try std.testing.expectEqual(@as(usize, 253), boundary.summary.text().len);
    var full: memory_status.Terminal = .{ .id = boundary.id, .result = .saved };
    var text: [256]u8 = @splat('x');
    @memcpy(text[253..256], "中");
    full.summary.append(&text);
    const full_wire = try encodeEvent(a, .{ .memory_completed = full });
    defer a.free(full_wire);
    var full_decoded = try decodeEvent(a, full_wire);
    defer full_decoded.deinit();
    try std.testing.expectEqual(@as(usize, 256), full_decoded.event.memory_completed.summary.text().len);
    try std.testing.expectEqualStrings(&text, full_decoded.event.memory_completed.summary.text());
}
test "memory completion rejects missing unknown malformed and unsafe fields" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "{\"t\":\"memory_completed\",\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"failure\":null,\"saved_count\":0,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"saved_count\":0,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":null,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"\",\"extra\":1}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"unknown\",\"failure\":null,\"saved_count\":0,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"failed\",\"failure\":\"unknown\",\"saved_count\":0,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":false,\"saved_count\":0,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":\"1\",\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":18446744073709551616,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":4294967296,\"summary\":\"\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"bad\\u001b\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"a\\nb\"}",
        "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"\",\"seq\":null}",
        "{\"t\":\"memory_completed\",\"id\":1,\"id\":2,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"\"}",
    }) |json| try std.testing.expectError(error.BadRequest, decodeEvent(a, json));
    const too_long: [257]u8 = @splat('x');
    const wire = try std.fmt.allocPrint(a, "{{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"{s}\"}}", .{&too_long});
    defer a.free(wire);
    try std.testing.expectError(error.BadRequest, decodeEvent(a, wire));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"\xff\"}"));
}
test "memory completion decode preserves allocation failure" {
    const Scenario = struct {
        fn run(a: std.mem.Allocator) !void {
            var decoded = try decodeEvent(a, "{\"t\":\"memory_completed\",\"id\":1,\"result\":\"skipped\",\"failure\":null,\"saved_count\":0,\"summary\":\"\"}");
            defer decoded.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
test "wire error codes classify configuration rejections as invalid input" {
    const cases = [_]anyerror{
        error.ProxyNotConfigured,
        error.UnknownProvider,
        error.UnknownProxyModel,
        error.ApiKeyNotFound,
        error.MissingRegistry,
        error.InvalidDefault,
    };
    for (cases) |err| {
        try std.testing.expectEqual(.invalid_input, errorCode(err));
    }
    // A stale version guard loses a race against a newer credential write; the
    // request itself was well formed, so it is retry-busy rather than invalid.
    try std.testing.expectEqual(.busy, errorCode(error.AuthVersionConflict));
    // Reclassification never widens the neighbors it sits between.
    try std.testing.expectEqual(.unsupported, errorCode(error.Unsupported));
    try std.testing.expectEqual(.internal, errorCode(error.CleanupFailed));
}
test "decision diagnostic terminal roundtrip owns labels and rejects invalid wire values" {
    const a = std.testing.allocator;
    var diagnostic: @import("../core/decision.zig").Diagnostic = .{
        .stage = .transport,
        .backend = .systemone,
        .operation = .command,
        .transport_exit_code = 60,
    };
    diagnostic.setError(error.DecisionTransport);
    const event: r.Event = .{ .finished = .{
        .status = .paused,
        .detail = error.DecisionUnavailable,
        .decision_failure = diagnostic,
    } };
    try expectEventRoundTrip(a, event);
    const encoded = try encodeEvent(a, event);
    defer a.free(encoded);
    var decoded = try decodeEvent(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("DecisionTransport", decoded.event.finished.decision_failure.?.causeName());
    try std.testing.expectEqual(@as(?u8, 60), decoded.event.finished.decision_failure.?.transport_exit_code);
    try std.testing.expect(decoded.event.finished.http_status == null);
    var doc = try std.json.parseFromSlice(std.json.Value, a, encoded, .{ .allocate = .alloc_always });
    defer doc.deinit();
    const allocator = doc.arena.allocator();
    const fields = &doc.value.object.getPtr("decision_failure").?.object;
    try fields.put(allocator, "cause", .{ .string = "raw response\nsecret" });
    try std.testing.expectError(error.BadRequest, decodeTerminalChecked(doc.value.object));
    try fields.put(allocator, "cause", .{ .string = "DecisionTransport" });
    try fields.put(allocator, "http_status", .{ .integer = 600 });
    try std.testing.expectError(error.BadRequest, decodeTerminalChecked(doc.value.object));
    try fields.put(allocator, "http_status", .{ .null = {} });
    try fields.put(allocator, "transport_exit_code", .{ .integer = 256 });
    try std.testing.expectError(error.BadRequest, decodeTerminalChecked(doc.value.object));
    try fields.put(allocator, "transport_exit_code", .{ .integer = 60 });
    try fields.put(allocator, "stage", .{ .string = "unknown-stage" });
    try std.testing.expectError(error.BadRequest, decodeTerminalChecked(doc.value.object));
    _ = doc.value.object.swapRemove("decision_failure");
    try std.testing.expect((try decodeTerminalChecked(doc.value.object)).decision_failure == null);
}
