fn fixtureSnapshot() !Snapshot {
    return capture(.{ .provider = .{ .base_url = "https://opencode.ai/zen/go/v1" }, .model = .{ .name = "gpt-5.6-luna", .protocol = .responses, .context_tokens = 1050000, .reasoning_effort = "high" } });
}
