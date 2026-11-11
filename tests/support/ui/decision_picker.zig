fn freeRows(a: std.mem.Allocator, rendered: Rows) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}

const profiles = [_]cfg.Model{
    .{ .name = "login/Family/Judge", .protocol = .chat, .context_tokens = 16384 },
    .{ .name = "second/family/judge", .protocol = .responses, .context_tokens = 16384 },
    .{ .name = "raw-only", .context_tokens = 16384 },
    .{ .name = "login/", .context_tokens = 16384 },
};

const logged = [_]Provider{.{ .name = "login" }};

fn allocationCase(a: std.mem.Allocator) !void {
    for ([_][]const u8{ "", "JUDGE", "missing" }) |query| {
        const rendered = try rows(a, .{ .selected = 1 }, &profiles, &logged, query, 40, 7);
        defer freeRows(a, rendered);
    }
}
