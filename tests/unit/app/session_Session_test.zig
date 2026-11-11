test "memory view identity revision and clear change only once" {
    var session: Session = undefined;
    session.last_subagent_view = .{};
    session.last_memory_view = .{};
    const first: @import("../core/memory_status.zig").View = .{ .enabled = true, .revision = 1, .active = .{ .id = 1, .phase = .extracting } };
    var next = first;
    try std.testing.expect(!session.memoryViewChanged(.{}));
    try std.testing.expect(session.memoryViewChanged(first));
    try std.testing.expect(!session.memoryViewChanged(first));
    next.active.?.id = 2;
    try std.testing.expect(session.memoryViewChanged(next));
    next.revision = 2;
    try std.testing.expect(session.memoryViewChanged(next));
    try std.testing.expect(session.memoryViewChanged(.{}));
    try std.testing.expect(!session.memoryViewChanged(.{}));
}
test "memory notice dirty survives busy metadata and cadence early returns" {
    // Minimal owner fixture: these paths must not touch App/Runtime or I/O.
    var session: Session = undefined;
    session.allocator = std.testing.allocator;
    session.last_subagent_view = .{};
    defer session.last_subagent_view.deinitOwned(session.allocator);
    session.app = null;
    session.owner_task_active = false;
    session.initial_default_pending = false;
    session.codex_job = null;
    session.codex_view = .{};
    session.codex_reported = .{};
    var job: MetadataJob = undefined;
    job.future = null;
    job.dev_future = null;
    session.metadata_job = &job;
    session.last_memory_view = .{ .enabled = true, .active = .{ .id = 1, .phase = .extracting } };
    try std.testing.expect(pollModels(&session, false));
    try std.testing.expect(!pollModels(&session, false));
    session.metadata_job = null;
    session.metadata_login_pending = 0;
    session.metadata_auto = true;
    session.metadata_blocked = false;
    session.metadata_awake_ms = 1;
    session.metadata_next_check_ms = 100;
    session.last_memory_view = .{ .enabled = true, .active = .{ .id = 1, .phase = .extracting } };
    try std.testing.expect(pollModels(&session, true));
    try std.testing.expect(!pollModels(&session, true));
}
