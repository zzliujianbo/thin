const std = @import("std");
const cfg = @import("../core/config.zig");
const diag = @import("../core/diagnostics.zig");
const fs = @import("../platform/filesystem.zig");
const k = @import("../core/knowledge.zig");
const memory_status = @import("../core/memory_status.zig");
const p = @import("../core/protocol.zig");
const knowledge = @import("../tools/knowledge_store.zig");
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
    fail: bool = false,
    bad_candidates: bool = false,
    cancel_during_extract: bool = false,
    fn service(self: *@This()) k.Service {
        return .{ .context = self, .extract_fn = extract };
    }
    fn extract(raw: *anyopaque, a: std.mem.Allocator, _: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.cancel_during_extract) {
            @constCast(cancel).cancel();
            return error.Canceled;
        }
        if (self.fail) return error.MemoryUnavailable;
        // Deliberately invalid topic: Service.extract owns the only validation.
        if (self.bad_candidates) return a.dupe(k.Candidate, &.{.{ .category = .preferences, .topic = "Bad Topic", .content = "prefers concise reviews" }});
        return a.dupe(k.Candidate, &.{.{ .category = .preferences, .topic = "response-style", .content = "Prefers concise code-review explanations." }});
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
fn finalize(owner: *Coordinator, a: std.mem.Allocator, text: []const u8, cancel: *const p.Cancellation) !memory_status.Terminal {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, text);
    const id = try owner.enqueueCopy(&capture, .chat, .{});
    owner.drain(cancel);
    const terminal = owner.view().last_terminal orelse return error.MissingMemoryTerminal;
    try std.testing.expectEqual(id, terminal.id);
    return terminal;
}
fn expectNoJobs(root: *fs.Root) !void {
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin/memory/jobs"));
    try std.testing.expectError(error.FileNotFound, fs.openPath(root.dir.handle, ".thin/memory/jobs-owner"));
}

test "automatic Memory extracts once saves and creates no jobs" {
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
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));

    try begin(owner, a, input);
    var cancel: p.Cancellation = .{};
    const saved = try finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(memory_status.Result.saved, saved.result);
    try std.testing.expect(saved.failure == null);
    try std.testing.expectEqual(@as(u32, 1), saved.saved_count);
    try std.testing.expectEqualStrings("Prefers concise code-review explanations.", saved.summary.text());
    const entry = try owner.store.read(a, "preferences-response-style");
    defer a.free(entry.content);
    defer a.free(entry.version);
    try std.testing.expect(std.mem.find(u8, entry.content, "concise") != null);
    try expectNoJobs(&root);

    try begin(owner, a, "Again: concise code reviews.");
    const skipped = try finalize(owner, a, "Again: I prefer concise explanations in all code reviews.", &cancel);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(memory_status.Result.skipped, skipped.result);
    try std.testing.expect(skipped.failure == null);
    try std.testing.expectEqual(@as(u32, 0), skipped.saved_count);
    try expectNoJobs(&root);
}

