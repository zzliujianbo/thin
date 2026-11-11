test "resume codec v2 roundtrip allocation cleanup no credentials or identity binding" {
    try allocationRoundtrip(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationRoundtrip, .{});
    const a = std.testing.allocator;
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    _ = try inspect(a, bytes, "1123456789abcdef0123456789abcdef".*);
    const offset = std.mem.find(u8, bytes, "hello").?;
    bytes[offset] = 'j'; // Still valid JSON is loadable, not authenticated.
    _ = try inspect(a, bytes, test_id);
    for (0..bytes.len) |len| {
        if (inspect(a, bytes[0..len], test_id)) |_| return error.AcceptedTruncation else |_| {}
    }
}
test "resume codec bounded lengths malformed selection and payload reject without authentication" {
    const a = std.testing.allocator;
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    const trailing = try std.mem.concat(a, u8, &.{ bytes, "x" });
    defer a.free(trailing);
    try std.testing.expectError(error.InvalidResumeLength, inspect(a, trailing, test_id));
    for ([_]usize{ 9, 13 }) |offset| {
        const saved = bytes[offset..][0..4].*;
        @memset(bytes[offset..][0..4], 255);
        try std.testing.expectError(error.InvalidResumeLength, inspect(a, bytes, test_id));
        @memset(bytes[offset..][0..4], 0);
        try std.testing.expectError(error.InvalidResumeLength, inspect(a, bytes, test_id));
        @memcpy(bytes[offset..][0..4], &saved);
    }
    try std.testing.expectError(error.InvalidSessionID, inspect(a, bytes, @splat('/')));
    try std.testing.expectError(error.InvalidResumeSelection, parseSelection(a, "{\"x\":{}}"));
    try std.testing.expectError(error.InvalidResumeSelection, parseSelection(a, "{\"session\":\"\xff\"}"));
    if (encode(a, test_id, &s, "[]")) |bad| {
        a.free(bad);
        return error.AcceptedInvalidPayload;
    } else |_| {}
}
test "resume codec rejects v1 frames and corrupted current payload" {
    const a = std.testing.allocator;
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    bytes[8] = 1;
    try std.testing.expectError(error.InvalidResumeVersion, inspect(a, bytes, test_id));
    bytes[8] = 2;
    bytes[bytes.len - 1] = '!';
    if (inspect(a, bytes, test_id)) |_| return error.AcceptedInvalidJson else |_| {}
}
