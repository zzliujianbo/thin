test "classified CAS category separation generation tombstones expiration and bounded retrieval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, backend.io(), tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root, .{});
    try std.testing.expectEqual(@as(u64, 0), try store.generation());
    try std.testing.expectEqualStrings("", try store.coreSnapshot(a));
    try std.testing.expectEqual(@as(usize, 0), (try store.topics(a)).len);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    var repository = repo.Repository.init(&store);
    var material: knowledge.Material = .{ .id = id, .generation = 0, .created_ms = 1, .sources = &.{.{ .id = 0, .kind = .user, .text = "中文 rust" }} };
    var c: knowledge.Candidate = .{ .category = .project, .topic = "language", .content = " 中文 rust " };
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, c));
    try std.testing.expectEqual(repo.Apply.unchanged, try repository.apply(a, material, c));
    try std.testing.expectEqual(@as(u64, 0), try store.generation());
    c.content = "rust updated";
    try std.testing.expectEqual(repo.Apply.conflict, try repository.apply(a, material, c));
    const related = try repository.related(a, "rust", 1);
    try std.testing.expectEqual(@as(usize, 1), related.len);
    try std.testing.expectEqualStrings("language", related[0].topic);
    c.expected_version = related[0].version;
    material.related = related;
    try std.testing.expectEqual(repo.Apply.updated, try repository.apply(a, material, c));
    c.expected_version = null;
    c.category = .preferences;
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, c));
    c.topic = "temporary";
    c.content = "ephemeral";
    c.expires_at_ms = std.math.maxInt(u64);
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, c));
    try std.testing.expectEqualStrings("", try repository.retrieve(a, "ephemeral", std.math.maxInt(u64), 8192));
    c.topic = "old";
    c.expires_at_ms = 2;
    try std.testing.expectEqual(repo.Apply.expired, try repository.apply(a, material, c));
    try std.testing.expectEqualStrings("", try repository.retrieve(a, "bananas", 1, 8192));
    for (0..160) |limit| {
        const text = try repository.retrieve(a, "rust", 1, limit);
        try std.testing.expect(text.len <= limit);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    }
    const manual = try store.write(a, "legacy", "legacy 中文", null);
    try std.testing.expect(std.mem.find(u8, try repository.retrieve(a, "中文", 1, 8192), "legacy 中文") != null);
    try std.testing.expectEqual(@as(u64, 1), try store.generation());
    c.expires_at_ms = null;
    try std.testing.expectEqual(repo.Apply.conflict, try repository.apply(a, material, c));
    try store.delete("legacy", manual.version);
    try std.testing.expectEqual(@as(u64, 2), try store.generation());
    try std.testing.expectError(error.GenerationConflict, store.writeGuarded(a, "legacy", "resurrect", null, 1));
    try std.testing.expectEqualStrings("", try store.coreSnapshot(a));
}
test "related budget hard cap preserves complete conditions before extractor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root, .{});
    var repository = repo.Repository.init(&store);
    var material: knowledge.Material = .{ .id = id, .generation = 0, .created_ms = 100, .sources = &.{.{ .id = 0, .kind = .user, .text = "Remember this durable condition." }} };
    const text = try a.alloc(u8, knowledge.max_content_bytes);
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
        bytes += entry.content.len + entry.topic.len + entry.version.len;
        if (std.mem.eql(u8, entry.topic, "z-long-condition-small")) {
            small_count += 1;
            try std.testing.expectEqualStrings(small, entry.content);
        } else {
            large_count += 1;
            try std.testing.expectEqual(knowledge.max_content_bytes, entry.content.len);
            try std.testing.expect(std.mem.startsWith(u8, entry.content, head));
            try std.testing.expectEqual(entry.topic[entry.topic.len - 1], entry.content[head.len]);
            try std.testing.expect(std.mem.endsWith(u8, entry.content, tail));
        }
    }
    try std.testing.expectEqual(@as(usize, 3), large_count);
    try std.testing.expectEqual(@as(usize, 1), small_count);
    try std.testing.expect(bytes <= knowledge.max_retrieval_bytes);
    _ = try @import("../core/knowledge_codec.zig").encode(a, material);
}
test "indexed retrieval reads only selected bodies always includes core and persists bounded evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root, .{});
    _ = try store.write(a, "core", "CORE 中文", null);
    var repository = repo.Repository.init(&store);
    const material: knowledge.Material = .{ .id = id, .generation = try store.generation(), .created_ms = 1, .sources = &.{.{ .id = 7, .kind = .tool, .text = "PRIVATE FULL SOURCE rust 中文" }} };
    const candidate: knowledge.Candidate = .{ .category = .project, .topic = "compiler", .content = "rust 中文编译器" };
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, candidate));
    const entry = try store.read(a, "project-compiler");
    try std.testing.expect(std.mem.find(u8, entry.content, "\"source_id\"") == null);
    try std.testing.expect(std.mem.find(u8, entry.content, "\"source_kind\"") == null);
    try std.testing.expect(std.mem.find(u8, entry.content, "\"quote\"") == null);
    try std.testing.expect(std.mem.find(u8, entry.content, "PRIVATE FULL SOURCE") == null);
    const binary = "other\n\x00";
    for (0..20) |i| {
        const key = try std.fmt.allocPrint(a, "unused-{d}", .{i});
        const name = try std.fmt.allocPrint(a, ".thin/memory/{s}.md", .{key});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = binary });
    }
    const text = try repository.retrieve(a, "请使用中文编译工具", 1, 8192);
    try std.testing.expect(std.mem.startsWith(u8, text, "[Untrusted current local reference: core]"));
    try std.testing.expect(std.mem.find(u8, text, "rust 中文编译器") != null);
    try std.testing.expect(std.mem.find(u8, text, "unused-") == null);
    try std.testing.expect(std.mem.find(u8, try repository.retrieve(a, "unrelated", 1, 8192), "CORE 中文") != null);
    for (0..180) |n| {
        const bounded = try repository.retrieve(a, "中文", 1, n);
        try std.testing.expect(bounded.len <= n);
        try std.testing.expect(std.unicode.utf8ValidateSlice(bounded));
    }
    for (0..20) |i| {
        const name = try std.fmt.allocPrint(a, ".thin/memory/ranked-{d:0>2}.md", .{i});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = if (i < 15) "target\nvalid" else "target\n\x00" });
    }
    const ranked = try repository.retrieve(a, "target", 1, 8192);
    try std.testing.expect(std.mem.find(u8, ranked, "ranked-14") != null);
    try std.testing.expect(std.mem.find(u8, ranked, "ranked-15") == null);
}
test "apply writes only on matching generation and CAS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root, .{});
    var repository = repo.Repository.init(&store);
    var material: knowledge.Material = .{ .id = id, .generation = 0, .created_ms = 1, .sources = &.{.{ .id = 7, .kind = .tool, .text = "PRIVATE FULL SOURCE rust 中文" }} };
    var candidate: knowledge.Candidate = .{ .category = .project, .topic = "preflight", .content = "rust" };
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, candidate));
    const before = try store.read(a, "project-preflight");
    try std.testing.expectEqual(repo.Apply.unchanged, try repository.apply(a, material, candidate));
    candidate.content = "new rust";
    try std.testing.expectEqual(repo.Apply.conflict, try repository.apply(a, material, candidate));
    try std.testing.expectEqualStrings(before.version, (try store.read(a, "project-preflight")).version);
    candidate.expected_version = before.version;
    try std.testing.expectEqual(repo.Apply.updated, try repository.apply(a, material, candidate));
    const updated = try store.read(a, "project-preflight");
    try std.testing.expect(!std.mem.eql(u8, before.version, updated.version));
    try std.testing.expect(std.mem.find(u8, updated.content, "new rust") != null);
    var competing = candidate;
    competing.content = "competing rust";
    competing.expected_version = updated.version;
    try std.testing.expectEqual(repo.Apply.updated, try repository.apply(a, material, competing));
    const competing_entry = try store.read(a, "project-preflight");
    try std.testing.expectEqual(repo.Apply.conflict, try repository.apply(a, material, candidate));
    try std.testing.expectEqualStrings(competing_entry.version, (try store.read(a, "project-preflight")).version);
    candidate.expected_version = competing_entry.version;
    const manual = try store.write(a, "manual", "user edit", null);
    try std.testing.expectEqual(repo.Apply.conflict, try repository.apply(a, material, candidate));
    material.generation = try store.generation();
    try store.delete("manual", manual.version);
    try std.testing.expectEqual(repo.Apply.conflict, try repository.apply(a, material, candidate));
    material.generation = try store.generation();
    candidate.expires_at_ms = 2;
    try std.testing.expectEqual(repo.Apply.expired, try repository.apply(a, material, candidate));
    try std.testing.expectEqualStrings(competing_entry.version, (try store.read(a, "project-preflight")).version);
    candidate.expires_at_ms = null;
    try std.testing.expectEqual(repo.Apply.updated, try repository.apply(a, material, candidate));
}
test "v1 records remain retrievable and CAS updates write v2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root, .{});
    const old = "project: language Zig old\n\n<!-- thin-knowledge-v1 -->\n{\"schema\":1,\"source\":\"" ++ id ++ "\",\"source_id\":0,\"source_kind\":\"user\",\"quote\":\"Zig\",\"generation\":0,\"created_ms\":1,\"expires_at_ms\":null,\"category\":\"project\",\"topic\":\"language\",\"content\":\"Zig old\"}\n";
    _ = try store.write(a, "project-language", old, null);
    var repository = repo.Repository.init(&store);
    const related = try repository.related(a, "Zig", 1);
    try std.testing.expectEqual(@as(usize, 1), related.len);
    try std.testing.expect(std.mem.find(u8, try repository.retrieve(a, "Zig", 1, 8192), "Zig old") != null);
    const material: knowledge.Material = .{ .id = id, .generation = try store.generation(), .created_ms = 1, .sources = &.{}, .related = related };
    const candidate: knowledge.Candidate = .{ .category = .project, .topic = "language", .content = "Zig new", .expected_version = related[0].version };
    try std.testing.expectEqual(repo.Apply.updated, try repository.apply(a, material, candidate));
    const entry = try store.read(a, "project-language");
    try std.testing.expect(std.mem.find(u8, entry.content, "thin-knowledge-v2") != null);
    try std.testing.expect(std.mem.find(u8, entry.content, "\"quote\"") == null);
}
test "strict persisted knowledge records reject unknown and duplicate schema fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, std.testing.io, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root, .{});
    var repository = repo.Repository.init(&store);
    const material: knowledge.Material = .{ .id = id, .generation = 0, .created_ms = 1, .sources = &.{.{ .id = 7, .kind = .tool, .text = "PRIVATE FULL SOURCE rust 中文" }} };
    const candidate: knowledge.Candidate = .{ .category = .project, .topic = "strict", .content = "rust" };
    _ = try repository.apply(a, material, candidate);
    const entry = try store.read(a, "project-strict");
    for ([_][]const u8{ "\"unknown\":1,", "\"schema\":1," }) |injection| {
        const pos = std.mem.findScalar(u8, entry.content, '{').?;
        const bad = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ entry.content[0 .. pos + 1], injection, entry.content[pos + 1 ..] });
        try root.write(".thin/memory/project-strict.md", bad, true);
        try std.testing.expectError(error.InvalidKnowledgeRecord, repository.retrieve(a, "rust", 1, 8192));
    }
}
