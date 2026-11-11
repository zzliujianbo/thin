const test_options: Options = .{ .base_url = "http://image.invalid/v1///", .api_key = "synthetic-image-key", .request_timeout_ms = 1000 };

fn creationCase(a: std.mem.Allocator) !void {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CURL_CA_BUNDLE", "/synthetic/ca.pem");
    try env.put("HTTPS_PROXY", "http://ambient.invalid:9999");
    var key: [8]u8 = @splat('k');
    var opts = test_options;
    opts.api_key = &key;
    opts.proxy_url = "http://owned.invalid:8080";
    const client = try Client.create(a, std.testing.io, &env, opts);
    defer client.deinit() catch unreachable;
    @memset(&key, 'x');
    try std.testing.expectEqualStrings("kkkkkkkk", client.key);
    try std.testing.expectEqualStrings("http://image.invalid/v1/chat/completions", client.endpoint);
    try std.testing.expectEqualStrings("http://owned.invalid:8080", client.transport.proxy_url.?);
    try std.testing.expect(client.transport.env.get("HTTPS_PROXY") == null);
    try std.testing.expectEqualStrings("/synthetic/ca.pem", client.transport.env.get("CURL_CA_BUNDLE").?);
    try std.testing.expect(!client.isPoisoned());
    try client.service().checkReady();
    var cancel: p.Cancellation = .{};
    cancel.cancel();
    const input: image.Input = .{ .image = .{ .data = "abc", .format = .png, .width = 1, .height = 1 } };
    try std.testing.expectError(error.Canceled, client.service().inspect(a, input, &cancel));
    client.transport.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, client.service().inspect(a, input, &cancel));
}
