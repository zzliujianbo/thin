const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const memory = @import("memory.zig");
const knowledge = @import("../core/knowledge.zig");
const repo = @import("knowledge_store.zig");
const queue = @import("memory_queue.zig");
const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
fn rootFor(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !fs.Root {
    var buf: [4096]u8 = undefined;
    const n = try dir.realPath(io, &buf);
    return fs.Root.open(a, io, buf[0..n]);
}
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
    var c: knowledge.Candidate = .{ .category = .project, .topic = "language", .content = " 中文 rust ", .source_id = 0, .quote = "rust" };
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
test "outbox sending crash recovery explicit retry receipt and strict storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, backend.io(), tmp.dir);
    defer root.deinit();
    var q = queue.Queue.init(&root);
    try std.testing.expectEqual(@as(usize, 0), (try q.pending(a)).len);
    try std.testing.expectEqualStrings("", try q.status(a));
    const material: knowledge.Material = .{ .id = id, .generation = 0, .created_ms = 1, .sources = &.{.{ .id = 0, .kind = .user, .text = "PRIVATE BODY" }} };
    try q.enqueue(a, material);
    try q.enqueue(a, material);
    try std.testing.expectEqual(@as(usize, 1), (try q.pending(a)).len);
    try q.mark(a, id, .sending);
    var recovered = queue.Queue.init(&root);
    try std.testing.expectEqual(@as(usize, 0), (try recovered.pending(a)).len);
    const active_status = try recovered.status(a);
    try std.testing.expect(std.mem.find(u8, active_status, "sending") != null);
    try std.testing.expectError(error.WorkerLeaseRequired, recovered.recover(a));
    const lease = try recovered.acquireWorker(a);
    defer fs.closeFd(lease);
    try std.testing.expectError(error.Busy, q.acquireWorker(a));
    try recovered.recover(a);
    const status = try recovered.status(a);
    try std.testing.expect(std.mem.find(u8, status, "uncertain") != null);
    try std.testing.expect(std.mem.find(u8, status, "PRIVATE") == null);
    try std.testing.expectError(error.InvalidJobTransition, recovered.mark(a, id, .queued));
    try recovered.retry(a, id);
    try std.testing.expectEqual(@as(usize, 1), (try recovered.pending(a)).len);
    try recovered.mark(a, id, .sending);
    try recovered.mark(a, id, .failed);
    try std.testing.expectEqual(@as(usize, 0), (try recovered.pending(a)).len);
    try recovered.retry(a, id);
    try recovered.mark(a, id, .sending);
    try recovered.mark(a, id, .done);
    const name = try std.fmt.allocPrint(a, ".thin/mem-jobs/{s}.json", .{id});
    const receipt = try root.readBinary(a, name, queue.max_file_bytes);
    try std.testing.expect(std.mem.find(u8, receipt, "PRIVATE") == null);
    try recovered.enqueue(a, material);
    try std.testing.expectEqual(@as(usize, 0), (try recovered.pending(a)).len);
    try std.testing.expectError(error.InvalidJobTransition, recovered.retry(a, id));
    try root.write(name, "{bad", true);
    try std.testing.expectError(error.SyntaxError, recovered.pending(a));
    const oversized = try a.alloc(u8, queue.max_file_bytes + 1);
    @memset(oversized, 'x');
    try root.write(name, oversized, true);
    try std.testing.expectError(error.FileTooLarge, recovered.pending(a));
    const zname = try a.dupeSentinel(u8, name, 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(root.dir.handle, zname, 0));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("/not-read", root.dir.handle, zname));
    try std.testing.expectError(error.SymlinkNotAllowed, recovered.pending(a));
}

test "outbox allocation failure before publication leaves no queued job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, backend.io(), tmp.dir);
    defer root.deinit();
    var q = queue.Queue.init(&root);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const material: knowledge.Material = .{ .id = id, .generation = 0, .created_ms = 1, .sources = &.{.{ .id = 0, .kind = .user, .text = "body" }} };
    try std.testing.expectError(error.OutOfMemory, q.enqueue(failing.allocator(), material));
    try std.testing.expectEqual(@as(usize, 0), (try q.pending(a)).len);
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
        try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, .{ .category = .project, .topic = topic, .content = text, .source_id = 0, .quote = "durable condition" }));
    }
    const small = "long condition short rule with complete exception";
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, material, .{ .category = .project, .topic = "z-long-condition-small", .content = small, .source_id = 0, .quote = "durable condition" }));
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