test "automatic Memory snapshots fresh generation after earlier mutation" {
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
    const terminal = try finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(memory_status.Result.saved, terminal.result);
    try std.testing.expectEqual(@as(u32, 1), terminal.saved_count);
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
    const terminal = try finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(u16, @intFromError(error.Busy)), owner.failure.load(.acquire));
    try std.testing.expectEqual(memory_status.Result.failed, terminal.result);
    try std.testing.expectEqual(memory_status.Failure.busy, terminal.failure.?);
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
    const uncertain = try finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(memory_status.Result.uncertain, uncertain.result);
    try std.testing.expectEqual(memory_status.Failure.unavailable, uncertain.failure.?);
    try expectNoJobs(&root);

    fake.fail = false;
    fake.cancel_during_extract = true;
    try begin(owner, a, input);
    var second_cancel: p.Cancellation = .{};
    const canceled = try finalize(owner, a, input, &second_cancel);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(memory_status.Result.canceled, canceled.result);
    try std.testing.expectEqual(memory_status.Failure.canceled, canceled.failure.?);
    try std.testing.expect(!second_cancel.isRequested());
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
    const terminal = try finalize(owner, a, input, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(u16, 0), owner.failure.load(.acquire));
    try std.testing.expectEqual(memory_status.Result.skipped, terminal.result);
    try std.testing.expect(terminal.failure == null);
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
    const terminal = try finalize(owner, a, "deploy with owned-memory-fixture-key please", &cancel);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(u16, 0), owner.failure.load(.acquire));
    try std.testing.expectEqual(memory_status.Result.skipped, terminal.result);
    try std.testing.expect(terminal.failure == null);
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
    try std.testing.expect(owner.extractor == null);
    var capture_arena = std.heap.ArenaAllocator.init(a);
    defer capture_arena.deinit();
    var capture: k.Capture = .{ .allocator = capture_arena.allocator() };
    capture.add(.user, input);
    var cancel: p.Cancellation = .{};
    try std.testing.expectError(error.MemoryUnavailable, owner.enqueueCopy(&capture, .chat, .{}));
    owner.drain(&cancel);
    const view = owner.view();
    try std.testing.expect(!view.enabled);
    try std.testing.expect(view.active == null);
    try std.testing.expectEqual(memory_status.Result.failed, view.last_terminal.?.result);
    try std.testing.expectEqual(memory_status.Failure.unavailable, view.last_terminal.?.failure.?);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
}

/// Gated extractor: owns its release token, records call order and blocks all
/// jobs until the test releases the batch. Cancellation is observed while
/// gated so cancelAndJoin must wake and join a real worker.
const Gated = struct {
    io: std.Io,
    release: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(u32) = .init(0),
    cancelled: std.atomic.Value(u32) = .init(0),
    generations: [8]u64 = @splat(0),
    related_counts: [8]usize = @splat(0),
    fresh_versions: [8]bool = @splat(false),
    texts: [8][32]u8 = @splat(@splat(0)),
    text_lens: [8]usize = @splat(0),

    fn service(self: *@This()) k.Service {
        return .{ .context = self, .extract_fn = extract };
    }
    fn extract(raw: *anyopaque, a: std.mem.Allocator, material: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const index: usize = @intCast(self.calls.fetchAdd(1, .acq_rel));
        self.started.store(true, .release);
        if (index < self.generations.len) {
            self.generations[index] = material.generation;
            self.related_counts[index] = material.related.len;
            for (material.related) |related| {
                if (std.mem.indexOf(u8, related.content, "fifo alpha fact") == null or related.version.len != 64) continue;
                var valid = true;
                for (related.version) |c| {
                    if (!std.ascii.isHex(c)) {
                        valid = false;
                        break;
                    }
                }
                if (valid) self.fresh_versions[index] = true;
            }
            const text = material.sources[0].text;
            const count = @min(text.len, self.texts[index].len);
            @memcpy(self.texts[index][0..count], text[0..count]);
            self.text_lens[index] = count;
        }
        while (!self.release.load(.acquire)) {
            if (cancel.isRequested()) {
                _ = self.cancelled.fetchAdd(1, .acq_rel);
                return error.Canceled;
            }
            try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
        }
        const text = material.sources[0].text;
        const topic = try std.fmt.allocPrint(a, "job-{d}", .{index + 1});
        return a.dupe(k.Candidate, &.{.{
            .category = .preferences,
            .topic = topic,
            .content = text,
        }});
    }
};

fn waitFlag(io: std.Io, flag: *const std.atomic.Value(bool)) !void {
    const start = std.Io.Clock.awake.now(io);
    while (!flag.load(.acquire)) {
        if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 2000) return error.TestTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}

fn waitGate(io: std.Io, gate: *const std.atomic.Value(u8)) !void {
    const start = std.Io.Clock.awake.now(io);
    while (gate.load(.acquire) == 0) {
        if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 2000) return error.TestTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}

fn enqueueText(owner: *Coordinator, a: std.mem.Allocator, text: []const u8) !u64 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, text);
    return owner.enqueueCopy(&capture, .chat, .{});
}

