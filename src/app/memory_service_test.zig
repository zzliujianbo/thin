const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const k = @import("../core/knowledge.zig");
const p = @import("../core/protocol.zig");
const decision = @import("../core/decision.zig");
const Coordinator = @import("memory_service.zig").Coordinator;

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
    calls: usize = 0,
    reviews: usize = 0,
    approve: bool = true,
    fail: bool = false,
    bad_candidates: bool = false,
    cancel_during_extract: bool = false,
    fn service(self: *@This()) k.Service {
        return .{ .context = self, .extract_fn = extract };
    }
    fn review(self: *@This()) decision.Service {
        return .{ .context = self, .decide_fn = decide };
    }
    fn extract(raw: *anyopaque, a: std.mem.Allocator, material: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.cancel_during_extract) {
            @constCast(cancel).cancel();
            return error.Canceled;
        }
        if (self.fail) return error.MemoryUnavailable;
        // Deliberately invalid topic: Service.extract owns the only validation.
        if (self.bad_candidates) return a.dupe(k.Candidate, &.{.{ .category = .preferences, .topic = "Bad Topic", .content = "prefers concise reviews", .source_id = material.sources[0].id, .quote = "prefer concise explanations" }});
        return a.dupe(k.Candidate, &.{.{ .category = .preferences, .topic = "response-style", .content = "Prefers concise code-review explanations.", .source_id = material.sources[0].id, .quote = "prefer concise explanations" }});
    }
    fn decide(raw: *anyopaque, _: std.mem.Allocator, _: decision.Input, _: *const p.Cancellation) !decision.Output {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.reviews += 1;
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
fn finalize(owner: *Coordinator, a: std.mem.Allocator, text: []const u8, cancel: *const p.Cancellation) void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, text);
    owner.finalize(&capture, .chat, cancel);
}
fn expectNoJobs(root: *fs.Root) !void {
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin/memory/jobs"));
    try std.testing.expectError(error.FileNotFound, fs.openPath(root.dir.handle, ".thin/memory/jobs-owner"));
}

test "automatic Memory synchronously extracts reviews saves and creates no jobs" {
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
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));

    try begin(owner, a, input);
    var cancel: p.Cancellation = .{};
    finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.reviews);
    try std.testing.expectEqual(@as(u64, 1), owner.completed.load(.acquire));
    try std.testing.expectEqualStrings("Memory: saved", owner.notice().?);
    const entry = try owner.store.read(a, "preferences-response-style");
    defer a.free(entry.content);
    defer a.free(entry.version);
    try std.testing.expect(std.mem.find(u8, entry.content, "concise") != null);
    try expectNoJobs(&root);

    try begin(owner, a, "Again: concise code reviews.");
    finalize(owner, a, "Again: I prefer concise explanations in all code reviews.", &cancel);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.reviews);
    try std.testing.expectEqualStrings("Memory: no new durable entries", owner.notice().?);
    try expectNoJobs(&root);
}

test "automatic Memory generation mutation skips before extraction" {
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
    var cancel: p.Cancellation = .{};
    finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqualStrings("Memory: no new durable entries", owner.notice().?);
    try std.testing.expectError(error.FileNotFound, owner.store.read(a, "preferences-response-style"));
    try expectNoJobs(&root);
}

test "automatic Memory contention fails promptly without jobs" {
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
    try begin(owner, a, input);
    const held = try fs.openDirectory(root.dir.handle, ".");
    defer fs.closeFd(held);
    try std.testing.expectEqual(@as(c_int, 0), fs.linux.flock(held, 2 | 4));
    var cancel: p.Cancellation = .{};
    finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(u16, @intFromError(error.Busy)), owner.failure.load(.acquire));
    try std.testing.expectEqualStrings("Memory: finalization failed", owner.notice().?);
    try expectNoJobs(&root);
}

test "automatic Memory uncertainty and cancellation are terminal without replay" {
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
    var cancel: p.Cancellation = .{};
    finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(std.mem.find(u8, owner.notice().?, "uncertain") != null);
    try expectNoJobs(&root);

    fake.fail = false;
    fake.cancel_during_extract = true;
    try begin(owner, a, input);
    var second_cancel: p.Cancellation = .{};
    finalize(owner, a, input, &second_cancel);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqualStrings("Memory: finalization canceled", owner.notice().?);
    try std.testing.expect(second_cancel.isRequested());
    try expectNoJobs(&root);
}

test "invalid service candidates never reach storage" {
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
    var fake: Fake = .{ .bad_candidates = true };
    owner.service_override = fake.service();
    try begin(owner, a, input);
    var cancel: p.Cancellation = .{};
    finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(u16, @intFromError(error.InvalidMemoryCandidate)), owner.failure.load(.acquire));
    try std.testing.expectEqualStrings("Memory: finalization failed", owner.notice().?);
    // The rejected batch is never persisted, and no index shard is created.
    try std.testing.expectError(error.FileNotFound, owner.store.read(a, "preferences-response-style"));
    try expectNoJobs(&root);
}

test "known secret source is rejected before any auxiliary request" {
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
    try begin(owner, a, input);
    var cancel: p.Cancellation = .{};
    // The fixture provider key is known to this Coordinator only, not to Capture.
    finalize(owner, a, "deploy with owned-memory-fixture-key please", &cancel);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(u16, @intFromError(error.SensitiveMemoryMaterial)), owner.failure.load(.acquire));
    try std.testing.expectEqualStrings("Memory: finalization failed", owner.notice().?);
    try std.testing.expectError(error.FileNotFound, owner.store.read(a, "preferences-response-style"));
    try expectNoJobs(&root);
}

test "Auto Memory Off has no helper clients or storage side effects" {
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
    try std.testing.expect(owner.extractor == null and owner.reviewer == null);
    var capture_arena = std.heap.ArenaAllocator.init(a);
    defer capture_arena.deinit();
    var capture: k.Capture = .{ .allocator = capture_arena.allocator() };
    capture.add(.user, input);
    var cancel: p.Cancellation = .{};
    owner.finalize(&capture, .chat, &cancel);
    try std.testing.expect(owner.notice() == null);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
}
