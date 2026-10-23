//! Dedicated offline regression suite; only generated temporary project data.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const memory = @import("memory.zig");
const knowledge = @import("../core/knowledge.zig");
const repo = @import("knowledge_store.zig");
const queue = @import("memory_queue.zig");
fn rootFor(a: std.mem.Allocator, dir: std.Io.Dir) !fs.Root {
    var buf: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buf);
    return fs.Root.open(a, std.testing.io, buf[0..n]);
}
fn jobId(a: std.mem.Allocator, n: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "{x:0>64}", .{n});
}
fn material(id: []const u8, generation: u64) knowledge.Material {
    return .{ .id = id, .generation = generation, .created_ms = 1, .sources = &.{.{ .id = 7, .kind = .tool, .text = "PRIVATE FULL SOURCE rust 中文" }} };
}
extern "c" fn fork() c_int;
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
extern "c" fn _exit(c_int) noreturn;
fn claim(q: *queue.Queue, id: []const u8) !bool {
    q.mark(std.heap.page_allocator, id, .sending) catch |err| {
        if (err == error.InvalidJobTransition) return false;
        return err;
    };
    return true;
}

test "worker lease excludes independent process and status cannot recover sending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, tmp.dir);
    defer root.deinit();
    var q = queue.Queue.init(&root);
    const lease = try q.acquireWorker(a);
    defer fs.closeFd(lease);
    const id = try jobId(a, 1);
    try q.enqueue(a, material(id, 0));
    var observer = queue.Queue.init(&root);
    var first = try std.Io.concurrent(root.io, claim, .{ &q, id });
    defer _ = first.cancel(root.io) catch {};
    var second = try std.Io.concurrent(root.io, claim, .{ &observer, id });
    defer _ = second.cancel(root.io) catch {};
    const won = try first.await(root.io);
    try std.testing.expect(won != try second.await(root.io));
    try std.testing.expectError(error.Busy, observer.acquireWorker(a));
    try std.testing.expectEqual(@as(usize, 0), (try observer.pending(a)).len);
    try std.testing.expect(std.mem.find(u8, try observer.status(a), "sending") != null);
    try std.testing.expectError(error.InvalidJobTransition, observer.mark(a, id, .sending));
    try std.testing.expectError(error.WorkerLeaseRequired, observer.recover(a));
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        fs.closeFd(lease);
        const fd = fs.linux.openat(root.dir.handle, ".thin/memory/jobs-owner", fs.linux.nofollow | fs.linux.cloexec, 0);
        if (fd < 0) _exit(2);
        const rc = fs.linux.flock(fd, 2 | 4);
        const busy = rc == -1 and std.c._errno().* == 11;
        fs.closeFd(fd);
        _exit(if (busy) 0 else 3);
    }
    var status: c_int = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (std.c._errno().* != 4) return error.WaitFailed;
    }
    try std.testing.expectEqual(@as(c_int, 0), status);
    try q.recover(a);
    try std.testing.expect(std.mem.find(u8, try observer.status(a), "uncertain") != null);
    try std.testing.expectEqual(@as(usize, 0), (try q.pending(a)).len);
}

test "queue bounded done eviction preserves active jobs and receipts are idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, tmp.dir);
    defer root.deinit();
    var q = queue.Queue.init(&root);
    for (0..queue.max_jobs) |i| {
        const m = material(try jobId(a, i), 0);
        try q.enqueue(a, m);
    }
    try std.testing.expectError(error.QueueFull, q.enqueue(a, material(try jobId(a, 100), 0)));
    try std.testing.expectEqual(@as(usize, 32), (try q.pending(a)).len);
    const done = try jobId(a, 0);
    try q.mark(a, done, .done);
    try q.enqueue(a, material(done, 0));
    try std.testing.expectEqual(@as(usize, 31), (try q.pending(a)).len);
    for (100..140) |i| {
        const m = material(try jobId(a, i), 0);
        try q.enqueue(a, m);
        try q.mark(a, m.id, .done);
    }
    try std.testing.expectEqual(@as(usize, 31), (try q.pending(a)).len);
}

test "indexed retrieval reads only selected bodies always includes core and persists bounded evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root, .{});
    _ = try store.write(a, "core", "CORE 中文", null);
    var repository = repo.Repository.init(&store);
    const m = material(try jobId(a, 1), try store.generation());
    const c: knowledge.Candidate = .{ .category = .project, .topic = "compiler", .content = "rust 中文编译器", .source_id = 7, .quote = "rust" };
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, m, c));
    const entry = try store.read(a, "project-compiler");
    try std.testing.expect(std.mem.find(u8, entry.content, "\"source_id\":7") != null);
    try std.testing.expect(std.mem.find(u8, entry.content, "\"source_kind\":\"tool\"") != null);
    try std.testing.expect(std.mem.find(u8, entry.content, "\"quote\":\"rust\"") != null);
    try std.testing.expect(std.mem.find(u8, entry.content, "PRIVATE FULL SOURCE") == null);
    // Unselected shards have valid small titles but invalid full bodies. A
    // read-everything implementation fails, index-first retrieval succeeds.
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
    // Twenty matching titles: only the top fifteen may be fully read (plus
    // core). Poison the unselected five bodies to enforce the read ceiling.
    for (0..20) |i| {
        const name = try std.fmt.allocPrint(a, ".thin/memory/ranked-{d:0>2}.md", .{i});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = if (i < 15) "target\nvalid" else "target\n\x00" });
    }
    const ranked = try repository.retrieve(a, "target", 1, 8192);
    try std.testing.expect(std.mem.find(u8, ranked, "ranked-14") != null);
    try std.testing.expect(std.mem.find(u8, ranked, "ranked-15") == null);
}