const Events = struct {
    records: [4]diag.Record = undefined,
    len: usize = 0,
    fn emit(raw: ?*anyopaque, record: diag.Record) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.len < self.records.len) {
            self.records[self.len] = record;
            self.len += 1;
        }
    }
};

test "queued jobs run FIFO from owned capture copies with a fresh generation" {
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
    var gated: Gated = .{ .io = io };
    owner.service_override = gated.service();

    // Each caller arena dies immediately after enqueue; the job must own copies.
    try std.testing.expectEqual(@as(u64, 1), try enqueueText(owner, a, "fifo alpha fact"));
    try std.testing.expectEqual(@as(u64, 2), try enqueueText(owner, a, "fifo beta fact"));
    try std.testing.expectEqual(@as(u64, 3), try enqueueText(owner, a, "fifo gamma fact"));
    gated.release.store(true, .release);
    var cancel: p.Cancellation = .{};
    owner.drain(&cancel);
    owner.cancelAndJoin();

    try std.testing.expectEqual(@as(u32, 3), gated.calls.load(.acquire));
    try std.testing.expectEqualStrings("fifo alpha fact", gated.texts[0][0..gated.text_lens[0]]);
    try std.testing.expectEqualStrings("fifo beta fact", gated.texts[1][0..gated.text_lens[1]]);
    try std.testing.expectEqualStrings("fifo gamma fact", gated.texts[2][0..gated.text_lens[2]]);
    // Automatic guarded writes retain the epoch but later jobs see prior facts.
    try std.testing.expectEqual(gated.generations[0], gated.generations[1]);
    try std.testing.expectEqual(gated.generations[1], gated.generations[2]);
    try std.testing.expectEqual(@as(usize, 0), gated.related_counts[0]);
    try std.testing.expect(gated.related_counts[1] >= 1 and gated.fresh_versions[1]);
    try std.testing.expect(gated.related_counts[2] >= 2 and gated.fresh_versions[2]);
    const expected = [_]struct { key: []const u8, text: []const u8 }{
        .{ .key = "preferences-job-1", .text = "fifo alpha fact" },
        .{ .key = "preferences-job-2", .text = "fifo beta fact" },
        .{ .key = "preferences-job-3", .text = "fifo gamma fact" },
    };
    for (expected) |item| {
        const entry = try owner.store.read(a, item.key);
        defer a.free(entry.content);
        defer a.free(entry.version);
        try std.testing.expect(std.mem.find(u8, entry.content, item.text) != null);
    }
    const view = owner.view();
    try std.testing.expect(view.active == null);
    try std.testing.expectEqual(@as(u64, 0), view.queued_count);
    try std.testing.expectEqual(@as(u64, 3), view.last_terminal.?.id);
    try std.testing.expect(view.last_terminal.?.result == .saved);
    try expectNoJobs(&root);
}

test "primary retrieve and parent reportFailure never rewrite an active job outcome" {
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
    var gated: Gated = .{ .io = io };
    owner.service_override = gated.service();

    try std.testing.expectEqual(@as(u64, 1), try enqueueText(owner, a, "active job evidence"));
    try waitFlag(io, &gated.started);
    const before = owner.view();
    try std.testing.expectEqual(@as(u64, 1), before.active.?.id);
    try std.testing.expectEqual(.extracting, before.active.?.phase);

    const reference = try owner.retrieve(a, input, 8192);
    a.free(reference);
    owner.reportFailure(error.Busy);
    try std.testing.expectEqual(@as(u16, @intFromError(error.Busy)), owner.failure.load(.acquire));
    const during = owner.view();
    try std.testing.expectEqual(before.active.?.id, during.active.?.id);
    try std.testing.expectEqual(before.active.?.phase, during.active.?.phase);
    try std.testing.expect(during.last_terminal == null);

    gated.release.store(true, .release);
    var cancel: p.Cancellation = .{};
    owner.drain(&cancel);
    owner.cancelAndJoin();
    const after = owner.view();
    try std.testing.expect(after.active == null);
    try std.testing.expectEqual(@as(u64, 1), after.last_terminal.?.id);
    try std.testing.expect(after.last_terminal.?.result == .saved);
    try std.testing.expect(after.last_terminal.?.failure == null);
    try std.testing.expectEqual(@as(u16, 0), owner.failure.load(.acquire));
    try expectNoJobs(&root);
}

