//! Strictly offline Coordinator lifecycle tests, not Runtime tool-approval tests.
//! Only this file is owned by this suite. Discover it from a private snapshot root.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const k = @import("../core/knowledge.zig");
const decision = @import("../core/decision.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const Queue = @import("../tools/memory_queue.zig").Queue;
const Repository = @import("../tools/knowledge_store.zig").Repository;
const Coordinator = @import("memory_service.zig").Coordinator;
const a = std.testing.allocator;
const key = "owned-memory-fixture-key";
const text = "Prefer concise reviews.";
const evidence = [_]k.Evidence{.{ .id = 0, .kind = .user, .text = text }};
const candidate: k.Candidate = .{ .category = .preferences, .topic = "review-style", .content = "Prefers concise reviews.", .source_id = 0, .quote = "concise reviews" };

fn frozen() cfg.Config {
    return .{
        .provider = .{ .base_url = "http://127.0.0.1:1", .api_key = key },
        .selected_provider = "local",
        .model = .{ .name = "fixture", .protocol = .chat, .context_tokens = 32768, .output_tokens = 8192 },
        .limits = .{ .low_price_input = false, .request_timeout_ms = 2000 },
    };
}

// Heap-stable owner: neither root pointers nor Threaded backing move after init.
// The worker's long-lived owner backing is testing.allocator, never a shared Arena.
const Fixture = struct {
    backend: std.Io.Threaded,
    tmp: std.testing.TmpDir,
    root: fs.Root,
    env: std.process.Environ.Map,
    owner: ?*Coordinator = null,

    fn create() !*Fixture {
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        self.backend = .init(a, .{});
        errdefer self.backend.deinit();
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const io = self.backend.io();
        var path: [4096]u8 = undefined;
        self.root = try fs.Root.open(a, io, path[0..try self.tmp.dir.realPath(io, &path)]);
        errdefer self.root.deinit();
        self.env = .init(a);
        errdefer self.env.deinit();
        try self.env.put("HOME", self.root.path);
        self.owner = null;
        return self;
    }
    fn start(self: *Fixture, fake: *Fake) !*Coordinator {
        try std.testing.expect(self.owner == null);
        const owner = try Coordinator.create(a, self.backend.io(), &self.root, frozen(), &self.env);
        self.owner = owner;
        // No wake has occurred; overrides remain immutable until join.
        owner.service_override = .{ .context = fake, .extract_fn = Fake.extract };
        owner.review_override = .{ .context = fake, .decide_fn = Fake.review };
        try std.testing.expectEqual(@as(u64, 0), owner.extractor.?.calls);
        return owner;
    }
    fn stop(self: *Fixture) void {
        if (self.owner) |owner| {
            // Check only once joined below: fake callbacks never call the real client.
            owner.deinit();
            self.owner = null;
        }
    }
    fn deinit(self: *Fixture) void {
        self.stop();
        self.env.deinit();
        self.root.deinit();
        self.tmp.cleanup();
        self.backend.deinit();
        a.destroy(self);
    }
    fn wake(self: *Fixture, max_bytes: usize) !void {
        const result = try self.owner.?.retrieve(a, text, max_bytes);
        defer a.free(result);
        if (max_bytes == 0) try std.testing.expectEqualStrings("", result);
    }
    fn seed(self: *Fixture, n: usize, state: @import("../tools/memory_queue.zig").State, created: u64, sources: []const k.Evidence) ![64]u8 {
        const id = jobId(n);
        var store = mem.Store.init(&self.root, .{});
        var q = Queue.init(&self.root);
        try q.enqueue(a, .{ .id = &id, .generation = try store.generation(), .created_ms = created, .sources = sources });
        if (state == .uncertain) try q.mark(a, &id, .sending);
        if (state != .queued) try q.mark(a, &id, state);
        return id;
    }
};

const Mode = enum { allow, deny, fail, wrong_tag, mutate, cleanup, malicious, related, block };
const Fake = struct {
    io: std.Io,
    mode: Mode = .allow,
    store: ?*mem.Store = null,
    calls: std.atomic.Value(usize) = .init(0),
    reviews: std.atomic.Value(usize) = .init(0),
    entered: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    saw_cancel: std.atomic.Value(bool) = .init(false),
    related_checked: std.atomic.Value(bool) = .init(false),

    fn extract(raw: *anyopaque, out: std.mem.Allocator, material: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
        const self: *Fake = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .acq_rel);
        if (self.mode == .block) {
            defer self.exited.store(true, .release);
            self.entered.store(true, .release);
            while (!cancel.isRequested()) {
                std.Io.sleep(self.io, .fromMilliseconds(5), .awake) catch {
                    self.saw_cancel.store(cancel.isRequested(), .release);
                    return error.Canceled;
                };
            }
            self.saw_cancel.store(true, .release);
            return error.Canceled;
        }
        if (self.mode == .related) {
            // A safe lexical match must survive, while the entire key-bearing
            // legacy entry must disappear, not merely its sensitive substring.
            try std.testing.expectEqual(@as(usize, 1), material.related.len);
            try std.testing.expectEqualStrings("safe-legacy", material.related[0].topic);
            for (material.related) |entry| {
                try std.testing.expect(std.mem.find(u8, entry.content, key) == null);
                try std.testing.expect(std.mem.find(u8, entry.topic, key) == null);
                try std.testing.expect(std.mem.find(u8, entry.content, "unsafe sentinel") == null);
            }
            self.related_checked.store(true, .release);
            return &.{};
        }
        if (self.mode == .malicious) {
            var bad = candidate;
            bad.topic = key; // Legal topic syntax; not caught by the pure marker list.
            bad.content = "Second otherwise-valid candidate.";
            return out.dupe(k.Candidate, &.{ candidate, bad });
        }
        return out.dupe(k.Candidate, &.{candidate});
    }
    fn review(raw: *anyopaque, out: std.mem.Allocator, input: decision.Input, _: *const p.Cancellation) !decision.Output {
        const self: *Fake = @ptrCast(@alignCast(raw));
        _ = self.reviews.fetchAdd(1, .acq_rel);
        try std.testing.expect(input == .memory_write);
        try std.testing.expectEqualStrings(candidate.topic, input.memory_write.topic);
        switch (self.mode) {
            .deny => return .{ .memory_write = false },
            .fail => return error.FixtureReviewFailed,
            .wrong_tag => return .{ .command = .{ .timeout = .none, .ask = false } },
            .cleanup => return error.CleanupFailed,
            .mutate => {
                // Real Store mutation advances generation after inspect but
                // before apply. Approval of value cannot revive the old generation.
                const entry = try self.store.?.write(out, "manual", "Manual correction during review.", null);
                out.free(entry.content);
                out.free(entry.version);
            },
            else => {},
        }
        return .{ .memory_write = true };
    }
};

