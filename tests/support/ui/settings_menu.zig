fn freeRows(a: std.mem.Allocator, rendered: Rows) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}

fn proxyAllocationCase(a: std.mem.Allocator) !void {
    const rendered = try proxyRows(a, .{ .selected = 1 }, .{ .proxy_configured = true, .proxy_address = "::1", .proxy_port = 3128, .proxy_model_count = 3 }, 40, 3);
    defer freeRows(a, rendered);
}

fn allocationCase(a: std.mem.Allocator) !void {
    const rendered = try rows(a, .{ .selected = 5 }, .{}, 40, 10);
    defer freeRows(a, rendered);
}
