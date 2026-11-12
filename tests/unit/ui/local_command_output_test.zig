test "local output is literal without stream success or encoding labels" {
    const a = std.testing.allocator;
    const out = try format(a, "{\"stdout\":\"**literal**\\n\\u001b[2J\\\\x1b\",\"stderr\":\"bad\",\"exit_code\":7,\"signal\":9,\"timed_out\":true,\"canceled\":true,\"cleanup_failed\":true,\"truncated\":true,\"output_encoding\":\"utf8\"}");
    defer a.free(out.text);
    for ([_][]const u8{ "**literal**", "bad", "Command exited with status 7", "Command terminated by signal 9", "Command timed out", "Command canceled", "Command cleanup failed", "[output truncated]", "\\x1b" }) |s| try std.testing.expect(std.mem.indexOf(u8, out.text, s) != null);
    for ([_][]const u8{ "stdout:", "stderr:", "exit:", "output encoding:" }) |s| try std.testing.expect(std.mem.indexOf(u8, out.text, s) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.text, 0x1b) == null);
}
test "local output fallback empty and unknown" {
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
}

test "large local output decodes complete streams and statuses" {
    const a = std.testing.allocator;
    const stdout = try a.alloc(u8, 140 * 1024);
    defer a.free(stdout);
    @memset(stdout, 'x');
    const json = try std.fmt.allocPrint(a, "{{\"stdout\":\"HEAD{s}TAIL\",\"stderr\":\"ERROR-END\",\"exit_code\":7}}", .{stdout});
    defer a.free(json);
    const out = try format(a, json);
    defer a.free(out.text);
    try std.testing.expect(std.mem.startsWith(u8, out.text, "HEAD"));
    try std.testing.expect(std.mem.endsWith(u8, out.text, "TAIL\nERROR-END\nCommand exited with status 7\n"));
    try std.testing.expectEqual(@as(usize, stdout.len + "HEADTAIL\nERROR-END\nCommand exited with status 7\n".len), out.text.len);
}

test "large malformed output remains fully sanitized literal" {
    const a = std.testing.allocator;
    const input = try a.alloc(u8, 140 * 1024 + 5);
    defer a.free(input);
    @memset(input, 'x');
    @memcpy(input[input.len - 5 ..], "\xff\x1b\r\nZ");
    const out = try format(a, input);
    defer a.free(out.text);
    try std.testing.expectEqual(@as(usize, 140 * 1024 + 8), out.text.len);
    try std.testing.expect(std.mem.endsWith(u8, out.text, "��\nZ"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.text));
    try std.testing.expect(std.mem.indexOfScalar(u8, out.text, 0x1b) == null);
}
test "local output propagates allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const out = try format(a, "{\"stdout\":\"hello\\nworld\",\"exit_code\":7}");
            defer a.free(out.text);
        }
    }.run, .{});
}
