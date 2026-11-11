const test_material: k.Material = .{ .id = "synthetic", .generation = 1, .created_ms = 100, .sources = &.{.{ .id = 0, .kind = .user, .text = "Use Zig for this project." }} };

const test_item = "{\"category\":\"project\",\"topic\":\"language\",\"content\":\"Zig is preferred.\"}";

fn codecCase(a: std.mem.Allocator) !void {
    const result = try parse(a, "{\"items\":[" ++ test_item ++ ",{}," ++ test_item ++ "]}");
    defer freeCandidates(a, result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("Zig is preferred.", result[0].content);
}
