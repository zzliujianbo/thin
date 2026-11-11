fn testProjection(busy: bool, model: []const u8) !*Client.Projection {
    const a = std.testing.allocator;
    const projection = try a.create(Client.Projection);
    projection.* = .{ .a = a, .arena = .init(a), .state = .{ .runtime = null, .available = true, .busy = busy, .model = model, .base_url = "" }, .snapshot = .{ .available = true, .attached = true, .busy = busy, .control_epoch = 7 } };
    return projection;
}
