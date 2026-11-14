test "codec filters invalid items and preserves allocation rollback" {
    try codecCase(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, codecCase, .{});
    const empty = try parse(std.testing.allocator, "{\"items\":[],\"note\":\"metadata\"}");
    defer freeCandidates(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.InvalidMemoryOutput, parse(std.testing.allocator, "{\"items\":[],\"items\":[]}"));
}
test "codec strict outer syntax bounds and per-item validation" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "{\"items\":[],\"items\":[]}", "{\"items\":[],\"it\\u0065ms\":[]}", "{\"items\":[[[[[]]]]]}", "{\"items\":[]}\xff", "{\"items\":{}}", "{\"note\":0}", "[]" }) |bad| {
        try std.testing.expectError(error.InvalidMemoryOutput, parse(a, bad));
    }
    const mixed = "{\"items\":[{\"category\":\"project\",\"topic\":\"blank\",\"content\":\"   \\t\\r\\n\"}," ++ test_item ++ ",{\"category\":\"project\",\"topic\":\"bad\",\"content\":\"password=secret\"}]}";
    const filtered = try parse(a, mixed);
    defer freeCandidates(a, filtered);
    try std.testing.expectEqual(@as(usize, 3), filtered.len);
    const old_extra = try parse(a, "{\"items\":[{\"category\":\"project\",\"topic\":\"config\",\"content\":\"Use .env for api_key configuration\",\"source_id\":0,\"quote\":\"not verbatim\"}]}");
    defer freeCandidates(a, old_extra);
    try std.testing.expectEqual(@as(usize, 1), old_extra.len);
    const many = "{\"items\":[" ++ test_item ++ "," ++ test_item ++ "," ++ test_item ++ "," ++ test_item ++ "," ++ test_item ++ "," ++ test_item ++ "," ++ test_item ++ "," ++ test_item ++ "," ++ test_item ++ "]}";
    const many_items = try parse(a, many);
    defer freeCandidates(a, many_items);
    try std.testing.expectEqual(@as(usize, 9), many_items.len);
    const padding = try a.alloc(u8, 33000);
    defer a.free(padding);
    @memset(padding, ' ');
    const large = try std.fmt.allocPrint(a, "{s}{{\"items\":[{s}]}}", .{ padding, test_item });
    defer a.free(large);
    const items = try parse(a, large);
    defer freeCandidates(a, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
}
test "service filters decoded semantic failures and retains later valid items" {
    const Fake = struct {
        fn extract(_: *anyopaque, a: std.mem.Allocator, _: k.Material, _: *const @import("protocol.zig").Cancellation) ![]const k.Candidate {
            return parse(a, "{\"items\":[" ++
                "{\"category\":\"project\",\"topic\":\"bad slug\",\"content\":\"x\"}," ++
                "{\"category\":\"project\",\"topic\":\"blank\",\"content\":\"   \"}," ++
                "{\"category\":\"project\",\"topic\":\"secret\",\"content\":\"-----BEGIN PRIVATE KEY-----\"}," ++
                test_item ++ "," ++ test_item ++ ",{}]}");
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dummy: u8 = 0;
    var cancel: @import("protocol.zig").Cancellation = .{};
    const service: k.Service = .{ .context = &dummy, .extract_fn = Fake.extract };
    const filtered = try service.extract(arena.allocator(), test_material, &cancel);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqualStrings("language", filtered[0].topic);
}
test "codec ignores legacy version and expiry fields" {
    const a = std.testing.allocator;
    const v = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const text = "{\"items\":[{\"category\":\"project\",\"topic\":\"language\",\"content\":\"Zig\",\"expected_version\":\"" ++ v ++ "\",\"expires_at_ms\":101}]}";
    const accepted = try parse(a, text);
    defer freeCandidates(a, accepted);
    try std.testing.expectEqual(@as(usize, 1), accepted.len);
    try std.testing.expectEqualStrings("language", accepted[0].topic);
    try std.testing.expectEqualStrings("Zig", accepted[0].content);
}
