fn freeRows(a: std.mem.Allocator, rendered: Rows) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}

const profiles = [_]cfg.Model{
    .{ .name = "login/Family/Proxy", .protocol = .chat, .context_tokens = 16384 },
    // Native protocol and unknown capacity stay selectable for proxy routing.
    .{ .name = "login/native/Judge", .protocol = .systemone, .context_tokens = 0 },
    .{ .name = "second/family/proxy", .protocol = .responses, .context_tokens = 16384 },
    .{ .name = "unlogged/private-model", .context_tokens = 16384 },
    .{ .name = "raw-only", .context_tokens = 16384 },
    .{ .name = "login/", .context_tokens = 16384 },
};

const logged = [_]Provider{.{ .name = "login" }};

fn allocationCase(a: std.mem.Allocator) !void {
    for ([_][]const u8{ "", "JUDGE", "missing" }) |query| {
        const rendered = try rows(a, .{ .selected = 1 }, &profiles, &logged, &.{"login/Family/Proxy"}, true, "10.0.0.1", 8080, query, 40, 7);
        defer freeRows(a, rendered);
    }
}
