test "V3 create unchanged baseline update skip and legacy ignore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, backend.io(), tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root);
    try std.testing.expectEqualStrings("", try store.coreSnapshot(a));
    try std.testing.expectEqual(@as(usize, 0), (try store.topics(a)).len);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));

    var repository = repo.Repository.init(&store);
    var material: knowledge.Material = .{ .id = id, .created_ms = 1, .sources = &.{.{ .id = 0, .kind = .user, .text = "中文 rust" }} };
    var candidate: knowledge.Candidate = .{ .category = .project, .topic = "language", .content = " 中文 rust " };
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, candidate));
    try std.testing.expectEqual(repo.Apply.unchanged, try repository.apply(a, material, candidate));

    // No baseline: an existing different fact is not overwritten.
    candidate.content = "rust updated";
    try std.testing.expectEqual(repo.Apply.skipped, try repository.apply(a, material, candidate));

    const related = try repository.related(a, "rust", 1);
    try std.testing.expectEqual(@as(usize, 1), related.len);
    try std.testing.expectEqualStrings("language", related[0].topic);
    try std.testing.expectEqualStrings("中文 rust", related[0].content);
    material.related = related;
    try std.testing.expectEqual(repo.Apply.updated, try repository.apply(a, material, candidate));

    // Same content under a different category is a separate record.
    candidate.category = .preferences;
    candidate.content = "prefer rust";
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, candidate));

    // A topic deleted after extraction is not resurrected.
    const removed_key = "project-removed";
    const removed = try repository.apply(a, material, .{ .category = .project, .topic = "removed", .content = "gone" });
    try std.testing.expectEqual(repo.Apply.created, removed);
    var removed_material = material;
    removed_material.related = try repository.related(a, "gone", 1);
    try store.remove(removed_key);
    try std.testing.expectEqual(repo.Apply.skipped, try repository.apply(a, removed_material, .{ .category = .project, .topic = "removed", .content = "resurrected" }));

    // Legacy v2 files are ignored by related/retrieve and are not auto-overwritten.
    const old = "project: language Zig old\n\n<!-- thin-knowledge-v2 -->\n{\"schema\":2,\"source\":\"" ++ id ++ "\",\"generation\":0,\"created_ms\":1,\"expires_at_ms\":null,\"category\":\"project\",\"topic\":\"legacy\",\"content\":\"Zig old\"}\n";
    _ = try store.replace(a, "project-legacy", old);
    try std.testing.expectEqual(@as(usize, 0), (try repository.related(a, "Zig", 1)).len);
    try std.testing.expectEqualStrings("", try repository.retrieve(a, "Zig", 1));
    for (try store.topics(a)) |topic| try std.testing.expect(!std.mem.eql(u8, topic, "project-legacy"));
    const page = try store.listPage(a, 0, 100);
    try std.testing.expect(std.mem.find(u8, page.text, "legacy") == null);
    try std.testing.expectEqual(repo.Apply.skipped, try repository.apply(a, material, .{ .category = .project, .topic = "legacy", .content = "Zig new" }));
}

