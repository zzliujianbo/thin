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

test "retrieval corpus preserves exact ranked output and ignores obsolete or corrupt records" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root);
    var repository = repo.Repository.init(&store);
    const core = try store.create(a, "core", "Always here.");
    a.free(core.content);

    const padding: [600]u8 = @splat('x');
    const record = "previewtoken\n<!-- thin-knowledge-v3 -->\n" ++
        "{\"schema\":3,\"source\":\"" ++ id ++ "\",\"created_ms\":1,\"category\":\"project\",\"topic\":\"fact\",\"content\":\"decoded NEEDLE\\nsecond line\"}";
    // Insert ties out of lexical order. The raw matches occur below the first
    // line; V3 matches must use decoded content, never the preview or JSON.
    const corpus = .{
        .{ "zulu", "Last\n" ++ padding ++ "\nbody-only needle" },
        .{ "project-fact", record },
        .{ "needle-guide", "Key-only match" },
        .{ "alpha", "First\nbody-only Needle" },
        .{ "hay", "hayneedle is not a word match" },
        .{ "legacy-one", "needle\n<!-- thin-knowledge-v1 -->\n" ++ padding ++ "\xff" },
        .{ "legacy-two", "needle\n<!-- thin-knowledge-v2 -->\n" ++ padding ++ "\xff" },
        .{ "project-broken", "needle\n<!-- thin-knowledge-v3 -->\n{bad json" },
    };
    inline for (corpus) |row| try tmp.dir.writeFile(io, .{ .sub_path = ".thin/memory/" ++ row[0] ++ ".md", .data = row[1] });

    const core_text = "[Untrusted current local reference: core]\nAlways here.\n";
    const ranked = try repository.retrieve(a, "needle");
    defer a.free(ranked);
    try std.testing.expectEqualStrings(core_text ++
        "[Untrusted current local reference: needle-guide]\nKey-only match\n" ++
        "[Untrusted current local reference: alpha]\nFirst\nbody-only Needle\n" ++
        "[Untrusted current local reference: project-fact]\ndecoded NEEDLE\nsecond line\n" ++
        "[Untrusted current local reference: zulu]\nLast\n" ++ padding ++ "\nbody-only needle\n", ranked);

    const only_core = try repository.retrieve(a, "previewtoken");
    defer a.free(only_core);
    try std.testing.expectEqualStrings(core_text, only_core);
    try store.remove("core");
    const no_hits = try repository.retrieve(a, "absent");
    defer a.free(no_hits);
    try std.testing.expectEqualStrings("", no_hits);

    // Only an early legacy marker exempts a shard from full text validation.
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/memory/late.md", .data = "Title\n" ++ padding ++ "\n<!-- thin-knowledge-v2 -->\n\xff" });
    try std.testing.expectError(error.InvalidUtf8, repository.retrieve(a, "absent"));
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
