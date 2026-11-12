test "local command unknown price keeps output, pairs checkpoint and next normal stays gated" {
    var fake: Fake = .{};
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.executeCommand("!printf hello", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expectEqual(@as(u32, 0), terminal.usage.normal_calls + terminal.usage.summary_calls);
    try std.testing.expect(!terminal.context_snapshot.?.known);
    try std.testing.expectEqualStrings(&output, runtime.messages()[2].blocks[0].tool_result.text);
    try std.testing.expect(!runtime.messages()[2].blocks[0].tool_result.truncated);
    try paired(&runtime);
    const bytes = try cp.encode(a, try runtime.exportCheckpoint());
    defer a.free(bytes);
    const decoded = try cp.decode(a, bytes);
    defer decoded.deinit();
    // Imported permission counters are not call-ID authority.
    var state = decoded.value;
    state.permission_id = 0;
    var restored = try fake.init(&config, false);
    defer restored.deinit();
    fake.runtime = &restored;
    try restored.restoreCheckpoint(state);
    try std.testing.expectEqual(r.Status.success, (try restored.executeCommand("!second", &cancel)).status);
    try std.testing.expect(!std.mem.eql(u8, restored.messages()[1].blocks[1].tool_call.id, restored.messages()[4].blocks[1].tool_call.id));
    try paired(&restored);
    const next = try restored.run("continue", &cancel);
    try std.testing.expectEqual(error.UnknownInputPriceThreshold, next.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.primary);
    // Independently encode the canonical next-normal history without sending it.
    const encoded = try chat.encode(a, .{ .scope = .{ .connection = "https://offline.invalid", .model = "offline", .protocol = .chat }, .system = restored.system, .messages = restored.messages(), .tools = &schemas, .purpose = .normal });
    defer a.free(encoded);
    const wire = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
    defer wire.deinit();
    inline for (.{ "max_tokens", "max_completion_tokens", "max_output_tokens" }) |key|
        try std.testing.expect(wire.value.object.get(key) == null);
    try std.testing.expectEqual(@as(usize, 3), fake.finished);
    try std.testing.expectEqual(fake.finished, fake.submitted);
}
test "local command default approval and explicit denial never execute" {
    for ([_]bool{ true, false }) |default_host| {
        var fake: Fake = .{ .approve = .deny };
        const config = configuration();
        var runtime = try fake.init(&config, default_host);
        defer runtime.deinit();
        fake.runtime = &runtime;
        var cancel: p.Cancellation = .{};
        _ = try runtime.executeCommand("!denied", &cancel);
        try paired(&runtime);
        try std.testing.expectEqual(@as(usize, 0), fake.executions + fake.primary);
        try std.testing.expect(runtime.messages()[2].blocks[0].tool_result.is_error);
        try std.testing.expectEqual(@as(usize, 1), fake.finished);
    }
}
test "local command decision ask and review failure preserve pairing" {
    for ([_]?anyerror{ null, error.AuxiliaryTimeout, error.CleanupFailed }) |failure| {
        var fake: Fake = .{ .review_error = failure };
        const config = configuration();
        var runtime = try fake.init(&config, false);
        defer runtime.deinit();
        fake.runtime = &runtime;
        runtime.decision_service = .{ .context = &fake, .decide_fn = Fake.review };
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.executeCommand("!review", &cancel);
        try paired(&runtime);
        try std.testing.expectEqual(@as(usize, 1), fake.reviewed);
        try std.testing.expectEqual(@as(usize, 1), fake.finished);
        try std.testing.expectEqual(@as(usize, 0), fake.primary);
        if (failure) |err| {
            try std.testing.expectEqual(if (err == error.CleanupFailed) error.CleanupFailed else error.DecisionUnavailable, terminal.detail.?);
            try std.testing.expectEqual(@as(usize, 0), fake.executions + fake.permissions);
        } else {
            try std.testing.expectEqual(r.Status.success, terminal.status);
            try std.testing.expectEqual(@as(usize, 1), fake.executions);
            try std.testing.expectEqual(@as(usize, 1), fake.permissions);
        }
    }
}
test "local command approval and execution cancellation cleanup prepare and host errors finish once" {
    for (0..6) |mode| {
        var cancel: p.Cancellation = .{};
        var fake: Fake = .{ .cancel_on_approval = if (mode == 0) &cancel else null, .cancel_on_execute = if (mode == 1) &cancel else null, .cleanup = mode == 2, .prepare_error = mode == 3, .disconnect = mode == 4, .execute_error = mode == 5 };
        const config = configuration();
        var runtime = try fake.init(&config, false);
        defer runtime.deinit();
        fake.runtime = &runtime;
        const terminal = try runtime.executeCommand("!fixture", &cancel);
        try paired(&runtime);
        try std.testing.expectEqual(@as(usize, 1), fake.finished);
        try std.testing.expectEqual(@as(usize, 0), fake.primary);
        if (mode == 0) try std.testing.expectEqual(r.Status.canceled, terminal.status);
        if (mode == 1) {
            try std.testing.expectEqual(error.Canceled, terminal.detail.?);
            try std.testing.expectEqual(r.Status.canceled, terminal.status);
            try std.testing.expectEqual(@as(usize, 1), fake.executions);
        }
        if (mode == 2) {
            try std.testing.expect(runtime.poisoned);
            const before = fake.executions;
            _ = try runtime.executeCommand("!never", &cancel);
            try std.testing.expectEqual(before, fake.executions);
        }
        if (mode == 3 or mode == 4) try std.testing.expectEqual(@as(usize, 0), fake.executions);
        if (mode == 5) try std.testing.expectEqualStrings("CommandFailed", runtime.messages()[2].blocks[0].tool_result.text);
    }
}
test "local command validates before adding executable history" {
    var fake: Fake = .{};
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    var cancel: p.Cancellation = .{};
    for ([_][]const u8{ "! ", "no bang", "!x\x00", "!\xff" }) |text| {
        try std.testing.expectEqual(error.InvalidInput, (try runtime.executeCommand(text, &cancel)).detail.?);
    }
    try std.testing.expectEqual(@as(usize, 0), runtime.messages().len);
    try std.testing.expectEqual(@as(usize, 4), fake.finished);
    cancel.cancel();
    try std.testing.expectEqual(r.Status.canceled, (try runtime.executeCommand("!not started", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 0), fake.executions + fake.primary);
}
test "local command accepts shell input beyond former command byte quota" {
    var fake: Fake = .{ .capture_command = true };
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    // A valid no-op with trailing spaces crosses 32 KiB but stays well below
    // the operating system's per-argument limit. Execute it rather than mocking.
    const submitted = try a.alloc(u8, 32770);
    defer a.free(submitted);
    @memset(submitted, ' ');
    @memcpy(submitted[0..2], "!:");
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(r.Status.success, (try runtime.executeCommand(submitted, &cancel)).status);
    try std.testing.expectEqualStrings(submitted, runtime.messages()[0].blocks[0].text);
    const parsed = try std.json.parseFromSlice(struct { command: []const u8 }, a, runtime.messages()[1].blocks[1].tool_call.arguments, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(submitted[1..], parsed.value.command);
    try std.testing.expectEqual(@as(usize, 1), fake.executions);
    try std.testing.expectEqual(@as(usize, 0), fake.primary);
    try paired(&runtime);
}
test "local command matches trimmed UI prefix but preserves exact shell bytes" {
    var fake: Fake = .{};
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    var cancel: p.Cancellation = .{};
    const submitted = " \t! printf '%s' escaped\\ \n";
    const terminal = try runtime.executeCommand(submitted, &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expectEqual(@as(usize, 1), fake.executions);
    try std.testing.expectEqual(@as(usize, 0), fake.primary);
    const messages = runtime.messages();
    try std.testing.expectEqualStrings(submitted, messages[0].blocks[0].text);
    const arguments = messages[1].blocks[1].tool_call.arguments;
    const parsed = try std.json.parseFromSlice(struct { command: []const u8 }, a, arguments, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(" printf '%s' escaped\\ \n", parsed.value.command);
    try paired(&runtime);
}
test "local command preserves full captured output beyond former response quota without inference" {
    var fake: Fake = .{ .capture_command = true };
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    const calibration = runtime.estimator;
    var cancel: p.Cancellation = .{};
    // A short shell-only command emits more than the former 16 MiB quota;
    // do not pass an oversized script through execve/ARG_MAX.
    const terminal = try runtime.executeCommand("!i=0; while [ \"$i\" -lt 8193 ]; do printf '%02048d' 0; i=$((i+1)); done", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    const result = runtime.messages()[2].blocks[0].tool_result;
    try std.testing.expectEqual(@as(usize, 8193 * 2048), result.text.len);
    try std.testing.expectEqual(@as(usize, 0), std.mem.trim(u8, result.text, "0").len);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualDeep(calibration, runtime.estimator);
    try std.testing.expectEqual(@as(usize, 0), fake.primary);
    try paired(&runtime);
}
test "local command dense imported IDs are indexed once and pre-cancel never allocates an ID" {
    var fake: Fake = .{};
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    const owned = runtime.arena.allocator();
    const count = 65537;
    const calls = try owned.alloc(p.Block, count);
    const results = try owned.alloc(p.Block, count);
    for (calls, results, 1..) |*call, *result, number| {
        const id = try std.fmt.allocPrint(owned, "local_command_{d}", .{number});
        call.* = .{ .tool_call = .{ .id = id, .name = "old_never_execute", .arguments = "{}" } };
        result.* = .{ .tool_result = .{ .call_id = id, .text = "archived" } };
    }
    try runtime.history.append(owned, .{ .role = .assistant, .blocks = calls });
    try runtime.history.append(owned, .{ .role = .tool, .blocks = results });
    var canceled: p.Cancellation = .{};
    canceled.cancel();
    const rejected = try runtime.executeCommand("!never", &canceled);
    try std.testing.expectEqual(r.Status.canceled, rejected.status);
    try std.testing.expectEqual(@as(u64, 0), runtime.permission_id);
    try std.testing.expectEqual(@as(usize, 2), runtime.messages().len);
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(r.Status.success, (try runtime.executeCommand("!new", &cancel)).status);
    const new_call = runtime.messages()[3].blocks[1].tool_call;
    try std.testing.expectEqualStrings("local_command_65538", new_call.id);
    try std.testing.expectEqualStrings(new_call.id, runtime.messages()[4].blocks[0].tool_result.call_id);
    try std.testing.expectEqual(@as(u64, 65539), runtime.permission_id);
    try std.testing.expectEqual(@as(usize, 1), fake.executions);
    try std.testing.expectEqual(@as(usize, 0), fake.primary);
    try std.testing.expectEqual(@as(usize, 2), fake.finished);
}
test "local command malformed output completes may-have-run and cleanup failure wins" {
    for ([_]bool{ false, true }) |cleanup| {
        var fake: Fake = .{ .result_text = "bad\xffoutput", .cleanup = cleanup };
        const config = configuration();
        var runtime = try fake.init(&config, false);
        defer runtime.deinit();
        fake.runtime = &runtime;
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.executeCommand("!invalid-output", &cancel);
        try std.testing.expectEqual(if (cleanup) error.CleanupFailed else error.InvalidToolOutput, terminal.detail.?);
        const result = runtime.messages()[2].blocks[0].tool_result;
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.text, "may have run") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.text, "Not executed") == null);
        try std.testing.expectEqual(cleanup, runtime.poisoned);
        try std.testing.expectEqual(@as(usize, 1), fake.executions);
        try std.testing.expectEqual(@as(usize, 1), fake.finished);
        try paired(&runtime);
    }
}
test "local command preserves complete UTF8 across former byte boundaries and rejects malformed output" {
    // Exercise each former split position of a four-byte scalar.
    for (1..4) |split| {
        var bytes: [1030]u8 = @splat('x');
        const start = 1024 - split;
        @memcpy(bytes[start..][0..4], "\xf0\x9f\x98\x80");
        var fake: Fake = .{ .result_text = &bytes };
        const config = configuration();
        var runtime = try fake.init(&config, false);
        defer runtime.deinit();
        fake.runtime = &runtime;
        var cancel: p.Cancellation = .{};
        try std.testing.expectEqual(r.Status.success, (try runtime.executeCommand("!utf8", &cancel)).status);
        const result = runtime.messages()[2].blocks[0].tool_result;
        try std.testing.expectEqualStrings(&bytes, result.text);
        try std.testing.expect(std.unicode.utf8ValidateSlice(result.text));
        try std.testing.expect(!result.truncated);
        try paired(&runtime);
    }
    // Malformed UTF8 remains invalid even without a capture byte quota.
    var bytes: [8192]u8 = @splat('x');
    bytes[0] = 0xff;
    var fake: Fake = .{ .result_text = &bytes };
    const config = configuration();
    var runtime = try fake.init(&config, false);
    defer runtime.deinit();
    fake.runtime = &runtime;
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(error.InvalidToolOutput, (try runtime.executeCommand("!bad-prefix", &cancel)).detail.?);
    try paired(&runtime);
}