test "cancelAndJoin wakes and joins the worker without extracting queued jobs" {
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
    var gated: Gated = .{ .io = io };
    owner.service_override = gated.service();

    _ = try enqueueText(owner, a, "active canceled job");
    try waitFlag(io, &gated.started);
    _ = try enqueueText(owner, a, "queued canceled job one");
    _ = try enqueueText(owner, a, "queued canceled job two");
    const busy = owner.view();
    try std.testing.expectEqual(@as(u64, 1), busy.active.?.id);
    try std.testing.expectEqual(@as(u64, 2), busy.queued_count);

    owner.cancelAndJoin();
    try std.testing.expect(owner.stopped);
    try std.testing.expect(owner.future == null);
    try std.testing.expectEqual(@as(u32, 1), gated.calls.load(.acquire));
    try std.testing.expect(gated.cancelled.load(.acquire) >= 1);
    const after = owner.view();
    try std.testing.expect(after.active == null);
    try std.testing.expectEqual(@as(u64, 0), after.queued_count);
    try std.testing.expectEqual(@as(u64, 3), after.last_terminal.?.id);
    try std.testing.expect(after.last_terminal.?.result == .canceled);
    try std.testing.expectError(error.MemoryUnavailable, enqueueText(owner, a, "rejected after stop"));
    try expectNoJobs(&root);
}

test "worker wait failure fails every queued job and releases drain" {
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
    var gated: Gated = .{ .io = io };
    owner.service_override = gated.service();

    gated.release.store(true, .release);
    _ = try enqueueText(owner, a, "warmup before wait fault");
    var cancel: p.Cancellation = .{};
    owner.drain(&cancel);
    try waitFlag(io, &owner.wait_ready);
    owner.fail_wait.store(true, .release);
    _ = try enqueueText(owner, a, "stranded wait job one");
    // The seam pauses the failing worker before it publishes, so both jobs are
    // really queued and the public drain must see both failed terminals.
    try waitGate(io, &owner.fail_wait_gate);
    _ = try enqueueText(owner, a, "stranded wait job two");
    owner.fail_wait_gate.store(2, .release);
    owner.drain(&cancel);
    owner.cancelAndJoin();

    try std.testing.expect(owner.stopped);
    try std.testing.expect(owner.future == null);
    try std.testing.expectEqual(@as(u32, 1), gated.calls.load(.acquire));
    const view = owner.view();
    try std.testing.expect(view.active == null);
    try std.testing.expectEqual(@as(u64, 0), view.queued_count);
    try std.testing.expectEqual(@as(u64, 3), view.last_terminal.?.id);
    try std.testing.expect(view.last_terminal.?.result == .failed);
    try std.testing.expect(view.last_terminal.?.failure.? == .other);
    try std.testing.expectEqual(@as(u16, @intFromError(error.TestWaitFailure)), owner.failure.load(.acquire));
    try expectNoJobs(&root);
}

test "exhausted job ids are rejected without reuse and stay observable" {
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
    owner.reportFailure(error.Busy);
    try std.testing.expect(owner.view().last_terminal.?.failure.? == .busy);

    owner.next_id = std.math.maxInt(u64);
    var events: Events = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, input);
    const sink: diag.Sink = .{ .context = &events, .emit_fn = Events.emit };
    try std.testing.expectError(error.MemoryIdExhausted, owner.enqueueCopy(&capture, .chat, sink));
    try std.testing.expectEqual(std.math.maxInt(u64), owner.next_id);
    const view = owner.view();
    try std.testing.expectEqual(@as(u64, 0), view.last_terminal.?.id);
    try std.testing.expect(view.last_terminal.?.result == .failed);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(diag.Stage.memory_submit, events.records[0].stage);
    try std.testing.expectEqualStrings("MemoryIdExhausted", events.records[0].error_name.?.name());
    // Exhaustion is sticky: it never wraps to a previously used id.
    try std.testing.expectError(error.MemoryIdExhausted, owner.enqueueCopy(&capture, .chat, sink));
    try std.testing.expectEqual(std.math.maxInt(u64), owner.next_id);
    try expectNoJobs(&root);
}

