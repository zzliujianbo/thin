test "grouped subagent progress changes watch stamp" {
    const base: WatchStamp = .{ .sequence = 0, .revision = 0, .queue_revision = 0, .task = 0, .codex = .{} };
    var next = base;
    next.subagents.group_id = 1;
    next.subagents.total = 1;
    next.subagents.running = 1;
    next.subagents.latest_id = 1;
    try std.testing.expect(!base.eql(next));
}