fn jobId(n: usize) [64]u8 {
    var result: [64]u8 = @splat('0');
    result[63] = "0123456789abcdef"[n];
    return result;
}
fn now(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.real.now(io).toMilliseconds()));
}
fn submit(owner: *Coordinator, source: []const u8) !void {
    // Per-call arena is only used by the submitting thread and destroyed after
    // enqueue has durably copied the capture. It never backs the worker owner.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, source);
    try std.testing.expectEqual(@as(usize, 1), capture.sources.items.len);
    try owner.enqueue(&capture);
}
fn waitTrue(io: std.Io, value: *const std.atomic.Value(bool)) !void {
    const start = std.Io.Clock.awake.now(io);
    while (!value.load(.acquire)) {
        if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 2000) return error.FixtureWaitTimeout;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}
fn settle(owner: *Coordinator) !void {
    owner.finish();
    if (!owner.isPoisoned()) try std.testing.expect(owner.settled_version.load(.acquire) >= owner.work_version.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), owner.extractor.?.calls);
}
fn missing(owner: *Coordinator) !void {
    try std.testing.expectError(error.FileNotFound, owner.store.read(a, "preferences-review-style"));
}
fn status(root: *fs.Root, id: []const u8, state: []const u8) !void {
    var q = Queue.init(root);
    const body = try q.status(a);
    defer a.free(body);
    const line = try std.fmt.allocPrint(a, "{s} {s}\n", .{ id, state });
    defer a.free(line);
    try std.testing.expect(std.mem.find(u8, body, line) != null);
}
fn receipt(root: *fs.Root, id: []const u8) !void {
    try status(root, id, "done");
    const path = try std.fmt.allocPrint(a, ".thin/mem-jobs/{s}.json", .{id});
    defer a.free(path);
    const body = try root.readBinary(a, path, 65536);
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("material").? == .null);
    try std.testing.expect(std.mem.find(u8, body, "sources") == null);
    try std.testing.expect(std.mem.find(u8, body, text) == null);
    try std.testing.expect(std.mem.find(u8, body, key) == null);
}

