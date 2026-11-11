test "lifecycle local batch starts independent generation without inference" {
    var f: Fixture = .{ .local = true };
    var config = configuration();
    var runtime = try f.runtime(&config);
    defer runtime.deinit();
    runtime.display_generation = 40;
    var cancel: p.Cancellation = .{};
    const result = try runtime.executeCommand("!echo fixture", &cancel);
    try t.expectEqual(r.Status.success, result.status);
    try t.expectEqual(@as(usize, 0), f.attempts);
    try t.expectEqual(@as(usize, 1), f.executions);
    try t.expectEqual(@as(u64, 41), f.keys[0].generation);
    try t.expectEqual(@as(u32, 0), result.usage.normal_calls);
}
test "lifecycle refuses streamed key reuse when canonical arguments differ" {
    var f: Fixture = .{};
    var config = configuration();
    var runtime = try f.runtime(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const result = try runtime.run("fixture", &cancel);
    try t.expectEqual(r.Status.success, result.status);
    try t.expectEqual(@as(usize, 2), f.executions);
    try t.expect(!f.keys[1].eql(f.streamed_key.?));
    try t.expect(!f.keys[0].eql(f.keys[1]));
    try t.expectEqual(@as(usize, 1), f.keys[1].index);
    try t.expectEqual(@as(usize, 2), f.begins);
}
test "lifecycle final-only prepare failure and deny keep keys without starts" {
    for (0..3) |scenario| {
        var f: Fixture = .{ .final_only = true, .prepare_error = scenario == 1, .deny = scenario == 2 };
        var config = configuration();
        var runtime = try f.runtime(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        try t.expectEqual(r.Status.success, (try runtime.run("fixture", &cancel)).status);
        try t.expectEqual(@as(usize, 2), f.results);
        try t.expect(!f.keys[0].eql(f.keys[1]));
        try t.expectEqual(@as(usize, if (scenario == 0) 2 else 0), f.started);
    }
}
test "lifecycle failed and canceled previews do not execute or commit" {
    for (0..3) |scenario| {
        var cancel: p.Cancellation = .{};
        var f: Fixture = .{ .fail = scenario == 0, .cancel_model = scenario == 1, .cancel_permission = if (scenario == 2) &cancel else null };
        var config = configuration();
        var runtime = try f.runtime(&config);
        defer runtime.deinit();
        const result = try runtime.run("fixture", &cancel);
        try t.expectEqual(if (scenario == 0) r.Status.failed else r.Status.canceled, result.status);
        try t.expectEqual(@as(usize, 0), f.executions);
        try t.expectEqual(@as(usize, if (scenario == 2) 1 else 0), f.commits);
    }
}
test "lifecycle fallback attempts get generations and display failure preserves original deltas" {
    var f: Fixture = .{ .fallback = true, .reject_preview = true };
    var config = configuration();
    config.model.protocol = .auto;
    var runtime = try f.runtime(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const result = try runtime.run("fixture", &cancel);
    try t.expectEqual(r.Status.success, result.status);
    try t.expectEqual(@as(usize, 3), f.begins);
    try t.expectEqual(@as(usize, 1), f.raw);
    try t.expectEqual(@as(u64, 2), f.keys[1].generation);
    try t.expectEqual(@as(u32, 3), result.usage.normal_calls);
}