test "inspect is side effect free exact preflight and apply rechecks generation and CAS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root, .{});
    var repository = repo.Repository.init(&store);
    var m = material(try jobId(a, 1), 0);
    var c: knowledge.Candidate = .{ .category = .project, .topic = "preflight", .content = "rust", .source_id = 7, .quote = "rust" };
    try std.testing.expectEqual(repo.Apply.created, try repository.inspect(a, m, c));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    try std.testing.expectEqual(repo.Apply.created, try repository.apply(a, m, c));
    const before = try store.read(a, "project-preflight");
    try std.testing.expectEqual(repo.Apply.unchanged, try repository.inspect(a, m, c));
    c.content = "new rust";
    try std.testing.expectEqual(repo.Apply.conflict, try repository.inspect(a, m, c));
    c.expected_version = before.version;
    m.related = &.{.{ .category = .project, .topic = "preflight", .content = "rust", .version = before.version }};
    try std.testing.expectEqual(repo.Apply.updated, try repository.inspect(a, m, c));
    try std.testing.expectEqualStrings(before.version, (try store.read(a, "project-preflight")).version);
    // A competing automatic update does not increment manual generation, but
    // invalidates the inspected expected_version before the approved apply.
    var competing = c;
    competing.content = "competing rust";
    try std.testing.expectEqual(repo.Apply.updated, try repository.apply(a, m, competing));
    try std.testing.expectEqual(repo.Apply.conflict, try repository.apply(a, m, c));
    c.expected_version = (try store.read(a, "project-preflight")).version;
    m.related = &.{.{ .category = .project, .topic = "preflight", .content = "competing rust", .version = c.expected_version.? }};
    try std.testing.expectEqual(repo.Apply.updated, try repository.inspect(a, m, c));
    const manual = try store.write(a, "manual", "user edit", null);
    try std.testing.expectEqual(repo.Apply.conflict, try repository.apply(a, m, c));
    m.generation = try store.generation();
    try std.testing.expectEqual(repo.Apply.updated, try repository.inspect(a, m, c));
    try store.delete("manual", manual.version);
    try std.testing.expectEqual(repo.Apply.conflict, try repository.apply(a, m, c));
    m.generation = try store.generation();
    c.expires_at_ms = 2;
    try std.testing.expectEqual(repo.Apply.expired, try repository.inspect(a, m, c));
    c.expires_at_ms = null;
    c.quote = "invented quote";
    try std.testing.expectError(error.InvalidMemoryEvidence, repository.inspect(a, m, c));
}

test "strict record and queue JSON reject unknown duplicate fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(a, tmp.dir);
    defer root.deinit();
    var store = memory.Store.init(&root, .{});
    var repository = repo.Repository.init(&store);
    const id = try jobId(a, 1);
    const m = material(id, 0);
    const c: knowledge.Candidate = .{ .category = .project, .topic = "strict", .content = "rust", .source_id = 7, .quote = "rust" };
    _ = try repository.apply(a, m, c);
    const entry = try store.read(a, "project-strict");
    for ([_][]const u8{ "\"unknown\":1,", "\"schema\":1," }) |injection| {
        const pos = std.mem.findScalar(u8, entry.content, '{').?;
        const bad = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ entry.content[0 .. pos + 1], injection, entry.content[pos + 1 ..] });
        try root.write(".thin/memory/project-strict.md", bad, true);
        try std.testing.expectError(error.InvalidKnowledgeRecord, repository.retrieve(a, "rust", 1, 8192));
    }
    var q = queue.Queue.init(&root);
    try q.enqueue(a, m);
    const name = try std.fmt.allocPrint(a, ".thin/memory/jobs/{s}.json", .{id});
    const bytes = try root.readBinary(a, name, queue.max_file_bytes);
    for ([_][]const u8{ "\"unknown\":1,", "\"schema\":1," }) |injection| {
        const bad = try std.fmt.allocPrint(a, "{{{s}{s}", .{ injection, bytes[1..] });
        try root.write(name, bad, true);
        if (q.pending(a)) |_| return error.AcceptedInvalidJSON else |_| {}
    }
}
