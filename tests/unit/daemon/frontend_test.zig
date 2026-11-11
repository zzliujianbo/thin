test "synchronous codex login requires async action" {
    var context: u8 = 0;
    try std.testing.expectError(error.AsyncRequired, Frontend.noCodexLogin(&context, .start, 1));
}
test "pending codex code publication wakes once" {
    var frontend: Frontend = .{ .a = std.testing.allocator, .communication = undefined, .view = try testProjection(false, "model"), .revision = 10 };
    defer frontend.view.deinit();
    defer if (frontend.retired) |retired| retired.deinit();
    frontend.view.state.codex_login = .{ .generation = 3, .status = .pending };
    const pending = try testProjection(false, "model");
    pending.state.codex_login = .{ .generation = 3, .status = .pending, .code_len = 4 };
    @memcpy(pending.state.codex_login.code[0..4], "ABCD");
    frontend.adopt(.{ .generation = 1, .revision = 11, .watermark = 0, .ordered = false, .projection = pending });
    try std.testing.expect(Frontend.metadataOwned(&frontend, false));
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
}
test "identical and stale codex views do not wake" {
    var frontend: Frontend = .{ .a = std.testing.allocator, .communication = undefined, .view = try testProjection(false, "model"), .revision = 10 };
    defer frontend.view.deinit();
    defer if (frontend.retired) |retired| retired.deinit();
    frontend.view.state.codex_login = .{ .generation = 3, .status = .pending, .code_len = 4 };
    @memcpy(frontend.view.state.codex_login.code[0..4], "ABCD");
    const same = try testProjection(false, "model");
    same.state.codex_login = frontend.view.state.codex_login;
    same.state.codex_login.code[5] = 42; // Unused array padding is not presentation.
    frontend.adopt(.{ .generation = 1, .revision = 11, .watermark = 0, .ordered = false, .projection = same });
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
    const stale = try testProjection(false, "model");
    stale.state.codex_login = .{ .generation = 2, .status = .failed, .failure = .denied };
    frontend.adopt(.{ .generation = 1, .revision = 10, .watermark = 0, .ordered = false, .projection = stale });
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
    try std.testing.expectEqualStrings("ABCD", frontend.view.state.codex_login.userCode());
}
test "per-agent status rows wake frontend once" {
    const Agent = @import("../core/subagent_status.zig").AgentView;
    const first_rows = [_]Agent{.{ .id = 1, .phase = .running, .elapsed_ms = 1 }};
    const next_rows = [_]Agent{.{ .id = 1, .phase = .running, .elapsed_ms = 2 }};
    var frontend: Frontend = .{ .a = std.testing.allocator, .communication = undefined, .view = try testProjection(false, "model"), .revision = 10 };
    defer frontend.view.deinit();
    defer if (frontend.retired) |retired| retired.deinit();
    frontend.view.state.subagents = .{ .agents = &first_rows };
    const changed = try testProjection(false, "model");
    changed.state.subagents = .{ .agents = &next_rows };
    frontend.adopt(.{ .generation = 1, .revision = 11, .watermark = 0, .ordered = false, .projection = changed });
    try std.testing.expect(Frontend.metadataOwned(&frontend, false));
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
}
test "grouped subagent progress publication wakes once" {
    var frontend: Frontend = .{ .a = std.testing.allocator, .communication = undefined, .view = try testProjection(false, "model"), .revision = 10 };
    defer frontend.view.deinit();
    defer if (frontend.retired) |retired| retired.deinit();
    const changed = try testProjection(false, "model");
    changed.state.subagents_supported = true;
    changed.state.subagents = .{ .group_id = 7, .revision = 1, .total = 1, .running = 1, .latest_id = 1 };
    frontend.adopt(.{ .generation = 1, .revision = 11, .watermark = 0, .ordered = false, .projection = changed });
    try std.testing.expect(Frontend.metadataOwned(&frontend, false));
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
    const same = try testProjection(false, "model");
    same.state.subagents_supported = true;
    same.state.subagents = frontend.view.state.subagents;
    frontend.adopt(.{ .generation = 1, .revision = 12, .watermark = 0, .ordered = false, .projection = same });
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
    const progress = try testProjection(false, "model");
    progress.state.subagents_supported = true;
    progress.state.subagents = frontend.view.state.subagents;
    progress.state.subagents.revision += 1;
    frontend.adopt(.{ .generation = 1, .revision = 13, .watermark = 0, .ordered = false, .projection = progress });
    try std.testing.expect(Frontend.metadataOwned(&frontend, false));
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
}
test "configuration-only publications notify the UI once without polling the owner" {
    var frontend: Frontend = .{ .a = std.testing.allocator, .communication = undefined, .view = try testProjection(false, "old"), .revision = 10 };
    defer frontend.view.deinit();
    defer if (frontend.retired) |retired| retired.deinit();
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
    const changed = try testProjection(false, "new");
    changed.configuration_revision = 1;
    frontend.adopt(.{ .generation = 1, .revision = 11, .watermark = 0, .ordered = false, .projection = changed });
    try std.testing.expectEqualStrings("new", Frontend.current(&frontend).model);
    try std.testing.expect(Frontend.metadataOwned(&frontend, false));
    try std.testing.expect(!Frontend.metadataOwned(&frontend, true));
    frontend.adopt(.{ .generation = 1, .revision = 9, .watermark = 0, .ordered = false, .projection = try testProjection(false, "stale") });
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
    try std.testing.expectEqualStrings("new", Frontend.current(&frontend).model);
    const activity_only = try testProjection(true, "new");
    activity_only.configuration_revision = 1;
    frontend.adopt(.{ .generation = 1, .revision = 12, .watermark = 1, .ordered = true, .projection = activity_only });
    try std.testing.expect(frontend.view.snapshot.busy);
    try std.testing.expect(!Frontend.metadataOwned(&frontend, false));
}
test "newer control settings cannot erase an ordered idle acknowledgement" {
    var frontend: Frontend = .{ .a = std.testing.allocator, .communication = undefined, .view = try testProjection(true, "old-settings"), .generation = 2, .revision = 10 };
    defer frontend.view.deinit();
    defer if (frontend.retired) |retired| retired.deinit();
    frontend.adopt(.{ .generation = 2, .revision = 12, .watermark = 20, .ordered = false, .projection = try testProjection(false, "new-settings") });
    try std.testing.expect(frontend.view.snapshot.busy);
    // Older task's idle must not settle the accepted task at watermark 20.
    frontend.adopt(.{ .generation = 2, .revision = 11, .watermark = 19, .ordered = true, .projection = try testProjection(false, "stale-settings") });
    try std.testing.expect(frontend.view.snapshot.busy);
    // This reaches the consumer only after its preceding terminal event. Even
    // though settings overtook its revision, idle must still be acknowledged.
    frontend.adopt(.{ .generation = 2, .revision = 11, .watermark = 20, .ordered = true, .projection = try testProjection(false, "stale-settings") });
    try std.testing.expect(!frontend.view.snapshot.busy);
    try std.testing.expect(!frontend.view.state.busy);
    try std.testing.expectEqualStrings("new-settings", frontend.view.state.model);
    frontend.adopt(.{ .generation = 1, .revision = 100, .watermark = 100, .ordered = true, .projection = try testProjection(true, "old-session") });
    try std.testing.expectEqual(@as(u64, 2), frontend.generation);
    try std.testing.expect(!frontend.view.snapshot.busy);
}