test "memory lifecycle review deny fail wrong tag manual-generation mutation and cleanup poison" {
    for ([_]Mode{ .deny, .fail, .wrong_tag, .mutate, .cleanup }) |mode| {
        const f = try Fixture.create();
        defer f.deinit();
        var fake: Fake = .{ .io = f.backend.io(), .mode = mode };
        const owner = try f.start(&fake);
        fake.store = &owner.store;
        const generation = try owner.store.generation();
        const id = try f.seed(1, .queued, now(f.backend.io()), &evidence);
        try f.wake(0);
        try settle(owner);
        try missing(owner);
        try std.testing.expectEqual(@as(usize, 1), fake.calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), fake.reviews.load(.acquire));
        switch (mode) {
            .deny => {
                try receipt(&f.root, &id);
                try std.testing.expectEqual(@as(u64, 1), owner.completed.load(.acquire));
                try std.testing.expectEqual(@as(u16, 0), owner.failure.load(.acquire));
            },
            .mutate => {
                try std.testing.expectEqual(generation + 1, try owner.store.generation());
                const entry = try owner.store.read(a, "manual");
                defer a.free(entry.content);
                defer a.free(entry.version);
                try std.testing.expectEqualStrings("Manual correction during review.", entry.content);
                // Manual mutation intentionally purges the entire obsolete outbox.
                var q = Queue.init(&f.root);
                const body = try q.status(a);
                defer a.free(body);
                try std.testing.expectEqualStrings("", body);
                try std.testing.expectEqual(@as(u16, @intFromError(error.MemoryConflict)), owner.failure.load(.acquire));
            },
            .cleanup => {
                try waitTrue(f.backend.io(), &owner.poisoned);
                try status(&f.root, &id, "uncertain");
                try std.testing.expectError(error.CleanupFailed, owner.retrieve(a, text, 0));
                try std.testing.expectError(error.CleanupFailed, owner.retrieve(a, text, 8192));
            },
            else => {
                try status(&f.root, &id, "uncertain");
                const expected = if (mode == .fail) error.FixtureReviewFailed else error.InvalidDecision;
                try std.testing.expectEqual(@as(u16, @intFromError(expected)), owner.failure.load(.acquire));
            },
        }
        f.stop(); // All callbacks joined before fake's stack lifetime ends.
    }
}

test "memory lifecycle restart wakes only queued jobs after real retrieve including zero budget" {
    for ([_]usize{ 0, 8192 }) |max_bytes| {
        const f = try Fixture.create();
        defer f.deinit();
        var first: Fake = .{ .io = f.backend.io() };
        _ = try f.start(&first);
        const queued = try f.seed(1, .queued, now(f.backend.io()), &evidence);
        const sending = try f.seed(2, .sending, now(f.backend.io()), &evidence);
        const uncertain = try f.seed(3, .uncertain, now(f.backend.io()), &evidence);
        // First owner exits without ever receiving a task/wake.
        f.stop();
        try std.testing.expectEqual(@as(usize, 0), first.calls.load(.acquire));
        var second: Fake = .{ .io = f.backend.io() };
        const owner = try f.start(&second);
        try std.Io.sleep(f.backend.io(), .fromMilliseconds(90), .awake);
        try std.testing.expectEqual(@as(usize, 0), second.calls.load(.acquire));
        try status(&f.root, &sending, "sending");
        try f.wake(max_bytes);
        try settle(owner);
        try std.testing.expectEqual(@as(usize, 1), second.calls.load(.acquire));
        try receipt(&f.root, &queued);
        try status(&f.root, &sending, "uncertain");
        try status(&f.root, &uncertain, "uncertain");
        try f.wake(max_bytes);
        try settle(owner);
        try std.testing.expectEqual(@as(usize, 1), second.calls.load(.acquire));
        f.stop();
    }
}

test "memory lifecycle expired queued and explicitly retried failed uncertain jobs erase sources without extraction" {
    const f = try Fixture.create();
    defer f.deinit();
    var fake: Fake = .{ .io = f.backend.io() };
    const owner = try f.start(&fake);
    try std.testing.expect(now(f.backend.io()) > 86400000);
    const queued = try f.seed(1, .queued, 0, &evidence);
    const failed = try f.seed(2, .failed, 0, &evidence);
    const uncertain = try f.seed(3, .uncertain, 0, &evidence);
    const future = try f.seed(4, .queued, std.math.maxInt(u64), &evidence);
    var q = Queue.init(&f.root);
    // Explicit storage retry only, not a claim of Runtime Tool authorization.
    try q.retry(a, &failed);
    try q.retry(a, &uncertain);
    try f.wake(0);
    try settle(owner);
    for ([_][64]u8{ queued, failed, uncertain, future }) |id| try receipt(&f.root, &id);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fake.reviews.load(.acquire));
    try missing(owner);
    f.stop();
}

