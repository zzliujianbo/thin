test "image client zero-request creation owns route key CA and preserves poison" {
    try creationCase(std.testing.allocator);
}
test "image client construction failure releases owned allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, creationCase, .{});
}
test "image client owned allocations reach backing rawFree erased" {
    const Observer = struct {
        dirty: bool = false,
        frees: usize = 0,
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            for (bytes) |byte| if (byte != 0) {
                self.dirty = true;
                break;
            };
            self.frees += 1;
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var observer: Observer = .{};
    const a: std.mem.Allocator = .{ .ptr = &observer, .vtable = &.{ .alloc = Observer.alloc, .resize = Observer.resize, .remap = Observer.remap, .free = Observer.free } };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("CURL_CA_BUNDLE", "/synthetic/first.pem");
    const client = try Client.create(a, std.testing.io, &env, test_options);
    try env.put("CURL_CA_BUNDLE", "/synthetic/changed.pem");
    try std.testing.expectEqualStrings("/synthetic/first.pem", client.transport.env.get("CURL_CA_BUNDLE").?);
    try client.deinit();
    try std.testing.expect(observer.frees > 0);
    try std.testing.expect(!observer.dirty);
}
test "image client failed destruction explicitly retains a wiped retryable owner" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const client = try Client.create(std.testing.allocator, std.testing.io, &env, test_options);
    // Invalid sentinel exercises reapOwned's no-signal guard, not a real child.
    client.transport.unreaped_pid = 1;
    try std.testing.expectError(error.CleanupFailed, client.deinit());
    try std.testing.expect(client.isPoisoned());
    try std.testing.expectEqual(@as(?std.c.pid_t, 1), client.transport.unreaped_pid);
    try std.testing.expect(client.key.len == 0 and client.endpoint.len == 0);
    try std.testing.expectError(error.CleanupFailed, client.service().checkReady());
    client.transport.unreaped_pid = null; // Release only our injected sentinel.
    try client.deinit();
}
test "image client sink grows JSON and rechecks deadline cancel before spawn" {
    var cancel: p.Cancellation = .{};
    var sink: Sink = .{ .a = std.testing.allocator, .io = std.testing.io, .start = std.Io.Clock.awake.now(std.testing.io), .timeout_ms = 10000, .cancel = &cancel };
    defer sink.body.deinit(sink.a);
    try Sink.check(&sink);
    try Sink.write(&sink, .{ .status = 200, .is_sse = false }, "{\"a\":");
    try Sink.write(&sink, .{ .status = 200, .is_sse = false }, "1}");
    try std.testing.expectEqualStrings("{\"a\":1}", sink.body.items);
    try std.testing.expectError(error.ImageHttpResponse, Sink.write(&sink, .{ .status = 302, .is_sse = false }, "secret body"));
    try std.testing.expectError(error.ImageHttpResponse, Sink.write(&sink, .{ .status = 200, .is_sse = true }, "data: {}"));
    const large = try sink.a.alloc(u8, 65537);
    defer sink.a.free(large);
    @memset(large, 'x');
    try Sink.write(&sink, .{ .status = 200, .is_sse = false }, large);
    try std.testing.expectEqual(large.len + 7, sink.body.items.len);
    sink.timeout_ms = 0;
    try std.testing.expectError(error.Timeout, Sink.check(&sink));
    cancel.cancel();
    try std.testing.expectError(error.Canceled, Sink.check(&sink));
}
test "image client refuses bad selections before any request" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var options = test_options;
    options.model = "deepseek-flash-exp";
    try std.testing.expectError(error.InvalidImageModel, Client.create(a, std.testing.io, &env, options));
    options = test_options;
    options.api_key = "bad\nkey";
    try std.testing.expectError(error.InvalidApiKey, Client.create(a, std.testing.io, &env, options));
    options = test_options;
    options.base_url = "https://user:secret@image.invalid";
    try std.testing.expectError(error.InvalidUrl, Client.create(a, std.testing.io, &env, options));
    options = test_options;
    options.request_timeout_ms = 0;
    try std.testing.expectError(error.InvalidTimeout, Client.create(a, std.testing.io, &env, options));
}
