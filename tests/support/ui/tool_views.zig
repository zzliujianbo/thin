fn view(generation: u64, index: usize, label: []const u8, ready: bool) r.ToolView {
    return .{
        .key = key(generation, index),
        .name = "read_file",
        .fields = .{ .path = .{ .text = label } },
        .ready = ready,
    };
}

fn subagentProgressAllocationScenario(a: Allocator) !void {
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 7);
    var event: r.ToolView = .{ .key = key(7, 1), .name = "get_subagent_result", .fields = .{ .id = .{ .text = "subagent_1" } }, .ready = true };
    try views.upsert(a, event);
    const old = views.get(event.key).?.caption.label;
    event.subagent_progress = "working";
    views.upsert(a, event) catch |err| {
        try std.testing.expect(views.get(event.key).?.caption.label.ptr == old.ptr);
        try std.testing.expectEqualStrings("subagent_1", views.get(event.key).?.caption.label);
        return err;
    };
}

fn allocationScenario(a: Allocator) !void {
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 1);
    views.upsert(a, view(1, 0, "old", false)) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), views.entries.items.len);
        try std.testing.expectEqual(@as(usize, 0), views.ready_count);
        return err;
    };
    const label_before = views.get(key(1, 0)).?.caption.label;
    views.upsert(a, view(1, 0, "ready", true)) catch |err| {
        const old = views.get(key(1, 0)).?;
        try std.testing.expect(!old.ready);
        try std.testing.expect(old.caption.label.ptr == label_before.ptr);
        try std.testing.expectEqualStrings("old", old.caption.label);
        try std.testing.expectEqual(@as(usize, 0), views.ready_count);
        return err;
    };
    views.upsert(a, view(1, 1, "second", true)) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), views.entries.items.len);
        try std.testing.expectEqual(@as(usize, 1), views.ready_count);
        try std.testing.expectEqualStrings("ready", views.get(key(1, 0)).?.caption.label);
        return err;
    };
    const clone = (views.cloneReadyCaption(a, key(1, 0)) catch |err| {
        try std.testing.expectEqualStrings("ready", views.get(key(1, 0)).?.caption.label);
        try std.testing.expectEqual(@as(usize, 2), views.ready_count);
        return err;
    }).?;
    defer clone.deinit(a);
    try std.testing.expect(clone.label.ptr != views.get(key(1, 0)).?.caption.label.ptr);
    views.clear(a);
    try std.testing.expectEqualStrings("ready", clone.label);
}

fn growthScenario(a: Allocator) !void {
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 5);
    try views.upsert(a, view(5, 0, "first", true));
    const initial_capacity = views.entries.capacity;
    try std.testing.expect(initial_capacity < limit);
    for (1..initial_capacity) |i| try views.upsert(a, view(5, i, "existing", true));
    const label_before = views.entries.items[0].caption.label;
    views.upsert(a, view(5, initial_capacity, "growing", true)) catch |err| {
        try std.testing.expectEqual(initial_capacity, views.entries.items.len);
        try std.testing.expectEqual(initial_capacity, views.ready_count);
        try std.testing.expect(label_before.ptr == views.entries.items[0].caption.label.ptr);
        try std.testing.expectEqualStrings("first", views.entries.items[0].caption.label);
        return err;
    };
    try std.testing.expectEqual(initial_capacity + 1, views.ready_count);
}
