fn rowsAllocationProbe(a: Allocator) !void {
    var picker = Picker.init(a);
    defer picker.deinit();
    const rendered = try picker.rowsWithProviders(a, "p/current", 100, &.{.{ .name = "p/other", .context_tokens = 200 }}, 24, 10, .{}, &.{}, &.{.{ .name = "p" }});
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
}