test "memory lifecycle deinit cancels sleeping extractor and joins before releasing fake" {
    const f = try Fixture.create();
    defer f.deinit();
    const fake = try a.create(Fake);
    fake.* = .{ .io = f.backend.io(), .mode = .block };
    defer a.destroy(fake);
    _ = try f.start(fake);
    _ = try f.seed(1, .queued, now(f.backend.io()), &evidence);
    try f.wake(0);
    try waitTrue(f.backend.io(), &fake.entered);
    const start = std.Io.Clock.awake.now(f.backend.io());
    f.stop();
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(f.backend.io())).toMilliseconds() < 2000);
    try std.testing.expect(fake.exited.load(.acquire));
    try std.testing.expect(fake.saw_cancel.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fake.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fake.reviews.load(.acquire));
}

test "memory lifecycle known key capture batch atomic rejection clean receipt and core retrieval rejection" {
    const f = try Fixture.create();
    defer f.deinit();
    var fake: Fake = .{ .io = f.backend.io(), .mode = .malicious };
    const owner = try f.start(&fake);
    try f.wake(0);
    try settle(owner);
    try std.testing.expectError(error.SensitiveMemoryMaterial, submit(owner, "Remember " ++ key));
    var q = Queue.init(&f.root);
    const empty = try q.status(a);
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
    const id = try f.seed(1, .queued, now(f.backend.io()), &evidence);
    try f.wake(0);
    try settle(owner);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fake.reviews.load(.acquire));
    try missing(owner); // First valid candidate cannot escape a poisoned batch.
    try std.testing.expectError(error.FileNotFound, owner.store.read(a, "preferences-" ++ key));
    try receipt(&f.root, &id);
    try std.testing.expectEqual(@as(u16, @intFromError(error.SensitiveMemoryMaterial)), owner.failure.load(.acquire));
    try std.testing.expectEqual(@backingInt(@import("memory_service.zig").State.failed), owner.state.load(.acquire));
    const core = try owner.store.write(a, "core", "Local core contains " ++ key, null);
    defer a.free(core.content);
    defer a.free(core.version);
    try std.testing.expectError(error.SensitiveMemoryMaterial, owner.retrieve(a, text, 8192));
    try settle(owner);
    f.stop();
}

fn legacy(f: *Fixture, n: usize, topic: []const u8, content: []const u8) !void {
    var store = mem.Store.init(&f.root, .{});
    var repository = Repository.init(&store);
    const id = jobId(n);
    const material: k.Material = .{ .id = &id, .generation = try store.generation(), .created_ms = now(f.backend.io()), .sources = &evidence };
    var item = candidate;
    item.topic = topic;
    item.content = content;
    // Pure Repository deliberately has no session-key knowledge.
    try std.testing.expectEqual(@import("../tools/knowledge_store.zig").Apply.created, try repository.apply(a, material, item));
}

test "memory lifecycle legacy related key omits whole entry and recovered key source never sends" {
    for ([_]bool{ false, true }) |unsafe_source| {
        const f = try Fixture.create();
        defer f.deinit();
        try legacy(f, 8, "unsafe-legacy", "concise reviews unsafe sentinel " ++ key);
        try legacy(f, 9, "safe-legacy", "concise reviews safe sentinel");
        // Prove that both complete records are relevant before the owner applies
        // session-key screening. This guards against a vacuous lexical miss.
        var store = mem.Store.init(&f.root, .{});
        var repository = Repository.init(&store);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const related = try repository.related(arena.allocator(), text, now(f.backend.io()));
        try std.testing.expectEqual(@as(usize, 2), related.len);
        var found_unsafe = false;
        for (related) |entry| {
            if (std.mem.eql(u8, entry.topic, "unsafe-legacy")) {
                found_unsafe = true;
                try std.testing.expect(std.mem.find(u8, entry.content, key) != null);
            }
        }
        try std.testing.expect(found_unsafe);
        const sources: []const k.Evidence = if (unsafe_source) &.{.{ .id = 0, .kind = .user, .text = "concise reviews " ++ key }} else &evidence;
        // Persist before construction: this is recovered plaintext, not capture
        // admitted through the current owner's known-key filter.
        const id = try f.seed(1, .queued, now(f.backend.io()), sources);
        var fake: Fake = .{ .io = f.backend.io(), .mode = .related };
        const owner = try f.start(&fake);
        try std.testing.expectEqual(@as(usize, 0), fake.calls.load(.acquire));
        try f.wake(0); // Actual retrieve owns generation/wake even with no reference budget.
        try settle(owner);
        try receipt(&f.root, &id);
        try std.testing.expectEqual(@as(usize, if (unsafe_source) 0 else 1), fake.calls.load(.acquire));
        try std.testing.expectEqual(!unsafe_source, fake.related_checked.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), fake.reviews.load(.acquire));
        if (unsafe_source) try std.testing.expectEqual(@as(u16, @intFromError(error.SensitiveMemoryMaterial)), owner.failure.load(.acquire));
        f.stop();
    }
}
