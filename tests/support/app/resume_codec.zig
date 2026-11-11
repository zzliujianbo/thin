const test_id: ids.Id = "0123456789abcdef0123456789abcdef".*;

fn fixturePayload(a: std.mem.Allocator) ![]u8 {
    return checkpoint.encode(a, .{ .system = "hello", .messages = &.{}, .selector = .{ .configured = .auto, .selected = null }, .estimator = .{}, .last_context_tokens = null, .permission_id = 0 });
}

fn fixture() selections.Snapshot {
    var s: selections.Snapshot = .{ .endpoint = @splat('a'), .provider = null, .protocol = .responses, .effort = null };
    @memcpy(s.model_buffer[0..5], "model");
    s.model_len = 5;
    return s;
}

fn allocationRoundtrip(a: std.mem.Allocator) !void {
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    const envelope = try inspect(a, bytes, test_id);
    try std.testing.expectEqualStrings(payload, envelope.payload);
    try std.testing.expectEqualStrings(s.model(), envelope.selection.model());
}
