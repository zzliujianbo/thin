fn subagentEnvironmentAllocationCase(a: std.mem.Allocator, config: cfg.Config, source: *const std.process.Environ.Map) !void {
    var snapshot = try captureSubagentEnvironment(a, config, source);
    defer wipeSubagentEnvironment(&snapshot);
    try std.testing.expectEqual(@as(usize, 3), snapshot.count());
    try std.testing.expectEqualStrings("ca-original", snapshot.get("CURL_CA_BUNDLE").?);
    try std.testing.expectEqualStrings("active-original", snapshot.get("ACTIVE_KEY").?);
    try std.testing.expectEqualStrings("other-original", snapshot.get("OTHER_KEY").?);
    try std.testing.expect(snapshot.get("SECRET") == null);
    try std.testing.expect(snapshot.get("PATH") == null);
}

fn expectSessionTitleSchema(app: *const App, expected: usize) !void {
    var count: usize = 0;
    for (app.runtime.executor.schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "set_session_title")) count += 1;
    }
    try std.testing.expectEqual(expected, count);
}
