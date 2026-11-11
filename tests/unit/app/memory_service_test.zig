test "completed jobs retain full FIFO values beyond last snapshot" {
    const Fake = struct {
        fn extract(_: *anyopaque, a: std.mem.Allocator, material: k.Material, _: *const p.Cancellation) ![]const k.Candidate {
            const text = material.sources[0].text;
            if (std.mem.eql(u8, text, "failure evidence")) return error.InvalidMemoryOutput;
            if (std.mem.eql(u8, text, "canceled evidence")) return error.Canceled;
            const first = std.mem.eql(u8, text, "first saved fact");
            return a.dupe(k.Candidate, &.{.{ .category = .preferences, .topic = if (first) "first" else "second", .content = text }});
        }
    };
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    var context: u8 = 0;
    fixture.owner.service_override = .{ .context = &context, .extract_fn = Fake.extract };
    const reference = try fixture.owner.retrieve(a, "first saved fact", 8192);
    a.free(reference);
    const one = try NotificationTestFixture.enqueue(fixture.owner, "first saved fact");
    const two = try NotificationTestFixture.enqueue(fixture.owner, "second saved fact");
    var cancel: p.Cancellation = .{};
    fixture.owner.drain(&cancel);
    try std.testing.expectEqual(two, fixture.owner.view().last_terminal.?.id);
    try std.testing.expectEqual(one, fixture.queue.peek().?.id);
    try std.testing.expectEqual(one, fixture.queue.peek().?.id);

    const fail_id = try NotificationTestFixture.enqueue(fixture.owner, "failure evidence");
    fixture.owner.drain(&cancel);
    const canceled_id = try NotificationTestFixture.enqueue(fixture.owner, "canceled evidence");
    fixture.owner.drain(&cancel);
    var incomplete: k.Capture = .{ .allocator = a, .incomplete = true };
    try std.testing.expectError(error.IncompleteCapture, fixture.owner.enqueueCopy(&incomplete, .chat, .{}));

    const first = fixture.queue.take().?;
    try std.testing.expectEqual(one, first.id);
    try std.testing.expectEqual(memory_status.Result.saved, first.result);
    try std.testing.expectEqual(@as(u32, 1), first.saved_count);
    try std.testing.expectEqualStrings("first saved fact", first.summary.text());
    const second = fixture.queue.take().?;
    try std.testing.expectEqual(two, second.id);
    try std.testing.expectEqual(memory_status.Result.saved, second.result);
    try std.testing.expectEqual(@as(u32, 1), second.saved_count);
    try std.testing.expectEqualStrings("second saved fact", second.summary.text());
    const failed = fixture.queue.take().?;
    try std.testing.expectEqual(fail_id, failed.id);
    try std.testing.expectEqual(memory_status.Result.failed, failed.result);
    try std.testing.expectEqual(memory_status.Failure.invalid_output, failed.failure.?);
    const canceled = fixture.queue.take().?;
    try std.testing.expectEqual(canceled_id, canceled.id);
    try std.testing.expectEqual(memory_status.Result.canceled, canceled.result);
    try std.testing.expectEqual(memory_status.Failure.canceled, canceled.failure.?);
    const rejected = fixture.queue.take().?;
    try std.testing.expectEqual(canceled_id + 1, rejected.id);
    try std.testing.expectEqual(memory_status.Result.failed, rejected.result);
    try std.testing.expect(fixture.queue.take() == null);
}
test "parent failure while a job is active notifies without changing either outcome" {
    const r = @import("../core/runtime.zig");
    const Fake = struct {
        io: std.Io,
        owner: *Coordinator,
        started: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        fn extract(raw: *anyopaque, a: std.mem.Allocator, _: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started.store(true, .release);
            while (!self.release.load(.acquire)) {
                if (cancel.isRequested()) return error.Canceled;
                try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
            }
            return a.dupe(k.Candidate, &.{.{ .category = .preferences, .topic = "parent-test", .content = "Job result remains saved." }});
        }
        fn call(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.owner.reportFailure(error.Busy);
            return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "Primary success" }} }, .finish = .stop } };
        }
        fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
            return error.UnexpectedTool;
        }
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
            return error.UnexpectedTool;
        }
    };
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    var fake: Fake = .{ .io = io, .owner = fixture.owner };
    fixture.owner.service_override = .{ .context = &fake, .extract_fn = Fake.extract };
    const id = try NotificationTestFixture.enqueue(fixture.owner, "Evidence for a saved job.");
    try NotificationTestFixture.waitBool(io, &fake.started);
    const before = fixture.owner.view();
    try std.testing.expectEqual(id, before.active.?.id);
    var runtime = try r.Runtime.init(a, io, &fixture.owner.config.value, .{ .context = &fake, .call_fn = Fake.call }, .{ .context = &fake, .schemas = &.{}, .prepare_fn = Fake.prepare, .execute_fn = Fake.execute }, .{}, "");
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const primary = try runtime.run("Primary task", &cancel);
    try std.testing.expectEqual(r.Status.success, primary.status);
    const during = fixture.owner.view();
    try std.testing.expectEqual(before.active.?.id, during.active.?.id);
    try std.testing.expectEqualDeep(before.last_terminal, during.last_terminal);
    const failure = fixture.queue.take().?;
    try std.testing.expectEqual(@as(u64, 0), failure.id);
    try std.testing.expectEqual(memory_status.Result.failed, failure.result);
    try std.testing.expectEqual(memory_status.Failure.busy, failure.failure.?);
    fake.release.store(true, .release);
    fixture.owner.drain(&cancel);
    const completed = fixture.queue.take().?;
    try std.testing.expectEqual(id, completed.id);
    try std.testing.expectEqual(memory_status.Result.saved, completed.result);
    try std.testing.expect(completed.failure == null);
    try std.testing.expectEqual(@as(u32, 1), completed.saved_count);
    try std.testing.expectEqualStrings("Job result remains saved.", completed.summary.text());
    try std.testing.expect(fixture.queue.take() == null);
}
test "worker wait failure publishes every pending completion" {
    const Empty = struct {
        fn extract(_: *anyopaque, _: std.mem.Allocator, _: k.Material, _: *const p.Cancellation) ![]const k.Candidate {
            return &.{};
        }
    };
    var backend = std.Io.Threaded.init(std.testing.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    var context: u8 = 0;
    fixture.owner.service_override = .{ .context = &context, .extract_fn = Empty.extract };
    const warm = try NotificationTestFixture.enqueue(fixture.owner, "warmup evidence");
    var cancel: p.Cancellation = .{};
    fixture.owner.drain(&cancel);
    try NotificationTestFixture.waitBool(io, &fixture.owner.wait_ready);
    fixture.owner.fail_wait.store(true, .release);
    const one = try NotificationTestFixture.enqueue(fixture.owner, "first stranded evidence");
    try NotificationTestFixture.waitGate(io, &fixture.owner.fail_wait_gate);
    const two = try NotificationTestFixture.enqueue(fixture.owner, "second stranded evidence");
    fixture.owner.fail_wait_gate.store(2, .release);
    fixture.owner.drain(&cancel);
    fixture.owner.cancelAndJoin();
    try std.testing.expectEqual(warm, fixture.queue.take().?.id);
    const first = fixture.queue.take().?;
    const second = fixture.queue.take().?;
    try std.testing.expectEqual(one, first.id);
    try std.testing.expectEqual(two, second.id);
    try std.testing.expectEqual(memory_status.Result.failed, first.result);
    try std.testing.expectEqual(memory_status.Result.failed, second.result);
    try std.testing.expect(fixture.queue.take() == null);
}
test "cancel joins active and queued jobs before queue release" {
    const Blocked = struct {
        io: std.Io,
        started: std.atomic.Value(bool) = .init(false),
        fn extract(raw: *anyopaque, _: std.mem.Allocator, _: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started.store(true, .release);
            while (!cancel.isRequested()) try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
            return error.Canceled;
        }
    };
    var backend = std.Io.Threaded.init(std.testing.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    var blocked: Blocked = .{ .io = io };
    fixture.owner.service_override = .{ .context = &blocked, .extract_fn = Blocked.extract };
    const one = try NotificationTestFixture.enqueue(fixture.owner, "active cancellation evidence");
    try NotificationTestFixture.waitBool(io, &blocked.started);
    const two = try NotificationTestFixture.enqueue(fixture.owner, "queued cancellation evidence two");
    const three = try NotificationTestFixture.enqueue(fixture.owner, "queued cancellation evidence three");
    fixture.owner.cancelAndJoin();
    for ([_]u64{ one, two, three }) |id| {
        const result = fixture.queue.take().?;
        try std.testing.expectEqual(id, result.id);
        try std.testing.expectEqual(memory_status.Result.canceled, result.result);
    }
    try std.testing.expect(fixture.queue.take() == null);
}
test "notification reservation exhaustion never limits Memory admission" {
    const Gated = struct {
        io: std.Io,
        started: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        fn extract(raw: *anyopaque, _: std.mem.Allocator, _: k.Material, cancel: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started.store(true, .release);
            while (!self.release.load(.acquire)) {
                if (cancel.isRequested()) return error.Canceled;
                try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
            }
            return &.{};
        }
    };
    var backend = std.Io.Threaded.init(std.testing.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var fixture = try NotificationTestFixture.init(io);
    defer fixture.deinit();
    const original = fixture.queue.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.queue.allocator = failing.allocator();
    defer {
        fixture.owner.cancelAndJoin();
        fixture.queue.allocator = original;
    }
    for (0..fixture.queue.emergency.len) |i| {
        fixture.queue.publish(fixture.queue.reserve().?, .{ .id = @intCast(100 + i), .result = .failed });
    }
    var gated: Gated = .{ .io = io };
    fixture.owner.service_override = .{ .context = &gated, .extract_fn = Gated.extract };
    const job = try NotificationTestFixture.enqueue(fixture.owner, "admitted while notifications are exhausted");
    try NotificationTestFixture.waitBool(io, &gated.started);
    // Free one emergency node before completion: publication retries only on
    // this exceptional OOM path and appends without disturbing earlier values.
    try std.testing.expectEqual(@as(u64, 100), fixture.queue.take().?.id);
    gated.release.store(true, .release);
    var cancel: p.Cancellation = .{};
    fixture.owner.drain(&cancel);
    for (101..108) |i| try std.testing.expectEqual(@as(u64, @intCast(i)), fixture.queue.take().?.id);
    const result = fixture.queue.take().?;
    try std.testing.expectEqual(job, result.id);
    try std.testing.expectEqual(memory_status.Result.skipped, result.result);
    try std.testing.expect(fixture.queue.take() == null);
}
test "admission allocation failure produces a reserved terminal" {
    var backend = std.Io.Threaded.init(std.testing.allocator, .{});
    defer backend.deinit();
    var fixture = try NotificationTestFixture.init(backend.io());
    defer fixture.deinit();
    var capture: k.Capture = .{ .allocator = std.testing.allocator };
    const original = fixture.owner.allocator;
    fixture.owner.allocator = std.testing.failing_allocator;
    const result = fixture.owner.enqueueCopy(&capture, .chat, .{});
    fixture.owner.allocator = original;
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(u16, @intFromError(error.OutOfMemory)), fixture.owner.failure.load(.acquire));
    try std.testing.expect(!fixture.owner.isPoisoned());
    const failure = fixture.queue.take().?;
    try std.testing.expectEqual(@as(u64, 1), failure.id);
    try std.testing.expectEqual(memory_status.Result.failed, failure.result);
    try std.testing.expect(fixture.queue.take() == null);
}
test "coordinator diagnostics pair extraction and writes" {
    const Capture = struct {
        records: [32]diag.Record = undefined,
        len: usize = 0,
        seq: u64 = 0,
        fn next(raw: ?*anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.seq += 1;
            return self.seq;
        }
        fn emit(raw: ?*anyopaque, record: diag.Record) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.records[self.len] = record;
            self.len += 1;
        }
    };
    const Fake = struct {
        fail: bool = false,
        cancel: bool = false,
        fn extract(raw: *anyopaque, a: std.mem.Allocator, _: k.Material, cancellation: *const p.Cancellation) ![]const k.Candidate {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.cancel) {
                @constCast(cancellation).cancel();
                return error.Canceled;
            }
            if (self.fail) return error.MemoryUnavailable;
            return a.dupe(k.Candidate, &.{
                .{ .category = .preferences, .topic = "first", .content = "Prefers concise explanations." },
                .{ .category = .preferences, .topic = "second", .content = "Prefers concise reviews." },
            });
        }
    };
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    var root = try fs.Root.open(a, io, path[0..try tmp.dir.realPath(io, &path)]);
    defer root.deinit();
    var config = try cfg.clone(a, .{ .provider = .{ .base_url = "http://127.0.0.1:1", .api_key = "fixture" }, .selected_provider = "local", .model = .{ .name = "fixture", .protocol = .chat, .context_tokens = 32768, .output_tokens = 8192 }, .limits = .{ .low_price_input = false } });
    defer cfg.release(&config);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const owner = try Coordinator.create(a, io, &root, config.value, &env);
    defer owner.deinit();
    var events: Capture = .{};
    owner.bindDiagnostics(.{ .context = &events, .emit_fn = Capture.emit, .next_fn = Capture.next });
    var fake: Fake = .{};
    owner.service_override = .{ .context = &fake, .extract_fn = Fake.extract };
    const text = "I prefer concise explanations in all code reviews.";
    var cancel: p.Cancellation = .{};
    const reference = try owner.retrieve(a, text, 8192);
    a.free(reference);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var capture: k.Capture = .{ .allocator = arena.allocator() };
    capture.add(.user, text);
    const saved = owner.finalize(&capture, .chat, &cancel);
    try std.testing.expectEqual(State.saved, saved.state);
    try std.testing.expect(saved.err == null);
    try std.testing.expectEqual(@as(u32, 2), saved.saved_count);
    try std.testing.expectEqual(@as(u16, 0), owner.failure.load(.acquire));
    try std.testing.expectEqual(@as(usize, 6), events.len);
    try std.testing.expectEqual(diag.Stage.memory_extract, events.records[0].stage);
    try std.testing.expectEqual(@as(?u32, 0), events.records[2].candidate_index);
    try std.testing.expectEqual(diag.Stage.memory_write, events.records[4].stage);
    try std.testing.expectEqual(@as(?u32, 1), events.records[4].candidate_index);
    events.len = 0;
    fake.fail = true;
    const again = try owner.retrieve(a, text, 8192);
    a.free(again);
    const uncertain = owner.finalize(&capture, .chat, &cancel);
    try std.testing.expectEqual(State.uncertain, uncertain.state);
    try std.testing.expect(uncertain.err.? == error.MemoryUnavailable);
    try std.testing.expectEqual(@as(u16, @intFromError(error.MemoryUnavailable)), owner.failure.load(.acquire));
    try std.testing.expectEqualStrings("MemoryUnavailable", events.records[1].error_name.?.name());
    events.len = 0;
    fake.fail = false;
    fake.cancel = true;
    const last = try owner.retrieve(a, text, 8192);
    a.free(last);
    const canceled = owner.finalize(&capture, .chat, &cancel);
    try std.testing.expectEqual(State.canceled, canceled.state);
    try std.testing.expect(canceled.err.? == error.Canceled);
    try std.testing.expectEqual(@as(u16, @intFromError(error.Canceled)), owner.failure.load(.acquire));
    try std.testing.expectEqual(diag.Result.canceled, events.records[1].result.?);

    owner.reportFailure(error.CleanupFailed);
    try std.testing.expect(owner.isPoisoned());
    try std.testing.expectEqual(@as(u16, @intFromError(error.CleanupFailed)), owner.failure.load(.acquire));
    try std.testing.expectEqual(memory_status.Failure.cleanup, owner.view().last_terminal.?.failure.?);
    var retry_cancel: p.Cancellation = .{};
    const blocked = owner.finalize(&capture, .chat, &retry_cancel);
    try std.testing.expectEqual(State.failed, blocked.state);
    try std.testing.expect(blocked.err.? == error.CleanupFailed);
    try std.testing.expect(owner.isPoisoned());
    try std.testing.expectError(error.CleanupFailed, owner.retrieve(a, text, 8192));
}
test "Codex memory secret registration and incomplete source fail closed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    var root = try fs.Root.open(a, io, path[0..try tmp.dir.realPath(io, &path)]);
    defer root.deinit();
    var config = try cfg.clone(a, .{
        .provider = .{ .base_url = "https://chatgpt.com/backend-api/codex", .kind = .openai_codex, .codex_oauth = .{ .access_token = "access-canary", .refresh_token = "refresh-canary", .expires_at_ms = 1 } },
        .selected_provider = "codex",
        .model = .{ .name = "model", .protocol = .responses, .context_tokens = 32768 },
        .limits = .{ .low_price_input = false },
    });
    defer cfg.release(&config);
    try cfg.validate(config.value);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const owner = try Coordinator.create(a, io, &root, config.value, &env);
    defer owner.deinit();
    try std.testing.expect(owner.containsSecret("access-canary"));
    try std.testing.expect(owner.containsSecret("refresh-canary"));
    try std.testing.expectError(error.MissingCredentialSource, Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000));
    const Fake = struct {
        fn acquire(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: []const u8, _: ?*const p.Cancellation, _: u32) !codex_auth.RequestCredential {
            const mode: *u8 = @ptrCast(@alignCast(ctx.?));
            const access = try alloc.dupe(u8, if (mode.* == 2) "new-access-canary" else "rotated-access-canary");
            errdefer alloc.free(access);
            const account = try alloc.dupe(u8, "account");
            errdefer alloc.free(account);
            return .{ .access_token = access, .account_id = account, .redaction_refresh_token = if (mode.* != 0) try alloc.dupe(u8, "rotated-refresh-canary") else null };
        }
    };
    var mode: u8 = 1;
    owner.codex_source = .{ .context = &mode, .acquire_fn = Fake.acquire };
    var credential = try Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000);
    credential.deinit(a);
    try std.testing.expect(owner.containsSecret("rotated-access-canary"));
    try std.testing.expect(owner.containsSecret("rotated-refresh-canary"));
    mode = 0;
    try std.testing.expectError(error.CodexSecretRegistrationUnavailable, Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000));
    while (owner.secret_count < owner.secrets.len) {
        var buffer: [40]u8 = undefined;
        try owner.rememberSecret(try std.fmt.bufPrint(&buffer, "capacity-{d}", .{owner.secret_count}));
    }
    mode = 1;
    var duplicate = try Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000);
    duplicate.deinit(a);
    mode = 2;
    try std.testing.expectError(error.TooManySessionCredentials, Coordinator.acquireGuardedCodex(owner, a, "codex", null, 1000));
}
