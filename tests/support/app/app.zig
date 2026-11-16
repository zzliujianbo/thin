fn expectSessionTitleSchema(app: *const App, expected: usize) !void {
    var count: usize = 0;
    for (app.runtime.executor.schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "set_session_title")) count += 1;
    }
    try std.testing.expectEqual(expected, count);
}
