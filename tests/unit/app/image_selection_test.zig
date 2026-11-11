test "image selector accepts only exact Flash declarations and never changes primary" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"http://main.invalid/v1","models":{"chat":{"context_tokens":32768,"protocol":"chat"}}},"vision":{"base_url":"http://vision.invalid/v1","models":{"deepseek-flash":{"protocol":"anthropic"}}},"similar":{"base_url":"http://similar.invalid/v1","models":{"deepseek-v4-flash":{}}}}}}
    );
    defer cfg.release(&parsed);
    const cache = try a.create(metadata.Cache);
    defer a.destroy(cache);
    cache.* = .{};
    try std.testing.expect(available(parsed.value, cache, "vision"));
    try std.testing.expect(!available(parsed.value, cache, "similar"));
    try std.testing.expect(!available(parsed.value, cache, "main"));
    const before = parsed.value.provider.base_url;
    try std.testing.expect(try apply(parsed.arena.allocator(), &parsed.value, .{ .model = "vision/deepseek-flash" }));
    try std.testing.expect(parsed.value.imageActive());
    try std.testing.expectEqualStrings(before, parsed.value.provider.base_url);
    try std.testing.expectError(error.InvalidImageModel, apply(parsed.arena.allocator(), &parsed.value, .{ .model = "vision/deepseek-v4-flash" }));
    try std.testing.expect(try apply(parsed.arena.allocator(), &parsed.value, .off));
    try std.testing.expect(!parsed.value.imageActive());
    try std.testing.expect(parsed.value.image.model == null);
    try std.testing.expect(!try apply(parsed.arena.allocator(), &parsed.value, .off));
}
