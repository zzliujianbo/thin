fn makeConfig(a: std.mem.Allocator, url: []const u8, key: []const u8, payload: []const u8, timeout_ms: u32) ![]u8 {
    return makeConfigRouted(a, url, key, payload, timeout_ms, false, null);
}

fn largeConfigCase(a: std.mem.Allocator, payload: []const u8, stream: bool) !void {
    const url = "https://example.invalid/api";
    const headers = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer fake" }};
    const config = if (stream)
        try makeStreamConfig(a, url, &headers, payload, 1250, 1024, true, null)
    else
        try makeConfigRouted(a, url, "fake", payload, 1250, true, null);
    defer wipeFree(a, config);
    // config.len is the whole allocation, not just the prefix sent to curl.
    try std.testing.expect(config.len >= payload.len and config.len <= payload.len + 2048);
    const end = std.mem.indexOfScalar(u8, config, 0) orelse return error.MissingConfigDelimiter;
    try std.testing.expect(end > payload.len);
    try std.testing.expect(std.mem.allEqual(u8, config[end..], 0));
}

fn fakeResult(bytes: []const u8) process.Result {
    return .{ .stdout = bytes, .stderr = "untrusted server diagnostics", .stdout_bytes = bytes.len, .stderr_bytes = 28, .truncated = false, .term = .{ .exited = 0 } };
}

fn allocationCase(a: std.mem.Allocator) !void {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "http://127.0.0.1:1");
    var client = try Client.init(a, std.testing.io, &env);
    defer client.deinit();
    const config = try makeConfig(a, "https://example.invalid/", "fake-\\\"key", "{\"text\":\"中文\\u4f60\"}", 11000);
    defer wipeFree(a, config);
    try std.testing.expect(std.mem.indexOf(u8, config, "connect-timeout = \"10.000\"") != null);
    const response = try parseResponse(a, fakeResult("{\"ok\":true}\n200"));
    defer response.deinit(a);
}

const StreamTestSink = struct {
    data: std.ArrayList(u8) = .empty,
    head: ?StreamHead = null,
    fn write(raw: *anyopaque, head: StreamHead, bytes: []const u8) !void {
        const self: *StreamTestSink = @ptrCast(@alignCast(raw));
        self.head = head;
        try self.data.appendSlice(std.testing.allocator, bytes);
    }
};

fn streamAllocationCase(a: std.mem.Allocator) !void {
    const headers = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer fake-\\\"key" }};
    const config = try makeStreamConfig(a, "https://origin.invalid/v1/messages", &headers, "{\"x\":\"中文\\n\"}", 11000, 1024, true, "http://127.0.0.1:7890");
    defer wipeFree(a, config);
    try std.testing.expect(std.mem.indexOf(u8, config, "proxy = \"http://127.0.0.1:7890\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "noproxy = \"\"") != null);
}
