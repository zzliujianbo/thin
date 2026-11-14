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
    const reference = try owner.retrieve(a, text);
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
    try std.testing.expectError(error.FileNotFound, root.dir.statFile(root.io, ".thin/memory/jobs-owner", .{ .follow_symlinks = false }));
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
    related_counts: [8]usize = @splat(0),
    texts: [8][32]u8 = @splat(@splat(0)),
    text_lens: [8]usize = @splat(0),

    fn service(self: *@This()) k.Service {
        return .{ .context = self, .extract_fn = extract };
    }
    fn extract(raw: *anyopaque, a: std.mem.Allocator, material: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const index: usize = @intCast(self.calls.fetchAdd(1, .acq_rel));
        self.started.store(true, .release);
        if (index < self.related_counts.len) {
            self.related_counts[index] = material.related.len;
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
