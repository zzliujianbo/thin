fn allocationScenario(a: Allocator) !void {
    var h: History = .{};
    defer h.deinit(a);
    h.commit(a, try h.prepare(a, "first"));
    h.index = 0;
    const prepared = h.prepare(a, "second") catch |err| {
        try std.testing.expectEqualStrings("first", h.entries.items[0]);
        try std.testing.expectEqual(@as(?usize, 0), h.index);
        return err;
    };
    h.commit(a, prepared);
}
