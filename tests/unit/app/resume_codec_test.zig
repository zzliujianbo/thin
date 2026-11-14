test "resume codec v3 roundtrip allocation cleanup no credentials or identity binding" {
    try allocationRoundtrip(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationRoundtrip, .{});
    const a = std.testing.allocator;
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    const unchecked = try encodeUnchecked(a, test_id, &s, payload);
    defer a.free(unchecked);
    try std.testing.expectEqualStrings(bytes, unchecked);
    try std.testing.expectEqual(@as(u8, 3), bytes[8]);
    try std.testing.expectEqual(@as(u64, @intCast(payload.len)), std.mem.readInt(u64, bytes[13..21], .little));
    const selection_len = std.mem.readInt(u32, bytes[9..13], .little);
    try std.testing.expectEqual(21 + @as(usize, selection_len) + payload.len, bytes.len);
    _ = try inspect(a, bytes, "1123456789abcdef0123456789abcdef".*);
    const offset = std.mem.find(u8, bytes, "hello").?;
    bytes[offset] = 'j'; // Still valid JSON is loadable, not authenticated.
    _ = try inspect(a, bytes, test_id);
    for (0..bytes.len) |len| {
        if (inspect(a, bytes[0..len], test_id)) |_| return error.AcceptedTruncation else |_| {}
    }
}
test "resume codec checked u64 lengths malformed selection and payload reject without authentication" {
    const a = std.testing.allocator;
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    const trailing = try std.mem.concat(a, u8, &.{ bytes, "x" });
    defer a.free(trailing);
    try std.testing.expectError(error.InvalidResumeLength, inspect(a, trailing, test_id));
    inline for (.{ .{ 9, 4 }, .{ 13, 8 } }) |field| {
        const saved = bytes[field[0]..][0..field[1]].*;
        @memset(bytes[field[0]..][0..field[1]], 255);
        try std.testing.expectError(error.InvalidResumeLength, inspect(a, bytes, test_id));
        @memset(bytes[field[0]..][0..field[1]], 0);
        try std.testing.expectError(error.InvalidResumeLength, inspect(a, bytes, test_id));
        @memcpy(bytes[field[0]..][0..field[1]], &saved);
    }
    // A high u64 byte must not be ignored as if this were a v2 u32 frame.
    bytes[17] = 1;
    try std.testing.expectError(error.InvalidResumeLength, inspect(a, bytes, test_id));
    bytes[17] = 0;
    try std.testing.expectError(error.InvalidSessionID, inspect(a, bytes, @splat('/')));
    try std.testing.expectError(error.InvalidResumeSelection, parseSelection(a, "{\"x\":{}}"));
    try std.testing.expectError(error.InvalidResumeSelection, parseSelection(a, "{\"session\":\"\xff\"}"));
    if (encode(a, test_id, &s, "[]")) |bad| {
        a.free(bad);
        return error.AcceptedInvalidPayload;
    } else |_| {}
}
test "resume codec v3 keeps a payload beyond the old 16 MiB quota" {
    const a = std.testing.allocator;
    const system = try a.alloc(u8, 16 * 1024 * 1024 + 1);
    defer a.free(system);
    @memset(system, 'x');
    const payload = try checkpoint.encode(a, .{ .system = system, .messages = &.{}, .selector = .{ .configured = .auto, .selected = null }, .estimator = .{}, .last_context_tokens = null, .permission_id = 0 });
    defer a.free(payload);
    const selection = fixture();
    const bytes = try encode(a, test_id, &selection, payload);
    defer a.free(bytes);
    const envelope = try inspect(a, bytes, test_id);
    try std.testing.expectEqualStrings(payload, envelope.payload);
    try std.testing.expectEqual(@as(u64, @intCast(payload.len)), std.mem.readInt(u64, bytes[13..21], .little));
}
test "resume codec reads existing v2 frames" {
    const a = std.testing.allocator;
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const current = try encode(a, test_id, &s, payload);
    defer a.free(current);
    const old = try a.alloc(u8, current.len - 4);
    defer a.free(old);
    @memcpy(old[0..13], current[0..13]);
    old[8] = 2;
    std.mem.writeInt(u32, old[13..17], @intCast(payload.len), .little);
    @memcpy(old[17..], current[21..]);
    const loaded = try inspect(a, old, test_id);
    try std.testing.expectEqualStrings(payload, loaded.payload);
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
    bytes[8] = 3;
    bytes[bytes.len - 1] = '!';
    if (inspect(a, bytes, test_id)) |_| return error.AcceptedInvalidJson else |_| {}
}
