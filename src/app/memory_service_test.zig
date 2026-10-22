const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const k = @import("../core/knowledge.zig");
const p = @import("../core/protocol.zig");
const decision = @import("../core/decision.zig");
const Coordinator = @import("memory_service.zig").Coordinator;
const Queue = @import("../tools/memory_queue.zig").Queue;
// Coordinator consumes the frozen active selection, not a disk declaration
// which still awaits App metadata resolution. Use a validated owned snapshot.
fn fixtureConfig(a: std.mem.Allocator) !std.json.Parsed(cfg.Config) {
    return cfg.clone(a, .{
        .provider = .{ .base_url = "http://127.0.0.1:1", .api_key = "owned-memory-fixture-key" },
        .selected_provider = "local",
        .model = .{ .name = "fixture", .protocol = .chat, .context_tokens = 32768, .output_tokens = 8192 },
        .limits = .{ .low_price_input = false },
    });
}
const input = "I prefer concise explanations in all code reviews.";
const Fake = struct {
    calls: std.atomic.Value(usize) = .init(0),
    reviews: std.atomic.Value(usize) = .init(0),
    approve: bool = true,
    fail: bool = false,
    fn service(self: *@This()) k.Service {
        return .{ .context = self, .extract_fn = extract };
    }
    fn review(self: *@This()) decision.Service {
        return .{ .context = self, .decide_fn = decide };
    }
    fn extract(raw: *anyopaque, a: std.mem.Allocator, material: k.Material, _: *const p.Cancellation) ![]const k.Candidate {
        const self: *@This() = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .acq_rel);
        if (self.fail) return error.FixtureMemoryUnavailable;
        return a.dupe(k.Candidate, &.{.{ .category = .preferences, .topic = "response-style", .content = "Prefers concise code-review explanations.", .source_id = material.sources[0].id, .quote = "prefer concise explanations" }});
    }
    fn decide(raw: *anyopaque, _: std.mem.Allocator, _: decision.Input, _: *const p.Cancellation) !decision.Output {
        const self: *@This() = @ptrCast(@alignCast(raw));
        _ = self.reviews.fetchAdd(1, .acq_rel);
        return .{ .memory_write = self.approve };
    }
};
fn openRoot(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    return fs.Root.open(a, io, buffer[0..try dir.realPath(io, &buffer)]);
}
fn begin(owner: *Coordinator, a: std.mem.Allocator, text: []const u8) !void {
    const reference = try owner.retrieve(a, text, 8192);
    a.free(reference);
}
fn submit(owner: *Coordinator, a: std.mem.Allocator, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, text);
    try owner.enqueue(&capture);
}

fn rootContentionCase(retrieving: bool) !void {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try openRoot(a, io, tmp.dir);
    defer root.deinit();
    var config = try fixtureConfig(a);
    defer cfg.release(&config);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const owner = try Coordinator.create(a, io, &root, config.value, &env);
    defer owner.deinit();
    // Keep Auto enabled, but join the idle worker before task retrieval wakes it.
    // This regression needs no inference and no competing worker transaction.
    owner.stop.store(true, .release);
    if (owner.future) |*future| future.cancel(io);
    owner.future = null;
    try begin(owner, a, input);

    const Releaser = struct {
        io: std.Io,
        fd: c_int,
        released: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer {
                fs.closeFd(self.fd);
                self.released.store(true, .release);
            }
            // Bound the old blocking implementation: it succeeds after release
            // and fails expectError below rather than hanging the test runner.
            std.Io.sleep(self.io, .fromMilliseconds(200), .awake) catch {};
        }
    };
    var held: ?c_int = try fs.openDirectory(root.dir.handle, ".");
    defer if (held) |fd| fs.closeFd(fd);
    try std.testing.expectEqual(@as(c_int, 0), fs.linux.flock(held.?, 2 | 4));
    var releaser: Releaser = .{ .io = io, .fd = held.? };
    var release = try std.Io.concurrent(io, Releaser.run, .{&releaser});
    held = null; // Only the releaser owns/closes this locked open description.
    defer release.await(io);

    if (retrieving) {
        try std.testing.expectError(error.Busy, begin(owner, a, input));
        try std.testing.expect(!owner.acceptance_valid.load(.acquire));
    } else {
        try std.testing.expectError(error.Busy, submit(owner, a, input));
    }
    try std.testing.expect(!releaser.released.load(.acquire));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    try std.testing.expectEqual(@as(u64, 0), owner.extractor.?.calls);
}

