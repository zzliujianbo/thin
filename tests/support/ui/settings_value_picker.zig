fn freeRows(a: std.mem.Allocator, rendered: Rows) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}

fn allocationCase(a: std.mem.Allocator) !void {
    var picker = Picker.init(.request_timeout_ms, 12345, .{});
    picker.beginCustom();
    try std.testing.expect(picker.append("67.890"));
    const rendered = try rows(a, .{ .selected = picker.count() - 1 }, picker, 40, 12);
    defer freeRows(a, rendered);
}
