test "capture retains sources beyond historical count and byte thresholds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.alloc(u8, 5000);
    @memset(source, 'x');
    var capture: Capture = .{ .allocator = a };
    for (0..30) |_| capture.add(.user, source);
    try std.testing.expect(!capture.incomplete);
    try std.testing.expectEqual(@as(usize, 30), capture.sources.items.len);
    try std.testing.expectEqual(@as(usize, 0), capture.omitted_sources);
    for (capture.sources.items, 0..) |entry, i| {
        try std.testing.expectEqual(i, entry.id);
        try std.testing.expectEqualStrings(source, entry.text);
    }
}
test "service filters borrowed candidates without mutation" {
    const Fake = struct {
        fn extract(_: *anyopaque, _: std.mem.Allocator, _: Material, _: *const p.Cancellation) ![]const Candidate {
            return &.{
                .{ .category = .project, .topic = "invalid slug", .content = "bad" },
                .{ .category = .project, .topic = "blank", .content = "   \t\r\n" },
                .{ .category = .project, .topic = "sk-abcdefghijklmnopqrstuvwxyz", .content = "ordinary content" },
                .{ .category = .project, .topic = "bearer-secret", .content = "Bearer abc.def" },
                .{ .category = .project, .topic = "config", .content = "Store configuration in .env; api_key is optional." },
                .{ .category = .project, .topic = "secret", .content = "password=secret" },
                .{ .category = .project, .topic = "config", .content = "duplicate" },
            };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var dummy: u8 = 0;
    const service: Service = .{ .context = &dummy, .extract_fn = Fake.extract };
    const material: Material = .{ .id = "test", .generation = 0, .created_ms = 1, .sources = &.{} };
    var cancel: p.Cancellation = .{};
    const items = try service.extract(arena.allocator(), material, &cancel);
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("sk-abcdefghijklmnopqrstuvwxyz", items[0].topic);
    try std.testing.expectEqualStrings("bearer-secret", items[1].topic);
    try std.testing.expectEqualStrings("config", items[2].topic);
    try std.testing.expectEqualStrings("secret", items[3].topic);
    var capture: Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, "Bearer abc.def");
    capture.add(.user, "ordinary source");
    try std.testing.expectEqual(@as(usize, 2), capture.sources.items.len);
    try std.testing.expectEqualStrings("Bearer abc.def", capture.sources.items[0].text);
    try std.testing.expectEqualStrings("ordinary source", capture.sources.items[1].text);
    try std.testing.expectEqual(@as(usize, 0), capture.omitted_sources);
    for ([_][]const u8{
        "Use Bearer authentication for HTTP requests",
        "token = nextToken()",
        "password: minimum 8 characters",
        "Use .env and api_key when configuring /.thin/",
        "Bearer abc.def",
        "ghp_abcdefghijklmnopqrstuvwxyz",
        "sk-abcdefghijklmnopqrstuvwxyz",
    }) |text| {
        try std.testing.expect(!sensitiveMaterial(text));
        try validateCandidate(material, .{ .category = .project, .topic = "ordinary", .content = text });
        capture.add(.user, text);
    }
    try std.testing.expectEqual(@as(usize, 9), capture.sources.items.len);
    try std.testing.expect(sensitiveMaterial("-----BEGIN PRIVATE KEY-----"));
    try std.testing.expect(sensitiveMaterial("-----BEGIN RSA PRIVATE KEY-----"));
    try std.testing.expect(!sensitiveMaterial("-----BEGIN CERTIFICATE-----\nPRIVATE KEY-----"));
}
