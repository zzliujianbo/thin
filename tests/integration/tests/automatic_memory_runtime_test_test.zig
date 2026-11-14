test "automatic Memory headless log-off captures user and complete tool only once" {
    var fake = Fake{ .tool = true };
    var config = configValue();
    config.memory.auto = false; // Manual retrieval remains active; App owns finalization policy.
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("durable user fact", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expectEqual(@as(usize, 1), fake.completes);
    try std.testing.expectEqual(@as(usize, 2), fake.source_count);
    try std.testing.expectEqualStrings("durable user factverified tool fact", fake.captured());
    try std.testing.expect(runtime.memory_capture == null);
    try std.testing.expectEqual(@as(u32, 2), terminal.usage.normal_calls);
    try std.testing.expectEqual(@as(u32, 0), terminal.usage.summary_calls);
    try std.testing.expectEqualStrings("project facts A", fake.reference);
    try std.testing.expect(std.mem.endsWith(u8, lastReference(&runtime), fake.reference));
}
test "automatic Memory excludes errored canceled truncated cleanup and sensitive tool material" {
    for ([_]r.Execution{
        .{ .text = "error detail", .is_error = true },
        .{ .text = "partial cancellation", .canceled = true },
        .{ .text = "fragment", .truncated = true },
        .{ .text = "-----BEGIN PRIVATE KEY-----" },
    }) |output| {
        var fake = Fake{ .tool = true, .output = output };
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        const terminal = try runtime.run("user fact", &cancel);
        if (output.canceled) {
            try std.testing.expectEqual(r.Status.canceled, terminal.status);
            try std.testing.expectEqual(@as(usize, 0), fake.completes);
            continue;
        }
        try std.testing.expectEqual(r.Status.success, terminal.status);
        try std.testing.expectEqualStrings("user fact", fake.captured());
        try std.testing.expectEqual(@as(usize, 1), fake.source_count);
    }
}
test "automatic Memory never completes failure cancellation or assistant commit disconnect" {
    for (0..4) |mode| {
        var cancel: p.Cancellation = .{};
        var fake = Fake{ .fail = mode == 0, .disconnect = mode == 1, .cancel_stop = if (mode == 2) &cancel else null, .tool = mode == 3, .output = .{ .text = "unsafe", .cleanup_failed = mode == 3 } };
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        const terminal = try runtime.run("user fact", &cancel);
        try std.testing.expect(terminal.status != .success);
        try std.testing.expectEqual(@as(usize, 0), fake.completes);
        try std.testing.expect(runtime.memory_capture == null);
    }
}
test "automatic Memory refused response remains visible successful but never finalizes" {
    var fake = Fake{ .refused = true };
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("refused task", &cancel)).status);
    try std.testing.expectEqual(@as(usize, 0), fake.completes);
    try std.testing.expectEqual(@as(usize, 1), fake.finished);
    const last = runtime.messages()[runtime.messages().len - 1];
    try std.testing.expectEqual(p.Role.assistant, last.role);
    try std.testing.expectEqualStrings("assistant conjecture must not be captured", last.blocks[0].text);
    fake.refused = false;
    _ = try runtime.run("next normal task", &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.completes);
    try std.testing.expectEqualStrings("next normal task", fake.captured());
}
test "automatic Memory final-stop steering commits before capture and followup gets own task" {
    var box: r.Inbox = .{};
    defer box.deinit();
    var fake = Fake{ .box = &box, .steer = true };
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    _ = try box.enqueue(std.testing.allocator, .follow_up, "future followup fact");
    var cancel: p.Cancellation = .{};
    try std.testing.expectEqual(r.Status.success, (try runtime.run("original fact", &cancel)).status);
    try std.testing.expectEqualStrings("original factcommitted steering fact", fake.captured());
    try std.testing.expectEqual(@as(usize, 1), fake.completes);
    const lease = box.claimNext().?;
    var followup = box.commit(lease).?;
    defer followup.deinit();
    try std.testing.expectEqual(r.Status.success, (try runtime.run(followup.text, &cancel)).status);
    try std.testing.expectEqualStrings("future followup fact", fake.captured());
    try std.testing.expectEqual(@as(usize, 2), fake.completes);
}
test "automatic Memory fresh retrieval deduplicates latest reference but refreshes changes empty and unavailable" {
    var fake = Fake{};
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("one", &cancel);
    _ = try runtime.run("two", &cancel);
    try std.testing.expectEqual(@as(usize, 1), referenceCount(&runtime));
    fake.reference = "project facts B";
    _ = try runtime.run("three", &cancel);
    fake.reference = "project facts A";
    _ = try runtime.run("four", &cancel);
    try std.testing.expectEqual(@as(usize, 3), referenceCount(&runtime));
    fake.reference = "";
    _ = try runtime.run("five", &cancel);
    try std.testing.expect(std.mem.find(u8, lastReference(&runtime), "is empty") != null);
    fake.retrieval_error = true;
    _ = try runtime.run("six", &cancel);
    try std.testing.expect(std.mem.find(u8, lastReference(&runtime), "unavailable") != null);
    fake.retrieval_error = false;
    fake.invalid_return = true;
    _ = try runtime.run("seven", &cancel);
    try std.testing.expect(std.mem.find(u8, lastReference(&runtime), "invalid retrieval") != null);
    try std.testing.expectEqual(@as(usize, 7), fake.retrieves);
    try std.testing.expectEqual(@as(usize, 7), fake.completes);
}
test "automatic Memory validates input before retrieve and command compact never capture" {
    var fake = Fake{};
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("\xff", &cancel);
    _ = try runtime.run("   ", &cancel);
    _ = try runtime.executeCommand("!printf offline", &cancel);
    _ = try runtime.compactContext(&cancel);
    try std.testing.expectEqual(@as(usize, 0), fake.retrieves);
    try std.testing.expectEqual(@as(usize, 0), fake.completes);
}
test "automatic Memory retains a complete reference beyond the old retrieval budget" {
    const reference: [9000]u8 = @splat('x');
    var fake = Fake{ .reference = &reference };
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    runtime.estimator.per_mille = 2000;
    var cancel: p.Cancellation = .{};
    const terminal = try runtime.run("small user input", &cancel);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expect(std.mem.endsWith(u8, lastReference(&runtime), &reference));
    try std.testing.expectEqual(@as(usize, 1), fake.retrieves);
}
test "automatic Memory unsafe retrieval poisons Runtime before any primary request" {
    for ([_]anyerror{ error.CleanupFailed, error.UnsafeToContinue }) |failure| {
        var fake = Fake{ .retrieval_poison = failure };
        var config = configValue();
        var runtime = try fake.init(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        try std.testing.expectEqual(r.Status.failed, (try runtime.run("safe user input", &cancel)).status);
        try std.testing.expect(runtime.poisoned);
        fake.retrieval_poison = null;
        _ = try runtime.run("later task", &cancel);
        try std.testing.expectEqual(@as(usize, 0), fake.calls);
        try std.testing.expectEqual(@as(usize, 0), fake.completes);
        try std.testing.expectEqual(@as(usize, 1), fake.retrieves);
    }
}
test "automatic Memory reports actual context failure without replacing full reference with empty" {
    var fake = Fake{};
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    config.model.context_tokens = 2; // Smallest valid model: one input token of room.
    try std.testing.expectEqual(@as(usize, 1), @import("../core/context.zig").inputBudget(config));
    var cancel: p.Cancellation = .{};
    const first = try runtime.run("valid task", &cancel);
    try std.testing.expectEqual(r.Status.failed, first.status);
    try std.testing.expectEqual(@as(?anyerror, error.ContextTooLarge), first.detail);
    try std.testing.expectEqual(@as(usize, 1), fake.retrieves);
    try std.testing.expectEqual(@as(usize, 1), referenceCount(&runtime));
    try std.testing.expect(std.mem.endsWith(u8, lastReference(&runtime), fake.reference));
    const second = try runtime.run("second task", &cancel);
    try std.testing.expectEqual(r.Status.failed, second.status);
    try std.testing.expectEqual(@as(?anyerror, error.ContextTooLarge), second.detail);
    try std.testing.expectEqual(@as(usize, 2), fake.retrieves);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.completes);
}
test "automatic Memory restore consults current Store instead of trusting saved context" {
    var first = Fake{};
    var config = configValue();
    var runtime = try first.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("old task", &cancel);
    const state = try runtime.exportCheckpoint();
    var second = Fake{ .reference = "current Store B" };
    var restored = try second.init(&config);
    defer restored.deinit();
    try restored.restoreCheckpoint(state);
    try std.testing.expectEqual(@as(usize, 0), second.retrieves);
    _ = try restored.run("new task", &cancel);
    try std.testing.expectEqual(@as(usize, 1), second.retrieves);
    try std.testing.expect(std.mem.endsWith(u8, lastReference(&restored), "current Store B"));
    try std.testing.expectEqualStrings("new task", second.captured());
}
test "automatic Memory survives compaction arena replacement and reinserts reference after signed-prefix rewrite" {
    var fake = Fake{};
    var config = configValue();
    config.model.protocol = .anthropic;
    config.model.output_tokens = 8192;
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("old task", &cancel);
    const a = runtime.arena.allocator();
    const old_text: [40_000]u8 = @splat('x');
    try runtime.history.append(a, try p.textMessage(a, .user, &old_text));
    try runtime.history.append(a, try p.cloneMessage(a, .{
        .role = .assistant,
        .blocks = &.{ .{ .reasoning = "old signed thought" }, .{ .text = "old verified answer" } },
        .replay = .{ .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .anthropic }, .json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"old signed thought\",\"signature\":\"old\"},{\"type\":\"text\",\"text\":\"old verified answer\"}]}", .retain_turn = true },
    }));
    const old_arena = runtime.history.items.ptr;
    // Cross the internal compaction trigger while the summary request still
    // fits the declared model window; no manual input quota is involved.
    config.model.context_tokens = 20000;
    const terminal = try runtime.run("current durable fact", &cancel);
    try std.testing.expectEqual(@as(?anyerror, null), terminal.detail);
    try std.testing.expectEqual(r.Status.success, terminal.status);
    try std.testing.expect(fake.summaries > 0);
    try std.testing.expect(old_arena != runtime.history.items.ptr);
    try std.testing.expectEqualStrings("current durable fact", fake.captured());
    const before = referenceCount(&runtime);
    _ = try runtime.run("next durable fact", &cancel);
    try std.testing.expectEqual(before + 1, referenceCount(&runtime));
    try std.testing.expectEqual(@as(usize, 3), fake.completes);
    try std.testing.expect(std.mem.endsWith(u8, lastReference(&runtime), fake.reference));
}
test "automatic Memory tool-prefix rewrite retains actual usage observation" {
    var fake = Fake{};
    var config = configValue();
    var runtime = try fake.init(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    _ = try runtime.run("user input", &cancel);
    runtime.last_context_tokens = 1234;
    var prefix = try runtime.prepareToolPrefix();
    runtime.installToolPrefix(&prefix);
    try std.testing.expectEqual(@as(?u64, 1234), runtime.last_context_tokens);
    try std.testing.expectEqual(@as(usize, 1), fake.completes);
}
test "automatic Memory validates topic content and sensitive candidates" {
    const sources = [_]k.Evidence{.{ .id = 0, .kind = .user, .text = "Use focused offline tests" }};
    const material = k.Material{ .id = "offline", .created_ms = 1, .sources = &sources };
    var candidate = k.Candidate{ .category = .project, .topic = "testing", .content = "Use focused offline tests" };
    try k.validateCandidate(material, candidate);
    candidate.topic = "other-topic";
    try k.validateCandidate(material, candidate);
    candidate.category = .preferences;
    try k.validateCandidate(material, candidate);
    candidate.content = "Authorization: Bearer credential";
    try k.validateCandidate(material, candidate);
    candidate.content = "-----BEGIN PRIVATE KEY-----";
    try std.testing.expectError(error.InvalidMemoryCandidate, k.validateCandidate(material, candidate));
    candidate.content = "safe fact";
    try k.validateCandidate(material, candidate);
}
test "automatic Memory Capture keeps complete sources but omits invalid assistant and sensitive data with OOM safety" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = k.Capture{ .allocator = arena.allocator() };
    capture.add(.assistant, "conjecture");
    capture.add(.user, "read /home/user/.ssh/id_rsa");
    capture.add(.tool, "-----BEGIN PRIVATE KEY-----");
    capture.add(.tool, "\xff");
    capture.add(.tool, &@as([4097]u8, @splat('x')));
    capture.add(.user, "verified durable fact");
    try std.testing.expectEqual(@as(usize, 3), capture.sources.items.len);
    try std.testing.expectEqual(@as(usize, 3), capture.omitted_sources);
    try std.testing.expectEqualStrings("read /home/user/.ssh/id_rsa", capture.sources.items[0].text);
    try std.testing.expectEqualStrings(&@as([4097]u8, @splat('x')), capture.sources.items[1].text);
    try std.testing.expectEqualStrings("verified durable fact", capture.sources.items[2].text);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var oom = k.Capture{ .allocator = failing.allocator() };
    oom.add(.user, "fact");
    try std.testing.expect(oom.incomplete);
}
