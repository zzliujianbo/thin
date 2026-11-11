test "local output is literal without stream success or encoding labels" {
    const a = std.testing.allocator;
    const out = try format(a, "{\"stdout\":\"**literal**\\n\\u001b[2J\\\\x1b\",\"stderr\":\"bad\",\"exit_code\":7,\"signal\":9,\"timed_out\":true,\"canceled\":true,\"cleanup_failed\":true,\"truncated\":true,\"output_encoding\":\"utf8\"}");
    defer a.free(out.text);
    for ([_][]const u8{ "**literal**", "bad", "Command exited with status 7", "Command terminated by signal 9", "Command timed out", "Command canceled", "Command cleanup failed", "[output truncated]", "\\x1b" }) |s| try std.testing.expect(std.mem.indexOf(u8, out.text, s) != null);
    for ([_][]const u8{ "stdout:", "stderr:", "exit:", "output encoding:" }) |s| try std.testing.expect(std.mem.indexOf(u8, out.text, s) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.text, 0x1b) == null);
}
test "local output fallback empty unknown and bounded" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "Denied", "", "{}", "{\"unknown\":{\"nested\":[]}}", "{\"stdout\":42}" }) |s| {
        const out = try format(a, s);
        defer a.free(out.text);
        try std.testing.expectEqualStrings(s, out.text);
    }
    const success = try format(a, "{\"stdout\":\"moved\\n\",\"stderr\":\"\",\"exit_code\":0,\"output_encoding\":\"utf8\"}");
    defer a.free(success.text);
    try std.testing.expectEqualStrings("moved\n", success.text);
    const empty = try format(a, "{\"stdout\":\"\",\"truncated\":true}");
    defer a.free(empty.text);
    try std.testing.expectEqualStrings("[output truncated]\n", empty.text);
    const large = try a.alloc(u8, limit + 1);
    defer a.free(large);
    @memset(large, 'x');
    const out = try format(a, large);
    defer a.free(out.text);
    try std.testing.expect(out.clipped and out.text.len <= limit);
}
test "local output propagates allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const out = try format(a, "{\"stdout\":\"hello\\nworld\",\"exit_code\":7}");
            defer a.free(out.text);
        }
    }.run, .{});
}
