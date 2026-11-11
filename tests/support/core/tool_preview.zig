fn expectEmpty(e: *const Extractor) !void {
    const s = e.snapshot();
    try std.testing.expect(s.path == null and s.command == null and s.action == null and s.topic == null and s.task == null);
}

fn checkGolden(e: *const Extractor) !void {
    const s = e.snapshot();
    try std.testing.expectEqualStrings("目录/😀/\\\"\n", s.path.?.text);
    try std.testing.expectEqualStrings("echo hi", s.command.?.text);
    try std.testing.expectEqualStrings("", s.action.?.text);
    try std.testing.expectEqualStrings("中", s.topic.?.text);
    try std.testing.expect(!s.path.?.truncated);
}
