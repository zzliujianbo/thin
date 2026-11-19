test "retrieval includes core and V3 matches but ignores unrelated raw files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root);
    _ = try store.replace(a, "core", "CORE 中文");
    var repository = repo.Repository.init(&store);
    const record = try std.fmt.allocPrint(a, "project: compiler\n\n<!-- thin-knowledge-v3 -->\n{{\"schema\":3,\"source\":\"{s}\",\"created_ms\":1,\"category\":\"project\",\"topic\":\"compiler\",\"content\":\"rust 中文编译器\"}}\n", .{id});
    _ = try store.replace(a, "project-compiler", record);
    const binary = "other\nvalid unrelated content";
    for (0..20) |i| {
        const key = try std.fmt.allocPrint(a, ".thin/memory/unused-{d}.md", .{i});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = key, .data = binary });
    }
    const text = try repository.retrieve(a, "请使用中文编译工具");
    try std.testing.expect(std.mem.startsWith(u8, text, "[Untrusted current local reference: core]"));
    try std.testing.expect(std.mem.find(u8, text, "rust 中文编译器") != null);
    try std.testing.expect(std.mem.find(u8, text, "unused-") == null);
    try std.testing.expect(std.mem.find(u8, try repository.retrieve(a, "unrelated"), "CORE 中文") != null);
    const matching = try repository.retrieve(a, "中文");
    try std.testing.expect(std.mem.find(u8, matching, "rust 中文编译器") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(matching));
}

test "long preview before a V3 marker remains retrievable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root);
    var repository = repo.Repository.init(&store);
    const prefix = try a.alloc(u8, 600);
    @memset(prefix, 'x');
    const record = try std.fmt.allocPrint(a, "{s}\n<!-- thin-knowledge-v3 -->\n{{\"schema\":3,\"source\":\"{s}\",\"created_ms\":1,\"category\":\"project\",\"topic\":\"late\",\"content\":\"unique searchable fact\"}}\n", .{ prefix, id });
    _ = try store.replace(a, "project-late", record);
    const text = try repository.retrieve(a, "unique searchable");
    try std.testing.expect(std.mem.find(u8, text, "unique searchable fact") != null);
    const content = try repository.readContent(a, "project-late");
    defer a.free(content);
    try std.testing.expectEqualStrings("unique searchable fact", content);
}
