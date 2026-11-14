test "rotated journal credential filters related evidence and candidates" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try openRoot(a, io, tmp.dir);
    defer root.deinit();
    var config = try fixtureConfig(a);
    defer cfg.release(&config);
    config.value.provider.api_key = try config.arena.allocator().dupe(u8, "new-credential-canary");
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var journal = try @import("journal.zig").Journal.init(a, &root, "new-credential-canary");
    defer journal.deinit();
    try journal.rememberKey("old-credential-canary");
    const owner = try Coordinator.create(a, io, &root, config.value, &env);
    defer owner.deinit();
    const Guard = struct {
        fn contains(raw: *anyopaque, text: []const u8) bool {
            const j: *@import("journal.zig").Journal = @ptrCast(@alignCast(raw));
            return j.containsSecret(text);
        }
    };
    owner.secret_guard = .{ .context = &journal, .contains_fn = Guard.contains };
    var repository = knowledge.Repository.init(&owner.store);
    const material: k.Material = .{ .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .created_ms = 1, .sources = &.{} };
    try std.testing.expectEqual(knowledge.Apply.created, try repository.apply(a, material, .{ .category = .preferences, .topic = "rotation", .content = "rotation old-credential-canary" }));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const now: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toMilliseconds()));
    const related = try repository.related(arena.allocator(), "rotation", now);
    try std.testing.expectEqual(@as(usize, 1), related.len);
    const Extract = struct {
        calls: usize = 0,
        fn extract(raw: *anyopaque, alloc: std.mem.Allocator, source: k.Material, _: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqual(@as(usize, 0), source.related.len);
            for (source.sources) |evidence| try std.testing.expect(std.mem.find(u8, evidence.text, "old-credential-canary") == null);
            return alloc.dupe(k.Candidate, &.{
                .{ .category = .preferences, .topic = "leak", .content = "old-credential-canary" },
                .{ .category = .preferences, .topic = "safe", .content = "A safe rotation fact." },
            });
        }
    };
    var fake: Extract = .{};
    owner.service_override = .{ .context = &fake, .extract_fn = Extract.extract };
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, "rotation preferences");
    capture.add(.tool, "old-credential-canary");
    _ = try owner.enqueueCopy(&capture, .chat, .{});
    var cancel: p.Cancellation = .{};
    owner.drain(&cancel);
    const terminal = owner.view().last_terminal.?;
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(memory_status.Result.saved, terminal.result);
    try std.testing.expectEqual(@as(u32, 1), terminal.saved_count);
    try std.testing.expectEqualStrings("A safe rotation fact.", terminal.summary.text());
    try std.testing.expectError(error.FileNotFound, owner.store.read(a, "preferences-leak"));
    const saved = try owner.store.read(a, "preferences-safe");
    defer a.free(saved.content);
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
test "automatic Memory applies after an earlier manual mutation" {
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
    const entry = try owner.store.create(a, "old", "old fact");
    defer a.free(entry.content);
    try begin(owner, a, input);
    try owner.store.remove("old");
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
    try std.testing.expectEqual(@as(c_int, 0), fs.flock(held, fs.LOCK.EX | fs.LOCK.NB));
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
test "queued jobs run FIFO from owned capture copies" {
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
    // Later jobs see prior facts through the normal related lookup.
    try std.testing.expectEqual(@as(usize, 0), gated.related_counts[0]);
    try std.testing.expect(gated.related_counts[1] >= 1);
    try std.testing.expect(gated.related_counts[2] >= 2);
    const expected = [_]struct { key: []const u8, text: []const u8 }{
        .{ .key = "preferences-job-1", .text = "fifo alpha fact" },
        .{ .key = "preferences-job-2", .text = "fifo beta fact" },
        .{ .key = "preferences-job-3", .text = "fifo gamma fact" },
    };
    for (expected) |item| {
        const entry = try owner.store.read(a, item.key);
        defer a.free(entry.content);
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

    const reference = try owner.retrieve(a, input);
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
    const existing = try owner.store.create(a, "preferences-conflict", "existing independent fact");
    defer a.free(existing.content);
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
                .{ .category = .preferences, .topic = "secret", .content = "owned-memory-fixture-key" },
                .{ .category = .preferences, .topic = "bearer-secret", .content = "Bearer abc.def" },
                .{ .category = .preferences, .topic = "good", .content = "  A useful fact.  " },
                .{ .category = .preferences, .topic = "conflict", .content = "must not overwrite" },
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
    try std.testing.expect(std.mem.indexOf(u8, saved.content, "owned-memory-fixture-key") == null);
    try std.testing.expectError(error.FileNotFound, owner.store.read(a, "preferences-secret"));
    const ordinary = try owner.store.read(a, "preferences-bearer-secret");
    defer a.free(ordinary.content);
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
    try std.testing.expectEqualStrings("existing independent fact", conflict.content);
}
test "automatic Memory saves every candidate without a total index budget" {
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
    const Many = struct {
        fn extract(_: *anyopaque, alloc: std.mem.Allocator, _: k.Material, _: *const p.Cancellation) ![]const k.Candidate {
            return alloc.dupe(k.Candidate, &.{
                .{ .category = .project, .topic = "fact-0", .content = "Durable fact zero." },
                .{ .category = .project, .topic = "fact-1", .content = "Durable fact one." },
                .{ .category = .project, .topic = "fact-2", .content = "Durable fact two." },
                .{ .category = .project, .topic = "fact-3", .content = "Durable fact three." },
                .{ .category = .project, .topic = "fact-4", .content = "Durable fact four." },
                .{ .category = .project, .topic = "fact-5", .content = "Durable fact five." },
                .{ .category = .project, .topic = "fact-6", .content = "Durable fact six." },
                .{ .category = .project, .topic = "fact-7", .content = "Durable fact seven." },
            });
        }
    };
    var dummy: u8 = 0;
    owner.service_override = .{ .context = &dummy, .extract_fn = Many.extract };
    try begin(owner, a, "eight facts");
    var cancel: p.Cancellation = .{};
    const terminal = try finalize(owner, a, "eight facts", &cancel);
    try std.testing.expect(terminal.result == .saved);
    try std.testing.expectEqual(@as(u32, 8), terminal.saved_count);
    for (0..8) |i| {
        const key = try std.fmt.allocPrint(a, "project-fact-{d}", .{i});
        defer a.free(key);
        const entry = try owner.store.read(a, key);
        defer a.free(entry.content);
        try std.testing.expect(std.mem.find(u8, entry.content, "Durable fact") != null);
    }
}