test "automatic memory root contention completion enqueue reports Busy without waiting or creating queue" {
    try rootContentionCase(false);
}

test "automatic memory root contention task retrieval reports Busy and invalidates acceptance" {
    try rootContentionCase(true);
}

test "automatic memory no startup request independent reviewer exact dedup and bounded task retrieval" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try openRoot(a, io, tmp.dir);
    defer root.deinit();
    var config = try fixtureConfig(a);
    defer cfg.release(&config);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const owner = try Coordinator.create(a, io, &root, config.value, &env);
    defer owner.deinit();
    var fake: Fake = .{};
    owner.service_override = fake.service();
    owner.review_override = fake.review();
    try std.testing.expectEqual(@as(usize, 0), fake.calls.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), owner.extractor.?.calls);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    try begin(owner, a, input);
    try submit(owner, a, input);
    owner.finish();
    try std.testing.expectEqual(@as(usize, 1), fake.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fake.reviews.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), owner.completed.load(.acquire));
    const entry = try owner.store.read(a, "preferences-response-style");
    defer a.free(entry.content);
    defer a.free(entry.version);
    try std.testing.expect(std.mem.find(u8, entry.content, "concise") != null);
    const reference = try owner.retrieve(a, "code review concise", 512);
    defer a.free(reference);
    try std.testing.expect(reference.len <= 512 and std.mem.find(u8, reference, "concise") != null);
    // A different source job proposing the same fact must not call the reviewer again.
    try submit(owner, a, "Again: I prefer concise explanations in all code reviews.");
    owner.finish();
    try std.testing.expectEqual(@as(usize, 2), fake.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fake.reviews.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), owner.extractor.?.calls);
    var queue = Queue.init(&root);
    const status = try queue.status(a);
    defer a.free(status);
    try std.testing.expect(std.mem.find(u8, status, "done") != null);
    try std.testing.expect(std.mem.find(u8, status, "concise") == null);
}

test "manual deletion during accepted task cannot be relearned by its automatic capture" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try openRoot(a, io, tmp.dir);
    defer root.deinit();
    var config = try fixtureConfig(a);
    defer cfg.release(&config);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const owner = try Coordinator.create(a, io, &root, config.value, &env);
    defer owner.deinit();
    var fake: Fake = .{};
    owner.service_override = fake.service();
    const entry = try owner.store.write(a, "old", "old fact", null);
    defer a.free(entry.content);
    defer a.free(entry.version);
    try begin(owner, a, input);
    try owner.store.delete("old", entry.version);
    try submit(owner, a, input);
    owner.finish();
    try std.testing.expectEqual(@as(usize, 0), fake.calls.load(.acquire));
    try std.testing.expectError(error.FileNotFound, owner.store.read(a, "preferences-response-style"));
}

test "auxiliary error is visible uncertain and never automatically replayed" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try openRoot(a, io, tmp.dir);
    defer root.deinit();
    var config = try fixtureConfig(a);
    defer cfg.release(&config);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const owner = try Coordinator.create(a, io, &root, config.value, &env);
    defer owner.deinit();
    var fake: Fake = .{ .fail = true };
    owner.service_override = fake.service();
    try begin(owner, a, input);
    try submit(owner, a, input);
    owner.finish();
    try std.testing.expectEqual(@as(usize, 1), fake.calls.load(.acquire));
    try std.testing.expect(std.mem.find(u8, owner.notice().?, "uncertain") != null);
    try submit(owner, a, input);
    owner.finish();
    try std.testing.expectEqual(@as(usize, 1), fake.calls.load(.acquire));
    var queue = Queue.init(&root);
    const status = try queue.status(a);
    defer a.free(status);
    try std.testing.expect(std.mem.find(u8, status, "uncertain") != null);
}

test "Auto memory Off creates no worker or queue and rejects known credentials" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try openRoot(a, backend.io(), tmp.dir);
    defer root.deinit();
    var config = try fixtureConfig(a);
    defer cfg.release(&config);
    config.value.memory.auto = false;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const owner = try Coordinator.create(a, backend.io(), &root, config.value, &env);
    defer owner.deinit();
    try std.testing.expect(owner.future == null and owner.extractor == null);
    try begin(owner, a, input);
    try submit(owner, a, input);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
}