test "mixed sources and candidates save only committed safe entries" {
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
    const existing = try owner.store.write(a, "preferences-conflict", "existing independent fact", null);
    defer a.free(existing.content);
    defer a.free(existing.version);
    const Mixed = struct {
        calls: usize = 0,
        fn extract(raw: *anyopaque, alloc: std.mem.Allocator, material: k.Material, _: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqual(@as(usize, 5), material.sources.len);
            try std.testing.expectEqualStrings("Useful source", material.sources[0].text);
            try std.testing.expectEqualStrings("Use Bearer authentication for HTTP requests", material.sources[1].text);
            try std.testing.expectEqualStrings("token = nextToken()", material.sources[2].text);
            try std.testing.expectEqualStrings("password: minimum 8 characters", material.sources[3].text);
            try std.testing.expectEqualStrings("Set api_key in .env at /app/config", material.sources[4].text);
            return alloc.dupe(k.Candidate, &.{
                .{ .category = .preferences, .topic = "bad topic", .content = "invalid" },
                .{ .category = .preferences, .topic = "conflict", .content = "must not overwrite" },
                .{ .category = .preferences, .topic = "secret", .content = "owned-memory-fixture-key" },
                .{ .category = .preferences, .topic = "bearer-secret", .content = "Bearer abc.def" },
                .{ .category = .preferences, .topic = "good", .content = "  A useful fact.  " },
            });
        }
    };
    var mixed: Mixed = .{};
    owner.service_override = .{ .context = &mixed, .extract_fn = Mixed.extract };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, "Useful source");
    capture.add(.user, "Use Bearer authentication for HTTP requests");
    capture.add(.tool, "token = nextToken()");
    capture.add(.user, "password: minimum 8 characters");
    capture.add(.user, "Set api_key in .env at /app/config");
    capture.add(.tool, "owned-memory-fixture-key");
    _ = try owner.enqueueCopy(&capture, .chat, .{});
    var cancel: p.Cancellation = .{};
    owner.drain(&cancel);
    const terminal = owner.view().last_terminal.?;
    try std.testing.expectEqual(@as(usize, 1), mixed.calls);
    try std.testing.expectEqual(@as(u32, 2), terminal.saved_count);
    try std.testing.expectEqualStrings("Bearer abc.def · A useful fact.", terminal.summary.text());
    try std.testing.expect(terminal.result == .saved);
    const saved = try owner.store.read(a, "preferences-good");
    defer a.free(saved.content);
    defer a.free(saved.version);
    try std.testing.expect(std.mem.indexOf(u8, saved.content, "owned-memory-fixture-key") == null);
    try std.testing.expectError(error.FileNotFound, owner.store.read(a, "preferences-secret"));
    const ordinary = try owner.store.read(a, "preferences-bearer-secret");
    defer a.free(ordinary.content);
    defer a.free(ordinary.version);
    var repository = knowledge.Repository.init(&owner.store);
    const now_ms: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toMilliseconds()));
    const related = try repository.related(arena.allocator(), "Bearer", now_ms);
    var matches: usize = 0;
    for (related) |entry| {
        if (entry.category != .preferences or !std.mem.eql(u8, entry.topic, "bearer-secret")) continue;
        matches += 1;
        try std.testing.expectEqualStrings("Bearer abc.def", entry.content);
    }
    try std.testing.expectEqual(@as(usize, 1), matches);
    const conflict = try owner.store.read(a, "preferences-conflict");
    defer a.free(conflict.content);
    defer a.free(conflict.version);
    try std.testing.expectEqualStrings("existing independent fact", conflict.content);
}
