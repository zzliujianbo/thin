test "per-agent status rows own cloned values" {
    var agents = [_]AgentView{.{ .id = 3, .phase = .running }};
    const borrowed: View = .{ .agents = &agents };
    var owned = try borrowed.clone(std.testing.allocator);
    defer owned.deinitOwned(std.testing.allocator);
    try std.testing.expect(View.eql(borrowed, owned));
    agents[0].phase = .failed;
    try std.testing.expect(!View.eql(borrowed, owned));
    try std.testing.expect(owned.agents[0].active());
}