test "related records preserve complete conditions without versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root);
    var repository = repo.Repository.init(&store);
    var material: knowledge.Material = .{ .id = id, .created_ms = 100, .sources = &.{.{ .id = 0, .kind = .user, .text = "Remember this durable condition." }} };
    const text = try a.alloc(u8, 4096);
    @memset(text, 'x');
    const head = "long condition ";
    const tail = " Required exception must remain complete.";
    @memcpy(text[0..head.len], head);
    @memcpy(text[text.len - tail.len ..], tail);
    for (0..8) |i| {
        text[head.len] = @as(u8, @intCast(i)) + '0';
        const topic = try std.fmt.allocPrint(a, "long-condition-{d}", .{i});
        try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, .{ .category = .project, .topic = topic, .content = text }));
    }
    const small = "long condition short rule with complete exception";
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, .{ .category = .project, .topic = "z-long-condition-small", .content = small }));
    material.related = try repository.related(a, "long condition", 100);
    var bytes: usize = 0;
    var large_count: usize = 0;
    var small_count: usize = 0;
    for (material.related) |entry| {
        bytes += entry.content.len + entry.topic.len;
        if (std.mem.eql(u8, entry.topic, "z-long-condition-small")) {
            small_count += 1;
            try std.testing.expectEqualStrings(small, entry.content);
        } else {
            large_count += 1;
            try std.testing.expectEqual(@as(usize, 4096), entry.content.len);
            try std.testing.expect(std.mem.startsWith(u8, entry.content, head));
            try std.testing.expectEqual(entry.topic[entry.topic.len - 1], entry.content[head.len]);
            try std.testing.expect(std.mem.endsWith(u8, entry.content, tail));
        }
    }
    try std.testing.expectEqual(@as(usize, 8), large_count);
    try std.testing.expectEqual(@as(usize, 1), small_count);
    try std.testing.expect(bytes > 8192);
    _ = try @import("../core/knowledge_codec.zig").encode(a, material);
}

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
    const material: knowledge.Material = .{ .id = id, .created_ms = 1, .sources = &.{.{ .id = 7, .kind = .tool, .text = "PRIVATE FULL SOURCE rust 中文" }} };
    const candidate: knowledge.Candidate = .{ .category = .project, .topic = "compiler", .content = "rust 中文编译器" };
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, candidate));
    const entry = try store.read(a, "project-compiler");
    try std.testing.expect(std.mem.find(u8, entry.content, "\"source_id\"") == null);
    try std.testing.expect(std.mem.find(u8, entry.content, "\"quote\"") == null);
    try std.testing.expect(std.mem.find(u8, entry.content, "PRIVATE FULL SOURCE") == null);
    const binary = "other\nvalid unrelated content";
    for (0..20) |i| {
        const key = try std.fmt.allocPrint(a, "unused-{d}", .{i});
        const name = try std.fmt.allocPrint(a, ".thin/memory/{s}.md", .{key});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = binary });
    }
    const text = try repository.retrieve(a, "请使用中文编译工具", 1);
    try std.testing.expect(std.mem.startsWith(u8, text, "[Untrusted current local reference: core]"));
    try std.testing.expect(std.mem.find(u8, text, "rust 中文编译器") != null);
    try std.testing.expect(std.mem.find(u8, text, "unused-") == null);
    try std.testing.expect(std.mem.find(u8, try repository.retrieve(a, "unrelated", 1), "CORE 中文") != null);
    const matching = try repository.retrieve(a, "中文", 1);
    try std.testing.expect(std.mem.find(u8, matching, "rust 中文编译器") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(matching));
}

test "apply updates only when the baseline still matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root);
    var repository = repo.Repository.init(&store);
    var material: knowledge.Material = .{ .id = id, .created_ms = 1, .sources = &.{.{ .id = 7, .kind = .tool, .text = "PRIVATE FULL SOURCE rust 中文" }} };
    var candidate: knowledge.Candidate = .{ .category = .project, .topic = "preflight", .content = "rust" };
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, candidate));
    material.related = try repository.related(a, "rust", 1);
    candidate.content = "new rust";
    try std.testing.expectEqual(repo.Apply.updated, try repository.apply(a, material, candidate));

    // A manual replacement after extraction wins; the old baseline cannot
    // overwrite it.
    const manual_text = "project: preflight manual edit\n<!-- thin-knowledge-v3 -->\n{\"schema\":3,\"source\":\"" ++ id ++ "\",\"created_ms\":1,\"category\":\"project\",\"topic\":\"preflight\",\"content\":\"manual edit\"}\n";
    _ = try store.replace(a, "project-preflight", manual_text);
    try std.testing.expectEqual(repo.Apply.skipped, try repository.apply(a, material, candidate));
    material.related = try repository.related(a, "manual", 1);
    try std.testing.expectEqual(@as(usize, 1), material.related.len);
    candidate.content = "manual corrected";
    try std.testing.expectEqual(repo.Apply.updated, try repository.apply(a, material, candidate));
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
    const material: knowledge.Material = .{ .id = id, .created_ms = 1, .sources = &.{} };
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, .{ .category = .project, .topic = "late", .content = "unique searchable fact" }));
    const old = try store.read(a, "project-late");
    const pos = std.mem.find(u8, old.content, "\n<!-- thin-knowledge-v3 -->\n").?;
    const prefix = try a.alloc(u8, 600);
    @memset(prefix, 'x');
    const replacement = try std.mem.concat(a, u8, &.{ prefix, old.content[pos..] });
    _ = try store.replace(a, "project-late", replacement);
    const text = try repository.retrieve(a, "unique searchable", 1);
    try std.testing.expect(std.mem.find(u8, text, "unique searchable fact") != null);
}

fn relatedAllocationCase(a: std.mem.Allocator, repository: *repo.Repository) !void {
    const related = try repository.related(a, "allocation", 1);
    defer {
        for (related) |entry| {
            a.free(entry.topic);
            a.free(entry.content);
        }
        a.free(related);
    }
    try std.testing.expectEqual(@as(usize, 1), related.len);
}

test "related allocation failure releases partially constructed results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root);
    var repository = repo.Repository.init(&store);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const material: knowledge.Material = .{ .id = id, .created_ms = 1, .sources = &.{} };
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(arena.allocator(), material, .{ .category = .project, .topic = "allocation", .content = "allocation fact" }));
    try std.testing.checkAllAllocationFailures(a, relatedAllocationCase, .{&repository});
}
